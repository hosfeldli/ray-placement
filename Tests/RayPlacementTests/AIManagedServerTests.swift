import Darwin
import Foundation
import Testing
@testable import RayPlacement

private final class ServerTestLoopbackListener {
    let descriptor: Int32
    let port: Int

    init() throws {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw POSIXError(.ENFILE) }
        descriptor = socket
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(socket, 128) == 0 else {
            Darwin.close(socket)
            throw POSIXError(.EADDRINUSE)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let queried = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(socket, $0, &length)
            }
        }
        guard queried == 0 else {
            Darwin.close(socket)
            throw POSIXError(.EINVAL)
        }
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    deinit { Darwin.close(descriptor) }
}

@MainActor
private func serverTestWorkspace() throws -> (
    root: URL, paths: AIWorkspacePaths, store: AIWorkspaceStore,
    terminal: AIWorkspaceTerminalCoordinator, projects: AIProjectManager,
    servers: AIManagedServerManager
) {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("LimaManagedServer-\(UUID().uuidString)", isDirectory: true)
    let paths = AIWorkspacePaths(root: root)
    let store = AIWorkspaceStore(fixtures: [])
    let toolAccess = LimaAIToolStore(fixtures: [], accessMode: .fullControl)
    let terminal = AIWorkspaceTerminalCoordinator(paths: paths, projectStore: store,
        toolAccessStore: toolAccess)
    let servers = AIManagedServerManager(terminal: terminal, projects: store)
    let projects = AIProjectManager(store: store, paths: paths, terminal: terminal, servers: servers)
    return (root, paths, store, terminal, projects, servers)
}

private func serverTestCall(_ name: String, serverID: UUID) -> AIOutputItem {
    AIOutputItem(phase: .completed, apiType: "function_call", callID: UUID().uuidString,
                 name: name, arguments: "{\"server_id\":\"\(serverID.uuidString)\"}")
}

private func serverTestFields(_ result: LimaAIToolExecution) throws -> [String: Any] {
    let data = try #require(result.output.data(using: .utf8))
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private let serverTestLoopbackCommand = #"""
/usr/bin/perl -MIO::Socket::INET -e 'my $server = IO::Socket::INET->new(LocalAddr => "127.0.0.1", LocalPort => 0, Listen => 128, ReuseAddr => 1) or die $!; $| = 1; my $port = $server->sockport; print "http://127.0.0.1:$port/\n"; while (my $client = $server->accept) { print $client "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK"; close $client; }'
"""#

@Test @MainActor func managedServerRejectsUnrelatedLoopbackListener() async throws {
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else { return }
    let workspace = try serverTestWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace.root) }
    let listener = try ServerTestLoopbackListener()
    let project = try workspace.projects.create(name: "Foreign Listener")
    let conversationID = UUID()
    let session = try workspace.terminal.start(conversationID: conversationID, projectID: project.id)
    defer {
        if (try? workspace.terminal.status(sessionID: session.id))?.state == .running {
            _ = try? workspace.terminal.interrupt(sessionID: session.id)
        }
    }
    _ = try workspace.terminal.run(sessionID: session.id, command: "sleep 30", timeoutSeconds: 40)
    let processDeadline = ContinuousClock().now.advanced(by: .seconds(10))
    while (try workspace.terminal.status(sessionID: session.id)).processID == nil &&
        ContinuousClock().now < processDeadline {
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(try workspace.terminal.status(sessionID: session.id).processID != nil)
    let record = try workspace.servers.register(sessionID: session.id,
        port: listener.port, conversationID: conversationID)
    let status = try await workspace.servers.status(record.id, conversationID: conversationID)
    #expect(status["listening"] as? Bool == true)
    #expect(status["listener_owned"] as? Bool == false)
    #expect(status["foreign_listener"] as? Bool == true)
    #expect(status["listener_ownership"] as? String == "foreign")
    #expect(status["ready"] as? Bool == false)
    #expect(try await workspace.servers.isReady(record.id, conversationID: conversationID) == false)
    let browser = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    browser.aiControlMode = .fullControl
    let deniedOpen = await AIManagedServerTools.execute(
        serverTestCall("server_open", serverID: record.id), approvalGranted: false,
        conversationID: conversationID, manager: workspace.servers, browser: browser,
        toolAccessMode: .fullControl)
    #expect(deniedOpen.isError)
    #expect(browser.tabs.isEmpty)
    let stopped = try await workspace.servers.stop(record.id, conversationID: conversationID)
    #expect(stopped["terminal_running"] as? Bool == false)
    #expect(stopped["listening"] as? Bool == true)
    #expect(stopped["unattributed_listener"] as? Bool == true)
    withExtendedLifetime(listener) { }
}

@Test @MainActor func managedServerOpensReusesAndStopsOwnedLoopbackProcess() async throws {
    let files = FileManager.default
    guard files.isExecutableFile(atPath: "/usr/bin/sandbox-exec"),
          files.isExecutableFile(atPath: "/usr/bin/perl"),
          files.isExecutableFile(atPath: "/usr/sbin/lsof") else { return }
    let workspace = try serverTestWorkspace()
    defer { try? files.removeItem(at: workspace.root) }
    let project = try workspace.projects.create(name: "Owned Server")
    let conversationID = UUID()
    let session = try workspace.terminal.start(conversationID: conversationID, projectID: project.id)
    defer {
        if (try? workspace.terminal.status(sessionID: session.id))?.state == .running {
            _ = try? workspace.terminal.interrupt(sessionID: session.id)
        }
    }
    _ = try workspace.terminal.run(sessionID: session.id,
        command: "echo SERVER_LAUNCH; " + serverTestLoopbackCommand + "; echo SERVER_EXIT",
        timeoutSeconds: 30)
    var record: AIManagedServerManager.Record?
    let deadline = ContinuousClock().now.advanced(by: .seconds(8))
    while ContinuousClock().now < deadline {
        let snapshot = try workspace.terminal.status(sessionID: session.id)
        if snapshot.output.contains("http://127.0.0.1:") {
            record = try workspace.servers.register(sessionID: session.id,
                port: nil, conversationID: conversationID)
            break
        }
        if snapshot.state != .running { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    guard let server = record else {
        let snapshot = try workspace.terminal.status(sessionID: session.id)
        Issue.record("Local server emitted no URL: state=\(snapshot.state.rawValue), output=\(snapshot.output.suffix(1_000))")
        return
    }
    let ready = try await workspace.servers.wait(server.id,
        conversationID: conversationID, timeoutSeconds: 8)
    #expect(ready["terminal_running"] as? Bool == true)
    #expect(ready["listening"] as? Bool == true)
    #expect(ready["listener_owned"] as? Bool == true)
    #expect(ready["listener_ownership"] as? String == "owned")
    #expect(ready["ready"] as? Bool == true)

    let browser = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    browser.aiControlMode = .off
    let openCall = serverTestCall("server_open", serverID: server.id)
    let denied = await AIManagedServerTools.execute(openCall, approvalGranted: false,
        conversationID: conversationID, manager: workspace.servers, browser: browser,
        toolAccessMode: .fullControl)
    #expect(denied.isError)
    #expect(browser.tabs.isEmpty)

    browser.aiControlMode = .fullControl
    let opened = await AIManagedServerTools.execute(openCall, approvalGranted: false,
        conversationID: conversationID, manager: workspace.servers, browser: browser,
        toolAccessMode: .fullControl)
    #expect(!opened.isError)
    let firstID = try #require((try serverTestFields(opened))["tab_id"] as? String)
    let reopened = await AIManagedServerTools.execute(openCall, approvalGranted: false,
        conversationID: conversationID, manager: workspace.servers, browser: browser,
        toolAccessMode: .fullControl)
    #expect(!reopened.isError)
    #expect((try serverTestFields(reopened))["tab_id"] as? String == firstID)
    #expect(browser.tabs.filter { $0.context?.serverID == server.id }.count == 1)

    let stoppedResult = await AIManagedServerTools.execute(
        serverTestCall("server_stop", serverID: server.id), approvalGranted: false,
        conversationID: conversationID, manager: workspace.servers,
        toolAccessMode: .fullControl)
    #expect(!stoppedResult.isError)
    let stopped = try serverTestFields(stoppedResult)
    #expect(stopped["terminal_running"] as? Bool == false)
    #expect(stopped["listening"] as? Bool == false)
}

@Test @MainActor func projectArchiveStopsManagedServerAndPreservesFiles() async throws {
    let files = FileManager.default
    guard files.isExecutableFile(atPath: "/usr/bin/sandbox-exec"),
          files.isExecutableFile(atPath: "/usr/bin/perl"),
          files.isExecutableFile(atPath: "/usr/sbin/lsof") else { return }
    let workspace = try serverTestWorkspace()
    defer { try? files.removeItem(at: workspace.root) }
    let project = try workspace.projects.create(name: "Archive Server")
    let source = workspace.paths.project(project.id).appendingPathComponent("README.md")
    try Data("# Preserve me".utf8).write(to: source)
    let conversationID = UUID()
    let session = try workspace.terminal.start(conversationID: conversationID, projectID: project.id)
    defer {
        if (try? workspace.terminal.status(sessionID: session.id))?.state == .running {
            _ = try? workspace.terminal.interrupt(sessionID: session.id)
        }
    }
    _ = try workspace.terminal.run(sessionID: session.id,
        command: serverTestLoopbackCommand + "; echo SERVER_EXIT",
        timeoutSeconds: 30)
    var registered: AIManagedServerManager.Record?
    let deadline = ContinuousClock().now.advanced(by: .seconds(8))
    while ContinuousClock().now < deadline {
        let snapshot = try workspace.terminal.status(sessionID: session.id)
        if snapshot.output.contains("http://127.0.0.1:") {
            registered = try workspace.servers.register(sessionID: session.id,
                port: nil, conversationID: conversationID)
            break
        }
        if snapshot.state != .running { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    let server = try #require(registered)
    let ready = try await workspace.servers.wait(server.id,
        conversationID: conversationID, timeoutSeconds: 8)
    #expect(ready["ready"] as? Bool == true)

    _ = try await workspace.projects.archive(project.id)
    #expect(workspace.store.project(id: project.id)?.lifecycle == .archived)
    #expect(!workspace.terminal.sessions.contains { $0.id == session.id })
    let preserved = workspace.paths.project(project.id, lifecycle: .archived)
        .appendingPathComponent("README.md")
    #expect(try String(contentsOf: preserved, encoding: .utf8) == "# Preserve me")
    let after = try await workspace.servers.status(server.id, conversationID: conversationID)
    #expect(after["terminal_running"] as? Bool == false)
    #expect(after["listening"] as? Bool == false)
}
