import Foundation
import Testing
@testable import RayPlacement

private func processToolCall(_ name: String, _ arguments: [String: Any] = [:]) throws -> AIOutputItem {
    let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
    return AIOutputItem(phase: .completed, apiType: "function_call",
                        callID: UUID().uuidString, name: name,
                        arguments: String(decoding: data, as: UTF8.self))
}

private func processToolPayload(_ execution: LimaAIToolExecution) throws -> [String: Any] {
    let data = try #require(execution.output.data(using: .utf8))
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test @MainActor func aiProcessToolsAreTerminalGatedAndKeepReadsSeparateFromActions() throws {
    #expect(AIProcessTools.readIDs == ["process_list", "process_status", "process_logs", "process_ports"])
    #expect(AIProcessTools.actionIDs == ["process_interrupt", "process_stop", "process_kill"])
    let suite = "AIProcessPolicy.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let policy = AIComputerActionPolicy(defaults: defaults)
    for definition in AIProcessTools.definitions {
        if AIProcessTools.actionIDs.contains(definition.id) {
            #expect(definition.risk == .localAction)
            #expect(definition.actionCategory == .terminal)
        } else {
            #expect(definition.risk == .read)
            #expect(definition.actionCategory == nil)
        }
    }
    policy.setAccess(.disabled, for: .terminal)
    for definition in AIProcessTools.definitions {
        #expect(!policy.allows(definition, toolAccessMode: .automatic))
    }
    policy.setAccess(.askEveryTime, for: .terminal)
    for definition in AIProcessTools.definitions {
        #expect(policy.allows(definition, toolAccessMode: .automatic))
        #expect(policy.permits(definition, approvalGranted: true, toolAccessMode: .automatic))
        if AIProcessTools.actionIDs.contains(definition.id) {
            #expect(!policy.permits(definition, approvalGranted: false, toolAccessMode: .automatic))
        } else {
            #expect(policy.permits(definition, approvalGranted: false, toolAccessMode: .automatic))
        }
    }
}

@Test @MainActor func aiProcessToolsOnlyInspectAndKillOwnedSessions() async throws {
    let files = FileManager.default
    guard files.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else { return }
    let root = files.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("LimaProcessTools-\(UUID().uuidString)", isDirectory: true)
    try files.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? files.removeItem(at: root) }
    let access = LimaAIToolStore(fixtures: [], accessMode: .automatic)
    let terminal = AIWorkspaceTerminalCoordinator(testRoot: root, toolAccessStore: access)
    let suite = "AIProcessPolicy.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let policy = AIComputerActionPolicy(defaults: defaults)
    policy.setAccess(.askEveryTime, for: .terminal)

    let owner = UUID()
    let other = UUID()
    let session = try terminal.start(conversationID: owner)
    let args: [String: Any] = ["session_id": session.id.uuidString]

    let ownerList = await AIProcessTools.execute(try processToolCall("process_list"),
        approvalGranted: false, conversationID: owner, terminal: terminal,
        actionPolicy: policy, toolAccessMode: .automatic)
    let otherList = await AIProcessTools.execute(try processToolCall("process_list"),
        approvalGranted: false, conversationID: other, terminal: terminal,
        actionPolicy: policy, toolAccessMode: .automatic)
    #expect(!ownerList.isError)
    #expect(!otherList.isError)
    let owned = try #require(processToolPayload(ownerList)["processes"] as? [[String: Any]])
    let foreign = try #require(processToolPayload(otherList)["processes"] as? [[String: Any]])
    #expect(owned.map { $0["session_id"] as? String } == [session.id.uuidString])
    #expect(foreign.isEmpty)

    let foreignStatus = await AIProcessTools.execute(try processToolCall("process_status", args),
        approvalGranted: false, conversationID: other, terminal: terminal,
        actionPolicy: policy, toolAccessMode: .automatic)
    #expect(foreignStatus.isError)
    let arbitraryPID = await AIProcessTools.execute(try processToolCall("process_kill",
        ["process_id": ProcessInfo.processInfo.processIdentifier]),
        approvalGranted: true, conversationID: owner, terminal: terminal,
        actionPolicy: policy, toolAccessMode: .automatic)
    #expect(arbitraryPID.isError)

    _ = try terminal.run(sessionID: session.id, command: "/bin/sleep 30", timeoutSeconds: 40)
    let unapproved = await AIProcessTools.execute(try processToolCall("process_kill", args),
        approvalGranted: false, conversationID: owner, terminal: terminal,
        actionPolicy: policy, toolAccessMode: .automatic)
    #expect(unapproved.isError)
    #expect(try terminal.status(sessionID: session.id).state == .running)
    let wrongOwner = await AIProcessTools.execute(try processToolCall("process_kill", args),
        approvalGranted: true, conversationID: other, terminal: terminal,
        actionPolicy: policy, toolAccessMode: .automatic)
    #expect(wrongOwner.isError)
    #expect(try terminal.status(sessionID: session.id).state == .running)

    let logs = await AIProcessTools.execute(try processToolCall("process_logs",
        ["session_id": session.id.uuidString, "from_byte": 0]),
        approvalGranted: false, conversationID: owner, terminal: terminal,
        actionPolicy: policy, toolAccessMode: .automatic)
    #expect(!logs.isError)
    #expect((try processToolPayload(logs)["output"] as? String)?.contains("Lima AI") == true)
    let ports = await AIProcessTools.execute(try processToolCall("process_ports", args),
        approvalGranted: false, conversationID: owner, terminal: terminal,
        actionPolicy: policy, toolAccessMode: .automatic)
    #expect(!ports.isError)
    #expect((try processToolPayload(ports)["registered_ports"] as? [[String: Any]])?.isEmpty == true)

    let killed = await AIProcessTools.execute(try processToolCall("process_kill", args),
        approvalGranted: true, conversationID: owner, terminal: terminal,
        actionPolicy: policy, toolAccessMode: .automatic)
    #expect(!killed.isError)
    #expect(try processToolPayload(killed)["request_accepted"] as? Bool == true)
    let deadline = Date().addingTimeInterval(8)
    var result = try terminal.status(sessionID: session.id)
    while result.state == .running && Date() < deadline {
        try await Task.sleep(for: .milliseconds(25))
        result = try terminal.status(sessionID: session.id)
    }
    #expect(result.state == .cancelled)
    try terminal.close(sessionID: session.id)
}
