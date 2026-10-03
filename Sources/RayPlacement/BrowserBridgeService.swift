import AppKit
import Darwin
import Network
import RayPlacementCore

enum BrowserBridgeError: LocalizedError {
    case unavailable, interactionUnavailable, broadGrantDisabled, unsupportedGrant, timeout, invalidResponse, rejected(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Enable the bridge in Settings and connect the companion extension in Zen or Firefox."
        case .interactionUnavailable: return "The connected Browser Bridge companion needs a compatible signed update before it can click, type, or submit."
        case .broadGrantDisabled: return "The browser has an all-HTTPS grant. Enable Broad HTTPS browser grants in AI Settings → Experimental browser access, or revoke the broad grant in the companion."
        case .unsupportedGrant: return "The browser reported an unsupported host grant. Revoke it in the companion before using browser tools."
        case .timeout: return "The browser did not respond. Reconnect the companion extension and try again."
        case .invalidResponse: return "The browser returned an invalid response."
        case .rejected(let code):
            if code == "unsupported_command" {
                return "The installed signed Browser Bridge companion does not support this interaction yet. Install a compatible signed companion release, then reconnect."
            }
            return "Browser request stopped: \(code). Check site access and the companion approval in the browser."
        }
    }
}

/// Lima must distinguish an exact site grant from the browser's wildcard
/// permission. The signed companion reports both; this policy gates what Lima
/// can expose without changing or re-signing the companion.
struct BrowserBridgeGrantPolicy {
    let exactHosts: Set<String>
    let hasBroadHTTPS: Bool

    static func parse(_ origins: [JSONValue]) throws -> Self {
        var exactHosts = Set<String>()
        var hasBroadHTTPS = false
        for origin in origins {
            guard case .string(let pattern) = origin else { throw BrowserBridgeError.unsupportedGrant }
            if pattern == "https://*/*" {
                hasBroadHTTPS = true
                continue
            }
            guard pattern.hasSuffix("/*"),
                  let url = URL(string: String(pattern.dropLast(2))),
                  let host = host(for: url),
                  url.path.isEmpty, url.query == nil, url.fragment == nil else {
                throw BrowserBridgeError.unsupportedGrant
            }
            exactHosts.insert(host)
        }
        return Self(exactHosts: exactHosts, hasBroadHTTPS: hasBroadHTTPS)
    }

    func require(_ rawURL: String, broadEnabled: Bool, interaction: Bool = false) throws {
        guard let url = URL(string: rawURL), let host = Self.host(for: url) else {
            throw BrowserBridgeError.invalidResponse
        }
        if exactHosts.contains(host) { return }
        if !interaction && hasBroadHTTPS && broadEnabled { return }
        if hasBroadHTTPS && !broadEnabled && !interaction { throw BrowserBridgeError.broadGrantDisabled }
        throw BrowserBridgeError.rejected("site_not_granted")
    }

    func allows(_ rawURL: String, broadEnabled: Bool) -> Bool {
        (try? require(rawURL, broadEnabled: broadEnabled)) != nil
    }

    private static func host(for url: URL) -> String? {
        guard url.scheme == "https", let host = url.host, !host.isEmpty,
              !host.contains("*"), url.port == nil, url.user == nil,
              url.password == nil else { return nil }
        return host.lowercased()
    }
}

@MainActor
final class BrowserBridgeService: ObservableObject {
    static let shared = BrowserBridgeService()
    private static let mutationCommands: Set<String> = [
        "browser.open", "browser.open_tabs", "browser.focus", "browser.close", "browser.navigate",
        "browser.click", "browser.type", "browser.submit"
    ]
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

    init(defaults: UserDefaults = LimaTestEnvironment.userDefaults, socketURL: URL? = nil, registry: TaskRegistry? = nil) {
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
        guard command.hasPrefix("browser.") else {
            return try await rawRequest(command, arguments: arguments, recordActivity: command != "bridge.status")
        }
        guard let session = selectedSession else { throw BrowserBridgeError.unavailable }
        let policy = try await currentGrantPolicy(session: session)
        guard selectedSession == session else { throw BrowserBridgeError.unavailable }
        let broadEnabled = defaults.bool(forKey: AIComputerActionPolicy.broadBrowserGrantsKey)

        switch command {
        case "browser.tabs":
            let result = try await rawRequest(command, arguments: arguments, expectedSession: session)
            let latest = try await currentGrantPolicy(session: session)
            guard selectedSession == session, case .object(var fields) = result,
                  case .array(let tabs)? = fields["tabs"] else { throw BrowserBridgeError.invalidResponse }
            let eligible = tabs.filter { tab in
                guard case .object(let info) = tab, case .string(let url)? = info["url"] else { return false }
                if info["incognito"] == .bool(true) { return false }
                return latest.allows(url, broadEnabled: defaults.bool(forKey: AIComputerActionPolicy.broadBrowserGrantsKey))
            }
            fields["tabs"] = .array(eligible)
            return .object(fields)

        case "browser.current":
            let result = try await rawRequest(command, arguments: arguments, expectedSession: session)
            let latest = try await currentGrantPolicy(session: session)
            guard selectedSession == session, case .object(let info) = result,
                  case .string(let url)? = info["url"], info["incognito"] != .bool(true) else {
                throw BrowserBridgeError.invalidResponse
            }
            try latest.require(url, broadEnabled: defaults.bool(forKey: AIComputerActionPolicy.broadBrowserGrantsKey))
            return result

        case "browser.read":
            guard case .number(let tabID)? = arguments["tabID"] else { throw BrowserBridgeError.invalidResponse }
            let listed = try await rawRequest("browser.tabs", expectedSession: session, recordActivity: false)
            guard case .object(let fields) = listed, case .array(let tabs)? = fields["tabs"],
                  let tab = tabs.first(where: { item in
                      guard case .object(let info) = item else { return false }
                      return info["id"] == .number(tabID)
                  }),
                  case .object(let info) = tab, case .string(let expectedURL)? = info["url"],
                  info["incognito"] != .bool(true) else {
                throw BrowserBridgeError.rejected("site_not_granted")
            }
            try policy.require(expectedURL, broadEnabled: broadEnabled)
            let result = try await rawRequest(command, arguments: arguments, expectedSession: session)
            let latest = try await currentGrantPolicy(session: session)
            guard selectedSession == session, case .object(let page) = result,
                  case .string(let actualURL)? = page["url"],
                  actualURL == expectedURL, page["incognito"] != .bool(true) else { throw BrowserBridgeError.invalidResponse }
            try latest.require(actualURL, broadEnabled: defaults.bool(forKey: AIComputerActionPolicy.broadBrowserGrantsKey))
            return result

        case "browser.open", "browser.open_tabs", "browser.focus", "browser.close",
             "browser.navigate", "browser.click", "browser.type", "browser.submit":
            let urls: [JSONValue]
            switch command {
            case "browser.open": urls = [arguments["url"]].compactMap { $0 }
            case "browser.open_tabs":
                guard case .array(let values)? = arguments["urls"], !values.isEmpty else {
                    throw BrowserBridgeError.invalidResponse
                }
                urls = values
            case "browser.navigate": urls = [arguments["expectedURL"], arguments["url"]].compactMap { $0 }
            default: urls = [arguments["expectedURL"]].compactMap { $0 }
            }
            guard !urls.isEmpty else { throw BrowserBridgeError.invalidResponse }
            for value in urls {
                guard case .string(let url) = value else { throw BrowserBridgeError.invalidResponse }
                try policy.require(url, broadEnabled: broadEnabled,
                                   interaction: ["browser.click", "browser.type", "browser.submit", "browser.close"].contains(command))
            }
            // A completed browser mutation cannot be undone. Return its actual
            // result even if the experiment is switched off while it is running.
            return try await rawRequest(command, arguments: arguments, expectedSession: session)

        default:
            throw BrowserBridgeError.invalidResponse
        }
    }

    private func currentGrantPolicy(session: UUID) async throws -> BrowserBridgeGrantPolicy {
        let status = try await rawRequest("bridge.status", expectedSession: session, recordActivity: false)
        guard case .object(let fields) = status,
              case .array(let origins)? = fields["origins"] else { throw BrowserBridgeError.invalidResponse }
        return try BrowserBridgeGrantPolicy.parse(origins)
    }

    private func rawRequest(_ command: String, arguments: [String: JSONValue] = [:], expectedSession: UUID? = nil,
                            recordActivity: Bool = true) async throws -> JSONValue {
        guard expectedSession == nil || selectedSession == expectedSession else { throw BrowserBridgeError.unavailable }
        guard enabled, let session = selectedSession, sessions.contains(session),
              let channel = channels[session], pending.count < 16 else { throw BrowserBridgeError.unavailable }
        let message = BrowserBridgeMessage(command: command, arguments: arguments)
        let journal = Self.journalMetadata(command: command, arguments: arguments)
        let taskID: UUID? = recordActivity
            ? registry.begin(kind: .aiTool, title: journal.title, detail: journal.detail,
                isCancellable: true, onCancel: { [weak self] in self?.cancel(message, session: session) })
            : nil
        do {
            let value = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    let timeout = Task { [weak self] in
                        let seconds: UInt64 = Self.mutationCommands.contains(command) ? 75 : 15
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
            // Once a mutation response arrives, the browser may already have
            // changed. Keep its result instead of turning a late Stop into a
            // misleading cancellation report; pending requests still cancel.
            if !Self.mutationCommands.contains(command) { try Task.checkCancellation() }
            if let taskID { registry.finish(taskID) }
            return value
        } catch {
            if let taskID { registry.finish(taskID, state: error is CancellationError ? .cancelled : .failed) }
            throw error
        }
    }

    /// Feature-detect the static, signed interaction adapter before sending a
    /// page-action request. Older signed companions return no capability rather
    /// than receiving an unknown command.
    func requireInteractionCapability() async throws {
        let status = try await request("bridge.status")
        guard case .object(let fields) = status,
              case .array(let capabilities)? = fields["capabilities"],
              capabilities.contains(.string("browser_interaction_v1")) else {
            throw BrowserBridgeError.interactionUnavailable
        }
    }

    private static func journalMetadata(
        command: String,
        arguments: [String: JSONValue]
    ) -> (title: String, detail: String?) {
        let candidateURLs: [JSONValue]
        switch command {
        case "browser.open_tabs":
            if case .array(let urls)? = arguments["urls"] { candidateURLs = urls }
            else { candidateURLs = [] }
        case "browser.open", "browser.navigate":
            candidateURLs = ["url", "expectedURL"].compactMap { arguments[$0] }
        default:
            candidateURLs = ["expectedURL", "url"].compactMap { arguments[$0] }
        }
        let host: String? = candidateURLs.lazy.compactMap { value in
            guard case .string(let string) = value, let host = URL(string: string)?.host else { return nil }
            return host
        }.first
        switch command {
        case "browser.open", "browser.open_tabs", "browser.focus", "browser.navigate":
            let action: String
            switch command {
            case "browser.open": action = "Open tab"
            case "browser.open_tabs":
                if case .array(let urls)? = arguments["urls"] { action = "Open \(urls.count) tabs" }
                else { action = "Open tabs" }
            case "browser.focus": action = "Focus tab"
            default: action = "Navigate tab"
            }
            return ("AI browser navigation", [action, host].compactMap { $0 }.joined(separator: " · "))
        case "browser.click", "browser.type", "browser.submit":
            let action = command == "browser.click" ? "Click control" : (command == "browser.type" ? "Type text" : "Submit form")
            return ("AI browser interaction", [action, host].compactMap { $0 }.joined(separator: " · "))
        default:
            return ("Browser read", nil)
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
