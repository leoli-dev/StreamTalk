import Foundation

/// Synthesizes one sentence by calling the CosyVoice FastAPI directly
/// (`POST <server>/v1/audio/speech`). No local proxy needed.
struct TTSClient {
    /// - Parameters:
    ///   - server: CosyVoice FastAPI base URL, e.g. http://pc-lan.home:5055
    ///   - instruct: natural-language style/dialect instruction (e.g. 粤语)
    func synthesize(_ text: String, server: String, instruct: String) async throws -> Data {
        let base = server.trimmingCharacters(in: .init(charactersIn: " /"))
        guard let url = URL(string: base + "/v1/audio/speech") else {
            throw NSError(domain: "TTS", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无效的 TTS 服务器地址"])
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "input": text,
            "response_format": "wav",
            "instruct": instruct,
        ])

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "TTS", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "TTS HTTP \(http.statusCode) \(msg)"])
        }
        return data
    }

    /// Pre-warm the TTS server (`POST /warmup`) so the first real synthesis is
    /// fast. Fire-and-forget; failures (older server, offline) are ignored.
    func warmup(server: String) async {
        let base = server.trimmingCharacters(in: .init(charactersIn: " /"))
        guard let url = URL(string: base + "/warmup") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "texts": ["你好。", "今天过得怎么样呀？", "我们随便聊几句，测试一下反应速度。"],
        ])
        _ = try? await URLSession.shared.data(for: req)
    }
}
