import Foundation
import Speech
import AVFoundation

/// On-device (when available) speech-to-text via Apple's Speech framework.
/// Push-to-talk style: start(), it streams partial results, and auto-stops
/// after a short silence — then delivers the final transcript.
final class SpeechRecognizer {
    private var recognizer: SFSpeechRecognizer?
    private var localeIdentifier: String
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: DispatchWorkItem?
    private var noSpeechTimer: DispatchWorkItem?
    private var lastTranscript = ""
    private var heardSpeech = false
    private var finished = false

    /// After speech starts, stop if no new words arrive for this long.
    var silenceTimeout: TimeInterval = 2.5
    /// Before any speech is heard, wait this long before giving up.
    var noSpeechTimeout: TimeInterval = 8.0

    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((String) -> Void)?

    init(localeIdentifier: String) {
        self.localeIdentifier = localeIdentifier
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
    }

    /// Rebuild the recognizer if the locale changed (e.g. user switched languages).
    func updateLocale(_ identifier: String) {
        guard identifier != localeIdentifier else { return }
        localeIdentifier = identifier
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier))
    }

    struct LocaleOption: Identifiable, Hashable {
        let id: String      // locale identifier, e.g. "yue-CN"
        let name: String    // localized display name
    }

    /// Locales the system can actually recognize, with friendly names.
    static func supportedLocaleOptions() -> [LocaleOption] {
        let loc = Locale.current
        let ids = Set(SFSpeechRecognizer.supportedLocales().map { $0.identifier })
        return ids.map { id in
            let n = loc.localizedString(forIdentifier: id) ?? id
            return LocaleOption(id: id, name: "\(n)  ·  \(id)")
        }
        .sorted { $0.name < $1.name }
    }

    static func requestPermissions(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { auth in
            guard auth == .authorized else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { mic in
                DispatchQueue.main.async { completion(mic) }
            }
        }
    }

    func start() {
        guard let recognizer, recognizer.isAvailable else {
            onError?("识别器不可用（检查语言包/网络）"); return
        }
        finished = false
        heardSpeech = false
        lastTranscript = ""

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            onError?("麦克风启动失败: \(error.localizedDescription)")
            return
        }

        // Wait for the user to actually start talking before counting silence.
        armNoSpeechTimer()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                if text != self.lastTranscript, !text.isEmpty {
                    self.lastTranscript = text
                    if !self.heardSpeech {
                        self.heardSpeech = true
                        self.noSpeechTimer?.cancel()
                    }
                    self.onPartial?(text)
                    self.armSilenceTimer()   // reset silence countdown on new words
                }
                if result.isFinal { self.finish() }
            }
            // Ignore errors until the user has actually spoken — the recognizer
            // emits transient "no speech" errors during the opening pause.
            if error != nil, self.heardSpeech { self.finish() }
        }
    }

    /// Manually stop (e.g. user tapped the button again).
    func stop() { finish() }

    private func armSilenceTimer() {
        silenceTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finish() }
        silenceTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + silenceTimeout, execute: work)
    }

    private func armNoSpeechTimer() {
        noSpeechTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finish() }
        noSpeechTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + noSpeechTimeout, execute: work)
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        silenceTimer?.cancel(); silenceTimer = nil
        noSpeechTimer?.cancel(); noSpeechTimer = nil

        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil

        let final = lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.main.async { self.onFinal?(final) }
    }
}
