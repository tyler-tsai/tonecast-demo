import Foundation

struct WhisperClient {
    /// Where + how to make the transcribe call. Wraps the endpoint URL,
    /// any extra headers (e.g. `X-App: tonecast` for the proxy's
    /// multi-tenant routing), and the App Attest signer that produces
    /// the per-request `X-AppAttest-*` headers.
    struct Config {
        let endpoint: URL
        let extraHeaders: [String: String]
        let requestSigner: any RequestSigner

        init(endpoint: URL,
             extraHeaders: [String: String] = [:],
             requestSigner: any RequestSigner = NoopRequestSigner()) {
            self.endpoint = endpoint
            self.extraHeaders = extraHeaders
            self.requestSigner = requestSigner
        }
    }

    let config: Config

    init(config: Config) {
        self.config = config
    }

    func transcribe(audioURL: URL) async throws -> String {
        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        // X-App: tonecast is injected here. No Authorization header —
        // App Attest assertions (added by config.requestSigner below)
        // are the only credential the proxy accepts.
        for (name, value) in config.extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        // gpt-4o-transcribe: 2025-era replacement for whisper-1 — better
        // accuracy on short clips and on mixed zh/en code-switching, fewer
        // hallucinations. Same per-minute price. Endpoint and request
        // shape are identical, so this is a drop-in upgrade.
        body.appendString("gpt-4o-transcribe\r\n")

        // Language hint — when the user has set a preferred input language,
        // pass it as Whisper's `language` parameter (ISO-639-1). Without this
        // hint Whisper sometimes mis-detects Mandarin as Korean or Japanese.
        // Empty string = auto-detect (Whisper default).
        let langCode = SharedDefaults.whisperLanguage()
        if !langCode.isEmpty {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
            body.appendString("\(langCode)\r\n")
        }

        // Biasing prompt — Whisper accepts a `prompt` string that nudges its
        // vocabulary/style. We include both zh and en so mixed code-switching
        // ("明天 sync meeting 改到 4pm") still transcribes cleanly regardless
        // of the `language` setting. User's personal vocabulary is appended
        // so domain-specific names and jargon transcribe correctly.
        var biasPrompt = "Mix of 繁體中文 and English. Common terms: meeting, sync, email, deadline, OK."
        let userVocab = SharedDefaults.personalVocabularyForPrompt()
        if !userVocab.isEmpty {
            biasPrompt += " " + userVocab
        }
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n")
        body.appendString("\(biasPrompt)\r\n")

        // Whisper inspects the filename extension to pick a decoder; if we
        // claim a format that doesn't match the bytes (e.g. say WAV but send
        // AAC/m4a), it returns 'Invalid file format'. Forward the real
        // filename + matching MIME based on the audio URL extension.
        let filename = audioURL.lastPathComponent
        let mimeType: String
        switch audioURL.pathExtension.lowercased() {
        case "m4a", "mp4": mimeType = "audio/m4a"
        case "wav":         mimeType = "audio/wav"
        case "mp3", "mpga": mimeType = "audio/mpeg"
        case "ogg", "oga":  mimeType = "audio/ogg"
        case "flac":        mimeType = "audio/flac"
        case "webm":        mimeType = "audio/webm"
        default:            mimeType = "application/octet-stream"
        }

        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.appendString("Content-Type: \(mimeType)\r\n\r\n")
        body.append(try Data(contentsOf: audioURL))
        body.appendString("\r\n")
        body.appendString("--\(boundary)--\r\n")

        request.httpBody = body

        // Sign last so the App Attest assertion is bound to the final
        // request shape (method + path are what's signed; body bytes
        // are not, but the proxy verifies them separately via the X-App
        // header + per-app key pool).
        try? await config.requestSigner.sign(&request)

        let (data, response) = try await NetworkSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let raw = String(data: data, encoding: .utf8) ?? "unknown error"
            throw NSError(domain: "Tonecast.Whisper", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Whisper API \((response as? HTTPURLResponse)?.statusCode ?? -1): \(raw)"])
        }

        struct WhisperResponse: Decodable { let text: String }
        let decoded = try JSONDecoder().decode(WhisperResponse.self, from: data)
        return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Data {
    mutating func appendString(_ s: String) {
        if let d = s.data(using: .utf8) { append(d) }
    }
}
