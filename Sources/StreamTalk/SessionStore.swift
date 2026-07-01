import Foundation

/// Source of truth for chat sessions. Persists to a JSON file in
/// Application Support and publishes changes for the UI.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []

    private let fileURL: URL
    private var saveScheduled = false

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StreamTalk", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("sessions.json")
        load()
    }

    // MARK: - Queries

    func session(_ id: UUID) -> Session? { sessions.first { $0.id == id } }

    // MARK: - Mutations

    @discardableResult
    func newSession() -> UUID {
        let s = Session()
        sessions.insert(s, at: 0)
        scheduleSave()
        return s.id
    }

    func delete(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        scheduleSave()
    }

    func rename(_ id: UUID, to title: String) {
        guard let i = index(of: id) else { return }
        sessions[i].title = title
        scheduleSave()
    }

    /// Set (or clear, with nil/empty) the per-session system-prompt override.
    func setPrompt(_ text: String?, for id: UUID) {
        guard let i = index(of: id) else { return }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        sessions[i].systemPrompt = (trimmed?.isEmpty ?? true) ? nil : trimmed
        scheduleSave()
    }

    func appendMessage(_ message: StoredMessage, to id: UUID) {
        guard let i = index(of: id) else { return }
        sessions[i].messages.append(message)
        sessions[i].updatedAt = Date()
        // Auto-title from the first user message.
        if sessions[i].title == "新对话", message.role == "user" {
            sessions[i].title = String(message.text.prefix(20))
        }
        bumpToTop(i)
        scheduleSave()
    }

    /// Update the text of an in-flight assistant message (called per token).
    func updateMessageText(_ text: String, messageID: UUID, in sessionID: UUID) {
        guard let si = index(of: sessionID),
              let mi = sessions[si].messages.firstIndex(where: { $0.id == messageID })
        else { return }
        sessions[si].messages[mi].text = text
        // Don't persist on every token; persisted when the turn completes.
    }

    func touchAndSave(_ id: UUID) {
        if let i = index(of: id) { sessions[i].updatedAt = Date() }
        save()
    }

    // MARK: - Helpers

    private func index(of id: UUID) -> Int? { sessions.firstIndex { $0.id == id } }

    private func bumpToTop(_ i: Int) {
        guard i > 0 else { return }
        let s = sessions.remove(at: i)
        sessions.insert(s, at: 0)
    }

    // MARK: - Persistence

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.saveScheduled = false
            self?.save()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Session].self, from: data)
        else { return }
        sessions = decoded
    }
}
