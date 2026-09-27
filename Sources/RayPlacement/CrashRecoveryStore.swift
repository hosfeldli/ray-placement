import Foundation

/// Recoverable UI state only. No document bodies, prompts, transcripts,
/// credentials, shell commands, or executable work are ever stored here.
struct LimaRecoverySnapshot: Codable, Equatable, Sendable {
    var activeSurface: String?
    var activeWorkspaceModule: String?
    var selectedNoteID: UUID?
    var selectedConversationID: UUID?
    var formatterWasOpen: Bool
    /// Optional for compatibility with snapshots written before visibility tracking.
    var workspaceWasOpen: Bool?
    /// Metadata only: in-flight operations are never restored or resumed.
    var workWasActive: Bool?
    var capturedAt: Date

    init(
        activeSurface: String? = nil,
        activeWorkspaceModule: String? = nil,
        selectedNoteID: UUID? = nil,
        selectedConversationID: UUID? = nil,
        formatterWasOpen: Bool = false,
        workspaceWasOpen: Bool? = nil,
        workWasActive: Bool? = nil,
        capturedAt: Date = Date()
    ) {
        self.activeSurface = activeSurface
        self.activeWorkspaceModule = activeWorkspaceModule
        self.selectedNoteID = selectedNoteID
        self.selectedConversationID = selectedConversationID
        self.formatterWasOpen = formatterWasOpen
        self.workspaceWasOpen = workspaceWasOpen
        self.workWasActive = workWasActive
        self.capturedAt = capturedAt
    }
}

struct CrashRecoveryPlan: Equatable {
    let module: LimaWorkspaceModule
    let selectedNoteID: UUID?
    let selectedAIConversationID: UUID?
    let hadInterruptedWork: Bool

    static func make(
        from snapshot: LimaRecoverySnapshot,
        availableNoteIDs: Set<UUID>,
        availableAIConversationIDs: Set<UUID>
    ) -> Self? {
        let workspaceWasOpen = snapshot.workspaceWasOpen ?? (snapshot.activeSurface == LimaSurfaceID.workspace.rawValue)
        let formatterWasOpen = snapshot.formatterWasOpen || snapshot.activeSurface == LimaSurfaceID.formatter.rawValue
        guard workspaceWasOpen || formatterWasOpen else { return nil }

        let savedModule = snapshot.activeWorkspaceModule.flatMap(LimaWorkspaceModule.init(rawValue:))
        // Restoring the Terminal module would start a shell process; keep
        // recovery limited to passive UI state and switch it back to Notes.
        let module: LimaWorkspaceModule
        if formatterWasOpen {
            module = .formatter
        } else if let savedModule, savedModule != .terminal {
            module = savedModule
        } else {
            module = .notes
        }

        return Self(
            module: module,
            selectedNoteID: snapshot.selectedNoteID.flatMap { availableNoteIDs.contains($0) ? $0 : nil },
            selectedAIConversationID: snapshot.selectedConversationID.flatMap {
                availableAIConversationIDs.contains($0) ? $0 : nil
            },
            hadInterruptedWork: snapshot.workWasActive == true
        )
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
        // The prior value remains in pendingRestoration for interruption
        // reporting; the new process starts with no active work.
        snapshot.workWasActive = false
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
        snapshot.workWasActive = false
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
