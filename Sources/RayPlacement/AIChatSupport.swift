import AppKit
import Foundation
import Security
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Chat controls and persisted metadata

enum AIReasoningEffort: String, Codable, CaseIterable, Identifiable, Sendable {
    case minimal
    case low
    case medium
    case high
    case xhigh

    var id: String { rawValue }

    var title: String {
        switch self {
        case .minimal: return "Quick"
        case .low: return "Light"
        case .medium: return "Standard"
        case .high: return "Deep"
        case .xhigh: return "Max"
        }
    }

    var detail: String {
        switch self {
        case .minimal: return "Lowest latency"
        case .low: return "Fast reasoning"
        case .medium: return "Balanced quality and speed"
        case .high: return "More deliberate analysis"
        case .xhigh: return "Maximum supported effort"
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
}

enum AIToolApprovalDecision: String, Codable, Sendable {
    case pending
    case allowedOnce
    case denied
}

struct AIToolApprovalRequest: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var remoteApprovalID: String?
    var serverLabel: String
    var toolName: String
    var arguments: String?
    var decision: AIToolApprovalDecision
    var createdAt: Date

    init(
        id: UUID = UUID(),
        remoteApprovalID: String? = nil,
        serverLabel: String,
        toolName: String,
        arguments: String? = nil,
        decision: AIToolApprovalDecision = .pending,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.remoteApprovalID = remoteApprovalID
        self.serverLabel = serverLabel
        self.toolName = toolName
        self.arguments = arguments
        self.decision = decision
        self.createdAt = createdAt
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
    private let queue = DispatchQueue(label: "dev.liam.lima.mcp-persistence", qos: .utility)
    private var pendingSave: DispatchWorkItem?

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        fileURL = base.appendingPathComponent("Lima/AI/mcp-servers.json")
        load()
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
    private static let service = "dev.liam.lima.mcp"

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
        if let sessionID {
            _ = try await post(
                to: endpoint,
                server: server,
                method: "notifications/initialized",
                params: [:],
                sessionID: sessionID,
                requestID: nil
            )
        }

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

struct AIMarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let value):
                    if let attributed = try? AttributedString(markdown: value, options: .init(interpretedSyntax: .full)) {
                        Text(attributed).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                case .code(let language, let value):
                    VStack(alignment: .leading, spacing: 4) {
                        if !language.isEmpty { Text(language).limaFont(.caption2).foregroundStyle(LimaColors.tertiaryText) }
                        Text(value)
                            .font(.system(size: 12.5, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LimaColors.editorBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(LimaColors.border, lineWidth: 1))
                }
            }
        }
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
