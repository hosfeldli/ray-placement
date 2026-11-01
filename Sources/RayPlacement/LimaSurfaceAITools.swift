import Foundation

@MainActor
enum LimaSurfaceAITools {
    nonisolated static let ids: Set<String> = ["lima_surfaces", "lima_surface_open"]
    static var openSurface: ((LimaWorkspaceModule) -> Bool)?
    static let definitions: [LimaAIToolDefinition] = [
        LimaAIToolDefinition(id: "lima_surfaces", name: "lima_surfaces",
            description: "List Lima's implemented workspace surfaces, the selected surface, and which native tools to use for their content. Does not read private content or change focus.",
            parameters: ["type": "object", "properties": [:] as [String: Any], "required": [], "additionalProperties": false], risk: .read),
        LimaAIToolDefinition(id: "lima_surface_open", name: "lima_surface_open",
            description: "Open an existing Lima workspace surface so the user can see your work. Changes presentation only; use that surface's tools to read or edit its content. Reports actual workspace visibility.",
            parameters: ["type": "object", "properties": ["surface": ["type": "string", "enum": LimaWorkspaceModule.userFacingModules.map(\.rawValue)]],
                         "required": ["surface"], "additionalProperties": false], risk: .navigation)
    ]

    static func execute(_ call: AIOutputItem) -> LimaAIToolExecution {
        if call.name == "lima_surfaces" {
            let selected = WorkspaceStateRegistry.shared.state.activeModule.flatMap(LimaWorkspaceModule.init(rawValue:)) ?? .ai
            return .json([
                "selected_surface": [.home, .workflows].contains(selected) ? "ai" : selected.rawValue,
                "can_open": openSurface != nil,
                "surfaces": LimaWorkspaceModule.userFacingModules.map { ["id": $0.rawValue, "title": $0.title, "destination": $0.primaryDestination.rawValue, "content_tools": tools(for: $0)] }
            ])
        }
        guard call.name == "lima_surface_open", let raw = call.arguments?.data(using: .utf8), raw.count <= 1024,
              let args = try? JSONSerialization.jsonObject(with: raw) as? [String: String],
              Set(args.keys) == ["surface"], let value = args["surface"],
              let module = LimaWorkspaceModule(rawValue: value), LimaWorkspaceModule.userFacingModules.contains(module) else {
            return .json(["error": "Choose an implemented surface from lima_surfaces."], isError: true)
        }
        let visible = openSurface?(module) ?? false
        return .json(["surface": module.rawValue, "visible": visible,
                      "content_tools": tools(for: module)], isError: !visible)
    }

    private static func tools(for surface: LimaWorkspaceModule) -> String {
        switch surface {
        case .notes: return "Search and read Notes, then use reviewed note edit tools."
        case .ai: return "Conversation, project, memory, and scheduled task tools."
        case .browser: return "browser_tabs, browser_observe, navigation and interaction tools under live Browser access."
        case .terminal: return "terminal_sessions, terminal_read, terminal_run and process tools under Terminal access."
        case .context: return "lima_data_search and lima_data_read for saved context and captures; use native tools for private references."
        case .extensions: return "list_extensions and routed extension tools."
        case .home: return "lima_capabilities and current native Calendar, Reminders, Contacts, and workspace tools."
        case .clipboard, .dictation: return "lima_data_search and lima_data_read for saved text with Workspace data access."
        case .grammar, .formatter, .workflows:
            return "Use available tools reported by lima_capabilities. Opening a surface does not imply content access or start recording."
        }
    }
}
