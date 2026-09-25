import AppKit
import Darwin
import Foundation

enum BrowserBridgeError: LocalizedError {
    case unavailable
    case disconnected
    case invalidResponse
    case transport(String)
    case missingHost
    case missingExtension
    case zenNotInstalled
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "The browser bridge is not available."
        case .disconnected: return "The Lima browser extension is not connected."
        case .invalidResponse: return "The browser extension returned an invalid response."
        case .transport(let detail): return "Browser bridge transport failed: \(detail)"
        case .missingHost: return "The bundled browser bridge host is missing."
        case .missingExtension: return "The bundled Zen/Firefox extension is missing."
        case .zenNotInstalled: return "Zen Browser is not installed."
        case .installFailed(let detail): return "The browser extension could not be opened in Zen: \(detail)"
        }
    }
}

private enum BrowserBridgeFraming {
    static let maximumMessageBytes = 4 * 1_024 * 1_024

    static func readFrame(from descriptor: Int32) -> Data? {
        guard let header = readExactly(4, from: descriptor) else { return nil }
        let length = header.withUnsafeBytes { raw -> UInt32 in
            raw.load(as: UInt32.self).littleEndian
        }
        guard length > 0, length <= maximumMessageBytes else { return nil }
        return readExactly(Int(length), from: descriptor)
    }

    static func writeFrame(_ data: Data, to descriptor: Int32) -> Bool {
        guard !data.isEmpty, data.count <= maximumMessageBytes else { return false }
        var length = UInt32(data.count).littleEndian
        let header = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        return writeExactly(header, to: descriptor) && writeExactly(data, to: descriptor)
    }

    private static func readExactly(_ count: Int, from descriptor: Int32) -> Data? {
        var output = Data(count: count)
        var offset = 0
        let success = output.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress else { return false }
            while offset < count {
                let amount = Darwin.read(descriptor, base.advanced(by: offset), count - offset)
                if amount == 0 { return false }
                if amount < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += amount
            }
            return true
        }
        return success ? output : nil
    }

    private static func writeExactly(_ data: Data, to descriptor: Int32) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress else { return false }
            while offset < data.count {
                let amount = Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
                if amount < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if amount == 0 { return false }
                offset += amount
            }
            return true
        }
    }
}

private final class BrowserBridgeSocketServer {
    private let token: String
    private let acceptQueue = DispatchQueue(label: "dev.liam.lima.browserbridge.accept", qos: .utility)
    private let writeQueue = DispatchQueue(label: "dev.liam.lima.browserbridge.write", qos: .userInitiated)
    private let lock = NSLock()

    private var listeningDescriptor: Int32 = -1
    private var clientDescriptor: Int32 = -1
    private var isRunning = false

    var onConnectionChanged: ((Bool) -> Void)?
    var onMessage: (([String: Any]) -> Void)?

    init(token: String) {
        self.token = token
    }

    func start() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw BrowserBridgeError.transport(Self.errorString()) }

        var reuse: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let detail = Self.errorString()
            Darwin.close(descriptor)
            throw BrowserBridgeError.transport(detail)
        }
        guard Darwin.listen(descriptor, 2) == 0 else {
            let detail = Self.errorString()
            Darwin.close(descriptor)
            throw BrowserBridgeError.transport(detail)
        }

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &boundLength)
            }
        }
        guard nameResult == 0 else {
            let detail = Self.errorString()
            Darwin.close(descriptor)
            throw BrowserBridgeError.transport(detail)
        }

        lock.lock()
        listeningDescriptor = descriptor
        isRunning = true
        lock.unlock()

        acceptQueue.async { [weak self] in self?.acceptLoop() }
        return UInt16(bigEndian: boundAddress.sin_port)
    }

    func stop() {
        lock.lock()
        isRunning = false
        let listener = listeningDescriptor
        let client = clientDescriptor
        listeningDescriptor = -1
        clientDescriptor = -1
        lock.unlock()

        if client >= 0 {
            Darwin.shutdown(client, SHUT_RDWR)
            Darwin.close(client)
        }
        if listener >= 0 {
            Darwin.shutdown(listener, SHUT_RDWR)
            Darwin.close(listener)
        }
        onConnectionChanged?(false)
    }

    func send(_ object: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw BrowserBridgeError.transport("request is not valid JSON")
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        lock.lock()
        let descriptor = clientDescriptor
        lock.unlock()
        guard descriptor >= 0 else { throw BrowserBridgeError.disconnected }

        writeQueue.async { [weak self] in
            guard BrowserBridgeFraming.writeFrame(data, to: descriptor) else {
                self?.disconnect(descriptor)
                return
            }
        }
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let running = isRunning
            let listener = listeningDescriptor
            lock.unlock()
            guard running, listener >= 0 else { return }

            let descriptor = Darwin.accept(listener, nil, nil)
            if descriptor < 0 {
                if errno == EINTR { continue }
                lock.lock()
                let shouldContinue = isRunning
                lock.unlock()
                if shouldContinue { continue }
                return
            }
            handleClient(descriptor)
        }
    }

    private func handleClient(_ descriptor: Int32) {
        guard let helloData = BrowserBridgeFraming.readFrame(from: descriptor),
              let hello = try? JSONSerialization.jsonObject(with: helloData) as? [String: Any],
              hello["type"] as? String == "hello",
              hello["token"] as? String == token else {
            Darwin.close(descriptor)
            return
        }

        lock.lock()
        let previous = clientDescriptor
        clientDescriptor = descriptor
        lock.unlock()
        if previous >= 0, previous != descriptor {
            Darwin.shutdown(previous, SHUT_RDWR)
            Darwin.close(previous)
        }
        onConnectionChanged?(true)

        while let data = BrowserBridgeFraming.readFrame(from: descriptor) {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            onMessage?(object)
        }
        disconnect(descriptor)
    }

    private func disconnect(_ descriptor: Int32) {
        lock.lock()
        let wasCurrent = clientDescriptor == descriptor
        if wasCurrent { clientDescriptor = -1 }
        lock.unlock()

        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
        if wasCurrent { onConnectionChanged?(false) }
    }

    private static func errorString() -> String {
        String(cString: strerror(errno))
    }
}

@MainActor
final class BrowserBridgeService: ObservableObject {
    static let shared = BrowserBridgeService()

    @Published private(set) var isConnected = false
    @Published private(set) var statusText = "Browser bridge is not running."
    @Published private(set) var activePageTitle: String?
    @Published private(set) var activePageURL: String?

    private var socketServer: BrowserBridgeSocketServer?
    private var pending: [String: (Result<[String: Any], Error>) -> Void] = [:]
    private(set) var token = ""

    private init() {}

    func start() {
        guard socketServer == nil else { return }
        token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let server = BrowserBridgeSocketServer(token: token)
        server.onConnectionChanged = { [weak self] connected in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isConnected = connected
                self.statusText = connected
                    ? "Zen/Firefox extension connected."
                    : "Waiting for the Zen/Firefox extension."
                if !connected {
                    self.activePageTitle = nil
                    self.activePageURL = nil
                }
            }
        }
        server.onMessage = { [weak self] message in
            DispatchQueue.main.async { self?.receive(message) }
        }

        do {
            let port = try server.start()
            socketServer = server
            try BrowserBridgeInstaller.installNativeMessagingHost()
            try writeRuntimeConfiguration(port: port)
            statusText = "Waiting for the Zen/Firefox extension."
        } catch {
            server.stop()
            socketServer = nil
            statusText = error.localizedDescription
        }
    }

    func stop() {
        socketServer?.stop()
        socketServer = nil
        pending.values.forEach { $0(.failure(BrowserBridgeError.disconnected)) }
        pending.removeAll()
        isConnected = false
        try? FileManager.default.removeItem(at: Self.runtimeConfigurationURL)
    }

    func refreshActivePage() {
        request(method: "browser.activePage") { [weak self] result in
            guard let self else { return }
            if case .success(let object) = result {
                self.activePageTitle = object["title"] as? String
                self.activePageURL = object["url"] as? String
            }
        }
    }

    func openSalesforceCases(
        _ caseNumbers: [String],
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        let normalized = caseNumbers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalized.isEmpty else {
            completion(.failure(BrowserBridgeError.invalidResponse))
            return
        }
        request(
            method: "salesforce.openCases",
            params: ["caseNumbers": Array(normalized.prefix(50))],
            completion: completion
        )
    }

    func request(
        method: String,
        params: [String: Any] = [:],
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        guard isConnected else {
            completion(.failure(BrowserBridgeError.disconnected))
            return
        }
        let identifier = UUID().uuidString
        pending[identifier] = completion
        do {
            try socketServer?.send([
                "type": "request",
                "id": identifier,
                "method": method,
                "params": params
            ])
        } catch {
            pending.removeValue(forKey: identifier)
            completion(.failure(error))
        }
    }

    private func receive(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "response":
            guard let identifier = message["id"] as? String,
                  let completion = pending.removeValue(forKey: identifier) else { return }
            if message["ok"] as? Bool == true {
                completion(.success(message["result"] as? [String: Any] ?? [:]))
            } else {
                let detail = message["error"] as? String ?? "Unknown browser bridge error."
                completion(.failure(BrowserBridgeError.transport(detail)))
            }
        case "event":
            if message["event"] as? String == "activePageChanged",
               let payload = message["payload"] as? [String: Any] {
                activePageTitle = payload["title"] as? String
                activePageURL = payload["url"] as? String
            }
        default:
            break
        }
    }

    private func writeRuntimeConfiguration(port: UInt16) throws {
        try ApplicationPaths.prepare()
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "host": "127.0.0.1",
            "port": Int(port),
            "token": token
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Self.runtimeConfigurationURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: Self.runtimeConfigurationURL.path
        )
    }

    static var runtimeConfigurationURL: URL {
        ApplicationPaths.applicationSupport.appendingPathComponent("browser-bridge-runtime.json")
    }
}

@MainActor
enum BrowserBridgeInstaller {
    static let extensionIdentifier = "lima-browser-bridge@liamhosfeld.com"
    static let nativeHostName = "dev.liam.lima.browserbridge"
    static let zenBundleIdentifier = "app.zen-browser.zen"

    static var zenApplicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: zenBundleIdentifier)
    }

    static var nativeManifestURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Mozilla/NativeMessagingHosts", isDirectory: true)
            .appendingPathComponent("\(nativeHostName).json")
    }

    static var bundledHostURL: URL? {
        let packaged = Bundle.main.resourceURL?
            .appendingPathComponent("BrowserBridge", isDirectory: true)
            .appendingPathComponent("LimaBrowserBridgeHost")
        if let packaged, FileManager.default.isExecutableFile(atPath: packaged.path) { return packaged }

        let development = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("LimaBrowserBridgeHost")
        if let development, FileManager.default.isExecutableFile(atPath: development.path) { return development }
        return nil
    }

    static var bundledExtensionURL: URL? {
        let url = Bundle.main.resourceURL?
            .appendingPathComponent("BrowserBridge", isDirectory: true)
            .appendingPathComponent("LimaBrowserBridge.xpi")
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static var extensionBuildKind: String {
        let marker = Bundle.main.resourceURL?
            .appendingPathComponent("BrowserBridge", isDirectory: true)
            .appendingPathComponent("extension-build.txt")
        guard let marker,
              let value = try? String(contentsOf: marker, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return "unknown" }
        return value
    }

    static var nativeManifestInstalled: Bool {
        FileManager.default.fileExists(atPath: nativeManifestURL.path)
    }

    static func installNativeMessagingHost() throws {
        guard let host = bundledHostURL else { throw BrowserBridgeError.missingHost }
        let directory = nativeManifestURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let manifest: [String: Any] = [
            "name": nativeHostName,
            "description": "Lima browser bridge for Zen and Firefox",
            "path": host.path,
            "type": "stdio",
            "allowed_extensions": [extensionIdentifier]
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: nativeManifestURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: nativeManifestURL.path)
    }

    static func openExtensionInstaller(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let zen = zenApplicationURL else {
            completion(.failure(BrowserBridgeError.zenNotInstalled))
            return
        }
        guard let extensionURL = bundledExtensionURL else {
            completion(.failure(BrowserBridgeError.missingExtension))
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [extensionURL],
            withApplicationAt: zen,
            configuration: configuration
        ) { _, error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(BrowserBridgeError.installFailed(error.localizedDescription)))
                } else {
                    completion(.success(()))
                }
            }
        }
    }

    static func openZenAddOns() {
        guard let zen = zenApplicationURL, let url = URL(string: "about:addons") else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: zen, configuration: configuration)
    }

    static func revealExtensionSource() {
        guard let source = Bundle.main.resourceURL?
            .appendingPathComponent("BrowserBridge/Source", isDirectory: true),
              FileManager.default.fileExists(atPath: source.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([source])
    }
}
