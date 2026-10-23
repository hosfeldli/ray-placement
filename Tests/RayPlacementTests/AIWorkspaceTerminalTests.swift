import Foundation
import Testing
@testable import RayPlacement

@Test @MainActor func aiWorkspaceRejectsTraversalAndSymlinkDirectories() throws {
    let manager = FileManager.default
    let parent = manager.temporaryDirectory.appendingPathComponent("LimaWorkspacePathTests-\(UUID().uuidString)", isDirectory: true)
    let root = parent.appendingPathComponent("root", isDirectory: true)
    let project = root.appendingPathComponent("project", isDirectory: true)
    let outside = parent.appendingPathComponent("outside", isDirectory: true)
    try manager.createDirectory(at: project, withIntermediateDirectories: true)
    try manager.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: parent) }

    #expect(try AIWorkspaceTerminalCoordinator.validDirectory(".", root: root).path == root.path)
    #expect(try AIWorkspaceTerminalCoordinator.validDirectory("project", root: root).path == project.path)
    #expect(throws: AIWorkspaceTerminalCoordinator.WorkspaceError.self) {
        try AIWorkspaceTerminalCoordinator.validDirectory("../outside", root: root)
    }
    #expect(throws: AIWorkspaceTerminalCoordinator.WorkspaceError.self) {
        try AIWorkspaceTerminalCoordinator.validDirectory("/tmp", root: root)
    }
    let link = root.appendingPathComponent("linked", isDirectory: true)
    try manager.createSymbolicLink(at: link, withDestinationURL: outside)
    #expect(throws: AIWorkspaceTerminalCoordinator.WorkspaceError.self) {
        try AIWorkspaceTerminalCoordinator.validDirectory("linked", root: root)
    }
}

@Test @MainActor func aiWorkspaceSandboxConfinesWritesAndDeniesUnrelatedHomeReads() throws {
    let manager = FileManager.default
    let desktop = manager.homeDirectoryForCurrentUser
        .standardizedFileURL.resolvingSymlinksInPath()
        .appendingPathComponent("Desktop", isDirectory: true)
    guard manager.fileExists(atPath: desktop.path),
          manager.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else { return }
    let suffix = UUID().uuidString
    let root = desktop.appendingPathComponent("LimaSandboxFixture-\(suffix)", isDirectory: true)
    let outside = desktop.appendingPathComponent("LimaSandboxOutside-\(suffix).txt")
    let secret = desktop.appendingPathComponent("LimaSandboxSecret-\(suffix).txt")
    try manager.createDirectory(at: root, withIntermediateDirectories: false)
    try Data("private test value".utf8).write(to: secret)
    defer {
        try? manager.removeItem(at: root)
        try? manager.removeItem(at: outside)
        try? manager.removeItem(at: secret)
    }
    let temporary = root.appendingPathComponent(".tmp", isDirectory: true)
    try manager.createDirectory(at: temporary, withIntermediateDirectories: false)
    let inside = root.appendingPathComponent("inside.txt")
    let profile = AIWorkspaceTerminalCoordinator.sandboxProfile(root: root)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    process.arguments = [
        "-p", profile, "/bin/zsh", "-f", "-c",
        """
        printf inside > "$1"
        if printf outside > "$2" 2>/dev/null; then echo outside-write-allowed; else echo outside-write-denied; fi
        if /bin/cat "$3" >/dev/null 2>&1; then echo home-read-allowed; else echo home-read-denied; fi
        """,
        "_", inside.path, outside.path, secret.path
    ]
    process.currentDirectoryURL = root
    process.environment = [
        "HOME": root.path, "TMPDIR": temporary.path + "/",
        "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"
    ]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

    #expect(process.terminationStatus == 0)
    #expect(manager.fileExists(atPath: inside.path))
    #expect(!manager.fileExists(atPath: outside.path))
    #expect(text.contains("outside-write-denied"))
    #expect(text.contains("home-read-denied"))
}

@Test @MainActor func aiWorkspaceNetworkProfileRequiresExplicitFullControlSelection() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LimaNetworkProfileFixture")
    let defaultProfile = AIWorkspaceTerminalCoordinator.sandboxProfile(root: root)
    let fullControlProfile = AIWorkspaceTerminalCoordinator.sandboxProfile(root: root, networkEnabled: true)
    #expect(!defaultProfile.contains("(allow network*)"))
    #expect(fullControlProfile.contains("(allow network*)"))
    #expect(defaultProfile.contains("(deny default)"))
    #expect(fullControlProfile.contains("(deny default)"))
    #expect(fullControlProfile.contains("(deny file-read*"))
    #expect(fullControlProfile.contains("(allow file-write* (subpath"))
}

@Test @MainActor func aiWorkspaceNetworkSandboxDeniesLoopbackWithoutFullControlRule() async throws {
    let files = FileManager.default
    guard files.isExecutableFile(atPath: "/usr/bin/sandbox-exec"),
          files.isExecutableFile(atPath: "/usr/bin/python3") else { return }
    let root = files.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("LimaNetworkDenied-\(UUID().uuidString)", isDirectory: true)
    defer { try? files.removeItem(at: root) }
    let paths = AIWorkspacePaths(root: root)
    let store = AIWorkspaceStore(fixtures: [])
    let toolAccess = LimaAIToolStore(fixtures: [], accessMode: .automatic)
    let terminal = AIWorkspaceTerminalCoordinator(paths: paths, projectStore: store,
        toolAccessStore: toolAccess)
    let session = try terminal.start(conversationID: UUID())
    _ = try terminal.run(sessionID: session.id,
        command: "/usr/bin/python3 -c 'import socket; socket.socket().bind((\"127.0.0.1\", 0))'",
        timeoutSeconds: 8)
    _ = try await terminal.wait(sessionID: session.id, from: nil, maxWaitSeconds: 8)
    let result = try terminal.status(sessionID: session.id)
    #expect(result.networkEnabled == false)
    #expect(result.state == .failed)
    #expect(result.exitStatus != 0)
    #expect(result.output.contains("Operation not permitted"))
    try terminal.close(sessionID: session.id)
}

@Test @MainActor func aiWorkspaceToolDefinitionsKeepReadsSeparateFromActions() {
    #expect(AIWorkspaceActionTools.actionIDs.count == 9)
    #expect(AIWorkspaceActionTools.readIDs == ["terminal_sessions", "terminal_status", "terminal_read", "terminal_wait"])
    for definition in AIWorkspaceActionTools.definitions {
        if AIWorkspaceActionTools.actionIDs.contains(definition.id) {
            #expect(definition.actionCategory == .terminal)
            #expect(definition.risk == .localAction)
        } else {
            #expect(definition.actionCategory == nil)
            #expect(definition.risk == .read)
        }
    }
}

@Test @MainActor func terminalKillOnlyStopsAnApprovedConversationOwnedSession() async throws {
    let files = FileManager.default
    guard files.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else { return }
    let root = files.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("LimaTerminalKill-\(UUID().uuidString)", isDirectory: true)
    try files.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? files.removeItem(at: root) }
    let coordinator = AIWorkspaceTerminalCoordinator(testRoot: root,
        toolAccessStore: LimaAIToolStore(fixtures: [], accessMode: .automatic))
    let suite = "AITerminalKillPolicy.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let policy = AIComputerActionPolicy(defaults: defaults)
    policy.setAccess(.askEveryTime, for: .terminal)
    let owner = UUID()
    let session = try coordinator.start(conversationID: owner)
    _ = try coordinator.run(sessionID: session.id, command: "/bin/sleep 30", timeoutSeconds: 40)
    let call = AIOutputItem(phase: .completed, apiType: "function_call",
        callID: "kill-owned", name: "terminal_kill",
        arguments: "{\"session_id\":\"\(session.id.uuidString)\"}")
    let foreign = await AIWorkspaceActionTools.execute(call, approvalGranted: true,
        actionPolicy: policy, conversationID: UUID(), runtime: coordinator)
    #expect(foreign.isError)
    let unapproved = await AIWorkspaceActionTools.execute(call, approvalGranted: false,
        actionPolicy: policy, conversationID: owner, runtime: coordinator)
    #expect(unapproved.isError)
    #expect(try coordinator.status(sessionID: session.id).state == .running)
    let accepted = await AIWorkspaceActionTools.execute(call, approvalGranted: true,
        actionPolicy: policy, conversationID: owner, runtime: coordinator)
    #expect(!accepted.isError)
    #expect(accepted.output.contains("\"kill_requested\":true"))
    #expect(accepted.output.contains("\"verified_stopped\":false"))
    let ended = try await waitForAIWorkspaceCommand(coordinator, sessionID: session.id)
    #expect(ended.state == .cancelled)
    try coordinator.close(sessionID: session.id)
}

private enum AIWorkspaceFixtureError: Error {
    case commandDidNotFinish
}

@MainActor
private func waitForAIWorkspaceCommand(
    _ coordinator: AIWorkspaceTerminalCoordinator,
    sessionID: UUID
) async throws -> AIWorkspaceTerminalSnapshot {
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline {
        let snapshot = try coordinator.status(sessionID: sessionID)
        if snapshot.state != .running { return snapshot }
        try await Task.sleep(for: .milliseconds(25))
    }
    throw AIWorkspaceFixtureError.commandDidNotFinish
}

@MainActor
private func waitForPTYText(
    _ coordinator: AIWorkspaceTerminalCoordinator,
    sessionID: UUID,
    from startByte: Int,
    containing marker: String
) async throws -> String {
    let deadline = Date().addingTimeInterval(10)
    var cursor = startByte
    var collected = ""
    while Date() < deadline {
        let result = try await coordinator.wait(sessionID: sessionID, from: cursor, maxWaitSeconds: 2)
        #expect(result["interactive_pty"] as? Bool == true)
        #expect(result["verified_success"] as? Bool == false)
        #expect(result["command_finished"] as? Bool == false)
        collected += result["output"] as? String ?? ""
        if collected.contains(marker) { return collected }
        cursor = result["next_byte"] as? Int ?? cursor
        try await Task.sleep(for: .milliseconds(50))
    }
    throw AIWorkspaceFixtureError.commandDidNotFinish
}

@Test @MainActor func aiWorkspaceInteractivePTYIsSharedAndKeepsShellState() async throws {
    let manager = FileManager.default
    guard manager.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else { return }
    let root = manager.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("LimaWorkspacePTYTests-\(UUID().uuidString)", isDirectory: true)
    let project = root.appendingPathComponent("project", isDirectory: true)
    try manager.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }

    let coordinator = AIWorkspaceTerminalCoordinator(testRoot: root)
    let owner = UUID()
    let other = UUID()
    let session = try coordinator.start(directory: "project", conversationID: owner, interactive: true)
    #expect(session.isInteractivePTY)
    #expect(session.state == .running)
    let view = try #require(coordinator.ptyView(sessionID: session.id))
    #expect(view.process.running)
    #expect(coordinator.ptyView(sessionID: session.id) === view)
    #expect(throws: AIWorkspaceTerminalCoordinator.WorkspaceError.self) {
        try coordinator.resize(sessionID: session.id, columns: 19, rows: 42)
    }
    let resized = try coordinator.resize(sessionID: session.id, columns: 110, rows: 42)
    #expect(resized["verified_size"] as? Bool == true)
    #expect(resized["observed_columns"] as? Int == 110)
    #expect(resized["observed_rows"] as? Int == 42)
    let sizeCursor = try coordinator.status(sessionID: session.id).nextOutputByte
    _ = try coordinator.write(sessionID: session.id, input: "printf 'pty-size:'; stty size\n")
    let sizeOutput = try await waitForPTYText(coordinator, sessionID: session.id,
                                              from: sizeCursor, containing: "pty-size:42 110")
    #expect(sizeOutput.contains("pty-size:42 110"))

    let suite = "AIWorkspacePTYPolicy.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let policy = AIComputerActionPolicy(defaults: defaults)
    policy.setAccess(.askEveryTime, for: .terminal)
    let input = "export LIMA_PTY_TEST=alive\n"
    let arguments = try #require(String(data: JSONSerialization.data(withJSONObject: [
        "session_id": session.id.uuidString, "input": input
    ]), encoding: .utf8))
    let call = AIOutputItem(phase: .completed, apiType: "function_call", callID: "pty-write",
                            name: "terminal_write", arguments: arguments)
    let unapproved = await AIWorkspaceActionTools.execute(call, approvalGranted: false,
        actionPolicy: policy, conversationID: owner, runtime: coordinator)
    #expect(unapproved.isError)
    let wrongOwner = await AIWorkspaceActionTools.execute(call, approvalGranted: true,
        actionPolicy: policy, conversationID: other, runtime: coordinator)
    #expect(wrongOwner.isError)
    #expect(wrongOwner.output.contains("another conversation"))
    let resizeArguments = try #require(String(data: JSONSerialization.data(withJSONObject: [
        "session_id": session.id.uuidString, "columns": 120, "rows": 44
    ]), encoding: .utf8))
    let resizeCall = AIOutputItem(phase: .completed, apiType: "function_call", callID: "pty-resize",
                                  name: "terminal_resize", arguments: resizeArguments)
    let resizeWrongOwner = await AIWorkspaceActionTools.execute(resizeCall, approvalGranted: true,
        actionPolicy: policy, conversationID: other, runtime: coordinator)
    #expect(resizeWrongOwner.isError)
    let resizeApproved = await AIWorkspaceActionTools.execute(resizeCall, approvalGranted: true,
        actionPolicy: policy, conversationID: owner, runtime: coordinator)
    #expect(!resizeApproved.isError)
    #expect(resizeApproved.output.contains("\"verified_size\":true"))
    let approved = await AIWorkspaceActionTools.execute(call, approvalGranted: true,
        actionPolicy: policy, conversationID: owner, runtime: coordinator)
    #expect(!approved.isError)
    #expect(approved.output.contains("\"input_accepted\":true"))
    #expect(approved.output.contains("\"verified_success\":false"))

    let cursor = try coordinator.status(sessionID: session.id).nextOutputByte
    let accepted = try coordinator.write(sessionID: session.id,
        input: "printf 'pty-state:%s\\n' \"$LIMA_PTY_TEST\"\n")
    #expect(accepted["input_accepted"] as? Bool == true)
    #expect(accepted["verified_success"] as? Bool == false)
    let aiOutput = try await waitForPTYText(coordinator, sessionID: session.id,
                                            from: cursor, containing: "pty-state:alive")
    #expect(aiOutput.contains("pty-state:alive"))

    // SwiftTerm's user-input path must reach the same process and AI read cursor.
    let userCursor = try coordinator.status(sessionID: session.id).nextOutputByte
    view.send(data: Array("printf 'user-visible-route\\n'\n".utf8)[...])
    let userOutput = try await waitForPTYText(coordinator, sessionID: session.id,
                                              from: userCursor, containing: "user-visible-route")
    #expect(userOutput.contains("user-visible-route"))
    #expect(throws: AIWorkspaceTerminalCoordinator.WorkspaceError.self) {
        try coordinator.write(sessionID: session.id, input: "\u{1B}[2J")
    }
    #expect(throws: AIWorkspaceTerminalCoordinator.WorkspaceError.self) {
        try coordinator.run(sessionID: session.id, command: "echo wrong-api", timeoutSeconds: 2)
    }

    _ = try coordinator.terminate(sessionID: session.id)
    let ended = try await waitForAIWorkspaceCommand(coordinator, sessionID: session.id)
    #expect(ended.state == .cancelled)
    try coordinator.close(sessionID: session.id)
    #expect(coordinator.ptyView(sessionID: session.id) == nil)
    #expect(manager.fileExists(atPath: project.path))
}

@Test @MainActor func aiWorkspaceRuntimeStreamsVerifiedResultsAndCancellationToVisibleSessions() async throws {
    let manager = FileManager.default
    guard manager.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else { return }
    let root = manager.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("LimaWorkspaceRuntimeTests-\(UUID().uuidString)", isDirectory: true)
    try manager.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? manager.removeItem(at: root) }

    let coordinator = AIWorkspaceTerminalCoordinator(testRoot: root)
    let project = try coordinator.start(newWorkspace: "Prism Demo")
    #expect(project.directory == root.appendingPathComponent("Prism Demo").path)
    #expect(manager.fileExists(atPath: project.directory))
    try coordinator.close(sessionID: project.id)
    #expect(manager.fileExists(atPath: project.directory)) // Closing never deletes files.
    #expect(throws: AIWorkspaceTerminalCoordinator.WorkspaceError.self) {
        try coordinator.start(newWorkspace: "Prism Demo")
    }
    #expect(throws: AIWorkspaceTerminalCoordinator.WorkspaceError.self) {
        try coordinator.start(newWorkspace: "../outside")
    }
    #expect(throws: AIWorkspaceTerminalCoordinator.WorkspaceError.self) {
        try coordinator.start(directory: "Prism Demo", newWorkspace: "Another")
    }
    let started = try coordinator.start()
    #expect(started.state == .idle)
    #expect(coordinator.sessions.contains { $0.id == started.id })

    let launched = try coordinator.run(
        sessionID: started.id,
        command: "SECRET_FIXTURE=never_echo /usr/bin/printf visible-output",
        timeoutSeconds: 5
    )
    #expect(launched.state == .running)
    let waited = try await coordinator.wait(sessionID: started.id, from: nil, maxWaitSeconds: 10)
    #expect(waited["verified_success"] as? Bool == true)
    #expect(waited["command_finished"] as? Bool == true)
    #expect(waited["wait_expired"] as? Bool == false)
    #expect((waited["output"] as? String)?.contains("visible-output") == true)
    let completed = try coordinator.status(sessionID: started.id)
    #expect(completed.state == .completed)
    #expect(completed.exitStatus == 0)
    #expect(completed.output.contains("visible-output"))
    #expect(completed.output.contains("Approved command"))
    #expect(!completed.output.contains("SECRET_FIXTURE=never_echo"))
    #expect(coordinator.sessions.first { $0.id == started.id } == completed)

    let read = try coordinator.read(sessionID: started.id, from: nil)
    #expect((read["output"] as? String)?.contains("visible-output") == true)
    let cursor = try #require(read["next_byte"] as? Int)
    let afterCursor = try coordinator.read(sessionID: started.id, from: cursor)
    #expect((afterCursor["output"] as? String) == "")

    _ = try coordinator.run(sessionID: started.id, command: "printf failed-output; exit 7", timeoutSeconds: 5)
    let failed = try await waitForAIWorkspaceCommand(coordinator, sessionID: started.id)
    #expect(failed.state == .failed)
    #expect(failed.exitStatus == 7)
    #expect(failed.output.contains("failed-output"))
    #expect(failed.toolFailure?.code == .nonzeroExit)
    let failedWait = try await coordinator.wait(sessionID: started.id, from: nil, maxWaitSeconds: 1)
    let failure = try #require(failedWait["failure"] as? [String: Any])
    #expect(failure["code"] as? String == "nonzero_exit")
    #expect(failure["recoverable"] as? Bool == true)
    #expect((failure["next_action"] as? String)?.contains("Inspect terminal output") == true)

    _ = try coordinator.run(
        sessionID: started.id,
        command: "printf cancellation-output; exec /usr/bin/yes > /dev/null",
        timeoutSeconds: 5
    )
    _ = try coordinator.interrupt(sessionID: started.id)
    let cancelled = try await waitForAIWorkspaceCommand(coordinator, sessionID: started.id)
    #expect(cancelled.state == .cancelled)
    #expect(cancelled.output.contains("[AI command cancelled]"))
    try coordinator.close(sessionID: started.id)
    #expect(coordinator.sessions.allSatisfy { $0.id != started.id })
}

@Test @MainActor func aiWorkspaceOutputDrainPreservesOrderingBeforeCompletion() async throws {
    let manager = FileManager.default
    guard manager.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else { return }
    let root = manager.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("LimaWorkspaceOutputDrainTests-\(UUID().uuidString)", isDirectory: true)
    try manager.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? manager.removeItem(at: root) }

    let coordinator = AIWorkspaceTerminalCoordinator(testRoot: root)
    let session = try coordinator.start()
    defer { try? coordinator.close(sessionID: session.id) }
    _ = try coordinator.run(
        sessionID: session.id,
        command: "awk 'BEGIN { for (i = 1; i <= 6000; i++) printf \"LINE%05d\\n\", i }'",
        timeoutSeconds: 10
    )
    let completed = try await waitForAIWorkspaceCommand(coordinator, sessionID: session.id)
    #expect(completed.state == .completed)
    #expect(completed.exitStatus == 0)
    #expect(!completed.outputTruncated)
    let expected = (1...6_000).map { String(format: "LINE%05d\n", $0) }.joined()
    #expect(completed.output.contains(expected))
    #expect(completed.output.hasSuffix("[AI command completed]\n"))
}

@Test @MainActor func aiTerminalStartRequestsTheVisibleSharedSessionAndReportsItsObservation() async throws {
    let manager = FileManager.default
    guard manager.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else { return }
    let root = manager.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("LimaTerminalRevealTests-\(UUID().uuidString)", isDirectory: true)
    try manager.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? manager.removeItem(at: root) }

    let coordinator = AIWorkspaceTerminalCoordinator(testRoot: root)
    let earlier = try coordinator.start()
    #expect(!coordinator.revealAIForegroundSession(earlier.id))
    #expect(coordinator.foregroundSessionID == earlier.id)
    var revealedID: UUID?
    coordinator.onAIForegroundSession = { id in
        revealedID = id
        return true
    }

    let suite = "AITerminalRevealPolicy.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let policy = AIComputerActionPolicy(defaults: defaults)
    policy.setAccess(.askEveryTime, for: .terminal)
    let owner = UUID()
    let call = AIOutputItem(phase: .completed, apiType: "function_call",
                            callID: "visible-terminal-start", name: "terminal_start", arguments: "{}")
    let result = await AIWorkspaceActionTools.execute(
        call, approvalGranted: true, actionPolicy: policy,
        conversationID: owner, runtime: coordinator
    )
    #expect(!result.isError)
    let data = try #require(result.output.data(using: .utf8))
    let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let rawID = try #require(fields["session_id"] as? String)
    let id = try #require(UUID(uuidString: rawID))
    #expect(fields["terminal_visible"] as? Bool == true)
    #expect(fields["post_action_verified"] as? Bool == true)
    #expect(revealedID == id)
    #expect(coordinator.foregroundSessionID == id)
    #expect(coordinator.sessions.contains { $0.id == id })

    try coordinator.close(sessionID: id)
    #expect(coordinator.foregroundSessionID == earlier.id)
    try coordinator.close(sessionID: earlier.id)
    #expect(coordinator.foregroundSessionID == nil)
    #expect(!coordinator.revealAIForegroundSession(id))
}

@Test @MainActor func boundedExternalCommandStreamsIntoTheSharedVisibleTerminalSession() async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("LimaBoundedTerminalTests-\(UUID().uuidString)", isDirectory: true)
    try manager.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? manager.removeItem(at: root) }
    let initialize = Process()
    initialize.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    initialize.arguments = ["init", "-q", root.path]
    try initialize.run()
    initialize.waitUntilExit()
    #expect(initialize.terminationStatus == 0)
    try Data("visible fixture\n".utf8).write(to: root.appendingPathComponent("marker.txt"))

    let conversationID = UUID()
    let result = await AILocalCommandRunner.shared.run(
        command: "git status --short", workingDirectory: root, timeoutSeconds: 5,
        conversationID: conversationID
    )
    #expect(!result.isError)
    let data = try #require(result.output.data(using: .utf8))
    let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let rawID = try #require(fields["session_id"] as? String)
    let id = try #require(UUID(uuidString: rawID))
    #expect(fields["visible_in_terminal"] as? Bool == true)
    #expect(fields["succeeded"] as? Bool == true)
    #expect((fields["output"] as? String)?.contains("?? marker.txt") == true)

    let coordinator = AIWorkspaceTerminalCoordinator.shared
    let visible = try coordinator.status(sessionID: id)
    #expect(visible.isBoundedExternal)
    #expect(visible.belongs(to: conversationID))
    #expect(coordinator.sessions(for: conversationID).contains { $0.id == id })
    #expect(visible.title.contains("External"))
    #expect(visible.state == .completed)
    #expect(visible.exitStatus == 0)
    #expect(visible.output.contains("Approved bounded developer command"))
    #expect(visible.output.contains("?? marker.txt"))
    #expect(coordinator.sessions.contains { $0.id == id })
    let suite = "AIWorkspaceExternalPolicy.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let policy = AIComputerActionPolicy(defaults: defaults)
    let readDefinition = try #require(AIWorkspaceActionTools.definitions.first { $0.id == "terminal_read" })
    #expect(!policy.allows(readDefinition))
    policy.setAccess(.askEveryTime, for: .terminal)
    #expect(policy.allows(readDefinition))
    #expect(!policy.requiresApproval(for: readDefinition))
    let readCall = AIOutputItem(
        phase: .completed, apiType: "function_call", callID: "bounded-external-read",
        name: "terminal_read", arguments: "{\"session_id\":\"\(rawID)\"}"
    )
    let blockedRead = await AIWorkspaceActionTools.execute(
        readCall, approvalGranted: false, actionPolicy: policy, conversationID: conversationID
    )
    #expect(blockedRead.isError)
    #expect(blockedRead.output.contains("not an AI Workspace session"))
    #expect(!blockedRead.output.contains("marker.txt"))
    let waitCall = AIOutputItem(
        phase: .completed, apiType: "function_call", callID: "bounded-external-wait",
        name: "terminal_wait", arguments: "{\"session_id\":\"\(rawID)\"}"
    )
    let blockedWait = await AIWorkspaceActionTools.execute(
        waitCall, approvalGranted: false, actionPolicy: policy, conversationID: conversationID
    )
    #expect(blockedWait.isError)
    #expect(blockedWait.output.contains("not an AI Workspace session"))
    #expect(!blockedWait.output.contains("marker.txt"))
    policy.setAccess(.disabled, for: .terminal)
    let revokedRead = await AIWorkspaceActionTools.execute(
        readCall, approvalGranted: false, actionPolicy: policy, conversationID: conversationID
    )
    #expect(revokedRead.isError)
    #expect(revokedRead.output.contains("disabled or still needs your approval"))
    #expect(!revokedRead.output.contains("marker.txt"))
    #expect(throws: AIWorkspaceTerminalCoordinator.WorkspaceError.self) {
        try coordinator.run(sessionID: id, command: "echo should-not-run", timeoutSeconds: 5)
    }
    try coordinator.close(sessionID: id)
}

@Test @MainActor func aiTerminalSessionsStayInTheirOriginatingConversation() async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("LimaConversationTerminalTests-\(UUID().uuidString)", isDirectory: true)
    try manager.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? manager.removeItem(at: root) }
    let coordinator = AIWorkspaceTerminalCoordinator(testRoot: root)
    let suite = "AIConversationTerminalPolicy.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let policy = AIComputerActionPolicy(defaults: defaults)
    policy.setAccess(.askEveryTime, for: .terminal)
    let conversationA = UUID()
    let conversationB = UUID()
    let start = AIOutputItem(phase: .completed, apiType: "function_call", callID: "start-a",
                             name: "terminal_start", arguments: "{}")
    let anonymous = await AIWorkspaceActionTools.execute(start, approvalGranted: true,
        actionPolicy: policy, runtime: coordinator)
    #expect(anonymous.isError)
    #expect(anonymous.output.contains("originating conversation"))
    #expect(coordinator.sessions.isEmpty)
    let startedA = await AIWorkspaceActionTools.execute(start, approvalGranted: true,
        actionPolicy: policy, conversationID: conversationA, runtime: coordinator)
    #expect(!startedA.isError)
    let startData = try #require(startedA.output.data(using: .utf8))
    let fields = try #require(JSONSerialization.jsonObject(with: startData) as? [String: Any])
    let idA = try #require(UUID(uuidString: fields["session_id"] as? String ?? ""))
    let snapshotA = try coordinator.status(sessionID: idA)
    #expect(snapshotA.belongs(to: conversationA))
    #expect(!snapshotA.belongs(to: conversationB))
    #expect(coordinator.sessions(for: conversationA).map { $0.id } == [idA])
    #expect(coordinator.sessions(for: conversationB).isEmpty)
    #expect(coordinator.sessions(for: nil).isEmpty)
    let list = AIOutputItem(phase: .completed, apiType: "function_call", callID: "list-a",
                            name: "terminal_sessions", arguments: "{}")
    let listedA = await AIWorkspaceActionTools.execute(list, approvalGranted: false,
        actionPolicy: policy, conversationID: conversationA, runtime: coordinator)
    let listedB = await AIWorkspaceActionTools.execute(list, approvalGranted: false,
        actionPolicy: policy, conversationID: conversationB, runtime: coordinator)
    #expect(!listedA.isError)
    #expect(!listedB.isError)
    let dataA = try #require(listedA.output.data(using: .utf8))
    let dataB = try #require(listedB.output.data(using: .utf8))
    let sessionsA = try #require((JSONSerialization.jsonObject(with: dataA) as? [String: Any])?["sessions"] as? [[String: Any]])
    let sessionsB = try #require((JSONSerialization.jsonObject(with: dataB) as? [String: Any])?["sessions"] as? [[String: Any]])
    #expect(sessionsA.map { $0["session_id"] as? String } == [idA.uuidString])
    #expect(sessionsB.isEmpty)

    let status = AIOutputItem(phase: .completed, apiType: "function_call", callID: "status-a",
                              name: "terminal_status", arguments: "{\"session_id\":\"\(idA.uuidString)\"}")
    let denied = await AIWorkspaceActionTools.execute(status, approvalGranted: false,
        actionPolicy: policy, conversationID: conversationB, runtime: coordinator)
    #expect(denied.isError)
    #expect(denied.output.contains("another conversation"))
    let allowed = await AIWorkspaceActionTools.execute(status, approvalGranted: false,
        actionPolicy: policy, conversationID: conversationA, runtime: coordinator)
    #expect(!allowed.isError)

    let close = AIOutputItem(phase: .completed, apiType: "function_call", callID: "close-a",
                             name: "terminal_close", arguments: "{\"session_id\":\"\(idA.uuidString)\"}")
    let deniedClose = await AIWorkspaceActionTools.execute(close, approvalGranted: true,
        actionPolicy: policy, conversationID: conversationB, runtime: coordinator)
    #expect(deniedClose.isError)
    #expect(coordinator.sessions(for: conversationA).map { $0.id } == [idA])
    let allowedClose = await AIWorkspaceActionTools.execute(close, approvalGranted: true,
        actionPolicy: policy, conversationID: conversationA, runtime: coordinator)
    #expect(!allowedClose.isError)
    #expect(coordinator.sessions(for: conversationA).isEmpty)
}

@Test @MainActor func aiWorkspaceDirectoryGrantIsOwnedRevocableAndWriteConfined() async throws {
    let manager = FileManager.default
    guard manager.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else { return }
    let desktop = manager.homeDirectoryForCurrentUser.standardizedFileURL
        .resolvingSymlinksInPath().appendingPathComponent("Desktop", isDirectory: true)
    guard manager.fileExists(atPath: desktop.path) else { return }
    let root = desktop.appendingPathComponent("LimaDirectoryGrantTests-\(UUID().uuidString)", isDirectory: true)
    let project = root.appendingPathComponent("project", isDirectory: true)
    let sibling = root.appendingPathComponent("sibling", isDirectory: true)
    try manager.createDirectory(at: project, withIntermediateDirectories: true)
    try manager.createDirectory(at: sibling, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }

    let coordinator = AIWorkspaceTerminalCoordinator(testRoot: root)
    let suite = "AIDirectoryGrantPolicy.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let policy = AIComputerActionPolicy(defaults: defaults)
    policy.setAccess(.askEveryTime, for: .terminal)
    let owner = UUID()
    let other = UUID()
    let session = try coordinator.start(directory: "project", conversationID: owner)
    let command = "printf inside > inside.txt; if printf escape > ../sibling/escaped.txt 2>/dev/null; then echo escape-allowed; else echo escape-denied; fi"
    let call = AIOutputItem(phase: .completed, apiType: "function_call", callID: "directory-run",
                            name: "terminal_run", arguments: """
                            {"session_id":"\(session.id.uuidString)","command":"\(command)"}
                            """)
    #expect(AIWorkspaceActionTools.directoryGrantPath(
        for: call, conversationID: owner, actionPolicy: policy, runtime: coordinator
    ) == project.path)
    #expect(AIWorkspaceActionTools.directoryGrantPath(
        for: call, conversationID: other, actionPolicy: policy, runtime: coordinator
    ) == nil)
    let unapproved = await AIWorkspaceActionTools.execute(
        call, approvalGranted: false, actionPolicy: policy, conversationID: owner, runtime: coordinator
    )
    #expect(unapproved.isError)
    #expect(!coordinator.hasDirectoryGrant(sessionID: session.id, conversationID: owner))

    let granted = try AIWorkspaceActionTools.grantDirectory(
        for: call, conversationID: owner, expectedDirectory: project.path,
        actionPolicy: policy, runtime: coordinator
    )
    #expect(granted.directoryGrantActive)
    #expect(coordinator.hasDirectoryGrant(sessionID: session.id, conversationID: owner))
    #expect(!coordinator.hasDirectoryGrant(sessionID: session.id, conversationID: other))
    #expect(throws: AIWorkspaceTerminalCoordinator.WorkspaceError.self) {
        try AIWorkspaceActionTools.grantDirectory(
            for: call, conversationID: other, expectedDirectory: project.path,
            actionPolicy: policy, runtime: coordinator
        )
    }
    let launched = await AIWorkspaceActionTools.execute(
        call, approvalGranted: false, actionPolicy: policy, conversationID: owner, runtime: coordinator
    )
    #expect(!launched.isError)
    let finished = try await waitForAIWorkspaceCommand(coordinator, sessionID: session.id)
    #expect(finished.state == .completed)
    #expect(finished.output.contains("escape-denied"))
    #expect(manager.fileExists(atPath: project.appendingPathComponent("inside.txt").path),
            "Command output: \(finished.output)")
    #expect(!manager.fileExists(atPath: sibling.appendingPathComponent("escaped.txt").path))

    let startAgain = AIOutputItem(phase: .completed, apiType: "function_call", callID: "start-again",
                                  name: "terminal_start", arguments: "{}")
    let blockedStart = await AIWorkspaceActionTools.execute(
        startAgain, approvalGranted: false, actionPolicy: policy, conversationID: owner, runtime: coordinator
    )
    #expect(blockedStart.isError)
    let changeCall = AIOutputItem(phase: .completed, apiType: "function_call", callID: "change-dir",
                                  name: "terminal_set_directory",
                                  arguments: "{\"session_id\":\"\(session.id.uuidString)\",\"directory\":\"sibling\"}")
    let blockedChange = await AIWorkspaceActionTools.execute(
        changeCall, approvalGranted: false, actionPolicy: policy, conversationID: owner, runtime: coordinator
    )
    #expect(blockedChange.isError)

    coordinator.revokeDirectoryGrants(for: other)
    #expect(coordinator.hasDirectoryGrant(sessionID: session.id, conversationID: owner))
    coordinator.revokeDirectoryGrants(for: owner)
    #expect(!coordinator.hasDirectoryGrant(sessionID: session.id, conversationID: owner))
    _ = try coordinator.grantDirectory(
        sessionID: session.id, conversationID: owner, expectedDirectory: project.path
    )
    coordinator.revokeDirectoryGrant(sessionID: session.id)
    #expect(!coordinator.hasDirectoryGrant(sessionID: session.id, conversationID: owner))
    let revoked = await AIWorkspaceActionTools.execute(
        call, approvalGranted: false, actionPolicy: policy, conversationID: owner, runtime: coordinator
    )
    #expect(revoked.isError)
    _ = try coordinator.grantDirectory(
        sessionID: session.id, conversationID: owner, expectedDirectory: project.path
    )
    _ = try coordinator.setDirectory(sessionID: session.id, relativeDirectory: "sibling")
    _ = try coordinator.setDirectory(sessionID: session.id, relativeDirectory: "project")
    #expect(!coordinator.hasDirectoryGrant(sessionID: session.id, conversationID: owner))
    _ = try coordinator.grantDirectory(
        sessionID: session.id, conversationID: owner, expectedDirectory: project.path
    )
    policy.setAccess(.disabled, for: .terminal)
    #expect(!AIWorkspaceActionTools.hasApplicableDirectoryGrant(
        for: call, conversationID: owner, actionPolicy: policy, runtime: coordinator
    ))
    let disabled = await AIWorkspaceActionTools.execute(
        call, approvalGranted: false, actionPolicy: policy, conversationID: owner, runtime: coordinator
    )
    #expect(disabled.isError)
    try coordinator.close(sessionID: session.id)
    #expect(!coordinator.hasDirectoryGrant(sessionID: session.id, conversationID: owner))
}
