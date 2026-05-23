import SwiftUI
import UIKit

@main
struct TonecastApp: App {
    @State private var showRecording = false   // kept as @Binding stub for ContentView signature
    @Environment(\.scenePhase) private var scenePhase

    init() {
        SessionWarmer.warm()

        // App Attest: kick off first-launch attestation in the background.
        // Tonecast is proxy-only and the proxy no longer accepts the
        // legacy bearer fallback, so without an attested key every
        // Whisper/GPT call would 401. AppAttestService
        // is an actor; sign(_:) awaits setupTask, so any request fired
        // before attestation completes queues safely behind it.
        //
        // Caveat: Simulator can't attest (DCAppAttestService.isSupported
        // is false there), so voice/transcribe + refine flows won't work
        // in Simulator. Use a real device for end-to-end testing.
        let proxyMode = ProxyMode()
        Task.detached {
            await AppAttestService.shared.configure(mode: .enabled(
                proxyBaseURL: proxyMode.baseURL,
                appId: ProxyEndpointDefaults.appId
            ))
            await AppAttestService.shared.setUpIfNeeded()
        }

        // IAP. StoreKit 2 owns the local entitlement state; IAPService
        // syncs it to the proxy (which is authority on tier — see
        // UserTier.swift). configure() starts a long-lived
        // Transaction.updates listener internally so renewals / refunds
        // / family-sharing events flow through /v1/iap/verify without
        // UI involvement.
        Task.detached {
            await IAPService.shared.configure(mode: .enabled(
                proxyBaseURL: proxyMode.baseURL,
                appId: ProxyEndpointDefaults.appId,
                signer: AppAttestService.shared
            ))
            // Warm StoreKit BEFORE the user can tap "Upgrade to Plus".
            // First call to Product.products / Storefront.current on a
            // sandbox-signed-in device triggers an interactive sandbox
            // account confirmation prompt that conflicts with SwiftUI
            // sheet presentation — the paywall flashes open then
            // closes. warmUp() is idempotent so SubscriptionSection's
            // button can also call it on tap as a defence-in-depth.
            await IAPService.shared.warmUp()
            // Brief delay so first sync doesn't race App Attest setup;
            // otherwise /v1/iap/verify will 401 missing-attest until
            // attestation completes.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await IAPService.shared.syncWithServer()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(showRecording: $showRecording)
                .onOpenURL { url in
                    handle(url: url)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    NSLog("[Tonecast/main] scenePhase changed to %@", String(describing: newPhase))
                }
        }
    }

    private func handle(url: URL) {
        NSLog("[Tonecast/main] handle URL: %@", url.absoluteString)
        guard url.scheme == "tonecast" else { return }

        switch url.host {
        case "record-start":
            // Keyboard tapped mic with no active Flow Session. We only want
            // to *activate* the session here — not record. The user will be
            // bounced back to the keyboard and can tap the mic again to
            // actually record (which now goes through the no-app-jump path
            // because the session is alive).
            let params = Self.queryParams(url)
            let tone = Tone(rawValue: Int(params["tone"] ?? "") ?? 2) ?? .casual
            let translate = TranslateMode(rawValue: Int(params["translate"] ?? "") ?? 0) ?? .off
            Task { @MainActor in
                RecordingService.shared.startFlowSession(tone: tone, translate: translate)
                // Cancel (discard, no Whisper/GPT) the capture that
                // startFlowSession kicks off — keep the session alive but
                // do not record. User returns to keyboard and taps mic
                // again to actually record (no app jump this time).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    SharedDefaults.setCancelRequested(true)
                }
                Self.suspendApp(delay: 0.15)
            }

        default:
            break
        }
    }

    private static func queryParams(_ url: URL) -> [String: String] {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .reduce(into: [:]) { $0[$1.name] = $1.value } ?? [:]
    }

    private static func suspendApp(delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            NSLog("[Tonecast/main] suspendApp dispatching")
            UIApplication.shared.perform(NSSelectorFromString("suspend"))
        }
    }
}
