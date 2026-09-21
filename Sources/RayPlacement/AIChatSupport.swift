import AppKit
import ApplicationServices
import Foundation
import Security
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Chat controls and persisted metadata

enum AIReasoningEffort: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Off"
        case .minimal: return "Quick"
        case .low: return "Light"
        case .medium: return "Standard"
        case .high: return "Deep"
        case .xhigh: return "Extra Deep"
        case .max: return "Max"
        }
    }

    var detail: String {
        switch self {
        case .none: return "No reasoning"
        case .minimal: return "Lowest latency"
        case .low: return "Fast reasoning"
        case .medium: return "Balanced quality and speed"
        case .high: return "More deliberate analysis"
        case .xhigh: return "Extended reasoning"
        case .max: return "Maximum supported effort"
        }
    }
}

struct AIModelOption: Hashable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let supportsReasoning: Bool
    let supportedReasoningEfforts: [AIReasoningEffort]

    init(
        id: String,
        displayName: String? = nil,
        supportsReasoning: Bool? = nil,
        supportedReasoningEfforts: [AIReasoningEffort]? = nil
    ) {
        self.id = id
        self.displayName = displayName ?? Self.displayName(for: id)
        let inferredReasoning = Self.isReasoningModel(id)
        self.supportsReasoning = supportsReasoning ?? inferredReasoning
        self.supportedReasoningEfforts = supportedReasoningEfforts
            ?? ((supportsReasoning ?? inferredReasoning) ? Self.reasoningEfforts(for: id) : [])
    }

    var isLegacyOrUnknown: Bool {
        !Self.isKnownModel(id)
    }

    var defaultReasoningEffort: AIReasoningEffort? {
        supportedReasoningEfforts.contains(.medium)
            ? .medium
            : supportedReasoningEfforts.first
    }

    static func isChatModel(_ id: String) -> Bool {
        let value = id.lowercased()
        let nonChatMarkers = ["embedding", "moderation", "whisper", "tts", "dall-e", "image", "search-preview", "transcribe", "realtime", "audio", "search"]
        guard !nonChatMarkers.contains(where: value.contains) else { return false }
        return value.hasPrefix("gpt-")
            || value.hasPrefix("o1")
            || value.hasPrefix("o3")
            || value.hasPrefix("o4")
            || value.hasPrefix("chatgpt-")
            || value.contains("computer-use")
    }

    private static func isKnownModel(_ id: String) -> Bool {
        let value = id.lowercased()
        return value.hasPrefix("gpt-") || value.hasPrefix("o1") || value.hasPrefix("o3") || value.hasPrefix("o4")
    }

    static func isReasoningModel(_ id: String) -> Bool {
        let value = id.lowercased()
        return value.hasPrefix("o1") || value.hasPrefix("o3") || value.hasPrefix("o4") || value.contains("gpt-5")
    }

    static func reasoningEfforts(for id: String) -> [AIReasoningEffort] {
        let value = id.lowercased()
        if value.hasPrefix("gpt-5.6") {
            return [.none, .low, .medium, .high, .xhigh, .max]
        }
        // Verified against the Responses API on 2026-09-20. GPT-5.4 rejects
        // both legacy `minimal` and `max`; keep the UI from constructing
        // either invalid request.
        if value.hasPrefix("gpt-5.4") {
            return [.none, .low, .medium, .high, .xhigh]
        }
        if value.contains("pro") {
            return [.high]
        }
        if value.contains("xhigh") || value.contains("5.2") {
            return [.low, .medium, .high, .xhigh]
        }
        if value.hasPrefix("gpt-5") {
            return [.minimal, .low, .medium, .high]
        }
        return [.low, .medium, .high]
    }

    static func displayName(for id: String) -> String {
        id.split(separator: "-")
            .map { part in
                let value = String(part)
                return value.isEmpty ? value : value.prefix(1).uppercased() + value.dropFirst()
            }
            .joined(separator: " ")
    }

    static let fallbackModels: [AIModelOption] = [
        AIModelOption(id: "gpt-5.4", displayName: "GPT-5.4"),
        AIModelOption(id: "gpt-5", displayName: "GPT-5"),
        AIModelOption(id: "gpt-5-mini", displayName: "GPT-5 mini"),
        AIModelOption(id: "o4-mini", displayName: "o4-mini")
    ]
}

enum AIAttachmentKind: String, Codable, CaseIterable, Sendable {
    case file
    case image
    case clipboard
    case selection

    var symbol: String {
        switch self {
        case .file: return "doc"
        case .image: return "photo"
        case .clipboard: return "doc.on.clipboard"
        case .selection: return "text.quote"
        }
    }
}

struct AIAttachment: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var kind: AIAttachmentKind
    var displayName: String
    var path: String?
    var text: String?
    var mimeType: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        kind: AIAttachmentKind,
        displayName: String,
        path: String? = nil,
        text: String? = nil,
        mimeType: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.path = path
        self.text = text
        self.mimeType = mimeType
        self.createdAt = createdAt
    }

    var preview: String {
        if let text { return text.replacingOccurrences(of: "\n", with: " ").prefix(100).description }
        return path ?? displayName
    }
}

enum AIAgentActivityKind: String, Codable, Sendable {
    case started
    case thinking
    case reasoningSummary
    case toolStarted
    case toolCompleted
    case toolApproval
    case toolFailed
    case attachment
    case completed
    case error
}

struct AIUsageMetrics: Codable, Hashable, Sendable {
    var inputTokens: Int?
    var cachedInputTokens: Int?
    var outputTokens: Int?
    var reasoningTokens: Int?

    static func from(responseUsage usage: [String: Any]) -> Self {
        let inputDetails = usage["input_tokens_details"] as? [String: Any]
        let outputDetails = usage["output_tokens_details"] as? [String: Any]
        return Self(
            inputTokens: usage["input_tokens"] as? Int,
            cachedInputTokens: inputDetails?["cached_tokens"] as? Int,
            outputTokens: usage["output_tokens"] as? Int,
            reasoningTokens: outputDetails?["reasoning_tokens"] as? Int
        )
    }

    var totalKnownTokens: Int? {
        let values = [inputTokens, outputTokens, reasoningTokens].compactMap { $0 }
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    var displayText: String? {
        guard let totalKnownTokens else { return nil }
        return "\(totalKnownTokens.formatted()) tokens"
    }
}

struct AIAgentActivity: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var kind: AIAgentActivityKind
    var title: String
    var detail: String?
    var startedAt: Date
    var endedAt: Date?
    var duration: TimeInterval?
    var usage: AIUsageMetrics?
    var requiresApproval: Bool
    var completed: Bool

    init(
        id: UUID = UUID(),
        kind: AIAgentActivityKind,
        title: String,
        detail: String? = nil,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        duration: TimeInterval? = nil,
        usage: AIUsageMetrics? = nil,
        requiresApproval: Bool = false,
        completed: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.duration = duration
        self.usage = usage
        self.requiresApproval = requiresApproval
        self.completed = completed
    }

    var statusSymbol: String {
        switch kind {
        case .error, .toolFailed: return "exclamationmark.triangle.fill"
        case .toolApproval: return "hand.raised.fill"
        case .completed, .toolCompleted: return "checkmark"
        default: return "circle.fill"
        }
    }

    var displayTitle: String {
        switch title {
        case "read_screen_context": return "Screen context"
        case "search_files": return "Find files"
        case "read_file": return "Read a file"
        case "search_web": return "Search the web"
        case "list_extensions": return "Browse extensions"
        case "get_lima_status": return "Lima status"
        default: return title.replacingOccurrences(of: "_", with: " ")
        }
    }
}

enum AIToolApprovalDecision: String, Codable, Sendable {
    case pending
    case allowedOnce
    case denied
}

struct AIToolApprovalRequest: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var remoteApprovalID: String?
    var localCallID: String?
    var localToolID: String?
    var serverLabel: String
    var toolName: String
    var arguments: String?
    var decision: AIToolApprovalDecision
    var createdAt: Date

    init(
        id: UUID = UUID(),
        remoteApprovalID: String? = nil,
        localCallID: String? = nil,
        localToolID: String? = nil,
        serverLabel: String,
        toolName: String,
        arguments: String? = nil,
        decision: AIToolApprovalDecision = .pending,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.remoteApprovalID = remoteApprovalID
        self.localCallID = localCallID
        self.localToolID = localToolID
        self.serverLabel = serverLabel
        self.toolName = toolName
        self.arguments = arguments
        self.decision = decision
        self.createdAt = createdAt
    }
}

// MARK: - Responses output and diagnostics

enum AIOutputItemKind: String, Codable, Sendable {
    case message
    case reasoning
    case functionCall = "function_call"
    case mcpCall = "mcp_call"
    case mcpApprovalRequest = "mcp_approval_request"
    case toolCall = "tool_call"
    case unknown

    init(apiType: String) {
        switch apiType {
        case "message": self = .message
        case "reasoning": self = .reasoning
        case "function_call": self = .functionCall
        case "mcp_call": self = .mcpCall
        case "mcp_approval_request": self = .mcpApprovalRequest
        default:
            self = apiType.contains("tool") ? .toolCall : .unknown
        }
    }

    var isToolActivity: Bool {
        self == .functionCall || self == .mcpCall || self == .mcpApprovalRequest || self == .toolCall
    }
}

enum AIOutputItemPhase: String, Codable, Sendable {
    case added
    case completed
}

struct AIOutputItem: Hashable, Sendable {
    let phase: AIOutputItemPhase
    let kind: AIOutputItemKind
    let apiType: String
    let id: String?
    let callID: String?
    let name: String?
    let serverLabel: String?
    let arguments: String?
    let errorMessage: String?

    init(phase: AIOutputItemPhase, payload: [String: Any]) {
        let apiType = payload["type"] as? String ?? "unknown"
        self.phase = phase
        self.kind = AIOutputItemKind(apiType: apiType)
        self.apiType = apiType
        self.id = payload["id"] as? String ?? payload["approval_request_id"] as? String
        self.callID = payload["call_id"] as? String
        self.name = payload["name"] as? String ?? payload["tool_name"] as? String
        self.serverLabel = payload["server_label"] as? String
        self.arguments = payload["arguments"] as? String
        self.errorMessage = Self.errorMessage(from: payload["error"])
    }

    init(
        phase: AIOutputItemPhase,
        apiType: String,
        id: String? = nil,
        callID: String? = nil,
        name: String? = nil,
        serverLabel: String? = nil,
        arguments: String? = nil,
        errorMessage: String? = nil
    ) {
        self.phase = phase
        self.kind = AIOutputItemKind(apiType: apiType)
        self.apiType = apiType
        self.id = id
        self.callID = callID
        self.name = name
        self.serverLabel = serverLabel
        self.arguments = arguments
        self.errorMessage = errorMessage
    }

    private static func errorMessage(from value: Any?) -> String? {
        if let error = value as? [String: Any] { return error["message"] as? String }
        return value as? String
    }
}

struct AIChatDiagnostic: Codable, Hashable, Identifiable, Sendable {
    enum Stage: String, Codable, Sendable {
        case api
        case stream
        case outputItem
        case tool
        case transport
    }

    var id: UUID
    var stage: Stage
    var endpoint: String
    var httpStatus: Int?
    var model: String?
    var responseID: String?
    var eventType: String?
    var outputItemType: String?
    var toolName: String?
    var errorCode: String?
    var errorParameter: String?
    var message: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        stage: Stage,
        endpoint: String = "/v1/responses",
        httpStatus: Int? = nil,
        model: String? = nil,
        responseID: String? = nil,
        eventType: String? = nil,
        outputItemType: String? = nil,
        toolName: String? = nil,
        errorCode: String? = nil,
        errorParameter: String? = nil,
        message: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.stage = stage
        self.endpoint = endpoint
        self.httpStatus = httpStatus
        self.model = model
        self.responseID = responseID
        self.eventType = eventType
        self.outputItemType = outputItemType
        self.toolName = toolName
        self.errorCode = errorCode
        self.errorParameter = errorParameter
        self.message = message
        self.createdAt = createdAt
    }

    var developerSummary: String {
        var fields = ["Endpoint: \(endpoint)"]
        if let httpStatus { fields.append("HTTP: \(httpStatus)") }
        if let model { fields.append("Model: \(model)") }
        if let responseID { fields.append("Response: \(responseID)") }
        if let eventType { fields.append("Event: \(eventType)") }
        if let outputItemType { fields.append("Item: \(outputItemType)") }
        if let toolName { fields.append("Tool: \(toolName)") }
        if let errorCode { fields.append("Code: \(errorCode)") }
        if let errorParameter { fields.append("Parameter: \(errorParameter)") }
        fields.append(message)
        return fields.joined(separator: " · ")
    }
}

// MARK: - Remote HTTP MCP

enum MCPTransport: String, Codable, CaseIterable, Identifiable, Sendable {
    case streamableHTTP
    case sse
    var id: String { rawValue }
    var title: String { self == .sse ? "HTTP / SSE" : "Streamable HTTP" }
}

enum MCPToolRisk: String, Codable, Sendable {
    case read
    case write
    case destructive

    var title: String { rawValue.capitalized }
    var requiresApproval: Bool { self != .read }
}

struct MCPToolDescriptor: Codable, Hashable, Identifiable, Sendable {
    var id: String { "\(serverID.uuidString):\(name)" }
    var serverID: UUID
    var name: String
    var title: String?
    var description: String?
    var risk: MCPToolRisk
    var enabled: Bool

    var displayTitle: String { title?.isEmpty == false ? title! : name }
}

struct MCPServer: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var url: String
    var transport: MCPTransport
    var enabled: Bool
    var allowedToolNames: [String]
    var tools: [MCPToolDescriptor]
    var lastTestedAt: Date?
    var lastError: String?

    init(
        id: UUID = UUID(),
        name: String,
        url: String,
        transport: MCPTransport = .streamableHTTP,
        enabled: Bool = true,
        allowedToolNames: [String] = [],
        tools: [MCPToolDescriptor] = [],
        lastTestedAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.transport = transport
        self.enabled = enabled
        self.allowedToolNames = allowedToolNames
        self.tools = tools
        self.lastTestedAt = lastTestedAt
        self.lastError = lastError
    }

    var validURL: URL? { URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) }

    var validHTTPURL: URL? {
        guard let validURL,
              ["http", "https"].contains(validURL.scheme?.lowercased()),
              let host = validURL.host,
              !host.isEmpty,
              validURL.user == nil,
              validURL.password == nil else { return nil }
        return validURL
    }

    var apiLabel: String {
        let label = name.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "_"
        }.joined()
        let trimmed = String(label.prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let base = trimmed.isEmpty ? "mcp_\(id.uuidString.prefix(8))" : trimmed
        return base.first?.isNumber == true ? "mcp_\(base)" : base
    }

    static let noToolsSentinel = "__lima_no_mcp_tools__"

    var enabledTools: [MCPToolDescriptor] {
        guard allowedToolNames != [Self.noToolsSentinel] else { return [] }
        return tools.filter { $0.enabled && (allowedToolNames.isEmpty || allowedToolNames.contains($0.name)) }
    }
}

@MainActor
final class MCPServerStore: ObservableObject {
    static let shared = MCPServerStore()

    @Published private(set) var servers: [MCPServer] = []
    @Published private(set) var lastError: String?

    private let fileURL: URL
    private let persistsChanges: Bool
    private let queue = DispatchQueue(label: "dev.liam.lima.mcp-persistence", qos: .utility)
    private var pendingSave: DispatchWorkItem?

    private init() {
        if let testURL = LimaTestEnvironment.storageURL(relativePath: "AI/mcp-servers.json") {
            fileURL = testURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            fileURL = base.appendingPathComponent("Lima/AI/mcp-servers.json")
        }
        persistsChanges = true
        load()
    }

    init(fixtures: [MCPServer]) {
        fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("LimaMCPFixtures.json")
        persistsChanges = false
        servers = fixtures
    }

    func addOrUpdate(_ server: MCPServer) {
        servers.removeAll { $0.id == server.id }
        servers.insert(server, at: 0)
        scheduleSave()
    }

    func remove(id: UUID) {
        servers.removeAll { $0.id == id }
        MCPCredentialStore.remove(serverID: id)
        scheduleSave()
    }

    func setEnabled(_ id: UUID, enabled: Bool) {
        guard var server = servers.first(where: { $0.id == id }) else { return }
        server.enabled = enabled
        addOrUpdate(server)
    }

    func updateTools(_ tools: [MCPToolDescriptor], for id: UUID) {
        guard var server = servers.first(where: { $0.id == id }) else { return }
        server.tools = tools.map { tool in
            var updated = tool
            updated.enabled = server.allowedToolNames == [MCPServer.noToolsSentinel]
                ? false
                : (server.allowedToolNames.isEmpty || server.allowedToolNames.contains(tool.name))
            return updated
        }
        server.lastTestedAt = Date()
        server.lastError = nil
        if server.allowedToolNames.isEmpty { server.allowedToolNames = tools.map(\.name) }
        addOrUpdate(server)
    }

    func setToolEnabled(_ toolName: String, enabled: Bool, for serverID: UUID) {
        guard var server = servers.first(where: { $0.id == serverID }) else { return }
        var names: [String]
        if server.allowedToolNames == [MCPServer.noToolsSentinel] {
            names = []
        } else if server.allowedToolNames.isEmpty {
            names = server.tools.map(\.name)
        } else {
            names = server.allowedToolNames
        }
        names.removeAll { $0 == toolName }
        if enabled { names.append(toolName) }
        server.allowedToolNames = names.isEmpty && !enabled ? [MCPServer.noToolsSentinel] : names
        server.tools = server.tools.map {
            guard $0.name == toolName else { return $0 }
            var updated = $0
            updated.enabled = enabled
            return updated
        }
        addOrUpdate(server)
    }

    func markTestFailed(_ message: String, for id: UUID) {
        guard var server = servers.first(where: { $0.id == id }) else { return }
        server.lastTestedAt = Date()
        server.lastError = message
        addOrUpdate(server)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do { servers = try JSONDecoder().decode([MCPServer].self, from: data) }
        catch { lastError = "MCP server settings could not be loaded." }
    }

    private func scheduleSave() {
        guard persistsChanges else { return }
        pendingSave?.cancel()
        let snapshot = servers
        let url = fileURL
        let work = DispatchWorkItem { [weak self] in
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
                try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch { DispatchQueue.main.async { self?.lastError = error.localizedDescription } }
        }
        pendingSave = work
        queue.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
}

enum MCPCredentialStore {
    private static var service: String {
        LimaTestEnvironment.isEnabled ? "dev.liam.lima.mcp.test" : "dev.liam.lima.mcp"
    }

    static func save(serverID: UUID, value: String) throws {
        let data = Data(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard !data.isEmpty else { throw NSError(domain: "LimaMCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Enter a credential or token."]) }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: serverID.uuidString]
        let status = SecItemAdd(query.merging([kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]) { _, new in new } as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess else { throw keychainError() }
        } else if status != errSecSuccess { throw keychainError(status) }
    }

    static func value(serverID: UUID) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: serverID.uuidString, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func authorizationHeaderValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(of: "^(bearer|basic)\\s", options: [.regularExpression, .caseInsensitive]) == nil
            ? "Bearer \(trimmed)"
            : trimmed
    }

    static func remove(serverID: UUID) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: serverID.uuidString]
        SecItemDelete(query as CFDictionary)
    }

    private static func keychainError(_ status: OSStatus = errSecAuthFailed) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Lima could not access the MCP credential in Keychain."])
    }
}

struct MCPHTTPClient {
    enum ClientError: LocalizedError {
        case invalidURL
        case invalidResponse
        case requestFailed(Int, String)
        case invalidToolList
        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Enter a valid HTTP or HTTPS MCP URL."
            case .invalidResponse: return "The MCP server returned an invalid response."
            case .requestFailed(let status, let body): return "MCP request failed (\(status)): \(body)"
            case .invalidToolList: return "The MCP server did not return a valid tools/list response."
            }
        }
    }

    private let protocolVersion = "2025-06-18"

    func discoverTools(server: MCPServer) async throws -> [MCPToolDescriptor] {
        guard let url = server.validHTTPURL else { throw ClientError.invalidURL }
        let endpoint: URL
        switch server.transport {
        case .streamableHTTP:
            endpoint = url
        case .sse:
            endpoint = try await discoverSSEEndpoint(from: url, server: server)
        }

        let initialize = try await post(
            to: endpoint,
            server: server,
            method: "initialize",
            params: [
                "protocolVersion": protocolVersion,
                "capabilities": [:],
                "clientInfo": ["name": "Lima", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"]
            ],
            sessionID: nil
        )
        let initializeObject = try jsonObject(from: initialize.data)
        guard initializeObject["result"] != nil else { throw ClientError.invalidToolList }

        let sessionID = initialize.response.value(forHTTPHeaderField: "MCP-Session-Id")
        _ = try await post(
            to: endpoint,
            server: server,
            method: "notifications/initialized",
            params: [:],
            sessionID: sessionID,
            requestID: nil
        )

        let listed = try await post(
            to: endpoint,
            server: server,
            method: "tools/list",
            params: [:],
            sessionID: sessionID
        )
        let object = try jsonObject(from: listed.data)
        let result = (object["result"] as? [String: Any]) ?? object
        guard let tools = result["tools"] as? [[String: Any]] else { throw ClientError.invalidToolList }
        return tools.compactMap { tool in
            guard let name = tool["name"] as? String else { return nil }
            let description = tool["description"] as? String
            return MCPToolDescriptor(
                serverID: server.id,
                name: name,
                title: tool["title"] as? String,
                description: description,
                risk: risk(for: tool, name: name, description: description),
                enabled: true
            )
        }
    }

    func test(server: MCPServer) async throws -> [MCPToolDescriptor] { try await discoverTools(server: server) }

    private func post(
        to url: URL,
        server: MCPServer,
        method: String,
        params: [String: Any],
        sessionID: String?,
        requestID: String? = UUID().uuidString
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id") }
        if sessionID != nil { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        if let credential = MCPCredentialStore.value(serverID: server.id), !credential.isEmpty {
            request.setValue(MCPCredentialStore.authorizationHeaderValue(credential), forHTTPHeaderField: "Authorization")
        }
        var body: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if let requestID { body["id"] = requestID }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw ClientError.requestFailed(http.statusCode, Self.safeResponseText(data))
        }
        return (data, http)
    }

    private func discoverSSEEndpoint(from url: URL, server: MCPServer) async throws -> URL {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let credential = MCPCredentialStore.value(serverID: server.id), !credential.isEmpty {
            request.setValue(MCPCredentialStore.authorizationHeaderValue(credential), forHTTPHeaderField: "Authorization")
        }
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ClientError.invalidResponse
        }
        var event = ""
        var dataLines: [String] = []
        for try await line in bytes.lines {
            if line.isEmpty {
                if event == "endpoint", let value = dataLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).removingPercentEncoding,
                   let endpoint = URL(string: value, relativeTo: url)?.absoluteURL {
                    return endpoint
                }
                event = ""
                dataLines = []
            } else if line.hasPrefix("event:") {
                event = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        throw ClientError.invalidResponse
    }

    private func jsonObject(from data: Data) throws -> [String: Any] {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return object }
        let candidates = String(decoding: data, as: UTF8.self)
            .components(separatedBy: .newlines)
            .compactMap { line -> String? in
                guard line.hasPrefix("data:") else { return nil }
                return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            }
            .reversed()
        for candidate in candidates where candidate != "[DONE]" {
            if let object = try? JSONSerialization.jsonObject(with: Data(candidate.utf8)) as? [String: Any] { return object }
        }
        throw ClientError.invalidToolList
    }

    private func risk(for tool: [String: Any], name: String, description: String?) -> MCPToolRisk {
        if let annotations = tool["annotations"] as? [String: Any] {
            if annotations["destructiveHint"] as? Bool == true { return .destructive }
            if annotations["readOnlyHint"] as? Bool == true { return .read }
        }
        let lower = "\(name) \(description ?? "")".lowercased()
        if ["delete", "remove", "destroy", "drop", "purge"].contains(where: lower.contains) { return .destructive }
        if ["create", "update", "write", "send", "close", "move", "rename", "execute", "run"].contains(where: lower.contains) { return .write }
        return .read
    }

    private static func safeResponseText(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let message = error["message"] as? String { return message }
        return String(decoding: data.prefix(1_000), as: UTF8.self)
    }
}

// MARK: - Native Lima tools

enum AILocalToolRisk: String, Codable, Sendable {
    case read
    case localAction
    case write
    case destructive

    var requiresApproval: Bool { self != .read }
    var title: String {
        switch self {
        case .read: return "Read"
        case .localAction: return "Local action"
        case .write: return "Write"
        case .destructive: return "Destructive"
        }
    }
}

struct LimaAIToolDefinition: Identifiable, @unchecked Sendable {
    let id: String
    let name: String
    let description: String
    let parameters: [String: Any]
    let risk: AILocalToolRisk

    var responsePayload: [String: Any] {
        [
            "type": "function",
            "name": name,
            "description": description,
            "parameters": parameters,
            "strict": true
        ]
    }
}

struct LimaAIToolExecution: Sendable {
    let output: String
    let isError: Bool

    static func json(_ object: Any, isError: Bool = false) -> Self {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return Self(output: "{\\\"error\\\":\\\"Lima could not encode the tool result.\\\"}", isError: true)
        }
        return Self(output: text, isError: isError)
    }
}

enum AIReadOnlyPolicy {
    static let assistantInstructions = """
    You are Lima’s private assistant. Every tool is read-only: never write, delete, rename, install, execute, launch, submit, or otherwise change local or remote content. Do not attempt to use tools outside the supplied read-only list. You may inspect files, public web search results, screen context, and extension metadata. You may draft extension code or manifests in the chat for the user to review, but never save, install, or run an extension.
    """

    static func readableMCPTools(for server: MCPServer) -> [MCPToolDescriptor] {
        server.enabledTools.filter { !$0.risk.requiresApproval }
    }
}

@MainActor
final class LimaScreenContextStore {
    static let shared = LimaScreenContextStore()

    private var snapshot: [String: Any] = [:]

    func capture(application: NSRunningApplication) {
        guard application.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        var context: [String: Any] = [
            "application": application.localizedName ?? application.bundleIdentifier ?? "Unknown app",
            "captured_at": ISO8601DateFormatter().string(from: Date())
        ]
        if let title = focusedWindowTitle(for: application.processIdentifier), !title.isEmpty {
            context["window_title"] = title
        }
        if let selection = try? SelectedTextService.selectedText(in: application.processIdentifier),
           !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            context["selected_text"] = String(selection.prefix(6_000))
            context["selection_truncated"] = selection.count > 6_000
        }
        snapshot = context
    }

    func read() -> [String: Any] {
        guard !snapshot.isEmpty else {
            return [
                "note": "No previous-app screen context is available yet. Open Lima from the app you want to inspect, then ask again.",
                "screen_capture": false
            ]
        }
        var context = snapshot
        context["screen_capture"] = false
        context["note"] = "This is a read-only snapshot of the app and selected text that were active before Lima opened. Lima does not click or change that app."
        return context
    }

    private func focusedWindowTitle(for processIdentifier: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let application = AXUIElementCreateApplication(processIdentifier)
        var rawWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &rawWindow) == .success,
              let window = rawWindow else { return nil }
        var rawTitle: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &rawTitle) == .success else { return nil }
        return rawTitle as? String
    }
}

@MainActor
enum LimaAIToolRegistry {
    private static let fileSearch = FileSearchService()
    private static let maximumTextFileBytes = 96 * 1_024

    static let definitions: [LimaAIToolDefinition] = [
        LimaAIToolDefinition(
            id: "read_screen_context",
            name: "read_screen_context",
            description: "Read the previously active app’s name, window title, and selected text when macOS Accessibility permits it. It never captures pixels, clicks, types, or changes another app.",
            parameters: ["type": "object", "properties": [:] as [String: Any], "additionalProperties": false],
            risk: .read
        ),
        LimaAIToolDefinition(
            id: "search_files",
            name: "search_files",
            description: "Search file names in the user’s existing Spotlight index. Returns up to 20 paths and never reads file contents.",
            parameters: [
                "type": "object",
                "properties": ["query": ["type": "string", "description": "A concise file-name query."]],
                "required": ["query"],
                "additionalProperties": false
            ],
            risk: .read
        ),
        LimaAIToolDefinition(
            id: "read_file",
            name: "read_file",
            description: "Read a bounded text or source-code file. Sensitive credential locations, non-text files, and files larger than 96 KB are blocked. This tool never changes a file.",
            parameters: [
                "type": "object",
                "properties": ["path": ["type": "string", "description": "An absolute path returned by Search Files or supplied by the user."]],
                "required": ["path"],
                "additionalProperties": false
            ],
            risk: .read
        ),
        LimaAIToolDefinition(
            id: "search_web",
            name: "search_web",
            description: "Search public web results and return concise titles, URLs, and snippets. It never signs in, submits forms, follows private links, or changes web content.",
            parameters: [
                "type": "object",
                "properties": ["query": ["type": "string", "description": "A concise public-web search query."]],
                "required": ["query"],
                "additionalProperties": false
            ],
            risk: .read
        ),
        LimaAIToolDefinition(
            id: "list_extensions",
            name: "list_extensions",
            description: "List installed Lima extension commands and their declared capabilities. It only reads manifests; it does not run, install, modify, or approve extensions.",
            parameters: ["type": "object", "properties": [:] as [String: Any], "additionalProperties": false],
            risk: .read
        ),
        LimaAIToolDefinition(
            id: "get_lima_status",
            name: "get_lima_status",
            description: "Get non-sensitive Lima application status, including version and enabled read-only tool counts. Never returns credentials, prompts, selections, or Keychain data.",
            parameters: ["type": "object", "properties": [:] as [String: Any], "additionalProperties": false],
            risk: .read
        )
    ]

    static var defaultEnabledToolIDs: Set<String> { Set(definitions.map(\.id)) }

    static func definition(for name: String?) -> LimaAIToolDefinition? {
        guard let name else { return nil }
        return definitions.first { $0.name == name || $0.id == name }
    }

    static func enabledDefinitions(_ ids: Set<String>) -> [LimaAIToolDefinition] {
        definitions.filter { ids.contains($0.id) && $0.risk == .read }
    }

    static func execute(_ call: AIOutputItem) async -> LimaAIToolExecution {
        guard let definition = definition(for: call.name), definition.risk == .read else {
            return .json(["error": "Lima AI Chat only permits registered read-only tools."], isError: true)
        }
        switch definition.id {
        case "read_screen_context":
            return .json(LimaScreenContextStore.shared.read())
        case "search_files":
            guard let query = stringArgument(named: "query", from: call.arguments), !query.isEmpty else {
                return .json(["error": "Search Files needs a non-empty query."], isError: true)
            }
            let urls = await searchFiles(named: String(query.prefix(160)))
            return .json([
                "matches": urls.prefix(20).map { ["name": $0.lastPathComponent, "path": $0.path] },
                "truncated": urls.count > 20
            ])
        case "read_file":
            guard let path = stringArgument(named: "path", from: call.arguments), !path.isEmpty else {
                return .json(["error": "Read File needs an absolute path."], isError: true)
            }
            return readTextFile(at: path)
        case "search_web":
            guard let query = stringArgument(named: "query", from: call.arguments), !query.isEmpty else {
                return .json(["error": "Search Web needs a non-empty query."], isError: true)
            }
            return await searchWeb(query: String(query.prefix(200)))
        case "list_extensions":
            return extensionCatalog()
        case "get_lima_status":
            return .json([
                "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
                "native_read_only_tools_enabled": enabledDefinitions(LimaAIToolStore.shared.enabledToolIDs).count,
                "mcp_read_only_tools_enabled": MCPServerStore.shared.servers.filter(\.enabled).reduce(0) { $0 + AIReadOnlyPolicy.readableMCPTools(for: $1).count },
                "write_access": false
            ])
        default:
            return .json(["error": "The requested Lima tool is unavailable."], isError: true)
        }
    }

    private static func stringArgument(named key: String, from arguments: String?) -> String? {
        guard let arguments,
              let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func searchFiles(named query: String) async -> [URL] {
        await withCheckedContinuation { continuation in
            fileSearch.search(query) { urls in
                continuation.resume(returning: urls)
            }
        }
    }

    private static func readTextFile(at path: String) -> LimaAIToolExecution {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix("/") else {
            return .json(["error": "Read File only accepts absolute paths."], isError: true)
        }
        guard !isSensitivePath(url) else {
            return .json(["error": "Lima does not share credentials, system files, or hidden secret locations with AI Chat."], isError: true)
        }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey])
            guard values.isRegularFile == true else {
                return .json(["error": "Read File only supports regular files."], isError: true)
            }
            let byteCount = values.fileSize ?? 0
            guard byteCount <= maximumTextFileBytes else {
                return .json(["error": "That file is larger than Lima’s 96 KB read-only limit."], isError: true)
            }
            guard isTextFile(url: url, contentType: values.contentType) else {
                return .json(["error": "Read File supports text and source-code files only."], isError: true)
            }
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else {
                return .json(["error": "Lima could not decode that file as UTF-8 text."], isError: true)
            }
            let limitedText = String(text.prefix(32_000))
            return .json([
                "path": url.path,
                "content": limitedText,
                "truncated": text.count > limitedText.count
            ])
        } catch {
            return .json(["error": "Lima could not read that file."], isError: true)
        }
    }

    private static func isSensitivePath(_ url: URL) -> Bool {
        let components = Set(url.pathComponents.map { $0.lowercased() })
        let blockedComponents: Set<String> = [".ssh", ".aws", ".gnupg", ".docker", "keychains", "secrets"]
        if !components.intersection(blockedComponents).isEmpty { return true }
        let path = url.path.lowercased()
        return path.hasPrefix("/system/")
            || path.hasPrefix("/private/")
            || path.hasPrefix("/etc/")
            || path.contains("/library/application support/lima/ai/")
            || url.lastPathComponent.lowercased().contains("credential")
            || url.lastPathComponent.lowercased().contains("token")
            || url.lastPathComponent.lowercased().contains("secret")
    }

    private static func isTextFile(url: URL, contentType: UTType?) -> Bool {
        if contentType?.conforms(to: .text) == true || contentType?.conforms(to: .sourceCode) == true { return true }
        let extensions: Set<String> = ["csv", "env.example", "json", "log", "md", "plist", "py", "rb", "sh", "sql", "swift", "toml", "ts", "tsx", "txt", "xml", "yaml", "yml", "zsh"]
        return extensions.contains(url.pathExtension.lowercased())
    }

    private static func searchWeb(query: String) async -> LimaAIToolExecution {
        var components = URLComponents(string: "https://api.duckduckgo.com/")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "skip_disambig", value: "1")
        ]
        guard let url = components?.url else {
            return .json(["error": "Lima could not form a public web search request."], isError: true)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Lima/1.0 (read-only search)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .json(["error": "Public web search was unavailable."], isError: true)
            }
            var results: [[String: String]] = []
            if let abstract = object["AbstractText"] as? String, !abstract.isEmpty {
                results.append([
                    "title": (object["Heading"] as? String) ?? query,
                    "url": (object["AbstractURL"] as? String) ?? "",
                    "snippet": abstract
                ])
            }
            func collect(_ topics: [Any]) {
                for topic in topics where results.count < 6 {
                    if let item = topic as? [String: Any],
                       let text = item["Text"] as? String,
                       let firstURL = item["FirstURL"] as? String {
                        results.append(["title": String(text.prefix(160)), "url": firstURL, "snippet": text])
                    } else if let item = topic as? [String: Any], let nested = item["Topics"] as? [Any] {
                        collect(nested)
                    }
                }
            }
            collect(object["RelatedTopics"] as? [Any] ?? [])
            return .json(["query": query, "results": results, "source": "DuckDuckGo public instant answers"])
        } catch {
            return .json(["error": "Public web search could not be reached."], isError: true)
        }
    }

    private static func extensionCatalog() -> LimaAIToolExecution {
        let commands = ExtensionLoader().load(prepare: false, registerPackages: false).commands
        let entries = commands.prefix(80).map { loaded in
            [
                "extension": loaded.extensionName,
                "command": loaded.command.title,
                "summary": loaded.command.subtitle ?? "No summary provided.",
                "capabilities": loaded.capabilities.map(\.rawValue).sorted(),
                "action_type": loaded.command.action.type.rawValue,
                "can_execute_from_ai": false
            ] as [String: Any]
        }
        return .json([
            "commands": entries,
            "truncated": commands.count > entries.count,
            "policy": "AI Chat can inspect this catalog and draft extension code in chat, but never installs, executes, approves, or changes an extension."
        ])
    }
}

extension LimaAIToolDefinition {
    var displayName: String {
        switch id {
        case "read_screen_context": return "Screen context"
        case "search_files": return "Find files"
        case "read_file": return "Read a file"
        case "search_web": return "Search the web"
        case "list_extensions": return "Browse extensions"
        case "get_lima_status": return "Lima status"
        default: return name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var userSummary: String {
        switch id {
        case "read_screen_context": return "App, window, and selected text"
        case "search_files": return "Names and paths only"
        case "read_file": return "Text and code, never changes"
        case "search_web": return "Public results only"
        case "list_extensions": return "Catalog only, never runs"
        case "get_lima_status": return "Private app details"
        default: return description
        }
    }

    var symbol: String {
        switch id {
        case "read_screen_context": return "rectangle.on.rectangle"
        case "search_files": return "folder"
        case "read_file": return "doc.text"
        case "search_web": return "globe"
        case "list_extensions": return "square.grid.2x2"
        case "get_lima_status": return "checkmark.shield"
        default: return "eye"
        }
    }
}

@MainActor
final class LimaAIToolStore: ObservableObject {
    static let shared = LimaAIToolStore()

    @Published private(set) var enabledToolIDs: Set<String>
    private let defaultsKey = "lima.ai.enabled-native-tools"
    private let defaults: UserDefaults?

    private init() {
        let defaults = LimaTestEnvironment.userDefaults
        self.defaults = defaults
        let saved = defaults.stringArray(forKey: defaultsKey)
        enabledToolIDs = saved.map(Set.init) ?? LimaAIToolRegistry.defaultEnabledToolIDs
    }

    init(fixtures: Set<String>) {
        defaults = nil
        enabledToolIDs = fixtures
    }

    func isEnabled(_ definition: LimaAIToolDefinition) -> Bool {
        enabledToolIDs.contains(definition.id)
    }

    func setEnabled(_ definition: LimaAIToolDefinition, enabled: Bool) {
        if enabled { enabledToolIDs.insert(definition.id) }
        else { enabledToolIDs.remove(definition.id) }
        defaults?.set(Array(enabledToolIDs).sorted(), forKey: defaultsKey)
    }
}

// MARK: - Responses event decoding

enum AIResponsesEventDecoder {
    static func events(eventType: String, dataLines: [String], model: String?) -> [AIChatStreamEvent] {
        let data = dataLines.joined(separator: "\n")
        guard !data.isEmpty, data != "[DONE]" else { return [] }
        guard let payload = data.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return [.diagnostic(AIChatDiagnostic(
                stage: .stream,
                model: model,
                eventType: eventType.isEmpty ? nil : eventType,
                message: "Ignored malformed JSON in a streaming event."
            ))]
        }

        let type = (value["type"] as? String) ?? eventType
        let response = value["response"] as? [String: Any]
        let responseID = response?["id"] as? String ?? value["response_id"] as? String
        switch type {
        case "response.created", "response.in_progress":
            return responseID.map { [.responseCreated($0)] } ?? []
        case "response.output_text.delta":
            return (value["delta"] as? String).map { [.textDelta($0)] } ?? []
        case "response.output_text.done":
            return []
        case "response.reasoning_summary_text.delta", "response.reasoning_summary.delta":
            return (value["delta"] as? String).map { [.reasoningSummaryDelta($0)] } ?? []
        case "response.reasoning_summary_part.added":
            guard let part = value["part"] as? [String: Any], let text = part["text"] as? String, !text.isEmpty else { return [] }
            return [.reasoningSummaryDelta(text)]
        case "response.reasoning_summary_text.done", "response.reasoning_summary_part.done":
            return []
        case "response.content_part.added":
            guard let part = value["part"] as? [String: Any],
                  part["type"] as? String == "output_text",
                  let text = part["text"] as? String,
                  !text.isEmpty else { return [] }
            return [.textDelta(text)]
        case "response.content_part.done":
            return []
        case "response.output_item.added":
            return outputItemEvents(value["item"] as? [String: Any], phase: .added, model: model, responseID: responseID, eventType: type)
        case "response.output_item.done":
            return outputItemEvents(value["item"] as? [String: Any], phase: .completed, model: model, responseID: responseID, eventType: type)
        case "response.function_call_arguments.delta", "response.mcp_call.arguments.delta", "response.mcp_call_arguments.delta":
            return []
        case "response.function_call_arguments.done":
            let item = AIOutputItem(
                phase: .completed,
                apiType: "function_call",
                id: value["item_id"] as? String,
                callID: value["call_id"] as? String,
                name: value["name"] as? String,
                arguments: value["arguments"] as? String
            )
            return [.outputItem(item)]
        case "response.mcp_call.completed", "response.mcp_call.done":
            if let item = value["item"] as? [String: Any] {
                return outputItemEvents(item, phase: .completed, model: model, responseID: responseID, eventType: type)
            }
            return [.outputItem(AIOutputItem(
                phase: .completed,
                apiType: "mcp_call",
                name: value["name"] as? String,
                serverLabel: value["server_label"] as? String,
                errorMessage: errorMessage(from: value["error"])
            ))]
        case "response.mcp_call.failed", "response.mcp_call.error":
            return [.outputItem(AIOutputItem(
                phase: .completed,
                apiType: "mcp_call",
                name: value["name"] as? String,
                serverLabel: value["server_label"] as? String,
                errorMessage: errorMessage(from: value["error"]) ?? "The MCP tool failed."
            ))]
        case "response.completed":
            var result: [AIChatStreamEvent] = []
            if let usage = response?["usage"] as? [String: Any] { result.append(.usage(AIUsageMetrics.from(responseUsage: usage))) }
            result.append(.completed(responseID))
            return result
        case "response.failed", "error":
            let error = value["error"] as? [String: Any]
            let message = (error?["message"] as? String) ?? (value["message"] as? String) ?? "The provider reported a failed response."
            return [
                .diagnostic(AIChatDiagnostic(
                    stage: .api,
                    model: model,
                    responseID: responseID,
                    eventType: type,
                    errorCode: error?["code"] as? String,
                    errorParameter: error?["param"] as? String,
                    message: message
                )),
                .failed(message)
            ]
        default:
            return [.diagnostic(AIChatDiagnostic(
                stage: .stream,
                model: model,
                responseID: responseID,
                eventType: type.isEmpty ? nil : type,
                message: "Ignored an unsupported but well-formed Responses event."
            ))]
        }
    }

    private static func outputItemEvents(
        _ payload: [String: Any]?,
        phase: AIOutputItemPhase,
        model: String?,
        responseID: String?,
        eventType: String
    ) -> [AIChatStreamEvent] {
        guard let payload else {
            return [.diagnostic(AIChatDiagnostic(
                stage: .outputItem,
                model: model,
                responseID: responseID,
                eventType: eventType,
                message: "Ignored an output-item event without an item payload."
            ))]
        }
        let item = AIOutputItem(phase: phase, payload: payload)
        var events: [AIChatStreamEvent] = [.outputItem(item)]
        if item.kind == .unknown {
            events.append(.diagnostic(AIChatDiagnostic(
                stage: .outputItem,
                model: model,
                responseID: responseID,
                eventType: eventType,
                outputItemType: item.apiType,
                message: "Ignored an unsupported Responses output item."
            )))
        }
        return events
    }

    private static func errorMessage(from value: Any?) -> String? {
        if let error = value as? [String: Any] { return error["message"] as? String }
        return value as? String
    }
}

/// Incrementally reconstructs Responses Server-Sent Events without delaying
/// streamed output. Keeping framing separate from semantic decoding makes the
/// raw line-boundary behavior directly testable.
struct AIResponsesSSEParser {
    private let model: String?
    private var eventType = ""
    private var dataLines: [String] = []
    private var rawLineBytes: [UInt8] = []

    init(model: String?) {
        self.model = model
    }

    /// Feed one decoded line when a caller already preserves blank SSE delimiters.
    mutating func append(line: String) -> [AIChatStreamEvent] {
        if line.isEmpty {
            return flush()
        }
        if line.hasPrefix("event:") {
            eventType = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
            dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
        }
        return []
    }

    /// Feed raw response bytes. The URLSession line iterator can omit empty
    /// lines, which are the SSE event boundary; byte framing retains them.
    mutating func append(byte: UInt8) -> [AIChatStreamEvent] {
        guard byte == 0x0A else {
            rawLineBytes.append(byte)
            return []
        }

        let line = String(decoding: rawLineBytes, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        rawLineBytes.removeAll(keepingCapacity: true)
        return append(line: line)
    }

    mutating func finish() -> [AIChatStreamEvent] {
        var events: [AIChatStreamEvent] = []
        if !rawLineBytes.isEmpty {
            let line = String(decoding: rawLineBytes, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            rawLineBytes.removeAll(keepingCapacity: true)
            events += append(line: line)
        }
        events += flush()
        return events
    }

    private mutating func flush() -> [AIChatStreamEvent] {
        defer {
            eventType = ""
            dataLines = []
        }
        return AIResponsesEventDecoder.events(eventType: eventType, dataLines: dataLines, model: model)
    }
}

// MARK: - Local context and attachment encoding

@MainActor
enum AIContextCapture {
    static func clipboardAttachment() -> AIAttachment? {
        guard let text = NSPasteboard.general.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return AIAttachment(kind: .clipboard, displayName: "Clipboard", text: text, mimeType: "text/plain")
    }

    static func selectionAttachment() -> AIAttachment? {
        let app = NSWorkspace.shared.frontmostApplication
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier, let text = try? SelectedTextService.selectedText(in: app.processIdentifier), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return AIAttachment(kind: .selection, displayName: "Current Selection", text: text, mimeType: "text/plain")
    }

    static func attachment(for url: URL) -> AIAttachment {
        let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        let mime = type?.preferredMIMEType ?? "application/octet-stream"
        let kind: AIAttachmentKind = type?.conforms(to: .image) == true ? .image : .file
        return AIAttachment(kind: kind, displayName: url.lastPathComponent, path: url.path, mimeType: mime)
    }
}

struct AIInputEncoder {
    static func content(text: String, attachments: [AIAttachment]) throws -> [[String: Any]] {
        var content: [[String: Any]] = [["type": "input_text", "text": text]]
        for attachment in attachments {
            switch attachment.kind {
            case .clipboard, .selection:
                if let value = attachment.text { content.append(["type": "input_text", "text": "\n\n[\(attachment.displayName)]\n\(value)"]) }
            case .file, .image:
                guard let path = attachment.path else { continue }
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                guard data.count <= 50 * 1024 * 1024 else { throw NSError(domain: "LimaAI", code: 4, userInfo: [NSLocalizedDescriptionKey: "\(attachment.displayName) is larger than Lima’s 50 MB attachment limit."]) }
                let base64 = data.base64EncodedString()
                if attachment.kind == .image {
                    content.append(["type": "input_image", "image_url": "data:\(attachment.mimeType ?? "image/png");base64,\(base64)"])
                } else {
                    content.append(["type": "input_file", "filename": attachment.displayName, "file_data": "data:\(attachment.mimeType ?? "application/octet-stream");base64,\(base64)"])
                }
            }
        }
        return content
    }
}

// MARK: - Markdown rendering

/// A reusable read-only Markdown document renderer for Lima workspaces.
struct LimaMarkdownDocumentView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                markdownBlock(block)
            }
        }
    }

    @ViewBuilder
    private func markdownBlock(_ block: Block) -> some View {
        switch block {
        case .paragraph(let value):
            inlineText(value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let value):
            inlineText(value)
                .font(headingFont(for: level))
                .foregroundStyle(LimaTheme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level == 1 ? 4 : 1)
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        listMarker(item, index: index, ordered: ordered)
                            .frame(width: ordered ? 22 : 14, alignment: .trailing)
                            .foregroundStyle(LimaTheme.textSecondary)
                        inlineText(cleanListItem(item))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .quote(let value):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(SettingsStore.shared.accentTheme.readablePrimary)
                    .frame(width: 3)
                inlineText(value)
                    .foregroundStyle(LimaTheme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 3)
            .padding(.leading, 2)
        case .code(let language, let value):
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(language.isEmpty ? "CODE" : language.uppercased())
                        .limaFont(.caption2.weight(.semibold))
                        .foregroundStyle(LimaTheme.textTertiary)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(value, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .limaFont(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(LimaTheme.textSecondary)
                }
                Text(value)
                    .font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LimaTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous).stroke(LimaTheme.borderSubtle, lineWidth: LimaDesign.borderWidth))
        case .table(let headers, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    tableRow(headers, header: true)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        tableRow(row, header: false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous).stroke(LimaTheme.borderSubtle, lineWidth: LimaDesign.borderWidth))
            }
        case .rule:
            Rectangle()
                .fill(LimaTheme.borderStrong)
                .frame(height: LimaDesign.borderWidth)
                .padding(.vertical, 4)
        }
    }

    private func inlineText(_ value: String) -> Text {
        if let attributed = try? AttributedString(markdown: value, options: .init(interpretedSyntax: .full)) {
            return Text(attributed)
        }
        return Text(value)
    }

    @ViewBuilder
    private func listMarker(_ item: String, index: Int, ordered: Bool) -> some View {
        let trimmed = item.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[ ]") {
            Image(systemName: "square")
        } else if trimmed.lowercased().hasPrefix("[x]") {
            Image(systemName: "checkmark.square.fill")
        } else {
            Text(ordered ? "\(index + 1)." : "•")
                .limaFont(.body.weight(.medium))
        }
    }

    private func tableRow(_ cells: [String], header: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                inlineText(cell)
                    .limaFont(.callout.weight(header ? .semibold : .regular))
                    .textSelection(.enabled)
                    .frame(width: 150, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(header ? LimaTheme.surfaceSecondary : LimaTheme.surfaceRaised)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(LimaTheme.borderSubtle).frame(width: LimaDesign.borderWidth)
                    }
            }
        }
    }

    private func cleanListItem(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[ ]") || trimmed.lowercased().hasPrefix("[x]") else { return value }
        return String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return .title2.weight(.semibold)
        case 2: return .title3.weight(.semibold)
        default: return .headline
        }
    }

    private enum Block {
        case heading(Int, String)
        case paragraph(String)
        case list(Bool, [String])
        case quote(String)
        case code(String, String)
        case table([String], [[String]])
        case rule
    }

    private var blocks: [Block] {
        let lines = markdown.components(separatedBy: .newlines)
        let codeFence = String(repeating: "\u{60}", count: 3)
        var result: [Block] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            let value = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { result.append(.paragraph(value)) }
            paragraph = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
            } else if trimmed.hasPrefix(codeFence) {
                flushParagraph()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                index += 1
                var code: [String] = []
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(codeFence) {
                    code.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                result.append(.code(language, code.joined(separator: "\n")))
            } else if let heading = heading(from: trimmed) {
                flushParagraph()
                result.append(.heading(heading.level, heading.value))
                index += 1
            } else if isRule(trimmed) {
                flushParagraph()
                result.append(.rule)
                index += 1
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    quote.append(String(candidate.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                result.append(.quote(quote.joined(separator: "\n")))
            } else if let list = listStart(trimmed) {
                flushParagraph()
                var items: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard let next = listStart(candidate), next.ordered == list.ordered else { break }
                    items.append(next.value)
                    index += 1
                }
                result.append(.list(list.ordered, items))
            } else if index + 1 < lines.count, trimmed.contains("|"), isTableSeparator(lines[index + 1]) {
                flushParagraph()
                let headers = tableCells(trimmed)
                index += 2
                var rows: [[String]] = []
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(tableCells(lines[index]))
                    index += 1
                }
                result.append(.table(headers, rows))
            } else {
                paragraph.append(line)
                index += 1
            }
        }

        flushParagraph()
        return result.isEmpty ? [.paragraph("")] : result
    }

    private func heading(from line: String) -> (level: Int, value: String)? {
        let hashes = line.prefix { $0 == "#" }
        guard !hashes.isEmpty, hashes.count <= 6 else { return nil }
        let remainder = line.dropFirst(hashes.count)
        guard remainder.first == " " else { return nil }
        return (hashes.count, remainder.trimmingCharacters(in: .whitespaces))
    }

    private func listStart(_ line: String) -> (ordered: Bool, value: String)? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            return (false, String(line.dropFirst(2)))
        }
        guard let period = line.firstIndex(of: "."), period > line.startIndex else { return nil }
        let prefix = line[..<period]
        let afterPeriod = line.index(after: period)
        guard prefix.allSatisfy(\.isNumber), line[afterPeriod...].first == " " else { return nil }
        return (true, String(line[line.index(after: afterPeriod)...]).trimmingCharacters(in: .whitespaces))
    }

    private func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        return compact.count >= 3 && (Set(compact) == ["-"] || Set(compact) == ["*"] || Set(compact) == ["_"])
    }

    private func isTableSeparator(_ line: String) -> Bool {
        let cells = tableCells(line)
        return !cells.isEmpty && cells.allSatisfy { cell in
            let compact = cell.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
            return compact.isEmpty && cell.contains("-")
        }
    }

    private func tableCells(_ line: String) -> [String] {
        line
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
    }
}

struct AIMarkdownView: View {
    let markdown: String

    var body: some View {
        LimaMarkdownDocumentView(markdown: markdown)
    }

    private enum Block { case text(String); case code(String, String) }

    private var blocks: [Block] {
        var result: [Block] = []
        var text = ""
        var code: String?
        var language = ""
        var codeLines: [String] = []
        for line in markdown.components(separatedBy: .newlines) {
            if line.hasPrefix("```") {
                if code != nil {
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(.text(text.trimmingCharacters(in: .whitespacesAndNewlines))); text = "" }
                    result.append(.code(language, codeLines.joined(separator: "\n")))
                    code = nil; language = ""; codeLines = []
                } else {
                    code = ""; language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
            } else if code != nil {
                codeLines.append(line)
            } else {
                text += line + "\n"
            }
        }
        if code != nil { text += "```\(language)\n\(codeLines.joined(separator: "\n"))" }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(.text(text.trimmingCharacters(in: .whitespacesAndNewlines))) }
        return result.isEmpty ? [.text("")] : result
    }
}

struct AIToolApprovalView: View {
    let request: AIToolApprovalRequest
    let allow: () -> Void
    let deny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(LimaColors.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lima wants to use a tool").limaFont(.callout.weight(.semibold))
                    Text("\(request.serverLabel) · \(request.toolName)")
                        .limaFont(.caption)
                        .foregroundStyle(LimaColors.secondaryText)
                }
                Spacer()
            }
            if let arguments = request.arguments, !arguments.isEmpty {
                Text(arguments)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(8)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LimaColors.editorBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            HStack {
                Text("Write and destructive tools always require a decision.")
                    .limaFont(.caption2)
                    .foregroundStyle(LimaColors.tertiaryText)
                Spacer()
                Button("Deny", action: deny)
                Button("Allow Once", action: allow)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(LimaColors.recessedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(LimaColors.warning.opacity(0.55), lineWidth: 1))
    }
}

struct AIAttachmentStrip: View {
    let attachments: [AIAttachment]
    let remove: (AIAttachment) -> Void

    var body: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(attachments) { attachment in
                        HStack(spacing: 5) {
                            Image(systemName: attachment.kind.symbol)
                            Text(attachment.displayName).lineLimit(1)
                            Button { remove(attachment) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                        }
                        .limaFont(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(LimaColors.accentSoft, in: Capsule())
                    }
                }
            }
        }
    }
}
