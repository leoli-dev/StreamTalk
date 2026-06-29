import Foundation
import SwiftUI

@MainActor
final class ChatViewModel: ObservableObject {
    enum Phase: String { case idle, listening, thinking, speaking }

    @Published var phase: Phase = .idle
    @Published var status = "就绪"
    @Published var lastError: String?
    @Published var liveTranscript = ""          // STT partial, pre-commit
    @Published var currentSessionID: UUID?
    @Published var textInput = ""               // typed message box

    let store: SessionStore
    private let config = Config.shared
    private lazy var speech = SpeechRecognizer(localeIdentifier: config.sttLocale)
    private let tts = TTSClient()
    private let player = AudioPlayer()
    private let hotkey = HotkeyManager()

    private var llmTask: Task<Void, Never>?
    private var consumerTask: Task<Void, Never>?
    private var sentenceContinuation: AsyncStream<String>.Continuation?
    private var consumerDone = false
    private var permissionsOK = false
    private var autoListenTask: Task<Void, Never>?

    init(store: SessionStore) {
        self.store = store
        currentSessionID = store.sessions.first?.id
        player.onIdle = { [weak self] in
            Task { @MainActor in self?.audioDrained() }
        }
        hotkey.onTap = { [weak self] in
            guard let self, self.config.optionKeyToTalk else { return }
            self.talkButtonTapped()
        }
        hotkey.start()
        // Note: the TTS server auto-warms on startup; an app-side warmup only
        // contends with real requests on the single-GPU queue, so we don't.
    }

    // MARK: - Session selection

    func selectSession(_ id: UUID) {
        autoListenTask?.cancel()
        if phase != .idle { cancelTurn(); finishTurn() }
        currentSessionID = id
    }

    func newChat() {
        autoListenTask?.cancel()
        if phase != .idle { cancelTurn(); finishTurn() }
        currentSessionID = store.newSession()
    }

    private func ensureSession() -> UUID {
        if let id = currentSessionID, store.session(id) != nil { return id }
        let id = store.newSession()
        currentSessionID = id
        return id
    }

    // MARK: - Mic button

    func talkButtonTapped() {
        autoListenTask?.cancel()                 // any manual action wins
        switch phase {
        case .idle: beginListening()
        case .listening: speech.stop()
        case .thinking, .speaking: cancelTurn(); beginListening()  // barge-in
        }
    }

    private func beginListening() {
        ensurePermissions { [weak self] ok in
            guard let self else { return }
            guard ok else { self.status = "需要麦克风 + 语音识别权限（在系统设置开启）"; return }
            self.startListeningNow()
        }
    }

    private func startListeningNow() {
        // STT locale may have changed in settings — rebuild if needed.
        speech.updateLocale(config.sttLocale)
        liveTranscript = ""
        phase = .listening
        status = "聆听中…"

        speech.onPartial = { [weak self] t in
            Task { @MainActor in self?.liveTranscript = t }
        }
        speech.onError = { [weak self] msg in
            Task { @MainActor in self?.status = msg; self?.phase = .idle }
        }
        speech.onFinal = { [weak self] text in
            Task { @MainActor in
                guard let self, self.phase == .listening else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                self.liveTranscript = ""
                if trimmed.isEmpty { self.phase = .idle; self.status = "没听到内容"; return }
                self.send(trimmed)
            }
        }
        speech.start()
    }

    // MARK: - Send (voice or typed)

    func sendTyped() {
        let t = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        autoListenTask?.cancel()
        textInput = ""
        if phase != .idle { cancelTurn() }
        send(t)
    }

    private func send(_ text: String) {
        let sid = ensureSession()
        store.appendMessage(StoredMessage(role: "user", text: text), to: sid)

        // Snapshot history (ends with the user message) for the request.
        let history = (store.session(sid)?.messages ?? [])
            .map { ChatMessage(role: $0.role, content: $0.text) }

        // Placeholder assistant message we stream into.
        let assistant = StoredMessage(role: "assistant", text: "")
        store.appendMessage(assistant, to: sid)

        phase = .thinking
        status = "思考中…"
        lastError = nil
        consumerDone = false

        startPipeline(sessionID: sid, assistantID: assistant.id, history: history)
    }

    // MARK: - Pipeline

    private func startPipeline(sessionID sid: UUID, assistantID: UUID,
                              history: [ChatMessage]) {
        // Capture provider + voice settings up front (read on main actor).
        let provider = LLMProviderFactory.make(kind: config.selectedProvider,
                                               settings: config.current,
                                               temperature: config.temperature)
        // Per-session prompt overrides the global default; reply-language hint
        // is always appended.
        let base = store.session(sid)?.systemPrompt ?? config.systemPrompt
        let system = base + "\n" + config.voiceLanguage.replyHint
        let serverURL = config.ttsServerURL
        let instruct = config.voiceLanguage.ttsInstruct

        let (stream, continuation) = AsyncStream<String>.makeStream()
        sentenceContinuation = continuation

        // Consumer: synthesize sentences one at a time, in order, and enqueue.
        consumerTask = Task { [weak self] in
            guard let self else { return }
            for await sentence in stream {
                if Task.isCancelled { break }
                // Skip fragments with nothing speakable (emoji / pure symbols /
                // punctuation) — the TTS model returns 500 "no audio" for them.
                guard let speak = Self.speakable(sentence) else { continue }
                do {
                    let wav = try await self.tts.synthesize(speak,
                                                            server: serverURL,
                                                            instruct: instruct)
                    if Task.isCancelled { break }
                    await MainActor.run {
                        self.lastError = nil
                        if self.phase == .thinking { self.phase = .speaking; self.status = "回答中…" }
                    }
                    self.player.enqueue(wav: wav)
                } catch {
                    let benign = (error as? URLError)?.code == .cancelled
                        || error.localizedDescription.contains("no audio")
                    if !benign {
                        await MainActor.run { self.lastError = "TTS: \(error.localizedDescription)" }
                    }
                }
            }
            await MainActor.run { self.consumerFinished() }
        }

        // Producer: stream the LLM, chunk to sentences, write text into the store.
        let chunker = SentenceChunker()
        llmTask = Task { [weak self] in
            guard let self else { return }
            var full = ""
            do {
                try await provider.stream(system: system, messages: history) { delta in
                    full += delta
                    let snapshot = full
                    Task { @MainActor in
                        self.store.updateMessageText(snapshot, messageID: assistantID, in: sid)
                    }
                    for s in chunker.push(delta) { self.sentenceContinuation?.yield(s) }
                }
            } catch {
                await MainActor.run { self.lastError = "AI 错误: \(error.localizedDescription)" }
            }
            if let rest = chunker.flush() { self.sentenceContinuation?.yield(rest) }
            self.sentenceContinuation?.finish()
            await MainActor.run { self.store.touchAndSave(sid) }
        }
    }

    private func cancelTurn() {
        llmTask?.cancel(); llmTask = nil
        consumerTask?.cancel(); consumerTask = nil
        sentenceContinuation?.finish(); sentenceContinuation = nil
        player.stop()
    }

    private func consumerFinished() {
        player.flush()            // release any clips still held by the prebuffer
        consumerDone = true
        if !player.hasPending { replyCompleted() }
    }

    private func audioDrained() {
        if consumerDone { replyCompleted() }
    }

    /// A reply fully finished (text + audio). Go idle, then — in continuous
    /// mode — reopen the mic shortly after so the user can just keep talking.
    private func replyCompleted() {
        guard phase == .thinking || phase == .speaking else { return }
        phase = .idle
        status = "就绪"
        guard config.continuousMode else { return }
        autoListenTask?.cancel()
        autoListenTask = Task { @MainActor in
            // brief gap so the speaker tail doesn't get captured as input
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled, self.phase == .idle, self.config.continuousMode
            else { return }
            self.beginListening()
        }
    }

    /// Generic return-to-idle for cancel / session-switch (no auto-listen).
    private func finishTurn() {
        guard phase != .idle else { return }
        phase = .idle
        status = "就绪"
    }

    // MARK: - Permissions

    /// Clean a fragment for TTS: drop emoji, markdown symbols, list markers and
    /// parenthetical asides. Returns nil if nothing speakable remains.
    static func speakable(_ s: String) -> String? {
        var out = ""
        var depth = 0          // inside （...) / (...) asides → skip
        for ch in s {
            if ch == "（" || ch == "(" { depth += 1; continue }
            if ch == "）" || ch == ")" { depth = max(0, depth - 1); continue }
            if depth > 0 { continue }
            if ch.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) { continue }
            if "*#`_~>|".contains(ch) { continue }      // markdown noise
            out.append(ch)
        }
        // strip leading list markers like "1. " / "- " / "• "
        var t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = t.first, first == "-" || first == "•" || first == "·" {
            t.removeFirst(); t = t.trimmingCharacters(in: .whitespaces)
        }
        guard t.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return t
    }

    private func ensurePermissions(_ done: @escaping (Bool) -> Void) {
        if permissionsOK { done(true); return }
        SpeechRecognizer.requestPermissions { [weak self] ok in
            Task { @MainActor in self?.permissionsOK = ok; done(ok) }
        }
    }
}
