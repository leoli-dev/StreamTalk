import Foundation

/// A streaming chat backend. `onDelta` is called with incremental text.
protocol LLMProvider {
    func stream(system: String,
                messages: [ChatMessage],
                onDelta: @escaping (String) -> Void) async throws
}

enum LLMProviderFactory {
    /// Build the right provider for the given settings.
    static func make(kind: ProviderKind,
                     settings: ProviderSettings,
                     temperature: Double) -> LLMProvider {
        if kind.isClaude {
            return ClaudeProvider(settings: settings)
        }
        return OpenAICompatibleProvider(settings: settings, temperature: temperature)
    }
}
