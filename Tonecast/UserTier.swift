import Foundation

/// Tonecast API authorization tier — drives the per-day request cap the
/// proxy enforces (Free = 200/day, Plus = 1000/day).
///
/// **The proxy is the authority on tier.** This enum is a read-only
/// local cache for UI purposes only — the paywall checks it to decide
/// whether to show subscribe, and the Subscription section reflects it.
/// The proxy looks tier up in its own KV record keyed by the App Attest
/// keyId; it ignores any tier hint the client sends. See
/// `IAPService.syncWithServer()` for the write path — `IAPService` is
/// the only writer of this UserDefaults key.
enum UserTier: String, Sendable, CaseIterable {
    case free
    case plus

    fileprivate static let key = "tonecast.userTier.v1"

    /// Current cached tier. Reflects what `IAPService` most recently
    /// observed from `Transaction.currentEntitlements` + the proxy's
    /// `/v1/iap/verify` response. Defaults to `.free` when no cache
    /// entry exists (first launch).
    static var current: UserTier {
        let raw = UserDefaults.standard.string(forKey: key) ?? UserTier.free.rawValue
        return UserTier(rawValue: raw) ?? .free
    }

    /// Writer used exclusively by `IAPService`. Kept internal so callers
    /// outside the IAP layer can't fake an upgrade by writing to the
    /// cache; the proxy would catch it on the next request anyway, but
    /// the discipline avoids subtle UI/tier divergence.
    static func _write(_ tier: UserTier) {
        UserDefaults.standard.set(tier.rawValue, forKey: key)
    }
}
