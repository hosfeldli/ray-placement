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
    #expect(store.enabledToolIDs.isSuperset(of: ["read_file", "lima_capabilities"]))
    #expect(store.enabledToolIDs.isSuperset(of: AIWorkspaceActionTools.ids))
    #expect(!store.effectiveEnabledToolIDs.contains("read_web"))
    #expect(AIComputerActionPolicy(defaults: defaults).enabledCategories.isEmpty)

    store.setAccessMode(.fullControl)
    #expect(store.effectiveEnabledToolIDs.contains("read_web"))
    #expect(store.enabledToolIDs.isSuperset(of: ["read_file", "lima_capabilities"]))

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

@Test @MainActor func capabilityInspectorReportsActualRoutedRuntimeNotModePromises() throws {
    let call = AIOutputItem(
        phase: .completed, apiType: "function_call", callID: "capabilities",
        name: "lima_capabilities", arguments: "{}"
    )
    let tools = ["read_file", "read_note", "browser_read"].compactMap {
        LimaAIToolRegistry.definition(for: $0)
    }
    #expect(tools.count == 3)
    let result = AIContextTools.capabilities(call, routedTools: tools, accessMode: .fullControl)
    #expect(!result.isError)
    let data = try #require(result.output.data(using: .utf8))
    let output = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let files = try #require(output["files"] as? [String: Any])
    let terminal = try #require(output["terminal"] as? [String: Any])
    let browser = try #require(output["browser"] as? [String: Any])
    let workspace = try #require(output["workspace"] as? [String: Any])
    #expect(files["read"] as? Bool == true)
    #expect(files["create_text"] as? Bool == false)
    #expect(terminal["available"] as? Bool == false)
    #expect(terminal["mode"] as? String == "unavailable")
    #expect(terminal["shared_workspace_session"] as? Bool == false)
    #expect(terminal["bounded_external_command"] as? Bool == false)
    #expect(terminal["visible_in_terminal"] as? Bool == false)
    #expect(terminal["bounded_external_network_policy"] as? String == "unavailable")
    #expect(browser["read"] as? Bool == true)
    #expect(browser["navigate"] as? Bool == false)
    #expect(browser["site_grant"] as? String == "not_checked")
    #expect(browser["bridge_connection"] as? String == "not_checked")
    #expect(workspace["ai_operable"] as? Bool == false)
}

@Test @MainActor func fullControlExposesEligibleToolsWithoutPerToolSelections() {
    let model = AIChatViewModel(
        store: AIConversationStore(fixtures: [AIConversation()]),
        credentials: AIChatCredentialStore(configuration: .fixture),
        nativeToolStore: LimaAIToolStore(fixtures: [], accessMode: .fullControl),
        transport: FixtureAITransport.standard
    )

    let routed = Set(model.routedNativeTools(for: "Explain this query").map(\.id))
    #expect(routed.contains("read_file"))
    #expect(routed.contains("lima_capabilities"))
    #expect(!routed.isEmpty)
}
