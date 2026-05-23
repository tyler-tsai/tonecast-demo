import Foundation

enum FlowSessionState: String {
    case idle
    case recording
    case processing
    case done
    case error
}

/// Cross-process state for the Wispr-style Flow Session pattern.
/// Main app (background recorder) writes; keyboard extension polls and reads.
/// All persisted in the shared App Group UserDefaults suite.
enum SharedDefaults {
    static let appGroup = "group.com.example.tonecast"

    // Keys
    private static let kSessionState = "tc.session_state"
    private static let kSessionStateTimestamp = "tc.session_state_ts"
    private static let kResultText = "tc.result_text"
    private static let kResultTone = "tc.result_tone"
    private static let kResultOriginal = "tc.result_original"  // raw Whisper output, before GPT
    private static let kCustomTempPrefix = "tc.tone_temperature."  // tc.tone_temperature.<rawValue> → Double
    private static let kErrorMessage = "tc.error_message"
    private static let kStopRequested = "tc.stop_requested"
    private static let kCancelRequested = "tc.cancel_requested"
    // Typeless-style Flow Session signaling
    private static let kFlowSessionActive = "tc.flow_session_active"
    private static let kFlowHeartbeat = "tc.flow_heartbeat"   // timestamp
    private static let kFlowSessionStartedAt = "tc.flow_started_at"  // timestamp
    private static let kStartRequested = "tc.start_requested"
    private static let kRequestedTone = "tc.requested_tone"
    private static let kRequestedTranslate = "tc.requested_translate"

    // User-configurable
    private static let kFlowDurationMinutes = "tc.flow_duration_minutes"
    private static let kDefaultTone = "tc.default_tone"
    private static let kDefaultTranslate = "tc.default_translate"
    private static let kCustomStyleGuidePrefix = "tc.tone_style_guide."
    private static let kWhisperLanguage = "tc.whisper_language"   // "" = auto / "zh" / "en"
    private static let kPersonalVocabulary = "tc.personal_vocab"  // comma/newline-separated terms
    private static let kHasSeenSetupGuide = "tc.has_seen_setup_guide"

    // Keyboard heartbeat — extension writes on every viewDidLoad / viewWillAppear
    // so the main app can show live "keyboard installed + Full Access ON" status
    // on the home screen. Without these, the user can only learn the keyboard's
    // state by typing somewhere and watching — which is what we're trying to fix.
    private static let kKeyboardLastSeen = "tc.keyboard_last_seen"        // TimeInterval epoch
    private static let kKeyboardHasFullAccess = "tc.keyboard_full_access" // Bool

    // Speak-to-Edit: keyboard tells main app to treat the next recording as
    // a voice command targeting this selected text, not a fresh dictation.
    private static let kEditModeText = "tc.edit_mode_text"
    private static let kEditModeActive = "tc.edit_mode_active"

    // Retry — when Whisper or GPT fails for a fresh recording, main app
    // keeps the audio file on disk and stashes the original tone/translate
    // context here so the keyboard can offer a Retry chip. Cleared on
    // retry success / new recording / Send.
    private static let kRetryAvailable    = "tc.retry_available"
    private static let kRetryFilePath     = "tc.retry_file_path"
    private static let kRetryTone         = "tc.retry_tone"
    private static let kRetryTranslate    = "tc.retry_translate"
    private static let kRetryRequested    = "tc.retry_requested"

    // Quick-action refine: keyboard tells main app to transform a piece of
    // text (typically the most-recently-inserted result) via GPT — no new
    // recording needed. Result is written back to a separate slot so the
    // keyboard knows to replace rather than append.
    private static let kRefineRequested  = "tc.refine_requested"
    private static let kRefineAction     = "tc.refine_action"      // "shorter" | "longer" | "polish" | "tone"
    private static let kRefineParam      = "tc.refine_param"       // optional — for "tone": target tone rawValue as string
    private static let kRefineInputText  = "tc.refine_input_text"
    private static let kRefineSourceTone     = "tc.refine_source_tone"
    private static let kRefineSourceTranslate = "tc.refine_source_translate"
    private static let kRefineResultText = "tc.refine_result_text"
    private static let kRefineResultReady = "tc.refine_result_ready"

    // Live audio amplitude IPC (main app writes during recording, keyboard reads for waveform)
    private static let kCurrentAmplitude = "tc.current_amplitude"   // 0.0 - 1.0
    private static let kAmplitudeTimestamp = "tc.amplitude_ts"

    // Recording history (most-recent first, capped to historyLimit)
    private static let kHistoryEntries = "tc.history_entries"
    static let historyLimit = 20

    // Recording trigger style (tap-toggle vs hold-to-talk)
    private static let kHoldToTalkMode = "tc.hold_to_talk_mode"

    /// How fresh a heartbeat needs to be for the keyboard to trust that
    /// the main app is still alive in the background.
    private static let heartbeatStaleThreshold: TimeInterval = 3.0

    static var store: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    // MARK: - Session state

    static func setSessionState(_ state: FlowSessionState) {
        store?.set(state.rawValue, forKey: kSessionState)
        store?.set(Date().timeIntervalSince1970, forKey: kSessionStateTimestamp)
    }

    static func sessionState() -> FlowSessionState {
        let raw = store?.string(forKey: kSessionState) ?? FlowSessionState.idle.rawValue
        return FlowSessionState(rawValue: raw) ?? .idle
    }

    static func sessionStateAge() -> TimeInterval {
        let ts = store?.double(forKey: kSessionStateTimestamp) ?? 0
        return Date().timeIntervalSince1970 - ts
    }

    // MARK: - Result handoff

    static func setResult(_ text: String, tone: String, original: String? = nil) {
        store?.set(text, forKey: kResultText)
        store?.set(tone, forKey: kResultTone)
        if let original = original, !original.isEmpty {
            store?.set(original, forKey: kResultOriginal)
        } else {
            store?.removeObject(forKey: kResultOriginal)
        }
        store?.removeObject(forKey: kErrorMessage)
        setSessionState(.done)
    }

    static func peekResult() -> (text: String, tone: String, original: String?)? {
        guard let text = store?.string(forKey: kResultText), !text.isEmpty else { return nil }
        let tone = store?.string(forKey: kResultTone) ?? ""
        let original = store?.string(forKey: kResultOriginal)
        return (text, tone, (original?.isEmpty == false) ? original : nil)
    }

    static func setError(_ message: String) {
        store?.set(message, forKey: kErrorMessage)
        setSessionState(.error)
    }

    static func peekError() -> String? {
        store?.string(forKey: kErrorMessage)
    }

    static func clearError() {
        store?.removeObject(forKey: kErrorMessage)
    }

    // MARK: - Stop request (keyboard → main app, no URL needed)

    static func setStopRequested(_ value: Bool) {
        store?.set(value, forKey: kStopRequested)
    }

    static func stopRequested() -> Bool {
        store?.bool(forKey: kStopRequested) ?? false
    }

    static func setCancelRequested(_ value: Bool) {
        store?.set(value, forKey: kCancelRequested)
    }

    static func cancelRequested() -> Bool {
        store?.bool(forKey: kCancelRequested) ?? false
    }

    // MARK: - Flow Session (Typeless-style always-on)

    static func setFlowSessionActive(_ value: Bool) {
        store?.set(value, forKey: kFlowSessionActive)
        if value {
            recordFlowHeartbeat()
            store?.set(Date().timeIntervalSince1970, forKey: kFlowSessionStartedAt)
        } else {
            store?.removeObject(forKey: kFlowHeartbeat)
            store?.removeObject(forKey: kFlowSessionStartedAt)
        }
    }

    /// Seconds elapsed since the active Flow Session started. Nil if no session.
    static func flowSessionElapsed() -> TimeInterval? {
        guard flowSessionActive() else { return nil }
        let started = store?.double(forKey: kFlowSessionStartedAt) ?? 0
        if started == 0 { return nil }
        return Date().timeIntervalSince1970 - started
    }

    /// Seconds remaining until the Flow Session auto-expires, based on the
    /// user's chosen duration. Nil if no session.
    static func flowSessionRemaining() -> TimeInterval? {
        guard let elapsed = flowSessionElapsed() else { return nil }
        let total = TimeInterval(flowDurationMinutes() * 60)
        return max(0, total - elapsed)
    }

    /// Called by the main app's flag-poll timer every tick to prove it's
    /// still alive. The keyboard ignores stale heartbeats and treats the
    /// Flow Session as expired — forcing a URL re-launch.
    static func recordFlowHeartbeat() {
        store?.set(Date().timeIntervalSince1970, forKey: kFlowHeartbeat)
    }

    static func flowSessionActive() -> Bool {
        guard store?.bool(forKey: kFlowSessionActive) == true else { return false }
        let heartbeat = store?.double(forKey: kFlowHeartbeat) ?? 0
        let age = Date().timeIntervalSince1970 - heartbeat
        if age > heartbeatStaleThreshold {
            // Heartbeat stale → main app probably dead. Clear so the next
            // tap takes the URL-launch path again.
            store?.set(false, forKey: kFlowSessionActive)
            return false
        }
        return true
    }

    static func setStartRequested(tone: Int, translate: Int) {
        store?.set(tone, forKey: kRequestedTone)
        store?.set(translate, forKey: kRequestedTranslate)
        store?.set(true, forKey: kStartRequested)
    }

    static func consumeStartRequest() -> (tone: Int, translate: Int)? {
        guard store?.bool(forKey: kStartRequested) == true else { return nil }
        let tone = store?.integer(forKey: kRequestedTone) ?? 2
        let translate = store?.integer(forKey: kRequestedTranslate) ?? 0
        store?.set(false, forKey: kStartRequested)
        return (tone, translate)
    }

    // MARK: - Refine (quick-action)

    struct RefineRequest {
        let action: String
        let param: String?
        let inputText: String
        let sourceTone: Int
        let sourceTranslate: Int
    }

    static func setRefineRequest(action: String,
                                  param: String?,
                                  inputText: String,
                                  sourceTone: Int,
                                  sourceTranslate: Int) {
        store?.set(action, forKey: kRefineAction)
        store?.set(param, forKey: kRefineParam)
        store?.set(inputText, forKey: kRefineInputText)
        store?.set(sourceTone, forKey: kRefineSourceTone)
        store?.set(sourceTranslate, forKey: kRefineSourceTranslate)
        // Clear any stale prior result before flagging the new request.
        store?.removeObject(forKey: kRefineResultText)
        store?.set(false, forKey: kRefineResultReady)
        store?.set(true, forKey: kRefineRequested)
    }

    static func consumeRefineRequest() -> RefineRequest? {
        guard store?.bool(forKey: kRefineRequested) == true else { return nil }
        guard
            let action = store?.string(forKey: kRefineAction),
            let inputText = store?.string(forKey: kRefineInputText),
            !inputText.isEmpty
        else {
            store?.set(false, forKey: kRefineRequested)
            return nil
        }
        let param = store?.string(forKey: kRefineParam)
        let sourceTone = store?.integer(forKey: kRefineSourceTone) ?? 2
        let sourceTranslate = store?.integer(forKey: kRefineSourceTranslate) ?? 0
        store?.set(false, forKey: kRefineRequested)
        return RefineRequest(action: action,
                              param: param,
                              inputText: inputText,
                              sourceTone: sourceTone,
                              sourceTranslate: sourceTranslate)
    }

    static func setRefineResult(_ text: String) {
        store?.set(text, forKey: kRefineResultText)
        store?.set(true, forKey: kRefineResultReady)
    }

    static func consumeRefineResult() -> String? {
        guard store?.bool(forKey: kRefineResultReady) == true else { return nil }
        let text = store?.string(forKey: kRefineResultText)
        store?.set(false, forKey: kRefineResultReady)
        store?.removeObject(forKey: kRefineResultText)
        return (text?.isEmpty == false) ? text : nil
    }

    // MARK: - Retry (after Whisper/GPT failure)

    struct RetryContext {
        let filePath: String
        let tone: Int
        let translate: Int
    }

    static func setRetryAvailable(filePath: String, tone: Int, translate: Int) {
        store?.set(filePath, forKey: kRetryFilePath)
        store?.set(tone, forKey: kRetryTone)
        store?.set(translate, forKey: kRetryTranslate)
        store?.set(true, forKey: kRetryAvailable)
    }

    static func peekRetryContext() -> RetryContext? {
        guard store?.bool(forKey: kRetryAvailable) == true else { return nil }
        guard let path = store?.string(forKey: kRetryFilePath), !path.isEmpty else { return nil }
        let tone = store?.integer(forKey: kRetryTone) ?? 2
        let translate = store?.integer(forKey: kRetryTranslate) ?? 0
        return RetryContext(filePath: path, tone: tone, translate: translate)
    }

    static func setRetryRequested(_ requested: Bool) {
        store?.set(requested, forKey: kRetryRequested)
    }

    static func consumeRetryRequest() -> RetryContext? {
        guard store?.bool(forKey: kRetryRequested) == true else { return nil }
        store?.set(false, forKey: kRetryRequested)
        return peekRetryContext()
    }

    static func clearRetry() {
        store?.set(false, forKey: kRetryAvailable)
        store?.set(false, forKey: kRetryRequested)
        store?.removeObject(forKey: kRetryFilePath)
    }

    // MARK: - Flow Session time remaining

    /// Seconds until the active Flow Session expires, or nil if no session
    /// is active. Used by the keyboard to show a "Session ending soon"
    /// warning when the remaining time is short.
    static func flowSessionTimeRemaining() -> TimeInterval? {
        guard flowSessionActive() else { return nil }
        let startedAt = store?.double(forKey: kFlowSessionStartedAt) ?? 0
        guard startedAt > 0 else { return nil }
        let duration = TimeInterval(flowDurationMinutes()) * 60.0
        let elapsed = Date().timeIntervalSince1970 - startedAt
        return max(0, duration - elapsed)
    }

    // MARK: - User preferences

    /// Allowed values: 5, 15, 30, 60. Defaults to 15.
    static func flowDurationMinutes() -> Int {
        let raw = store?.integer(forKey: kFlowDurationMinutes) ?? 0
        return raw > 0 ? raw : 15
    }

    static func setFlowDurationMinutes(_ minutes: Int) {
        store?.set(minutes, forKey: kFlowDurationMinutes)
    }

    static func defaultTone() -> Int {
        let raw = store?.object(forKey: kDefaultTone) as? Int
        return raw ?? 2 // casual
    }

    static func setDefaultTone(_ tone: Int) {
        store?.set(tone, forKey: kDefaultTone)
    }

    static func defaultTranslate() -> Int {
        let raw = store?.object(forKey: kDefaultTranslate) as? Int
        return raw ?? 0 // off
    }

    static func setDefaultTranslate(_ translate: Int) {
        store?.set(translate, forKey: kDefaultTranslate)
    }

    /// User-customized tone style guide (returns nil if user hasn't set one,
    /// meaning Tone.swift's defaultStyleGuide is in effect).
    static func customStyleGuide(for tone: Tone) -> String? {
        let raw = store?.string(forKey: kCustomStyleGuidePrefix + String(tone.rawValue))
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    static func setCustomStyleGuide(_ value: String?, for tone: Tone) {
        let key = kCustomStyleGuidePrefix + String(tone.rawValue)
        if let value = value, !value.isEmpty {
            store?.set(value, forKey: key)
        } else {
            store?.removeObject(forKey: key)
        }
    }

    /// User-configured creativity temperature for a tone. nil means use the
    /// factory default (currently 0.4). Range 0.0–1.0. Lower = closer to
    /// input wording; higher = more variation.
    static func customTemperature(for tone: Tone) -> Double? {
        let key = kCustomTempPrefix + String(tone.rawValue)
        // Sentinel: -1 means "explicitly cleared", treat as nil.
        guard let raw = store?.object(forKey: key) as? Double else { return nil }
        return raw >= 0 ? raw : nil
    }

    static func setCustomTemperature(_ value: Double?, for tone: Tone) {
        let key = kCustomTempPrefix + String(tone.rawValue)
        if let value = value {
            store?.set(value, forKey: key)
        } else {
            store?.removeObject(forKey: key)
        }
    }

    // MARK: - Live amplitude (recording waveform)

    static func setCurrentAmplitude(_ amp: Float) {
        store?.set(amp, forKey: kCurrentAmplitude)
        store?.set(Date().timeIntervalSince1970, forKey: kAmplitudeTimestamp)
    }

    /// Returns the most recent amplitude if it's < 0.5s old, else nil.
    static func currentAmplitude() -> Float? {
        let ts = store?.double(forKey: kAmplitudeTimestamp) ?? 0
        if Date().timeIntervalSince1970 - ts > 0.5 { return nil }
        return store?.object(forKey: kCurrentAmplitude) as? Float
    }

    // MARK: - Recording history

    struct HistoryEntry: Codable, Identifiable {
        let id: UUID
        let timestamp: Date
        let original: String     // Whisper output, before tone rewrite
        let final: String        // GPT output, what was inserted
        let tone: String
        let translate: String

        init(id: UUID = UUID(), timestamp: Date = .init(),
             original: String, final: String, tone: String, translate: String) {
            self.id = id
            self.timestamp = timestamp
            self.original = original
            self.final = final
            self.tone = tone
            self.translate = translate
        }
    }

    static func appendHistory(_ entry: HistoryEntry) {
        var current = recentHistory()
        current.insert(entry, at: 0)
        if current.count > historyLimit {
            current = Array(current.prefix(historyLimit))
        }
        if let data = try? JSONEncoder().encode(current) {
            store?.set(data, forKey: kHistoryEntries)
        }
    }

    static func recentHistory() -> [HistoryEntry] {
        guard let data = store?.data(forKey: kHistoryEntries) else { return [] }
        return (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
    }

    static func clearHistory() {
        store?.removeObject(forKey: kHistoryEntries)
    }

    // MARK: - Recording trigger mode

    /// true = hold-to-talk (press to record, release to stop)
    /// false = tap-to-toggle (tap to start, tap again to stop) — default
    static func holdToTalkMode() -> Bool {
        store?.bool(forKey: kHoldToTalkMode) ?? false
    }

    static func setHoldToTalkMode(_ value: Bool) {
        store?.set(value, forKey: kHoldToTalkMode)
    }

    // MARK: - Whisper language hint

    /// Whisper ISO-639-1 language hint. "" means auto-detect.
    /// Recommended: "zh" for Chinese-primary users (handles mixed zh/en well,
    /// stops mis-detection as Korean/Japanese).
    static func whisperLanguage() -> String {
        store?.string(forKey: kWhisperLanguage) ?? ""
    }

    static func setWhisperLanguage(_ code: String) {
        store?.set(code, forKey: kWhisperLanguage)
    }

    // MARK: - Personal vocabulary

    /// Comma- or newline-separated list of names/terms Whisper should
    /// expect. Appended to the bias prompt to nudge transcription.
    static func personalVocabulary() -> String {
        store?.string(forKey: kPersonalVocabulary) ?? ""
    }

    static func setPersonalVocabulary(_ raw: String) {
        store?.set(raw, forKey: kPersonalVocabulary)
    }

    // MARK: - Setup guide flag

    static func hasSeenSetupGuide() -> Bool {
        store?.bool(forKey: kHasSeenSetupGuide) ?? false
    }

    // MARK: - Keyboard heartbeat

    /// Called by the keyboard extension on every viewDidLoad / viewWillAppear.
    /// Main app uses (lastSeen, hasFullAccess) to render the permission card.
    static func recordKeyboardHeartbeat(hasFullAccess: Bool) {
        store?.set(Date().timeIntervalSince1970, forKey: kKeyboardLastSeen)
        store?.set(hasFullAccess, forKey: kKeyboardHasFullAccess)
    }

    /// `nil` means the keyboard extension has never reported in — most
    /// likely the user hasn't added the Tonecast keyboard in Settings yet.
    static func keyboardLastSeen() -> Date? {
        let t = store?.double(forKey: kKeyboardLastSeen) ?? 0
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// Last reported value. `false` if the extension has never run or if
    /// the user has Full Access disabled. Pair with `keyboardLastSeen()`
    /// to distinguish "never installed" from "installed without Full Access".
    static func keyboardHasFullAccess() -> Bool {
        store?.bool(forKey: kKeyboardHasFullAccess) ?? false
    }

    static func markSetupGuideSeen() {
        store?.set(true, forKey: kHasSeenSetupGuide)
    }

    /// Cleaned vocabulary as a comma-joined string, suitable for inclusion
    /// in a Whisper prompt. Drops empty lines and surrounding whitespace.
    static func personalVocabularyForPrompt() -> String {
        let raw = personalVocabulary()
        let terms = raw
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return terms.joined(separator: ", ")
    }

    // MARK: - Speak-to-Edit

    static func armEditMode(selectedText: String) {
        store?.set(selectedText, forKey: kEditModeText)
        store?.set(true, forKey: kEditModeActive)
    }

    static func clearEditMode() {
        store?.removeObject(forKey: kEditModeText)
        store?.set(false, forKey: kEditModeActive)
    }

    static func editModeActive() -> Bool {
        store?.bool(forKey: kEditModeActive) ?? false
    }

    static func editModeText() -> String? {
        store?.string(forKey: kEditModeText)
    }

    // MARK: - Cleanup

    static func clearAll() {
        store?.removeObject(forKey: kSessionState)
        store?.removeObject(forKey: kSessionStateTimestamp)
        store?.removeObject(forKey: kResultText)
        store?.removeObject(forKey: kResultTone)
        store?.removeObject(forKey: kResultOriginal)
        store?.removeObject(forKey: kErrorMessage)
        store?.removeObject(forKey: kStopRequested)
        store?.removeObject(forKey: kCancelRequested)
        store?.removeObject(forKey: kStartRequested)
        store?.removeObject(forKey: kEditModeText)
        store?.set(false, forKey: kEditModeActive)
        // Refine — wipe in-flight requests + results so a fresh recording
        // doesn't get polluted by a stale chip tap.
        store?.set(false, forKey: kRefineRequested)
        store?.removeObject(forKey: kRefineAction)
        store?.removeObject(forKey: kRefineParam)
        store?.removeObject(forKey: kRefineInputText)
        store?.set(false, forKey: kRefineResultReady)
        store?.removeObject(forKey: kRefineResultText)
        // Retry — fresh recording invalidates any prior failed-recording
        // retry slot. The orphaned audio file gets cleaned up by the next
        // app launch's tmp-dir reaping.
        store?.set(false, forKey: kRetryAvailable)
        store?.set(false, forKey: kRetryRequested)
        store?.removeObject(forKey: kRetryFilePath)
    }
}
