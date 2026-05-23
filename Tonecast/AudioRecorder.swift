import Foundation
import AVFoundation

/// Records mic input via AVAudioEngine + input-node tap, writing PCM-WAV.
///
/// AVAudioRecorder is unreliable in keyboard extensions: it silently returns
/// false from .record() even when the audio session is fully configured and
/// permissions granted. AVAudioEngine bypasses that whole layer and lets us
/// pull buffers directly from the input node, writing WAV via AVAudioFile.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var outputFile: AVAudioFile?
    private(set) var currentURL: URL?

    func start() throws -> URL {
        NSLog("[Tonecast] AudioRecorder.start() entry")

        let session = AVAudioSession.sharedInstance()
        do {
            // .record + .measurement is the most isolated config — it
            // disables system audio processing (gain/compression) and
            // doesn't conflict with the host app's playback session.
            // .playAndRecord + .defaultToSpeaker previously yielded
            // !rec (cannotStartRecording) from iOS.
            try session.setCategory(.record, mode: .measurement, options: [])
            NSLog("[Tonecast] setCategory(.record, .measurement) ok")
            try session.setActive(true, options: [.notifyOthersOnDeactivation])
            NSLog("[Tonecast] setActive ok — rate=%.0f input=%@ cat=%@ mode=%@",
                  session.sampleRate,
                  session.isInputAvailable ? "YES" : "NO",
                  session.category.rawValue,
                  session.mode.rawValue)
            let inputs = session.currentRoute.inputs.map { "\($0.portName)(\($0.portType.rawValue))" }.joined(separator: ",")
            let outputs = session.currentRoute.outputs.map { "\($0.portName)(\($0.portType.rawValue))" }.joined(separator: ",")
            NSLog("[Tonecast] route inputs=[%@] outputs=[%@]", inputs, outputs)
        } catch {
            NSLog("[Tonecast] session config failed: %@", error.localizedDescription)
            throw error
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        NSLog("[Tonecast] input node format: rate=%.0f ch=%u",
              inputFormat.sampleRate, inputFormat.channelCount)

        let tmpDir = FileManager.default.temporaryDirectory
        let url = tmpDir.appendingPathComponent("tonecast-\(Int(Date().timeIntervalSince1970)).wav")
        NSLog("[Tonecast] writing WAV to %@", url.path)

        // Write linear-PCM int16 WAV at the input's native sample rate.
        // Whisper accepts any rate; we don't bother downsampling here.
        let writeSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: inputFormat.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: writeSettings)
        } catch {
            NSLog("[Tonecast] AVAudioFile init failed: %@", error.localizedDescription)
            throw error
        }
        self.outputFile = file
        NSLog("[Tonecast] AVAudioFile ready")

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            do {
                try self?.outputFile?.write(from: buffer)
            } catch {
                NSLog("[Tonecast] tap write error: %@", error.localizedDescription)
            }
        }

        engine.prepare()
        NSLog("[Tonecast] engine.prepare() done — about to start")
        do {
            try engine.start()
        } catch let nsError as NSError {
            let fourCC = String(bytes: stride(from: 24, through: 0, by: -8).map { UInt8((nsError.code >> $0) & 0xff) },
                                encoding: .ascii) ?? "?"
            NSLog("[Tonecast] engine.start() failed: %@ code=%d (FourCC=%@) domain=%@",
                  nsError.localizedDescription, nsError.code, fourCC, nsError.domain)
            input.removeTap(onBus: 0)
            self.outputFile = nil
            throw nsError
        }
        NSLog("[Tonecast] engine.start() ok — isRunning=%@", engine.isRunning ? "YES" : "NO")

        self.currentURL = url
        return url
    }

    @discardableResult
    func stop() -> URL? {
        let duration = outputFile.map { Double($0.length) / $0.fileFormat.sampleRate } ?? 0
        NSLog("[Tonecast] AudioRecorder.stop() — running=%@ duration=%.2fs",
              engine.isRunning ? "YES" : "NO", duration)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        outputFile = nil
        let url = currentURL
        return url
    }
}
