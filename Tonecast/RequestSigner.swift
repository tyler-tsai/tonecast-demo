import Foundation

/// Hook for client code that needs to mutate `URLRequest` headers
/// before send-time — used to inject App Attest assertion headers
/// (`X-AppAttest-KeyID` + `X-AppAttest-Assertion`).
///
/// Simulator builds use the no-op implementation (DCAppAttestService
/// reports `isSupported == false` there); device builds plug in the
/// real `AppAttestService`-backed signer.
protocol RequestSigner: Sendable {
    /// Attach signing headers to `request`. Implementations MUST
    /// either set the headers or no-op cleanly; throwing should be
    /// reserved for unrecoverable problems. Callers generally wrap
    /// this in a try? so transient signing failures don't fail the
    /// whole request — but with the bearer fallback removed, an
    /// unsigned request will be rejected as 401 by the proxy.
    func sign(_ request: inout URLRequest) async throws
}

/// Default no-op signer. Used by unit tests and any code path that
/// hasn't been wired up to App Attest yet.
struct NoopRequestSigner: RequestSigner {
    func sign(_ request: inout URLRequest) async throws {
        // intentionally empty
    }
}
