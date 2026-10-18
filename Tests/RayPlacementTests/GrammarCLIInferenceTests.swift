import Foundation
import Testing
@testable import RayPlacement

private actor GrammarRuntimeFixture: GrammarToolFreeRuntime {
    private var calls: [GrammarToolFreeRequest] = []

    func infer(_ request: GrammarToolFreeRequest) async throws -> String {
        calls.append(request)
        if request.instructions.contains("adjudicator") {
            return #"{"decisions":[{"issue_id":"issue-1","winner":"minimal-editor","confidence":0.95}]}"#
        }
        if request.instructions.contains("corrected_text") {
            return #"{"corrected_text":"This is correct."}"#
        }
        if request.input.contains("Connection check") {
            return request.provider == .codexCLI ? #"{"changes":[]}"# : "OK"
        }
        return #"{"changes":[{"find":"This are","replacement":"This is","before":null,"after":null}]}"#
    }

    func captured() -> [GrammarToolFreeRequest] { calls }
}

@Test @MainActor func grammarCLIInferenceUsesIsolatedStructuredRequests() async throws {
    let runtime = GrammarRuntimeFixture()
    let client = GrammarInferenceClient(runtime: runtime)
    let configuration = DeveloperGrammarConfiguration(
        provider: .codexCLI, apiKey: "", model: "default", baseURL: ""
    )
    let changes = try await client.correctDocument(
        "This are correct.", configuration: configuration,
        systemPrompt: StealthGrammarRemoteClient.systemPrompt,
        temperature: 0.1, reasoningEffort: "high"
    )
    #expect(changes.count == 1)
    #expect(changes.first?.find == "This are")
    #expect(changes.first?.replacement == "This is")

    let decisions = try await client.judgeDocument(
        contextText: "This are correct.", candidateSummary: "issue-1: minimal-editor",
        configuration: configuration
    )
    #expect(decisions.first?.winner == "minimal-editor")
    let corrected = try await client.correctText("This are correct.", configuration: configuration)
    #expect(corrected == "This is correct.")
    try await client.testConnection(configuration: configuration)

    let calls = await runtime.captured()
    #expect(calls.count == 4)
    #expect(calls.allSatisfy { $0.provider == .codexCLI && $0.model == "default" })
    #expect(calls.allSatisfy { !$0.instructions.contains("Previous Lima conversation") })
    #expect(calls.allSatisfy { !$0.instructions.contains("AVAILABLE LIMA TOOLS") })
    #expect(calls[0].input == "This are correct.")
    #expect(calls[0].reasoningEffort == .high)
    let schema = try #require(JSONSerialization.jsonObject(with: calls[0].outputSchema) as? [String: Any])
    #expect((schema["properties"] as? [String: Any])?["changes"] != nil)
    let judgeSchema = try #require(JSONSerialization.jsonObject(with: calls[1].outputSchema) as? [String: Any])
    #expect((judgeSchema["properties"] as? [String: Any])?["decisions"] != nil)
}

@Test @MainActor func grammarCLICapabilitiesRequireNeitherAPIKeyNorEndpoint() {
    #expect(AIProvider.writingProviders.contains(.codexCLI))
    #expect(AIProvider.writingProviders.contains(.claudeCLI))
    for provider in [AIProvider.codexCLI, .claudeCLI] {
        #expect(provider.access == .localCLI)
        #expect(!provider.requiresGrammarAPIKey)
        #expect(!provider.requiresGrammarBaseURL)
        #expect(!provider.allowsGrammarLocalFallback)
        #expect(provider.defaultModel == "default")
    }
    #expect(AIProvider.openAI.requiresGrammarAPIKey)
    #expect(AIProvider.openAI.allowsGrammarLocalFallback)
    #expect(AIProvider.openAICompatible.requiresGrammarBaseURL)
    #expect(!AIProvider.openAICompatible.requiresGrammarAPIKey)
}

@Test func codexGrammarAppServerSendsEmptyToolsAndStructuredSchemaOnFreshThreads() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LimaGrammarAppServerFixture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("fake-codex")
    let launches = directory.appendingPathComponent("launches.txt")
    let script = #"""
    #!/usr/bin/python3
    import json, os, sys
    args = sys.argv[1:]
    required = [("--disable", name) for name in ["shell_tool", "multi_agent", "skill_search", "view_image", "image_generation", "standalone_web_search"]]
    required += [("--config", 'web_search="disabled"')]
    home = os.environ.get("CODEX_HOME", "")
    if args[:2] != ["app-server", "--stdio"] or any(not any(args[i:i+2] == list(pair) for i in range(len(args) - 1)) for pair in required) or os.path.realpath(home) != os.getcwd() or os.path.exists(os.path.join(home, "config.toml")):
        sys.exit(3)
    with open("__LAUNCH_LOG__", "a") as f:
        f.write("started\n")
    counter = 0
    def send(value):
        sys.stdout.write(json.dumps(value) + "\n")
        sys.stdout.flush()
    for line in sys.stdin:
        message = json.loads(line)
        method = message.get("method")
        request_id = message.get("id")
        params = message.get("params", {})
        if method == "initialize":
            send({"id": request_id, "result": {"capabilities": {}}})
        elif method == "thread/start":
            if params.get("dynamicTools") != [] or params.get("sandbox") != "read-only" or params.get("approvalPolicy") != "never" or not params.get("ephemeral"):
                send({"id": request_id, "error": {"message": "Grammar thread was not isolated"}})
            else:
                counter += 1
                send({"id": request_id, "result": {"thread": {"id": "grammar-" + str(counter)}}})
        elif method == "turn/start":
            schema = params.get("outputSchema", {})
            if "changes" not in schema.get("properties", {}) or params.get("effort") != "high":
                send({"id": request_id, "error": {"message": "Missing Grammar schema"}})
            else:
                thread = params["threadId"]
                send({"id": request_id, "result": {"turn": {"id": "turn-" + thread}}})
                if "Try native tool" in params.get("input", [{}])[0].get("text", ""):
                    send({"method": "item/started", "params": {"threadId": thread, "item": {"type": "commandExecution", "id": "native-tool"}}})
                else:
                    send({"method": "item/agentMessage/delta", "params": {"threadId": thread, "delta": json.dumps({"changes": []})}})
                    send({"method": "turn/completed", "params": {"threadId": thread, "turn": {"id": "turn-" + thread, "status": "completed"}}})
    """#.replacingOccurrences(of: "__LAUNCH_LOG__", with: launches.path)
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let client = CodexAppServerClient(executableURL: executable, toolFreeProcess: true)
    let schema: [String: Any] = [
        "type": "object", "properties": ["changes": ["type": "array", "items": ["type": "object"]]],
        "required": ["changes"], "additionalProperties": false
    ]
    do {
        let first = try await client.inferToolFree(model: "default", input: "First", instructions: "Grammar only.", outputSchema: schema, effort: .high)
        let second = try await client.inferToolFree(model: "default", input: "Second", instructions: "Grammar only.", outputSchema: schema, effort: .high)
        #expect((try JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any])?["changes"] is [Any])
        #expect((try JSONSerialization.jsonObject(with: Data(second.utf8)) as? [String: Any])?["changes"] is [Any])
        #expect(try String(contentsOf: launches).split(separator: "\n").count == 1)
        let status = await client.status()
        #expect(status.connected)
        #expect(!status.threadActive)
        do {
            _ = try await client.inferToolFree(model: "default", input: "Try native tool", instructions: "Grammar only.", outputSchema: schema, effort: .high)
            Issue.record("An isolated Grammar turn must reject native tool activity.")
        } catch {
            #expect(error.localizedDescription.contains("tool call"))
        }
    } catch {
        await client.shutdown()
        throw error
    }
    await client.shutdown()
}

@Test func cancelledCodexGrammarTurnResetsItsPooledLaneBeforeReuse() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LimaGrammarPoolFixture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("fake-codex")
    let launches = directory.appendingPathComponent("launches.txt")
    let ready = directory.appendingPathComponent("first-turn-ready")
    let script = #"""
    #!/usr/bin/python3
    import json, sys, time
    args = sys.argv[1:]
    required = [("--disable", "shell_tool"), ("--disable", "multi_agent"), ("--disable", "skill_search")]
    if args[:2] != ["app-server", "--stdio"] or any(not any(args[i:i+2] == list(pair) for i in range(len(args) - 1)) for pair in required):
        sys.exit(3)
    with open("__LAUNCH_LOG__", "a+") as f:
        f.seek(0)
        launch = len(f.readlines()) + 1
        f.write("started\n")
    def send(value):
        sys.stdout.write(json.dumps(value) + "\n")
        sys.stdout.flush()
    for line in sys.stdin:
        message = json.loads(line)
        method = message.get("method")
        request_id = message.get("id")
        params = message.get("params", {})
        if method == "initialize":
            send({"id": request_id, "result": {"capabilities": {}}})
        elif method == "thread/start":
            if params.get("dynamicTools") != [] or not params.get("ephemeral"):
                send({"id": request_id, "error": {"message": "Grammar tools or history leaked"}})
            else:
                send({"id": request_id, "result": {"thread": {"id": "grammar-" + str(launch)}}})
        elif method == "turn/start":
            thread = params["threadId"]
            send({"id": request_id, "result": {"turn": {"id": "turn-" + thread}}})
            if launch == 1:
                with open("__READY_MARKER__", "w") as f:
                    f.write("ready")
                while True:
                    send({"method": "item/agentMessage/delta", "params": {"threadId": thread, "delta": " "}})
                    time.sleep(0.05)
            else:
                send({"method": "item/agentMessage/delta", "params": {"threadId": thread, "delta": json.dumps({"changes": []})}})
                send({"method": "turn/completed", "params": {"threadId": thread, "turn": {"id": "turn-" + thread, "status": "completed"}}})
    """#
        .replacingOccurrences(of: "__LAUNCH_LOG__", with: launches.path)
        .replacingOccurrences(of: "__READY_MARKER__", with: ready.path)
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

    let schema: [String: Any] = [
        "type": "object", "properties": ["changes": ["type": "array", "items": ["type": "object"]]],
        "required": ["changes"], "additionalProperties": false
    ]
    let request = GrammarToolFreeRequest(
        provider: .codexCLI, model: "default", instructions: "Grammar only.",
        input: "Check this text.", outputSchema: try JSONSerialization.data(withJSONObject: schema),
        reasoningEffort: .low
    )
    let pool = CodexGrammarPool(size: 1, executableURL: executable)
    let cancelled = Task { try await pool.infer(request) }
    for _ in 0..<200 {
        if FileManager.default.fileExists(atPath: ready.path) { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(FileManager.default.fileExists(atPath: ready.path))
    cancelled.cancel()
    do {
        _ = try await cancelled.value
        Issue.record("A cancelled Grammar candidate must not return a partial result.")
    } catch is CancellationError {
        // Expected: cancellation also forces the lane to discard the active process.
    }
    do {
        let result = try await pool.infer(request)
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        #expect(parsed["changes"] is [Any])
        #expect(try String(contentsOf: launches).split(separator: "\n").count == 2)
    } catch {
        await pool.shutdown()
        throw error
    }
    await pool.shutdown()
}

@Test @MainActor func liveCodexGrammarToolFreeConnectionSmoke() async throws {
    guard ProcessInfo.processInfo.environment["LIMA_TEST_LIVE_GRAMMAR_CODEX"] == "1",
          LimaTestEnvironment.allowsLiveAI else { return }

    let pool = CodexGrammarPool(size: 1)
    let client = GrammarInferenceClient(runtime: DefaultGrammarToolFreeRuntime(codexPool: pool))
    let configuration = DeveloperGrammarConfiguration(
        provider: .codexCLI, apiKey: "", model: "default", baseURL: ""
    )
    do {
        try await client.testConnection(configuration: configuration)
    } catch {
        await pool.shutdown()
        throw error
    }
    await pool.shutdown()
}

@Test func claudeGrammarCLIProcessReceivesNoToolsOrChatFraming() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LimaGrammarClaudeFixture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("fake-claude")
    let script = #"""
    #!/usr/bin/python3
    import json, sys
    args = sys.argv[1:]
    prompt = sys.stdin.read()
    if "--tools" not in args or args[args.index("--tools") + 1] != "" or "AVAILABLE LIMA TOOLS" in prompt or "Previous Lima conversation" in prompt:
        print(json.dumps({"is_error": True, "result": ""}))
    elif "<grammar_input>" not in prompt or "This are wrong." not in prompt:
        print(json.dumps({"is_error": True, "result": ""}))
    else:
        print(json.dumps({"is_error": False, "result": json.dumps({"changes": []})}))
    """#
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let reply = try await CLIChatProviderClient.inferToolFree(
        provider: .claudeCLI, model: "default", input: "This are wrong.",
        instructions: "Return JSON.", executableURL: executable
    )
    #expect((try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])?["changes"] is [Any])
}
