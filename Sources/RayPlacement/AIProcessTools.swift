import Foundation
import RayPlacementCore

/// Process inspection and control is keyed by an AI-owned Terminal session,
/// never an arbitrary PID. This keeps the live ownership check in the Terminal
/// coordinator and prevents the model from signaling unrelated local processes.
@MainActor
enum AIProcessTools {
    nonisolated static let readIDs: Set<String> = [
        "process_list", "process_status", "process_logs", "process_ports"
    ]
    nonisolated static let actionIDs: Set<String> = [
        "process_interrupt", "process_stop", "process_kill"
    ]
    nonisolated static let ids = readIDs.union(actionIDs)

    private static let string: [String: Any] = ["type": "string"]
    static let definitions: [LimaAIToolDefinition] = [
        definition("process_list",
                   "List the current conversation's AI-owned Project and Scratch process sessions; never enumerate unrelated system processes.",
                   properties: [:], required: []),
        definition("process_status",
                   "Read state, PID, and exit status for one AI-owned process session. Use its session_id, not a raw PID.",
                   properties: ["session_id": string], required: ["session_id"]),
        definition("process_logs",
                   "Read up to 32 KB of bounded output for an AI-owned process session from an optional byte cursor.",
                   properties: ["session_id": string,
                                "from_byte": ["type": "integer", "minimum": 0]],
                   required: ["session_id"]),
        definition("process_ports",
                   "Inspect registered managed-server ports associated with an AI-owned process session. This is not a system-wide port scan.",
                   properties: ["session_id": string], required: ["session_id"]),
        definition("process_interrupt",
                   "Send Ctrl-C to the foreground job in an AI-owned PTY or request cancellation of an AI-owned one-shot command. Inspect status afterward.",
                   properties: ["session_id": string], required: ["session_id"], action: true),
        definition("process_stop",
                   "Request a graceful stop of an AI-owned process session. The result is a request acknowledgement; verify exit with process_status.",
                   properties: ["session_id": string], required: ["session_id"], action: true),
        definition("process_kill",
                   "Immediately kill the live process for an AI-owned session, without accepting an arbitrary PID. Verify exit and server ports afterward.",
                   properties: ["session_id": string], required: ["session_id"], action: true)
    ]

    private static func definition(_ name: String, _ description: String,
                                   properties: [String: Any], required: [String],
                                   action: Bool = false) -> LimaAIToolDefinition {
        LimaAIToolDefinition(
            id: name, name: name, description: description,
            parameters: ["type": "object", "properties": properties,
                         "required": required, "additionalProperties": false],
            risk: action ? .localAction : .read,
            actionCategory: action ? .terminal : nil
        )
    }

    static func execute(_ call: AIOutputItem, approvalGranted: Bool,
                        conversationID: UUID?,
                        terminal suppliedTerminal: AIWorkspaceTerminalCoordinator? = nil,
                        servers suppliedServers: AIManagedServerManager? = nil,
                        actionPolicy suppliedPolicy: AIComputerActionPolicy? = nil,
                        toolAccessMode: LimaAIToolAccessMode? = nil) async -> LimaAIToolExecution {
        guard let definition = definitions.first(where: { $0.id == call.name }),
              let conversationID else {
            return failure("The process tool needs an originating conversation.")
        }
        let policy = suppliedPolicy ?? .shared
        guard policy.permits(definition, approvalGranted: approvalGranted,
                             toolAccessMode: toolAccessMode ?? LimaAIToolStore.shared.accessMode) else {
            return failure("Process access is disabled or still needs approval.")
        }
        let raw = call.arguments ?? "{}"
        guard raw.utf8.count <= 8_192, let data = raw.data(using: .utf8),
              let arguments = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              Set(arguments.keys).isSubset(of:
                Set((definition.parameters["properties"] as? [String: Any] ?? [:]).keys)) else {
            return failure("Invalid Process tool arguments.")
        }
        let terminal = suppliedTerminal ?? .shared
        func ownedSession() throws -> AIWorkspaceTerminalSnapshot {
            guard case .string(let rawID)? = arguments["session_id"],
                  let id = UUID(uuidString: rawID),
                  let snapshot = try? terminal.status(sessionID: id),
                  snapshot.belongs(to: conversationID),
                  !snapshot.isBoundedExternal else {
                throw AIWorkspaceTerminalCoordinator.WorkspaceError.unknownSession
            }
            return snapshot
        }
        do {
            switch definition.id {
            case "process_list":
                let sessions = terminal.sessions(for: conversationID)
                    .filter { !$0.isBoundedExternal }
                return .json(["processes": sessions.map(payload)])
            case "process_status":
                return .json(payload(try ownedSession()))
            case "process_logs":
                let session = try ownedSession()
                let fromByte: Int?
                switch arguments["from_byte"] {
                case .none, .some(.null): fromByte = nil
                case .some(.number(let value)) where value.isFinite
                    && value.rounded() == value && value >= 0
                    && value <= Double(Int.max):
                    fromByte = Int(value)
                default:
                    return failure("from_byte must be a nonnegative integer.")
                }
                return .json(try terminal.read(sessionID: session.id, from: fromByte))
            case "process_ports":
                let session = try ownedSession()
                let servers = suppliedServers ?? .shared
                let registered = await servers.list(conversationID: conversationID)
                    .filter { $0["session_id"] as? String == session.id.uuidString }
                return .json(["session_id": session.id.uuidString,
                              "registered_ports": registered,
                              "exhaustive": false])
            case "process_interrupt":
                let session = try ownedSession()
                let current = try terminal.interrupt(sessionID: session.id)
                return .json(actionPayload(current, action: "interrupt"))
            case "process_stop":
                let session = try ownedSession()
                let current = try session.isInteractivePTY
                    ? terminal.terminate(sessionID: session.id)
                    : terminal.interrupt(sessionID: session.id)
                return .json(actionPayload(current, action: "stop"))
            case "process_kill":
                let session = try ownedSession()
                let current = try terminal.forceKill(sessionID: session.id)
                return .json(actionPayload(current, action: "kill"))
            default:
                return failure("Unknown Process tool.")
            }
        } catch {
            return failure(error.localizedDescription)
        }
    }

    private static func payload(_ session: AIWorkspaceTerminalSnapshot) -> [String: Any] {
        var result: [String: Any] = [
            "session_id": session.id.uuidString,
            "process_id": session.processID.map { $0 as Any } ?? NSNull(),
            "state": session.state.rawValue,
            "interactive_pty": session.isInteractivePTY,
            "network_enabled": session.networkEnabled,
            "working_directory": session.directory,
            "exit_status": session.exitStatus.map { $0 as Any } ?? NSNull(),
            "first_available_byte": session.firstOutputByte,
            "next_byte": session.nextOutputByte
        ]
        switch session.workScope {
        case .project(let id):
            result["scope"] = "project"
            result["project_id"] = id.uuidString
        case .scratch(let id):
            result["scope"] = "scratch"
            result["scratch_run_id"] = id.uuidString
        case .none:
            result["scope"] = "none"
        }
        return result
    }

    private static func actionPayload(_ session: AIWorkspaceTerminalSnapshot,
                                      action: String) -> [String: Any] {
        var result = payload(session)
        result["requested_action"] = action
        result["request_accepted"] = true
        result["post_action_verified"] = session.state != .running
        result["next_step"] = "Use process_status and process_ports to verify exit and port closure."
        return result
    }

    private static func failure(_ message: String) -> LimaAIToolExecution {
        AIToolFailure(.resourceUnavailable, message: message, recoverable: true,
                      nextAction: "Inspect process_list or the owned Terminal session before retrying.",
                      suggestedTools: ["process_list", "process_status", "terminal_status"])
            .toolExecution()
    }
}
