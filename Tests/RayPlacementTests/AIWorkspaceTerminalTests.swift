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

@Test @MainActor func aiWorkspaceToolDefinitionsKeepReadsSeparateFromActions() {
    #expect(AIWorkspaceActionTools.actionIDs.count == 5)
    #expect(AIWorkspaceActionTools.readIDs == ["terminal_status", "terminal_read"])
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
        await Task.yield()
    }
    throw AIWorkspaceFixtureError.commandDidNotFinish
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
    let completed = try await waitForAIWorkspaceCommand(coordinator, sessionID: started.id)
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

    let result = await AILocalCommandRunner.shared.run(
        command: "git status --short", workingDirectory: root, timeoutSeconds: 5
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
    #expect(visible.title.contains("External"))
    #expect(visible.state == .completed)
    #expect(visible.exitStatus == 0)
    #expect(visible.output.contains("Approved bounded developer command"))
    #expect(visible.output.contains("?? marker.txt"))
    #expect(coordinator.sessions.contains { $0.id == id })
    let readCall = AIOutputItem(
        phase: .completed, apiType: "function_call", callID: "bounded-external-read",
        name: "terminal_read", arguments: "{\"session_id\":\"\(rawID)\"}"
    )
    let blockedRead = AIWorkspaceActionTools.execute(readCall, approvalGranted: false)
    #expect(blockedRead.isError)
    #expect(blockedRead.output.contains("not an AI Workspace session"))
    #expect(!blockedRead.output.contains("marker.txt"))
    #expect(throws: AIWorkspaceTerminalCoordinator.WorkspaceError.self) {
        try coordinator.run(sessionID: id, command: "echo should-not-run", timeoutSeconds: 5)
    }
    try coordinator.close(sessionID: id)
}
