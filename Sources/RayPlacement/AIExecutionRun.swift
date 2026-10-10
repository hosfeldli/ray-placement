import Foundation

struct AIExecutionProviderConfigurationSnapshot: Codable, Hashable, Sendable {
    let providerID: String
    let modelID: String
    let reasoningEffort: String
}

struct AIExecutionSubagentBudget: Codable, Equatable, Sendable {
    static let maximumConcurrentCeiling = 12
    static let maximumPerRunCeiling = 32
    static let standard = AIExecutionSubagentBudget(maximumConcurrent: 4, maximumPerRun: 12)

    let maximumConcurrent: Int
    let maximumPerRun: Int

    init(maximumConcurrent: Int, maximumPerRun: Int) {
        let boundedTotal = min(max(maximumPerRun, 1), Self.maximumPerRunCeiling)
        self.maximumPerRun = boundedTotal
        self.maximumConcurrent = min(max(maximumConcurrent, 1), min(Self.maximumConcurrentCeiling, boundedTotal))
    }
}

struct AIExecutionToolConfigurationSnapshot: Codable, Equatable, Sendable {
    let localToolIDs: [String]
    let subagentBudget: AIExecutionSubagentBudget

    init(
        localToolIDs: [String],
        subagentBudget: AIExecutionSubagentBudget = .standard
    ) {
        self.localToolIDs = localToolIDs
        self.subagentBudget = subagentBudget
    }
}

struct AIExecutionRunFailure: Codable, Hashable, Sendable {
    enum Category: String, Codable, Sendable {
        case invalidConfiguration
        case authentication
        case quotaExhausted
        case rateLimited
        case timedOut
        case transport
        case providerUnavailable
        case providerRejected
        case unknown
    }

    enum Retryability: String, Codable, Sendable {
        case safe
        case afterDelay
        case configurationChange
        case manual
    }

    let category: Category
    let originalRequestConfiguration: AIExecutionProviderConfigurationSnapshot
    let httpStatus: Int?
    /// A user-safe summary only. Never retain provider bodies, request data, or credentials here.
    let safeMessage: String
    let invalidParameter: String?
    let retryability: Retryability

    var provider: String { originalRequestConfiguration.providerID }
    var model: String { originalRequestConfiguration.modelID }

    init(
        category: Category = .unknown,
        originalRequestConfiguration: AIExecutionProviderConfigurationSnapshot = AIExecutionProviderConfigurationSnapshot(
            providerID: "unknown",
            modelID: "unknown",
            reasoningEffort: "medium"
        ),
        httpStatus: Int? = nil,
        safeMessage: String,
        invalidParameter: String? = nil,
        retryability: Retryability = .manual
    ) {
        self.category = category
        self.originalRequestConfiguration = originalRequestConfiguration
        self.httpStatus = httpStatus.flatMap { (100...599).contains($0) ? $0 : nil }
        self.safeMessage = String(safeMessage.prefix(1_000))
        self.invalidParameter = invalidParameter.flatMap(AIProviderFailure.parameter)
        self.retryability = retryability
    }

    private enum CodingKeys: String, CodingKey {
        case category, originalRequestConfiguration, httpStatus, safeMessage, invalidParameter, retryability
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            category: try values.decodeIfPresent(Category.self, forKey: .category) ?? .unknown,
            originalRequestConfiguration: try values.decodeIfPresent(
                AIExecutionProviderConfigurationSnapshot.self,
                forKey: .originalRequestConfiguration
            ) ?? AIExecutionProviderConfigurationSnapshot(
                providerID: "unknown",
                modelID: "unknown",
                reasoningEffort: "medium"
            ),
            httpStatus: try values.decodeIfPresent(Int.self, forKey: .httpStatus),
            safeMessage: try values.decode(String.self, forKey: .safeMessage),
            invalidParameter: try values.decodeIfPresent(String.self, forKey: .invalidParameter),
            retryability: try values.decodeIfPresent(Retryability.self, forKey: .retryability) ?? .manual
        )
    }
}

struct AIExecutionSubagent: Codable, Equatable, Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        case running
        case completed
        case failed
        case cancelled
    }

    let id: String
    let title: String
    let providerID: String
    let modelID: String
    let startedAt: Date
    var completedAt: Date?
    var state: State
}

enum AIExecutionRunState: String, Codable, CaseIterable, Sendable {
    case preparing
    case reasoning
    case runningTools
    case writing
    case waitingForApproval
    case completed
    case failed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        case .preparing, .reasoning, .runningTools, .writing, .waitingForApproval: false
        }
    }

    var isActive: Bool { !isTerminal }

    /// Approval pauses execution without making the run appear to be actively streaming.
    var isStreaming: Bool {
        switch self {
        case .preparing, .reasoning, .runningTools, .writing: true
        case .waitingForApproval, .completed, .failed, .cancelled: false
        }
    }

    fileprivate func canTransition(to next: Self) -> Bool {
        if self == next { return true }
        switch self {
        case .preparing:
            return [.reasoning, .runningTools, .writing, .waitingForApproval, .completed, .failed, .cancelled].contains(next)
        case .reasoning:
            return [.runningTools, .writing, .waitingForApproval, .completed, .failed, .cancelled].contains(next)
        case .runningTools:
            return [.reasoning, .writing, .waitingForApproval, .completed, .failed, .cancelled].contains(next)
        case .writing:
            return [.reasoning, .runningTools, .waitingForApproval, .completed, .failed, .cancelled].contains(next)
        case .waitingForApproval:
            return [.reasoning, .runningTools, .writing, .failed, .cancelled].contains(next)
        case .completed, .failed, .cancelled:
            return false
        }
    }
}

struct AIExecutionRun: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let conversationID: UUID
    let userMessageID: UUID
    let assistantMessageID: UUID
    let providerConfigurationSnapshot: AIExecutionProviderConfigurationSnapshot
    let toolConfigurationSnapshot: AIExecutionToolConfigurationSnapshot
    let startedAt: Date
    private(set) var state: AIExecutionRunState
    private(set) var completedAt: Date?
    private(set) var failure: AIExecutionRunFailure?
    var activities: [AIAgentActivity]
    var subagents: [AIExecutionSubagent]
    private(set) var subagentRequestsUsed: Int

    init(
        id: UUID = UUID(),
        conversationID: UUID,
        userMessageID: UUID,
        assistantMessageID: UUID,
        providerConfigurationSnapshot: AIExecutionProviderConfigurationSnapshot,
        toolConfigurationSnapshot: AIExecutionToolConfigurationSnapshot,
        startedAt: Date = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.userMessageID = userMessageID
        self.assistantMessageID = assistantMessageID
        self.providerConfigurationSnapshot = providerConfigurationSnapshot
        self.toolConfigurationSnapshot = toolConfigurationSnapshot
        self.startedAt = startedAt
        state = .preparing
        completedAt = nil
        failure = nil
        activities = []
        subagents = []
        subagentRequestsUsed = 0
    }

    var isActive: Bool { state.isActive }
    var isStreaming: Bool { state.isStreaming }

    mutating func reserveSubagentRequest() -> Int? {
        guard !state.isTerminal,
              subagentRequestsUsed < toolConfigurationSnapshot.subagentBudget.maximumPerRun else { return nil }
        subagentRequestsUsed += 1
        return subagentRequestsUsed
    }

    @discardableResult
    mutating func transition(
        to nextState: AIExecutionRunState,
        failure nextFailure: AIExecutionRunFailure? = nil,
        at date: Date = Date()
    ) -> Bool {
        guard state.canTransition(to: nextState) else { return false }
        guard (nextState == .failed) == (nextFailure != nil) else { return false }
        if state == nextState { return true }

        state = nextState
        failure = nextFailure
        completedAt = nextState.isTerminal ? date : nil
        return true
    }

    mutating func appendActivity(_ activity: AIAgentActivity) {
        activities.append(activity)
    }

    mutating func beginSubagent(_ subagent: AIExecutionSubagent) {
        guard !state.isTerminal else { return }
        if let index = subagents.firstIndex(where: { $0.id == subagent.id }) {
            subagents[index] = subagent
        } else {
            subagents.append(subagent)
        }
    }

    mutating func finishSubagent(id: String, state: AIExecutionSubagent.State, at date: Date = Date()) {
        guard !self.state.isTerminal,
              let index = subagents.firstIndex(where: { $0.id == id }) else { return }
        subagents[index].state = state
        subagents[index].completedAt = date
    }
}
