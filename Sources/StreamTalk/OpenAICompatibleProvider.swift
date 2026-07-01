import Foundation

/// Streaming chat for any OpenAI-compatible endpoint:
/// the local MLX server, OpenAI, DeepSeek, and MiniMax.
///
/// All four share the same wire format: SSE `data: {...}` lines, incremental
/// text at `choices[0].delta.content`, terminated by `data: [DONE]`.
struct OpenAICompatibleProvider: LLMProvider {
    let settings: ProviderSettings
    let temperature: Double

    private struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta
        }
        let choices: [Choice]?
    }

    func stream(system: String,
                messages: [ChatMessage],
                onDelta: @escaping (String) -> Void) async throws {
        let base = settings.baseURL.trimmingCharacters(in: .init(charactersIn: " /"))
        guard let url = URL(string: base + "/chat/completions") else {
            throw err("无效的 LLM 地址")
        }

        var wire: [[String: String]] = [["role": "system", "content": system]]
        wire += messages.map { ["role": $0.role, "content": $0.content] }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !settings.apiKey.isEmpty {
            req.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": settings.model,
            "messages": wire,
            "stream": true,
            "temperature": temperature,
        ])

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        try Self.checkHTTP(response, bytes: bytes)

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
                  let piece = chunk.choices?.first?.delta.content,
                  !piece.isEmpty
            else { continue }
            onDelta(piece)
        }
    }

    private static func checkHTTP(_ response: URLResponse, bytes: URLSession.AsyncBytes) throws {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "LLM", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
    }

    private func err(_ msg: String) -> NSError {
        NSError(domain: "LLM", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
