import Foundation

// MARK: - Chat wire type (provider-agnostic)

struct ChatMessage: Codable {
    let role: String   // "system" | "user" | "assistant"
    let content: String
}

// MARK: - Persisted session model

struct StoredMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: String          // "user" | "assistant"
    var text: String
    let createdAt: Date

    init(id: UUID = UUID(), role: String, text: String, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

struct Session: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var messages: [StoredMessage]
    /// Per-session system prompt override; nil = use the global default.
    var systemPrompt: String?
    let createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), title: String = "新对话",
         messages: [StoredMessage] = [], systemPrompt: String? = nil,
         createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.messages = messages
        self.systemPrompt = systemPrompt
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}

// MARK: - Providers

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case local, openai, claude, deepseek, minimax
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local: return "本地 (MLX)"
        case .openai: return "OpenAI"
        case .claude: return "Claude"
        case .deepseek: return "DeepSeek"
        case .minimax: return "MiniMax"
        }
    }

    /// Claude uses the Anthropic Messages API; everyone else is OpenAI-compatible.
    var isClaude: Bool { self == .claude }

    var defaultBaseURL: String {
        switch self {
        case .local: return "http://127.0.0.1:8000/v1"
        case .openai: return "https://api.openai.com/v1"
        case .claude: return "https://api.anthropic.com"
        case .deepseek: return "https://api.deepseek.com"
        case .minimax: return "https://api.minimax.io/v1"
        }
    }

    var defaultModel: String { suggestedModels.first ?? "" }

    /// A few current model IDs to offer in the picker (the field stays editable).
    var suggestedModels: [String] {
        switch self {
        case .local:
            return ["Qwen3.6-35B-A3B-MLX-8bit", "Qwen3.5-122B-A10B-4bit",
                    "gemma-4-31b-it-8bit"]
        case .openai:
            return ["gpt-5.4", "gpt-5.4-mini", "gpt-4.1", "gpt-4o"]
        case .claude:
            return ["claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5",
                    "claude-fable-5"]
        case .deepseek:
            return ["deepseek-v4-flash", "deepseek-v4-pro", "deepseek-chat"]
        case .minimax:
            return ["MiniMax-M2.5", "MiniMax-M3", "MiniMax-M2.5-highspeed"]
        }
    }

    var defaultKey: String { "" }   // secrets come from .env / Settings, never source
}

struct ProviderSettings: Codable, Equatable {
    var baseURL: String
    var apiKey: String
    var model: String

    static func defaults(for kind: ProviderKind) -> ProviderSettings {
        ProviderSettings(baseURL: kind.defaultBaseURL,
                         apiKey: kind.defaultKey,
                         model: kind.defaultModel)
    }
}

// MARK: - Voice / reply language

enum VoiceLanguage: String, Codable, CaseIterable, Identifiable {
    case cantonese, mandarin, english
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cantonese: return "粤语"
        case .mandarin: return "普通话"
        case .english: return "English"
        }
    }

    /// Instruction sent to CosyVoice to control the spoken language/accent.
    var ttsInstruct: String {
        switch self {
        case .cantonese: return "请用自然、清晰的香港粤语口语表达。"
        case .mandarin: return "请用自然、清晰的普通话表达。"
        case .english: return "Please speak in natural, clear English."
        }
    }

    /// Appended to the system prompt so the AI replies in the spoken language.
    /// Strong wording — the model otherwise mirrors the user's input language.
    var replyHint: String {
        switch self {
        case .cantonese:
            return "【回复语言·最高优先级】无论用户用什么语言说话，你都必须始终用自然口语化的香港粤语回复，绝不要切换成普通话或其他语言。"
        case .mandarin:
            return "【回复语言·最高优先级】无论用户用什么语言说话（包括粤语、英文），你都必须始终只用自然口语化的简体中文普通话回复，绝不要使用粤语字词或其他语言。"
        case .english:
            return "[Reply language · TOP PRIORITY] Always respond ONLY in natural, conversational English, no matter what language the user speaks. Never switch to Chinese."
        }
    }

    /// Reasonable default STT locale to pair with this reply language.
    var defaultSTTLocale: String {
        switch self {
        case .cantonese: return "yue-CN"   // Apple 的粤语代码（zh-HK 其实偏普通话）
        case .mandarin: return "zh-CN"
        case .english: return "en-US"
        }
    }
}
