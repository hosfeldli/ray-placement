import Foundation
import Testing
@testable import RayPlacement

@Test @MainActor func freshToolAccessDefaultsStayAutomaticAfterMigration() throws {
    let suite = "ToolAccessFresh.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let first = LimaAIToolStore(defaults: defaults)
    #expect(first.accessMode == .automatic)
    #expect(defaults.string(forKey: "lima.ai.tool-access-mode") == LimaAIToolAccessMode.automatic.rawValue)
    #expect(first.enabledToolIDs.contains("lima_capabilities"))

    let reloaded = LimaAIToolStore(defaults: defaults)
    #expect(reloaded.accessMode == .automatic)
}

@Test @MainActor func existingToolChoicesStayCustomAndSurviveModeChanges() throws {
    let suite = "ToolAccessExisting.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["read_file"], forKey: "lima.ai.enabled-native-tools")
    for key in ["lima.ai.context-tools-v1", "lima.ai.computer-actions-v1",
                "lima.ai.browser-notes-read-v1", "lima.ai.browser-capabilities-v1"] {
        defaults.set(true, forKey: key)
    }

    let store = LimaAIToolStore(defaults: defaults)
    #expect(store.accessMode == .custom)
    #expect(store.enabledToolIDs == ["read_file", "lima_capabilities"])
    #expect(!store.effectiveEnabledToolIDs.contains("read_web"))
    #expect(AIComputerActionPolicy(defaults: defaults).enabledCategories.isEmpty)

    store.setAccessMode(.fullControl)
    #expect(store.effectiveEnabledToolIDs.contains("read_web"))
    #expect(store.enabledToolIDs == ["read_file", "lima_capabilities"])

    store.setAccessMode(.custom)
    #expect(!store.effectiveEnabledToolIDs.contains("read_web"))
    #expect(LimaAIToolStore(defaults: defaults).accessMode == .custom)
}

@Test @MainActor func askForActionsOverridesJournalButNotDisabledCategories() throws {
    let suite = "ToolAccessApprovals.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let policy = AIComputerActionPolicy(defaults: defaults)
    let navigation = LimaAIToolDefinition(
        id: "browser_navigate_tab", name: "browser_navigate_tab", description: "fixture",
        parameters: [:], risk: .navigation, actionCategory: .browserNavigation
    )

    policy.setAccess(.allowWithJournal, for: .browserNavigation)
    #expect(policy.allows(navigation))
    #expect(!policy.requiresApproval(for: navigation, toolAccessMode: .automatic))
    #expect(policy.requiresApproval(for: navigation, toolAccessMode: .askForActions))

    policy.setAccess(.disabled, for: .browserNavigation)
    #expect(!policy.allows(navigation))
}

@Test @MainActor func validAgentDoesNotHidePermittedTools() {
    let model = AIChatViewModel(
        store: AIConversationStore(fixtures: [AIConversation(agentID: "agent.writing")]),
        credentials: AIChatCredentialStore(configuration: .fixture),
        mcpStore: MCPServerStore(fixtures: []),
        nativeToolStore: LimaAIToolStore(fixtures: ["read_file"]),
        transport: FixtureAITransport.standard
    )

    #expect(model.selectedAgentConfiguration?.id == "agent.writing")
    #expect(model.routedNativeTools(for: "Read the Swift source file").contains { $0.id == "read_file" })
}

@Test @MainActor func automaticAndAskModesRouteEligibleReadsWithoutKeywords() {
    for mode in [LimaAIToolAccessMode.automatic, .askForActions] {
        let model = AIChatViewModel(
            store: AIConversationStore(fixtures: [AIConversation()]),
            credentials: AIChatCredentialStore(configuration: .fixture),
            mcpStore: MCPServerStore(fixtures: []),
            nativeToolStore: LimaAIToolStore(fixtures: [], accessMode: mode),
            transport: FixtureAITransport.standard
        )
        let routed = Set(model.routedNativeTools(for: "Explain this query").map(\.id))
        let alternative = Set(model.routedNativeTools(for: "Fix the browser and run tests").map(\.id))
        #expect(routed == alternative)
        #expect(routed.contains("read_file"))
        #expect(routed.contains("lima_capabilities"))
    }
}

@Test @MainActor func fullControlExposesEligibleToolsWithoutPerToolSelections() {
    let model = AIChatViewModel(
        store: AIConversationStore(fixtures: [AIConversation()]),
        credentials: AIChatCredentialStore(configuration: .fixture),
        mcpStore: MCPServerStore(fixtures: []),
        nativeToolStore: LimaAIToolStore(fixtures: [], accessMode: .fullControl),
        transport: FixtureAITransport.standard
    )

    let routed = Set(model.routedNativeTools(for: "Explain this query").map(\.id))
    #expect(routed.contains("read_file"))
    #expect(routed.contains("lima_capabilities"))
    #expect(!routed.isEmpty)
}
