import Foundation
import Testing
@testable import RayPlacement

@Test func subagentCapabilityBundleIsExplicitAndSanitized() {
    let bundle = AIContextTools.subagentCapabilityBundle
    #expect(bundle.contains("every Lima tool routed for the parent"))
    #expect(bundle.contains("including tools that can require user approval"))
    #expect(bundle.contains("pause for the parent user’s normal Lima approval"))
    #expect(bundle.contains("Recursive subagent delegation is unavailable"))
    #expect(!bundle.contains("Available tools: none"))

    let diagnostic = AIChatDiagnostic(stage: .delegation, message: AIContextTools.delegationCapabilityTrace)
    #expect(diagnostic.stage.rawValue == "delegation")
    #expect(diagnostic.message == AIContextTools.delegationCapabilityTrace)
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
        definition("terminal", .localAction, category: .terminal),
        definition("agent_delegate", .delegation)
    ]

    #expect(Set(AIContextTools.inheritedAgentTools(from: tools, actionPolicy: policy).map(\.id)) ==
            Set(["read", "memory", "navigation", "click", "submit", "local", "terminal"]))
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
        tool("search_web", .read),
        tool("read_web", .read),
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
    #expect(Set(bundle.localTools.map { $0.id }) == Set(["search_web", "read_web", "browser_open_tabs", "browser_submit", "run_terminal_command"]))

    let disabled = AIContextTools.subagentToolBundle(
        aiEnabled: false, enabledTools: candidateTools, actionPolicy: policy
    )
    #expect(disabled.localTools.isEmpty)
}
