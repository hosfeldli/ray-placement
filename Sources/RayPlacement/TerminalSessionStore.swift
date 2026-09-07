import Foundation
import RayPlacementCore

struct TerminalSession: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var cwd: String
    var history: [String]
    var createdAt: Date
    var lastUsedAt: Date

    init(id: UUID = UUID(), name: String = "Local Shell", cwd: String = FileManager.default.homeDirectoryForCurrentUser.path, history: [String] = [], createdAt: Date = Date(), lastUsedAt: Date = Date()) {
        self.id = id; self.name = name; self.cwd = cwd; self.history = history; self.createdAt = createdAt; self.lastUsedAt = lastUsedAt
    }
}

@MainActor
final class TerminalSessionStore: ObservableObject {
    static let shared = TerminalSessionStore()
    @Published private(set) var sessions: [TerminalSession]
    @Published var selectedSessionID: UUID?
    @Published var lastError: String?
    private let url = ApplicationPaths.applicationSupport.appendingPathComponent("terminal-sessions.json")
    private let store = PrivateFileStore()

    private init() {
        let loaded = store.loadJSON([TerminalSession].self, from: url)
        sessions = loaded.value ?? [TerminalSession()]
        selectedSessionID = sessions.first?.id
        if loaded.result.state == .corrupt || loaded.result.state == .unreadable { lastError = "Terminal sessions could not be restored; a recovery copy was preserved." }
    }

    var selectedSession: TerminalSession? { sessions.first { $0.id == selectedSessionID } ?? sessions.first }

    @discardableResult
    func create(name: String = "Local Shell") -> TerminalSession {
        let session = TerminalSession(name: name)
        sessions.insert(session, at: 0); selectedSessionID = session.id; save(); return session
    }

    func select(_ id: UUID) { guard sessions.contains(where: { $0.id == id }) else { return }; selectedSessionID = id; touch(id) }
    func rename(_ id: UUID, name: String) { guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }; sessions[i].name = name; save() }
    func record(_ command: String, for id: UUID? = nil) {
        let identifier = id ?? selectedSessionID
        guard let identifier, let i = sessions.firstIndex(where: { $0.id == identifier }) else { return }
        let clean = command.trimmingCharacters(in: .whitespacesAndNewlines); guard !clean.isEmpty else { return }
        sessions[i].history.removeAll { $0 == clean }; sessions[i].history.insert(clean, at: 0); sessions[i].history = Array(sessions[i].history.prefix(100)); sessions[i].lastUsedAt = Date(); save()
    }
    func updateDirectory(_ cwd: String, for id: UUID? = nil) { let identifier = id ?? selectedSessionID; guard let identifier, let i = sessions.firstIndex(where: { $0.id == identifier }) else { return }; sessions[i].cwd = cwd; sessions[i].lastUsedAt = Date(); save() }
    func touch(_ id: UUID) { guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }; sessions[i].lastUsedAt = Date(); save() }
    func save() { do { try ApplicationPaths.prepare(); try store.write(sessions, to: url); lastError = nil } catch { lastError = error.localizedDescription } }
}
