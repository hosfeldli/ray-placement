import Foundation
import Testing
@testable import RayPlacement

private func planUpdate(revision: Int, status: String, evidence: String = "", reason: String = "") throws -> Data {
    try JSONSerialization.data(withJSONObject: ["expected_revision": revision, "reason": reason,
        "steps": [["id": "verify", "title": "Verify the result", "status": status, "evidence": evidence]]])
}

@Test func taskPlanRequiresStartedWorkEvidenceAndCurrentRevision() throws {
    #expect(throws: Error.self) { try AITaskPlanTool.apply(planUpdate(revision: 0, status: "completed", evidence: "Done"), to: nil) }
    let started = try AITaskPlanTool.apply(planUpdate(revision: 0, status: "in_progress"), to: nil)
    #expect(started.continuationReminder != nil)
    #expect(throws: Error.self) { try AITaskPlanTool.apply(planUpdate(revision: 0, status: "completed", evidence: "Checked"), to: started) }
    #expect(throws: Error.self) { try AITaskPlanTool.apply(planUpdate(revision: 1, status: "completed"), to: started) }
    let completed = try AITaskPlanTool.apply(planUpdate(revision: 1, status: "completed", evidence: "Verified the returned confirmation."), to: started)
    #expect(completed.completedCount == 1)
    #expect(completed.continuationReminder == nil)
    let blocked = try AITaskPlanTool.apply(planUpdate(revision: 1, status: "blocked", evidence: "Waiting for the user's date."), to: started)
    #expect(blocked.continuationReminder == nil)
    #expect(throws: Error.self) { try AITaskPlanTool.apply(planUpdate(revision: 2, status: "pending"), to: completed) }
}

@Test func taskPlanCannotSilentlyDropWorkAndPersistsWithItsMessage() throws {
    let plan = AITaskPlan(revision: 1, steps: [
        AITaskPlanStep(id: "verify", title: "Verify the result", status: .inProgress, evidence: ""),
        AITaskPlanStep(id: "report", title: "Report the outcome", status: .pending, evidence: "")])
    #expect(throws: Error.self) { try AITaskPlanTool.apply(planUpdate(revision: 1, status: "in_progress"), to: plan) }
    let revised = try AITaskPlanTool.apply(planUpdate(revision: 1, status: "in_progress", reason: "The user removed the reporting step."), to: plan)
    #expect(revised.steps.count == 1)
    var message = AIChatMessage(role: .assistant, text: "Working")
    let revision = message.renderRevision
    message.taskPlan = plan
    #expect(message.renderRevision > revision)
    let restored = try JSONDecoder().decode(AIChatMessage.self, from: JSONEncoder().encode(message))
    #expect(restored.taskPlan == plan)
    let legacy = AIChatMessage(role: .assistant, text: "Old answer")
    #expect(try JSONDecoder().decode(AIChatMessage.self, from: JSONEncoder().encode(legacy)).taskPlan == nil)
}

@Test @MainActor func searchAskModePreservesThePromptAndReturnsToSearch() {
    let model = LauncherViewModel(clipboard: ClipboardHistoryService(fixtures: []), scanApplications: false)
    model.query = "Find a reservation for two"
    model.beginAskingAI()
    #expect(model.isAskingAI)
    #expect(model.aiPrompt == "Find a reservation for two")
    #expect(model.query.isEmpty)
    #expect(model.searchPhase == .idle)
    model.handleEscape()
    #expect(!model.isAskingAI)
    #expect(model.aiPrompt == "Find a reservation for two")
}

@Test @MainActor func searchStartsAFreshRunningChatWithoutChangingExistingMessages() async throws {
    let previous = AIConversation(model: "gpt-5.6-terra", messages: [AIChatMessage(role: .user, text: "Earlier request")])
    let store = AIConversationStore(fixtures: [previous])
    let model = AIChatViewModel(store: store, credentials: AIChatCredentialStore(configuration: .fixture),
        nativeToolStore: LimaAIToolStore(fixtures: []),
        transport: FixtureAITransport(events: [.textDelta("New answer"), .completed("search-new")], interEventDelay: .milliseconds(80)))
    model.select(previous.id)
    #expect(model.startNewChat(prompt: "  A fresh request  "))
    let newID = try #require(model.selectedConversationID)
    #expect(newID != previous.id)
    #expect(model.canEndTask)
    #expect(!model.startNewChat(prompt: "Do not interrupt"))
    for _ in 0..<300 where model.canEndTask { try await Task.sleep(for: .milliseconds(20)) }
    #expect(store.conversation(id: newID)?.messages.first?.text == "A fresh request")
    #expect(store.conversation(id: newID)?.messages.last?.text == "New answer")
    #expect(store.conversation(id: previous.id)?.messages.count == 1)
}

private func workflowEvents(_ events: [AIChatStreamEvent]) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
    AsyncThrowingStream { continuation in
        events.forEach { continuation.yield($0) }
        continuation.finish()
    }
}

@Test @MainActor func unfinishedChecklistActuallyContinuesAndChecksOffBeforeFinalizing() async throws {
    let start = String(decoding: try planUpdate(revision: 0, status: "in_progress"), as: UTF8.self)
    let finish = String(decoding: try planUpdate(revision: 1, status: "completed", evidence: "Verified fixture result."), as: UTF8.self)
    var transport = FixtureAITransport(events: [])
    transport.replyStream = { input, _ in
        let continuing = input.contains("saved checklist still has unfinished work")
        return workflowEvents([.responseCreated(continuing ? "continue-plan" : "start-plan"),
            .outputItem(AIOutputItem(phase: .completed, apiType: "function_call", callID: continuing ? "finish-step" : "start-step",
                                    name: AITaskPlanTool.id, arguments: continuing ? finish : start)),
            .completed(continuing ? "continue-plan" : "start-plan")])
    }
    transport.toolOutputEvents = [.textDelta("Result checked."), .completed("after-plan")]
    let store = AIConversationStore(fixtures: [])
    let model = AIChatViewModel(store: store, credentials: AIChatCredentialStore(configuration: .fixture),
        nativeToolStore: LimaAIToolStore(fixtures: [AITaskPlanTool.id]), transport: transport)
    #expect(LimaAIToolRegistry.schemaValidationMessage(for: AITaskPlanTool.id) == nil)
    #expect(model.requestLocalTools(for: "Verify the work, then report.").contains { $0.id == AITaskPlanTool.id })
    #expect(model.startNewChat(prompt: "Verify the work, then report."))
    for _ in 0..<500 where model.canEndTask { try await Task.sleep(for: .milliseconds(20)) }
    #expect(!model.canEndTask)
    let response = try #require(model.selectedConversation?.messages.last)
    #expect(response.taskPlan?.revision == 2)
    #expect(response.taskPlan?.completedCount == 1)
    #expect(response.taskPlan?.continuationReminder == nil)
}

@Test @MainActor func unfinishedChecklistRemindersAreBoundedAndNeverAutoCompleteTasks() async throws {
    let start = String(decoding: try planUpdate(revision: 0, status: "in_progress"), as: UTF8.self)
    var transport = FixtureAITransport(events: [])
    transport.replyStream = { input, _ in
        if input.contains("saved checklist still has unfinished work") {
            return workflowEvents([.textDelta("Stopped early."), .completed("still-unfinished")])
        }
        return workflowEvents([.responseCreated("start"),
            .outputItem(AIOutputItem(phase: .completed, apiType: "function_call", callID: "start-plan",
                                    name: AITaskPlanTool.id, arguments: start)), .completed("start")])
    }
    transport.toolOutputEvents = [.textDelta("Stopped early."), .completed("after-plan")]
    let model = AIChatViewModel(store: AIConversationStore(fixtures: []), credentials: AIChatCredentialStore(configuration: .fixture),
        nativeToolStore: LimaAIToolStore(fixtures: [AITaskPlanTool.id]), transport: transport)
    #expect(model.startNewChat(prompt: "Verify the result"))
    for _ in 0..<400 where model.canEndTask { try await Task.sleep(for: .milliseconds(20)) }
    #expect(!model.canEndTask)
    #expect(model.selectedConversation?.messages.last?.taskPlan?.completedCount == 0)
    #expect(model.currentTaskState.title == "Tasks unfinished")
    #expect(model.selectedConversation?.messages.last?.text.components(separatedBy: "Stopped early.").count == 4)
}

@Test @MainActor func taskPlanMigratesOnceAndKeepsExplicitOffChoices() throws {
    let suite = "task-plan-migration-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["memory_search"], forKey: "lima.ai.enabled-native-tools")
    defaults.set(true, forKey: "lima.ai.context-tools-v1")
    let first = LimaAIToolStore(defaults: defaults)
    let tool = try #require(LimaAIToolRegistry.definition(for: AITaskPlanTool.id))
    #expect(first.enabledToolIDs.contains(tool.id))
    first.setEnabled(tool, enabled: false)
    #expect(!LimaAIToolStore(defaults: defaults).enabledToolIDs.contains(tool.id))
    #expect(!AIContextTools.inheritedAgentTools(from: [tool], toolAccessMode: .fullControl).contains { $0.id == tool.id })
}

@Test func savedChecklistSurvivesProviderHistoryAndRejectsOversizeUpdates() throws {
    let plan = AITaskPlan(revision: 1, steps: [AITaskPlanStep(id: "one", title: "Verify the result", status: .inProgress, evidence: "")])
    let history = AIProviderMessage.transcript([AIChatMessage(role: .assistant, text: "", taskPlan: plan)])
    #expect(history.count == 1)
    #expect(throws: Error.self) { try AITaskPlanTool.apply(Data(repeating: 0, count: 64_001), to: plan) }
}
