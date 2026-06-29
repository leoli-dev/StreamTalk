import AVFoundation

/// Gapless playback of a queue of WAV clips (one per sentence) via an
/// AVAudioEngine player node.
///
/// To reduce choppiness when TTS can't always stay ahead of playback, clips
/// are held until a small prebuffer is reached (or the turn ends), giving a
/// cushion that absorbs jitter. Supports stop() for barge-in / cancellation.
final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var connectedFormat: AVAudioFormat?
    private let lock = NSLock()
    private var pending = 0
    private var generation = 0

    private var held: [AVAudioPCMBuffer] = []
    private var started = false
    private let prebufferTarget = 3   // wait for N clips before starting (smoother)

    /// Called on the main thread when the queue fully drains.
    var onIdle: (() -> Void)?

    var hasPending: Bool {
        lock.lock(); defer { lock.unlock() }
        return pending > 0 || !held.isEmpty
    }

    init() {
        engine.attach(player)
    }

    /// Append a clip. Starts playback once the prebuffer fills.
    func enqueue(wav: Data) {
        guard let buffer = Self.decode(wav: wav) else { return }
        ensureConnected(format: buffer.format)
        held.append(buffer)
        if started {
            scheduleHeld()
        } else if held.count >= prebufferTarget {
            started = true
            scheduleHeld()
            if !player.isPlaying { player.play() }
        }
    }

    /// Producer finished — release whatever's held even if below the prebuffer.
    func flush() {
        started = true
        scheduleHeld()
        if pendingCount() > 0, !player.isPlaying { player.play() }
    }

    /// Immediately stop and discard everything (barge-in).
    func stop() {
        lock.lock()
        generation += 1
        pending = 0
        held.removeAll()
        started = false
        lock.unlock()
        player.stop()
    }

    // MARK: - internals

    private func pendingCount() -> Int {
        lock.lock(); defer { lock.unlock() }; return pending
    }

    private func scheduleHeld() {
        let buffers = held
        held.removeAll()
        for buffer in buffers { schedule(buffer) }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        pending += 1
        let gen = generation
        lock.unlock()

        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) {
            [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            var done = false
            if gen == self.generation {
                self.pending -= 1
                if self.pending == 0 { self.started = false; done = true }
            }
            self.lock.unlock()
            if done { DispatchQueue.main.async { self.onIdle?() } }
        }
    }

    private func ensureConnected(format: AVAudioFormat) {
        guard connectedFormat == nil else { return }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        connectedFormat = format
        try? engine.start()
    }

    private static func decode(wav: Data) -> AVAudioPCMBuffer? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try wav.write(to: tmp)
            let file = try AVAudioFile(forReading: tmp)
            let frames = AVAudioFrameCount(file.length)
            guard frames > 0,
                  let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                             frameCapacity: frames)
            else { return nil }
            try file.read(into: buf)
            return buf
        } catch {
            return nil
        }
    }
}
