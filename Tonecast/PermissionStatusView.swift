import SwiftUI
import AVFoundation
import UIKit

/// Live status card for the three permissions Tonecast needs:
///
///   1. Microphone — granted via AVAudioApplication.requestRecordPermission.
///   2. Tonecast keyboard added — detected via the extension writing a
///      heartbeat to SharedDefaults on viewDidLoad / viewWillAppear.
///   3. Full Access — same heartbeat carries `hasFullAccess`.
///
/// When all three are green, the card collapses to a single satisfied
/// row. When anything's missing it stays expanded with a CTA per row
/// (request permission, or open Settings → Tonecast).
///
/// Why this exists at all: before this card, the user would tap
/// "Start Flow Session" and get either silence (mic denied) or a
/// surprise system prompt mid-tap. The keyboard rows in particular
/// were invisible — the only way to learn "is my keyboard installed
/// and does it have Full Access" was to try it.
struct PermissionStatusView: View {
    /// AVAudioApplication.recordPermission is iOS 17+. Project deployment
    /// target is iOS 17, so we use it directly rather than the older
    /// AVAudioSession.sharedInstance().recordPermission.
    @State private var micPermission: AVAudioApplication.recordPermission = AVAudioApplication.shared.recordPermission
    @State private var keyboardLastSeen: Date? = SharedDefaults.keyboardLastSeen()
    @State private var keyboardFullAccess: Bool = SharedDefaults.keyboardHasFullAccess()

    /// Heartbeats older than this mean the user probably removed or
    /// disabled the Tonecast keyboard in Settings — we no longer trust
    /// the cached `hasFullAccess` value either, since the extension
    /// can't update it if it isn't being loaded.
    private static let keyboardStaleAfter: TimeInterval = 24 * 60 * 60 // 24 h

    /// We can only learn the keyboard's state when the extension loads
    /// (its viewDidLoad writes a heartbeat). Until then we don't know
    /// — important distinction from "definitely missing", because a
    /// fresh app install always lands in the unknown bucket until the
    /// user switches to the Tonecast keyboard at least once.
    enum KeyboardCheck {
        case confirmedFresh(hasFullAccess: Bool)
        case confirmedStale(hasFullAccess: Bool)
        case unknown
    }

    private var keyboardCheck: KeyboardCheck {
        guard let seen = keyboardLastSeen else { return .unknown }
        let age = Date().timeIntervalSince(seen)
        if age < Self.keyboardStaleAfter {
            return .confirmedFresh(hasFullAccess: keyboardFullAccess)
        }
        return .confirmedStale(hasFullAccess: keyboardFullAccess)
    }

    /// "Known good" — mic granted AND extension recently reported with
    /// Full Access ON. The card collapses to a single line when true.
    private var allGreen: Bool {
        if case .confirmedFresh(true) = keyboardCheck, micPermission == .granted {
            return true
        }
        return false
    }

    /// Something is definitively wrong (mic denied, or extension reports
    /// without Full Access). Triggers the alarming orange "Finish setup"
    /// header — distinct from the gentler blue "Verify" header used
    /// when state is merely unknown.
    private var anyKnownBad: Bool {
        if micPermission == .denied { return true }
        if case .confirmedFresh(false) = keyboardCheck { return true }
        if case .confirmedStale(false) = keyboardCheck { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: headerIcon)
                    .foregroundStyle(headerTint)
                Text(headerTitle)
                    .font(.headline)
                    .foregroundStyle(allGreen ? Color.green : Color.primary)
                Spacer()
            }

            if !allGreen {
                PermissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    status: micStatusLabel,
                    state: micState,
                    cta: micCTA,
                    action: micAction
                )

                PermissionRow(
                    icon: "keyboard",
                    title: "Tonecast keyboard added",
                    status: keyboardRowStatus,
                    state: keyboardRowState,
                    cta: keyboardRowCTA,
                    action: keyboardRowCTA == nil ? nil : openKeyboardSettings
                )

                PermissionRow(
                    icon: "lock.open.fill",
                    title: "Full Access",
                    status: fullAccessRowStatus,
                    state: fullAccessRowState,
                    cta: fullAccessRowCTA,
                    action: fullAccessRowCTA == nil ? nil : openKeyboardSettings
                )

                Text(footerHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(cardFillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(cardStrokeColor, lineWidth: 1)
        )
        .onAppear(perform: refresh)
        // Poll while visible — keyboard heartbeat is the only signal
        // we can't observe via NotificationCenter, so we re-read it
        // every second the card is on screen.
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            refresh()
        }
        .animation(.easeInOut(duration: 0.25), value: allGreen)
    }

    // MARK: - State derivation

    private var micState: PermissionRow.State {
        switch micPermission {
        case .granted:     return .ok
        case .denied:      return .denied
        case .undetermined: return .missing
        @unknown default:  return .missing
        }
    }

    private var micStatusLabel: String {
        switch micPermission {
        case .granted:      return "Allowed"
        case .denied:       return "Denied"
        case .undetermined: return "Not requested yet"
        @unknown default:   return "Unknown"
        }
    }

    private var micCTA: String? {
        switch micPermission {
        case .granted:      return nil
        case .denied:       return "Open Settings"
        case .undetermined: return "Allow"
        @unknown default:   return nil
        }
    }

    private var micAction: (() -> Void)? {
        switch micPermission {
        case .granted:
            return nil
        case .undetermined:
            return requestMicPermission
        case .denied:
            return openAppSettings
        @unknown default:
            return nil
        }
    }

    // MARK: - Header

    private var headerTitle: String {
        if allGreen { return "Permissions OK" }
        if anyKnownBad { return "Finish setup" }
        return "Verify keyboard"
    }

    private var headerIcon: String {
        if allGreen { return "checkmark.seal.fill" }
        if anyKnownBad { return "exclamationmark.triangle.fill" }
        return "info.circle.fill"
    }

    private var headerTint: Color {
        if allGreen { return .green }
        if anyKnownBad { return .orange }
        return .blue
    }

    private var cardFillColor: Color {
        if allGreen { return .green.opacity(0.08) }
        if anyKnownBad { return .orange.opacity(0.10) }
        return .blue.opacity(0.08)
    }

    private var cardStrokeColor: Color {
        if allGreen { return .green.opacity(0.3) }
        if anyKnownBad { return .orange.opacity(0.3) }
        return .blue.opacity(0.25)
    }

    private var footerHint: String {
        switch keyboardCheck {
        case .confirmedFresh(true):
            return "" // shouldn't render — allGreen short-circuits
        case .confirmedFresh(false), .confirmedStale(false):
            return "Settings → General → Keyboard → Keyboards → Tonecast → Allow Full Access"
        case .confirmedStale(true):
            return "Tonecast keyboard hasn't been used in over 24 hours — confirm it's still installed."
        case .unknown:
            return "Open any text field, switch to the Tonecast keyboard once, then come back — it'll auto-verify."
        }
    }

    // MARK: - Keyboard row

    private var keyboardRowStatus: String {
        switch keyboardCheck {
        case .confirmedFresh:  return "Added"
        case .confirmedStale:  return "Added (not used recently)"
        case .unknown:         return "Switch to Tonecast keyboard to verify"
        }
    }

    private var keyboardRowState: PermissionRow.State {
        switch keyboardCheck {
        case .confirmedFresh, .confirmedStale: return .ok
        case .unknown:                          return .unknown
        }
    }

    /// In `.unknown` and `.confirmedStale` we still offer Open Settings —
    /// even though the surest way to verify is "switch to the keyboard
    /// once", the user might want to inspect / re-add the keyboard
    /// without leaving the app first. Only suppress the CTA when the
    /// row is definitively green.
    private var keyboardRowCTA: String? {
        switch keyboardCheck {
        case .confirmedFresh:           return nil
        case .confirmedStale, .unknown: return "Open Settings"
        }
    }

    // MARK: - Full Access row

    private var fullAccessRowStatus: String {
        switch keyboardCheck {
        case .confirmedFresh(true), .confirmedStale(true):   return "Allowed"
        case .confirmedFresh(false), .confirmedStale(false): return "Disabled"
        case .unknown:                                        return "—"
        }
    }

    private var fullAccessRowState: PermissionRow.State {
        switch keyboardCheck {
        case .confirmedFresh(true), .confirmedStale(true):   return .ok
        case .confirmedFresh(false), .confirmedStale(false): return .missing
        case .unknown:                                        return .unknown
        }
    }

    private var fullAccessRowCTA: String? {
        switch keyboardCheck {
        case .confirmedFresh(false), .confirmedStale(false): return "Open Settings"
        case .confirmedFresh(true), .confirmedStale(true):   return nil
        // In .unknown we don't know whether Full Access is on, but a
        // jump to Settings is still useful — the user can flip it
        // there and the heartbeat will catch up on next keyboard use.
        case .unknown:                                        return "Open Settings"
        }
    }

    // MARK: - Actions

    private func refresh() {
        micPermission = AVAudioApplication.shared.recordPermission
        keyboardLastSeen = SharedDefaults.keyboardLastSeen()
        keyboardFullAccess = SharedDefaults.keyboardHasFullAccess()
    }

    private func requestMicPermission() {
        AVAudioApplication.requestRecordPermission { _ in
            DispatchQueue.main.async { refresh() }
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// `UIApplication.openSettingsURLString` deep-links into the app's
    /// own Settings page; from there the user one-taps into Keyboards.
    /// iOS doesn't expose a public deep link to "Settings → General →
    /// Keyboard → Keyboards" directly — the `prefs:` URL scheme that
    /// some third-party apps use is private API and will fail review.
    /// So we open the app's Settings and instruct via the caption text.
    private func openKeyboardSettings() {
        openAppSettings()
    }
}

// MARK: - Row component

private struct PermissionRow: View {
    enum State {
        case ok
        case missing
        case denied
        /// We don't have enough information to determine the row's
        /// state — used for keyboard / Full Access rows when we've
        /// never received a heartbeat from the extension. Visually
        /// neutral (blue question-mark) rather than alarming red.
        case unknown
    }

    let icon: String
    let title: String
    let status: String
    let state: State
    let cta: String?
    let action: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(iconColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let cta, let action {
                Button(action: action) {
                    Text(cta)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(Color.accentColor.opacity(0.15))
                        )
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            } else if state == .ok {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
            } else if state == .unknown {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(Color.blue.opacity(0.7))
            }
        }
    }

    private var iconColor: Color {
        switch state {
        case .ok:      return .green
        case .missing: return .orange
        case .denied:  return .red
        case .unknown: return .blue.opacity(0.7)
        }
    }
}

#Preview {
    PermissionStatusView()
        .padding()
}
