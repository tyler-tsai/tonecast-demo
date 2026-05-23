import Foundation

// Tonecast routes ALL OpenAI traffic through the proxy.
// The actual OpenAI key lives ONLY in the Worker's secret store —
// it is NOT bundled in this app.
//
// This file used to hold the key in plaintext. That made it
// extractable via `strings` / `class-dump` from any installed .ipa.
// The migration removed both that key AND every code path that could
// have used it: ProxyMode no longer has a `.direct` case, so even if
// someone re-added a key to `openAIKey` below, no call site would
// pick it up.
//
// A previous shared bearer header was also retired. The only credential
// the app holds now is a per-device App Attest assertion produced at
// request time by `AppAttestService` (see `Tonecast/AppAttestService.swift`).
//
// The `Secrets` enum is preserved as an empty placeholder so future
// non-OpenAI credentials (if any) have a stable home.

enum Secrets {
    /// Deprecated. Kept as an empty string for source-compatibility —
    /// any reference to it should be removed.
    static let openAIKey: String = ""
}
