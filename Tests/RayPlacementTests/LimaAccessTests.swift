import Darwin
import Foundation
import RayPlacementCore
import Security
import Testing
@testable import RayPlacement

private func accessRequest(_ method: String, id: Int = 1,
                           params: [String: Any] = [:]) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0", "id": id, "method": method, "params": params
    ])
}

private func accessResponse(_ data: Data?) throws -> [String: Any] {
    let payload = try #require(data)
    return try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
}

/// Opt-in integration tests share one service and one test Keychain namespace.
private actor LiveAccessTestGate {
    static let shared = LiveAccessTestGate()
    private var held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !held { held = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty { held = false }
        else { waiting.removeFirst().resume() }
    }
}

@Test func localAccessHTTPRejectsAmbiguousAndOversizedFraming() {
    let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
    let head = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:43821\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
    let parsed = LimaAccessHTTP.parse(Data((head + body).utf8))
    #expect(parsed?.method == "POST")
    #expect(parsed?.host == "127.0.0.1:43821")
    #expect(parsed?.origin == nil)
    #expect(parsed?.body == Data(body.utf8))
    if let parsed {
        #expect(LimaAccessHTTP.isTrustedLoopback(parsed, port: 43821))
    }
    let hostileHost = head.replacingOccurrences(of: "Host: 127.0.0.1:43821", with: "Host: attacker.example")
    if let request = LimaAccessHTTP.parse(Data((hostileHost + body).utf8)) {
        #expect(!LimaAccessHTTP.isTrustedLoopback(request, port: 43821))
    } else { Issue.record("Host rejection fixture did not parse") }
    let browserOrigin = head.replacingOccurrences(of: "\r\n\r\n",
                                                with: "\r\nOrigin: https://attacker.example\r\n\r\n")
    if let request = LimaAccessHTTP.parse(Data((browserOrigin + body).utf8)) {
        #expect(!LimaAccessHTTP.isTrustedLoopback(request, port: 43821))
    } else { Issue.record("Origin rejection fixture did not parse") }

    let networkHead = head.replacingOccurrences(of: "Host: 127.0.0.1:43821",
                                                 with: "Host: 192.168.1.12:43822")
    if let request = LimaAccessHTTP.parse(Data((networkHead + body).utf8)) {
        #expect(LimaAccessHTTP.isTrustedNetwork(request, address: "192.168.1.12", port: 43822))
        #expect(!LimaAccessHTTP.isTrustedNetwork(request, address: "192.168.1.13", port: 43822))
    } else { Issue.record("Network Host fixture did not parse") }
    let networkOrigin = networkHead.replacingOccurrences(of: "\r\n\r\n",
        with: "\r\nOrigin: https://192.168.1.12\r\n\r\n")
    if let request = LimaAccessHTTP.parse(Data((networkOrigin + body).utf8)) {
        #expect(!LimaAccessHTTP.isTrustedNetwork(request, address: "192.168.1.12", port: 43822))
    } else { Issue.record("Network Origin fixture did not parse") }

    let duplicate = head.replacingOccurrences(of: "\r\n\r\n",
                                               with: "\r\nContent-Length: \(body.utf8.count)\r\n\r\n")
    #expect(LimaAccessHTTP.parse(Data((duplicate + body).utf8)) == nil)
    let chunked = head.replacingOccurrences(of: "\r\n\r\n",
                                             with: "\r\nTransfer-Encoding: chunked\r\n\r\n")
    #expect(LimaAccessHTTP.parse(Data((chunked + body).utf8)) == nil)
    let signedLength = head.replacingOccurrences(of: "Content-Length: \(body.utf8.count)",
                                                    with: "Content-Length: +\(body.utf8.count)")
    #expect(LimaAccessHTTP.parse(Data((signedLength + body).utf8)) == nil)
    #expect(LimaAccessHTTP.parse(Data((head + body + "GET /mcp HTTP/1.1\r\n\r\n").utf8)) == nil)
    let oversizedHeader = "POST /mcp HTTP/1.1\r\nX-Filler: " + String(repeating: "x", count: 8_200)
    #expect(LimaAccessHTTP.parse(Data((oversizedHeader + "\r\n\r\n").utf8)) == nil)
    #expect(LimaAccessHTTP.parse(Data(repeating: 0, count: LimaAccessHTTP.maximumRequestBytes + 1)) == nil)
}

@Test func localAccessHTTPStopsAtAbsoluteDeadline() {
    var sockets: [Int32] = [-1, -1]
    guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
        Issue.record("Could not create a local socket pair")
        return
    }
    defer {
        _ = Darwin.close(sockets[0])
        _ = Darwin.close(sockets[1])
    }
    let prefix = Data("POST /mcp HTTP/1.1\r\nHost:".utf8)
    let sent = prefix.withUnsafeBytes { raw in
        Darwin.send(sockets[0], raw.baseAddress!, raw.count, 0)
    }
    #expect(sent == prefix.count)
    let deadline = ProcessInfo.processInfo.systemUptime + 0.02
    #expect(LimaAccessHTTP.readRequest(from: sockets[1], deadline: deadline) == nil)
}

@Test @MainActor func localAccessMCPAdvertisesOnlyBoundedReadTools() async throws {
    let note = MarkdownNote(title: "Launch plan", content: "A private local note.")
    let store = NotesStore(visualFixtures: [note])

    let initialize = try accessResponse(await LimaAccessMCP.handle(
        accessRequest("initialize"), access: .readOnly, notes: store))
    let info = try #require((initialize["result"] as? [String: Any])?["serverInfo"] as? [String: Any])
    #expect(info["name"] as? String == "Lima")

    let listed = try accessResponse(await LimaAccessMCP.handle(
        accessRequest("tools/list"), access: .readOnly, notes: store))
    let tools = try #require((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]])
    #expect(Set(tools.compactMap { $0["name"] as? String })
        == ["lima_capabilities", "get_lima_status", "search_notes", "read_note"])
    #expect(tools.allSatisfy {
        ($0["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true
    })

    let templates = try accessResponse(await LimaAccessMCP.handle(
        accessRequest("resources/templates/list"), access: .readOnly, notes: store))
    let resourceTemplates = try #require((templates["result"] as? [String: Any])?["resourceTemplates"] as? [[String: Any]])
    #expect(resourceTemplates.map { $0["uriTemplate"] as? String } == ["lima://notes/{id}"])

    let malformedParams = try JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0", "id": 3, "method": "tools/list", "params": ["not", "an", "object"]
    ])
    let invalid = try accessResponse(await LimaAccessMCP.handle(
        malformedParams, access: .readOnly, notes: store))
    #expect((invalid["error"] as? [String: Any])?["code"] as? Int == -32602)

    let status = try accessResponse(await LimaAccessMCP.handle(
        accessRequest("tools/call", params: ["name": "get_lima_status"]),
        access: .readOnly, notes: store))
    #expect((status["result"] as? [String: Any])?["isError"] as? Bool == false)

    let search = try accessResponse(await LimaAccessMCP.handle(
        accessRequest("tools/call", params: [
            "name": "search_notes", "arguments": ["query": "Launch"]
        ]), access: .readOnly, notes: store))
    let result = try #require(search["result"] as? [String: Any])
    #expect(result["isError"] as? Bool == false)
    let content = try #require(result["content"] as? [[String: Any]])
    #expect((content.first?["text"] as? String)?.contains(note.id.uuidString) == true)
}

/// Run only with LIMA_TEST_MODE=1 LIMA_ACCESS_LIVE_TESTS=1. The ordinary
/// suite never starts a listener or touches even the test Keychain namespace.
@Test @MainActor func pairedLoopbackMCPRejectsRevokedBearer() async throws {
    guard LimaTestEnvironment.isEnabled,
          ProcessInfo.processInfo.environment["LIMA_ACCESS_LIVE_TESTS"] == "1" else { return }
    await LiveAccessTestGate.shared.acquire()
    defer { Task { await LiveAccessTestGate.shared.release() } }
    let service = LimaAccessService.shared
    service.setLocalEnabled(true)
    #expect(service.isRunning)
    guard service.isRunning else { return }
    var pairedID: UUID?
    defer {
        if let pairedID { try? service.revoke(pairedID) }
        service.setLocalEnabled(false)
    }

    let token = try service.pairClient(named: "Lima Access integration fixture")
    pairedID = service.clients.last?.id
    let endpoint = try #require(URL(string: service.endpoint))
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    func send() async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try accessRequest("initialize")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        return (data, try #require(response as? HTTPURLResponse))
    }

    let (accepted, firstResponse) = try await send()
    #expect(firstResponse.statusCode == 200)
    #expect((try accessResponse(accepted)["result"] as? [String: Any]) != nil)

    service.setLocalEnabled(false)
    service.setLocalEnabled(true)
    #expect(service.isRunning)
    guard service.isRunning else { return }
    let (restarted, restartResponse) = try await send()
    #expect(restartResponse.statusCode == 200)
    #expect((try accessResponse(restarted)["result"] as? [String: Any]) != nil)

    if let pairedID { try service.revoke(pairedID) }
    pairedID = nil
    let (_, revokedResponse) = try await send()
    #expect(revokedResponse.statusCode == 401)
}

private final class PinnedLimaTLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let certificate: SecCertificate

    init(certificate: SecCertificate) { self.certificate = certificate }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              CFEqual(leaf, certificate),
              SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

@Test @MainActor func isolatedTLSNetworkPairingScopesAndRevokesBearer() async throws {
    guard LimaTestEnvironment.isEnabled,
          ProcessInfo.processInfo.environment["LIMA_ACCESS_LIVE_TESTS"] == "1",
          let address = LimaAccessTLSIdentity.availableAddresses().first else { return }
    await LiveAccessTestGate.shared.acquire()
    defer { Task { await LiveAccessTestGate.shared.release() } }
    let service = LimaAccessService.shared
    var networkClientID: UUID?
    var localClientID: UUID?
    defer {
        if let networkClientID { try? service.revoke(networkClientID) }
        if let localClientID { try? service.revoke(localClientID) }
        try? service.setNetworkEnabled(false)
        service.setLocalEnabled(false)
    }
    try service.setNetworkEnabled(true, on: address)
    for _ in 0..<50 where !service.isNetworkRunning {
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    #expect(service.isNetworkRunning)
    guard service.isNetworkRunning,
          let endpoint = service.networkEndpoint,
          let url = URL(string: endpoint) else { return }
    let material = try LimaAccessTLSIdentity.loadOrCreate(for: address)
    var certificate: SecCertificate?
    #expect(SecIdentityCopyCertificate(material.identity, &certificate) == errSecSuccess)
    let pin = try #require(certificate)
    let session = URLSession(configuration: .ephemeral,
                             delegate: PinnedLimaTLSDelegate(certificate: pin), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let networkToken = try service.pairClient(named: "TLS integration fixture", transport: .network)
    networkClientID = service.clients.last?.id
    service.setLocalEnabled(true)
    #expect(service.isRunning)
    guard service.isRunning else { return }
    let localToken = try service.pairClient(named: "Local integration fixture")
    localClientID = service.clients.last?.id

    func send(to endpoint: URL, token: String, session: URLSession) async throws -> HTTPURLResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try accessRequest("initialize")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 5
        let (_, response) = try await session.data(for: request)
        return try #require(response as? HTTPURLResponse)
    }
    let localURL = try #require(URL(string: service.endpoint))
    #expect(try await send(to: url, token: networkToken, session: session).statusCode == 200)
    #expect(try await send(to: url, token: localToken, session: session).statusCode == 401)
    #expect(try await send(to: localURL, token: networkToken, session: session).statusCode == 401)

    try service.setNetworkEnabled(false)
    #expect(!service.networkEnabled && !service.isNetworkRunning)
    try service.setNetworkEnabled(true, on: address)
    for _ in 0..<50 where !service.isNetworkRunning {
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    #expect(service.isNetworkRunning)
    #expect(service.networkCertificateFingerprint == material.fingerprint)
    #expect(try await send(to: url, token: networkToken, session: session).statusCode == 200)

    if let networkClientID { try service.revoke(networkClientID) }
    networkClientID = nil
    #expect(try await send(to: url, token: networkToken, session: session).statusCode == 401)
}

@Test func isolatedNetworkTLSIdentityCanBeLoaded() async throws {
    guard LimaTestEnvironment.isEnabled,
          ProcessInfo.processInfo.environment["LIMA_ACCESS_LIVE_TESTS"] == "1",
          let address = LimaAccessTLSIdentity.availableAddresses().first else { return }
    await LiveAccessTestGate.shared.acquire()
    defer { Task { await LiveAccessTestGate.shared.release() } }
    let first = try LimaAccessTLSIdentity.loadOrCreate(for: address)
    let second = try LimaAccessTLSIdentity.loadOrCreate(for: address)
    #expect(first.certificatePEM == second.certificatePEM)
    #expect(first.fingerprint == second.fingerprint)
    #expect(first.certificatePEM.hasPrefix("-----BEGIN CERTIFICATE-----"))
    var certificate: SecCertificate?
    #expect(SecIdentityCopyCertificate(first.identity, &certificate) == errSecSuccess)
    #expect(certificate != nil)
}

@Test @MainActor func localAccessMCPBoundsResourcesAndRejectsActions() async throws {
    let note = MarkdownNote(title: "Long note", content: String(repeating: "a", count: 12_000))
    let store = NotesStore(visualFixtures: [note])

    let resource = try accessResponse(await LimaAccessMCP.handle(
        accessRequest("resources/read", params: ["uri": "lima://notes/\(note.id.uuidString)"]),
        access: .readOnly, notes: store))
    let contents = try #require((resource["result"] as? [String: Any])?["contents"] as? [[String: Any]])
    let text = try #require(contents.first?["text"] as? String)
    let value = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    #expect((value["content"] as? String)?.count == 10_000)
    #expect(value["next_offset"] as? Int == 10_000)

    for name in ["notes_create", "browser_click", "terminal_command"] {
        let denied = try accessResponse(await LimaAccessMCP.handle(
            accessRequest("tools/call", params: ["name": name, "arguments": [:] as [String: Any]]),
            access: .readOnly, notes: store))
        #expect((denied["error"] as? [String: Any])?["code"] as? Int == -32602)
    }
    #expect(!LimaAccessTLSIdentity.isPrivateIPv4("127.0.0.1"))
    #expect(LimaAccessTLSIdentity.isPrivateIPv4("192.168.1.12"))
    #expect(LimaAccessTLSIdentity.isPrivateIPv4("100.101.102.103"))
    #expect(!LimaAccessTLSIdentity.isPrivateIPv4("8.8.8.8"))
}
