import Foundation
import Testing
@testable import RayPlacement

@Test func subagentCapabilityBundleIsExplicitAndSanitized() {
    let bundle = AIContextTools.subagentCapabilityBundle
    #expect(bundle.contains("every Lima tool routed for the parent"))
    #expect(bundle.contains("Embedded Browser"))
    #expect(bundle.contains("live Browser AI Control"))
    #expect(bundle.contains("Recursive subagent delegation is unavailable"))
    #expect(!bundle.contains("Available tools: none"))

    let diagnostic = AIChatDiagnostic(stage: .delegation, message: AIContextTools.delegationCapabilityTrace)
    #expect(diagnostic.stage.rawValue == "delegation")
    #expect(diagnostic.message == AIContextTools.delegationCapabilityTrace)
}

@Test @MainActor func subagentInheritsParentRoutedBrowserActionsWithoutLegacyCategories() throws {
    let suite = "SubagentBrowserAuthority.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let policy = AIComputerActionPolicy(defaults: defaults)
    policy.setAccess(.disabled, for: .savedMemory)

    let names = ["read_file", "search_workspace_text", "inspect_directory_tree",
                 "browser_click", "memory_save", "terminal_start", "agent_delegate"]
    let tools = try names.map { try #require(LimaAIToolRegistry.definition(for: $0)) }
    let fullControl = AIContextTools.inheritedAgentTools(
        from: tools, actionPolicy: policy, toolAccessMode: .fullControl
    )
    #expect(Set(fullControl.map(\.id)) == Set(names).subtracting(["agent_delegate"]))

    let automatic = AIContextTools.inheritedAgentTools(
        from: tools, actionPolicy: policy, toolAccessMode: .automatic
    )
    #expect(Set(automatic.map(\.id)) == Set(["read_file", "search_workspace_text",
                                               "inspect_directory_tree", "browser_click"]))
}

@Test @MainActor func subagentBrowserAuthorityIsIndependentOfComputerActionCategories() throws {
    let suite = "SubagentAllTools.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let policy = AIComputerActionPolicy(defaults: defaults)
    policy.setAccess(.askEveryTime, for: .localFiles)
    policy.setAccess(.askEveryTime, for: .savedMemory)
    policy.setAccess(.askEveryTime, for: .terminal)

    let browserNames = ["browser_navigate", "browser_click", "browser_type", "browser_submit"]
    let browserTools = try browserNames.map { name in
        try #require(BrowserWorkspaceAITools.definitions.first { $0.id == name })
    }
    let file = try #require(LimaAIToolRegistry.definition(for: "create_text_file"))
    let terminal = try #require(LimaAIToolRegistry.definition(for: "run_terminal_command"))
    let delegate = try #require(LimaAIToolRegistry.definition(for: "agent_delegate"))
    let tools = browserTools + [file, terminal, delegate]

    for mode in [LimaAIToolAccessMode.automatic, .askForActions, .custom, .fullControl] {
        let inherited = AIContextTools.inheritedAgentTools(
            from: tools, actionPolicy: policy, toolAccessMode: mode
        )
        #expect(Set(inherited.map(\.id)) == Set(browserNames + ["create_text_file", "run_terminal_command"]))
    }
}

@Test @MainActor func subagentToolBundleInheritsParentEnabledEmbeddedBrowserTools() throws {
    let suite = "SubagentToolBundle.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let policy = AIComputerActionPolicy(defaults: defaults)
    policy.setAccess(.askEveryTime, for: .terminal)

    let names = ["browser_read", "browser_scan", "browser_new_tab", "browser_submit",
                 "run_terminal_command", "agent_delegate"]
    let candidates = try names.map { try #require(LimaAIToolRegistry.definition(for: $0)) }
    let bundle = AIContextTools.subagentToolBundle(
        aiEnabled: true, enabledTools: candidates, actionPolicy: policy,
        toolAccessMode: .automatic
    )
    #expect(Set(bundle.localTools.map(\.id)) == Set(names).subtracting(["agent_delegate"]))

    let disabled = AIContextTools.subagentToolBundle(
        aiEnabled: false, enabledTools: candidates, actionPolicy: policy
    )
    #expect(disabled.localTools.isEmpty)
}
