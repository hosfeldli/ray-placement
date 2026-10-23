import Darwin
import Foundation
import RayPlacementCore

enum AIManagedServerError: LocalizedError {
    case invalidPort
    case missingServer
    case notProjectOwned
    case unavailableProject
    case sessionNotRunning
    case networkUnavailable
    case ambiguousPort
    case portAlreadyRegistered
    case notReady
    case stillRunning
    case browserControlDisabled

    var errorDescription: String? {
        switch self {
        case .invalidPort: "Use a TCP port from 1 through 65535."
        case .missingServer: "That managed server is not available to this conversation."
        case .notProjectOwned: "Register a Terminal session owned by an active Project in this conversation."
        case .unavailableProject: "The server's Project is no longer active and materialized."
        case .sessionNotRunning: "The owning Terminal session is not running."
        case .networkUnavailable: "Start the Terminal command in Full Control to allow a local server to listen."
        case .ambiguousPort: "The Terminal output has no single unambiguous localhost port; provide port explicitly."
        case .portAlreadyRegistered: "Another running session already owns this Project and port."
        case .notReady: "The local server port is not accepting connections yet. Use server_wait."
        case .stillRunning: "The managed server or its localhost port is still running. Inspect it and retry."
        case .browserControlDisabled: "Browser AI Control must allow navigation, and the target tab must not be paused."
        }
    }
}

/// A managed server is an explicit binding between one Project-owned Terminal
/// session and one loopback port. No arbitrary PID or external URL is accepted.
/// Port probes connect to 127.0.0.1 only and never follow HTTP redirects.
@MainActor
final class AIManagedServerManager {
    static let shared = AIManagedServerManager(terminal: .shared, projects: .shared)

    struct Record: Identifiable {
        let id: UUID
        let projectID: UUID
        var conversationID: UUID
        var sessionID: UUID
        let port: Int
        let createdAt: Date

        var url: URL { URL(string: "http://127.0.0.1:\(port)")! }
    }

    private enum ListenerOwnership: String, Sendable {
        case owned
        case foreign
        case unverified
    }

    private let terminal: AIWorkspaceTerminalCoordinator
    private let projects: AIWorkspaceStore
    private let requireNetworkEnabled: Bool
    private var records: [UUID: Record] = [:]

    init(terminal: AIWorkspaceTerminalCoordinator, projects: AIWorkspaceStore,
         requireNetworkEnabled: Bool = true) {
        self.terminal = terminal
        self.projects = projects
        self.requireNetworkEnabled = requireNetworkEnabled
    }

    func register(sessionID: UUID, port explicitPort: Int?, conversationID: UUID) throws -> Record {
        let session = try terminal.status(sessionID: sessionID)
        guard !session.isBoundedExternal, session.conversationID == conversationID,
              case .project(let projectID) = session.workScope else {
            throw AIManagedServerError.notProjectOwned
        }
        guard let project = projects.project(id: projectID),
              project.lifecycle == .active, project.workState == .materialized else {
            throw AIManagedServerError.unavailableProject
        }
        guard session.state == .running else { throw AIManagedServerError.sessionNotRunning }
        guard !requireNetworkEnabled || session.networkEnabled else {
            throw AIManagedServerError.networkUnavailable
        }
        let port = try explicitPort ?? Self.detectPort(in: session.output)
        guard (1...65_535).contains(port) else { throw AIManagedServerError.invalidPort }
        if var existing = records.values.first(where: { $0.projectID == projectID && $0.port == port }) {
            if existing.sessionID == sessionID { return existing }
            if let old = try? terminal.status(sessionID: existing.sessionID), old.state == .running {
                throw AIManagedServerError.portAlreadyRegistered
            }
            existing.sessionID = sessionID
            existing.conversationID = conversationID
            records[existing.id] = existing
            return existing
        }
        guard records.count < 32 else { throw AIManagedServerError.portAlreadyRegistered }
        let record = Record(id: UUID(), projectID: projectID, conversationID: conversationID,
                            sessionID: sessionID, port: port, createdAt: Date())
        records[record.id] = record
        return record
    }

    func record(_ id: UUID, conversationID: UUID) throws -> Record {
        guard let record = records[id], record.conversationID == conversationID else {
            throw AIManagedServerError.missingServer
        }
        return record
    }

    func list(conversationID: UUID) async -> [[String: Any]] {
        var output: [[String: Any]] = []
        for record in records.values.filter({ $0.conversationID == conversationID }).sorted(by: { $0.createdAt < $1.createdAt }) {
            output.append(await statusPayload(record))
        }
        return output
    }

    func status(_ id: UUID, conversationID: UUID) async throws -> [String: Any] {
        await statusPayload(try record(id, conversationID: conversationID))
    }

    func wait(_ id: UUID, conversationID: UUID, timeoutSeconds: Int) async throws -> [String: Any] {
        guard (1...20).contains(timeoutSeconds) else { throw AIManagedServerError.invalidPort }
        let record = try record(id, conversationID: conversationID)
        let deadline = ContinuousClock().now.advanced(by: .seconds(timeoutSeconds))
        repeat {
            try Task.checkCancellation()
            let result = await statusPayload(record)
            if result["ready"] as? Bool == true || result["terminal_running"] as? Bool == false {
                return result
            }
            try await Task.sleep(for: .milliseconds(200))
        } while ContinuousClock().now < deadline
        return await statusPayload(record)
    }

    func stop(_ id: UUID, conversationID: UUID) async throws -> [String: Any] {
        let record = try record(id, conversationID: conversationID)
        let ownedBeforeStop = await statusPayload(record)["listener_owned"] as? Bool == true
        if let session = try? terminal.status(sessionID: record.sessionID), session.state == .running {
            if session.isInteractivePTY {
                _ = try terminal.terminate(sessionID: session.id)
            } else {
                _ = try terminal.interrupt(sessionID: session.id)
            }
        }
        let deadline = ContinuousClock().now.advanced(by: .seconds(6))
        repeat {
            try Task.checkCancellation()
            let result = await statusPayload(record)
            if result["terminal_running"] as? Bool == false &&
                (!ownedBeforeStop || result["listening"] as? Bool == false) {
                return result
            }
            try await Task.sleep(for: .milliseconds(200))
        } while ContinuousClock().now < deadline
        throw AIManagedServerError.stillRunning
    }

    func stopAll(projectID: UUID) async throws {
        for record in records.values.filter({ $0.projectID == projectID }) {
            _ = try await stop(record.id, conversationID: record.conversationID)
        }
    }

    func isReady(_ id: UUID, conversationID: UUID) async throws -> Bool {
        let record = try record(id, conversationID: conversationID)
        return await statusPayload(record)["ready"] as? Bool == true
    }

    private func statusPayload(_ record: Record) async -> [String: Any] {
        let session = try? terminal.status(sessionID: record.sessionID)
        let running = session?.state == .running
        let listening = await Self.probe(port: record.port)
        let ownership: ListenerOwnership
        if running, listening, let pid = session?.processID {
            ownership = await Self.listenerOwnership(port: record.port, rootPID: pid)
        } else {
            ownership = .unverified
        }
        let listenerOwned = ownership == .owned
        return [
            "server_id": record.id.uuidString,
            "project_id": record.projectID.uuidString,
            "session_id": record.sessionID.uuidString,
            "url": record.url.absoluteString,
            "port": record.port,
            "terminal_state": session?.state.rawValue ?? "closed",
            "terminal_running": running,
            "listening": listening,
            "listener_owned": listenerOwned,
            "listener_ownership": listening ? ownership.rawValue : "none",
            "ready": running && listening && listenerOwned,
            "foreign_listener": running && listening && ownership == .foreign,
            "ownership_unverified": running && listening && ownership == .unverified,
            "unattributed_listener": !running && listening
        ]
    }

    private static func detectPort(in output: String) throws -> Int {
        let regex = try NSRegularExpression(
            pattern: #"http://(?:localhost|127\.0\.0\.1):([0-9]{1,5})"#,
            options: [.caseInsensitive]
        )
        let text = String(output.suffix(32_768))
        let range = NSRange(text.startIndex..., in: text)
        let ports = Set(regex.matches(in: text, range: range).compactMap { match -> Int? in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return Int(text[range])
        }.filter { (1...65_535).contains($0) })
        guard ports.count == 1, let port = ports.first else { throw AIManagedServerError.ambiguousPort }
        return port
    }

    private nonisolated static func probe(port: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: probeSynchronously(port: port))
            }
        }
    }

    private nonisolated static func probeSynchronously(port: Int) -> Bool {
        guard (1...65_535).contains(port) else { return false }
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private nonisolated static func listenerOwnership(port: Int, rootPID: Int32) async -> ListenerOwnership {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                guard let output = utilityOutput("/usr/sbin/lsof", arguments: [
                    "-nP", "-a", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fp"
                ]) else {
                    continuation.resume(returning: .unverified)
                    return
                }
                let owners = output.split(separator: "\n").compactMap { line -> Int32? in
                    guard line.first == "p" else { return nil }
                    return Int32(line.dropFirst())
                }
                guard !owners.isEmpty else {
                    continuation.resume(returning: .unverified)
                    return
                }
                var uncertain = false
                for owner in owners {
                    switch descends(owner, from: rootPID) {
                    case .some(true):
                        continuation.resume(returning: .owned)
                        return
                    case .some(false): break
                    case .none: uncertain = true
                    }
                }
                continuation.resume(returning: uncertain ? .unverified : .foreign)
            }
        }
    }

    private nonisolated static func descends(_ pid: Int32, from rootPID: Int32) -> Bool? {
        guard pid > 1, rootPID > 1 else { return nil }
        var current = pid
        var visited = Set<Int32>()
        for _ in 0..<32 {
            if current == rootPID { return true }
            guard visited.insert(current).inserted,
                  let output = utilityOutput("/bin/ps", arguments: ["-o", "ppid=", "-p", String(current)]),
                  let parent = Int32(output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return nil
            }
            if parent <= 1 { return false }
            current = parent
        }
        return nil
    }

    private nonisolated static func utilityOutput(_ executable: String, arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, data.count <= 16_384 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
enum AIManagedServerTools {
    nonisolated static let readIDs: Set<String> = ["server_list", "server_status", "server_wait"]
    nonisolated static let actionIDs: Set<String> = ["server_register", "server_open", "server_stop"]
    nonisolated static let ids = readIDs.union(actionIDs)

    static let definitions: [LimaAIToolDefinition] = [
        definition("server_list", "List managed localhost servers owned by this conversation.", [:], []),
        definition("server_status", "Check a managed server's owning Terminal session and loopback port.", ["server_id": string], ["server_id"]),
        definition("server_wait", "Wait up to 20 seconds for a managed localhost port to accept connections or its Terminal session to stop.", ["server_id": string, "timeout_seconds": ["type": "integer", "minimum": 1, "maximum": 20]], ["server_id"]),
        definition("server_register", "Bind a running Project-owned Terminal session to its single detected localhost port, or provide the port explicitly. The session must have been launched in Full Control.", ["session_id": string, "port": ["type": "integer", "minimum": 1, "maximum": 65_535]], ["session_id"], action: true),
        definition("server_open", "Open or reload the existing Browser tab for a ready managed server. Requires Browser AI navigation control and never opens duplicate tabs for that server.", ["server_id": string], ["server_id"], action: true),
        definition("server_stop", "Stop the Project-owned Terminal session and verify its localhost port closed; preserve Project files.", ["server_id": string], ["server_id"], action: true)
    ]
    private static let string: [String: Any] = ["type": "string"]

    private static func definition(_ name: String, _ description: String,
                                   _ properties: [String: Any], _ required: [String],
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
                        manager suppliedManager: AIManagedServerManager? = nil,
                        browser suppliedBrowser: BrowserWorkspaceModel? = nil,
                        actionPolicy suppliedPolicy: AIComputerActionPolicy? = nil,
                        toolAccessMode: LimaAIToolAccessMode? = nil) async -> LimaAIToolExecution {
        guard let definition = definitions.first(where: { $0.id == call.name }),
              let conversationID else {
            return failure("The managed server tool needs an originating conversation.")
        }
        let policy = suppliedPolicy ?? .shared
        guard policy.permits(definition, approvalGranted: approvalGranted,
                             toolAccessMode: toolAccessMode ?? LimaAIToolStore.shared.accessMode) else {
            return failure("Managed server access is disabled or still needs approval.")
        }
        let raw = call.arguments ?? "{}"
        guard raw.utf8.count <= 8_192, let data = raw.data(using: .utf8),
              let args = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              Set(args.keys).isSubset(of: Set((definition.parameters["properties"] as? [String: Any] ?? [:]).keys)) else {
            return failure("Invalid managed server arguments.")
        }
        func id(_ key: String) -> UUID? {
            guard case .string(let value)? = args[key] else { return nil }
            return UUID(uuidString: value)
        }
        let manager = suppliedManager ?? .shared
        do {
            switch definition.id {
            case "server_list":
                return .json(["servers": await manager.list(conversationID: conversationID)])
            case "server_status":
                guard let serverID = id("server_id") else { return failure("A valid server_id is required.") }
                return .json(try await manager.status(serverID, conversationID: conversationID))
            case "server_wait":
                guard let serverID = id("server_id") else { return failure("A valid server_id is required.") }
                let timeout: Int
                switch args["timeout_seconds"] {
                case .none, .some(.null): timeout = 20
                case .some(.number(let value)) where value.isFinite && value.rounded() == value && (1...20).contains(value):
                    timeout = Int(value)
                default: return failure("timeout_seconds must be an integer from 1 to 20.")
                }
                return .json(try await manager.wait(serverID, conversationID: conversationID, timeoutSeconds: timeout))
            case "server_register":
                guard let sessionID = id("session_id") else { return failure("A valid session_id is required.") }
                let port: Int?
                switch args["port"] {
                case .none, .some(.null): port = nil
                case .some(.number(let value)) where value.isFinite && value.rounded() == value && (1...65_535).contains(value):
                    port = Int(value)
                default: return failure("port must be an integer from 1 to 65535.")
                }
                let record = try manager.register(sessionID: sessionID, port: port, conversationID: conversationID)
                return .json(try await manager.status(record.id, conversationID: conversationID))
            case "server_open":
                guard let serverID = id("server_id") else { return failure("A valid server_id is required.") }
                let record = try manager.record(serverID, conversationID: conversationID)
                let browser = suppliedBrowser ?? .shared
                guard browser.aiControlMode.canNavigate,
                      browser.tab(projectID: record.projectID, serverID: record.id)
                        .map({ !browser.pausedTabIDs.contains($0.id) }) ?? true else {
                    throw AIManagedServerError.browserControlDisabled
                }
                guard try await manager.isReady(serverID, conversationID: conversationID) else {
                    throw AIManagedServerError.notReady
                }
                let tab = try browser.openServer(record.url, projectID: record.projectID, serverID: record.id)
                let visible = browser.revealAIForegroundTab(tab.id)
                return .json([
                    "server_id": record.id.uuidString, "tab_id": tab.id.uuidString,
                    "selected_tab_id": browser.selectedTabID?.uuidString ?? "",
                    "browser_visible": visible, "page_state_verified": false,
                    "post_action_verified": browser.selectedTabID == tab.id,
                    "next_step": "Use browser_wait, browser_read, and browser_screenshot with this tab_id to verify the page."
                ], browserTabID: tab.id)
            case "server_stop":
                guard let serverID = id("server_id") else { return failure("A valid server_id is required.") }
                return .json(try await manager.stop(serverID, conversationID: conversationID))
            default:
                return failure("Unknown managed server tool.")
            }
        } catch {
            return failure(error.localizedDescription)
        }
    }

    private static func failure(_ message: String) -> LimaAIToolExecution {
        AIToolFailure(.resourceUnavailable, message: message, recoverable: true,
                      nextAction: "Inspect the Project-owned Terminal session and managed server status.",
                      suggestedTools: ["terminal_status", "server_status", "server_wait"]).toolExecution()
    }
}
