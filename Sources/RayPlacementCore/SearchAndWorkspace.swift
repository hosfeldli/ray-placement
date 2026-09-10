import Foundation

public enum LimaSearchKind: String, Codable, CaseIterable, Sendable {
    case command, application, note, dictation, terminal, window, clipboard, file
}

public struct LimaSearchResult: Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: LimaSearchKind
    public let title: String
    public let subtitle: String
    public let keywords: [String]
    public let score: Double

    public init(id: String, kind: LimaSearchKind, title: String, subtitle: String, keywords: [String] = [], score: Double = 0) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.score = score
    }
}

public protocol LimaSearchProvider: Sendable {
    var kind: LimaSearchKind { get }
    func search(query: String) async -> [LimaSearchResult]
}



public struct WorkspaceState: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var activeWorkspace: String?
    public var notesSection: String?
    public var selectedNoteID: UUID?
    public var selectedDictationID: UUID?
    public var terminalSessionID: UUID?
    public var windowFrames: [String: String]
    public var dockMode: String?

    public init(schemaVersion: Int = 1, activeWorkspace: String? = nil, notesSection: String? = nil, selectedNoteID: UUID? = nil, selectedDictationID: UUID? = nil, terminalSessionID: UUID? = nil, windowFrames: [String: String] = [:], dockMode: String? = nil) {
        self.schemaVersion = schemaVersion
        self.activeWorkspace = activeWorkspace
        self.notesSection = notesSection
        self.selectedNoteID = selectedNoteID
        self.selectedDictationID = selectedDictationID
        self.terminalSessionID = terminalSessionID
        self.windowFrames = windowFrames
        self.dockMode = dockMode
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, activeWorkspace, notesSection, selectedNoteID, selectedDictationID
        case terminalSessionID, windowFrames, dockMode
        // Obsolete tester/workspace keys are intentionally omitted. Codable
        // ignores unknown keys, allowing old installations to start safely.
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        activeWorkspace = try container.decodeIfPresent(String.self, forKey: .activeWorkspace)
        notesSection = try container.decodeIfPresent(String.self, forKey: .notesSection)
        selectedNoteID = try container.decodeIfPresent(UUID.self, forKey: .selectedNoteID)
        selectedDictationID = try container.decodeIfPresent(UUID.self, forKey: .selectedDictationID)
        terminalSessionID = try container.decodeIfPresent(UUID.self, forKey: .terminalSessionID)
        windowFrames = try container.decodeIfPresent([String: String].self, forKey: .windowFrames) ?? [:]
        dockMode = try container.decodeIfPresent(String.self, forKey: .dockMode)
    }
}

public struct CommandProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Legacy allow-list. A nil value means all commands are enabled.
    public var enabledCommandIDs: Set<String>?
    /// New deny-list used by the profile editor without needing to know every
    /// command at the time a profile is created.
    public var disabledCommandIDs: Set<String>
    public var favoriteCommandIDs: Set<String>
    public var favoriteCommandOrder: [String]
    public var confirmationRequiredCommandIDs: Set<String>

    public init(id: UUID = UUID(), name: String, enabledCommandIDs: Set<String>? = nil, disabledCommandIDs: Set<String> = [], favoriteCommandIDs: Set<String> = [], favoriteCommandOrder: [String] = [], confirmationRequiredCommandIDs: Set<String> = []) {
        self.id = id
        self.name = name
        self.enabledCommandIDs = enabledCommandIDs
        self.disabledCommandIDs = disabledCommandIDs
        self.favoriteCommandIDs = favoriteCommandIDs
        self.favoriteCommandOrder = favoriteCommandOrder
        self.confirmationRequiredCommandIDs = confirmationRequiredCommandIDs
    }

    private enum CodingKeys: String, CodingKey { case id, name, enabledCommandIDs, disabledCommandIDs, favoriteCommandIDs, favoriteCommandOrder, confirmationRequiredCommandIDs }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Default"
        enabledCommandIDs = try container.decodeIfPresent(Set<String>.self, forKey: .enabledCommandIDs)
        disabledCommandIDs = try container.decodeIfPresent(Set<String>.self, forKey: .disabledCommandIDs) ?? []
        favoriteCommandIDs = try container.decodeIfPresent(Set<String>.self, forKey: .favoriteCommandIDs) ?? []
        favoriteCommandOrder = try container.decodeIfPresent([String].self, forKey: .favoriteCommandOrder) ?? []
        confirmationRequiredCommandIDs = try container.decodeIfPresent(Set<String>.self, forKey: .confirmationRequiredCommandIDs) ?? []
    }
}

public struct WorkflowDefinition: Codable, Equatable, Identifiable, Sendable {
    public struct Step: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        public var commandID: String
        public var continueOnFailure: Bool

        public init(id: UUID = UUID(), commandID: String, continueOnFailure: Bool = false) {
            self.id = id
            self.commandID = commandID
            self.continueOnFailure = continueOnFailure
        }
    }

    public var id: UUID
    public var name: String
    public var steps: [Step]
    public var favorite: Bool

    public init(id: UUID = UUID(), name: String, steps: [Step] = [], favorite: Bool = false) {
        self.id = id
        self.name = name
        self.steps = steps
        self.favorite = favorite
    }
}

public struct WorkflowExecutionReport: Codable, Equatable, Sendable {
    public struct StepResult: Codable, Equatable, Sendable {
        public let commandID: String
        public let succeeded: Bool
        public let message: String?

        public init(commandID: String, succeeded: Bool, message: String? = nil) {
            self.commandID = commandID
            self.succeeded = succeeded
            self.message = message
        }
    }

    public let workflowID: UUID
    public let startedAt: Date
    public let finishedAt: Date
    public let steps: [StepResult]

    public init(workflowID: UUID, startedAt: Date, finishedAt: Date, steps: [StepResult]) {
        self.workflowID = workflowID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.steps = steps
    }

    public var succeeded: Bool { steps.allSatisfy(\.succeeded) }
}

public struct WorkspaceProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var state: WorkspaceState
    public var favorite: Bool
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, state: WorkspaceState = WorkspaceState(), favorite: Bool = false, updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.state = state
        self.favorite = favorite
        self.updatedAt = updatedAt
    }
}

public enum UpdateArchiveEntryValidation {
    public static func validate(_ entry: String, rootName: String = "LimaUpdate") -> Bool {
        let normalized = entry.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        return !normalized.hasPrefix("/")
            && !normalized.contains("\0")
            && !components.contains("..")
            && components.first == rootName
    }
}
