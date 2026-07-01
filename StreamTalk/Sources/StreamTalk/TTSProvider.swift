import Foundation

/// One TTS backend: turns a sentence into audio bytes (always WAV — the
/// `AudioPlayer` decodes WAV). Mirrors `LLMProvider` / `LLMProviderFactory`.
protocol TTSProvider: Sendable {
    /// - Parameters:
    ///   - text: sentence to synthesize (already filtered to speakable text).
    ///   - language: reply language, mapped by each provider to its own params
    ///     (CosyVoice instruct, MeloTTS language code).
    func synthesize(_ text: String, language: VoiceLanguage) async throws -> Data
}

enum TTSProviderFactory {
    /// Build the right TTS provider for the given settings.
    static func make(kind: TTSProviderKind, settings: TTSProviderSettings) -> TTSProvider {
        switch kind {
        case .cosyvoice: return CosyVoiceTTSProvider(settings: settings)
        case .melotts:   return MeloTTSProvider(settings: settings)
        }
    }
}

/// Shared POST helper: sends `body` as JSON to `<server>/v1/audio/speech` and
/// returns the raw audio bytes. Both providers share this endpoint shape.
enum TTSHTTP {
    static func speech(server: String, body: [String: Any]) async throws -> Data {
        let base = server.trimmingCharacters(in: .init(charactersIn: " /"))
        guard let url = URL(string: base + "/v1/audio/speech") else {
            throw NSError(domain: "TTS", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无效的 TTS 服务器地址"])
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "TTS", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "TTS HTTP \(http.statusCode) \(msg)"])
        }
        return data
    }
}

/// CosyVoice FastAPI — natural-language `instruct` controls the dialect/accent.
struct CosyVoiceTTSProvider: TTSProvider {
    let settings: TTSProviderSettings

    func synthesize(_ text: String, language: VoiceLanguage) async throws -> Data {
        var body: [String: Any] = [
            "input": text,
            "response_format": "wav",
            "instruct": language.ttsInstruct,
            "speed": settings.speed,
        ]
        if !settings.mode.isEmpty { body["mode"] = settings.mode }
        return try await TTSHTTP.speech(server: settings.serverURL, body: body)
    }
}

/// MeloTTS FastAPI — `language` code + optional `speaker` (no instruct/cloning).
struct MeloTTSProvider: TTSProvider {
    let settings: TTSProviderSettings

    func synthesize(_ text: String, language: VoiceLanguage) async throws -> Data {
        var body: [String: Any] = [
            "input": text,
            "response_format": "wav",
            "speed": settings.speed,
            "language": language.melottsLanguage,
        ]
        if !settings.speaker.isEmpty { body["speaker"] = settings.speaker }
        return try await TTSHTTP.speech(server: settings.serverURL, body: body)
    }
}
