import Foundation
import Testing
@testable import RayPlacement

@Test func aiExecutionRunTransitionsThroughPausedAndTerminalStates() throws {
    let runID = UUID()
    let userMessageID = UUID()
    let assistantMessageID = UUID()
    let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    var run = AIExecutionRun(
        id: runID,
        conversationID: UUID(),
        userMessageID: userMessageID,
        assistantMessageID: assistantMessageID,
        providerConfigurationSnapshot: AIExecutionProviderConfigurationSnapshot(
            providerID: "openAI",
            modelID: "gpt-5",
            reasoningEffort: "medium"
        ),
        toolConfigurationSnapshot: AIExecutionToolConfigurationSnapshot(
            localToolIDs: ["read_file"]
        ),
        startedAt: startedAt
    )

    #expect(run.state == .preparing)
    #expect(run.isActive)
    #expect(run.isStreaming)
    #expect(run.completedAt == nil)

    let enteredReasoning = run.transition(to: .reasoning)
    let startedTools = run.transition(to: .runningTools)
    let pausedForApproval = run.transition(to: .waitingForApproval)
    #expect(enteredReasoning)
    #expect(startedTools)
    #expect(pausedForApproval)
    #expect(run.isActive)
    #expect(!run.isStreaming)

    let resumedTools = run.transition(to: .runningTools)
    let beganWriting = run.transition(to: .writing)
    let finishedAt = Date(timeIntervalSince1970: 1_700_000_020)
    let completed = run.transition(to: .completed, at: finishedAt)
    #expect(resumedTools)
    #expect(beganWriting)
    #expect(completed)
    #expect(run.state == .completed)
    #expect(!run.isActive)
    #expect(!run.isStreaming)
    #expect(run.completedAt == finishedAt)
    let rejectedTerminalMutation = run.transition(to: .cancelled)
    #expect(!rejectedTerminalMutation)
    #expect(run.state == .completed)

    let decoded = try JSONDecoder().decode(AIExecutionRun.self, from: JSONEncoder().encode(run))
    #expect(decoded == run)
}

@Test func aiExecutionRunRequiresSafeFailureAndRejectsInvalidTransitions() {
    var run = AIExecutionRun(
        conversationID: UUID(),
        userMessageID: UUID(),
        assistantMessageID: UUID(),
        providerConfigurationSnapshot: AIExecutionProviderConfigurationSnapshot(
            providerID: "openAI",
            modelID: "gpt-5",
            reasoningEffort: "medium"
        ),
        toolConfigurationSnapshot: AIExecutionToolConfigurationSnapshot(
            localToolIDs: []
        )
    )

    let rejectedMissingFailure = run.transition(to: .failed)
    #expect(!rejectedMissingFailure)
    #expect(run.state == .preparing)

    let failure = AIExecutionRunFailure(safeMessage: "The provider rejected this request.")
    let acceptedFailure = run.transition(to: .failed, failure: failure)
    #expect(acceptedFailure)
    #expect(run.state == .failed)
    #expect(run.failure == failure)
    #expect(run.completedAt != nil)
    let rejectedPostFailureTransition = run.transition(to: .reasoning)
    #expect(!rejectedPostFailureTransition)
}

@Test func subagentBudgetClampsLimitsAndReservesRequestsPerRun() {
    let aboveCeilings = AIExecutionSubagentBudget(maximumConcurrent: 50, maximumPerRun: 50)
    #expect(aboveCeilings.maximumConcurrent == AIExecutionSubagentBudget.maximumConcurrentCeiling)
    #expect(aboveCeilings.maximumPerRun == AIExecutionSubagentBudget.maximumPerRunCeiling)

    let perRunLimited = AIExecutionSubagentBudget(maximumConcurrent: 8, maximumPerRun: 2)
    #expect(perRunLimited.maximumConcurrent == 2)
    #expect(perRunLimited.maximumPerRun == 2)

    var run = AIExecutionRun(
        conversationID: UUID(),
        userMessageID: UUID(),
        assistantMessageID: UUID(),
        providerConfigurationSnapshot: AIExecutionProviderConfigurationSnapshot(
            providerID: "openAI",
            modelID: "gpt-5",
            reasoningEffort: "medium"
        ),
        toolConfigurationSnapshot: AIExecutionToolConfigurationSnapshot(
            localToolIDs: ["agent_delegate"],
            subagentBudget: perRunLimited
        )
    )
    let first = run.reserveSubagentRequest()
    let second = run.reserveSubagentRequest()
    let overBudget = run.reserveSubagentRequest()
    #expect(first == 1)
    #expect(second == 2)
    #expect(overBudget == nil)
    #expect(run.subagentRequestsUsed == 2)
}

@Test func aiExecutionRunRetainsStructuredActivityAndSubagentOutcomes() {
    var run = AIExecutionRun(
        conversationID: UUID(),
        userMessageID: UUID(),
        assistantMessageID: UUID(),
        providerConfigurationSnapshot: AIExecutionProviderConfigurationSnapshot(
            providerID: "openAI",
            modelID: "gpt-5",
            reasoningEffort: "medium"
        ),
        toolConfigurationSnapshot: AIExecutionToolConfigurationSnapshot(
            localToolIDs: ["agent_delegate"]
        )
    )
    let activity = AIAgentActivity(kind: .toolStarted, title: "read_file")
    let subagent = AIExecutionSubagent(
        id: "child-1",
        title: "Inspect the parser",
        providerID: "openAI",
        modelID: "gpt-5",
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        state: .running
    )

    run.appendActivity(activity)
    run.beginSubagent(subagent)
    run.finishSubagent(id: subagent.id, state: .completed, at: Date(timeIntervalSince1970: 1_700_000_005))

    #expect(run.activities == [activity])
    #expect(run.subagents.count == 1)
    #expect(run.subagents[0].state == .completed)
    #expect(run.subagents[0].completedAt == Date(timeIntervalSince1970: 1_700_000_005))
}
