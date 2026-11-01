import Foundation
import Testing
@testable import RayPlacement

@Test func missionKeepsTheLatestGoalAndDoesNotReuseOldActions() {
    let old = AIChatMessage(role: .assistant, text: "Old response", activities: [
        AIAgentActivity(kind: .toolCompleted, title: "terminal_run", completed: true)])
    let messages = [AIChatMessage(role: .user, text: "Old goal"), old,
                    AIChatMessage(role: .user, text: "Build a little game")]
    let next = AIMissionSnapshot(messages: messages, isActive: true)
    #expect(next.goal == "Build a little game")
    #expect(next.steps.isEmpty)
    #expect(next.returnedCount == 0)
}

@Test func missionShowsReturnedAndFailedActionsWithoutCallingTheGoalComplete() {
    let messages = [AIChatMessage(role: .user, text: "Book a table"),
        AIChatMessage(role: .assistant, text: "", activities: [
            AIAgentActivity(kind: .toolStarted, title: "browser_read", correlationID: "read"),
            AIAgentActivity(kind: .toolCompleted, title: "browser_read", correlationID: "read", completed: true),
            AIAgentActivity(kind: .toolStarted, title: "browser_click", correlationID: "click"),
            AIAgentActivity(kind: .toolFailed, title: "browser_click", correlationID: "click", completed: true)])]
    let result = AIMissionSnapshot(messages: messages, isActive: false)
    #expect(result.returnedCount == 1)
    #expect(result.failureCount == 1)
    #expect(result.current?.status == .failed)
    #expect(result.steps.count == 2)
    #expect(result.goal == "Book a table")
}

@Test @MainActor func terminalExecuteCreatesEditsAndRunsScriptsInAnExternalDirectory() async throws {
    let files = FileManager.default
    let parent = files.temporaryDirectory.appendingPathComponent("LimaExecute-" + UUID().uuidString)
    let root = parent.appendingPathComponent("scratch")
    let target = parent.appendingPathComponent("project with ' spaces")
    try files.createDirectory(at: root, withIntermediateDirectories: true)
    try files.createDirectory(at: target, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: parent) }
    let runtime = AIWorkspaceTerminalCoordinator(testRoot: root)
    let suite = "LimaExecutePolicy." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let policy = AIComputerActionPolicy(defaults: defaults)
    policy.setAccess(.askEveryTime, for: .terminal)
    let command = """
    cat > game.sh <<'LIMA_SCRIPT'
    printf 'first version'
    LIMA_SCRIPT
    /usr/bin/sed -i '' 's/first version/ready to play/' game.sh
    /bin/sh game.sh
    """
    let args: [String: Any] = ["command": command, "working_directory": target.path, "timeout_seconds": 10]
    let call = AIOutputItem(phase: .completed, apiType: "function_call", callID: "execute", name: "terminal_execute",
        arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self))
    let denied = await AIWorkspaceActionTools.execute(call, approvalGranted: false,
        actionPolicy: policy, conversationID: UUID(), runtime: runtime)
    #expect(denied.isError)
    #expect(runtime.sessions.isEmpty)
    let missing = AIOutputItem(phase: .completed, apiType: "function_call", callID: "missing", name: "terminal_execute",
        arguments: "{\"command\":\"printf unused\",\"working_directory\":\"/no-such-lima-directory\"}")
    let missingResult = await AIWorkspaceActionTools.execute(missing, approvalGranted: true,
        actionPolicy: policy, conversationID: UUID(), runtime: runtime)
    #expect(missingResult.isError)
    #expect(runtime.sessions.isEmpty)
    let owner = UUID()
    let result = await AIWorkspaceActionTools.execute(call, approvalGranted: true,
        actionPolicy: policy, conversationID: owner, runtime: runtime)
    #expect(!result.isError)
    let data = try #require(result.output.data(using: .utf8))
    let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let id = try #require(UUID(uuidString: fields["session_id"] as? String ?? ""))
    #expect(fields["verified_success"] as? Bool == false)
    var snapshot = try runtime.status(sessionID: id)
    let deadline = Date().addingTimeInterval(15)
    while snapshot.state == .running && Date() < deadline {
        try await Task.sleep(for: .milliseconds(25))
        snapshot = try runtime.status(sessionID: id)
    }
    #expect(snapshot.state == .completed)
    #expect(snapshot.exitStatus == 0)
    #expect(snapshot.output.contains("ready to play"))
    #expect(snapshot.directory == target.path)
    #expect(snapshot.belongs(to: owner))
    #expect(try String(contentsOf: target.appendingPathComponent("game.sh"), encoding: .utf8).contains("ready to play"))
    let second = try runtime.run(sessionID: id, command: "pwd", timeoutSeconds: 10)
    #expect(second.directory == target.path)
    while try runtime.status(sessionID: id).state == .running && Date() < deadline {
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(try runtime.status(sessionID: id).exitStatus == 0)
    try runtime.close(sessionID: id)
}

@Test @MainActor func terminalAcceptsLargerScriptsAndRejectsOversizeWithoutLaunching() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LimaScript-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = AIWorkspaceTerminalCoordinator(testRoot: root)
    let session = try runtime.start(conversationID: UUID())
    #expect(throws: AIWorkspaceTerminalCoordinator.WorkspaceError.self) {
        try runtime.run(sessionID: session.id, command: String(repeating: "x", count: 65537), timeoutSeconds: 10)
    }
    #expect(try runtime.status(sessionID: session.id).state == .idle)
    _ = try runtime.run(sessionID: session.id,
        command: "# " + String(repeating: "a", count: 8192) + "\nprintf script-ok", timeoutSeconds: 10)
    let deadline = Date().addingTimeInterval(15)
    while try runtime.status(sessionID: session.id).state == .running && Date() < deadline {
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(try runtime.status(sessionID: session.id).output.contains("script-ok"))
    #expect(try runtime.status(sessionID: session.id).exitStatus == 0)
    try runtime.close(sessionID: session.id)
}

@Test @MainActor func extensionSearchPreparesSearchWithoutRunningTheCommand() {
    let model = LauncherViewModel(clipboard: ClipboardHistoryService(fixtures: []), scanApplications: false)
    var revealed: [String] = []
    model.revealCommandSearch = { revealed.append($0) }
    model.findCommandInSearch("Format JSON")
    #expect(model.query == "Format JSON")
    #expect(revealed == ["Format JSON"])
}
