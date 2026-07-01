import SwiftUI

struct MainView: View {
    @EnvironmentObject var vm: ChatViewModel
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var config: Config

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            ChatView()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: sessionSelection) {
            ForEach(store.sessions) { s in
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title).lineLimit(1)
                    Text("\(s.messages.count) 条消息")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .tag(s.id)
                .contextMenu {
                    Button("删除", role: .destructive) { store.delete(s.id) }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { vm.newChat() } label: { Image(systemName: "square.and.pencil") }
                    .help("新对话")
            }
        }
        .navigationTitle("对话")
    }

    private var sessionSelection: Binding<UUID?> {
        Binding(
            get: { vm.currentSessionID },
            set: { if let id = $0 { vm.selectSession(id) } }
        )
    }
}

// MARK: - Chat

struct ChatView: View {
    @EnvironmentObject var vm: ChatViewModel
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var config: Config
    @State private var showPrompt = false

    private var messages: [StoredMessage] {
        guard let id = vm.currentSessionID else { return [] }
        return store.session(id)?.messages ?? []
    }

    private var promptCustomized: Bool {
        guard let id = vm.currentSessionID else { return false }
        return store.session(id)?.systemPrompt != nil
    }

    /// Common STT input languages for the toolbar (full list lives in Settings).
    private var inputLocaleOptions: [SpeechRecognizer.LocaleOption] {
        let common = [("yue-CN", "粤语"), ("zh-CN", "普通话"), ("en-US", "English")]
        var opts = common.map { SpeechRecognizer.LocaleOption(id: $0.0, name: $0.1) }
        if !opts.contains(where: { $0.id == config.sttLocale }) {
            opts.append(.init(id: config.sttLocale, name: config.sttLocale))
        }
        return opts
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            inputBar
        }
        .toolbar { toolbarContent }
        .navigationTitle(store.session(vm.currentSessionID ?? UUID())?.title ?? "StreamTalk")
        .navigationSubtitle(statusText)
        // Sheet (not popover): presents reliably even when the prompt button
        // collapses into the toolbar's `>>` overflow menu on a narrow window.
        .sheet(isPresented: $showPrompt) {
            if let id = vm.currentSessionID {
                SessionPromptEditor(sessionID: id, isPresented: $showPrompt)
                    .environmentObject(store)
                    .environmentObject(config)
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { m in
                        MessageBubble(message: m)
                            .id(m.id)
                    }
                    if !vm.liveTranscript.isEmpty {
                        MessageBubble(message: StoredMessage(role: "user",
                                                             text: vm.liveTranscript))
                            .opacity(0.5)
                            .id("live")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .onChange(of: messages.last?.text) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: vm.liveTranscript) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            Button(action: { vm.talkButtonTapped() }) {
                Image(systemName: micIcon)
                    .font(.title2)
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.borderedProminent)
            .tint(micTint)
            .help("按一下说话（也可轻点左 Option 键）")

            TextField("输入消息，或按麦克风说话…", text: $vm.textInput, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit { vm.sendTyped() }

            Button(action: { vm.sendTyped() }) {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless)
            .disabled(vm.textInput.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(10)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button { config.continuousMode.toggle() } label: {
                Image(systemName: config.continuousMode
                      ? "infinity.circle.fill" : "infinity.circle")
            }
            .help(config.continuousMode ? "连续对话：开（回复后自动开麦）" : "连续对话：关")

            Picker("AI", selection: $config.selectedProvider) {
                ForEach(ProviderKind.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.menu).help("AI 提供商")

            Picker("说话语言", selection: $config.sttLocale) {
                ForEach(inputLocaleOptions) { Text("🎙 " + $0.name).tag($0.id) }
            }
            .pickerStyle(.menu).help("你说话的识别语言（STT 输入）")

            Picker("回复语言", selection: $config.voiceLanguage) {
                ForEach(config.selectedTTSProvider.supportedLanguages) {
                    Text("🔊 " + $0.displayName).tag($0)
                }
            }
            .pickerStyle(.menu)
            .help("AI 回复的语音/文字语言（\(config.selectedTTSProvider.displayName) 支持的语言）")

            Button { showPrompt = true } label: {
                Image(systemName: promptCustomized ? "text.bubble.fill" : "text.bubble")
            }
            .help("本对话的提示词")

            SettingsLink { Image(systemName: "gearshape") }
                .help("设置")
        }
    }

    private var micIcon: String {
        switch vm.phase {
        case .idle: return "mic.fill"
        case .listening: return "stop.fill"
        case .thinking, .speaking: return "hand.raised.fill"
        }
    }
    private var micTint: Color {
        switch vm.phase {
        case .idle: return .accentColor
        case .listening: return .red
        case .thinking, .speaking: return .orange
        }
    }
    private var phaseColor: Color {
        switch vm.phase {
        case .idle: return .gray
        case .listening: return .red
        case .thinking: return .orange
        case .speaking: return .green
        }
    }

    private var statusText: String {
        vm.lastError ?? vm.status
    }

    private var statusColor: Color {
        vm.lastError != nil ? .red : .secondary
    }
}

struct SessionPromptEditor: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var config: Config
    let sessionID: UUID
    @Binding var isPresented: Bool
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("本对话的提示词").font(.headline)
            Text("只影响这个对话。留空 = 用默认。可以给不同对话设不同人设/风格。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $text)
                .font(.body).frame(width: 380, height: 150).border(.quaternary)

            Text("默认提示词：\(config.systemPrompt)")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(3)

            HStack {
                Button("恢复默认") {
                    text = ""
                    store.setPrompt(nil, for: sessionID)
                    isPresented = false
                }
                Spacer()
                Button("保存") {
                    store.setPrompt(text, for: sessionID)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 410)
        .onAppear { text = store.session(sessionID)?.systemPrompt ?? "" }
    }
}

struct MessageBubble: View {
    let message: StoredMessage
    private var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            Text(message.text.isEmpty ? "…" : message.text)
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(isUser ? Color.accentColor.opacity(0.85)
                                   : Color.gray.opacity(0.18),
                            in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(isUser ? .white : .primary)
            if !isUser { Spacer(minLength: 40) }
        }
    }
}
