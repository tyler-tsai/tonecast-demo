import Foundation
import OSLog
import StoreKit

/// StoreKit 2 integration for Tonecast Plus.
///
/// Flow:
/// 1. App init configures the actor with the proxy base URL + the
///    App Attest signer. A detached Task starts listening on
///    `Transaction.updates` immediately (Apple's required pattern —
///    renewals / refunds / family-sharing events get delivered
///    asynchronously and must be drained from launch).
/// 2. `loadProducts()` fetches the SKU metadata from the App Store
///    (price string, localized title) for the paywall.
/// 3. `purchase(_:)` runs the StoreKit purchase sheet, finishes the
///    transaction, then calls `syncWithServer()`.
/// 4. `syncWithServer()` walks `Transaction.currentEntitlements` and
///    POSTs each verified plus-product JWS to `/v1/iap/verify`. The
///    proxy is the authority on tier — the local cache in UserDefaults
///    is a UI hint, not a security boundary.
/// 5. `restorePurchases()` triggers `AppStore.sync()` (required by
///    App Store HIG 4.10) and then `syncWithServer()` to roll any
///    newly-surfaced entitlements through the proxy.
///
/// Falls back gracefully when:
///   - Running on simulator where IAP works locally but the proxy
///     can't verify App Attest assertions (the post will 401; the
///     local tier still updates so dev UI behaves).
///   - Network is offline (post fails; local tier from StoreKit is
///     authoritative for the UI until next sync).

actor IAPService {

    enum Mode: Sendable {
        /// IAP disabled (e.g. unit-tests, simulator dev).
        case disabled
        /// IAP active. `signer` provides App Attest headers for the
        /// /v1/iap/verify call to the proxy.
        case enabled(proxyBaseURL: URL, appId: String, signer: any RequestSigner)
    }

    /// Product identifiers that unlock the Plus tier. These MUST match
    /// the configured products in App Store Connect AND the proxy's
    /// `AppConfig.plusProductIds` allowlist — a mismatch on either side
    /// means the purchase silently fails to upgrade. See
    /// `docs/IAP_SETUP_GUIDE.md`.
    enum ProductIdentifiers {
        // Apple disallows hyphens in productId — can't reuse the bundleId
        // prefix (com.example.tonecast). Use the brand `tonecast.*`
        // namespace. MUST match AppConfig.plusProductIds on the proxy.
        static let monthly = "tonecast.plus.monthly"
        static let annual = "tonecast.plus.annual"
        static var all: [String] { [monthly, annual] }
    }

    static let shared = IAPService()

    private let logger = Logger(subsystem: "tonecast", category: "IAP")
    private let session: URLSession
    private var mode: Mode = .disabled
    private var updatesTask: Task<Void, Never>?

    /// In-memory product cache. Populated by `warmUp()` / `loadProducts()`.
    /// Read sync via `cachedProductsSnapshot()` so the paywall can render
    /// immediately without re-awaiting StoreKit on every present.
    private var cachedProducts: [Product] = []

    /// Once `warmUp()` has successfully completed at least once, we
    /// skip further work — Storefront + sandbox-account confirmation
    /// dialogs are one-shot per session and rerunning them would just
    /// re-prompt the user.
    private var warmUpTask: Task<Void, Never>?

    init(session: URLSession = .shared) {
        self.session = session
    }

    func configure(mode: Mode) {
        self.mode = mode
        if case .enabled = mode, updatesTask == nil {
            updatesTask = Task.detached(priority: .background) { [weak self] in
                await self?.listenForUpdates()
            }
        }
    }

    /// Fetch product metadata from the App Store. Throws when the
    /// network is down OR (more often in dev) when the products
    /// aren't yet configured in App Store Connect for the current
    /// bundle's environment. Caches the result so subsequent paywall
    /// opens render instantly via `cachedProductsSnapshot()`.
    func loadProducts() async throws -> [Product] {
        let products = try await Product.products(for: ProductIdentifiers.all)
        cachedProducts = products
        logger.notice("Loaded \(products.count, privacy: .public) IAP products")
        return products
    }

    /// Snapshot of the most recent successful `loadProducts()`. Empty
    /// before warm-up completes. Safe to call from the paywall to
    /// short-circuit the loading spinner.
    func cachedProductsSnapshot() -> [Product] {
        return cachedProducts
    }

    /// Idempotent warm-up: triggers the one-shot iOS sandbox-account
    /// confirmation dialog + populates the product cache. Call BEFORE
    /// presenting the paywall — otherwise the first paywall present
    /// races against the sandbox prompt, which iOS resolves by
    /// dismissing whatever sheet is in flight ("paywall flashes
    /// closed on first tap, works on second"). Subsequent calls await
    /// the same in-flight task if one is already running, then return
    /// immediately once the cache is populated.
    func warmUp() async {
        if !cachedProducts.isEmpty {
            return
        }
        if let task = warmUpTask {
            await task.value
            return
        }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            // Touching Storefront.current is what actually triggers
            // iOS to resolve the sandbox account selection. Doing
            // this BEFORE Product.products keeps the prompt isolated
            // to a moment when no sheet is present.
            _ = await Storefront.current
            do {
                _ = try await self.loadProducts()
            } catch {
                self.logger.warning("Warm-up loadProducts failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        warmUpTask = task
        await task.value
    }

    /// Run a purchase. `nil` return = user cancelled, or transaction
    /// is pending (e.g. parental approval). Caller should NOT treat
    /// pending as success — Transaction.updates will deliver the
    /// resolved transaction later and trigger syncWithServer then.
    func purchase(_ product: Product) async throws -> StoreKit.Transaction? {
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await transaction.finish()
            // Sync EVERY current entitlement, so a user who bought
            // monthly then upgraded to annual ends up reporting the
            // latest one to the server.
            await syncWithServer()
            return transaction
        case .userCancelled:
            return nil
        case .pending:
            logger.notice("Purchase pending (parental approval or SCA)")
            return nil
        @unknown default:
            return nil
        }
    }

    /// Restore Purchases button on the paywall. Required by App Store
    /// HIG 4.10. AppStore.sync() prompts for an iCloud password if
    /// needed, then refreshes Transaction.currentEntitlements.
    func restorePurchases() async throws {
        try await AppStore.sync()
        await syncWithServer()
    }

    /// Walk currentEntitlements, POST each plus-product JWS to the
    /// proxy, update the local tier cache to reflect the result.
    /// Safe to call repeatedly — proxy idempotently overwrites the
    /// tier:<keyId> KV record.
    func syncWithServer() async {
        guard case .enabled(let baseURL, let appId, let signer) = mode else {
            await refreshLocalTierFromStoreKit()
            return
        }
        var anyPlus = false
        var postedCount = 0
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard ProductIdentifiers.all.contains(transaction.productID) else { continue }
            // Send the SIGNED jws (from VerificationResult), not the
            // unsigned jsonRepresentation on Transaction.
            let jws = result.jwsRepresentation
            do {
                let response = try await postVerify(
                    jws: jws,
                    baseURL: baseURL,
                    appId: appId,
                    signer: signer
                )
                postedCount += 1
                if response.tier == "plus" {
                    anyPlus = true
                }
                logger.notice("Server verified \(transaction.productID, privacy: .public): tier=\(response.tier, privacy: .public)")
            } catch {
                logger.warning("iap sync failed for \(transaction.productID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                // Don't bail — keep trying other entitlements. The local
                // cache update below will fall back to StoreKit's view.
            }
        }
        // Cache update: prefer the server's answer when we got at
        // least one positive response. Otherwise reflect StoreKit's
        // local view (offline → local truth, instead of stuck plus
        // after a refund the server already saw).
        let newTier: UserTier
        if postedCount > 0 {
            newTier = anyPlus ? .plus : .free
        } else {
            newTier = await localTierFromStoreKit()
        }
        UserTier._write(newTier)
        logger.notice("Local tier cache updated: \(newTier.rawValue, privacy: .public)")
    }

    /// Read the local entitlement view without talking to the server.
    /// Used by the paywall to decide whether to even show subscribe.
    /// The proxy is still the source of truth for quota — this is for
    /// UI only.
    func currentTier() async -> UserTier {
        return await localTierFromStoreKit()
    }

    // MARK: - Private

    private func listenForUpdates() async {
        for await result in Transaction.updates {
            guard case .verified(let transaction) = result else {
                if case .unverified(_, let error) = result {
                    logger.warning("Unverified transaction update: \(error.localizedDescription, privacy: .public)")
                }
                continue
            }
            logger.notice("Transaction update: \(transaction.productID, privacy: .public) revocationDate=\(String(describing: transaction.revocationDate), privacy: .public)")
            await transaction.finish()
            await syncWithServer()
        }
    }

    private func localTierFromStoreKit() async -> UserTier {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard ProductIdentifiers.all.contains(transaction.productID) else { continue }
            // Subscription expiry handling: Transaction.expirationDate
            // for an active sub is in the future. For a refunded /
            // revoked transaction it might still appear but with
            // revocationDate set — skip those.
            if transaction.revocationDate != nil { continue }
            if let expiry = transaction.expirationDate, expiry <= Date() { continue }
            return .plus
        }
        return .free
    }

    private func refreshLocalTierFromStoreKit() async {
        let tier = await localTierFromStoreKit()
        UserTier._write(tier)
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value):
            return value
        case .unverified(_, let error):
            throw IAPError.unverified(error.localizedDescription)
        }
    }

    private struct VerifyResponse: Decodable {
        let ok: Bool
        let tier: String
        let expiresAt: TimeInterval
        let productId: String?
        let environment: String?
    }

    private func postVerify(
        jws: String,
        baseURL: URL,
        appId: String,
        signer: any RequestSigner
    ) async throws -> VerifyResponse {
        let url = baseURL.appendingPathComponent("v1/iap/verify")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(appId, forHTTPHeaderField: "X-App")
        let payload: [String: String] = ["transactionJWS": jws]
        request.httpBody = try JSONEncoder().encode(payload)
        try await signer.sign(&request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw IAPError.network("no HTTPURLResponse")
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw IAPError.serverRejected(status: http.statusCode, body: String(snippet))
        }
        return try JSONDecoder().decode(VerifyResponse.self, from: data)
    }

    enum IAPError: Error, CustomStringConvertible {
        case unverified(String)
        case network(String)
        case serverRejected(status: Int, body: String)

        var description: String {
            switch self {
            case .unverified(let reason): return "unverified: \(reason)"
            case .network(let reason): return "network: \(reason)"
            case .serverRejected(let status, let body): return "server \(status): \(body)"
            }
        }
    }
}
