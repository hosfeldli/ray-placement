import Foundation
import RayPlacementCore

/// Opaque AI-owned command sessions are visible in the Terminal workspace.
/// Starting, running, changing directory, and interrupting use the existing
/// Terminal action category and Lima approval flow. Reading an existing
/// session only returns output from that AI-owned session.
@MainActor
enum AIWorkspaceActionTools {
    static let actionIDs: Set<String> = [
        "terminal_start", "terminal_run", "terminal_set_directory", "terminal_interrupt", "terminal_close"
    ]
    static let readIDs: Set<String> = ["terminal_status", "terminal_read"]
    static let ids = actionIDs.union(readIDs)

    static let definitions: [LimaAIToolDefinition] = [
        definition(
            "terminal_start",
            "Start an AI-owned terminal session in the dedicated Lima Workspace. Optionally create a new named project workspace and operate in it immediately, or select an existing relative directory. Commands cannot write outside the workspace root or read unrelated home files, and network access is not granted. The session is visible in Lima's Terminal workspace.",
            properties: [
                "directory": ["type": "string", "description": "Optional existing relative directory inside the Lima Workspace. Omit for the root. Do not combine with new_workspace."],
                "new_workspace": ["type": "string", "description": "Optional new, visible project folder name to create under the Lima Workspace. Do not combine with directory."]
            ],
            required: [],
            action: true
        ),
        definition(
            "terminal_run",
            "Start one approved command in an AI Workspace session. The command runs under the workspace sandbox with no network access; output streams to the visible Terminal workspace. This tool returns immediately; poll terminal_read or terminal_status for completion and exit status. Do not put credentials in commands.",
            properties: [
                "session_id": ["type": "string", "description": "Opaque ID returned by terminal_start."],
                "command": ["type": "string", "description": "One command, at most 4096 UTF-8 bytes."],
                "timeout_seconds": ["type": "integer", "minimum": 1, "maximum": 900, "description": "Optional maximum run time, default 300 seconds."]
            ],
            required: ["session_id", "command"],
            action: true
        ),
        definition(
            "terminal_status",
            "Read the state, working directory, output cursor, and verified exit status of an AI Workspace terminal session. A launched command is not a successful command until its completed state and exit status confirm it.",
            properties: ["session_id": ["type": "string"]],
            required: ["session_id"],
            action: false
        ),
        definition(
            "terminal_read",
            "Read up to 32 KB of bounded output from an AI Workspace session, starting at an optional byte cursor. Output can be truncated; use next_byte to continue polling. This does not execute a command.",
            properties: [
                "session_id": ["type": "string"],
                "from_byte": ["type": "integer", "minimum": 0]
            ],
            required: ["session_id"],
            action: false
        ),
        definition(
            "terminal_interrupt",
            "Request cancellation of the active command in an AI Workspace session. The process result must still be checked with terminal_status; child processes may require separate review.",
            properties: ["session_id": ["type": "string"]],
            required: ["session_id"],
            action: true
        ),
        definition(
            "terminal_set_directory",
            "Set an idle AI Workspace session's working directory to an existing relative directory inside its workspace. Symlinks and paths outside the workspace are rejected.",
            properties: [
                "session_id": ["type": "string"],
                "directory": ["type": "string", "description": "Existing relative directory inside the Lima Workspace."]
            ],
            required: ["session_id", "directory"],
            action: true
        ),
        definition(
            "terminal_close",
            "Close an idle AI Workspace session and discard only its in-memory output. It does not delete workspace files or stop a running command.",
            properties: ["session_id": ["type": "string"]],
            required: ["session_id"],
            action: true
        )
    ]

    private static func definition(
        _ name: String,
        _ description: String,
        properties: [String: Any],
        required: [String],
        action: Bool
    ) -> LimaAIToolDefinition {
        LimaAIToolDefinition(
            id: name,
            name: name,
            description: description,
            parameters: [
                "type": "object",
                "properties": properties,
                "required": required,
                "additionalProperties": false
            ],
            risk: action ? .localAction : .read,
            actionCategory: action ? .terminal : nil
        )
    }

    static func execute(_ call: AIOutputItem, approvalGranted: Bool) -> LimaAIToolExecution {
        guard let definition = definitions.first(where: { $0.name == call.name }),
              AIComputerActionPolicy.shared.permits(definition, approvalGranted: approvalGranted) else {
            return .json(["error": "This AI Workspace action is disabled or still needs your approval."], isError: true)
        }
        guard let raw = call.arguments, raw.utf8.count <= 8_192,
              let data = raw.data(using: .utf8),
              let arguments = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              Set(arguments.keys).isSubset(of: Set((definition.parameters["properties"] as? [String: Any] ?? [:]).keys)) else {
            return .json(["error": "Invalid AI Workspace arguments."], isError: true)
        }
        let runtime = AIWorkspaceTerminalCoordinator.shared
        do {
            // The compatibility command already returned its bounded, sanitized
            // result. Its visible output is for the user, not a second AI read
            // channel that could bypass the older 64 KB result limit.
            if definition.id != "terminal_start" {
                let id = try sessionID(arguments)
                guard try !runtime.status(sessionID: id).isBoundedExternal else {
                    throw AIWorkspaceTerminalCoordinator.WorkspaceError.notWorkspaceSession
                }
            }
            switch definition.id {
            case "terminal_start":
                let directory: String?
                switch arguments["directory"] {
                case .some(.string(let value)): directory = value
                case .none, .some(.null): directory = nil
                default: return .json(["error": "directory must be a relative path."], isError: true)
                }
                let newWorkspace: String?
                switch arguments["new_workspace"] {
                case .some(.string(let value)): newWorkspace = value
                case .none, .some(.null): newWorkspace = nil
                default: return .json(["error": "new_workspace must be a new project folder name."], isError: true)
                }
                let snapshot = try runtime.start(directory: directory, newWorkspace: newWorkspace)
                return .json(payload(snapshot, root: true))

            case "terminal_run":
                let id = try sessionID(arguments)
                guard case .string(let command)? = arguments["command"] else {
                    return .json(["error": "command is required."], isError: true)
                }
                let timeout: Int
                switch arguments["timeout_seconds"] {
                case .none, .some(.null): timeout = 300
                case .some(.number(let value)) where value.isFinite && value.rounded() == value && (1...900).contains(value):
                    timeout = Int(value)
                default:
                    return .json(["error": "timeout_seconds must be an integer from 1 to 900."], isError: true)
                }
                let snapshot = try runtime.run(sessionID: id, command: command, timeoutSeconds: timeout)
                return .json(payload(snapshot).merging([
                    "launched": true,
                    "verified_success": false,
                    "next_step": "Poll terminal_read or terminal_status until the command finishes."
                ] as [String: Any], uniquingKeysWith: { _, new in new }))

            case "terminal_status":
                return .json(payload(try runtime.status(sessionID: sessionID(arguments))))

            case "terminal_read":
                let offset: Int?
                switch arguments["from_byte"] {
                case .none, .some(.null): offset = nil
                case .some(.number(let value)) where value.isFinite && value.rounded() == value && value >= 0 && value <= Double(Int.max):
                    offset = Int(value)
                default:
                    return .json(["error": "from_byte must be a nonnegative integer."], isError: true)
                }
                return .json(try runtime.read(sessionID: sessionID(arguments), from: offset))

            case "terminal_interrupt":
                let snapshot = try runtime.interrupt(sessionID: sessionID(arguments))
                return .json(payload(snapshot).merging([
                    "interrupt_requested": true,
                    "verified_stopped": false
                ] as [String: Any], uniquingKeysWith: { _, new in new }))

            case "terminal_set_directory":
                guard case .string(let directory)? = arguments["directory"] else {
                    return .json(["error": "directory is required."], isError: true)
                }
                let snapshot = try runtime.setDirectory(
                    sessionID: sessionID(arguments), relativeDirectory: directory
                )
                return .json(payload(snapshot))

            case "terminal_close":
                let id = try sessionID(arguments)
                try runtime.close(sessionID: id)
                return .json(["session_id": id.uuidString, "closed": true, "files_deleted": false])

            default:
                return .json(["error": "Unknown AI Workspace tool."], isError: true)
            }
        } catch {
            return .json(["error": error.localizedDescription], isError: true)
        }
    }

    private static func sessionID(_ arguments: [String: JSONValue]) throws -> UUID {
        guard case .string(let raw)? = arguments["session_id"], let id = UUID(uuidString: raw) else {
            throw AIWorkspaceTerminalCoordinator.WorkspaceError.unknownSession
        }
        return id
    }

    private static func payload(_ snapshot: AIWorkspaceTerminalSnapshot, root: Bool = false) -> [String: Any] {
        var output: [String: Any] = [
            "session_id": snapshot.id.uuidString,
            "working_directory": snapshot.directory,
            "state": snapshot.state.rawValue,
            "next_byte": snapshot.nextOutputByte,
            "first_available_byte": snapshot.firstOutputByte,
            "output_truncated": snapshot.outputTruncated,
            "exit_status": snapshot.exitStatus.map { $0 as Any } ?? NSNull(),
            "verified_success": snapshot.state == .completed && snapshot.exitStatus == 0
        ]
        if root {
            output["workspace_root"] = try? AIWorkspaceTerminalCoordinator.workspaceRoot(create: false).path
        }
        return output
    }
}
