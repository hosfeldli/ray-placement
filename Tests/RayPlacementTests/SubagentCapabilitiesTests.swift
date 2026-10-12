import Foundation
import Testing
@testable import RayPlacement

@Test func subagentCapabilityBundleIsExplicitAndSanitized() {
    let bundle = AIContextTools.subagentCapabilityBundle
    #expect(bundle.contains("every Lima tool routed for the parent"))
    #expect(bundle.contains("In Full Control, actions do not need Lima per-action approval"))
    #expect(bundle.contains("in other modes, pause for the parent user when approval is required"))
    #expect(bundle.contains("Recursive subagent delegation is unavailable"))
    #expect(!bundle.contains("Available tools: none"))

    let diagnostic = AIChatDiagnostic(stage: .delegation, message: AIContextTools.delegationCapabilityTrace)
    #expect(diagnostic.stage.rawValue == "delegation")
    #expect(diagnostic.message == AIContextTools.delegationCapabilityTrace)
}

@Test @MainActor func subagentFullControlInheritsParentRoutedActionsWithoutSavedCategorySwitches() throws {
    let suite = "SubagentFullControl.\(UUID().uuidString)"
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
    #expect(Set(fullControl.map { $0.id }) == Set(names).subtracting(["agent_delegate"]))

    let automatic = AIContextTools.inheritedAgentTools(
        from: tools, actionPolicy: policy, toolAccessMode: .automatic
    )
    #expect(Set(automatic.map { $0.id }) == Set(["read_file", "search_workspace_text",
                                                  "inspect_directory_tree"]))
}

@Test @MainActor func subagentInheritsParentEnabledActionToolsAndExcludesRecursiveDelegation() {
    let suite = "SubagentAllTools.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let policy = AIComputerActionPolicy(defaults: defaults)
    policy.setAccess(.allowWithJournal, for: .browserNavigation)
    policy.setBrowserInteractionExperimentalEnabled(true)
    policy.setAccess(.askEveryTime, for: .browserInteraction)
    policy.setAccess(.askEveryTime, for: .localFiles)
    policy.setAccess(.askEveryTime, for: .savedMemory)
    policy.setAccess(.askEveryTime, for: .terminal)

    func definition(_ id: String, _ risk: AILocalToolRisk, category: AIComputerActionCategory? = nil) -> LimaAIToolDefinition {
        LimaAIToolDefinition(id: id, name: id, description: "fixture", parameters: [:], risk: risk, actionCategory: category)
    }
    let tools = [
        definition("read", .read), definition("memory", .read),
        definition("navigation", .navigation, category: .browserNavigation),
        definition("click", .write, category: .browserInteraction),
        definition("submit", .write, category: .browserInteraction),
        definition("local", .localAction, category: .localFiles),
        definition("memory_save", .write, category: .savedMemory),
        definition("terminal", .localAction, category: .terminal),
        definition("agent_delegate", .delegation)
    ]

    #expect(Set(AIContextTools.inheritedAgentTools(from: tools, actionPolicy: policy).map(\.id)) ==
            Set(["read", "memory", "navigation", "click", "submit", "local", "memory_save", "terminal"]))
}

@Test @MainActor func subagentNavigationRequiresTheParentNoApprovalMode() {
    let suite = "SubagentActionPolicy.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let policy = AIComputerActionPolicy(defaults: defaults)
    let navigation = LimaAIToolDefinition(
        id: "browser_open_tabs", name: "browser_open_tabs", description: "Open granted tabs.",
        parameters: [:], risk: .navigation, actionCategory: .browserNavigation
    )

    #expect(AIContextTools.inheritedAgentTools(from: [navigation], actionPolicy: policy).isEmpty)
    policy.setAccess(.askEveryTime, for: .browserNavigation)
    #expect(AIContextTools.inheritedAgentTools(from: [navigation], actionPolicy: policy).map(\.id) == ["browser_open_tabs"])
    policy.setAccess(.allowWithJournal, for: .browserNavigation)
    #expect(AIContextTools.inheritedAgentTools(from: [navigation], actionPolicy: policy).map(\.id) == ["browser_open_tabs"])
}

@Test @MainActor func subagentInheritsBrowserClickAndTypeOnlyWithJournalMode() {
    let suite = "SubagentInteractionPolicy.\\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let policy = AIComputerActionPolicy(defaults: defaults)
    let navigation = LimaAIToolDefinition(
        id: "browser_navigate_tab", name: "browser_navigate_tab", description: "Navigate a granted tab.",
        parameters: [:], risk: .navigation, actionCategory: .browserNavigation
    )
    let click = LimaAIToolDefinition(
        id: "browser_click", name: "browser_click", description: "Click an allowed control.",
        parameters: [:], risk: .write, actionCategory: .browserInteraction
    )
    let type = LimaAIToolDefinition(
        id: "browser_type", name: "browser_type", description: "Type in an allowed field.",
        parameters: [:], risk: .write, actionCategory: .browserInteraction
    )
    let submit = LimaAIToolDefinition(
        id: "browser_submit", name: "browser_submit", description: "Submit a form.",
        parameters: [:], risk: .write, actionCategory: .browserInteraction
    )
    let terminal = LimaAIToolDefinition(
        id: "run_terminal_command", name: "run_terminal_command", description: "Run a command.",
        parameters: [:], risk: .localAction, actionCategory: .terminal
    )
    let tools = [navigation, click, type, submit, terminal]

    #expect(AIContextTools.inheritedAgentTools(from: tools, actionPolicy: policy).isEmpty)
    policy.setAccess(.allowWithJournal, for: .browserNavigation)
    policy.setBrowserInteractionExperimentalEnabled(true)
    policy.setAccess(.askEveryTime, for: .browserInteraction)
    let inherited = AIContextTools.inheritedAgentTools(from: tools, actionPolicy: policy)
    #expect(Set(inherited.map(\.id)) == Set(["browser_navigate_tab", "browser_click", "browser_type", "browser_submit"]))
    policy.setAccess(.allowWithJournal, for: .browserInteraction)
    #expect(Set(AIContextTools.inheritedAgentTools(from: tools, actionPolicy: policy).map(\.id)) == Set(["browser_navigate_tab", "browser_click", "browser_type", "browser_submit"]))
}

@Test @MainActor func subagentToolBundleInheritsAllParentEnabledNativeTools() {
    let suite = "SubagentToolBundle.\\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let policy = AIComputerActionPolicy(defaults: defaults)

    func tool(_ id: String, _ risk: AILocalToolRisk, category: AIComputerActionCategory? = nil) -> LimaAIToolDefinition {
        LimaAIToolDefinition(id: id, name: id, description: "fixture", parameters: [:], risk: risk, actionCategory: category)
    }
    let candidateTools = [
        tool("browser_read", .read),
        tool("browser_scan", .read),
        tool("browser_open_tabs", .navigation, category: .browserNavigation),
        tool("browser_submit", .write, category: .browserInteraction),
        tool("run_terminal_command", .localAction, category: .terminal),
        tool("agent_delegate", .delegation)
    ]
    policy.setAccess(.allowWithJournal, for: .browserNavigation)
    policy.setBrowserInteractionExperimentalEnabled(true)
    policy.setAccess(.askEveryTime, for: .browserInteraction)
    policy.setAccess(.askEveryTime, for: .terminal)

    let bundle = AIContextTools.subagentToolBundle(
        aiEnabled: true, enabledTools: candidateTools, actionPolicy: policy
    )
    #expect(Set(bundle.localTools.map { $0.id }) == Set(["browser_read", "browser_scan", "browser_open_tabs", "browser_submit", "run_terminal_command"]))

    let disabled = AIContextTools.subagentToolBundle(
        aiEnabled: false, enabledTools: candidateTools, actionPolicy: policy
    )
    #expect(disabled.localTools.isEmpty)
}
