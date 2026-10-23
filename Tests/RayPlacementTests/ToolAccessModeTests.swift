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

@Test @MainActor func retiredWebChoicesMigrateToEmbeddedBrowserAuthority() throws {
    let suite = "ToolAccessLegacyWeb.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["search_web", "read_web"], forKey: "lima.ai.enabled-native-tools")
    defaults.set(LimaAIToolAccessMode.custom.rawValue, forKey: "lima.ai.tool-access-mode")

    let store = LimaAIToolStore(defaults: defaults)
    #expect(!store.enabledToolIDs.contains("search_web"))
    #expect(!store.enabledToolIDs.contains("read_web"))
    #expect(store.enabledToolIDs.isDisjoint(with: BrowserWorkspaceAITools.ids))
    #expect(store.effectiveEnabledToolIDs.isSuperset(of: BrowserWorkspaceAITools.ids))
    let persisted = Set(defaults.stringArray(forKey: "lima.ai.enabled-native-tools") ?? [])
    #expect(!persisted.contains("search_web") && !persisted.contains("read_web"))
    #expect(!persisted.contains("browser_search_web") && !persisted.contains("browser_open_tabs"))
    #expect(persisted.isDisjoint(with: BrowserWorkspaceAITools.ids))
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
    #expect(store.effectiveEnabledToolIDs.contains("browser_read"))
    #expect(AIComputerActionPolicy(defaults: defaults).enabledCategories == [.savedMemory])

    store.setAccessMode(.fullControl)
    #expect(store.effectiveEnabledToolIDs.contains("browser_read"))
    #expect(store.enabledToolIDs.isSuperset(of: ["read_file", "lima_capabilities"]))

    store.setAccessMode(.custom)
    #expect(store.effectiveEnabledToolIDs.contains("browser_read"))
    #expect(LimaAIToolStore(defaults: defaults).accessMode == .custom)
}

@Test @MainActor func existingCustomWorkspaceToolsGainWaitOnceWithoutCommandGrant() throws {
    let suite = "ToolAccessWorkspaceWait.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["terminal_status", "terminal_read"], forKey: "lima.ai.enabled-native-tools")
    defaults.set(LimaAIToolAccessMode.custom.rawValue, forKey: "lima.ai.tool-access-mode")
    for key in ["lima.ai.context-tools-v1", "lima.ai.computer-actions-v1",
                "lima.ai.browser-notes-read-v1", "lima.ai.workspace-terminal-v1",
                "lima.ai.browser-capabilities-v1", "lima.ai.tool-capabilities-v1"] {
        defaults.set(true, forKey: key)
    }

    let store = LimaAIToolStore(defaults: defaults)
    #expect(store.enabledToolIDs.contains("terminal_wait"))
    #expect(store.enabledToolIDs.contains("terminal_resize"))
    #expect(!store.enabledToolIDs.contains("terminal_run"))
    #expect(!AIComputerActionPolicy(defaults: defaults).enabledCategories.contains(.terminal))

    let wait = try #require(LimaAIToolRegistry.definition(for: "terminal_wait"))
    store.setEnabled(wait, enabled: false)
    let resize = try #require(LimaAIToolRegistry.definition(for: "terminal_resize"))
    store.setEnabled(resize, enabled: false)
    let reloaded = LimaAIToolStore(defaults: defaults)
    #expect(!reloaded.enabledToolIDs.contains("terminal_wait"))
    #expect(!reloaded.enabledToolIDs.contains("terminal_resize"))
}

@Test @MainActor func existingCustomToolsGainReviewableMemoryWritesOnce() throws {
    let suite = "ToolAccessMemoryWrites.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["memory_search"], forKey: "lima.ai.enabled-native-tools")
    defaults.set(LimaAIToolAccessMode.custom.rawValue, forKey: "lima.ai.tool-access-mode")
    for key in ["lima.ai.context-tools-v1", "lima.ai.computer-actions-v1",
                "lima.ai.browser-notes-read-v1", "lima.ai.workspace-terminal-v1",
                "lima.ai.workspace-terminal-wait-v1", "lima.ai.browser-capabilities-v1",
                "lima.ai.tool-capabilities-v1"] {
        defaults.set(true, forKey: key)
    }

    let store = LimaAIToolStore(defaults: defaults)
    #expect(store.enabledToolIDs.isSuperset(of: AIContextTools.memoryWriteIDs))
    let policy = AIComputerActionPolicy(defaults: defaults)
    #expect(policy.access(for: .savedMemory) == .askEveryTime)
    let save = try #require(LimaAIToolRegistry.definition(for: "memory_save"))
    #expect(policy.requiresApproval(for: save))
    #expect(!policy.permits(save, approvalGranted: false))
    store.setEnabled(save, enabled: false)
    let reloaded = LimaAIToolStore(defaults: defaults)
    #expect(!reloaded.enabledToolIDs.contains("memory_save"))
    #expect(reloaded.enabledToolIDs.contains("memory_update"))
    #expect(LimaAIToolGroup.coreGroups.first { $0.id == "memory-changes" }?.toolIDs
            == AIContextTools.memoryWriteIDs)
}

@Test @MainActor func preciseFileEditMigratesWithoutEnablingLocalWrites() throws {
    let suite = "ToolAccessExactEdit.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["read_file"], forKey: "lima.ai.enabled-native-tools")
    defaults.set(LimaAIToolAccessMode.custom.rawValue, forKey: "lima.ai.tool-access-mode")
    for key in ["lima.ai.context-tools-v1", "lima.ai.computer-actions-v1",
                "lima.ai.browser-notes-read-v1", "lima.ai.workspace-terminal-v1",
                "lima.ai.workspace-terminal-wait-v1", "lima.ai.browser-capabilities-v1",
                "lima.ai.tool-capabilities-v1", "lima.ai.memory-writes-v1"] {
        defaults.set(true, forKey: key)
    }

    let store = LimaAIToolStore(defaults: defaults)
    #expect(store.enabledToolIDs.contains("edit_text_file"))
    let policy = AIComputerActionPolicy(defaults: defaults)
    let edit = try #require(LimaAIToolRegistry.definition(for: "edit_text_file"))
    #expect(!policy.allows(edit))
    store.setEnabled(edit, enabled: false)
    #expect(!LimaAIToolStore(defaults: defaults).enabledToolIDs.contains("edit_text_file"))
}

@Test @MainActor func embeddedBrowserBypassesLegacyComputerActionCategories() throws {
    let suite = "ToolAccessBrowserAuthority.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let policy = AIComputerActionPolicy(defaults: defaults)
    let navigation = try #require(BrowserWorkspaceAITools.definitions.first { $0.id == "browser_navigate" })
    #expect(navigation.actionCategory == nil)
    #expect(!policy.requiresApproval(for: navigation, toolAccessMode: .automatic))
    #expect(!policy.requiresApproval(for: navigation, toolAccessMode: .askForActions))
    #expect(AIComputerActionCategory.allCases == [
        .localFiles, .savedMemory, .terminal, .screenshotHistory,
        .screenCapture, .audioOutput, .networkQuality, .calendar, .reminders
    ])
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
        #expect(routed.isSuperset(of: AIWorkspaceReadTools.ids))
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
    let memory = try #require(output["memory"] as? [String: Any])
    let terminal = try #require(output["terminal"] as? [String: Any])
    let browser = try #require(output["browser"] as? [String: Any])
    let workspace = try #require(output["workspace"] as? [String: Any])
    #expect(memory["read"] as? Bool == false)
    #expect(memory["save"] as? Bool == false)
    #expect(memory["write_requires_approval"] as? Bool == false)
    #expect(files["write_requires_approval"] as? Bool == false)
    #expect(terminal["requires_approval"] as? Bool == false)
    #expect(files["read"] as? Bool == true)
    #expect(files["search_text"] as? Bool == false)
    #expect(files["inspect_tree"] as? Bool == false)
    #expect(files["create_text"] as? Bool == false)
    #expect(terminal["available"] as? Bool == false)
    #expect(terminal["mode"] as? String == "unavailable")
    #expect(terminal["shared_workspace_session"] as? Bool == false)
    #expect(terminal["wait_for_verified_exit"] as? Bool == false)
    #expect(terminal["bounded_external_command"] as? Bool == false)
    #expect(terminal["visible_in_terminal"] as? Bool == false)
    #expect(terminal["bounded_external_network_policy"] as? String == "unavailable")
    #expect(browser["read"] as? Bool == true)
    #expect(browser["navigate"] as? Bool == false)
    #expect(browser["runtime"] as? String == "embedded_webkit")
    #expect(browser["ai_control"] as? String == BrowserWorkspaceModel.shared.aiControlMode.rawValue)
    #expect(browser["site_grant"] == nil)
    #expect(browser["bridge_connection"] == nil)
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
    #expect(routed.isSuperset(of: AIWorkspaceReadTools.ids))
    #expect(routed.contains("lima_capabilities"))
    #expect(!routed.isEmpty)
    #expect(routed.isSuperset(of: [
        "browser_navigate", "browser_click", "browser_submit",
        "memory_save", "create_text_file", "terminal_start", "terminal_run",
        "run_terminal_command"
    ]))
}

@Test @MainActor func fullControlOverridesDisabledCategoriesWithoutChangingSavedChoices() throws {
    let suite = "ToolAccessFullControl.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let policy = AIComputerActionPolicy(defaults: defaults)
    #expect(policy.access(for: .localFiles) == .disabled)
    #expect(policy.access(for: .terminal) == .disabled)

    for id in ["browser_navigate", "browser_click", "browser_submit",
               "memory_save", "create_text_file", "terminal_start", "terminal_run",
               "terminal_status", "run_terminal_command"] {
        let definition = try #require(LimaAIToolRegistry.definition(for: id))
        #expect(policy.allows(definition, toolAccessMode: .fullControl), "\(id) should be exposed")
        #expect(!policy.requiresApproval(for: definition, toolAccessMode: .fullControl), "\(id) should not ask in Lima")
        #expect(policy.permits(definition, approvalGranted: false, toolAccessMode: .fullControl), "\(id) should run without a Lima token")
    }

    let file = try #require(LimaAIToolRegistry.definition(for: "create_text_file"))
    #expect(!policy.allows(file, toolAccessMode: .automatic))
    #expect(!policy.permits(file, approvalGranted: false, toolAccessMode: .automatic))
    #expect(policy.access(for: .localFiles) == .disabled)
}
