import Foundation

struct AIExecutionProviderConfigurationSnapshot: Codable, Hashable, Sendable {
    let providerID: String
    let modelID: String
    let reasoningEffort: String
}

struct AIExecutionSubagentBudget: Codable, Equatable, Sendable {
    static let maximumConcurrentCeiling = 12
    static let standard = AIExecutionSubagentBudget(maximumConcurrent: 4)

    /// Bounds simultaneous work, not the number of useful sequential children.
    let maximumConcurrent: Int

    init(maximumConcurrent: Int) {
        self.maximumConcurrent = min(max(maximumConcurrent, 1), Self.maximumConcurrentCeiling)
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
    let recoveryEvent: AIProviderFailureEvent?

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
        retryability: Retryability = .manual,
        recoveryEvent: AIProviderFailureEvent? = nil
    ) {
        self.category = category
        self.originalRequestConfiguration = originalRequestConfiguration
        self.httpStatus = httpStatus.flatMap { (100...599).contains($0) ? $0 : nil }
        self.safeMessage = String(safeMessage.prefix(1_000))
        self.invalidParameter = invalidParameter.flatMap(AIProviderFailure.parameter)
        self.retryability = retryability
        self.recoveryEvent = recoveryEvent
    }

    private enum CodingKeys: String, CodingKey {
        case category, originalRequestConfiguration, httpStatus, safeMessage, invalidParameter, retryability, recoveryEvent
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
            retryability: try values.decodeIfPresent(Retryability.self, forKey: .retryability) ?? .manual,
            recoveryEvent: try values.decodeIfPresent(AIProviderFailureEvent.self, forKey: .recoveryEvent)
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
    case diagnosingFailure
    case recovering
    case waitingForProvider
    case waitingForConfiguration
    case resuming
    case waitingForApproval
    case waitingForUserInput
    case completed
    case failed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        case .preparing, .reasoning, .runningTools, .writing, .diagnosingFailure, .recovering,
             .waitingForProvider, .waitingForConfiguration, .resuming,
             .waitingForApproval, .waitingForUserInput: false
        }
    }

    var isActive: Bool { !isTerminal }

    /// Approval pauses execution without making the run appear to be actively streaming.
    var isStreaming: Bool {
        switch self {
        case .preparing, .reasoning, .runningTools, .writing, .recovering, .resuming: true
        case .diagnosingFailure, .waitingForProvider, .waitingForConfiguration,
             .waitingForApproval, .waitingForUserInput, .completed, .failed, .cancelled: false
        }
    }

    fileprivate func canTransition(to next: Self) -> Bool {
        if self == next { return true }
        if !isTerminal && next == .diagnosingFailure { return true }
        if [.diagnosingFailure, .recovering, .resuming].contains(self),
           [.recovering, .waitingForProvider, .waitingForConfiguration, .resuming,
            .reasoning, .runningTools, .writing, .completed, .failed, .cancelled].contains(next) {
            return true
        }
        if [.waitingForProvider, .waitingForConfiguration].contains(self),
           [.resuming, .recovering, .failed, .cancelled].contains(next) { return true }
        switch self {
        case .preparing:
            return [.reasoning, .runningTools, .writing, .waitingForProvider, .waitingForConfiguration,
                    .waitingForApproval, .waitingForUserInput, .completed, .failed, .cancelled].contains(next)
        case .reasoning:
            return [.runningTools, .writing, .waitingForApproval, .waitingForUserInput, .completed, .failed, .cancelled].contains(next)
        case .runningTools:
            return [.reasoning, .writing, .waitingForApproval, .waitingForUserInput, .completed, .failed, .cancelled].contains(next)
        case .writing:
            return [.reasoning, .runningTools, .waitingForApproval, .waitingForUserInput, .completed, .failed, .cancelled].contains(next)
        case .waitingForApproval:
            return [.reasoning, .runningTools, .writing, .failed, .cancelled].contains(next)
        case .waitingForUserInput:
            return [.runningTools, .failed, .cancelled].contains(next)
        case .diagnosingFailure, .recovering, .waitingForProvider, .waitingForConfiguration, .resuming:
            return false
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
    private(set) var pendingQuestion: AIUserQuestion?

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
        pendingQuestion = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, conversationID, userMessageID, assistantMessageID
        case providerConfigurationSnapshot, toolConfigurationSnapshot, startedAt
        case state, completedAt, failure, activities, subagents, subagentRequestsUsed, pendingQuestion
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        conversationID = try values.decode(UUID.self, forKey: .conversationID)
        userMessageID = try values.decode(UUID.self, forKey: .userMessageID)
        assistantMessageID = try values.decode(UUID.self, forKey: .assistantMessageID)
        providerConfigurationSnapshot = try values.decode(AIExecutionProviderConfigurationSnapshot.self, forKey: .providerConfigurationSnapshot)
        toolConfigurationSnapshot = try values.decode(AIExecutionToolConfigurationSnapshot.self, forKey: .toolConfigurationSnapshot)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        state = try values.decode(AIExecutionRunState.self, forKey: .state)
        completedAt = try values.decodeIfPresent(Date.self, forKey: .completedAt)
        failure = try values.decodeIfPresent(AIExecutionRunFailure.self, forKey: .failure)
        activities = try values.decodeIfPresent([AIAgentActivity].self, forKey: .activities) ?? []
        subagents = try values.decodeIfPresent([AIExecutionSubagent].self, forKey: .subagents) ?? []
        subagentRequestsUsed = try values.decodeIfPresent(Int.self, forKey: .subagentRequestsUsed) ?? 0
        pendingQuestion = try values.decodeIfPresent(AIUserQuestion.self, forKey: .pendingQuestion)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(conversationID, forKey: .conversationID)
        try values.encode(userMessageID, forKey: .userMessageID)
        try values.encode(assistantMessageID, forKey: .assistantMessageID)
        try values.encode(providerConfigurationSnapshot, forKey: .providerConfigurationSnapshot)
        try values.encode(toolConfigurationSnapshot, forKey: .toolConfigurationSnapshot)
        try values.encode(startedAt, forKey: .startedAt)
        try values.encode(state, forKey: .state)
        try values.encodeIfPresent(completedAt, forKey: .completedAt)
        try values.encodeIfPresent(failure, forKey: .failure)
        try values.encode(activities, forKey: .activities)
        try values.encode(subagents, forKey: .subagents)
        try values.encode(subagentRequestsUsed, forKey: .subagentRequestsUsed)
        try values.encodeIfPresent(pendingQuestion, forKey: .pendingQuestion)
    }

    var isActive: Bool { state.isActive }
    var isStreaming: Bool { state.isStreaming }

    mutating func reserveSubagentRequest() -> Int? {
        guard !state.isTerminal else { return nil }
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
        // Only a matching structured answer may resume a suspended question.
        // Incidental activity from another callback must not clear it.
        if state == .waitingForUserInput, pendingQuestion != nil,
           !nextState.isTerminal, nextState != .waitingForUserInput {
            return false
        }
        guard (nextState == .failed) == (nextFailure != nil) else { return false }
        if state == nextState { return true }

        state = nextState
        if nextState != .waitingForUserInput { pendingQuestion = nil }
        failure = nextFailure
        completedAt = nextState.isTerminal ? date : nil
        return true
    }

    mutating func beginQuestion(_ question: AIUserQuestion) -> Bool {
        guard question.runID == id, pendingQuestion == nil,
              transition(to: .waitingForUserInput) else { return false }
        pendingQuestion = question
        return true
    }

    mutating func resumeQuestion(_ questionID: UUID) -> Bool {
        guard let question = pendingQuestion, question.id == questionID else { return false }
        pendingQuestion = nil
        guard transition(to: .runningTools) else {
            pendingQuestion = question
            return false
        }
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
