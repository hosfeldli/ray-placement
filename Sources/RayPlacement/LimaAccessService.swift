import Combine
import Darwin
import Foundation
import Security

/// Production, opt-in AI access. The QA control socket is deliberately separate.
enum LimaAccessTransport: String, Codable, CaseIterable {
    case local
    case network

    var title: String { self == .local ? "This Mac" : "Network" }
}

struct LimaAccessClient: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var createdAt: Date
    var lastUsedAt: Date?
    var access: LimaAccessProfile
    /// Optional for backward-compatible decoding of already-paired local clients.
    var transport: LimaAccessTransport?

    var effectiveTransport: LimaAccessTransport { transport ?? .local }
}

enum LimaAccessProfile: String, Codable, CaseIterable, Identifiable {
    case readOnly

    var id: String { rawValue }
    var title: String { "Read Only" }
}

private enum LimaAccessCredentialStore {
    static var service: String {
        LimaTestEnvironment.isEnabled ? "dev.liam.lima.access.test" : "dev.liam.lima.access"
    }

    static func save(_ token: String, for id: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
        SecItemDelete(query as CFDictionary)
        let attributes = query.merging([
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]) { _, value in value }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Lima could not store this AI connection in Keychain."])
        }
    }

    static func value(for id: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func remove(for id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
final class LimaAccessService: ObservableObject {
    static let shared = LimaAccessService()
    static let localPreferenceKey = "lima.access.localEnabled"
    static let networkPreferenceKey = "lima.access.networkEnabled"
    static let networkAddressKey = "lima.access.networkAddress"
    static let port: UInt16 = 43821

    @Published private(set) var localEnabled: Bool
    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var networkEnabled: Bool
    @Published private(set) var isNetworkRunning = false
    @Published private(set) var networkStatusMessage: String?
    @Published private(set) var networkAddress: String?
    @Published private(set) var clients: [LimaAccessClient]

    private let clientFileURL: URL
    private var networkListener: LimaAccessNetworkListener?
    private var networkMaterial: LimaAccessTLSIdentity.Material?
    private var networkGeneration: UInt64 = 0
    private var listener: Int32 = -1
    /// Invalidate requests accepted by an earlier listener, including across off/on cycles.
    private var listenerGeneration: UInt64 = 0
    private let connectionLimit = DispatchSemaphore(value: 4)

    private init() {
        localEnabled = LimaTestEnvironment.userDefaults.bool(forKey: Self.localPreferenceKey)
        networkEnabled = LimaTestEnvironment.userDefaults.bool(forKey: Self.networkPreferenceKey)
        networkAddress = LimaTestEnvironment.userDefaults.string(forKey: Self.networkAddressKey)
        clientFileURL = LimaTestEnvironment.storageURL(relativePath: "AI/access-clients.json")
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Lima/AI/access-clients.json")
        clients = (try? Data(contentsOf: clientFileURL))
            .flatMap { try? JSONDecoder().decode([LimaAccessClient].self, from: $0) } ?? []
    }

    var endpoint: String { "http://127.0.0.1:\(Self.port)/mcp" }
    var networkEndpoint: String? {
        networkAddress.map { "https://\($0):\(LimaAccessNetworkListener.port)/mcp" }
    }
    var networkCertificatePEM: String? { networkMaterial?.certificatePEM }
    var networkCertificateFingerprint: String? { networkMaterial?.fingerprint }
    var availableNetworkAddresses: [String] { LimaAccessTLSIdentity.availableAddresses() }

    func startIfEnabledAtLaunch() {
        if localEnabled && !start() {
            localEnabled = false
            LimaTestEnvironment.userDefaults.set(false, forKey: Self.localPreferenceKey)
        }
        if networkEnabled {
            do {
                guard let networkAddress else { throw networkError("Choose a private network address before enabling access.") }
                try startNetwork(on: networkAddress)
            } catch {
                networkEnabled = false
                networkStatusMessage = error.localizedDescription
                LimaTestEnvironment.userDefaults.set(false, forKey: Self.networkPreferenceKey)
            }
        }
    }

    func setLocalEnabled(_ enabled: Bool) {
        if enabled {
            guard start() else {
                localEnabled = false
                LimaTestEnvironment.userDefaults.set(false, forKey: Self.localPreferenceKey)
                return
            }
            localEnabled = true
            LimaTestEnvironment.userDefaults.set(true, forKey: Self.localPreferenceKey)
        } else {
            localEnabled = false
            LimaTestEnvironment.userDefaults.set(false, forKey: Self.localPreferenceKey)
            stop()
        }
    }

    /// Network exposure requires an explicit private interface and a Keychain TLS identity.
    /// The default remains off; failed starts clear the persisted opt-in.
    func setNetworkEnabled(_ enabled: Bool, on address: String? = nil) throws {
        guard enabled else {
            stopNetwork(persist: true)
            return
        }
        guard let address, LimaAccessTLSIdentity.availableAddresses().contains(address) else {
            throw networkError("Choose a current private LAN or Tailscale address.")
        }
        if networkEnabled && networkAddress == address && networkListener != nil { return }
        stopNetwork(persist: false)
        do {
            try startNetwork(on: address)
        } catch {
            // An address change must not leave a persisted opt-in pointing at a
            // stopped listener; a later launch must fail closed too.
            stopNetwork(persist: true)
            throw error
        }
        networkEnabled = true
        networkAddress = address
        LimaTestEnvironment.userDefaults.set(true, forKey: Self.networkPreferenceKey)
        LimaTestEnvironment.userDefaults.set(address, forKey: Self.networkAddressKey)
    }

    private func startNetwork(on address: String) throws {
        let material = try LimaAccessTLSIdentity.loadOrCreate(for: address)
        networkGeneration &+= 1
        let generation = networkGeneration
        let listener = try LimaAccessNetworkListener(
            address: address,
            identity: material.identity,
            handler: { [weak self] bytes in
                await self?.serve(bytes, transport: .network, generation: generation)
                    ?? LimaAccessHTTP.response(status: 503, body: ["error": "Lima Access is off."])
            },
            stateChanged: { [weak self] ready, error in
                Task { @MainActor [weak self] in
                    guard let self, self.networkGeneration == generation else { return }
                    if ready {
                        self.isNetworkRunning = true
                        self.networkStatusMessage = "TLS listening on \(address)."
                    } else if let error {
                        self.networkGeneration &+= 1
                        self.isNetworkRunning = false
                        self.networkStatusMessage = error
                        self.networkEnabled = false
                        self.networkListener?.stop()
                        self.networkListener = nil
                        self.networkMaterial = nil
                        LimaTestEnvironment.userDefaults.set(false, forKey: Self.networkPreferenceKey)
                    }
                }
            }
        )
        networkAddress = address
        networkMaterial = material
        networkListener = listener
        isNetworkRunning = false
        networkStatusMessage = "Starting TLS listener…"
        listener.start()
    }

    private func stopNetwork(persist: Bool) {
        networkGeneration &+= 1
        isNetworkRunning = false
        networkListener?.stop()
        networkListener = nil
        networkMaterial = nil
        networkStatusMessage = "Network AI Connections are off."
        if persist {
            networkEnabled = false
            LimaTestEnvironment.userDefaults.set(false, forKey: Self.networkPreferenceKey)
        }
    }

    func stopAll() {
        stop()
        stopNetwork(persist: false)
    }

    private func networkError(_ message: String) -> NSError {
        NSError(domain: "LimaAccess", code: 5,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    @discardableResult
    private func start() -> Bool {
        guard !isRunning else { return true }
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            statusMessage = "Local AI Connections could not open a socket."
            return false
        }
        var reuse: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = Self.port.bigEndian
        address.sin_addr = in_addr(s_addr: Darwin.inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            statusMessage = "Port \(Self.port) is unavailable. Local AI Connections remain off."
            return false
        }
        listener = fd
        listenerGeneration &+= 1
        let generation = listenerGeneration
        isRunning = true
        statusMessage = "Listening only on this Mac."
        let semaphore = connectionLimit
        DispatchQueue.global(qos: .utility).async { [weak self] in
            Self.acceptLoop(listener: fd, generation: generation, semaphore: semaphore, service: self)
        }
        return true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        listenerGeneration &+= 1
        let fd = listener
        listener = -1
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        statusMessage = "Local AI Connections are off."
    }

    /// The token is returned exactly once. Only client metadata is stored on disk;
    /// the bearer secret remains in this Mac's Keychain.
    func pairClient(named proposedName: String,
                    transport: LimaAccessTransport = .local) throws -> String {
        let active = transport == .local ? (localEnabled && isRunning) : (networkEnabled && isNetworkRunning)
        guard active else {
            throw NSError(domain: "LimaAccess", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Turn on this AI connection transport before pairing."])
        }
        guard clients.count < 32 else {
            throw NSError(domain: "LimaAccess", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Revoke an old AI connection before pairing another."])
        }
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else {
            throw NSError(domain: "LimaAccess", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Use a connection name of 1 to 80 characters."])
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NSError(domain: "LimaAccess", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Lima could not create a secure pairing token."])
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let client = LimaAccessClient(id: UUID(), name: trimmed, createdAt: Date(),
                                      lastUsedAt: nil, access: .readOnly, transport: transport)
        try LimaAccessCredentialStore.save(token, for: client.id)
        do {
            try persist(clients + [client])
            clients.append(client)
        } catch {
            LimaAccessCredentialStore.remove(for: client.id)
            throw error
        }
        return token
    }

    func revoke(_ id: UUID) throws {
        guard clients.contains(where: { $0.id == id }) else { return }
        let remaining = clients.filter { $0.id != id }
        try persist(remaining)
        clients = remaining
        LimaAccessCredentialStore.remove(for: id)
    }

    private func persist(_ value: [LimaAccessClient]) throws {
        try FileManager.default.createDirectory(at: clientFileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: clientFileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: clientFileURL.path)
    }

    private func authenticate(_ authorization: String?,
                              transport: LimaAccessTransport) -> LimaAccessClient? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let supplied = Array(authorization.dropFirst(7).utf8)
        guard supplied.count == 64 else { return nil }
        for client in clients where client.effectiveTransport == transport {
            guard let stored = LimaAccessCredentialStore.value(for: client.id) else { continue }
            let expected = Array(stored.utf8)
            guard expected.count == supplied.count else { continue }
            var difference: UInt8 = 0
            for index in supplied.indices { difference |= supplied[index] ^ expected[index] }
            if difference == 0 { return client }
        }
        return nil
    }

    private func serve(_ bytes: Data?, transport: LimaAccessTransport,
                       generation: UInt64) async -> Data {
        func isActive() -> Bool {
            switch transport {
            case .local: return isRunning && localEnabled && generation == listenerGeneration
            case .network: return isNetworkRunning && networkEnabled && generation == networkGeneration
            }
        }
        guard isActive() else {
            return LimaAccessHTTP.response(status: 503, body: ["error": "Lima Access is off."])
        }
        guard let bytes, let request = LimaAccessHTTP.parse(bytes) else {
            return LimaAccessHTTP.response(status: 400, body: ["error": "Invalid or oversized HTTP request."])
        }
        let trustedHost: Bool
        switch transport {
        case .local:
            trustedHost = LimaAccessHTTP.isTrustedLoopback(request, port: Self.port)
        case .network:
            trustedHost = networkAddress.map {
                LimaAccessHTTP.isTrustedNetwork(request, address: $0,
                                                port: LimaAccessNetworkListener.port)
            } ?? false
        }
        guard trustedHost else {
            return LimaAccessHTTP.response(status: 400, body: ["error": "Invalid MCP request origin or host."])
        }
        guard let client = authenticate(request.authorization, transport: transport) else {
            return LimaAccessHTTP.response(status: 401, body: ["error": "Pair this AI in Lima Settings."],
                                           extraHeaders: ["WWW-Authenticate": "Bearer"])
        }
        guard request.method == "POST", request.contentType == "application/json" else {
            return LimaAccessHTTP.response(status: 405, body: ["error": "Use JSON-RPC POST for this MCP endpoint."])
        }
        let result = await LimaAccessMCP.handle(request.body, access: client.access,
                                                notes: .shared, transport: transport)
        // Recheck after async work so a revocation or shutdown prevents that
        // result from being queued for delivery.
        guard isActive(),
              authenticate(request.authorization, transport: transport)?.id == client.id else {
            return LimaAccessHTTP.response(status: 401, body: ["error": "This AI connection is no longer active."])
        }
        if let index = clients.firstIndex(where: { $0.id == client.id }),
           clients[index].lastUsedAt.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
            var updated = clients
            updated[index].lastUsedAt = Date()
            if (try? persist(updated)) != nil { clients = updated }
        }
        return LimaAccessHTTP.response(status: result == nil ? 202 : 200, bodyData: result)
    }

    private nonisolated static func acceptLoop(listener: Int32, generation: UInt64,
                                               semaphore: DispatchSemaphore,
                                               service: LimaAccessService?) {
        while true {
            let client = Darwin.accept(listener, nil, nil)
            if client < 0 { return }
            semaphore.wait()
            DispatchQueue.global(qos: .utility).async {
                var noSignal: Int32 = 1
                _ = Darwin.setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                                      socklen_t(MemoryLayout<Int32>.size))
                var timeout = timeval(tv_sec: 5, tv_usec: 0)
                _ = Darwin.setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                                      socklen_t(MemoryLayout<timeval>.size))
                _ = Darwin.setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                                      socklen_t(MemoryLayout<timeval>.size))
                let bytes = LimaAccessHTTP.readRequest(from: client)
                Task { @MainActor in
                    let response = await service?.serve(bytes, transport: .local, generation: generation)
                        ?? LimaAccessHTTP.response(status: 503, body: ["error": "Lima Access is off."])
                    DispatchQueue.global(qos: .utility).async {
                        LimaAccessHTTP.write(response, to: client)
                        Darwin.close(client)
                        semaphore.signal()
                    }
                }
            }
        }
    }
}

/// Small, single-request HTTP/1.1 framing for a stateless loopback MCP endpoint.
enum LimaAccessHTTP {
    struct Request {
        let method: String
        let path: String
        let authorization: String?
        let host: String?
        let origin: String?
        let contentType: String?
        let body: Data
    }

    static let maximumRequestBytes = 128_000
    static let maximumRequestSeconds: TimeInterval = 5

    static func isTrustedLoopback(_ request: Request, port: UInt16) -> Bool {
        request.path == "/mcp" && request.host == "127.0.0.1:\(port)" && request.origin == nil
    }

    static func isTrustedNetwork(_ request: Request, address: String, port: UInt16) -> Bool {
        LimaAccessTLSIdentity.isPrivateIPv4(address)
            && request.path == "/mcp"
            && request.host == "\(address):\(port)"
            && request.origin == nil
    }

    private static let delimiter = Data([13, 10, 13, 10])

    static func readRequest(from socket: Int32) -> Data? {
        readRequest(from: socket, deadline: ProcessInfo.processInfo.systemUptime + maximumRequestSeconds)
    }

    static func readRequest(from socket: Int32, deadline: TimeInterval) -> Data? {
        var data = Data()
        var expected: Int?
        while data.count <= maximumRequestBytes {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return nil }
            var descriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(max(1, min(Double(Int32.max), (remaining * 1_000).rounded(.up))))
            guard Darwin.poll(&descriptor, 1, milliseconds) > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.recv(socket, &buffer, buffer.count, 0)
            guard count > 0 else { return nil }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumRequestBytes else { return nil }
            if expected == nil, data.range(of: delimiter) == nil, data.count > 8192 { return nil }
            if expected == nil, let boundary = data.range(of: delimiter) {
                guard boundary.lowerBound <= 8192,
                      let head = String(data: data[..<boundary.lowerBound], encoding: .utf8),
                      let length = contentLength(in: head),
                      length <= maximumRequestBytes - boundary.upperBound else { return nil }
                expected = boundary.upperBound + length
            }
            if let expected, data.count >= expected {
                // Never trim a coalesced second request or trailing bytes into a valid one.
                return data.count == expected ? data : nil
            }
        }
        return nil
    }

    /// Return the exact frame size once complete headers have arrived.
    /// A nil result means incomplete or invalid framing; callers enforce a deadline.
    static func expectedRequestLength(_ bytes: Data) -> Int? {
        guard bytes.count <= maximumRequestBytes,
              let boundary = bytes.range(of: delimiter),
              boundary.lowerBound <= 8192,
              let head = String(data: bytes[..<boundary.lowerBound], encoding: .utf8),
              let length = contentLength(in: head),
              length <= maximumRequestBytes - boundary.upperBound else { return nil }
        return boundary.upperBound + length
    }

    private static func contentLength(in head: String) -> Int? {
        var result: Int?
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            let pieces = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { return nil }
            let key = pieces[0].lowercased()
            if key == "transfer-encoding" { return nil }
            if key == "content-length" {
                guard result == nil,
                      !pieces[1].trimmingCharacters(in: .whitespaces).isEmpty,
                      pieces[1].trimmingCharacters(in: .whitespaces).utf8.allSatisfy({ (48...57).contains($0) }),
                      let number = Int(pieces[1].trimmingCharacters(in: .whitespaces)),
                      (0...maximumRequestBytes).contains(number) else { return nil }
                result = number
            }
        }
        return result
    }

    static func parse(_ bytes: Data) -> Request? {
        guard bytes.count <= maximumRequestBytes,
              let boundary = bytes.range(of: delimiter),
              boundary.lowerBound <= 8192,
              let head = String(data: bytes[..<boundary.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ").map(String.init)
        guard first.count == 3, first[2] == "HTTP/1.1", first[1] == "/mcp",
              let length = contentLength(in: head),
              bytes.count == boundary.upperBound + length else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pieces = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { return nil }
            let key = pieces[0].lowercased()
            guard headers[key] == nil else { return nil }
            headers[key] = pieces[1].trimmingCharacters(in: .whitespaces)
        }
        let contentType = headers["content-type"]?.split(separator: ";", maxSplits: 1).first
            .map(String.init)?.lowercased()
        return Request(method: first[0], path: first[1], authorization: headers["authorization"],
                       host: headers["host"], origin: headers["origin"],
                       contentType: contentType, body: Data(bytes[boundary.upperBound...]))
    }

    static func response(status: Int, body: [String: Any],
                         extraHeaders: [String: String] = [:]) -> Data {
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        return response(status: status, bodyData: data, extraHeaders: extraHeaders)
    }

    static func response(status: Int, bodyData: Data?,
                         extraHeaders: [String: String] = [:]) -> Data {
        let phrase: String
        switch status {
        case 200: phrase = "OK"
        case 202: phrase = "Accepted"
        case 400: phrase = "Bad Request"
        case 401: phrase = "Unauthorized"
        case 404: phrase = "Not Found"
        case 405: phrase = "Method Not Allowed"
        default: phrase = "Service Unavailable"
        }
        let payload = bodyData ?? Data()
        var head = "HTTP/1.1 \(status) \(phrase)\r\nContent-Type: application/json\r\n"
        head += "Content-Length: \(payload.count)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        for (key, value) in extraHeaders { head += "\(key): \(value)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + payload
    }

    static func write(_ data: Data, to socket: Int32) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let sent = Darwin.send(socket, base.advanced(by: offset), raw.count - offset, 0)
                guard sent > 0 else { return }
                offset += sent
            }
        }
    }
}
