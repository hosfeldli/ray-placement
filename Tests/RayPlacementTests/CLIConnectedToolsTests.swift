import Foundation
import Testing
@testable import RayPlacement

private final class CLIMCPMock: URLProtocol {
    struct State {
        var requests: [[String: Any]] = []
        var mode = "json"
        var stream: CLIMCPMock?
    }
    static let lock = NSLock()
    static var states: [String: State] = [:]

    static func install(host: String, mode: String) {
        lock.lock(); defer { lock.unlock() }
        states[host] = State(mode: mode)
    }

    static func recorded(host: String) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return states[host]?.requests ?? []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url!.host!
        Self.lock.lock()
        let mode = Self.states[host]?.mode ?? "json"
        Self.lock.unlock()
        if request.httpMethod == "GET" {
            Self.lock.lock(); Self.states[host]?.stream = self; Self.lock.unlock()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("event: endpoint\ndata: /messages\n\n".utf8))
            return
        }
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        Self.lock.lock(); Self.states[host]?.requests.append(body); Self.lock.unlock()
        let method = body["method"] as? String ?? ""
        if mode == "auth" {
            respond(status: 401, data: Data("private upstream details".utf8))
            return
        }
        if method == "notifications/initialized" {
            respond(status: 202, data: Data())
            return
        }
        let result: [String: Any]
        if method == "initialize" {
            result = ["protocolVersion": "2025-06-18", "capabilities": ["tools": [:]], "serverInfo": ["name": "Fixture", "version": "1"]]
        } else if method == "tools/list" {
            let params = body["params"] as? [String: Any]
            let tool = Self.tool(name: params?["cursor"] != nil ? "lookup_second" : "lookup",
                                 readOnly: mode != "drift")
            if mode == "paged" && params?["cursor"] == nil {
                result = ["tools": [tool], "nextCursor": "second"]
            } else { result = ["tools": [tool]] }
        } else {
            result = ["content": [["type": "text", "text": "actual MCP evidence"]],
                      "structuredContent": ["value": "blue"], "isError": mode == "tool-error"]
        }
        let envelope: [String: Any] = ["jsonrpc": "2.0", "id": body["id"] ?? "", "result": result]
        let response = try! JSONSerialization.data(withJSONObject: envelope)
        if method == "tools/list" && mode == "stall-list" { return }
        if method == "tools/list" && mode == "delay-list" {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                self.respond(status: 200, data: response)
            }
            return
        }
        if mode == "legacy" {
            respond(status: 202, data: Data())
            Self.lock.lock(); let stream = Self.states[host]?.stream; Self.lock.unlock()
            if let stream {
                stream.client?.urlProtocol(stream, didLoad: Data(("event: message\ndata: " + String(decoding: response, as: UTF8.self) + "\n\n").utf8))
            }
        } else if mode == "sse" {
            respond(status: 200, data: Data(("event: message\ndata: " + String(decoding: response, as: UTF8.self) + "\n\n").utf8),
                    contentType: "text/event-stream")
        } else {
            respond(status: 200, data: response)
        }
    }

    private func respond(status: Int, data: Data, contentType: String = "application/json") {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": contentType, "MCP-Session-Id": "fixture-session"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        guard let host = request.url?.host else { return }
        Self.lock.lock(); defer { Self.lock.unlock() }
        if Self.states[host]?.stream === self { Self.states[host]?.stream = nil }
    }

    static func tool(name: String, readOnly: Bool = true) -> [String: Any] {
        ["name": name, "description": "Look up fixture evidence.",
         "annotations": ["readOnlyHint": readOnly],
         "inputSchema": ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]]]
    }
}

private func connectedFixture() -> MCPServer {
    let id = UUID()
    return MCPServer(id: id, name: "Fixture service", url: "https://" + id.uuidString.lowercased() + ".invalid/private-endpoint",
                     tools: [MCPToolDescriptor(serverID: id, name: "lookup", risk: .read, enabled: true, declaredReadOnly: true)])
}

private func mockSession() -> MCPLocalSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CLIMCPMock.self]
    return MCPLocalSession(configuration: configuration)
}

private func connectedCall(_ server: MCPServer, list: Bool = false) throws -> AIOutputItem {
    let arguments: [String: Any] = list
        ? ["server_id": server.id.uuidString, "offset": 0]
        : ["server_id": server.id.uuidString, "tool": "lookup", "arguments_json": "{\"query\":\"sample\"}"]
    return AIOutputItem(phase: .completed, apiType: "function_call", id: "call", callID: "call",
                        name: list ? CLIConnectedTools.listName : CLIConnectedTools.callName,
                        arguments: String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self))
}

@Test @MainActor func cliRequestCatalogIncludesAllEnabledNativeToolsWithoutKeywordGuessing() {
    let ids: Set<String> = ["get_lima_status", "browser_tabs", "browser_read", "search_notes", "read_note"]
    for provider in [AIProvider.codexCLI, .claudeCLI] {
        let conversation = AIConversation(provider: provider, model: "default")
        let server = connectedFixture()
        let model = AIChatViewModel(store: AIConversationStore(fixtures: [conversation]),
            credentials: AIChatCredentialStore(configuration: .fixture),
            mcpStore: MCPServerStore(fixtures: [server]), nativeToolStore: LimaAIToolStore(fixtures: ids),
            transport: FixtureAITransport.standard)
        #expect(Set(model.requestLocalTools(for: "Help with this").map(\.id)) == ids.union([CLIConnectedTools.listName, CLIConnectedTools.callName, CLIToolDiscovery.name]))
        #expect(model.routedMCPServers(for: "Help with this").map(\.id) == [server.id])
    }
}

@Test func cliConnectedCatalogKeepsEndpointsAndCredentialsOutOfPrompt() throws {
    let server = connectedFixture()
    let tools = CLIChatProviderClient.requestTools(localTools: CLIConnectedTools.definitions(servers: [server]), mcpServers: [server])
    #expect(tools.count == 3)
    let prompt = try CLIChatProviderClient.prompt(input: "Find evidence", history: [], attachments: [],
                                                systemInstructions: "", localTools: tools)
    #expect(prompt.contains(CLIConnectedTools.callName))
    #expect(!prompt.contains(server.url))
    let envelope = "{\"kind\":\"tool_call\",\"text\":\"\",\"tool\":\"\(CLIConnectedTools.listName)\",\"arguments\":\"{}\"}"
    #expect(try CLIChatProviderClient.events(from: envelope, localTools: tools).count == 3)
}

@Test func connectedToolIdentityAndEnablementAreRechecked() {
    let server = connectedFixture()
    var changed = server
    changed.enabled = false
    #expect(CLIConnectedTools.authorizedServer(id: server.id, allowed: [server], current: [changed]) == nil)
    changed = server; changed.url = "https://different.invalid"
    #expect(CLIConnectedTools.authorizedServer(id: server.id, allowed: [server], current: [changed]) == nil)
    changed = server; changed.tools[0].declaredReadOnly = nil
    #expect(CLIConnectedTools.authorizedServer(id: server.id, allowed: [server], current: [changed]) == nil)
    changed = server; changed.allowedToolNames = [MCPServer.noToolsSentinel]
    #expect(CLIConnectedTools.authorizedServer(id: server.id, allowed: [server], current: [changed]) == nil)
    #expect(CLIConnectedTools.authorizedServer(id: server.id, allowed: [], current: [server]) == nil)
}

@Test @MainActor func connectedToolsExecuteThroughHTTPAndBothSSETransports() async throws {
    for mode in ["json", "sse", "legacy"] {
        var server = connectedFixture()
        if mode == "legacy" { server.transport = .sse }
        let host = server.validHTTPURL!.host!
        CLIMCPMock.install(host: host, mode: mode)
        let result = await CLIConnectedTools.execute(try connectedCall(server), allowedServers: [server],
            store: MCPServerStore(fixtures: [server]), sessionFactory: mockSession)
        #expect(!result.isError, "\(mode): \(result.output)")
        #expect(result.output.contains("actual MCP evidence"))
        let methods = CLIMCPMock.recorded(host: host).compactMap { $0["method"] as? String }
        #expect(methods == ["initialize", "notifications/initialized", "tools/list", "tools/call"])
    }
}

@Test @MainActor func connectedToolsDiscoverFullSchemasAndPaginate() async throws {
    var server = connectedFixture()
    server.tools.append(MCPToolDescriptor(serverID: server.id, name: "lookup_second", risk: .read, enabled: true, declaredReadOnly: true))
    CLIMCPMock.install(host: server.validHTTPURL!.host!, mode: "paged")
    let result = await CLIConnectedTools.execute(try connectedCall(server, list: true), allowedServers: [server],
        store: MCPServerStore(fixtures: [server]), sessionFactory: mockSession)
    #expect(!result.isError)
    #expect(result.output.contains("inputSchema"))
    #expect(result.output.contains("lookup_second"))
    #expect(!CLIMCPMock.recorded(host: server.validHTTPURL!.host!).contains { $0["method"] as? String == "tools/call" })
}

@Test @MainActor func connectedToolsBlockSchemaDriftAndSurfaceSafeFailures() async throws {
    for mode in ["drift", "auth", "tool-error"] {
        let server = connectedFixture()
        let host = server.validHTTPURL!.host!
        CLIMCPMock.install(host: host, mode: mode)
        let result = await CLIConnectedTools.execute(try connectedCall(server), allowedServers: [server],
            store: MCPServerStore(fixtures: [server]), sessionFactory: mockSession)
        #expect(result.isError)
        #expect(!result.output.contains("private upstream details"))
        if mode != "tool-error" {
            #expect(!CLIMCPMock.recorded(host: host).contains { $0["method"] as? String == "tools/call" })
        }
    }
}

@Test @MainActor func connectedToolsRecheckRevocationAfterDiscovery() async throws {
    let server = connectedFixture()
    let host = server.validHTTPURL!.host!
    CLIMCPMock.install(host: host, mode: "delay-list")
    let store = MCPServerStore(fixtures: [server])
    let call = try connectedCall(server)
    let task = Task { await CLIConnectedTools.execute(call, allowedServers: [server], store: store, sessionFactory: mockSession) }
    for _ in 0..<100 where !CLIMCPMock.recorded(host: host).contains(where: { $0["method"] as? String == "tools/list" }) {
        try await Task.sleep(for: .milliseconds(1))
    }
    store.setEnabled(server.id, enabled: false)
    let result = await task.value
    #expect(result.isError)
    #expect(!CLIMCPMock.recorded(host: host).contains { $0["method"] as? String == "tools/call" })
}

@Test @MainActor func connectedToolCancellationStopsBeforeExecution() async throws {
    let server = connectedFixture()
    let host = server.validHTTPURL!.host!
    CLIMCPMock.install(host: host, mode: "stall-list")
    let call = try connectedCall(server)
    let task = Task { await CLIConnectedTools.execute(call, allowedServers: [server],
        store: MCPServerStore(fixtures: [server]), sessionFactory: mockSession) }
    for _ in 0..<100 where !CLIMCPMock.recorded(host: host).contains(where: { $0["method"] as? String == "tools/list" }) {
        try await Task.sleep(for: .milliseconds(1))
    }
    task.cancel()
    let result = await task.value
    #expect(result.isError)
    #expect(!CLIMCPMock.recorded(host: host).contains { $0["method"] as? String == "tools/call" })
}

@Test func mcpLocalResponsesRequireMatchingRequestIDs() throws {
    let data = Data(#"{"jsonrpc":"2.0","id":"other","result":{"content":[]}}"#.utf8)
    #expect(try MCPLocalSession.result(data: data, id: "expected") == nil)
    let error = Data(#"{"jsonrpc":"2.0","id":"expected","error":{"message":"sensitive body"}}"#.utf8)
    #expect(throws: MCPLocalSession.Failure.self) { _ = try MCPLocalSession.result(data: error, id: "expected") }
}
