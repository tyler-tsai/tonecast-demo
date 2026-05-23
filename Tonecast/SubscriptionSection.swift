import SwiftUI
import StoreKit

/// Subscription status section for Settings. Read-only — purchase
/// flows live in PaywallView. Shows:
///   - Free tier → "Free", with an "Upgrade to Plus" button
///   - Plus tier → "Plus" + expiry date + "Manage Subscription" button
///     (deep-links to the App Store account → subscriptions screen)
///
/// Tier is read from the local cache (UserDefaults), updated by
/// IAPService whenever Transaction.updates fires or syncWithServer
/// runs. The proxy is still the authority — this view reflects the
/// most recent local view.
///
/// `showingPaywall` is owned by the parent (SettingsView). Sheet
/// modifier lives there too — declaring it inside this Section was
/// the original cause of the first-tap-flashes bug (mixing sheet
/// attachment levels in a view tree that already has many sibling
/// sheets confuses SwiftUI's modal management).
struct SubscriptionSection: View {
    @Binding var showingPaywall: Bool

    @SwiftUI.State private var showingManageSubscriptions: Bool = false
    @SwiftUI.State private var expiryDate: Date? = nil
    @SwiftUI.State private var currentTier: UserTier = UserTier.current
    @SwiftUI.State private var isUpgradeButtonBusy: Bool = false

    var body: some View {
        Section {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Plan")
                        Text(currentTier == .plus ? "Tonecast Plus" : "Free")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: currentTier == .plus ? "checkmark.seal.fill" : "person.fill")
                        .foregroundStyle(currentTier == .plus ? Color.green : Color.secondary)
                }
                Spacer()
                Text(currentTier.rawValue.capitalized)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(currentTier == .plus
                            ? Color.green.opacity(0.18)
                            : Color.secondary.opacity(0.18))
                    )
                    .foregroundStyle(currentTier == .plus ? .green : .secondary)
            }

            if currentTier == .plus, let expiry = expiryDate {
                HStack {
                    Image(systemName: "calendar")
                        .foregroundStyle(.secondary)
                    Text("Renews / expires")
                    Spacer()
                    Text(expiry.formatted(date: .abbreviated, time: .omitted))
                        .foregroundStyle(.secondary)
                }
            }

            if currentTier == .plus {
                Button {
                    showingManageSubscriptions = true
                } label: {
                    Label("Manage Subscription", systemImage: "person.crop.circle.badge.checkmark")
                }
            } else {
                Button {
                    // Warm StoreKit BEFORE presenting the sheet. The very
                    // first call to Product.products / Storefront.current
                    // on a sandbox-signed-in device triggers an iOS-owned
                    // confirmation dialog that, if it fires during sheet
                    // presentation, causes the paywall to flash open and
                    // immediately close. `warmUp()` is idempotent: instant
                    // after first success, awaits in-flight on subsequent
                    // taps. Users see at most a single brief delay on the
                    // very first cold-start tap.
                    isUpgradeButtonBusy = true
                    Task {
                        await IAPService.shared.warmUp()
                        isUpgradeButtonBusy = false
                        showingPaywall = true
                    }
                } label: {
                    HStack {
                        Label("Upgrade to Plus", systemImage: "sparkles")
                            .foregroundStyle(.tint)
                        Spacer()
                        if isUpgradeButtonBusy {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(isUpgradeButtonBusy)
            }
        } header: {
            Text("Subscription")
        } footer: {
            Text(currentTier == .plus
                 ? "Plus = 1,000 keyboard requests/day. Tap Manage to change plan or cancel."
                 : "Free = 200 requests/day. Plus lifts the cap for heavy dictation sessions.")
                .font(.caption)
        }
        // Paywall sheet is hosted by the parent (SettingsView). Declaring
        // it here was the original cause of the first-tap-flashes bug.
        .manageSubscriptionsSheet(isPresented: $showingManageSubscriptions)
        .task(id: "subscription-section-refresh") {
            await refresh()
        }
        // Refresh when the paywall closes — covers the case where the
        // user just completed a purchase and IAPService updated the
        // local tier cache. NOT a broad UserDefaults observer: that
        // approach fired on every prefs write in the whole app (tone
        // defaults, hold-to-talk toggle, vocab edits…) and re-rendered
        // this section during sheet presentation, which is one of two
        // causes of the "first tap flashes" symptom.
        .onChange(of: showingPaywall) { _, newValue in
            if !newValue { currentTier = UserTier.current }
        }
    }

    @MainActor
    private func refresh() async {
        currentTier = UserTier.current
        // Read expiry from StoreKit directly — the local UserDefaults
        // cache only stores the tier, not the expiry. currentEntitlements
        // is a local cache so this is cheap.
        var latest: Date? = nil
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard IAPService.ProductIdentifiers.all.contains(transaction.productID) else { continue }
            if transaction.revocationDate != nil { continue }
            if let expiry = transaction.expirationDate {
                if latest == nil || expiry > latest! { latest = expiry }
            }
        }
        expiryDate = latest
    }
}
