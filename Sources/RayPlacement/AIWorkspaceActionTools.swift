import Foundation
import RayPlacementCore

/// AI Workspace Terminal sessions are visible in the Terminal workspace. The
/// one-shot command path and opt-in persistent PTY share the existing Terminal
/// action category; a PTY write requires the same live policy as other actions.
/// Reads remain bound to the originating conversation and AI-owned session.
@MainActor
enum AIWorkspaceActionTools {
    nonisolated static let actionIDs: Set<String> = [
        "terminal_start", "terminal_execute", "terminal_run", "terminal_write", "terminal_set_directory",
        "terminal_interrupt", "terminal_resize", "terminal_terminate", "terminal_kill", "terminal_close"
    ]
    nonisolated static let readIDs: Set<String> = ["terminal_sessions", "terminal_status", "terminal_read", "terminal_wait"]
    nonisolated static let ids = actionIDs.union(readIDs)

    static let definitions: [LimaAIToolDefinition] = [
        definition(
            "terminal_sessions",
            "List only the current conversation's AI-owned Terminal sessions, with state and work scope.",
            properties: [:], required: [], action: false
        ),
        definition(
            "terminal_start",
            "Start a Terminal session in an active materialized Project, or omit project_id for temporary Scratch work. Set interactive for a persistent visible PTY; otherwise use bounded terminal_run commands. A launched shell has the user's normal filesystem and network access; the Project or Scratch path is only its initial working directory. Tool Access and required Lima reviews still gate launch and input.",
            properties: [
                "project_id": ["type": "string", "description": "Optional active materialized Project UUID. Omit for transient Scratch work."],
                "directory": ["type": "string", "description": "Optional existing relative directory inside that Project. Omit for the Project or Scratch root."],
                "interactive": ["type": "boolean", "description": "Start a persistent shared PTY shell instead of an idle one-shot command session."]
            ],
            required: [],
            action: true
        ),
        definition(
            "terminal_execute",
            "Run an arbitrary shell command or multiline script in an existing absolute working directory, without first creating a session. Supports creating/editing files, pipelines, scripts, builds and tests with normal OS filesystem/network access. Reuse terminal_run for an existing session. Returns a conversation-owned visible session immediately; use terminal_wait to verify exit and read output. Full Control skips Lima review; other modes use Terminal access. A command starting is not proof of success.",
            properties: [
                "command": ["type": "string", "description": "Shell command or multiline script, up to 64 KiB UTF-8. Never include credentials."],
                "working_directory": ["type": "string", "description": "Existing absolute directory as a plain path; spaces and apostrophes allowed."],
                "timeout_seconds": ["type": "integer", "minimum": 1, "maximum": 900]
            ],
            required: ["command", "working_directory"], action: true
        ),
        definition(
            "terminal_run",
            "Start one bounded command in a non-interactive AI Workspace session under the active Tool Access mode. Full Control needs no Lima prompt; other modes require exact-call review. The command has the user's normal filesystem and network access; directory-scoped grants cannot cover unrestricted shells. Use terminal_wait to verify command exit. For persistent shells use terminal_start with interactive: true and terminal_write. Do not put credentials in commands.",
            properties: [
                "session_id": ["type": "string", "description": "Opaque ID returned by terminal_start."],
                "command": ["type": "string", "description": "Shell command or multiline script, at most 64 KiB UTF-8."],
                "timeout_seconds": ["type": "integer", "minimum": 1, "maximum": 900, "description": "Optional maximum run time, default 300 seconds."]
            ],
            required: ["session_id", "command"],
            action: true
        ),
        definition(
            "terminal_write",
            "Send up to 4096 UTF-8 bytes to a running shared AI Workspace PTY, including an optional newline or response to an interactive prompt. This is an action governed by Terminal access. It acknowledges input only; call terminal_wait or terminal_read to observe output and do not treat input acceptance as command success. Binary controls and escape sequences are rejected.",
            properties: [
                "session_id": ["type": "string"],
                "input": ["type": "string", "description": "Text or a command followed by a newline, at most 4096 UTF-8 bytes."]
            ],
            required: ["session_id", "input"],
            action: true
        ),
        definition(
            "terminal_status",
            "Read session state and output cursor. One-shot commands report verified exit status. A persistent PTY reports shell state only; use explicit output or other postconditions to verify an interactive command.",
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
            "terminal_wait",
            "Wait up to 20 seconds for a one-shot command to finish, or for a persistent PTY to emit new output or exit. Read up to 32 KB and return a byte cursor. PTY output is observation, not verified command success; use next_byte for later reads.",
            properties: [
                "session_id": ["type": "string"],
                "from_byte": ["type": "integer", "minimum": 0],
                "max_wait_seconds": ["type": "integer", "minimum": 1, "maximum": 20]
            ],
            required: ["session_id"],
            action: false
        ),
        definition(
            "terminal_interrupt",
            "Interrupt an active one-shot command, or send Ctrl-C to the foreground job in a shared PTY without closing the shell. Inspect terminal_status and output afterward.",
            properties: ["session_id": ["type": "string"]],
            required: ["session_id"],
            action: true
        ),
        definition(
            "terminal_resize",
            "Resize a running shared AI Workspace PTY to 20–500 columns and 5–200 rows. The result reads back the kernel PTY dimensions; verify `verified_size` before relying on the change. The visible Terminal may resize it again if its window changes.",
            properties: [
                "session_id": ["type": "string"],
                "columns": ["type": "integer", "minimum": 20, "maximum": 500],
                "rows": ["type": "integer", "minimum": 5, "maximum": 200]
            ],
            required: ["session_id", "columns", "rows"],
            action: true
        ),
        definition(
            "terminal_terminate",
            "Request termination of a running shared PTY shell. Call terminal_wait or terminal_status to observe its exit before terminal_close. This does not delete workspace files.",
            properties: ["session_id": ["type": "string"]],
            required: ["session_id"],
            action: true
        ),
        definition(
            "terminal_kill",
            "Immediately kill a running AI-owned Terminal session by session_id; never accept an arbitrary PID. Verify exit with terminal_status or terminal_wait, and inspect registered server ports separately.",
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
            "Close a stopped or idle AI Workspace session and discard its in-memory output. It does not delete workspace files or stop a running command or PTY; terminate those first.",
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

    /// An unrestricted shell cannot be confined by a working-directory grant.
    /// Keep the parser and grant APIs for existing sessions, but never use a
    /// directory grant to bypass an exact-call Terminal review.
    private static func runSessionID(_ call: AIOutputItem) -> UUID? {
        guard call.name == "terminal_run", let raw = call.arguments,
              raw.utf8.count <= 400_000, let data = raw.data(using: .utf8),
              let arguments = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              Set(arguments.keys).isSubset(of: ["session_id", "command", "timeout_seconds"]),
              case .string(let rawID)? = arguments["session_id"],
              case .string(let command)? = arguments["command"],
              !command.isEmpty, command.utf8.count <= AIWorkspaceTerminalCoordinator.maximumCommandBytes,
              !command.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) && ![9, 10, 13].contains(Int($0.value))
              }) else { return nil }
        switch arguments["timeout_seconds"] {
        case .none, .some(.null): break
        case .some(.number(let seconds)) where seconds.isFinite &&
            seconds.rounded() == seconds && (1...900).contains(seconds): break
        default: return nil
        }
        return UUID(uuidString: rawID)
    }

    static func directoryGrantPath(for call: AIOutputItem, conversationID: UUID,
                                   actionPolicy: AIComputerActionPolicy? = nil,
                                   runtime suppliedRuntime: AIWorkspaceTerminalCoordinator? = nil) -> String? {
        let policy = actionPolicy ?? .shared
        let runtime = suppliedRuntime ?? .shared
        _ = (call, conversationID, policy, runtime)
        return nil
    }

    static func hasApplicableDirectoryGrant(for call: AIOutputItem, conversationID: UUID,
                                            actionPolicy: AIComputerActionPolicy? = nil,
                                            runtime suppliedRuntime: AIWorkspaceTerminalCoordinator? = nil) -> Bool {
        _ = (call, conversationID, actionPolicy, suppliedRuntime)
        return false
    }

    @discardableResult
    static func grantDirectory(for call: AIOutputItem, conversationID: UUID,
                               expectedDirectory: String,
                               actionPolicy: AIComputerActionPolicy? = nil,
                               runtime suppliedRuntime: AIWorkspaceTerminalCoordinator? = nil) throws -> AIWorkspaceTerminalSnapshot {
        _ = (call, conversationID, expectedDirectory, actionPolicy, suppliedRuntime)
        throw AIWorkspaceTerminalCoordinator.WorkspaceError.invalidDirectory
    }

    static func execute(
        _ call: AIOutputItem,
        approvalGranted: Bool,
        actionPolicy: AIComputerActionPolicy? = nil,
        conversationID: UUID? = nil,
        runtime suppliedRuntime: AIWorkspaceTerminalCoordinator? = nil
    ) async -> LimaAIToolExecution {
        let policy = actionPolicy ?? .shared
        let runtime = suppliedRuntime ?? .shared
        guard let definition = definitions.first(where: { $0.name == call.name }) else {
            return AIToolFailure(.unsupportedOperation, message: "Unknown AI Workspace action.", recoverable: false).toolExecution()
        }
        guard let conversationID else {
            return AIToolFailure(.permissionDenied, message: "This AI Workspace action needs an originating conversation.", recoverable: false).toolExecution()
        }
        guard let raw = call.arguments, raw.utf8.count <= 400_000,
              let data = raw.data(using: .utf8),
              let arguments = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              Set(arguments.keys).isSubset(of: Set((definition.parameters["properties"] as? [String: Any] ?? [:]).keys)) else {
            return invalidArguments("Invalid AI Workspace arguments.")
        }
        let directoryGranted = hasApplicableDirectoryGrant(
            for: call, conversationID: conversationID, actionPolicy: policy, runtime: runtime
        )
        guard policy.permits(definition, approvalGranted: approvalGranted || directoryGranted) else {
            return AIToolFailure(.permissionDenied, message: "This AI Workspace action is disabled or still needs your approval.", recoverable: false).toolExecution()
        }
        do {
            // The compatibility command already returned its bounded, sanitized
            // result. Its visible output is for the user, not a second AI read
            // channel that could bypass the older 64 KB result limit.
            if !["terminal_start", "terminal_execute", "terminal_sessions"].contains(definition.id) {
                let id = try sessionID(arguments)
                let existing = try runtime.status(sessionID: id)
                guard !existing.isBoundedExternal else {
                    throw AIWorkspaceTerminalCoordinator.WorkspaceError.notWorkspaceSession
                }
                if !existing.belongs(to: conversationID) {
                    return AIToolFailure(.permissionDenied, message: "This AI Workspace session belongs to another conversation.", recoverable: false).toolExecution()
                }
            }
            switch definition.id {
            case "terminal_sessions":
                return .json(["sessions": runtime.sessions(for: conversationID)
                    .filter { !$0.isBoundedExternal }.map { payload($0) }])
            case "terminal_start":
                let directory: String?
                switch arguments["directory"] {
                case .some(.string(let value)): directory = value
                case .none, .some(.null): directory = nil
                default: return invalidArguments("directory must be a relative path.")
                }
                let projectID: UUID?
                switch arguments["project_id"] {
                case .some(.string(let rawID)):
                    guard let id = UUID(uuidString: rawID) else { return invalidArguments("project_id must be a Project UUID.") }
                    projectID = id
                case .none, .some(.null): projectID = nil
                default: return invalidArguments("project_id must be a Project UUID.")
                }
                let interactive: Bool
                switch arguments["interactive"] {
                case .none, .some(.null): interactive = false
                case .some(.bool(let value)): interactive = value
                default: return invalidArguments("interactive must be a boolean.")
                }
                let snapshot = try runtime.start(directory: directory, conversationID: conversationID,
                                                 interactive: interactive, projectID: projectID)
                let terminalVisible = runtime.revealAIForegroundSession(snapshot.id)
                return .json(payload(snapshot, root: true).merging([
                    "terminal_visible": terminalVisible,
                    "post_action_verified": (try? runtime.status(sessionID: snapshot.id)) != nil
                ] as [String: Any], uniquingKeysWith: { _, new in new }))

            case "terminal_execute":
                guard case .string(let command)? = arguments["command"], !command.isEmpty,
                      command.utf8.count <= AIWorkspaceTerminalCoordinator.maximumCommandBytes,
                      case .string(let path)? = arguments["working_directory"], path.hasPrefix("/"),
                      path.utf8.count <= 4096,
                      !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    return invalidArguments("Provide a command of at most 64 KiB and an existing absolute working_directory.")
                }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    return invalidArguments("working_directory does not exist or is not a directory.")
                }
                let timeout: Int
                switch arguments["timeout_seconds"] {
                case .none, .some(.null): timeout = 300
                case .some(.number(let value)) where value.isFinite && value.rounded() == value && (1...900).contains(value):
                    timeout = Int(value)
                default: return invalidArguments("timeout_seconds must be an integer from 1 to 900.")
                }
                let started = try runtime.start(conversationID: conversationID)
                do {
                    let launched = try runtime.run(sessionID: started.id, command: command, timeoutSeconds: timeout,
                        workingDirectory: URL(fileURLWithPath: path, isDirectory: true))
                    let visible = runtime.revealAIForegroundSession(launched.id)
                    return .json(payload(launched).merging([
                        "launched": true, "working_directory": path, "terminal_visible": visible,
                        "verified_success": false,
                        "next_step": "Use terminal_wait with session_id to verify exit and inspect output. Reuse this session with terminal_run, or close it when no longer needed."
                    ] as [String: Any], uniquingKeysWith: { _, new in new }))
                } catch {
                    try? runtime.close(sessionID: started.id)
                    throw error
                }

            case "terminal_run":
                let id = try sessionID(arguments)
                guard case .string(let command)? = arguments["command"] else {
                    return invalidArguments("command is required.")
                }
                let timeout: Int
                switch arguments["timeout_seconds"] {
                case .none, .some(.null): timeout = 300
                case .some(.number(let value)) where value.isFinite && value.rounded() == value && (1...900).contains(value):
                    timeout = Int(value)
                default:
                    return invalidArguments("timeout_seconds must be an integer from 1 to 900.")
                }
                let snapshot = try runtime.run(sessionID: id, command: command, timeoutSeconds: timeout)
                return .json(payload(snapshot).merging([
                    "launched": true,
                    "verified_success": false,
                    "next_step": "Use terminal_wait to read output and verify the command's exit status."
                ] as [String: Any], uniquingKeysWith: { _, new in new }))

            case "terminal_write":
                guard case .string(let input)? = arguments["input"] else {
                    return invalidArguments("input is required.")
                }
                return .json(try runtime.write(sessionID: sessionID(arguments), input: input))

            case "terminal_status":
                return .json(payload(try runtime.status(sessionID: sessionID(arguments))))

            case "terminal_read":
                let offset: Int?
                switch arguments["from_byte"] {
                case .none, .some(.null): offset = nil
                case .some(.number(let value)) where value.isFinite && value.rounded() == value && value >= 0 && value <= Double(Int.max):
                    offset = Int(value)
                default:
                    return invalidArguments("from_byte must be a nonnegative integer.")
                }
                return .json(try runtime.read(sessionID: sessionID(arguments), from: offset))

            case "terminal_wait":
                let offset: Int?
                switch arguments["from_byte"] {
                case .none, .some(.null): offset = nil
                case .some(.number(let value)) where value.isFinite && value.rounded() == value && value >= 0 && value <= Double(Int.max):
                    offset = Int(value)
                default:
                    return invalidArguments("from_byte must be a nonnegative integer.")
                }
                let maxWait: Int
                switch arguments["max_wait_seconds"] {
                case .none, .some(.null): maxWait = 20
                case .some(.number(let value)) where value.isFinite && value.rounded() == value && (1...20).contains(value):
                    maxWait = Int(value)
                default:
                    return invalidArguments("max_wait_seconds must be an integer from 1 to 20.")
                }
                return .json(try await runtime.wait(
                    sessionID: sessionID(arguments), from: offset, maxWaitSeconds: maxWait
                ))

            case "terminal_interrupt":
                let snapshot = try runtime.interrupt(sessionID: sessionID(arguments))
                return .json(payload(snapshot).merging([
                    "interrupt_requested": true,
                    "verified_stopped": false
                ] as [String: Any], uniquingKeysWith: { _, new in new }))

            case "terminal_resize":
                guard case .number(let columns)? = arguments["columns"],
                      case .number(let rows)? = arguments["rows"],
                      columns.isFinite, rows.isFinite,
                      columns.rounded() == columns, rows.rounded() == rows,
                      (20...500).contains(columns), (5...200).contains(rows) else {
                    return invalidArguments("columns must be 20–500 and rows must be 5–200, both integers.")
                }
                return .json(try runtime.resize(sessionID: sessionID(arguments),
                                                columns: Int(columns), rows: Int(rows)))

            case "terminal_terminate":
                let snapshot = try runtime.terminate(sessionID: sessionID(arguments))
                return .json(payload(snapshot).merging([
                    "terminate_requested": true,
                    "verified_stopped": false
                ] as [String: Any], uniquingKeysWith: { _, new in new }))

            case "terminal_kill":
                let snapshot = try runtime.forceKill(sessionID: sessionID(arguments))
                return .json(payload(snapshot).merging([
                    "kill_requested": true,
                    "verified_stopped": false,
                    "next_step": "Use terminal_status and server_status to verify exit and port closure."
                ] as [String: Any], uniquingKeysWith: { _, new in new }))

            case "terminal_set_directory":
                guard case .string(let directory)? = arguments["directory"] else {
                    return invalidArguments("directory is required.")
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
                return AIToolFailure(.unsupportedOperation, message: "Unknown AI Workspace tool.", recoverable: false).toolExecution()
            }
        } catch {
            return failure(for: error).toolExecution(state: error is CancellationError ? .cancelled : .failed)
        }
    }

    private static func invalidArguments(_ message: String) -> LimaAIToolExecution {
        AIToolFailure(.invalidArguments, message: message, recoverable: true,
                      nextAction: "Correct the arguments using the Terminal tool schema.").toolExecution()
    }

    static func failure(for error: Error) -> AIToolFailure {
        if error is CancellationError {
            return AIToolFailure(.cancelled, message: "AI Workspace observation was cancelled.",
                                 recoverable: false)
        }
        guard let workspaceError = error as? AIWorkspaceTerminalCoordinator.WorkspaceError else {
            return AIToolFailure(.resourceUnavailable,
                                 message: "The AI Workspace action failed unexpectedly.", recoverable: false)
        }
        let message = workspaceError.localizedDescription
        switch workspaceError {
        case .invalidDirectory:
            return AIToolFailure(.pathNotFound, message: message, recoverable: true,
                                 nextAction: "Inspect the workspace and use an existing relative directory.")
        case .invalidWorkspaceName, .workspaceExists, .invalidCommand, .invalidInput, .invalidSize, .invalidWait:
            return AIToolFailure(.invalidArguments, message: message, recoverable: true,
                                 nextAction: "Correct the arguments and retry the Terminal action.")
        case .outsideWorkspace, .symlink, .notWorkspaceSession:
            return AIToolFailure(.permissionDenied, message: message, recoverable: false,
                                 nextAction: "Do not bypass the Workspace path or session boundary.")
        case .tooManySessions, .tooManyCommands:
            return AIToolFailure(.resourceUnavailable, message: message, recoverable: true,
                                 nextAction: "Wait for or close an existing AI Terminal session.",
                                 suggestedTools: ["terminal_status", "terminal_close"])
        case .unknownSession:
            return AIToolFailure(.resourceUnavailable, message: message, recoverable: true,
                                 nextAction: "Start a new AI Terminal session and use its returned ID.",
                                 suggestedTools: ["terminal_start"])
        case .alreadyRunning:
            return AIToolFailure(.resourceUnavailable, message: message, recoverable: true,
                                 nextAction: "Wait for the running command to finish before starting another.",
                                 suggestedTools: ["terminal_wait"])
        case .notInteractiveSession, .interactiveSessionRequiresWrite:
            return AIToolFailure(.unsupportedOperation, message: message, recoverable: true,
                                 nextAction: "Choose terminal_write for a PTY or terminal_run for a bounded command session.",
                                 suggestedTools: ["terminal_start", "terminal_write", "terminal_run"])
        case .notRunning:
            return AIToolFailure(.unsupportedOperation, message: message, recoverable: true,
                                 nextAction: "Check the session state before interrupting or waiting.",
                                 suggestedTools: ["terminal_status"])
        case .unavailable:
            return AIToolFailure(.resourceUnavailable, message: message, recoverable: false)
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
            "interactive_pty": snapshot.isInteractivePTY,
            "network_enabled": snapshot.networkEnabled,
            "process_id": snapshot.processID.map { $0 as Any } ?? NSNull(),
            "next_byte": snapshot.nextOutputByte,
            "first_available_byte": snapshot.firstOutputByte,
            "output_truncated": snapshot.outputTruncated,
            "exit_status": snapshot.exitStatus.map { $0 as Any } ?? NSNull(),
            "verified_success": !snapshot.isInteractivePTY && snapshot.state == .completed && snapshot.exitStatus == 0
        ]
        switch snapshot.workScope {
        case .none: output["scope"] = "none"
        case .scratch(let id):
            output["scope"] = "scratch"
            output["scratch_run_id"] = id.uuidString
        case .project(let id):
            output["scope"] = "project"
            output["project_id"] = id.uuidString
        }
        if root { output["workspace_root"] = AIWorkspacePaths().root.path }
        if let failure = snapshot.toolFailure { output["failure"] = failure.jsonObject }
        return output
    }
}
