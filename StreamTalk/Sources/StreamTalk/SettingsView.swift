import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var config: Config

    private var sttOptions: [SpeechRecognizer.LocaleOption] {
        var opts = SpeechRecognizer.supportedLocaleOptions()
        if !opts.contains(where: { $0.id == config.sttLocale }) {
            opts.insert(.init(id: config.sttLocale, name: config.sttLocale), at: 0)
        }
        return opts
    }

    var body: some View {
        TabView {
            providerTab.tabItem { Label("AI 提供商", systemImage: "brain") }
            voiceTab.tabItem { Label("语音", systemImage: "waveform") }
            promptTab.tabItem { Label("提示词", systemImage: "text.bubble") }
        }
        .padding(20)
    }

    // MARK: - Providers

    private var providerTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("当前使用", selection: $config.selectedProvider) {
                ForEach(ProviderKind.allCases) { Text($0.displayName).tag($0) }
            }
            Divider()
            ForEach(ProviderKind.allCases) { kind in
                ProviderEditor(kind: kind, settings: config.binding(for: kind))
            }
            HStack {
                Text("温度 (temperature)")
                Slider(value: $config.temperature, in: 0...1.5)
                Text(String(format: "%.1f", config.temperature)).monospacedDigit()
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Voice

    private var voiceTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("回复语言（AI 语音 + 文字）", selection: $config.voiceLanguage) {
                ForEach(config.selectedTTSProvider.supportedLanguages) { Text($0.displayName).tag($0) }
            }
            Text("只控制 AI 怎么回（TTS 发音 + 文字语言），可选语言取决于下面选中的 TTS 提供商（如 MeloTTS 无粤语但多了西/法/日/韩）。你说什么语言由下面的「说话语言」单独控制，两者互不影响。")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("连续对话（AI 回复后自动开麦听下一句）", isOn: $config.continuousMode)
            Toggle("轻点左 Option 键开始/停止说话", isOn: $config.optionKeyToTalk)
            Text("全局生效需在「系统设置 → 隐私与安全性 → 辅助功能」里允许 StreamTalk（仅前台时无需授权）。")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            Picker("TTS 提供商", selection: $config.selectedTTSProvider) {
                ForEach(TTSProviderKind.allCases) { Text($0.displayName).tag($0) }
            }
            ForEach(TTSProviderKind.allCases) { kind in
                TTSProviderEditor(kind: kind, settings: config.ttsBinding(for: kind))
            }
            Text("每个 TTS 提供商单独配置地址与参数，直连内网 API（app 直接调，无需本机代理）。"
                 + "回复语言用作 CosyVoice 的 instruct 方言或 MeloTTS 的 language；STT 用系统自带，无地址。")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 2) {
                Text("说话语言（STT 识别）").font(.caption).foregroundStyle(.secondary)
                Picker("说话语言", selection: $config.sttLocale) {
                    ForEach(sttOptions) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
            }

            Text("你说话用的识别语言，和上面的回复语言独立。"
                 + "粤语选 yue-CN（联网识别，需要网络）；注意 zh-HK 其实偏普通话，不要用来识别粤语。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Prompt

    private var promptTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("系统提示词").font(.headline)
            TextEditor(text: $config.systemPrompt)
                .font(.body).frame(minHeight: 160).border(.quaternary)
            Text("实际发送时会自动附加当前语音语言的回复要求。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: text).textFieldStyle(.roundedBorder)
        }
    }
}

/// Editor for one provider's base URL / key / model.
struct ProviderEditor: View {
    let kind: ProviderKind
    @Binding var settings: ProviderSettings
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                labeled("地址", $settings.baseURL)
                labeled("API Key", $settings.apiKey)
                HStack(alignment: .bottom, spacing: 6) {
                    labeled("模型", $settings.model)
                    Menu {
                        ForEach(kind.suggestedModels, id: \.self) { m in
                            Button(m) { settings.model = m }
                        }
                    } label: { Image(systemName: "list.bullet") }
                        .frame(width: 28)
                }
            }
            .padding(.vertical, 4)
        } label: {
            Text(kind.displayName).font(.subheadline.weight(.medium))
        }
    }

    private func labeled(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            TextField(label, text: text).textFieldStyle(.roundedBorder)
        }
    }
}

/// Editor for one TTS provider's server URL / speed / provider-specific field.
struct TTSProviderEditor: View {
    let kind: TTSProviderKind
    @Binding var settings: TTSProviderSettings
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                labeled("地址", $settings.serverURL)
                HStack {
                    Text("语速").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: $settings.speed, in: 0.5...2.0)
                    Text(String(format: "%.1f", settings.speed)).monospacedDigit()
                }
                if kind.usesSpeaker {
                    labeled("说话人 speaker（可空，按语言自动选）", $settings.speaker)
                } else {
                    labeled("模式 mode（可空，用服务器默认）", $settings.mode)
                }
            }
            .padding(.vertical, 4)
        } label: {
            Text(kind.displayName).font(.subheadline.weight(.medium))
        }
    }

    private func labeled(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            TextField(label, text: text).textFieldStyle(.roundedBorder)
        }
    }
}
