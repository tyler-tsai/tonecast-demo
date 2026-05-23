import Foundation

/// Resolves where Tonecast's OpenAI calls should go.
///
/// Tonecast is **proxy-only** — every Whisper / GPT call routes through
/// a Cloudflare Worker proxy. The previous `.direct` enum case (which
/// would call `api.openai.com` with a bundled OpenAI key) was removed
/// when the bundled key was stripped.
///
/// The proxy used to also accept a shared bearer header as a fallback;
/// that path was retired. The only credential the app holds now is an
/// App Attest assertion produced per-request by `AppAttestService`.
struct ProxyMode: Equatable {
    let baseURL: URL

    init(baseURL: URL = ProxyEndpointDefaults.baseURL) {
        self.baseURL = baseURL
    }

    /// Endpoint to hit for `/v1/audio/transcriptions`.
    var transcribeEndpoint: URL {
        baseURL.appendingPathComponent("v1/audio/transcriptions")
    }

    /// Endpoint to hit for `/v1/chat/completions`. All three GPT call
    /// sites in ToneRewriter (rewrite / editSelectedText / refine)
    /// share this endpoint.
    var chatCompletionsEndpoint: URL {
        baseURL.appendingPathComponent("v1/chat/completions")
    }

    /// Header set the multi-tenant Worker uses to route the request to
    /// Tonecast's per-app config (bundleId verification, quotas, key
    /// pool).
    var extraHeaders: [String: String] {
        ["X-App": "tonecast"]
    }
}

/// Compile-time constants for the proxy connection. The shared bearer
/// that used to live here was removed once App Attest assertions became
/// the only credential.
enum ProxyEndpointDefaults {
    static let baseURL: URL = URL(string: "https://your-proxy.example.workers.dev")!

    /// Stable app id used in the X-App proxy header and as the prefix
    /// for the App Attest challenge derivation. Must match the `appId`
    /// field of the tonecast `AppConfig` on the proxy side.
    static let appId: String = "tonecast"

    static var current: ProxyMode {
        ProxyMode()
    }
}

/// App-Group accessor for the proxy mode. Returns the same value on
/// every call now that direct mode no longer exists — kept as a
/// function (instead of a constant) so future per-environment routing
/// (staging vs prod, A/B keys) has a single chokepoint to extend.
extension SharedDefaults {
    static func currentProxyMode() -> ProxyMode {
        ProxyEndpointDefaults.current
    }
}
