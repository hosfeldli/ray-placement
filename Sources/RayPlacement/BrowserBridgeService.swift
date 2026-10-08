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
            switch code {
            case "site_not_granted":
                return "Site access is not granted. Allow reading for this exact HTTPS site in the Browser Bridge popup, or use a non-private tab."
            case "approval_expired":
                return "Browser approval expired. Retry the action and approve it promptly in the Zen or Firefox toolbar popup."
            case "denied":
                return "The browser action was denied in the companion popup."
            case "page_changed":
                return "The page changed since Lima inspected it. Refresh the granted tabs and try again."
            case "no_active_tab", "invalid_tab":
                return "The requested browser tab is no longer available. Refresh the granted tabs and try again."
            case "cancelled":
                return "The browser action was stopped."
            case "unsupported_command":
                return "The installed signed Browser Bridge companion does not support this interaction yet. Install a compatible signed companion release, then reconnect."
            case "site_policy_unavailable", "site_policy_update_failed":
                return "Browser site access could not be updated. Reconnect the companion and try again."
            case "target_not_found", "target_not_visible", "target_ambiguous", "invalid_selector", "unsupported_target", "sensitive_or_unsupported_target":
                return "The requested page control is unavailable or unsafe to use. Inspect the page again and choose a specific visible control."
            default:
                return "The browser could not complete this request. Check site access and the companion popup, then try again."
            }
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

    /// Returns current app/companion policy state without reading or changing a tab.
    func capabilitySnapshot(context suppliedContext: BrowserCapabilityTurnContext? = nil, requestedOrigin: String? = nil) async -> JSONValue {
        let toolStore = LimaAIToolStore.shared
        let context = suppliedContext ?? BrowserCapabilityTurnContext(
            selectedAgentID: nil,
            selectedAgentToolIDs: nil,
            enabledToolIDs: toolStore.effectiveEnabledToolIDs,
            turnToolIDs: toolStore.effectiveEnabledToolIDs,
            pendingApproval: false
        )
        let session = selectedSession
        let locallyConnected = enabled && session.map { sessions.contains($0) } == true
        var permissionStatusAvailable = false
        var companionConnected = locallyConnected
        var exactReadOrigins: [String] = []
        var exactInteractionOrigins: [String] = []
        var broadGrantInstalled = false
        var supportsInteraction = false
        var interactionPolicyAvailable = false

        if locallyConnected, let session {
            do {
                let response = try await rawRequest("bridge.status", expectedSession: session, recordActivity: false)
                guard case .object(let fields) = response,
                      case .array(let origins)? = fields["origins"] else {
                    throw BrowserBridgeError.invalidResponse
                }
                let readPolicy = try BrowserBridgeGrantPolicy.parse(origins)
                let interactionValues: [JSONValue]
                if case .array(let values)? = fields["interactionOrigins"] { interactionValues = values }
                else { interactionValues = [] }
                let interactionPolicy = try BrowserBridgeGrantPolicy.parse(interactionValues)
                exactReadOrigins = readPolicy.exactHosts.sorted().map { "https://\($0)" }
                exactInteractionOrigins = interactionPolicy.exactHosts.sorted().map { "https://\($0)" }
                broadGrantInstalled = readPolicy.hasBroadHTTPS
                if case .array(let capabilities)? = fields["capabilities"] {
                    supportsInteraction = capabilities.contains(.string("browser_interaction_v1"))
                }
                interactionPolicyAvailable = fields["interactionPolicyAvailable"] == .bool(true)
                companionConnected = fields["connected"] == .bool(true)
                permissionStatusAvailable = companionConnected
            } catch {
                permissionStatusAvailable = false
            }
        }

        let actionPolicy = AIComputerActionPolicy.shared
        let state = BrowserCapabilityState(
            bridgeEnabled: enabled,
            companionConnected: companionConnected,
            permissionStatusAvailable: permissionStatusAvailable,
            exactReadOrigins: exactReadOrigins,
            broadHTTPSGrantInstalled: broadGrantInstalled,
            broadHTTPSReadingEnabled: actionPolicy.broadBrowserGrantsExperimentalEnabled,
            exactInteractionOrigins: exactInteractionOrigins,
            companionSupportsInteraction: supportsInteraction,
            interactionPolicyAvailable: actionPolicy.browserInteractionExperimentalEnabled && interactionPolicyAvailable,
            navigationAccess: actionPolicy.access(for: .browserNavigation),
            interactionAccess: actionPolicy.access(for: .browserInteraction),
            context: context
        )

        func decision(_ value: BrowserCapabilityDecision) -> JSONValue {
            .object([
                "status": .string(value.status.rawValue),
                "reason": value.reason.map(JSONValue.string) ?? .null
            ])
        }
        let routedBrowserTools = (context.turnToolIDs
            .intersection(BrowserCapabilityTurnContext.readToolIDs)
            .union(context.turnToolIDs.intersection(BrowserCapabilityTurnContext.navigationToolIDs))
            .union(context.turnToolIDs.intersection(BrowserCapabilityTurnContext.interactionToolIDs)))
            .sorted()
        let originDecisions = requestedOrigin.map { state.decisions(forOrigin: $0) }
        return .object([
            "bridge": .object([
                "enabled": .bool(enabled),
                "status": .string(status),
                "companionConnected": .bool(companionConnected),
                "selectedSessionID": session.map { .string($0.uuidString) } ?? .null,
                "permissionStatusAvailable": .bool(permissionStatusAvailable)
            ]),
            "read": decision(state.read),
            "navigation": decision(state.navigation),
            "interaction": decision(state.interaction),
            "requestedOrigin": originDecisions?.origin.map(JSONValue.string) ?? .null,
            "originRead": originDecisions.map { decision($0.read) } ?? .null,
            "originNavigation": originDecisions.map { decision($0.navigation) } ?? .null,
            "originInteraction": originDecisions.map { decision($0.interaction) } ?? .null,
            "exactReadOrigins": .array(state.exactReadOrigins.map(JSONValue.string)),
            "exactInteractionOrigins": .array(state.exactInteractionOrigins.map(JSONValue.string)),
            "broadHTTPSGrantInstalled": .bool(state.broadHTTPSGrantInstalled),
            "broadHTTPSReadingEnabled": .bool(state.broadHTTPSReadingEnabled),
            "interactionCapabilitySupported": .bool(supportsInteraction),
            "interactionPolicyAvailable": .bool(interactionPolicyAvailable),
            "navigationPolicy": .string(actionPolicy.access(for: .browserNavigation).rawValue),
            "interactionPolicy": .string(actionPolicy.access(for: .browserInteraction).rawValue),
            "submitRequiresApproval": .bool(state.interactionSubmitRequiresApproval),
            "selectedAgentID": context.selectedAgentID.map(JSONValue.string) ?? .null,
            "routedBrowserTools": .array(routedBrowserTools.map(JSONValue.string))
        ])
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

    private struct TabIdentity {
        let id: Double
        let url: String
        let title: String
        let windowID: Double?
    }

    private enum BatchDestination {
        case existing(TabIdentity)
        case opened(index: Int, firstForURL: Bool)
    }

    /// Canonicalize only for matching; preserve the caller's requested and
    /// observed URLs in results. URL fragments do not create separate tabs.
    private static func canonicalTabURL(_ rawValue: String) -> String? {
        guard var components = URLComponents(string: rawValue),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.port == nil else { return nil }
        components.scheme = "https"
        components.host = host.lowercased()
        if components.path.isEmpty { components.path = "/" }
        components.fragment = nil
        return components.string
    }

    private func tabIdentities(in value: JSONValue) -> [TabIdentity] {
        guard case .object(let fields) = value, case .array(let tabs)? = fields["tabs"] else { return [] }
        return tabs.compactMap { tab in
            guard case .object(let fields) = tab,
                  case .number(let id)? = fields["id"], id.isFinite, id >= 0, id.rounded() == id,
                  case .string(let url)? = fields["url"], Self.canonicalTabURL(url) != nil else { return nil }
            let title: String
            if case .string(let value)? = fields["title"] { title = value } else { title = "" }
            let windowID: Double?
            if case .number(let value)? = fields["windowID"], value.isFinite { windowID = value }
            else { windowID = nil }
            return TabIdentity(id: id, url: url, title: title, windowID: windowID)
        }
    }

    private func correlateOpenedTabs(
        requestedURLs: [String],
        before: [TabIdentity],
        after: [TabIdentity]
    ) -> [Int: TabIdentity] {
        let previousIDs = Set(before.map(\.id))
        let newlyObserved = after.filter { !previousIDs.contains($0.id) }
        var requestedByCanonicalURL: [String: [Int]] = [:]
        for index in requestedURLs.indices {
            guard let key = Self.canonicalTabURL(requestedURLs[index]) else { continue }
            requestedByCanonicalURL[key, default: []].append(index)
        }

        var identities: [Int: TabIdentity] = [:]
        for (key, indices) in requestedByCanonicalURL {
            var candidates = newlyObserved
                .filter { Self.canonicalTabURL($0.url) == key }
                .sorted { $0.id < $1.id }
            var unmatchedIndices = indices

            for requestedURL in Set(indices.map { requestedURLs[$0] }) {
                let exactIndices = unmatchedIndices.filter { requestedURLs[$0] == requestedURL }
                let exactCandidates = candidates.filter { $0.url == requestedURL }
                guard !exactIndices.isEmpty, exactCandidates.count == exactIndices.count else { continue }
                let candidateIDs = Set(exactCandidates.map(\.id))
                for (index, candidate) in zip(exactIndices, exactCandidates) { identities[index] = candidate }
                unmatchedIndices.removeAll { exactIndices.contains($0) }
                candidates.removeAll { candidateIDs.contains($0.id) }
            }

            // If a redirect changed the URL, correlate only when the remaining
            // URL group is one-to-one; otherwise leave identity explicitly unknown.
            if unmatchedIndices.count == candidates.count {
                for (index, candidate) in zip(unmatchedIndices, candidates) { identities[index] = candidate }
            }
        }
        return identities
    }

    /// Keep the companion wire format at its signed 1.3.2 contract. Lima does
    /// URL-based reuse and identity projection around that bounded batch request.
    func openTabs(urls: [String], background: Bool, reuseExisting: Bool = true) async throws -> JSONValue {
        guard (1...50).contains(urls.count), urls.allSatisfy({ Self.canonicalTabURL($0) != nil }),
              let session = selectedSession else { throw BrowserBridgeError.invalidResponse }

        let beforeSnapshot = try await tabsSnapshot()
        guard selectedSession == session else { throw BrowserBridgeError.unavailable }
        let before = tabIdentities(in: beforeSnapshot).sorted { $0.id < $1.id }
        var existingByURL: [String: TabIdentity] = [:]
        for tab in before {
            if let key = Self.canonicalTabURL(tab.url), existingByURL[key] == nil { existingByURL[key] = tab }
        }

        var openURLs: [String] = []
        var firstOpenByURL: [String: Int] = [:]
        var destinations: [BatchDestination] = []
        for url in urls {
            guard let key = Self.canonicalTabURL(url) else { throw BrowserBridgeError.invalidResponse }
            if reuseExisting, let existing = existingByURL[key] {
                destinations.append(.existing(existing))
            } else if reuseExisting, let index = firstOpenByURL[key] {
                destinations.append(.opened(index: index, firstForURL: false))
            } else {
                let index = openURLs.count
                openURLs.append(url)
                if reuseExisting { firstOpenByURL[key] = index }
                destinations.append(.opened(index: index, firstForURL: true))
            }
        }

        var opened = 0
        var failed = 0
        var identities: [Int: TabIdentity] = [:]
        if !openURLs.isEmpty {
            let response = try await request("browser.open_tabs", arguments: [
                "urls": .array(openURLs.map(JSONValue.string)),
                "background": .bool(background)
            ])
            guard selectedSession == session, case .object(let fields) = response,
                  case .number(let openedValue)? = fields["opened"], openedValue.isFinite,
                  openedValue >= 0, openedValue.rounded() == openedValue,
                  openedValue <= Double(openURLs.count) else { throw BrowserBridgeError.invalidResponse }
            opened = Int(openedValue)
            if case .number(let failedValue)? = fields["failed"], failedValue.isFinite,
               failedValue >= 0, failedValue.rounded() == failedValue,
               failedValue <= Double(openURLs.count) {
                failed = Int(failedValue)
            }

            // Opening is already complete. If a later tab snapshot is unavailable,
            // keep the successful action result and mark identities as unavailable.
            if opened > 0, let afterSnapshot = try? await tabsSnapshot(), selectedSession == session {
                identities = correlateOpenedTabs(
                    requestedURLs: openURLs,
                    before: before,
                    after: tabIdentities(in: afterSnapshot)
                )
            }
        }

        func resultRow(
            requestedURL: String,
            identity: TabIdentity?,
            openedNew: Bool,
            reusedExisting: Bool,
            error: String? = nil
        ) -> JSONValue {
            var fields: [String: JSONValue] = [
                "requestedURL": .string(requestedURL),
                "tabID": identity.map { .number($0.id) } ?? .null,
                "finalURL": identity.map { .string($0.url) } ?? .null,
                "openedNew": .bool(openedNew),
                "reusedExisting": .bool(reusedExisting),
                "title": .string(identity?.title ?? ""),
                "identityStatus": .string(identity == nil ? "unavailable" : "observed")
            ]
            if let windowID = identity?.windowID { fields["windowID"] = .number(windowID) }
            if let error { fields["error"] = .string(error) }
            return .object(fields)
        }

        let results = destinations.enumerated().map { requestIndex, destination -> JSONValue in
            switch destination {
            case .existing(let identity):
                return resultRow(requestedURL: urls[requestIndex], identity: identity,
                                 openedNew: false, reusedExisting: true)
            case .opened(let index, let firstForURL):
                guard index < opened else {
                    return resultRow(requestedURL: urls[requestIndex], identity: nil,
                                     openedNew: false, reusedExisting: false, error: "open_failed")
                }
                return resultRow(requestedURL: urls[requestIndex], identity: identities[index],
                                 openedNew: firstForURL, reusedExisting: reuseExisting && !firstForURL)
            }
        }
        return .object([
            "opened": .number(Double(opened)),
            "failed": .number(Double(failed)),
            "background": .bool(background),
            "reuseExisting": .bool(reuseExisting),
            "results": .array(results)
        ])
    }

    func tabsSnapshot() async throws -> JSONValue {
        try await request("browser.tabs")
    }

    func currentTabSnapshot() async throws -> JSONValue {
        try await request("browser.current")
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
