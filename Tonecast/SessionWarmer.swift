import Foundation
import AVFoundation

/// Wispr Flow / Typeless style "Flow Session" warm-up.
///
/// iOS forbids keyboard extensions from creating new audio sessions,
/// but if the *containing app* has an active audio session (with the
/// `audio` UIBackgroundMode), the extension can sometimes piggyback on
/// it and capture audio without hitting `!rec` (cannotStartRecording).
///
/// This singleton is invoked from `TonecastApp.init()` so that the
/// audio session is primed before the user ever leaves the main app.
/// The session is left active deliberately — we never call setActive(false)
/// — so the keyboard can use it while the main app sits in background.
enum SessionWarmer {
    static func warm() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord,
                                    mode: .default,
                                    options: [.allowBluetooth, .defaultToSpeaker, .mixWithOthers])
            try session.setActive(true)
            NSLog("[Tonecast/main] session warmed — rate=%.0f input=%@",
                  session.sampleRate,
                  session.isInputAvailable ? "YES" : "NO")
        } catch {
            NSLog("[Tonecast/main] session warm failed: %@", error.localizedDescription)
        }
    }
}
