import Foundation
import RayPlacementCore

/// User-initiated workflow steps share stable IDs and one resolver. This
/// catalog intentionally does not expose computer-changing commands to AI.
enum LimaWorkflowBuiltin: String, CaseIterable {
    case openNotes = "builtin.notes"
    case openAI = "builtin.ai-chat"
    case openContext = "builtin.context-shelf"
    case openTerminal = "builtin.terminal"
    case createNote = "builtin.create-note"
    case captureClipboard = "builtin.capture-clipboard-note"

    var title: String {
        switch self {
        case .openNotes: "Open Notes"
        case .openAI: "Open AI"
        case .openContext: "Open Context Shelf"
        case .openTerminal: "Open Terminal"
        case .createNote: "Create Note"
        case .captureClipboard: "Capture Clipboard to Note"
        }
    }

    var detail: String {
        switch self {
        case .openNotes, .openAI, .openContext, .openTerminal: "Lima workspace"
        case .createNote: "Local note"
        case .captureClipboard: "Local note from current clipboard text"
        }
    }
}

struct LimaWorkflowCommand: Identifiable {
    enum Source {
        case builtin(LimaWorkflowBuiltin)
        case extensionCommand(LoadedExtensionCommand)
    }

    let id: String
    let title: String
    let detail: String
    let source: Source
}

enum LimaWorkflowCommandCatalog {
    /// Resolve IDs written by older workflow editors without rewriting or
    /// deleting a user's saved chain.
    private static let legacyBuiltinIDs: [String: LimaWorkflowBuiltin] = [
        "builtin.workflow.open-notes": .openNotes,
        "builtin.workflow.open-ai": .openAI,
        "builtin.workflow.open-context": .openContext,
        "builtin.workflow.open-terminal": .openTerminal,
        "builtin.workflow.create-note": .createNote,
        "builtin.workflow.capture-clipboard": .captureClipboard
    ]

    static func available(extensions: [LoadedExtensionCommand]) -> [LimaWorkflowCommand] {
        let builtins = LimaWorkflowBuiltin.allCases.map {
            LimaWorkflowCommand(id: $0.rawValue, title: $0.title, detail: $0.detail, source: .builtin($0))
        }
        let extensionCommands = extensions
            .filter { $0.command.action.type != .form }
            .map {
                LimaWorkflowCommand(
                    id: "extension.\($0.extensionID).\($0.command.id)",
                    title: $0.command.title,
                    detail: $0.extensionName,
                    source: .extensionCommand($0)
                )
            }
        return builtins + extensionCommands
    }

    static func resolve(_ id: String, extensions: [LoadedExtensionCommand]) -> LimaWorkflowCommand? {
        if let builtin = legacyBuiltinIDs[id] {
            return LimaWorkflowCommand(id: builtin.rawValue, title: builtin.title,
                                       detail: builtin.detail, source: .builtin(builtin))
        }
        return available(extensions: extensions).first { entry in
            if entry.id == id { return true }
            if case .extensionCommand(let command) = entry.source {
                return command.command.id == id
            }
            return false
        }
    }
}
