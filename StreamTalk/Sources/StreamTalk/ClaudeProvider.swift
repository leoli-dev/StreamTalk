import Foundation

/// Streaming chat via the Anthropic Messages API.
///
/// Differs from the OpenAI-compatible shape in three ways that matter here:
///  - auth is `x-api-key` + `anthropic-version`, not `Authorization: Bearer`
///  - the system prompt is a top-level field, not a message
///  - SSE deltas arrive as `content_block_delta` events with text at `delta.text`
struct ClaudeProvider: LLMProvider {
    let settings: ProviderSettings

    private struct Event: Decodable {
        struct Delta: Decodable {
            let type: String?
            let text: String?
        }
        let type: String
        let delta: Delta?
    }

    func stream(system: String,
                messages: [ChatMessage],
                onDelta: @escaping (String) -> Void) async throws {
        let base = settings.baseURL.trimmingCharacters(in: .init(charactersIn: " /"))
        guard let url = URL(string: base + "/v1/messages") else {
            throw err("无效的 Claude 地址")
        }

        // Anthropic requires alternating user/assistant and no system role here.
        let wire = messages
            .filter { $0.role == "user" || $0.role == "assistant" }
            .map { ["role": $0.role, "content": $0.content] }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(settings.apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": settings.model,
            "max_tokens": 4096,
            "system": system,
            "messages": wire,
            "stream": true,
        ])

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "Claude", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }   // ignore `event:` lines
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONDecoder().decode(Event.self, from: data)
            else { continue }
            if event.type == "content_block_delta",
               event.delta?.type == "text_delta",
               let text = event.delta?.text, !text.isEmpty {
                onDelta(text)
            }
        }
    }

    private func err(_ msg: String) -> NSError {
        NSError(domain: "Claude", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
