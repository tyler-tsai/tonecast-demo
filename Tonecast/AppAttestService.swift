import Foundation
import CryptoKit
import OSLog
#if canImport(DeviceCheck)
import DeviceCheck
#endif

/// App Attest integration for Tonecast.
///
/// Kept as a plain file rather than an SPM target because Tonecast's
/// project layout is file-based.
///
/// Flow:
/// 1. App init kicks off `setUpIfNeeded()` (fire-and-forget).
/// 2. On first launch on a real device:
///      - `DCAppAttestService.generateKey()` → fresh `keyId` (base64).
///      - Compute deterministic challenge = `SHA256("\(appId)-attest:\(keyId)")`.
///      - Compute `clientDataHash = SHA256(challenge)`.
///      - `attestKey(keyId, clientDataHash:)` → CBOR attestation blob.
///      - POST `{ keyId, attestation, app }` to the proxy's `/v1/attest`.
///      - Persist `keyId` locally on 2xx response.
/// 3. Every protected request goes through `sign(_:)`:
///      - `clientDataHash = SHA256("\(method) \(path)")`.
///      - `generateAssertion(keyId, clientDataHash:)` → CBOR assertion.
///      - Inject `X-AppAttest-KeyID` + `X-AppAttest-Assertion` headers.
///
/// No-ops gracefully when:
///   - Running on Simulator (`DCAppAttestService.isSupported == false`).
///     Consequence: voice/transcribe + GPT calls 401 in Simulator. Use
///     a real device for end-to-end testing.
///   - Attestation hasn't completed yet (first request raced setup) —
///     `sign(_:)` awaits the in-flight setup task before returning.
///   - Apple's service returns an unexpected error (logged, then no-op
///     — the proxy will 401 the unsigned request).
actor AppAttestService: RequestSigner {

    enum Mode: Sendable, Equatable {
        /// Signer disabled — used by tests.
        case disabled
        /// Proxy mode — sign every request with App Attest assertions
        /// against the given proxy base URL. `appId` matches the
        /// proxy's `AppConfig.appId` ("tonecast").
        case enabled(proxyBaseURL: URL, appId: String)
    }

    static let shared = AppAttestService()

    private let logger = Logger(subsystem: "tonecast", category: "AppAttest")
    private let session: URLSession
    private var mode: Mode = .disabled

    /// Persisted across launches in UserDefaults — the keyId is not
    /// secret (it's SHA256 of a public key), so UserDefaults is fine.
    /// The corresponding private key lives in the Secure Enclave and
    /// is referenced by this string id. UserDefaults is per-app so the
    /// key name does not collide with other apps from the same team.
    private let keyIdDefaultsKey = "appattest.keyId"
    private let attestedDefaultsKey = "appattest.attested"

    /// In-flight setup task — `sign(_:)` awaits this so requests that
    /// race the initial attestation get the new headers as soon as
    /// setup completes, rather than racing through with no headers.
    private var setupTask: Task<Void, Never>?

    init(session: URLSession = .shared) {
        self.session = session
    }

    func configure(mode: Mode) {
        self.mode = mode
    }

    /// One-shot setup. Idempotent: safe to call from multiple sites
    /// (the second call awaits the first's task).
    func setUpIfNeeded() async {
        if let task = setupTask {
            await task.value
            return
        }
        let task = Task<Void, Never> { [weak self] in
            await self?.runSetup()
        }
        setupTask = task
        await task.value
    }

    private func runSetup() async {
        guard case .enabled(let baseURL, let appId) = mode else {
            return
        }
        #if canImport(DeviceCheck)
        let service = DCAppAttestService.shared
        guard service.isSupported else {
            logger.notice("DCAppAttestService unsupported (likely Simulator) — proxy calls will 401.")
            return
        }
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: attestedDefaultsKey),
           let existing = defaults.string(forKey: keyIdDefaultsKey),
           !existing.isEmpty {
            logger.debug("App Attest already set up: keyId prefix=\(existing.prefix(8), privacy: .public)")
            return
        }

        do {
            let keyId = try await service.generateKey()
            logger.notice("App Attest key generated: prefix=\(keyId.prefix(8), privacy: .public)")

            // Both sides compute SHA256("<appId>-attest:" + keyId) as
            // the challenge — see proxy's deriveAttestChallenge. The
            // framework hashes (challenge) once internally before
            // signing, so we pass the challenge as the clientDataHash
            // field after a single SHA-256 pass.
            let challenge = Self.attestChallenge(forKeyId: keyId, appId: appId)
            let clientDataHash = Data(SHA256.hash(data: challenge))

            let attestation = try await service.attestKey(keyId, clientDataHash: clientDataHash)
            try await postAttestation(baseURL: baseURL, appId: appId, keyId: keyId, attestation: attestation)

            defaults.set(keyId, forKey: keyIdDefaultsKey)
            defaults.set(true, forKey: attestedDefaultsKey)
            logger.notice("App Attest attestation persisted.")
        } catch {
            // Don't bubble — next launch will retry. Subsequent
            // requests will 401 until attestation succeeds.
            logger.error("App Attest setup failed: \(error.localizedDescription, privacy: .public)")
        }
        #else
        logger.notice("DeviceCheck not available on this platform — App Attest disabled.")
        #endif
    }

    func sign(_ request: inout URLRequest) async throws {
        guard case .enabled = mode else { return }
        #if canImport(DeviceCheck)
        let service = DCAppAttestService.shared
        guard service.isSupported else { return }

        // Wait for an in-flight setup so first-request-after-launch
        // doesn't race past with empty headers. If setup never started
        // we don't trigger it here — TonecastApp.init owns that path.
        if let task = setupTask {
            await task.value
        }

        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: attestedDefaultsKey),
              let keyId = defaults.string(forKey: keyIdDefaultsKey),
              !keyId.isEmpty,
              let url = request.url,
              let method = request.httpMethod else {
            return // attestation never completed → request goes unsigned, proxy will 401
        }

        let path = url.path.isEmpty ? "/" : url.path
        let clientData = "\(method) \(path)"
        let clientDataHash = Data(SHA256.hash(data: Data(clientData.utf8)))

        do {
            let assertion = try await service.generateAssertion(keyId, clientDataHash: clientDataHash)
            request.setValue(keyId, forHTTPHeaderField: "X-AppAttest-KeyID")
            request.setValue(assertion.base64EncodedString(), forHTTPHeaderField: "X-AppAttest-Assertion")
        } catch {
            // Log but don't throw — the proxy will 401 if headers are
            // missing, which surfaces a clearer error to the user.
            logger.warning("generateAssertion failed for \(clientData, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    /// Same shape as the server's `deriveAttestChallenge`. Exposed for
    /// tests that exercise both sides agree on the input. The `appId`
    /// prefix means a keyId attested for one app cannot be replayed as
    /// an attestation for another app.
    static func attestChallenge(forKeyId keyId: String, appId: String) -> Data {
        let raw = "\(appId)-attest:\(keyId)".data(using: .utf8) ?? Data()
        return Data(SHA256.hash(data: raw))
    }

    private func postAttestation(baseURL: URL, appId: String, keyId: String, attestation: Data) async throws {
        struct Payload: Encodable {
            let keyId: String
            let attestation: String
            let app: String
        }
        let url = baseURL.appendingPathComponent("v1/attest")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = Payload(keyId: keyId, attestation: attestation.base64EncodedString(), app: appId)
        let body = try JSONEncoder().encode(payload)
        let (data, response) = try await session.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else {
            throw AttestError.network("no HTTPURLResponse")
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw AttestError.serverRejected(status: http.statusCode, body: String(snippet))
        }
    }

    enum AttestError: Error, CustomStringConvertible {
        case network(String)
        case serverRejected(status: Int, body: String)

        var description: String {
            switch self {
            case .network(let reason): return "network: \(reason)"
            case .serverRejected(let status, let body): return "server \(status): \(body)"
            }
        }
    }
}
