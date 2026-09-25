import Foundation

/// Recoverable UI state only. No document bodies, prompts, transcripts,
/// credentials, shell commands, or executable work are ever stored here.
struct LimaRecoverySnapshot: Codable, Equatable, Sendable {
    var activeSurface: String?
    var activeWorkspaceModule: String?
    var selectedNoteID: UUID?
    var selectedConversationID: UUID?
    var formatterWasOpen: Bool
    var capturedAt: Date

    init(
        activeSurface: String? = nil,
        activeWorkspaceModule: String? = nil,
        selectedNoteID: UUID? = nil,
        selectedConversationID: UUID? = nil,
        formatterWasOpen: Bool = false,
        capturedAt: Date = Date()
    ) {
        self.activeSurface = activeSurface
        self.activeWorkspaceModule = activeWorkspaceModule
        self.selectedNoteID = selectedNoteID
        self.selectedConversationID = selectedConversationID
        self.formatterWasOpen = formatterWasOpen
        self.capturedAt = capturedAt
    }
}

@MainActor
final class CrashRecoveryStore: ObservableObject {
    static let shared = CrashRecoveryStore()

    @Published private(set) var pendingRestoration: LimaRecoverySnapshot?

    private enum Key {
        static let running = "lima.recovery.running"
        static let snapshot = "lima.recovery.snapshot"
    }

    private let defaults: UserDefaults
    private var snapshot = LimaRecoverySnapshot()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Call once at startup. A prior running marker means the process did not
    /// complete its normal termination path, so only safe UI state is offered.
    func beginLaunch() {
        let previousWasRunning = defaults.bool(forKey: Key.running)
        snapshot = Self.load(defaults) ?? LimaRecoverySnapshot()
        pendingRestoration = previousWasRunning ? snapshot : nil
        defaults.set(true, forKey: Key.running)
        persist()
    }

    func update(_ change: (inout LimaRecoverySnapshot) -> Void) {
        change(&snapshot)
        snapshot.capturedAt = Date()
        persist()
    }

    func discardPendingRestoration() {
        pendingRestoration = nil
    }

    func markCleanShutdown() {
        defaults.set(false, forKey: Key.running)
        pendingRestoration = nil
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Key.snapshot)
    }

    private static func load(_ defaults: UserDefaults) -> LimaRecoverySnapshot? {
        guard let data = defaults.data(forKey: Key.snapshot) else { return nil }
        return try? JSONDecoder().decode(LimaRecoverySnapshot.self, from: data)
    }
}
