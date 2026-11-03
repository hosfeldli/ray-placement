import Foundation
import Testing
@testable import RayPlacement

@Test func openCodeProviderUsesLocalLoginAndExplicitModels() throws {
    #expect(AIProvider.chatProviders.contains(.opencodeCLI))
    #expect(AIProvider.writingProviders.contains(.opencodeCLI))
    #expect(AIProvider.opencodeCLI.isCLI)
    #expect(!AIProvider.opencodeCLI.requiresGrammarAPIKey)
    #expect(AIProvider.opencodeCLI.supportsChatImages)
    #expect(AIProviderClientRegistry.client(for: .opencodeCLI, openAICompatibleBaseURL: "") is CLIChatProviderClient)
    let args = CLIChatProviderClient.arguments(for: .opencodeCLI, model: "fixture/model", workingDirectory: URL(fileURLWithPath: "/tmp"), imageURLs: [URL(fileURLWithPath: "/tmp/frame.jpg")])
    #expect(args == ["run", "--format", "json", "--agent", "lima", "--model", "fixture/model", "--file", "/tmp/frame.jpg"])
    let env = try CLIChatProviderClient.openCodeEnvironment(in: ["PATH":"/fixture", "OPENCODE_PERMISSION":"allow", "OPENCODE_CONFIG_CONTENT":#"{"provider":{"fixture":{"name":"Custom endpoint"}},"model":"fixture/model"}"#])
    #expect(env["PATH"] == "/fixture")
    #expect(env["OPENCODE_PERMISSION"] == #"{"*":"deny"}"#)
    let rawConfig = try #require(env["OPENCODE_CONFIG_CONTENT"])
    let config = try #require(JSONSerialization.jsonObject(with: Data(rawConfig.utf8)) as? [String:Any])
    #expect(config["permission"] as? String == "deny")
    #expect(config["model"] as? String == "fixture/model")
    #expect((config["provider"] as? [String:Any])?["fixture"] != nil)
    #expect(throws: (any Error).self) { try CLIChatProviderClient.openCodeEnvironment(in: ["OPENCODE_CONFIG_CONTENT":"invalid"]) }
    let agents = try #require(config["agent"] as? [String:[String:Any]])
    #expect(agents["lima"]?["permission"] as? String == "deny")
    #expect(config["share"] as? String == "disabled")
    #expect(CLIChatProviderClient.openCodeModels(from: Data("fixture/model\nnoise\nfixture/model\n--model malicious/x\nsecond/model\n".utf8)).map(\.id) == ["default", "fixture/model", "second/model"])
}

@Test func openCodeEventsKeepTextAndRejectZeroExitErrors() throws {
    let data = Data(#"""
    {"type":"reasoning","part":{"text":"hidden fixture reasoning"}}
    {"type":"text","part":{"id":"a","text":"Hello"}}
    {"type":"text","part":{"id":"a","text":"Hello world"}}
    {"type":"text","part":{"id":"b","text":"Second paragraph"}}
    """#.utf8)
    #expect(try CLIChatProviderClient.extractReply(from: data, provider: .opencodeCLI) == "Hello world\nSecond paragraph")
    let error = Data(#"{"type":"error","error":{"name":"APIError","data":{"statusCode":401,"message":"private token fixture-secret"}}}"#.utf8)
    do {
        _ = try CLIChatProviderClient.extractReply(from: error, provider: .opencodeCLI)
        Issue.record("A zero-exit provider error must fail the response")
    } catch {
        #expect(!error.localizedDescription.contains("fixture-secret"))
        guard case CLIChatProviderClient.Failure.diagnosed(let diagnostic) = error else { Issue.record("Expected provider diagnostic"); return }
        #expect(diagnostic.code == "authentication_error")
    }
    #expect(throws: (any Error).self) { try CLIChatProviderClient.extractReply(from: Data(#"{"type":"step_start"}"#.utf8), provider: .opencodeCLI) }
}

@Test func openCodeSubprocessDiscoversModelsAndCompletesLimaToolRoundTrip() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LimaOpenCodeFixture-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("opencode")
    let script = #"""
    #!/usr/bin/python3
    import sys, os, json
    config=json.loads(os.environ['OPENCODE_CONFIG_CONTENT'])
    assert config['agent']['lima']['permission']=='deny'
    assert json.loads(os.environ['OPENCODE_PERMISSION'])=={'*':'deny'}
    assert os.environ['OPENCODE_DISABLE_PROJECT_CONFIG']=='true'
    if sys.argv[1:] == ['models']:
        print('fixture/model')
        sys.exit(0)
    assert sys.argv[1:7] == ['run','--format','json','--agent','lima','--model']
    prompt=sys.stdin.read()
    assert prompt
    if 'fixture-found-value' in prompt:
        text=json.dumps({'kind':'answer','text':'fixture-found-value','tool':'','arguments':''})
    else:
        text=json.dumps({'kind':'tool_call','text':'','tool':'lima_fixture','arguments':'{}'})
    print(json.dumps({'type':'text','part':{'id':'fixture-part','text':text}}))
    """#
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let client = CLIChatProviderClient(provider: .opencodeCLI, executableURL: executable)
    #expect(try await client.listModels(apiKey: "").map(\.id) == ["default", "fixture/model"])
    let tool = LimaAIToolDefinition(id: "lima_fixture", name: "lima_fixture", description: "Fixture lookup", parameters: ["type":"object", "properties":[:], "additionalProperties":false], risk: .read)
    var call: AIOutputItem?
    for try await event in client.streamReply(apiKey: "", model: "fixture/model", input: "Look up the fixture", history: [], previousResponseID: nil, reasoningEffort: .low, attachments: [], localTools: [tool], systemInstructions: "Use Lima tools") {
        if case .outputItem(let item) = event { call = item }
    }
    #expect(call?.name == tool.name)
    let callID = try #require(call?.callID)
    let history = [AIProviderMessage(role: .assistant, content: [.toolUse(id: callID, name: tool.name, arguments: "{}")]), AIProviderMessage(role: .user, content: [.toolResult(id: callID, output: "fixture-found-value")])]
    var answer = ""
    for try await event in client.streamToolOutputs(apiKey: "", model: "fixture/model", previousResponseID: "fixture", history: history, outputs: [], reasoningEffort: .low, localTools: [tool], systemInstructions: "Use Lima tools") {
        if case .textDelta(let text) = event { answer += text }
    }
    #expect(answer == "fixture-found-value")
}

@Test @MainActor func openCodeDiscoveredModelsAppearWithoutDiscardingCustomSelection() {
    let suite = "LimaOpenCodeModelTest-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let catalog = AIModelCatalogStore(defaults: defaults)
    catalog.replace([AIModelOption(id: "fixture/model", displayName: "Fixture")], for: .opencodeCLI)
    #expect(catalog.models(for: .opencodeCLI, compatibleModelID: "").contains { $0.id == "fixture/model" })
    #expect(catalog.listedIDs(for: .opencodeCLI).contains("fixture/model"))
    let conversation = AIConversation(provider: .opencodeCLI, model: "fixture/custom")
    let model = AIChatViewModel(store: AIConversationStore(fixtures: [conversation]),
        credentials: AIChatCredentialStore(configuration: .fixture), nativeToolStore: LimaAIToolStore(fixtures: []),
        transport: FixtureAITransport.standard, taskRegistry: TaskRegistry(), modelCatalog: catalog)
    #expect(model.pickerModels.contains { $0.id == "fixture/model" })
    #expect(model.pickerModels.contains { $0.id == "fixture/custom" })
    #expect(model.model == "fixture/custom")
}
