import Foundation
import Testing
@testable import RayPlacement

@Test @MainActor func workbenchNativeBrowserFixtureCoversReadActionsAndHumanTakeover() async throws {
    try await AIWorkbenchSelfTest.checkBrowser()
}

@Test @MainActor func workbenchNativeTerminalFixtureCoversPTYRoundTrip() async throws {
    try await AIWorkbenchSelfTest.checkTerminal()
}

@Test @MainActor func workbenchNativeFileFixtureRoundTrips() throws {
    try AIWorkbenchSelfTest.checkFiles()
}

@Test @MainActor func workbenchRegistryContainsRequiredBridgeAndRuntimeTools() async throws {
    try await AIWorkbenchSelfTest.checkRegistry()
    let ids = Set(LimaAIToolRegistry.validDefinitions.map(\.id))
    #expect(ids.contains("browser_read"))
    #expect(ids.contains("terminal_start"))
    #expect(ids.contains("lima_capabilities"))
}

@Test @MainActor func workbenchDiagnosticsSeparatesProviderToolsBrowserTerminalAndSelfTest() async {
    let snapshot = await DiagnosticsService.shared.workbenchSnapshot()
    let provider = snapshot["provider"] as? [String: Any]
    let tools = snapshot["tools"] as? [String: Any]
    let browser = snapshot["browser"] as? [String: Any]
    let terminal = snapshot["terminal"] as? [String: Any]
    let selfTest = snapshot["selfTest"] as? [String: Any]
    #expect(provider?["kind"] is String)
    #expect(tools?["exposedCount"] is Int)
    #expect(tools?["recentExecutions"] is [[String: Any]])
    #expect(browser?["controlMode"] is String)
    #expect(browser?["explicitlyPaused"] is Bool)
    #expect(terminal?["sessionCount"] is Int)
    #expect(selfTest?["checks"] is [[String: Any]])
}

@Test @MainActor func workbenchProviderToolOutputUsesContinuationEnvelope() {
    let output = AIWorkbenchSelfTest.providerToolOutput(
        callID: "call-123", output: #"{"ok":true}"#
    )
    #expect(output["type"] as? String == "function_call_output")
    #expect(output["call_id"] as? String == "call-123")
    #expect(output["output"] as? String == #"{"ok":true}"#)
}

@Test @MainActor func liveCodexAppServerWorkbenchBridgeSmoke() async throws {
    guard ProcessInfo.processInfo.environment["LIMA_WORKBENCH_LIVE_CODEX"] == "1" else { return }
    try await AIWorkbenchSelfTest.checkProvider(provider: .codexCLI, model: "default", endpoint: "")
}

/// This local fake validates the Swift JSON-RPC transport, streamed text, native
/// dynamic tool requests and same-turn continuation without network or sign-in.
@Test func codexAppServerBridgeStreamsAndContinuesInSameTurn() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LimaAppServerFixture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("fake-codex")
    let script = #"""
    #!/usr/bin/python3
    import json, sys

    def send(value):
        sys.stdout.write(json.dumps(value) + "\n")
        sys.stdout.flush()

    received = set()
    for line in sys.stdin:
        message = json.loads(line)
        method = message.get("method")
        request_id = message.get("id")
        if method == "initialize":
            send({"id": request_id, "result": {"capabilities": {}}})
        elif method == "thread/start":
            tools = message.get("params", {}).get("dynamicTools", [])
            if len(tools) != 1 or tools[0].get("name") != "lima_capabilities":
                send({"id": request_id, "error": {"message": "Missing native dynamic tool"}})
            else:
                send({"id": request_id, "result": {"thread": {"id": "thread-fixture"}}})
        elif method == "turn/start":
            send({"id": request_id, "result": {"turn": {"id": "turn-fixture"}}})
            send({"method": "item/reasoning/summaryTextDelta", "params": {"threadId": "thread-fixture", "itemId": "reason-streamed", "delta": "First "}})
            send({"method": "item/reasoning/textDelta", "params": {"threadId": "thread-fixture", "itemId": "reason-streamed", "delta": "private trace"}})
            send({"method": "item/reasoning/summaryTextDelta", "params": {"threadId": "thread-fixture", "itemId": "reason-streamed", "delta": "second."}})
            send({"method": "item/completed", "params": {"threadId": "thread-fixture", "item": {
                "id": "reason-streamed", "type": "reasoning", "summary": ["First second."]
            }}})
            send({"method": "item/completed", "params": {"threadId": "thread-fixture", "item": {
                "id": "reason-completed", "type": "reasoning", "summary": [" Completed."]
            }}})
            send({"method": "item/agentMessage/delta", "params": {"threadId": "thread-fixture", "delta": "Before "}})
            for rpc_id, call_id in [(991, "call-fixture"), (992, "call-fixture-2")]:
                send({"id": rpc_id, "method": "item/tool/call", "params": {
                    "threadId": "thread-fixture", "turnId": "turn-fixture",
                    "callId": call_id, "tool": "lima_capabilities", "arguments": {}
                }})
        elif request_id in (991, 992):
            body = message.get("result", {})
            has_image = any(item.get("type") == "inputImage" for item in body.get("contentItems", []))
            if body.get("success") is not True or has_image != (request_id == 991):
                send({"method": "error", "params": {"threadId": "thread-fixture", "message": "Tool result mismatch"}})
            else:
                received.add(request_id)
                if len(received) == 2:
                    send({"method": "item/agentMessage/delta", "params": {"threadId": "thread-fixture", "delta": "After"}})
                    send({"method": "turn/completed", "params": {
                        "threadId": "thread-fixture", "turn": {"id": "turn-fixture", "status": "completed"}
                    }})
        elif method == "turn/interrupt":
            send({"id": request_id, "result": {}})
    """#
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let client = CodexAppServerClient(executableURL: executable)
    defer { Task { await client.shutdown() } }
    let tool = try #require(AIContextTools.definitions.first { $0.id == "lima_capabilities" })
    let initial = AIProviderStreamWatchdog.bounded(client.streamReply(
        apiKey: "", model: "default", input: "Use the capability tool.", history: [],
        previousResponseID: nil, reasoningEffort: .low, attachments: [],
        localTools: [tool], systemInstructions: "Use the tool."
    ), after: .seconds(5))
    var firstText = ""
    var firstReasoning = ""
    var toolCalls: [AIOutputItem] = []
    var responseID: String?
    for try await event in initial {
        switch event {
        case .responseCreated(let id): responseID = id
        case .textDelta(let delta): firstText += delta
        case .reasoningSummaryDelta(let delta): firstReasoning += delta
        case .outputItem(let item): toolCalls.append(item)
        case .failed(let message): Issue.record("Fake app-server failed: \(message)")
        default: break
        }
    }
    #expect(firstText == "Before ")
    #expect(firstReasoning == "First second. Completed.")
    #expect(toolCalls.count == 2)
    #expect(toolCalls.allSatisfy { $0.name == "lima_capabilities" && $0.arguments == "{}" })
    let threadID = try #require(responseID)
    let firstCallID = try #require(toolCalls.first?.callID)
    let secondCallID = try #require(toolCalls.last?.callID)
    let screenshotInput: [String: Any] = ["role": "user", "content": [
        ["type": "input_text", "text": "Browser screenshot from tool call \(firstCallID)."],
        ["type": "input_image", "image_url": "data:image/jpeg;base64,/9j/"]
    ]]
    let resumed = AIProviderStreamWatchdog.bounded(client.streamToolOutputs(
        apiKey: "", model: "default", previousResponseID: threadID, history: [],
        outputs: [["type": "function_call_output", "call_id": firstCallID,
                   "output": #"{"ok":true}"#],
                  ["type": "function_call_output", "call_id": secondCallID,
                   "output": #"{"ok":true}"#], screenshotInput],
        reasoningEffort: .low, localTools: [tool], systemInstructions: "Use the tool."
    ), after: .seconds(5))
    var secondText = ""
    var completed = false
    for try await event in resumed {
        switch event {
        case .textDelta(let delta): secondText += delta
        case .completed: completed = true
        case .failed(let message): Issue.record("Fake app-server continuation failed: \(message)")
        default: break
        }
    }
    #expect(secondText == "After")
    #expect(completed)
    let status = await client.status()
    #expect(status.connected)
    #expect(status.continuationCount == 1)
    #expect(status.startupMilliseconds != nil)
    #expect(status.firstEventMilliseconds != nil)
    #expect(status.firstTextMilliseconds != nil)
    await client.shutdown()
    let restarted = AIProviderStreamWatchdog.bounded(client.streamReply(
        apiKey: "", model: "default", input: "Use the capability tool again.", history: [],
        previousResponseID: nil, reasoningEffort: .low, attachments: [],
        localTools: [tool], systemInstructions: "Use the tool."
    ), after: .seconds(5))
    var restartedCall = false
    for try await event in restarted {
        if case .outputItem(let item) = event, item.name == "lima_capabilities" {
            restartedCall = true
        }
    }
    #expect(restartedCall)
    await client.shutdown()
}
