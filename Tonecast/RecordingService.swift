import Foundation
import AVFoundation
import UIKit

/// Typeless-style "Flow Session" recording service.
///
/// Lifecycle:
///   1. First time keyboard taps mic → opens `tonecast://record-start` URL
///   2. Main app launches; `startFlowSession()` sets up AVAudioEngine,
///      activates AVAudioSession, and starts a continuous input-tap that
///      writes to /dev/null when `isCapturing == false`
///   3. iPhone's status-bar mic indicator turns on and stays on
///   4. Main app suspends; engine + session stay alive under UIBackgroundModes
///      audio + an active recorder
///   5. Subsequent keyboard taps just flip `isCapturing` via App Group flags
///      — NO further app jumps until Flow Session timeout
///   6. Flow Session auto-expires after 15 min to bound battery cost
///
/// IPC contract (App Group):
///   - `flow_session_active`     bool, main app writes
///   - `start_requested`         bool + tone/translate ints, keyboard writes
///   - `stop_requested`          bool, keyboard writes
///   - `session_state` + result keys: main app writes, keyboard polls
@MainActor
final class RecordingService {
    static let shared = RecordingService()

    // Audio plumbing
    private var audioEngine: AVAudioEngine?
    private var currentRecordingFile: AVAudioFile?
    private var currentRecordingURL: URL?

    // Recording state
    private var isCapturing = false
    private var currentTone: Tone = .casual
    private var currentTranslate: TranslateMode = .off

    // Timers
    private var flagPollTimer: Timer?
    private var sessionExpiryTimer: Timer?

    // User-configurable duration via SharedDefaults
    private var flowSessionDuration: TimeInterval {
        TimeInterval(SharedDefaults.flowDurationMinutes() * 60)
    }

    // MARK: - Public entry points

    /// Activate Flow Session and immediately begin capturing the first
    /// recording. Called by `tonecast://record-start` URL handler.
    func startFlowSession(tone: Tone, translate: TranslateMode) {
        currentTone = tone
        currentTranslate = translate

        if audioEngine?.isRunning == true {
            NSLog("[Tonecast/main] Flow Session already running — beginning capture")
            beginCapturing()
            return
        }

        do {
            try setupAudioSession()
            try setupEngine()
            SharedDefaults.setFlowSessionActive(true)
            startFlagPoll()
            scheduleSessionExpiry()
            NSLog("[Tonecast/main] Flow Session active — mic indicator now on")
            beginCapturing()
        } catch {
            NSLog("[Tonecast/main] Flow Session setup failed: %@", error.localizedDescription)
            SharedDefaults.setError("Flow Session: \(error.localizedDescription)")
        }
    }

    /// Force-end the Flow Session (engine off, session deactivated, mic
    /// indicator goes off). Called by the expiry timer.
    func expireFlowSession() {
        NSLog("[Tonecast/main] expiring Flow Session")
        flagPollTimer?.invalidate()
        flagPollTimer = nil
        sessionExpiryTimer?.invalidate()
        sessionExpiryTimer = nil

        if isCapturing {
            // Wrap up whatever was being captured first
            stopCapturing()
        }

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        SharedDefaults.setFlowSessionActive(false)
        SharedDefaults.setSessionState(.idle)
    }

    // MARK: - Audio setup

    private func setupAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord,
                                mode: .default,
                                options: [.allowBluetooth, .defaultToSpeaker, .mixWithOthers])
        try session.setActive(true)
        NSLog("[Tonecast/main] session ready — rate=%.0f input=%@",
              session.sampleRate, session.isInputAvailable ? "YES" : "NO")
    }

    private func setupEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        NSLog("[Tonecast/main] input format: rate=%.0f ch=%u",
              inputFormat.sampleRate, inputFormat.channelCount)

        // The tap fires for EVERY input buffer (~10-20 Hz at 4096 frames /
        // 48kHz). Two things to do:
        //   1. Write to file if user is actively recording
        //   2. Compute a normalised amplitude (0…1) and publish via the
        //      App Group so the keyboard's waveform UI can render in real
        //      time without itself touching the audio session.
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            // 1) capture
            if self.isCapturing {
                try? self.currentRecordingFile?.write(from: buffer)
            }

            // 2) amplitude — RMS of the buffer, scaled into 0…1
            let amplitude = Self.normalizedAmplitude(from: buffer)
            SharedDefaults.setCurrentAmplitude(amplitude)
        }

        engine.prepare()
        try engine.start()
        self.audioEngine = engine
        NSLog("[Tonecast/main] engine running — isRunning=%@", engine.isRunning ? "YES" : "NO")
    }

    // MARK: - Capture window

    private func beginCapturing() {
        guard let engine = audioEngine else {
            NSLog("[Tonecast/main] beginCapturing — no engine")
            return
        }
        guard !isCapturing else {
            NSLog("[Tonecast/main] beginCapturing — already capturing, ignoring")
            return
        }

        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        let tmpDir = FileManager.default.temporaryDirectory
        let url = tmpDir.appendingPathComponent("tonecast-\(Int(Date().timeIntervalSince1970)).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: inputFormat.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            currentRecordingFile = file
            currentRecordingURL = url
            isCapturing = true
            SharedDefaults.setStopRequested(false)
            SharedDefaults.setSessionState(.recording)
            NSLog("[Tonecast/main] capturing → %@", url.path)
        } catch {
            NSLog("[Tonecast/main] AVAudioFile init failed: %@", error.localizedDescription)
            SharedDefaults.setError("File init failed: \(error.localizedDescription)")
        }
    }

    /// Stop capturing and discard the audio file without sending to Whisper.
    /// Triggered by the keyboard's cancel button or slide-off-mic gesture.
    private func cancelCapturing() {
        guard isCapturing else {
            NSLog("[Tonecast/main] cancelCapturing — not capturing, ignoring")
            return
        }
        NSLog("[Tonecast/main] cancelCapturing — discarding audio")
        isCapturing = false
        currentRecordingFile = nil

        if let url = currentRecordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        currentRecordingURL = nil
        SharedDefaults.setSessionState(.idle)
    }

    private func stopCapturing() {
        guard isCapturing else {
            NSLog("[Tonecast/main] stopCapturing — not capturing, ignoring")
            return
        }
        NSLog("[Tonecast/main] stopCapturing")
        isCapturing = false
        currentRecordingFile = nil   // close file

        guard let url = currentRecordingURL else { return }
        currentRecordingURL = nil

        let editText = SharedDefaults.editModeText()
        let isEditMode = SharedDefaults.editModeActive() && (editText?.isEmpty == false)

        processAudio(at: url,
                      tone: currentTone,
                      translate: currentTranslate,
                      editText: editText,
                      isEditMode: isEditMode)
    }

    /// Whisper + GPT pipeline. Used by both fresh recordings (`stopCapturing`)
    /// and Retry (`handleRetryRequest`). On success the audio file is deleted
    /// and any prior retry slot is cleared. On failure the file is KEPT and
    /// the retry slot is stashed so the keyboard can offer a Retry chip.
    private func processAudio(at url: URL,
                               tone: Tone,
                               translate: TranslateMode,
                               editText: String?,
                               isEditMode: Bool) {
        SharedDefaults.setSessionState(.processing)

        // Beg iOS for post-suspend processing time.
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "TonecastProcessing") {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }

        Task.detached {
            var processingSucceeded = false
            do {
                // Tonecast is proxy-only — every Whisper/GPT call goes
                // through the proxy. App Attest assertions
                // (injected by AppAttestService.shared) are the only
                // credential; there is no bundled key or shared bearer.
                let proxyMode = SharedDefaults.currentProxyMode()
                let signer = AppAttestService.shared
                let raw = try await WhisperClient(config: .init(
                    endpoint: proxyMode.transcribeEndpoint,
                    extraHeaders: proxyMode.extraHeaders,
                    requestSigner: signer
                )).transcribe(audioURL: url)
                NSLog("[Tonecast/main] Whisper: %@", raw)

                // Silent-error guard #1: Whisper returned no usable text.
                // Most often means the audio was silent / too quiet / pure
                // noise. Without this throw, the empty raw would propagate
                // through and produce an empty `final` → setResult writes
                // an empty string → peekResult() returns nil → keyboard
                // shows "Done" with no insertion and NO error. Silent.
                let rawTrimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rawTrimmed.isEmpty else {
                    throw NSError(domain: "Tonecast.Whisper", code: 100,
                                  userInfo: [NSLocalizedDescriptionKey: "No speech detected — try recording again, speaking louder or closer to the mic"])
                }

                let final: String
                // Shared rewriter config — same proxyMode resolved above
                // (Whisper + GPT calls always go through the same mode for
                // a given recording).
                let rewriterConfig = ToneRewriter.Config(
                    endpoint: proxyMode.chatCompletionsEndpoint,
                    extraHeaders: proxyMode.extraHeaders,
                    requestSigner: signer
                )
                if isEditMode, let original = editText {
                    NSLog("[Tonecast/main] EDIT mode — applying command to selected text")
                    final = try await ToneRewriter(config: rewriterConfig)
                        .editSelectedText(original, withCommand: raw)
                    NSLog("[Tonecast/main] Edited: %@", final)
                } else if tone == .plain && translate == .off {
                    // PLAIN tone with no translation → skip GPT entirely.
                    // Whisper's transcript IS the result. Saves a network
                    // round-trip (~500ms) and guarantees zero LLM-induced
                    // drift on niche content (gaming jargon, code-speak,
                    // proper nouns the model would "helpfully correct").
                    NSLog("[Tonecast/main] PLAIN + no translate → bypassing GPT")
                    final = raw
                } else {
                    final = try await ToneRewriter(config: rewriterConfig)
                        .rewrite(raw, tone: tone, translate: translate)
                    NSLog("[Tonecast/main] GPT: %@", final)
                }

                // Silent-error guard #2: GPT returned an empty rewrite (or
                // edit). Same silent path as the Whisper guard above —
                // surface as an error so the user sees a message + retry
                // chip instead of a no-op.
                let finalTrimmed = final.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !finalTrimmed.isEmpty else {
                    throw NSError(domain: "Tonecast.GPT", code: 101,
                                  userInfo: [NSLocalizedDescriptionKey: "Rewrite returned empty — try Retry, or switch tone"])
                }

                processingSucceeded = true
                // Final deterministic formatting pass — applies regardless
                // of tone (including Plain bypass and Verbatim mode). Keeps
                // money / time / percent / email / URL conversions
                // consistent across the whole app. Idempotent, so it's safe
                // even when GPT already applied rule 10.
                let formattedFinal = LocalFormatter.apply(final)
                let formattedRaw = LocalFormatter.apply(raw)
                await MainActor.run {
                    // Pass the raw Whisper transcript through to the keyboard
                    // so the "Use Original" chip can swap back to it if GPT's
                    // rewrite drifted too far. Edit mode passes nil — the
                    // raw is a voice command, not insertable text.
                    SharedDefaults.setResult(formattedFinal,
                                              tone: isEditMode ? "Edit" : tone.displayName,
                                              original: isEditMode ? nil : formattedRaw)
                    SharedDefaults.appendHistory(.init(
                        original: isEditMode ? "\(editText ?? "") · cmd: \(raw)" : formattedRaw,
                        final: formattedFinal,
                        tone: isEditMode ? "Edit" : tone.displayName,
                        translate: translate.displayName
                    ))
                    SharedDefaults.clearEditMode()
                    SharedDefaults.clearRetry()
                    NSLog("[Tonecast/main] result written to App Group — keyboard will poll")
                }
            } catch {
                NSLog("[Tonecast/main] processing failed: %@", error.localizedDescription)
                await MainActor.run {
                    // Stash retry context BEFORE setting error — the keyboard's
                    // error-state UI checks peekRetryContext() to decide whether
                    // to show the Retry chip.
                    SharedDefaults.setRetryAvailable(filePath: url.path,
                                                     tone: tone.rawValue,
                                                     translate: translate.rawValue)
                    SharedDefaults.setError(error.localizedDescription)
                    SharedDefaults.clearEditMode()
                }
            }
            // Only delete the audio file on SUCCESS — on failure we keep it
            // around so Retry can re-run the pipeline against the same audio.
            if processingSucceeded {
                try? FileManager.default.removeItem(at: url)
            }
            await MainActor.run {
                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }
            }
        }
    }

    /// Keyboard tapped the Retry chip after a failed recording. Re-run the
    /// Whisper + GPT pipeline against the audio file we kept on disk.
    private func handleRetryRequest(_ ctx: SharedDefaults.RetryContext) {
        let url = URL(fileURLWithPath: ctx.filePath)
        guard FileManager.default.fileExists(atPath: ctx.filePath) else {
            NSLog("[Tonecast/main] retry: audio file vanished at %@", ctx.filePath)
            SharedDefaults.clearRetry()
            SharedDefaults.setError("Retry failed — audio file no longer available")
            return
        }
        let tone = Tone(rawValue: ctx.tone) ?? .casual
        let translate = TranslateMode(rawValue: ctx.translate) ?? .off
        NSLog("[Tonecast/main] retry: reprocessing %@", url.lastPathComponent)
        // Retries skip edit-mode replay — edit context was cleared at the
        // first failure. Treat retries as plain rewrite passes; this is a
        // tiny edge case (edit mode + API failure) we accept for v1.
        processAudio(at: url, tone: tone, translate: translate,
                      editText: nil, isEditMode: false)
    }

    // MARK: - Flag polling

    private func startFlagPoll() {
        flagPollTimer?.invalidate()
        NSLog("[Tonecast/main] starting flag-poll (every 0.2s)")
        let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            // Heartbeat — keyboard's flowSessionActive() check uses this to
            // verify the main app process is actually alive. Without this,
            // a stale flowSessionActive=YES (from a previous run that got
            // killed) would trap the keyboard into the no-app-jump path.
            SharedDefaults.recordFlowHeartbeat()

            if SharedDefaults.cancelRequested() {
                NSLog("[Tonecast/main] cancel_requested observed")
                SharedDefaults.setCancelRequested(false)
                Task { @MainActor in self.cancelCapturing() }
            }

            if SharedDefaults.stopRequested() {
                NSLog("[Tonecast/main] stop_requested observed")
                SharedDefaults.setStopRequested(false)
                Task { @MainActor in self.stopCapturing() }
            }

            if let req = SharedDefaults.consumeStartRequest() {
                NSLog("[Tonecast/main] start_requested observed (tone=%d translate=%d)",
                      req.tone, req.translate)
                let tone = Tone(rawValue: req.tone) ?? .casual
                let translate = TranslateMode(rawValue: req.translate) ?? .off
                Task { @MainActor in
                    self.currentTone = tone
                    self.currentTranslate = translate
                    self.beginCapturing()
                }
            }

            // Quick-action refine — keyboard wants us to transform a piece
            // of already-existing text (e.g. "make the last result shorter").
            // No Whisper needed; we go straight to the rewriter.
            if let req = SharedDefaults.consumeRefineRequest() {
                NSLog("[Tonecast/main] refine_requested observed (action=%@ chars=%d)",
                      req.action, req.inputText.count)
                self.handleRefineRequest(req)
            }

            // Retry — keyboard tapped the Retry chip after a failed
            // recording. Re-run the pipeline against the kept audio file.
            if let ctx = SharedDefaults.consumeRetryRequest() {
                NSLog("[Tonecast/main] retry_requested observed (tone=%d translate=%d)",
                      ctx.tone, ctx.translate)
                Task { @MainActor in self.handleRetryRequest(ctx) }
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        flagPollTimer = timer
    }

    // MARK: - Refine

    /// Process a quick-action refine request (Shorter / Longer / Polish /
    /// SwitchTone) from the keyboard. No audio involved — straight GPT
    /// transform on the supplied text. Writes result to a separate slot
    /// so the keyboard can distinguish replace-old-output from fresh-insert.
    private func handleRefineRequest(_ req: SharedDefaults.RefineRequest) {
        guard let action = RefineAction(rawValue: req.action) else {
            NSLog("[Tonecast/main] refine: unknown action %@", req.action)
            return
        }
        let sourceTone = Tone(rawValue: req.sourceTone) ?? .casual
        let sourceTranslate = TranslateMode(rawValue: req.sourceTranslate) ?? .off

        // Background task — refine should be allowed to finish even if the
        // main app gets squeezed for resources.
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "TonecastRefine") {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }

        Task.detached {
            do {
                // Refine routes through the proxy too — same X-App
                // header + same chat-completions endpoint + same App
                // Attest signer.
                let proxyMode = SharedDefaults.currentProxyMode()
                let refineConfig = ToneRewriter.Config(
                    endpoint: proxyMode.chatCompletionsEndpoint,
                    extraHeaders: proxyMode.extraHeaders,
                    requestSigner: AppAttestService.shared
                )
                let refined = try await ToneRewriter(config: refineConfig)
                    .refine(text: req.inputText,
                            action: action,
                            param: req.param,
                            currentTone: sourceTone,
                            translate: sourceTranslate)
                NSLog("[Tonecast/main] refine done (%d → %d chars)",
                      req.inputText.count, refined.count)
                let formattedRefined = LocalFormatter.apply(refined)
                await MainActor.run {
                    SharedDefaults.setRefineResult(formattedRefined)
                }
            } catch {
                NSLog("[Tonecast/main] refine failed: %@", error.localizedDescription)
                await MainActor.run {
                    SharedDefaults.setError(error.localizedDescription)
                }
            }
            await MainActor.run {
                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }
            }
        }
    }

    private func scheduleSessionExpiry() {
        sessionExpiryTimer?.invalidate()
        sessionExpiryTimer = Timer.scheduledTimer(withTimeInterval: flowSessionDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.expireFlowSession()
            }
        }
    }

    /// Compute a single 0…1 amplitude reading from a PCM buffer using
    /// root-mean-square, then ease it through a log curve so quiet voices
    /// still show motion in the waveform.
    private static func normalizedAmplitude(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let frames = Int(buffer.frameLength)
        if frames == 0 { return 0 }

        var sumSquares: Float = 0
        for i in 0..<frames {
            let s = channelData[i]
            sumSquares += s * s
        }
        let rms = sqrtf(sumSquares / Float(frames))

        // RMS for speech is typically 0.001 – 0.3 range. Map into 0…1 via
        // a perceptual scale (similar to a VU meter).
        let db = 20 * log10f(max(rms, 0.0000001))
        // -60 dB → 0,  -10 dB → ~1
        let normalized = max(0, min(1, (db + 60) / 50))
        return normalized
    }
}
