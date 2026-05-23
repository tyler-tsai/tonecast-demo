import SwiftUI
import StoreKit
import OSLog

/// Tonecast Plus paywall. Presented as a sheet from Settings →
/// "Upgrade to Plus" (and from rate-limit prompts in the future).
/// Loads products from App Store Connect at sheet appear, runs the
/// purchase via IAPService, and dismisses when the local tier flips
/// to plus.
///
/// App Store HIG checklist this view ticks off:
///   - Clear price + period before purchase (4.10.1)
///   - "Restore Purchases" button (4.10)
///   - Privacy policy + Terms links (3.1.2)
///   - Subscription metadata (auto-renew disclosure) — under the
///     subscribe buttons; iOS prepends Apple's standard verbiage
///     in the StoreKit confirmation sheet, but App Review usually
///     wants it on the paywall too.
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var products: [Product] = []
    @State private var isLoadingProducts: Bool = true
    @State private var loadError: String? = nil

    @State private var purchasingProductId: String? = nil
    @State private var purchaseError: String? = nil

    @State private var isRestoring: Bool = false
    @State private var restoreMessage: String? = nil

    @State private var storefrontInfo: String? = nil

    private let logger = Logger(subsystem: "tonecast", category: "Paywall")

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    featuresBlock
                    productsBlock
                    restoreBlock
                    footerBlock
                }
                .padding(20)
            }
            .navigationTitle("Tonecast Plus")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task {
            await loadProducts()
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "keyboard.badge.ellipsis")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)
            Text("Dictate without limits")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Free tier caps at 200 keyboard requests/day. Plus lifts the cap to 1,000/day so heavy chat-and-rewrite sessions keep flowing.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    private var featuresBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            feature("1,000 requests / day", icon: "infinity")
            feature("Tone shift + zh⇄en translate", icon: "wand.and.stars")
            feature("Supports development of Tonecast", icon: "heart.fill")
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    private func feature(_ text: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 24)
            Text(text)
                .font(.body)
            Spacer()
        }
    }

    @ViewBuilder
    private var productsBlock: some View {
        if isLoadingProducts {
            ProgressView("Loading subscriptions…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
        } else if let err = loadError {
            VStack(spacing: 8) {
                Text("Couldn't load subscriptions")
                    .font(.headline)
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try again") {
                    Task { await loadProducts() }
                }
                .padding(.top, 4)
            }
            .padding(.vertical, 24)
        } else if products.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("No subscriptions available")
                    .font(.headline)
                Text("StoreKit returned 0 products. Diagnostic:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(IAPService.ProductIdentifiers.all, id: \.self) { pid in
                    Text("• \(pid)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                if let storefront = storefrontInfo {
                    Text("Storefront: \(storefront)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text("Common causes:\n• Sandbox account not signed in\n• Product propagation delay (5–30 min)\n• Product state = MISSING_METADATA in ASC")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Reload") {
                    Task { await loadProducts() }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 24)
        } else {
            VStack(spacing: 12) {
                // Annual first (better value), then monthly.
                ForEach(sortedProducts, id: \.id) { product in
                    productButton(product)
                }
                if let err = purchaseError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
            }
        }
    }

    private var sortedProducts: [Product] {
        products.sorted { lhs, rhs in
            let aIsAnnual = lhs.id.hasSuffix(".annual")
            let bIsAnnual = rhs.id.hasSuffix(".annual")
            if aIsAnnual && !bIsAnnual { return true }
            if !aIsAnnual && bIsAnnual { return false }
            return lhs.id < rhs.id
        }
    }

    private func productButton(_ product: Product) -> some View {
        let isPurchasing = purchasingProductId == product.id
        let isAnnual = product.id.hasSuffix(".annual")
        return Button {
            Task { await purchase(product) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(productTitle(product))
                            .font(.headline)
                        if isAnnual {
                            Text("Best value")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.green.opacity(0.18)))
                                .foregroundStyle(.green)
                        }
                    }
                    Text(productSubtitle(product))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isPurchasing {
                    ProgressView()
                } else {
                    Text(product.displayPrice)
                        .font(.headline)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isAnnual ? Color.accentColor : Color(uiColor: .separator), lineWidth: isAnnual ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(purchasingProductId != nil)
    }

    private func productTitle(_ product: Product) -> String {
        let raw = product.displayName
        if raw.isEmpty { return product.id }
        return raw
    }

    private func productSubtitle(_ product: Product) -> String {
        guard let sub = product.subscription else {
            return product.description.isEmpty ? "One-time" : product.description
        }
        let period = sub.subscriptionPeriod
        let unit = unitText(period.unit, count: period.value)
        return "Auto-renews every \(unit)"
    }

    private func unitText(_ unit: Product.SubscriptionPeriod.Unit, count: Int) -> String {
        let base: String
        switch unit {
        case .day: base = "day"
        case .week: base = "week"
        case .month: base = "month"
        case .year: base = "year"
        @unknown default: base = "period"
        }
        return count == 1 ? base : "\(count) \(base)s"
    }

    @ViewBuilder
    private var restoreBlock: some View {
        VStack(spacing: 6) {
            Button {
                Task { await restore() }
            } label: {
                if isRestoring {
                    ProgressView()
                } else {
                    Text("Restore Purchases")
                        .font(.callout)
                }
            }
            .disabled(isRestoring)
            if let msg = restoreMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footerBlock: some View {
        VStack(spacing: 8) {
            Text("Subscription auto-renews unless cancelled at least 24 hours before the end of the current period. Manage or cancel anytime in your Apple ID Subscriptions.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Link("Privacy Policy", destination: URL(string: "https://your-org.github.io/legal-pages/tonecast-privacy.html")!)
                Text("·").foregroundStyle(.tertiary)
                Link("Terms of Use", destination: URL(string: "https://your-org.github.io/legal-pages/tonecast-terms.html")!)
            }
            .font(.caption2)
        }
        .padding(.top, 8)
    }

    // MARK: - Actions

    private func loadProducts() async {
        // Fast path: render IAPService's cache instantly when present,
        // skipping the loading spinner entirely. Then refresh in the
        // background to pick up any ASC changes since cache time.
        let cached = await IAPService.shared.cachedProductsSnapshot()
        if !cached.isEmpty {
            self.products = cached
            self.isLoadingProducts = false
        } else {
            self.isLoadingProducts = true
        }
        loadError = nil
        if let sf = await Storefront.current {
            storefrontInfo = "\(sf.countryCode) (\(sf.id))"
            logger.notice("storefront: \(sf.countryCode, privacy: .public) id=\(sf.id, privacy: .public)")
        }
        do {
            let loaded = try await IAPService.shared.loadProducts()
            self.products = loaded
            self.isLoadingProducts = false
            logger.notice("loadProducts returned \(loaded.count, privacy: .public) product(s) for ids=\(IAPService.ProductIdentifiers.all, privacy: .public)")
            if loaded.isEmpty {
                logger.warning("Product list empty — check App Store Connect config")
            }
        } catch {
            self.loadError = error.localizedDescription
            self.isLoadingProducts = false
            logger.error("loadProducts failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func purchase(_ product: Product) async {
        purchasingProductId = product.id
        purchaseError = nil
        defer { purchasingProductId = nil }
        do {
            let transaction = try await IAPService.shared.purchase(product)
            if transaction != nil {
                dismiss()
            }
            // Nil = cancelled / pending → leave sheet open.
        } catch {
            self.purchaseError = error.localizedDescription
            logger.error("purchase failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func restore() async {
        isRestoring = true
        restoreMessage = nil
        defer { isRestoring = false }
        do {
            try await IAPService.shared.restorePurchases()
            let tier = await IAPService.shared.currentTier()
            if tier == .plus {
                restoreMessage = "Plus restored."
                try? await Task.sleep(nanoseconds: 800_000_000)
                dismiss()
            } else {
                restoreMessage = "No active subscription found on this Apple ID."
            }
        } catch {
            restoreMessage = error.localizedDescription
            logger.error("restore failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

#Preview {
    PaywallView()
}
