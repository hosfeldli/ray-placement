import AppKit
import Darwin
import Network
import RayPlacementCore

enum BrowserBridgeError: LocalizedError {
    case unavailable, timeout, invalidResponse, rejected(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Enable the bridge in Settings and connect the companion extension in Zen or Firefox."
        case .timeout: return "The browser did not respond. Reconnect the companion extension and try again."
        case .invalidResponse: return "The browser returned an invalid response."
        case .rejected(let code): return "Browser request stopped: \(code). Check site access in the companion extension."
        }
    }
}

@MainActor
final class BrowserBridgeService: ObservableObject {
    static let shared = BrowserBridgeService()
    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "lima.browserBridge.enabled")
            if enabled { start() } else { stop() }
        }
    }
    @Published var openInBackground: Bool {
        didSet { defaults.set(openInBackground, forKey: "lima.browserBridge.backgroundTabs") }
    }
    @Published private(set) var status = "Disabled"
    @Published private(set) var sessions: [UUID] = []
    @Published var selectedSession: UUID?
    private let defaults: UserDefaults
    private let registry: TaskRegistry
    private let socketURL: URL
    private let allowsTestConnection: Bool
    private var listener: NWListener?
    private var channels: [UUID: BrowserBridgeChannel] = [:]
    private var handshakes: [UUID: Task<Void, Never>] = [:]
    private struct Pending {
        let session: UUID
        let command: String
        let continuation: CheckedContinuation<JSONValue, Error>
        let timeout: Task<Void, Never>
    }
    private var pending: [String: Pending] = [:]

    init(defaults: UserDefaults = .standard, socketURL: URL? = nil, registry: TaskRegistry? = nil) {
        self.defaults = defaults
        self.registry = registry ?? .shared
        self.socketURL = socketURL ?? BrowserBridgeIdentity.socketURL
        self.allowsTestConnection = socketURL != nil
        enabled = defaults.bool(forKey: "lima.browserBridge.enabled")
        openInBackground = defaults.object(forKey: "lima.browserBridge.backgroundTabs") as? Bool ?? true
    }

    func start() {
        guard enabled, listener == nil, (!LimaTestEnvironment.isEnabled || allowsTestConnection) else { return }
        do {
            let url = socketURL
            try BrowserBridgeInstallation.ensureDirectory(url.deletingLastPathComponent())
            try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                  ofItemAtPath: url.deletingLastPathComponent().path)
            // Never unlink a live listener owned by a different Lima instance.
            var info = stat()
            if lstat(url.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid() else {
                    throw BrowserBridgeError.unavailable
                }
                // A lock is held for this service's lifetime, including socket cleanup.
            }
            guard acquireLock() else { throw BrowserBridgeError.unavailable }
            if lstat(url.path, &info) == 0 { try FileManager.default.removeItem(at: url) }
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .unix(path: url.path)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                Task { @MainActor in
                    guard let self, let listener, self.listener === listener else { connection.cancel(); return }
                    self.accept(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        do {
                            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                            self.status = self.sessions.isEmpty ? "Waiting for companion extension" : "Connected"
                        } catch {
                            self.stop()
                            self.status = "Could not secure browser connection"
                        }
                    case .failed:
                        self.stop()
                        self.status = "Bridge could not start"
                    default: break
                    }
                }
            }
            listener.start(queue: DispatchQueue(label: "com.lima.browser-bridge.listener"))
        } catch {
            releaseLock()
            status = "Bridge unavailable; another Lima instance may be running"
        }
    }

    private var lockFD: Int32 = -1
    private func acquireLock() -> Bool {
        let path = socketURL.deletingLastPathComponent().appendingPathComponent("bridge.lock").path
        lockFD = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { return false }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { releaseLock(); return false }
        return true
    }
    private func releaseLock() {
        if lockFD >= 0 { Darwin.close(lockFD); lockFD = -1 }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        let old = channels
        channels.removeAll()
        old.values.forEach { $0.cancel() }
        handshakes.values.forEach { $0.cancel() }
        handshakes.removeAll()
        sessions = []
        selectedSession = nil
        for id in Array(pending.keys) { complete(id, result: .failure(BrowserBridgeError.unavailable)) }
        if lockFD >= 0 {
            try? FileManager.default.removeItem(at: socketURL)
            releaseLock()
        }
        status = "Disabled"
    }

    private func accept(_ connection: NWConnection) {
        guard enabled, listener != nil, channels.count < 4 else { connection.cancel(); return }
        let id = UUID()
        let channel = BrowserBridgeChannel(connection: connection, receive: { [weak self] message in
            await self?.receive(message, session: id)
        }, disconnected: { [weak self] in
            Task { @MainActor in self?.disconnect(id) }
        })
        channels[id] = channel
        handshakes[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.disconnect(id)
        }
        channel.start()
    }

    private func receive(_ message: BrowserBridgeMessage, session: UUID) {
        guard channels[session] != nil else { return }
        if message.kind == "hello", message.command == "connect",
           message.arguments["extensionID"] == .string(BrowserBridgeIdentity.extensionID) {
            guard !sessions.contains(session) else { return }
            handshakes.removeValue(forKey: session)?.cancel()
            sessions.append(session)
            if sessions.count == 1 { selectedSession = session }
            status = "Connected"
            return
        }
        guard sessions.contains(session), message.kind == "response",
              let request = pending[message.id], request.session == session,
              request.command == message.command else { return }
        if let error = message.error {
            // Error codes, never raw browser/page exception text.
            let safeCode = error.range(of: "^[a-z_]{1,64}$", options: .regularExpression) != nil ? error : "request_failed"
            complete(message.id, result: .failure(BrowserBridgeError.rejected(safeCode)))
        } else if let result = message.result {
            complete(message.id, result: .success(result))
        } else {
            complete(message.id, result: .failure(BrowserBridgeError.invalidResponse))
        }
    }

    private func disconnect(_ id: UUID) {
        channels.removeValue(forKey: id)?.cancel()
        handshakes.removeValue(forKey: id)?.cancel()
        sessions.removeAll { $0 == id }
        if selectedSession == id { selectedSession = sessions.count == 1 ? sessions.first : nil }
        for key in pending.keys.filter({ pending[$0]?.session == id }) {
            complete(key, result: .failure(BrowserBridgeError.unavailable))
        }
        if enabled, listener != nil { status = sessions.isEmpty ? "Waiting for companion extension" : "Connected" }
    }

    private func complete(_ id: String, result: Result<JSONValue, Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        request.continuation.resume(with: result)
    }

    func request(_ command: String, arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
        guard enabled, let session = selectedSession, sessions.contains(session),
              let channel = channels[session], pending.count < 16 else { throw BrowserBridgeError.unavailable }
        let message = BrowserBridgeMessage(command: command, arguments: arguments)
        let taskID = registry.begin(kind: .aiTool, title: "Browser interaction",
            isCancellable: true, onCancel: { [weak self] in self?.cancel(message, session: session) })
        do {
            let value = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    let timeout = Task { [weak self] in
                        let seconds: UInt64 = ["browser.open", "browser.open_tabs", "browser.focus", "browser.close", "browser.navigate"].contains(command) ? 75 : 15
                        try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                        guard !Task.isCancelled else { return }
                        self?.cancel(message, session: session, error: BrowserBridgeError.timeout)
                    }
                    pending[message.id] = Pending(session: session, command: command,
                                                  continuation: continuation, timeout: timeout)
                    channel.send(message)
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancel(message, session: session) }
            }
            try Task.checkCancellation()
            registry.finish(taskID)
            return value
        } catch {
            registry.finish(taskID, state: error is CancellationError ? .cancelled : .failed)
            throw error
        }
    }

    private func cancel(_ message: BrowserBridgeMessage, session: UUID, error: Error = CancellationError()) {
        guard pending[message.id] != nil else { return }
        channels[session]?.send(BrowserBridgeMessage(id: message.id, kind: "cancel", command: message.command))
        complete(message.id, result: .failure(error))
    }

    /// Open a bounded batch through one companion request so site policy is
    /// preflighted before the extension creates any tabs.
    func openTabs(urls: [String], background: Bool) async throws -> JSONValue {
        guard (1...50).contains(urls.count) else { throw BrowserBridgeError.invalidResponse }
        return try await request(
            "browser.open_tabs",
            arguments: [
                "urls": .array(urls.map(JSONValue.string)),
                "background": .bool(background)
            ]
        )
    }

    func resolveCase(number: String, tabID: Int) async throws -> JSONValue {
        let page = try await salesforcePage(tabID: tabID)
        return try resolveCase(number, in: page)
    }

    /// Extract only unambiguous, same-origin Case links from one granted
    /// Salesforce snapshot. Link labels are untrusted page data, never commands.
    func readCaseLinks(tabID: Int) async throws -> JSONValue {
        let page = try await salesforcePage(tabID: tabID)
        guard let pageURL = URL(string: page.url) else { throw BrowserBridgeError.invalidResponse }
        let links = page.links.map {
            SalesforcePageLink(href: $0.href, text: $0.text, accessibleName: $0.accessibleName, title: $0.title)
        }
        let cases = SalesforceCaseResolver.visibleCaseLinks(pageURL: pageURL, links: links)
        return .object([
            "cases": .array(cases.map {
                .object(["case_number": .string($0.caseNumber), "url": .string($0.url.absoluteString)])
            }),
            "limit": .number(50)
        ])
    }

    /// Resolve a bounded batch from one granted snapshot, avoiding repeated page
    /// reads and JSON conversion for the common Salesforce queue workflow.
    func resolveCases(numbers: [String], tabID: Int) async throws -> JSONValue {
        guard (1...30).contains(numbers.count) else { throw BrowserBridgeError.invalidResponse }
        let page = try await salesforcePage(tabID: tabID)
        return .array(try numbers.map { try resolveCase($0, in: page) })
    }

    private func salesforcePage(tabID: Int) async throws -> (url: String, links: [LimaBrowserBridgeLink]) {
        let snapshot = try await request("browser.read", arguments: ["tabID": .number(Double(tabID))])
        let data = try JSONEncoder().encode(snapshot)
        struct Snapshot: Decodable { var url: String; var links: [LimaBrowserBridgeLink] }
        let page = try JSONDecoder().decode(Snapshot.self, from: data)
        return (page.url, page.links)
    }

    private func resolveCase(
        _ number: String,
        in page: (url: String, links: [LimaBrowserBridgeLink])
    ) throws -> JSONValue {
        let response = LimaBrowserBridgeDispatcher.handle(.init(
            requestID: UUID().uuidString,
            command: "salesforce.resolve_case",
            caseNumber: number,
            pageURL: page.url,
            links: page.links
        ))
        return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(response))
    }
}
