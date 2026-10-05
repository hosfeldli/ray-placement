import Foundation

private final class MCPNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// One short-lived, sequential MCP session. The SSE receive stream remains
/// alive across initialize, tools/list, and tools/call for legacy servers.
// Owned by one sequential tool execution. Parsing and byte iteration run on
// the generic executor, never on the chat's main actor.
final class MCPLocalSession: @unchecked Sendable {
    enum Failure: LocalizedError {
        case invalidArguments, unavailable, invalidResponse, tooLarge, requestFailed, authentication
        var errorDescription: String? {
            switch self {
            case .invalidArguments: return "The connected-tool request has invalid arguments."
            case .unavailable: return "This connected-service tool is no longer enabled or read-only. Check its configuration in Lima."
            case .invalidResponse: return "The connected service returned an incompatible MCP response."
            case .tooLarge: return "The connected service returned too much data. Use a narrower query."
            case .requestFailed: return "The connected service could not complete the request. Check its connection in Lima."
            case .authentication: return "The connected service needs authentication. Update its connection in Lima."
            }
        }
    }

    private let session: URLSession
    private var endpoint: URL?
    private var credential: String?
    private var sessionID: String?
    private var protocolVersion = "2025-06-18"
    private var legacy = false
    private var eventIterator: AsyncThrowingStream<AIProviderSSEFrame, Error>.Iterator?
    private var eventReader: Task<Void, Never>?
    private let maximumBytes = 2 * 1024 * 1024

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 120
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: MCPNoRedirectDelegate(), delegateQueue: nil)
    }

    func close() {
        eventReader?.cancel()
        eventReader = nil
        eventIterator = nil
        session.invalidateAndCancel()
    }

    func connect(server: MCPServer, credential: String?) async throws {
        guard let url = server.validHTTPURL else { throw Failure.invalidArguments }
        self.credential = credential
        legacy = server.transport == .sse
        endpoint = url
        if legacy { endpoint = try await openEventStream(url) }
        let result = try await rpc(method: "initialize", params: [
            "protocolVersion": protocolVersion, "capabilities": [:],
            "clientInfo": ["name": "Lima", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"]
        ])
        guard let version = result["protocolVersion"] as? String,
              ["2024-11-05", "2025-03-26", "2025-06-18"].contains(version) else {
            throw Failure.invalidResponse
        }
        protocolVersion = version
        _ = try await rpc(method: "notifications/initialized", params: [:], notification: true)
    }

    func listTools() async throws -> [[String: Any]] {
        var tools: [[String: Any]] = []
        var cursor: String?
        var seen = Set<String>()
        var size = 0
        for _ in 0..<32 {
            let result = try await rpc(method: "tools/list", params: cursor.map { ["cursor": $0] } ?? [:])
            guard let page = result["tools"] as? [[String: Any]] else { throw Failure.invalidResponse }
            size += try JSONSerialization.data(withJSONObject: page).count
            guard size <= maximumBytes, tools.count + page.count <= 2_000 else { throw Failure.tooLarge }
            tools += page
            guard let next = result["nextCursor"] as? String, !next.isEmpty else {
                let names = tools.compactMap { $0["name"] as? String }
                guard names.count == tools.count, Set(names).count == names.count else { throw Failure.invalidResponse }
                return tools
            }
            guard next.utf8.count <= 4096, seen.insert(next).inserted else { throw Failure.invalidResponse }
            cursor = next
        }
        throw Failure.tooLarge
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> [String: Any] {
        let result = try await rpc(method: "tools/call", params: ["name": name, "arguments": arguments])
        guard result["content"] is [[String: Any]] || result["structuredContent"] is [String: Any] else {
            throw Failure.invalidResponse
        }
        // Preserve JSON validity and structured results; do not silently truncate.
        guard try JSONSerialization.data(withJSONObject: result).count <= 56_000 else { throw Failure.tooLarge }
        return result
    }

    private func request(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let credential, !credential.isEmpty {
            request.setValue(MCPCredentialStore.authorizationHeaderValue(credential), forHTTPHeaderField: "Authorization")
        }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id") }
        request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        return request
    }

    private func rpc(method: String, params: [String: Any], notification: Bool = false) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard let endpoint else { throw Failure.invalidResponse }
        let id = UUID().uuidString
        var body: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if !notification { body["id"] = id }
        var request = request(url: endpoint, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await session.bytes(for: request)
        let http = try validated(response)
        if method == "initialize", let header = http.value(forHTTPHeaderField: "MCP-Session-Id") {
            guard header.utf8.count <= 4096,
                  !header.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw Failure.invalidResponse
            }
            sessionID = header
        }
        if notification { return [:] }
        if legacy && http.statusCode == 202 {
            while let frame = try await nextEvent() {
                if let result = try Self.result(data: Data(frame.data.utf8), id: id) { return result }
            }
            throw Failure.invalidResponse
        }
        let isSSE = http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true
        var data = Data()
        var framer = AIProviderSSEFramer(maximumLineBytes: maximumBytes, maximumEventBytes: maximumBytes,
                                       maximumStreamBytes: maximumBytes, maximumDataLines: 4096)
        for try await byte in bytes {
            try Task.checkCancellation()
            if isSSE {
                if let frame = try framer.append(byte),
                   let result = try Self.result(data: Data(frame.data.utf8), id: id) { return result }
            } else {
                guard data.count < maximumBytes else { throw Failure.tooLarge }
                data.append(byte)
            }
        }
        if isSSE {
            if let frame = try framer.finish(),
               let result = try Self.result(data: Data(frame.data.utf8), id: id) { return result }
        } else if let result = try Self.result(data: data, id: id) { return result }
        throw Failure.invalidResponse
    }

    static func result(data: Data, id: String) throws -> [String: Any]? {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["jsonrpc"] as? String == "2.0" else { throw Failure.invalidResponse }
        // Ignore notifications or responses belonging to other requests.
        guard object["id"] as? String == id else { return nil }
        if object["error"] != nil { throw Failure.requestFailed }
        guard let result = object["result"] as? [String: Any] else { throw Failure.invalidResponse }
        return result
    }

    private func validated(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        if [401, 403].contains(http.statusCode) { throw Failure.authentication }
        guard (200...299).contains(http.statusCode) else { throw Failure.requestFailed }
        return http
    }

    private func openEventStream(_ url: URL) async throws -> URL {
        var request = request(url: url, method: "GET")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        _ = try validated(response)
        let stream = AsyncThrowingStream<AIProviderSSEFrame, Error>(bufferingPolicy: .bufferingOldest(32)) { continuation in
            eventReader = Task {
                do {
                    var framer = AIProviderSSEFramer(maximumLineBytes: maximumBytes, maximumEventBytes: maximumBytes,
                                                   maximumStreamBytes: maximumBytes * 4, maximumDataLines: 4096)
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        if let frame = try framer.append(byte) {
                            if case .dropped = continuation.yield(frame) { throw Failure.tooLarge }
                        }
                    }
                    if let frame = try framer.finish() { continuation.yield(frame) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
        eventIterator = stream.makeAsyncIterator()
        while let frame = try await nextEvent() {
            if frame.event == "endpoint" {
                return try MCPHTTPClient.validatedSSEEndpoint(frame.data, relativeTo: url)
            }
        }
        throw Failure.invalidResponse
    }

    private func nextEvent() async throws -> AIProviderSSEFrame? {
        try Task.checkCancellation()
        guard var iterator = eventIterator else { throw Failure.invalidResponse }
        let event = try await iterator.next()
        eventIterator = iterator
        try Task.checkCancellation()
        return event
    }
}
