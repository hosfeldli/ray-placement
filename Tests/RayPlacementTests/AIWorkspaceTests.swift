import Foundation
import Testing
@testable import RayPlacement

@Test func responsesTranscriptRebuildsRoleCorrectContinuityWithoutDuplicatingAttachments() throws {
    let history = [
        AIProviderMessage(role: .user, text: "We are planning a release."),
        AIProviderMessage(role: .assistant, text: "I will keep the release context."),
        AIProviderMessage(role: .user, text: "What should I verify next?")
    ]
    let attachment = AIAttachment(
        kind: .clipboard,
        displayName: "Release notes",
        text: "Validate checksums before publication."
    )

    let input = try AIInputEncoder.transcript(history, attachments: [attachment])
    #expect(input.map { $0["role"] as? String } == ["user", "assistant", "user"])

    let first = try #require(input[0]["content"] as? [[String: Any]])
    let assistant = try #require(input[1]["content"] as? [[String: Any]])
    let latest = try #require(input[2]["content"] as? [[String: Any]])
    #expect(first.count == 1)
    #expect(first[0]["type"] as? String == "input_text")
    #expect(assistant[0]["type"] as? String == "output_text")
    #expect(latest.count == 2)
    #expect(latest[0]["text"] as? String == "What should I verify next?")
    #expect((latest[1]["text"] as? String)?.contains("Release notes") == true)
}

@Test @MainActor func modelSwitchKeepsDurableConversationForExplicitContinuity() throws {
    let conversation = AIConversation(
        model: "gpt-5",
        lastResponseID: "response-before-switch",
        messages: [
            AIChatMessage(role: .user, text: "Remember this rollout plan."),
            AIChatMessage(role: .assistant, text: "I will use the rollout plan.")
        ]
    )
    let store = AIConversationStore(fixtures: [conversation])
    let model = AIChatViewModel(
        store: store,
        credentials: AIChatCredentialStore(configuration: .fixture),
        mcpStore: MCPServerStore(fixtures: []),
        nativeToolStore: LimaAIToolStore(fixtures: []),
        transport: FixtureAITransport.standard
    )

    model.selectModel(AIModelOption(id: "gpt-5-mini"))

    let updated = try #require(store.conversation(id: conversation.id))
    #expect(updated.lastResponseID == nil)
    #expect(updated.messages.map(\.text) == [
        "Remember this rollout plan.",
        "I will use the rollout plan."
    ])
    #expect(model.providerConnectionMessage?.contains("local history") == true)
}

@Test @MainActor func projectsAndMemoriesStayLocalAndScopeChatContext() throws {
    let workspace = AIWorkspaceStore(fixtures: [])
    let project = try #require(workspace.createProject(
        name: "Release planning",
        instructions: "Prefer verified release gates and concise status updates."
    ))
    let other = try #require(workspace.createProject(name: "Other work"))
    _ = try #require(workspace.createMemory(
        title: "Release preference",
        content: "Keep immutable tags and wait for green CI.",
        projectID: project.id
    ))
    _ = try #require(workspace.createMemory(
        title: "Global preference",
        content: "Use direct, task-oriented summaries.",
        projectID: nil
    ))
    _ = try #require(workspace.createMemory(
        title: "Unrelated",
        content: "Do not include this in release planning.",
        projectID: other.id
    ))

    let conversation = AIConversation(projectID: project.id)
    let model = AIChatViewModel(
        store: AIConversationStore(fixtures: [conversation]),
        credentials: AIChatCredentialStore(configuration: .fixture),
        mcpStore: MCPServerStore(fixtures: []),
        nativeToolStore: LimaAIToolStore(fixtures: []),
        transport: FixtureAITransport.standard,
        workspaceStore: workspace
    )

    #expect(model.selectedProject?.id == project.id)
    #expect(model.selectedProjectMemoryCount == 2)
    #expect(model.systemInstructions.contains("Release planning"))
    #expect(model.systemInstructions.contains("Keep immutable tags"))
    #expect(model.systemInstructions.contains("Use direct, task-oriented summaries."))
    #expect(!model.systemInstructions.contains("Do not include this in release planning."))

    model.assignProject(nil)
    #expect(model.selectedProject == nil)
    #expect(model.store.conversation(id: conversation.id)?.projectID == nil)
}

@Test @MainActor func capabilityGroupsRetainUnderlyingOptInPreferences() throws {
    let store = LimaAIToolStore(fixtures: LimaAIToolRegistry.defaultEnabledToolIDs)
    let groups = LimaAIToolGroup.visibleGroups(for: LimaAIToolRegistry.availableDefinitions)
    let browser = try #require(groups.first { $0.id == "browser" })
    let webResearch = try #require(groups.first { $0.id == "web-research" })

    #expect(store.isEnabled(webResearch))
    #expect(!store.isEnabled(browser))
    store.setEnabled(browser, enabled: true)
    #expect(store.isEnabled(browser))
    #expect(browser.toolIDs.allSatisfy(store.enabledToolIDs.contains))
    store.setEnabled(browser, enabled: false)
    #expect(!store.isEnabled(browser))
}

@Test @MainActor func modelSelectionRemainsAvailableDuringBackgroundCatalogUpdate() async throws {
    var transport = FixtureAITransport.standard
    transport.modelDiscoveryDelay = .seconds(10)
    let model = AIChatViewModel(
        store: AIConversationStore(fixtures: []),
        credentials: AIChatCredentialStore(configuration: .fixture),
        mcpStore: MCPServerStore(fixtures: []),
        nativeToolStore: LimaAIToolStore(fixtures: []),
        transport: transport
    )

    model.refreshModels()
    #expect(model.isLoadingModels)
    #expect(model.selectCustomModel("available-while-updating"))
    #expect(model.model == "available-while-updating")
    model.cancelModelDiscovery()
    for _ in 0..<100 where model.isLoadingModels {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!model.isLoadingModels)
}
