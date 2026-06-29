import Foundation
import SwiftUI

/// App-wide settings, persisted to UserDefaults as JSON.
@MainActor
final class Config: ObservableObject {
    static let shared = Config()

    @Published var selectedProvider: ProviderKind { didSet { persist() } }
    @Published var providers: [ProviderKind: ProviderSettings] { didSet { persist() } }
    /// Reply / TTS output language ONLY. Input (STT) language is `sttLocale`,
    /// controlled independently — speaking Cantonese while the AI replies in
    /// English is a valid combination.
    @Published var voiceLanguage: VoiceLanguage { didSet { persist() } }
    @Published var ttsProxyURL: String { didSet { persist() } }
    @Published var ttsServerURL: String { didSet { persist() } }
    @Published var autoStartProxy: Bool { didSet { persist() } }
    @Published var proxyScriptPath: String { didSet { persist() } }
    @Published var sttLocale: String { didSet { persist() } }
    @Published var continuousMode: Bool { didSet { persist() } }
    @Published var optionKeyToTalk: Bool { didSet { persist() } }
    @Published var systemPrompt: String { didSet { persist() } }
    @Published var temperature: Double { didSet { persist() } }

    private struct Snapshot: Codable {
        var selectedProvider: ProviderKind
        var providers: [String: ProviderSettings]
        var voiceLanguage: String   // raw — tolerant of removed cases
        var ttsProxyURL: String
        var ttsServerURL: String?
        var autoStartProxy: Bool?
        var proxyScriptPath: String?
        var sttLocale: String
        var continuousMode: Bool?
        var optionKeyToTalk: Bool?
        var systemPrompt: String
        var temperature: Double
    }

    private static let key = "streamtalk.config.v2"
    private var loading = false

    static let defaultSystemPrompt =
        "你是一个语音聊天助手，用户在用语音和你对话。像真人闲聊一样，"
        + "【每次只回复 1 到 2 句话，务必简短，不要长篇大论】。用自然口语，"
        + "正常使用标点符号。绝对不要用 markdown、星号(*)、井号(#)、编号或分点列表、"
        + "标题、表情符号，也不要用括号写动作或旁白。"

    /// Older prompt defaults we replace on load (kept too long / wrong style for
    /// a voice assistant — replies were huge and slow to speak).
    private static let legacySystemPrompts: Set<String> = [
        "你是一个语音聊天助手。回答简洁直接，像真人对话一样，"
            + "不要用列表、markdown 或书面语，不要用括号注释.",
        "你是一个语音聊天助手。回答简洁直接，像真人对话一样，"
            + "不要用列表、markdown 或书面语，不要用括号注释。",
        "你是一个语音聊天助手，用自然、口语化的方式简短回答，像真人聊天一样。"
            + "请正常使用标点符号（逗号、句号、问号、感叹号），这样断句和发音才自然。"
            + "不要使用 markdown、列表、标题、代码块或括号注释。",
    ]

    private init() {
        // Seed sensitive/host defaults from .env (gitignored) when present,
        // otherwise generic placeholders. Real values never live in source.
        let env = Self.loadDotenv()

        var providers: [ProviderKind: ProviderSettings] = [:]
        for kind in ProviderKind.allCases { providers[kind] = .defaults(for: kind) }
        if let k = env["STREAMTALK_LOCAL_KEY"] { providers[.local]?.apiKey = k }
        if let b = env["STREAMTALK_LLM_BASE"] { providers[.local]?.baseURL = b }
        if let m = env["STREAMTALK_LLM_MODEL"] { providers[.local]?.model = m }

        selectedProvider = .local
        self.providers = providers
        voiceLanguage = .cantonese
        ttsProxyURL = "http://127.0.0.1:8787"   // legacy, unused (app calls TTS directly)
        ttsServerURL = env["STREAMTALK_TTS_SERVER"] ?? "http://127.0.0.1:5055"
        autoStartProxy = false
        proxyScriptPath = ""
        sttLocale = "yue-CN"
        continuousMode = true
        optionKeyToTalk = true
        systemPrompt = Self.defaultSystemPrompt
        temperature = 0.7

        load()
    }

    /// Settings for the currently-selected provider (with a safe fallback).
    var current: ProviderSettings {
        providers[selectedProvider] ?? .defaults(for: selectedProvider)
    }

    /// Binding-friendly mutation for a specific provider's settings.
    func binding(for kind: ProviderKind) -> Binding<ProviderSettings> {
        Binding(
            get: { self.providers[kind] ?? .defaults(for: kind) },
            set: { self.providers[kind] = $0 }
        )
    }

    /// Full system prompt = base prompt + reply-language hint.
    var effectiveSystemPrompt: String {
        systemPrompt + "\n" + voiceLanguage.replyHint
    }

    // MARK: - .env loading (gitignored secrets)

    /// Parse a KEY=VALUE `.env` from $STREAMTALK_ENV, ~/.config/streamtalk/.env,
    /// or ./.env (whichever is found first). Returns empty if none.
    private static func loadDotenv() -> [String: String] {
        let fm = FileManager.default
        var candidates: [String] = []
        if let p = ProcessInfo.processInfo.environment["STREAMTALK_ENV"] { candidates.append(p) }
        candidates.append(fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/streamtalk/.env").path)
        candidates.append(fm.currentDirectoryPath + "/.env")

        for path in candidates {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            var dict: [String: String] = [:]
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                guard let eq = line.firstIndex(of: "=") else { continue }
                let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                var val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if val.count >= 2, (val.hasPrefix("\"") && val.hasSuffix("\"")) {
                    val = String(val.dropFirst().dropLast())
                }
                if !key.isEmpty { dict[key] = val }
            }
            return dict
        }
        return [:]
    }

    // MARK: - Persistence

    private func persist() {
        guard !loading else { return }
        var dict: [String: ProviderSettings] = [:]
        for (k, v) in providers { dict[k.rawValue] = v }
        let snap = Snapshot(selectedProvider: selectedProvider, providers: dict,
                            voiceLanguage: voiceLanguage.rawValue, ttsProxyURL: ttsProxyURL,
                            ttsServerURL: ttsServerURL,
                            autoStartProxy: autoStartProxy, proxyScriptPath: proxyScriptPath,
                            sttLocale: sttLocale, continuousMode: continuousMode,
                            optionKeyToTalk: optionKeyToTalk,
                            systemPrompt: systemPrompt, temperature: temperature)
        if let data = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        loading = true
        selectedProvider = snap.selectedProvider
        var merged = providers
        for (k, v) in snap.providers {
            if let kind = ProviderKind(rawValue: k) { merged[kind] = v }
        }
        providers = merged
        voiceLanguage = VoiceLanguage(rawValue: snap.voiceLanguage) ?? .cantonese
        ttsProxyURL = snap.ttsProxyURL
        // Migrate the Triton gRPC address back to the FastAPI address.
        let savedServer = snap.ttsServerURL ?? ttsServerURL
        ttsServerURL = savedServer.contains("18001") ? "http://pc-lan.home:5055" : savedServer
        autoStartProxy = snap.autoStartProxy ?? autoStartProxy
        proxyScriptPath = snap.proxyScriptPath ?? proxyScriptPath
        // Migrate: zh-HK was our old (wrong) Cantonese code → Apple's yue-CN.
        sttLocale = snap.sttLocale == "zh-HK" ? "yue-CN" : snap.sttLocale
        continuousMode = snap.continuousMode ?? continuousMode
        optionKeyToTalk = snap.optionKeyToTalk ?? optionKeyToTalk
        // Replace legacy no-punctuation prompts with the current default.
        systemPrompt = Self.legacySystemPrompts.contains(snap.systemPrompt)
            ? Self.defaultSystemPrompt : snap.systemPrompt
        temperature = snap.temperature
        loading = false
    }
}
