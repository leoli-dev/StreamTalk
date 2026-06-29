import Foundation

/// Splits a stream of LLM token deltas into speakable sentences as early as
/// possible, so TTS for sentence N starts while the LLM is still writing N+1.
///
/// Strategy: cut on strong punctuation always. For the *first* chunk of a reply
/// also cut on a soft punctuation (comma) once there's enough text, to get
/// audio playing as fast as possible. Force-flush very long runs.
final class SentenceChunker {
    private var buffer = ""
    private var emittedAny = false

    private let strong = Set("。！？!?…\n")
    private let soft = Set("，,、；;：:")
    private let firstChunkMinLen = 6
    private let maxLen = 60

    /// Append a delta and return any complete sentences now ready to speak.
    func push(_ delta: String) -> [String] {
        buffer += delta
        var out: [String] = []
        while let s = nextSentence() {
            out.append(s)
            emittedAny = true
        }
        return out
    }

    /// Return whatever is left at end of stream (may be a partial sentence).
    func flush() -> String? {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return rest.isEmpty ? nil : rest
    }

    private func nextSentence() -> String? {
        let chars = Array(buffer)

        // 1) Strong boundary anywhere.
        if let idx = chars.firstIndex(where: { strong.contains($0) }) {
            return cut(upToInclusive: idx, chars: chars)
        }

        // 2) Fast first chunk: cut on a comma so the reply starts speaking ASAP.
        if !emittedAny, chars.count >= firstChunkMinLen,
           let idx = chars.firstIndex(where: { soft.contains($0) }) {
            return cut(upToInclusive: idx, chars: chars)
        }

        // 3) Runaway protection: force a cut at the last soft break before maxLen.
        if chars.count >= maxLen {
            let window = chars.prefix(maxLen)
            if let idx = window.lastIndex(where: { soft.contains($0) }) {
                return cut(upToInclusive: idx, chars: chars)
            }
            return cut(upToInclusive: maxLen - 1, chars: chars)
        }

        return nil
    }

    private func cut(upToInclusive idx: Int, chars: [Character]) -> String? {
        let head = String(chars[0...idx])
        buffer = String(chars[(idx + 1)...])
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nextSentence() : trimmed
    }
}
