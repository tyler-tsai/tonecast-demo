import Foundation

/// Shared URLSession configured with explicit timeouts.
///
/// Why this exists: `URLSession.shared` defaults to
///   • `timeoutIntervalForRequest = 60s`   (per-data-stall)
///   • `timeoutIntervalForResource = 7 DAYS` (total per task)
///
/// The 7-day resource timeout means a half-broken connection where data
/// trickles in below the per-stall threshold can hang the recording
/// service in `.processing` essentially forever — surfacing as a silent
/// error to the user (state never reaches `.error`, no retry chip).
///
/// We tighten both ceilings so a hung connection bubbles up as an
/// NSError, the `processAudio` catch block fires, retry context is
/// stashed, and the keyboard shows an error + retry chip.
enum NetworkSession {
    /// Generous enough for typical 30-second recordings + multipart upload
    /// + Whisper transcription (~5-15s end-to-end), tight enough to detect
    /// dead connections within roughly a minute.
    static let shared: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60   // per-stall budget
        config.timeoutIntervalForResource = 120 // total ceiling per task
        config.waitsForConnectivity = false     // fail fast on no network
        return URLSession(configuration: config)
    }()
}
