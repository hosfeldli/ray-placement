import AppKit
import ApplicationServices
import CoreFoundation
import Foundation
import PDFKit
import RayPlacementCore
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

struct AIModelOption: Codable, Hashable, Identifiable, Sendable {
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
        // Discovery only returns model IDs, not feature metadata. Treat unfamiliar
        // families conservatively instead of equating a catalog entry with support.
        let knownFamilies = ["gpt-4o", "gpt-4.1", "gpt-5", "gpt-6", "o1", "o3", "o4"]
        return knownFamilies.contains { value == $0 || value.hasPrefix($0 + "-") || value.hasPrefix($0 + ".") }
    }

    static func isReasoningModel(_ id: String) -> Bool {
        let value = id.lowercased()
        return value.hasPrefix("o1") || value.hasPrefix("o3") || value.hasPrefix("o4")
            || value == "gpt-5" || value.hasPrefix("gpt-5-")
            || value == "gpt-6" || value.hasPrefix("gpt-6-")
            || ["gpt-5.2", "gpt-5.4", "gpt-5.6"].contains(where: value.hasPrefix)
    }

    static func reasoningEfforts(for id: String) -> [AIReasoningEffort] {
        let value = id.lowercased()
        if value.hasPrefix("gpt-6") || value.hasPrefix("gpt-5.6") {
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
        AIModelOption(id: "o4-mini", displayName: "o4-mini"),
        AIModelOption(id: "gpt-6-luna", displayName: "GPT-6 Luna"),
        AIModelOption(id: "gpt-6-sol", displayName: "GPT-6 Sol"),
        AIModelOption(id: "gpt-6-astra", displayName: "GPT-6 Astra")
    ]
}

/// Keep the everyday picker small and conservative. Provider discovery is still
/// the source of available API IDs; this policy removes old, preview, and
/// non-chat families rather than claiming that every listed ID works in chat.
enum AIModelPickerPolicy {
    static func isRecentChatModel(_ id: String, for provider: AIProvider) -> Bool {
        let value = id.lowercased()
        let excluded = ["preview", "experimental", "deprecated", "legacy", "-exp", "-beta"]
        guard !excluded.contains(where: value.contains) else { return false }
        switch provider {
        case .openAI:
            guard AIModelOption.isChatModel(value) else { return false }
            return ["gpt-5.4", "gpt-5.5", "gpt-5.6", "gpt-5.7", "gpt-5.8", "gpt-5.9", "gpt-6"]
                .contains { value == $0 || value.hasPrefix($0 + "-") || value.hasPrefix($0 + ".") }
        case .anthropic:
            return ["claude-4", "claude-5", "claude-sonnet-4", "claude-opus-4", "claude-haiku-4",
                    "claude-sonnet-5", "claude-opus-5", "claude-haiku-5"]
                .contains { value == $0 || value.hasPrefix($0 + "-") || value.hasPrefix($0 + ".") }
        case .gemini:
            return value.hasPrefix("gemini-2.5-") || value.hasPrefix("gemini-3")
        case .openAICompatible:
            return true // The configured endpoint owns its own model names.
        case .codexCLI, .claudeCLI:
            return value == "default" // Explicit IDs appear only after a successful CLI probe.
        case .mistral, .xAI, .deepSeek, .openRouter:
            return false // Not currently exposed by AI Chat.
        }
    }
}

/// Shared provider-level model discovery state. Conversations only retain their
/// selected model; switching between them never replaces a freshly discovered
/// catalog with static fallback data.
@MainActor
final class AIModelCatalogStore: ObservableObject {
    struct Catalog: Codable, Sendable {
        var models: [AIModelOption]
        var refreshedAt: Date?
    }

    static let shared = AIModelCatalogStore()

    @Published private(set) var catalogs: [String: Catalog]
    private let defaults: UserDefaults
    private let storageKey: String
    private var listedModelIDs: [String: [String]]
    private var verifiedCLIModels: [String: [String: Date]]
    private var lastSelectedModels: [String: String]

    init(defaults: UserDefaults = LimaTestEnvironment.userDefaults, storageKey: String = "aiModelCatalogs") {
        self.defaults = defaults
        self.storageKey = storageKey
        catalogs = (defaults.data(forKey: storageKey)).flatMap { try? JSONDecoder().decode([String: Catalog].self, from: $0) } ?? [:]
        listedModelIDs = (defaults.data(forKey: storageKey + ".listedModelIDs"))
            .flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
        verifiedCLIModels = (defaults.data(forKey: storageKey + ".verifiedCLIModels"))
            .flatMap { try? JSONDecoder().decode([String: [String: Date]].self, from: $0) } ?? [:]
        lastSelectedModels = defaults.dictionary(forKey: storageKey + ".lastSelectedModels") as? [String: String] ?? [:]
    }

    func models(for provider: AIProvider, compatibleModelID: String) -> [AIModelOption] {
        var fallback = provider == .openAICompatible
            ? [AIModelOption(id: compatibleModelID, displayName: compatibleModelID, supportsReasoning: false)]
            : provider.chatModels
        if let discovered = catalogs[provider.rawValue]?.models, !discovered.isEmpty {
            fallback = merge(discovered, fallback)
        }
        return fallback
    }

    func replace(_ models: [AIModelOption], for provider: AIProvider) {
        let unique = uniqueModels(models)
        guard !unique.isEmpty else { return }
        catalogs[provider.rawValue] = Catalog(models: unique, refreshedAt: Date())
        listedModelIDs[provider.rawValue] = unique.map(\.id)
        if let data = try? JSONEncoder().encode(listedModelIDs) {
            defaults.set(data, forKey: storageKey + ".listedModelIDs")
        }
        persist()
    }

    func retain(_ model: AIModelOption, for provider: AIProvider) {
        let existing = catalogs[provider.rawValue]?.models ?? []
        let merged = uniqueModels(existing + [model])
        catalogs[provider.rawValue] = Catalog(models: merged, refreshedAt: catalogs[provider.rawValue]?.refreshedAt)
        persist()
    }

    func refreshedAt(for provider: AIProvider) -> Date? { catalogs[provider.rawValue]?.refreshedAt }

    func listedIDs(for provider: AIProvider) -> Set<String> {
        Set(listedModelIDs[provider.rawValue] ?? [])
    }

    func verifiedCLIModelIDs(for provider: AIProvider, now: Date = Date()) -> Set<String> {
        guard provider.isCLI else { return [] }
        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        return Set((verifiedCLIModels[provider.rawValue] ?? [:]).compactMap { id, date in
            date >= cutoff ? id : nil
        })
    }

    func markCLIVerified(_ modelID: String, for provider: AIProvider, now: Date = Date()) {
        guard provider.isCLI, modelID != "default" else { return }
        verifiedCLIModels[provider.rawValue, default: [:]][modelID] = now
        if let data = try? JSONEncoder().encode(verifiedCLIModels) {
            defaults.set(data, forKey: storageKey + ".verifiedCLIModels")
        }
        objectWillChange.send()
    }

    func lastSelectedModelID(for provider: AIProvider) -> String? {
        lastSelectedModels[provider.rawValue]
    }

    func rememberSelection(_ modelID: String, for provider: AIProvider) {
        lastSelectedModels[provider.rawValue] = modelID
        defaults.set(lastSelectedModels, forKey: storageKey + ".lastSelectedModels")
    }

    private func merge(_ primary: [AIModelOption], _ fallback: [AIModelOption]) -> [AIModelOption] {
        uniqueModels(primary + fallback)
    }

    private func uniqueModels(_ models: [AIModelOption]) -> [AIModelOption] {
        var seen = Set<String>()
        return models.filter { seen.insert($0.id).inserted }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(catalogs) else { return }
        defaults.set(data, forKey: storageKey)
    }
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
        case "memory_search": return "Recall memory"
        case "agent_models": return "Choose a subagent model"
        case "agent_delegate": return "Delegate analysis"
        case "read_screen_context": return "Screen context"
        case "search_notes": return "Search Notes"
        case "read_note": return "Read Note"
        case "search_files": return "Find files"
        case "read_file": return "Read a file"
        case "search_web": return "Search the web"
        case "read_web": return "Read a web page"
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
        AIProviderFailure.toolMessage(value)
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
        self.endpoint = endpoint == "/v1/responses" ? endpoint : "provider"
        self.httpStatus = httpStatus.flatMap { (100...599).contains($0) ? $0 : nil }
        // Caller-provided model names, IDs and tool labels may contain user content.
        self.model = nil
        self.responseID = nil
        self.eventType = AIProviderFailure.diagnosticEvent(eventType)
        self.outputItemType = outputItemType.map {
            ["message", "reasoning", "function_call", "mcp_call", "mcp_approval_request"].contains($0) ? $0 : "unknown"
        }
        self.toolName = AIProviderFailure.localToolName(toolName)
        self.errorCode = AIProviderFailure.code(errorCode)
        self.errorParameter = AIProviderFailure.parameter(errorParameter)
        self.message = AIProviderFailure.diagnosticMessage(message, status: self.httpStatus)
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, stage, endpoint, httpStatus, model, responseID, eventType, outputItemType
        case toolName, errorCode, errorParameter, message, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            stage: try c.decode(Stage.self, forKey: .stage),
            endpoint: try c.decode(String.self, forKey: .endpoint),
            httpStatus: try c.decodeIfPresent(Int.self, forKey: .httpStatus),
            eventType: try c.decodeIfPresent(String.self, forKey: .eventType),
            outputItemType: try c.decodeIfPresent(String.self, forKey: .outputItemType),
            toolName: try c.decodeIfPresent(String.self, forKey: .toolName),
            errorCode: try c.decodeIfPresent(String.self, forKey: .errorCode),
            errorParameter: try c.decodeIfPresent(String.self, forKey: .errorParameter),
            message: try c.decode(String.self, forKey: .message),
            createdAt: try c.decode(Date.self, forKey: .createdAt)
        )
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
    /// Only a fresh tools/list declaration can mark a tool read-only. Legacy
    /// persisted risk guesses decode as nil and remain unavailable to AI.
    var declaredReadOnly: Bool? = nil

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
                risk: Self.risk(for: tool, name: name, description: description),
                enabled: true,
                declaredReadOnly: (tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true
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
        var framer = AIProviderSSEFramer(maximumLineBytes: 64_000, maximumEventBytes: 64_000,
                                         maximumStreamBytes: 256_000, maximumDataLines: 256)
        for try await byte in bytes {
            try Task.checkCancellation()
            if let frame = try framer.append(byte), frame.event == "endpoint" {
                return try Self.validatedSSEEndpoint(frame.data, relativeTo: url)
            }
        }
        if let frame = try framer.finish(), frame.event == "endpoint" {
            return try Self.validatedSSEEndpoint(frame.data, relativeTo: url)
        }
        throw ClientError.invalidResponse
    }

    /// Discovery cannot redirect a saved MCP credential to a different origin.
    static func validatedSSEEndpoint(_ raw: String, relativeTo base: URL) throws -> URL {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 4_096,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: value, relativeTo: base)?.absoluteURL,
              let candidate = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let original = URLComponents(url: base, resolvingAgainstBaseURL: true),
              candidate.scheme?.lowercased() == original.scheme?.lowercased(),
              ["http", "https"].contains(candidate.scheme?.lowercased() ?? ""),
              candidate.host?.lowercased() == original.host?.lowercased(),
              (candidate.port ?? (candidate.scheme == "https" ? 443 : 80)) ==
                (original.port ?? (original.scheme == "https" ? 443 : 80)),
              candidate.user == nil, candidate.password == nil, candidate.fragment == nil else {
            throw ClientError.invalidResponse
        }
        return url
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

    /// Tool names and descriptions are not proof of safety. Require a server's
    /// explicit read-only declaration, then reject obvious mutating behavior
    /// even if the declaration is contradictory.
    static func risk(for tool: [String: Any], name: String, description: String?) -> MCPToolRisk {
        let annotations = tool["annotations"] as? [String: Any]
        let lower = "\(name) \(description ?? "")".lowercased()
        if annotations?["destructiveHint"] as? Bool == true ||
            ["delete", "remove", "destroy", "drop", "purge", "purchase", "payment"].contains(where: lower.contains) {
            return .destructive
        }
        if annotations?["readOnlyHint"] as? Bool != true ||
            ["create", "update", "write", "send", "post", "submit", "close", "move", "rename",
             "execute", "run", "open", "focus", "navigate", "click", "type", "save", "set_",
             "install", "launch", "upload", "download", "archive", "publish", "transfer"].contains(where: lower.contains) {
            return .write
        }
        return .read
    }

    private static func safeResponseText(_ data: Data) -> String {
        AIProviderFailure.message(data: data)
    }
}

// MARK: - Native Lima tools

enum AILocalToolRisk: String, Codable, Sendable {
    case read
    /// Changes browser presentation (open, focus, or navigate). Exposure is
    /// controlled by the user’s browser-navigation action policy.
    case navigation
    /// Narrow local workspace mutation, controlled by the Memory capability.
    case memory
    /// Bounded API request with no child tools or inherited context.
    case delegation
    case localAction
    case write
    case destructive

    var requiresApproval: Bool {
        switch self {
        case .read, .navigation, .memory, .delegation: return false
        case .localAction, .write, .destructive: return true
        }
    }

    var title: String {
        switch self {
        case .read: return "Read"
        case .navigation: return "Browser navigation"
        case .memory: return "Local memory"
        case .delegation: return "AI subagent"
        case .localAction: return "Local action"
        case .write: return "Write"
        case .destructive: return "Destructive"
        }
    }
}

struct ExtensionAIToolBinding: Equatable, Sendable {
    let extensionID: String
    let extensionName: String
    let extensionCapabilities: Set<ExtensionManifest.Capability>
    let tool: ExtensionToolDefinition
}

@MainActor
protocol ExtensionToolHostAdapter {
    var id: String { get }
    var requiredCapabilities: Set<ExtensionManifest.Capability> { get }
    func execute(definition: ExtensionToolDefinition, arguments: JSONValue) async throws -> JSONValue
}

@MainActor
private struct BuiltinReadOnlyExtensionToolAdapter: ExtensionToolHostAdapter {
    let kind: ExtensionToolHostAdapterID

    var id: String { kind.rawValue }

    var requiredCapabilities: Set<ExtensionManifest.Capability> {
        switch kind {
        case .searchFiles, .readTextFile: [.filesystem]
        case .readPublicWeb: [.network]
        case .transformText: []
        }
    }

    func execute(definition: ExtensionToolDefinition, arguments: JSONValue) async throws -> JSONValue {
        guard case .object(let values) = arguments else { throw ExtensionToolAdapterError.invalidArguments }
        func string(_ key: String) -> String? {
            guard case .string(let value)? = values[key] else { return nil }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        switch kind {
        case .searchFiles:
            guard let query = string("query"), !query.isEmpty else { throw ExtensionToolAdapterError.invalidArguments }
            let urls = await LimaAIToolRegistry.searchFiles(named: String(query.prefix(160)))
            return .object([
                "matches": .array(urls.prefix(20).map {
                    .object(["name": .string($0.lastPathComponent), "path": .string($0.path)])
                }),
                "truncated": .bool(urls.count > 20)
            ])
        case .readTextFile:
            guard let path = string("path"), !path.isEmpty else { throw ExtensionToolAdapterError.invalidArguments }
            return LimaAIToolRegistry.jsonValue(from: LimaAIToolRegistry.readTextFile(at: path))
        case .readPublicWeb:
            guard let url = string("url"), !url.isEmpty else { throw ExtensionToolAdapterError.invalidArguments }
            return LimaAIToolRegistry.jsonValue(from: await LimaAIToolRegistry.readPublicWebPage(url))
        case .transformText:
            guard let text = string("text"), text.count <= 100_000,
                  let operation = string("operation") else { throw ExtensionToolAdapterError.invalidArguments }
            let transformed: String
            switch operation {
            case "trim": transformed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            case "uppercase": transformed = text.uppercased()
            case "lowercase": transformed = text.lowercased()
            case "collapse_whitespace":
                transformed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            default: throw ExtensionToolAdapterError.invalidArguments
            }
            return .object(["text": .string(transformed)])
        }
    }
}

private enum ExtensionToolAdapterError: Error {
    case invalidArguments
    case unavailable
    case unauthorized
}

struct AIChatSkillConfiguration: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let instructions: String
    let preferredToolIDs: [String]
    let recommendedProviderID: String?
    let recommendedModelID: String?
}

struct AIChatAgentConfiguration: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let instructions: String
    let providerID: String?
    let modelID: String?
    let reasoningEffort: AIReasoningEffort?
    let skillIDs: [String]
    let toolIDs: [String]
    let contextDefaults: [String]
}

@MainActor
enum AIChatConfigurationCatalog {
    static let builtInSkills: [AIChatSkillConfiguration] = [
        AIChatSkillConfiguration(
            id: "skill.code-review",
            name: "Code Review",
            instructions: "Review for correctness, edge cases, regressions, and security concerns. Prioritize actionable findings and cite concrete evidence. Never modify files.",
            preferredToolIDs: ["search_files", "read_file"],
            recommendedProviderID: nil,
            recommendedModelID: nil
        ),
        AIChatSkillConfiguration(
            id: "skill.writing",
            name: "Writing",
            instructions: "Improve clarity and structure while preserving the author's intent and voice. Explain substantive changes concisely.",
            preferredToolIDs: [],
            recommendedProviderID: nil,
            recommendedModelID: nil
        ),
        AIChatSkillConfiguration(
            id: "skill.research",
            name: "Research",
            instructions: "Use available public read-only sources, distinguish evidence from uncertainty, and provide source URLs when available.",
            preferredToolIDs: ["search_web", "read_web"],
            recommendedProviderID: nil,
            recommendedModelID: nil
        )
    ]

    static let builtInAgents: [AIChatAgentConfiguration] = [
        AIChatAgentConfiguration(
            id: "agent.code-review",
            name: "Code Review",
            instructions: "Act as a careful code reviewer. Lead with important defects and avoid proposing unrequested edits.",
            providerID: nil,
            modelID: nil,
            reasoningEffort: .high,
            skillIDs: ["skill.code-review"],
            toolIDs: ["search_files", "read_file"],
            contextDefaults: []
        ),
        AIChatAgentConfiguration(
            id: "agent.writing",
            name: "Writing",
            instructions: "Help produce clear, direct writing while retaining the user's intent.",
            providerID: nil,
            modelID: nil,
            reasoningEffort: nil,
            skillIDs: ["skill.writing"],
            toolIDs: [],
            contextDefaults: []
        ),
        AIChatAgentConfiguration(
            id: "agent.research",
            name: "Research",
            instructions: "Answer with evidence from public, read-only sources and state uncertainty plainly.",
            providerID: nil,
            modelID: nil,
            reasoningEffort: .medium,
            skillIDs: ["skill.research"],
            toolIDs: ["search_web", "read_web"],
            contextDefaults: []
        )
    ]

    static var skills: [AIChatSkillConfiguration] {
        let contributed = ExtensionLoader().contributionCatalog().flatMap { entry in
            entry.skills.map { skill in
                AIChatSkillConfiguration(
                    id: scopedID(extensionID: entry.extensionID, contributionID: skill.id),
                    name: "\(entry.extensionName) · \(skill.name)",
                    instructions: String(skill.instructions.prefix(8_000)),
                    preferredToolIDs: skill.preferredToolIDs.map { toolReferenceID($0, extensionID: entry.extensionID) },
                    recommendedProviderID: skill.recommendedModelProviderID,
                    recommendedModelID: skill.recommendedModelID
                )
            }
        }
        return builtInSkills + contributed
    }

    static var agents: [AIChatAgentConfiguration] {
        let contributed = ExtensionLoader().contributionCatalog().flatMap { entry in
            entry.agents.map { agent in
                AIChatAgentConfiguration(
                    id: scopedID(extensionID: entry.extensionID, contributionID: agent.id),
                    name: "\(entry.extensionName) · \(agent.name)",
                    instructions: String(agent.instructions.prefix(8_000)),
                    providerID: agent.modelProviderID,
                    modelID: agent.modelID,
                    reasoningEffort: agent.reasoningEffort.flatMap(AIReasoningEffort.init(rawValue:)),
                    skillIDs: agent.skillIDs.map { scopedID(extensionID: entry.extensionID, contributionID: $0) },
                    toolIDs: agent.toolIDs.map { toolReferenceID($0, extensionID: entry.extensionID) },
                    contextDefaults: agent.contextDefaults ?? []
                )
            }
        }
        return builtInAgents + contributed
    }

    static func skill(id: String) -> AIChatSkillConfiguration? { skills.first { $0.id == id } }
    static func agent(id: String) -> AIChatAgentConfiguration? { agents.first { $0.id == id } }

    static func provider(for identifier: String?) -> AIProvider? {
        guard let identifier else { return nil }
        switch identifier.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "openai", "open-ai": return .openAI
        case "anthropic": return .anthropic
        case "gemini", "google-gemini": return .gemini
        case "openai-compatible", "custom-openai-compatible": return .openAICompatible
        default: return AIProvider(rawValue: identifier)
        }
    }

    private static func scopedID(extensionID: String, contributionID: String) -> String {
        "extension:\(extensionID):\(contributionID)"
    }

    private static func toolReferenceID(_ id: String, extensionID: String) -> String {
        if LimaAIToolRegistry.definition(for: id) != nil { return id }
        return scopedID(extensionID: extensionID, contributionID: id)
    }
}

@MainActor
enum ExtensionToolHostAdapterRegistry {
    private static let adapters: [String: any ExtensionToolHostAdapter] = {
        ExtensionToolHostAdapterID.allCases.reduce(into: [:]) { result, kind in
            result[kind.rawValue] = BuiltinReadOnlyExtensionToolAdapter(kind: kind)
        }
    }()

    static func adapter(for id: String?) -> (any ExtensionToolHostAdapter)? {
        guard let id, ExtensionToolHostAdapterID(rawValue: id) != nil else { return nil }
        return adapters[id]
    }

    static func approvedBindings() -> [ExtensionAIToolBinding] {
        ExtensionLoader().contributionCatalog().flatMap { entry in
            entry.tools.compactMap { tool in
                guard let schemaData = try? JSONEncoder().encode(tool.inputSchema),
                      schemaData.count <= 32_768,
                      tool.isEligibleForReadOnlyHostAdapter,
                      let adapter = adapter(for: tool.hostAdapterID),
                      tool.capabilities.isSubset(of: entry.capabilities),
                      adapter.requiredCapabilities.isSubset(of: tool.capabilities),
                      adapter.requiredCapabilities.isSubset(of: entry.capabilities) else { return nil }
                return ExtensionAIToolBinding(
                    extensionID: entry.extensionID,
                    extensionName: entry.extensionName,
                    extensionCapabilities: entry.capabilities,
                    tool: tool
                )
            }
        }
    }

    static func execute(_ binding: ExtensionAIToolBinding, arguments: JSONValue) async throws -> JSONValue {
        guard let current = approvedBindings().first(where: { $0 == binding }),
              let adapter = adapter(for: current.tool.hostAdapterID),
              current.tool.isReadOnly,
              current.tool.execution == .hostReadOnly,
              current.tool.capabilities.isSubset(of: current.extensionCapabilities),
              adapter.requiredCapabilities.isSubset(of: current.tool.capabilities),
              adapter.requiredCapabilities.isSubset(of: current.extensionCapabilities),
              ExtensionToolInputValidator.accepts(arguments, schema: current.tool.inputSchema) else {
            throw ExtensionToolAdapterError.unauthorized
        }
        return try await adapter.execute(definition: current.tool, arguments: arguments)
    }

    static func functionName(extensionID: String, toolID: String) -> String {
        func safe(_ value: String) -> String {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-")
            return value.lowercased().unicodeScalars
                .map { allowed.contains($0) ? String($0) : "_" }
                .joined()
        }
        let package = String(safe(extensionID).prefix(20))
        let tool = String(safe(toolID).prefix(20))
        let identity = extensionID + "\\0" + toolID
        let hash = identity.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
        let suffix = String(String(hash, radix: 16).suffix(8))
        return "ext__\(package.isEmpty ? "package" : package)__\(tool.isEmpty ? "tool" : tool)__\(suffix)"
    }
}

struct LimaAIToolDefinition: Identifiable, @unchecked Sendable {
    let id: String
    let name: String
    let description: String
    let parameters: [String: Any]
    let risk: AILocalToolRisk
    /// A user-controlled computer-action category. Nil preserves the existing
    /// read-only or analysis-only behavior for legacy definitions.
    var actionCategory: AIComputerActionCategory? = nil
    var extensionBinding: ExtensionAIToolBinding? = nil

    /// Only validated strict schemas are serialized into an AI provider request.
    /// This prevents one malformed built-in or extension schema from causing a
    /// request-wide HTTP 400.
    var responsePayload: [String: Any]? {
        guard case .success(let strictParameters) = AIToolSchemaValidator.strictParameters(from: parameters) else {
            return nil
        }
        return [
            "type": "function",
            "name": name,
            "description": description,
            "parameters": strictParameters,
            "strict": true
        ]
    }

    var schemaValidationMessage: String? {
        guard case .failure(let error) = AIToolSchemaValidator.strictParameters(from: parameters) else { return nil }
        return error.message
    }
}

struct AIToolSchemaValidationError: Error {
    let message: String
}

/// Validates the supported strict JSON-schema subset before a function is
/// serialized into a Responses request. Strict functions require an object root,
/// `additionalProperties: false`, and every object property in `required`;
/// fields that were optional are made nullable.
enum AIToolSchemaValidator {
    static let supportedKeywords: Set<String> = [
        "type", "properties", "required", "additionalProperties", "description",
        "enum", "items", "anyOf", "pattern", "minimum", "maximum",
        "exclusiveMinimum", "exclusiveMaximum", "multipleOf", "minItems",
        "maxItems", "format"
    ]

    static let supportedFormats: Set<String> = [
        "date-time", "time", "date", "duration", "email", "hostname",
        "ipv4", "ipv6", "uuid"
    ]

    private static let jsonTypes: Set<String> = [
        "string", "number", "integer", "boolean", "object", "array", "null"
    ]

    private static let objectKeywords: Set<String> = [
        "properties", "required", "additionalProperties"
    ]

    private static let arrayKeywords: Set<String> = [
        "items", "minItems", "maxItems"
    ]

    private static let numericKeywords: Set<String> = [
        "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf"
    ]

    static func strictParameters(from schema: [String: Any]) -> Result<[String: Any], AIToolSchemaValidationError> {
        switch normalize(schema, path: "parameters", nullable: false) {
        case .success(let normalized):
            switch declaredTypes(normalized["type"], path: "parameters") {
            case .success(let types) where types == ["object"]:
                return .success(normalized)
            case .success:
                return .failure(.init(message: "parameters must declare type object."))
            case .failure(let error):
                return .failure(error)
            }
        case .failure(let error):
            return .failure(error)
        }
    }

    private static func normalize(
        _ schema: [String: Any],
        path: String,
        nullable: Bool
    ) -> Result<[String: Any], AIToolSchemaValidationError> {
        switch validateSchemaKeywords(schema, path: path) {
        case .success: break
        case .failure(let error): return .failure(error)
        }

        let types: [String]?
        if schema["type"] != nil {
            switch declaredTypes(schema["type"], path: path) {
            case .success(let value): types = value
            case .failure(let error): return .failure(error)
            }
        } else {
            types = nil
        }

        let hasAnyOf = schema["anyOf"] != nil
        guard types != nil || hasAnyOf else {
            return .failure(.init(message: "\(path) must declare a JSON type or anyOf."))
        }
        if types == nil {
            let compositionOnly = Set(["description", "anyOf"])
            guard Set(schema.keys).isSubset(of: compositionOnly) else {
                return .failure(.init(message: "\(path) must declare a JSON type when using additional schema keywords."))
            }
        }

        if let types {
            switch validateKeywordContext(schema, types: types, path: path) {
            case .success: break
            case .failure(let error): return .failure(error)
            }
        }

        var normalized = schema
        if let types, types.contains("object") {
            switch normalizeObject(schema, path: path) {
            case .success(let object): normalized = object
            case .failure(let error): return .failure(error)
            }
        }

        if let types, types.contains("array") {
            guard let rawItems = schema["items"] as? [String: Any] else {
                return .failure(.init(message: "\(path).items must be an object schema."))
            }
            switch normalize(rawItems, path: "\(path).items", nullable: false) {
            case .success(let items): normalized["items"] = items
            case .failure(let error): return .failure(error)
            }
        }

        if let rawAnyOf = schema["anyOf"] {
            switch normalizeAnyOf(rawAnyOf, path: "\(path).anyOf") {
            case .success(let branches): normalized["anyOf"] = branches
            case .failure(let error): return .failure(error)
            }
        }

        if nullable {
            switch addingNull(to: normalized, path: path) {
            case .success(let nullableSchema): normalized = nullableSchema
            case .failure(let error): return .failure(error)
            }
        }
        return .success(normalized)
    }

    private static func normalizeObject(
        _ schema: [String: Any],
        path: String
    ) -> Result<[String: Any], AIToolSchemaValidationError> {
        switch validateSchemaKeywords(schema, path: path) {
        case .success: break
        case .failure(let error): return .failure(error)
        }
        let types: [String]
        switch declaredTypes(schema["type"], path: path) {
        case .success(let value): types = value
        case .failure(let error): return .failure(error)
        }
        guard types.contains("object") else {
            return .failure(.init(message: "\(path) must declare type object."))
        }
        switch validateKeywordContext(schema, types: types, path: path) {
        case .success: break
        case .failure(let error): return .failure(error)
        }

        guard let rawProperties = schema["properties"] as? [String: Any] else {
            return .failure(.init(message: "\(path) must declare properties."))
        }
        let requiredValues: [String]
        if let rawRequired = schema["required"] {
            guard let values = stringArray(rawRequired),
                  Set(values).count == values.count else {
                return .failure(.init(message: "\(path).required must be an array of unique property names."))
            }
            requiredValues = values
        } else {
            requiredValues = []
        }
        let required = Set(requiredValues)
        guard required.isSubset(of: Set(rawProperties.keys)) else {
            return .failure(.init(message: "\(path).required contains an undeclared property."))
        }

        var normalizedProperties: [String: Any] = [:]
        for name in rawProperties.keys.sorted() {
            guard let property = rawProperties[name] as? [String: Any] else {
                return .failure(.init(message: "\(path).properties.\(name) is not an object schema."))
            }
            switch normalize(property, path: "\(path).properties.\(name)", nullable: !required.contains(name)) {
            case .success(let normalized): normalizedProperties[name] = normalized
            case .failure(let error): return .failure(error)
            }
        }
        var normalized = schema
        normalized["properties"] = normalizedProperties
        normalized["required"] = rawProperties.keys.sorted()
        normalized["additionalProperties"] = false
        return .success(normalized)
    }

    private static func normalizeAnyOf(
        _ rawBranches: Any,
        path: String
    ) -> Result<[[String: Any]], AIToolSchemaValidationError> {
        guard let values = rawBranches as? [Any], !values.isEmpty else {
            return .failure(.init(message: "\(path) must contain at least one schema branch."))
        }
        var branches: [[String: Any]] = []
        for (index, rawBranch) in values.enumerated() {
            guard let branch = rawBranch as? [String: Any] else {
                return .failure(.init(message: "\(path)[\(index)] is not an object schema."))
            }
            switch normalize(branch, path: "\(path)[\(index)]", nullable: false) {
            case .success(let normalized): branches.append(normalized)
            case .failure(let error): return .failure(error)
            }
        }
        return .success(branches)
    }

    private static func validateSchemaKeywords(
        _ schema: [String: Any],
        path: String
    ) -> Result<Void, AIToolSchemaValidationError> {
        let unsupported = Set(schema.keys).subtracting(supportedKeywords).sorted()
        guard unsupported.isEmpty else {
            return .failure(.init(message: "Unsupported strict schema keyword: \(unsupported[0]) at \(path)."))
        }
        if let description = schema["description"], !(description is String) {
            return .failure(.init(message: "\(path).description must be a string."))
        }
        return .success(())
    }

    private static func validateKeywordContext(
        _ schema: [String: Any],
        types: [String],
        path: String
    ) -> Result<Void, AIToolSchemaValidationError> {
        if let format = schema["format"] {
            guard types.contains("string"), let format = format as? String,
                  supportedFormats.contains(format) else {
                let rendered = format as? String ?? "invalid"
                return .failure(.init(message: "Unsupported strict schema format: \(rendered) at \(path)."))
            }
        }

        if schema["pattern"] != nil {
            guard types.contains("string"), schema["pattern"] is String else {
                return .failure(.init(message: "\(path).pattern is supported only for string schemas."))
            }
        }

        if schema["enum"] != nil {
            guard let values = schema["enum"] as? [Any], !values.isEmpty,
                  values.allSatisfy({ enumValue($0, matches: types) }) else {
                return .failure(.init(message: "\(path).enum must contain values compatible with its declared type."))
            }
        }

        if types.contains("object") {
            guard schema["properties"] is [String: Any] else {
                return .failure(.init(message: "\(path) must declare properties."))
            }
            guard schema["additionalProperties"] as? Bool == false else {
                return .failure(.init(message: "\(path) must set additionalProperties to false."))
            }
            if let required = schema["required"], stringArray(required) == nil {
                return .failure(.init(message: "\(path).required must be an array of property names."))
            }
        } else if objectKeywords.contains(where: { schema[$0] != nil }) {
            return .failure(.init(message: "\(path) uses object keywords without type object."))
        }

        if types.contains("array") {
            guard schema["items"] is [String: Any] else {
                return .failure(.init(message: "\(path).items must be an object schema."))
            }
            switch validateArrayBounds(schema, path: path) {
            case .success: break
            case .failure(let error): return .failure(error)
            }
        } else if arrayKeywords.contains(where: { schema[$0] != nil }) {
            return .failure(.init(message: "\(path) uses array keywords without type array."))
        }

        if numericKeywords.contains(where: { schema[$0] != nil }) {
            guard types.contains("number") || types.contains("integer") else {
                return .failure(.init(message: "\(path) uses numeric keywords without type number or integer."))
            }
            switch validateNumericBounds(schema, path: path) {
            case .success: break
            case .failure(let error): return .failure(error)
            }
        }
        return .success(())
    }

    private static func validateArrayBounds(
        _ schema: [String: Any],
        path: String
    ) -> Result<Void, AIToolSchemaValidationError> {
        let minimum = schema["minItems"].flatMap(nonnegativeInteger)
        let maximum = schema["maxItems"].flatMap(nonnegativeInteger)
        if schema["minItems"] != nil && minimum == nil {
            return .failure(.init(message: "\(path).minItems must be a non-negative integer."))
        }
        if schema["maxItems"] != nil && maximum == nil {
            return .failure(.init(message: "\(path).maxItems must be a non-negative integer."))
        }
        if let minimum, let maximum, minimum > maximum {
            return .failure(.init(message: "\(path).minItems cannot exceed maxItems."))
        }
        return .success(())
    }

    private static func validateNumericBounds(
        _ schema: [String: Any],
        path: String
    ) -> Result<Void, AIToolSchemaValidationError> {
        for keyword in numericKeywords {
            guard schema[keyword] == nil || finiteNumber(schema[keyword]) != nil else {
                return .failure(.init(message: "\(path).\(keyword) must be a finite number."))
            }
        }
        if let minimum = finiteNumber(schema["minimum"]),
           let maximum = finiteNumber(schema["maximum"]),
           minimum > maximum {
            return .failure(.init(message: "\(path).minimum cannot exceed maximum."))
        }
        if let minimum = finiteNumber(schema["exclusiveMinimum"]),
           let maximum = finiteNumber(schema["exclusiveMaximum"]),
           minimum >= maximum {
            return .failure(.init(message: "\(path).exclusiveMinimum must be less than exclusiveMaximum."))
        }
        if let multiple = finiteNumber(schema["multipleOf"]), multiple <= 0 {
            return .failure(.init(message: "\(path).multipleOf must be greater than zero."))
        }
        return .success(())
    }

    private static func addingNull(
        to schema: [String: Any],
        path: String
    ) -> Result<[String: Any], AIToolSchemaValidationError> {
        var normalized = schema
        if let rawType = normalized["type"] {
            let types: [String]
            switch declaredTypes(rawType, path: path) {
            case .success(let value): types = value
            case .failure(let error): return .failure(error)
            }
            if !types.contains("null") {
                normalized["type"] = types + ["null"]
            }
            if var values = normalized["enum"] as? [Any],
               !values.contains(where: { $0 is NSNull }) {
                values.append(NSNull())
                normalized["enum"] = values
            }
            return .success(normalized)
        }

        guard let rawBranches = normalized["anyOf"] as? [Any] else {
            return .failure(.init(message: "\(path) must declare a JSON type or anyOf."))
        }
        var branches = rawBranches.compactMap { $0 as? [String: Any] }
        guard branches.count == rawBranches.count else {
            return .failure(.init(message: "\(path).anyOf contains an invalid schema branch."))
        }
        if !branches.contains(where: schemaAllowsNull) {
            branches.append(["type": "null"])
        }
        normalized["anyOf"] = branches
        return .success(normalized)
    }

    private static func schemaAllowsNull(_ schema: [String: Any]) -> Bool {
        if case .success(let types) = declaredTypes(schema["type"], path: "schema"),
           types.contains("null") {
            return true
        }
        guard let branches = schema["anyOf"] as? [Any] else { return false }
        return branches.compactMap { $0 as? [String: Any] }.contains(where: schemaAllowsNull)
    }

    private static func declaredTypes(
        _ raw: Any?,
        path: String
    ) -> Result<[String], AIToolSchemaValidationError> {
        let types: [String]
        if let type = raw as? String {
            types = [type]
        } else if let values = stringArray(raw) {
            types = values
        } else {
            return .failure(.init(message: "\(path) has an invalid type declaration."))
        }
        guard !types.isEmpty,
              Set(types).count == types.count,
              types.allSatisfy(jsonTypes.contains) else {
            return .failure(.init(message: "\(path) has an unsupported JSON type declaration."))
        }
        return .success(types)
    }

    private static func stringArray(_ raw: Any?) -> [String]? {
        guard let values = raw as? [Any] else { return nil }
        let strings = values.compactMap { $0 as? String }
        return strings.count == values.count ? strings : nil
    }

    private static func enumValue(_ value: Any, matches types: [String]) -> Bool {
        if value is NSNull { return types.contains("null") }
        if value is Bool { return types.contains("boolean") }
        if value is String { return types.contains("string") }
        guard let number = finiteNumber(value) else { return false }
        if types.contains("number") { return true }
        return types.contains("integer") && number.rounded() == number
    }

    private static func nonnegativeInteger(_ raw: Any?) -> Int? {
        guard let value = finiteNumber(raw),
              value >= 0,
              value.rounded() == value,
              value <= Double(Int.max) else {
            return nil
        }
        return Int(value)
    }

    private static func finiteNumber(_ raw: Any?) -> Double? {
        guard let raw, !(raw is Bool) else { return nil }
        let value: Double?
        switch raw {
        case let number as Int: value = Double(number)
        case let number as Int64: value = Double(number)
        case let number as Double: value = number
        case let number as Float: value = Double(number)
        case let number as NSNumber: value = number.doubleValue
        default: value = nil
        }
        guard let value, value.isFinite else { return nil }
        return value
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
    You are Lima’s private assistant. Use only tools supplied in this request and only for their declared purpose. Never use an action tool unless the user explicitly asked for that action, and never attempt to bypass a missing tool, site grant, path rule, confirmation, or approval. Remote MCP and extension tools are read-only. Enabled subagents may analyze supplied evidence but cannot act or use tools. Do not attempt tools outside the supplied list. You may draft extension code or manifests in chat for review, but never install or run them.
    """

    static func readableMCPTools(for server: MCPServer) -> [MCPToolDescriptor] {
        server.enabledTools.filter { $0.risk == .read && $0.declaredReadOnly == true }
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
    private static let maximumWebPageBytes = 1 * 1_024 * 1_024

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
            description: "Search file names in the user’s existing Spotlight index. Returns up to 20 safe paths and never reads file contents.",
            parameters: [
                "type": "object",
                "properties": ["query": ["type": "string", "description": "A concise file-name query."]],
                "required": ["query"],
                "additionalProperties": false
            ],
            risk: .read
        ),
        LimaAIToolDefinition(
            id: "find_files",
            name: "find_files",
            description: "Find matching file names in the Spotlight index, optionally limited to a directory. Returns paths only.",
            parameters: [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "A concise file-name query."],
                    "directory": ["type": ["string", "null"], "description": "Optional absolute directory to limit results."]
                ],
                "required": ["query", "directory"],
                "additionalProperties": false
            ],
            risk: .read
        ),
        LimaAIToolDefinition(
            id: "list_directory",
            name: "list_directory",
            description: "List up to 100 visible direct children of a directory. Hidden and sensitive paths and symbolic links are omitted; file contents are never read.",
            parameters: [
                "type": "object",
                "properties": ["path": ["type": "string", "description": "An absolute directory path."]],
                "required": ["path"],
                "additionalProperties": false
            ],
            risk: .read
        ),
        LimaAIToolDefinition(
            id: "file_metadata",
            name: "file_metadata",
            description: "Read basic metadata for a file or directory without reading its contents. Sensitive locations are blocked.",
            parameters: [
                "type": "object",
                "properties": ["path": ["type": "string", "description": "An absolute file or directory path."]],
                "required": ["path"],
                "additionalProperties": false
            ],
            risk: .read
        ),
        LimaAIToolDefinition(
            id: "read_file",
            name: "read_file",
            description: "Read a bounded line range from a text or source-code file with line numbers. Sensitive locations, non-text files, and files larger than 96 KB are blocked. This tool never changes a file.",
            parameters: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "An absolute path returned by a file search or supplied by the user."],
                    "start_line": ["type": ["integer", "null"], "minimum": 1, "description": "One-based first line to read; defaults to 1."],
                    "length": ["type": ["integer", "null"], "minimum": 1, "maximum": 400, "description": "Maximum number of lines to return; defaults to 200."]
                ],
                "required": ["path", "start_line", "length"],
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
            id: "read_web",
            name: "read_web",
            description: "Read extracted headings, main text, metadata, and public links from a public web page. Links are references only; use a separate read_web call to read a selected link. It blocks local and private hosts, sends no cookies or credentials, does not follow redirects, and never submits or changes web content.",
            parameters: [
                "type": "object",
                "properties": ["url": ["type": "string", "description": "A public HTTP or HTTPS URL returned by Search Web or supplied by the user."]],
                "required": ["url"],
                "additionalProperties": false
            ],
            risk: .read
        ),
        LimaAIToolDefinition(
            id: "list_extensions",
            name: "list_extensions",
            description: "List installed Lima extension commands, declared read-only tools, skills, agents, and capabilities. It only reads manifests; it never runs, installs, modifies, or approves extensions.",
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

    private static var candidateDefinitions: [LimaAIToolDefinition] {
        definitions
            + AIContextTools.definitions
            + AINotesTools.definitions
            + BrowserBridgeAITools.definitions
            + AILocalComputerActionTools.definitions
            + ExtensionToolHostAdapterRegistry.approvedBindings().map(extensionDefinition)
    }

    static var availableDefinitions: [LimaAIToolDefinition] {
        candidateDefinitions
            .filter { $0.responsePayload != nil }
            .filter { $0.actionCategory == nil || AIComputerActionPolicy.shared.allows($0) }
    }

    static func schemaValidationMessage(for id: String) -> String? {
        candidateDefinitions.first(where: { $0.id == id })?.schemaValidationMessage
    }

    static var defaultEnabledToolIDs: Set<String> {
        Set(definitions.map(\.id))
            .union(AIContextTools.ids)
            .union(AINotesTools.ids)
            .union(BrowserBridgeAITools.readToolIDs)
    }

    static func definition(for name: String?) -> LimaAIToolDefinition? {
        guard let name else { return nil }
        return candidateDefinitions.first { $0.name == name || $0.id == name }
    }

    static func enabledDefinitions(_ ids: Set<String>) -> [LimaAIToolDefinition] {
        availableDefinitions.filter { definition in
            guard ids.contains(definition.id) else { return false }
            if definition.actionCategory != nil {
                return AIComputerActionPolicy.shared.allows(definition)
            }
            return definition.risk == .read || AIContextTools.delegationIDs.contains(definition.id)
        }
    }

    static func requiresApproval(for name: String?) -> Bool {
        guard let definition = definition(for: name) else { return false }
        return AIComputerActionPolicy.shared.requiresApproval(for: definition)
    }

    private static func extensionDefinition(_ binding: ExtensionAIToolBinding) -> LimaAIToolDefinition {
        let schemaData = try? JSONEncoder().encode(binding.tool.inputSchema)
        let schema = schemaData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            ?? ["type": "object", "properties": [:] as [String: Any], "additionalProperties": false]
        return LimaAIToolDefinition(
            id: "extension:\(binding.extensionID):\(binding.tool.id)",
            name: ExtensionToolHostAdapterRegistry.functionName(extensionID: binding.extensionID, toolID: binding.tool.id),
            description: String(binding.tool.description.prefix(2_000)),
            parameters: schema,
            risk: .read,
            extensionBinding: binding
        )
    }

    static func execute(_ call: AIOutputItem, approvalGranted: Bool = false) async -> LimaAIToolExecution {
        guard AIRequestPolicy.shared.isEnabled, !Task.isCancelled else {
            return .json(["error": AIRequestPolicy.disabledMessage], isError: true)
        }
        guard let definition = definition(for: call.name),
              definition.risk == .read || definition.actionCategory != nil else {
            return .json(["error": "Lima AI Chat only permits registered tools enabled by the current action policy."], isError: true)
        }
        guard definition.actionCategory == nil
                || AIComputerActionPolicy.shared.permits(definition, approvalGranted: approvalGranted) else {
            return .json(["error": "This computer action is disabled or still needs your approval in Lima Settings."], isError: true)
        }
        if let binding = definition.extensionBinding {
            guard let arguments = call.arguments,
                  arguments.utf8.count <= 64_000,
                  let data = arguments.data(using: .utf8),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                return .json(["error": "The extension tool arguments were invalid."], isError: true)
            }
            do {
                let output = try await ExtensionToolHostAdapterRegistry.execute(binding, arguments: value)
                let isError: Bool
                if case .object(let fields) = output { isError = fields["error"] != nil }
                else { isError = false }
                return .json(foundationValue(output), isError: isError)
            } catch {
                return .json(["error": "The approved read-only extension tool could not be executed."], isError: true)
            }
        }
        if AINotesTools.ids.contains(definition.id) {
            return await AINotesTools.execute(call)
        }
        if BrowserBridgeAITools.definitions.contains(where: { $0.id == definition.id }) {
            return await BrowserBridgeAITools.execute(call, approvalGranted: approvalGranted)
        }
        if AILocalComputerActionTools.ids.contains(definition.id) {
            return await AILocalComputerActionTools.execute(call, approvalGranted: approvalGranted)
        }
        switch definition.id {
        case "read_screen_context":
            return .json(LimaScreenContextStore.shared.read())
        case "search_files", "find_files":
            guard let query = stringArgument(named: "query", from: call.arguments), !query.isEmpty else {
                return .json(["error": "File search needs a non-empty query."], isError: true)
            }
            var directoryPath: String?
            if let directory = stringArgument(named: "directory", from: call.arguments) {
                guard directory.hasPrefix("/") else {
                    return .json(["error": "The optional search directory must be an absolute path."], isError: true)
                }
                let root = URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath()
                guard !isSensitivePath(root),
                      (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                    return .json(["error": "The search directory is unavailable or sensitive."], isError: true)
                }
                directoryPath = root.path
            }
            let urls = await searchFiles(named: String(query.prefix(160)))
            let matches = urls.compactMap { candidate -> [String: String]? in
                let url = candidate.standardizedFileURL.resolvingSymlinksInPath()
                guard !isSensitivePath(url),
                      directoryPath.map({ url.path.hasPrefix($0 == "/" ? "/" : $0 + "/") }) ?? true else { return nil }
                return ["name": url.lastPathComponent, "path": url.path]
            }
            return .json([
                "matches": matches.prefix(20),
                "truncated": matches.count > 20
            ])
        case "list_directory":
            guard let path = stringArgument(named: "path", from: call.arguments), !path.isEmpty else {
                return .json(["error": "List Directory needs an absolute path."], isError: true)
            }
            return listDirectory(at: path)
        case "file_metadata":
            guard let path = stringArgument(named: "path", from: call.arguments), !path.isEmpty else {
                return .json(["error": "File Metadata needs an absolute path."], isError: true)
            }
            return fileMetadata(at: path)
        case "read_file":
            guard let path = stringArgument(named: "path", from: call.arguments), !path.isEmpty else {
                return .json(["error": "Read File needs an absolute path."], isError: true)
            }
            let requestedStartLine = integerArgument(named: "start_line", from: call.arguments)
            let requestedLength = integerArgument(named: "length", from: call.arguments)
            guard (!hasArgument(named: "start_line", from: call.arguments) || requestedStartLine != nil),
                  (!hasArgument(named: "length", from: call.arguments) || requestedLength != nil) else {
                return .json(["error": "Read File needs integer start_line and length values."], isError: true)
            }
            let startLine = requestedStartLine ?? 1
            let length = requestedLength ?? 200
            guard startLine > 0, (1...400).contains(length) else {
                return .json(["error": "Read File accepts a positive start_line and a length from 1 to 400."], isError: true)
            }
            return readTextFile(at: path, startLine: startLine, length: length)
        case "search_web":
            guard let query = stringArgument(named: "query", from: call.arguments), !query.isEmpty else {
                return .json(["error": "Search Web needs a non-empty query."], isError: true)
            }
            return await searchWeb(query: String(query.prefix(200)))
        case "read_web":
            guard let rawURL = stringArgument(named: "url", from: call.arguments), !rawURL.isEmpty else {
                return .json(["error": "Read Web needs a public URL."], isError: true)
            }
            return await readPublicWebPage(rawURL)
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

    static func jsonValue(from execution: LimaAIToolExecution) -> JSONValue {
        guard let data = execution.output.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .object(["error": .string("Lima could not decode the bounded tool result.")])
        }
        return value
    }

    private static func foundationValue(_ value: JSONValue) -> Any {
        switch value {
        case .string(let value): value
        case .number(let value): value
        case .bool(let value): value
        case .object(let values): values.mapValues(foundationValue)
        case .array(let values): values.map(foundationValue)
        case .null: NSNull()
        }
    }

    static func stringArgument(named key: String, from arguments: String?) -> String? {
        guard let arguments,
              let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func integerArgument(named key: String, from arguments: String?) -> Int? {
        guard let arguments,
              let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = object[key] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite,
              value.rounded(.towardZero) == value,
              value >= Double(Int.min),
              value < Double(Int.max) else { return nil }
        return number.intValue
    }

    static func hasArgument(named key: String, from arguments: String?) -> Bool {
        guard let arguments,
              let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object.keys.contains(key)
    }

    static func searchFiles(named query: String) async -> [URL] {
        await withCheckedContinuation { continuation in
            fileSearch.search(query) { urls in
                continuation.resume(returning: urls)
            }
        }
    }

    static func readTextFile(at path: String, startLine: Int = 1, length: Int = 200) -> LimaAIToolExecution {
        guard path.hasPrefix("/"), startLine > 0, (1...400).contains(length) else {
            return .json(["error": "Read File needs an absolute path, a positive start line, and a length from 1 to 400."], isError: true)
        }
        let requestedURL = URL(fileURLWithPath: path).standardizedFileURL
        guard (try? requestedURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            return .json(["error": "Read File does not follow symbolic links."], isError: true)
        }
        let url = requestedURL.resolvingSymlinksInPath()
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
            guard let text = String(data: data, encoding: .utf8),
                  !data.contains(0),
                  !text.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0) && ![9, 10, 13].contains(Int($0.value))
                  }) else {
                return .json(["error": "Lima could not decode that file as safe UTF-8 text."], isError: true)
            }
            let normalizedText = text.replacingOccurrences(of: "\r\n", with: "\n")
            var lines = normalizedText.components(separatedBy: "\n")
            if normalizedText.hasSuffix("\n") { lines.removeLast() }
            let firstIndex = min(startLine - 1, lines.count)
            var output: [String] = []
            var outputCharacters = 0
            var lineWasClipped = false
            for index in firstIndex..<min(lines.count, firstIndex + length) {
                let line = lines[index]
                let remaining = max(0, 32_000 - outputCharacters)
                guard remaining > 0 else { break }
                let numberedLine = "\(index + 1)\t\(line)"
                if numberedLine.count <= remaining {
                    output.append(numberedLine)
                    outputCharacters += numberedLine.count + 1
                } else {
                    output.append(String(numberedLine.prefix(remaining)))
                    lineWasClipped = true
                    break
                }
            }
            let candidateNextStartLine = firstIndex + output.count + 1
            let nextStartLine: Int? = !lineWasClipped && candidateNextStartLine <= lines.count
                ? candidateNextStartLine
                : nil
            return .json([
                "path": url.path,
                "start_line": startLine,
                "length": length,
                "content": output.joined(separator: "\n"),
                "next_start_line": nextStartLine.map { $0 as Any } ?? NSNull(),
                "line_truncated": lineWasClipped,
                "truncated": nextStartLine != nil || lineWasClipped
            ])
        } catch {
            return .json(["error": "Lima could not read that file."], isError: true)
        }
    }

    static func listDirectory(at path: String) -> LimaAIToolExecution {
        guard path.hasPrefix("/") else {
            return .json(["error": "List Directory only accepts absolute paths."], isError: true)
        }
        let requestedURL = URL(fileURLWithPath: path).standardizedFileURL
        guard (try? requestedURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            return .json(["error": "List Directory does not follow symbolic links."], isError: true)
        }
        let url = requestedURL.resolvingSymlinksInPath()
        guard !isSensitivePath(url) else {
            return .json(["error": "Lima does not list credential, system, or hidden secret locations."], isError: true)
        }
        do {
            guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
                  let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                  ) else {
                return .json(["error": "List Directory needs an accessible directory path."], isError: true)
            }
            var entries: [[String: Any]] = []
            while let child = enumerator.nextObject() as? URL {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                if values?.isDirectory == true || values?.isSymbolicLink == true {
                    enumerator.skipDescendants()
                }
                guard values?.isSymbolicLink != true else { continue }
                let resolved = child.standardizedFileURL.resolvingSymlinksInPath()
                guard !isSensitivePath(resolved) else { continue }
                let kind = values?.isDirectory == true ? "directory" : (values?.isRegularFile == true ? "file" : "other")
                entries.append([
                    "name": child.lastPathComponent,
                    "path": child.path,
                    "kind": kind,
                    "size_bytes": values?.fileSize.map { $0 as Any } ?? NSNull()
                ])
                if entries.count > 100 { break }
            }
            entries.sort {
                ($0["name"] as? String ?? "").localizedStandardCompare($1["name"] as? String ?? "") == .orderedAscending
            }
            let boundedEntries = Array(entries.prefix(100))
            return .json([
                "path": url.path,
                "entries": boundedEntries,
                "truncated": entries.count > boundedEntries.count
            ])
        } catch {
            return .json(["error": "Lima could not list that directory."], isError: true)
        }
    }

    static func fileMetadata(at path: String) -> LimaAIToolExecution {
        guard path.hasPrefix("/") else {
            return .json(["error": "File Metadata only accepts absolute paths."], isError: true)
        }
        let requestedURL = URL(fileURLWithPath: path).standardizedFileURL
        guard (try? requestedURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            return .json(["error": "File Metadata does not follow symbolic links."], isError: true)
        }
        let url = requestedURL.resolvingSymlinksInPath()
        guard !isSensitivePath(url) else {
            return .json(["error": "Lima does not expose metadata from credential, system, or hidden secret locations."], isError: true)
        }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentTypeKey, .contentModificationDateKey])
            guard values.isRegularFile == true || values.isDirectory == true else {
                return .json(["error": "File Metadata supports regular files and directories only."], isError: true)
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return .json([
                "path": url.path,
                "name": url.lastPathComponent,
                "kind": values.isDirectory == true ? "directory" : "file",
                "size_bytes": values.fileSize ?? 0,
                "modified_at": values.contentModificationDate.map { formatter.string(from: $0) as Any } ?? NSNull(),
                "content_type": values.contentType.map { $0.identifier as Any } ?? NSNull()
            ])
        } catch {
            return .json(["error": "Lima could not read that item’s metadata."], isError: true)
        }
    }

    nonisolated static func isSensitivePath(_ url: URL) -> Bool {
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

    nonisolated static func isTextFile(url: URL, contentType: UTType?) -> Bool {
        if contentType?.conforms(to: .text) == true || contentType?.conforms(to: .sourceCode) == true { return true }
        let extensions: Set<String> = ["csv", "env.example", "json", "log", "md", "plist", "py", "rb", "sh", "sql", "swift", "toml", "ts", "tsx", "txt", "xml", "yaml", "yml", "zsh"]
        return extensions.contains(url.pathExtension.lowercased())
    }

    static func searchWeb(query: String) async -> LimaAIToolExecution {
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

    private final class NoRedirectWebReaderDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    static func readPublicWebPage(_ rawURL: String) async -> LimaAIToolExecution {
        guard let url = publicWebURL(rawURL) else {
            return .json(["error": "Read Web only accepts a public HTTP or HTTPS URL without credentials."], isError: true)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: NoRedirectWebReaderDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Lima/1.0 (read-only web reader)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html, text/plain, application/xhtml+xml, application/json;q=0.8", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return .json(["error": "The public web page could not be read."], isError: true)
            }
            guard publicWebURL(http.url?.absoluteString ?? "") != nil else {
                return .json(["error": "The page resolved to a non-public URL."], isError: true)
            }
            guard http.expectedContentLength < 0 || http.expectedContentLength <= Int64(maximumWebPageBytes),
                  data.count <= maximumWebPageBytes else {
                return .json(["error": "The page is larger than Lima’s 1 MB read-only limit."], isError: true)
            }
            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            guard contentType.isEmpty
                    || contentType.contains("text/html")
                    || contentType.contains("text/plain")
                    || contentType.contains("application/xhtml+xml")
                    || contentType.contains("application/json") else {
                return .json(["error": "Read Web supports public HTML, plain-text, and JSON pages only."], isError: true)
            }

            let rawText = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            let result: (
                title: String?,
                content: String,
                links: [String],
                headings: [String],
                metadata: [String: String],
                linkDetails: [[String: String]]
            )
            if contentType.contains("html") || rawText.range(of: "<html", options: .caseInsensitive) != nil {
                result = readableWebContent(fromHTML: rawText, baseURL: url)
            } else {
                result = (nil, normalizedWebText(rawText), [], [], [:], [])
            }
            guard !result.content.isEmpty else {
                return .json(["error": "The page did not contain readable public text."], isError: true)
            }
            let limitedContent = String(result.content.prefix(32_000))
            return .json([
                "url": url.absoluteString,
                "title": result.title ?? "",
                "headings": Array(result.headings.prefix(24)),
                "metadata": result.metadata,
                "content": limitedContent,
                "links": Array(result.links.prefix(20)),
                "link_details": Array(result.linkDetails.prefix(20)),
                "truncated": result.content.count > limitedContent.count,
                "source": "Public page read without cookies, credentials, redirects, or form submission"
            ])
        } catch {
            return .json(["error": "The public web page could not be reached."], isError: true)
        }
    }

    static func publicWebURL(_ rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 2_048,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.user == nil, components.password == nil,
              let host = components.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              !host.isEmpty,
              host != "localhost",
              !host.hasSuffix(".localhost"),
              !host.hasSuffix(".local"),
              !host.hasSuffix(".internal"),
              !isPrivateIPAddress(host),
              let url = components.url else { return nil }
        return url
    }

    private static func isPrivateIPAddress(_ host: String) -> Bool {
        // Reject literal IPv6 addresses rather than risk exposing local network
        // services. Public DNS names remain supported.
        if host.contains(":") { return true }
        let parts = host.split(separator: ".")
        let octets = parts.compactMap { Int($0) }
        guard parts.count == 4, octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }
        switch octets[0] {
        case 0, 10, 127:
            return true
        case 169:
            return octets[1] == 254
        case 172:
            return (16...31).contains(octets[1])
        case 192:
            return octets[1] == 168
        default:
            return false
        }
    }

    static func readableWebContent(
        fromHTML html: String,
        baseURL: URL
    ) -> (
        title: String?,
        content: String,
        links: [String],
        headings: [String],
        metadata: [String: String],
        linkDetails: [[String: String]]
    ) {
        let document = parseWebHTML(html)
        let contentRoot = firstWebElement(named: "main", in: document)
            ?? firstWebElement(named: "article", in: document)
            ?? firstWebElement(named: "body", in: document)
            ?? document

        var metadata: [String: String] = [:]
        visitWebElements(in: document) { element in
            guard element.name == "meta",
                  let content = element.attributes["content"] else { return }
            let key = (element.attributes["name"] ?? element.attributes["property"] ?? "").lowercased()
            switch key {
            case "description", "author", "og:title", "og:description":
                let value = String(normalizedWebText(content).prefix(500))
                if !value.isEmpty { metadata[key] = value }
            default:
                break
            }
        }
        if let htmlElement = firstWebElement(named: "html", in: document),
           let language = htmlElement.attributes["lang"] {
            metadata["language"] = String(decodeWebHTMLEntities(language).prefix(40))
        }
        visitWebElements(in: document) { element in
            guard element.name == "link",
                  decodeWebHTMLEntities(element.attributes["rel"] ?? "")
                    .lowercased().split(whereSeparator: \.isWhitespace).contains("canonical"),
                  let rawHref = element.attributes["href"],
                  let canonicalURL = URL(string: decodeWebHTMLEntities(rawHref), relativeTo: baseURL)?.absoluteURL,
                  publicWebURL(canonicalURL.absoluteString) != nil else { return }
            metadata["canonical_url"] = canonicalURL.absoluteString
        }

        let documentTitle = firstWebElement(named: "title", in: document).map {
            normalizedWebText(rawWebText(in: $0))
        }
        let title = documentTitle.flatMap { $0.isEmpty ? nil : $0 } ?? metadata["og:title"]

        var contentBuffer = ""
        appendReadableWebText(from: contentRoot, to: &contentBuffer)
        let content = normalizedWebText(contentBuffer)

        var headings: [String] = []
        collectReadableHeadings(in: contentRoot, into: &headings)
        var linkDetails: [[String: String]] = []
        var seenLinks = Set<String>()
        collectReadableLinks(in: contentRoot, baseURL: baseURL, into: &linkDetails, seen: &seenLinks)

        return (
            title,
            content,
            linkDetails.compactMap { $0["url"] },
            headings,
            metadata,
            linkDetails
        )
    }

    private final class WebHTMLNode {
        let name: String?
        let attributes: [String: String]
        let text: String?
        var children: [WebHTMLNode] = []

        init(name: String? = nil, attributes: [String: String] = [:], text: String? = nil) {
            self.name = name
            self.attributes = attributes
            self.text = text
        }
    }

    private static let voidWebHTMLTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link",
        "meta", "param", "source", "track", "wbr"
    ]

    private static let ignoredWebContentTags: Set<String> = [
        "aside", "canvas", "footer", "form", "head", "header", "iframe", "link",
        "meta", "nav", "noscript", "object", "script", "style", "svg", "template",
        "title"
    ]

    private static let blockWebContentTags: Set<String> = [
        "address", "article", "blockquote", "br", "dd", "div", "dl", "dt",
        "figcaption", "figure", "h1", "h2", "h3", "h4", "h5", "h6", "hr",
        "li", "ol", "p", "pre", "section", "table", "tbody", "td", "th",
        "thead", "tr", "ul"
    ]

    private static func parseWebHTML(_ html: String) -> WebHTMLNode {
        let document = WebHTMLNode()
        var stack = [document]
        var overflowTags: [String] = []
        var cursor = html.startIndex
        let maximumTreeDepth = 256

        while cursor < html.endIndex {
            guard html[cursor] == "<" else {
                let textEnd = html[cursor...].firstIndex(of: "<") ?? html.endIndex
                if overflowTags.isEmpty, textEnd > cursor {
                    stack[stack.count - 1].children.append(
                        WebHTMLNode(text: String(html[cursor..<textEnd]))
                    )
                }
                cursor = textEnd
                continue
            }

            if html[cursor...].hasPrefix("<!--") {
                if let commentEnd = html.range(of: "-->", range: cursor..<html.endIndex) {
                    cursor = commentEnd.upperBound
                } else {
                    break
                }
                continue
            }

            let afterOpen = html.index(after: cursor)
            guard afterOpen < html.endIndex else {
                if overflowTags.isEmpty {
                    stack[stack.count - 1].children.append(WebHTMLNode(text: "<"))
                }
                break
            }
            var tagStart = afterOpen
            if html[tagStart] == "/" {
                tagStart = html.index(after: tagStart)
            }
            guard tagStart < html.endIndex,
                  html[tagStart].isLetter || html[tagStart] == "!" || html[tagStart] == "?" else {
                if overflowTags.isEmpty {
                    stack[stack.count - 1].children.append(WebHTMLNode(text: "<"))
                }
                cursor = afterOpen
                continue
            }

            guard let tokenEnd = webHTMLTagEnd(in: html, startingAt: cursor) else {
                if overflowTags.isEmpty {
                    stack[stack.count - 1].children.append(WebHTMLNode(text: "<"))
                }
                cursor = afterOpen
                continue
            }
            let bodyStart = html.index(after: cursor)
            let bodyEnd = html.index(before: tokenEnd)
            let tokenBody = String(html[bodyStart..<bodyEnd])
            cursor = tokenEnd

            guard let tag = parseWebHTMLTag(tokenBody) else { continue }
            if tag.name.hasPrefix("!") || tag.name.hasPrefix("?") { continue }

            if !overflowTags.isEmpty {
                if tag.isClosing {
                    if let matching = overflowTags.lastIndex(of: tag.name) {
                        overflowTags.removeSubrange(matching..<overflowTags.count)
                    }
                } else if !tag.isSelfClosing && !voidWebHTMLTags.contains(tag.name) {
                    overflowTags.append(tag.name)
                }
                continue
            }

            if tag.isClosing {
                if let matching = stack.lastIndex(where: { $0.name == tag.name }), matching > 0 {
                    stack.removeSubrange(matching..<stack.count)
                }
                continue
            }

            let element = WebHTMLNode(name: tag.name, attributes: tag.attributes)
            stack[stack.count - 1].children.append(element)
            guard !tag.isSelfClosing, !voidWebHTMLTags.contains(tag.name) else { continue }
            if stack.count >= maximumTreeDepth {
                overflowTags = [tag.name]
            } else {
                stack.append(element)
            }
        }
        return document
    }

    private static func webHTMLTagEnd(in html: String, startingAt start: String.Index) -> String.Index? {
        var cursor = html.index(after: start)
        var quote: Character?
        while cursor < html.endIndex {
            let character = html[cursor]
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return html.index(after: cursor)
            }
            cursor = html.index(after: cursor)
        }
        return nil
    }

    private static func parseWebHTMLTag(
        _ source: String
    ) -> (name: String, attributes: [String: String], isClosing: Bool, isSelfClosing: Bool)? {
        let characters = Array(source)
        var offset = 0

        func skipWhitespace() {
            while offset < characters.count, characters[offset].isWhitespace { offset += 1 }
        }

        skipWhitespace()
        let isClosing = offset < characters.count && characters[offset] == "/"
        if isClosing { offset += 1 }
        skipWhitespace()

        let nameStart = offset
        while offset < characters.count,
              !characters[offset].isWhitespace,
              characters[offset] != "/",
              characters[offset] != ">" {
            offset += 1
        }
        guard offset > nameStart else { return nil }
        let name = String(characters[nameStart..<offset]).lowercased()
        if isClosing { return (name, [:], true, false) }

        var attributes: [String: String] = [:]
        var isSelfClosing = false
        while offset < characters.count {
            skipWhitespace()
            guard offset < characters.count else { break }
            if characters[offset] == "/" {
                isSelfClosing = true
                offset += 1
                continue
            }

            let attributeStart = offset
            while offset < characters.count,
                  !characters[offset].isWhitespace,
                  characters[offset] != "=",
                  characters[offset] != "/",
                  characters[offset] != ">" {
                offset += 1
            }
            guard offset > attributeStart else {
                offset += 1
                continue
            }
            let key = String(characters[attributeStart..<offset]).lowercased()
            skipWhitespace()

            var value = ""
            if offset < characters.count, characters[offset] == "=" {
                offset += 1
                skipWhitespace()
                if offset < characters.count, characters[offset] == "\"" || characters[offset] == "'" {
                    let quote = characters[offset]
                    offset += 1
                    let valueStart = offset
                    while offset < characters.count, characters[offset] != quote { offset += 1 }
                    value = String(characters[valueStart..<offset])
                    if offset < characters.count { offset += 1 }
                } else {
                    let valueStart = offset
                    while offset < characters.count,
                          !characters[offset].isWhitespace,
                          characters[offset] != ">" {
                        offset += 1
                    }
                    value = String(characters[valueStart..<offset])
                }
            }
            if attributes[key] == nil {
                attributes[key] = value
            }
        }
        return (name, attributes, false, isSelfClosing)
    }

    private static func firstWebElement(named name: String, in node: WebHTMLNode) -> WebHTMLNode? {
        if node.name == name { return node }
        for child in node.children {
            if let match = firstWebElement(named: name, in: child) { return match }
        }
        return nil
    }

    private static func visitWebElements(in node: WebHTMLNode, _ visit: (WebHTMLNode) -> Void) {
        visit(node)
        for child in node.children {
            visitWebElements(in: child, visit)
        }
    }

    private static func webText(in node: WebHTMLNode) -> String {
        var buffer = ""
        appendReadableWebText(from: node, to: &buffer)
        return buffer
    }

    private static func rawWebText(in node: WebHTMLNode) -> String {
        if let text = node.text { return text }
        return node.children.map(rawWebText(in:)).joined()
    }

    private static func appendReadableWebText(from node: WebHTMLNode, to output: inout String) {
        if let text = node.text {
            output += text
            return
        }
        guard let name = node.name else {
            for child in node.children { appendReadableWebText(from: child, to: &output) }
            return
        }
        let attributes = node.attributes
        let style = decodeWebHTMLEntities(attributes["style"] ?? "").lowercased()
        guard !ignoredWebContentTags.contains(name),
              attributes["hidden"] == nil,
              attributes["aria-hidden"]?.lowercased() != "true",
              !style.contains("display:none"),
              !style.contains("display: none"),
              !style.contains("visibility:hidden"),
              !style.contains("visibility: hidden") else { return }

        if name == "br" || name == "hr" {
            output += "\n"
            return
        }
        let isBlock = blockWebContentTags.contains(name)
        if isBlock, !output.isEmpty, !output.hasSuffix("\n") { output += "\n" }
        if name == "img", let alt = attributes["alt"], !alt.isEmpty {
            output += alt
        }
        for child in node.children {
            appendReadableWebText(from: child, to: &output)
        }
        if isBlock, !output.hasSuffix("\n") { output += "\n" }
    }

    private static func collectReadableHeadings(in node: WebHTMLNode, into headings: inout [String]) {
        guard let name = node.name else {
            for child in node.children { collectReadableHeadings(in: child, into: &headings) }
            return
        }
        guard !ignoredWebContentTags.contains(name) else { return }
        if ["h1", "h2", "h3", "h4", "h5", "h6"].contains(name) {
            let heading = normalizedWebText(webText(in: node))
            if !heading.isEmpty, !headings.contains(heading), headings.count < 32 {
                headings.append(String(heading.prefix(300)))
            }
        }
        for child in node.children { collectReadableHeadings(in: child, into: &headings) }
    }

    private static func collectReadableLinks(
        in node: WebHTMLNode,
        baseURL: URL,
        into links: inout [[String: String]],
        seen: inout Set<String>
    ) {
        guard let name = node.name else {
            for child in node.children {
                collectReadableLinks(in: child, baseURL: baseURL, into: &links, seen: &seen)
            }
            return
        }
        guard !ignoredWebContentTags.contains(name) else { return }
        if name == "a",
           let rawHref = node.attributes["href"],
           let url = URL(string: decodeWebHTMLEntities(rawHref), relativeTo: baseURL)?.absoluteURL,
           publicWebURL(url.absoluteString) != nil,
           seen.insert(url.absoluteString).inserted,
           links.count < 40 {
            let anchorText = normalizedWebText(webText(in: node))
            let fallbackLabel = node.attributes["title"].map(normalizedWebText) ?? url.host ?? "Link"
            let label = anchorText.isEmpty ? fallbackLabel : anchorText
            links.append([
                "text": String(label.prefix(300)),
                "url": url.absoluteString
            ])
        }
        for child in node.children {
            collectReadableLinks(in: child, baseURL: baseURL, into: &links, seen: &seen)
        }
    }

    private static func decodeWebHTMLEntities(_ value: String) -> String {
        let namedEntities = [
            "amp": "&", "apos": "'", "gt": ">", "lt": "<", "nbsp": " ",
            "quot": "\"", "copy": "©", "mdash": "—", "ndash": "–",
            "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
            "hellip": "…", "bull": "•"
        ]
        var output = ""
        var cursor = value.startIndex
        while cursor < value.endIndex {
            guard value[cursor] == "&" else {
                output.append(value[cursor])
                cursor = value.index(after: cursor)
                continue
            }
            let entityStart = value.index(after: cursor)
            guard let semicolon = value[entityStart...].firstIndex(of: ";"),
                  value.distance(from: entityStart, to: semicolon) <= 16 else {
                output.append("&")
                cursor = entityStart
                continue
            }
            let entity = String(value[entityStart..<semicolon])
            var decoded: String?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                if let scalarValue = UInt32(entity.dropFirst(2), radix: 16),
                   let scalar = UnicodeScalar(scalarValue) {
                    decoded = String(scalar)
                }
            } else if entity.hasPrefix("#") {
                if let scalarValue = UInt32(entity.dropFirst()),
                   let scalar = UnicodeScalar(scalarValue) {
                    decoded = String(scalar)
                }
            } else {
                decoded = namedEntities[entity.lowercased()]
            }
            if let decoded {
                output += decoded
                cursor = value.index(after: semicolon)
            } else {
                output += "&"
                cursor = entityStart
            }
        }
        return output
    }

    private static func normalizedWebText(_ value: String) -> String {
        let decoded = decodeWebHTMLEntities(value)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return decoded.components(separatedBy: "\n").compactMap { line in
            let normalizedLine = replacing(line, pattern: #"[ \t]+"#, with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return normalizedLine.isEmpty ? nil : normalizedLine
        }.joined(separator: "\n")
    }

    private static func replacing(_ value: String, pattern: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        return expression.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value),
            withTemplate: replacement
        )
    }


    private static func extensionCatalog() -> LimaAIToolExecution {
        let loader = ExtensionLoader()
        let commands = loader.load(prepare: false, registerPackages: false).commands
        let commandEntries = commands.prefix(80).map { loaded in
            [
                "extension": loaded.extensionName,
                "command": loaded.command.title,
                "summary": loaded.command.subtitle ?? "No summary provided.",
                "capabilities": loaded.capabilities.map(\.rawValue).sorted(),
                "action_type": loaded.command.action.type.rawValue,
                "can_execute_from_ai": false
            ] as [String: Any]
        }
        let contributions = loader.contributionCatalog()
        let contributionEntries = contributions.prefix(40).map { package in
            [
                "extension": package.extensionName,
                "capabilities": package.capabilities.map(\.rawValue).sorted(),
                "tools": package.tools.map { tool in
                    [
                        "id": tool.id,
                        "title": tool.title,
                        "description": tool.description,
                        "declared_read_only": tool.isReadOnly,
                        "host_adapter_available": tool.isEligibleForReadOnlyHostAdapter,
                        "requires_explicit_ai_opt_in": true
                    ] as [String: Any]
                },
                "skills": package.skills.map { skill in
                    ["id": skill.id, "name": skill.name, "preferred_tools": skill.preferredToolIDs]
                },
                "agents": package.agents.map { agent in
                    [
                        "id": agent.id,
                        "name": agent.name,
                        "model_provider": agent.modelProviderID ?? NSNull(),
                        "model": agent.modelID ?? NSNull(),
                        "skills": agent.skillIDs,
                        "tools": agent.toolIDs,
                        "can_execute_from_ai": false
                    ] as [String: Any]
                }
            ] as [String: Any]
        }
        return .json([
            "commands": commandEntries,
            "contributions": contributionEntries,
            "truncated": commands.count > commandEntries.count || contributions.count > contributionEntries.count,
            "policy": "AI Chat can inspect this catalog and draft extension code in chat, but never installs, runs, approves, or changes an extension. Only explicitly enabled declarations with an allowlisted read-only host adapter are callable; all other tools remain metadata only."
        ])
    }
}

/// A concise, user-facing capability. Each group preserves the underlying
/// strict function schemas while preventing the chat composer from presenting a
/// long list of implementation-level functions.
struct LimaAIToolGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let summary: String
    let symbol: String
    let toolIDs: Set<String>

    static let coreGroups: [LimaAIToolGroup] = [
        .init(id: "memory", title: "Memory", summary: "Read saved local context; add, edit, or forget entries in the inspector",
              symbol: "brain.head.profile", toolIDs: AIContextTools.memoryReadIDs),
        .init(id: "subagents", title: "Subagents", summary: "Up to three analysis requests per turn using configured providers; API usage applies",
              symbol: "person.2", toolIDs: AIContextTools.delegationIDs),
        .init(id: "notes", title: "Notes", summary: "Search and read local Notes when asked",
              symbol: "note.text", toolIDs: AINotesTools.ids),
        .init(
            id: "screen-context",
            title: "Screen context",
            summary: "Read the previous app and selected text",
            symbol: "rectangle.on.rectangle",
            toolIDs: ["read_screen_context"]
        ),
        .init(
            id: "files",
            title: "Files",
            summary: "Find and read local files",
            symbol: "folder",
            toolIDs: ["search_files", "find_files", "list_directory", "file_metadata", "read_file"]
        ),
        .init(
            id: "web-research",
            title: "Web research",
            summary: "Search and read public pages",
            symbol: "globe",
            toolIDs: ["search_web", "read_web"]
        ),
        .init(
            id: "browser",
            title: "Browser",
            summary: "Inspect granted tabs and visible page content",
            symbol: "safari",
            toolIDs: [
                "browser_tabs", "browser_current", "browser_read",
                "salesforce_read_case_links", "salesforce_resolve_case", "salesforce_resolve_cases"
            ]
        ),
        .init(
            id: "browser-navigation",
            title: "Browser navigation",
            summary: "Open, focus, and navigate granted tabs",
            symbol: "safari",
            toolIDs: ["browser_open_tabs", "browser_focus_tab", "browser_navigate_tab"]
        ),
        .init(
            id: "browser-interaction",
            title: "Browser interaction",
            summary: "Click and type with site access; submit always asks",
            symbol: "cursorarrow.click",
            toolIDs: ["browser_click", "browser_type", "browser_submit"]
        ),
        .init(
            id: "local-files",
            title: "Local files",
            summary: "Create or replace bounded text and source files",
            symbol: "doc.badge.plus",
            toolIDs: ["create_text_file", "replace_text_file"]
        ),
        .init(
            id: "terminal",
            title: "Terminal and code",
            summary: "Run one approved bounded local developer command",
            symbol: "terminal",
            toolIDs: ["run_terminal_command"]
        ),
        .init(
            id: "lima-workspace",
            title: "Lima workspace",
            summary: "Read Lima status and installed extensions",
            symbol: "sparkles",
            toolIDs: ["list_extensions", "get_lima_status"]
        )
    ]

    static func visibleGroups(for definitions: [LimaAIToolDefinition]) -> [LimaAIToolGroup] {
        let availableIDs = Set(definitions.map(\.id))
        var groups = coreGroups.compactMap { group -> LimaAIToolGroup? in
            let present = group.toolIDs.intersection(availableIDs)
            guard !present.isEmpty else { return nil }
            return LimaAIToolGroup(
                id: group.id,
                title: group.title,
                summary: group.summary,
                symbol: group.symbol,
                toolIDs: present
            )
        }
        let extensionIDs = Set(definitions.compactMap { definition in
            definition.extensionBinding == nil ? nil : definition.id
        })
        if !extensionIDs.isEmpty {
            groups.append(.init(
                id: "installed-extensions",
                title: "Installed extensions",
                summary: "Use approved read-only extension capabilities",
                symbol: "puzzlepiece.extension",
                toolIDs: extensionIDs
            ))
        }
        return groups
    }
}

extension LimaAIToolDefinition {
    var displayName: String {
        switch id {
        case "memory_search": return "Recall memory"
        case "agent_models": return "Subagent models"
        case "agent_delegate": return "Delegate analysis"
        case "read_screen_context": return "Screen context"
        case "search_notes": return "Search Notes"
        case "read_note": return "Read Note"
        case "search_files": return "Find files"
        case "read_file": return "Read a file"
        case "search_web": return "Search the web"
        case "read_web": return "Read a web page"
        case "list_extensions": return "Browse extensions"
        case "get_lima_status": return "Lima status"
        default:
            if let extensionBinding { return "\(extensionBinding.extensionName) · \(extensionBinding.tool.title)" }
            return name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var userSummary: String {
        switch id {
        case "read_screen_context": return "App, window, and selected text"
        case "search_notes": return "Titles and short matching excerpts"
        case "read_note": return "One bounded local note range"
        case "search_files", "find_files": return "Names and paths only"
        case "list_directory": return "Visible direct children only"
        case "file_metadata": return "Basic file metadata only"
        case "read_file": return "Bounded numbered text ranges"
        case "search_web": return "Public results only"
        case "read_web": return "Public text only, never submits"
        case "list_extensions": return "Catalog only, never runs"
        case "get_lima_status": return "Private app details"
        case "browser_open_tabs": return "Open granted tabs"
        case "browser_focus_tab": return "Focus a granted tab"
        case "browser_navigate_tab": return "Navigate a granted tab"
        case "browser_click": return "Click in a granted tab"
        case "browser_type": return "Type in a granted tab"
        case "browser_submit": return "Submit a granted form"
        case "create_text_file": return "Create a text file"
        case "replace_text_file": return "Replace a text file"
        case "run_terminal_command": return "Run a local developer command"
        default:
            if let extensionBinding { return extensionBinding.tool.description }
            return description
        }
    }

    var symbol: String {
        switch id {
        case "memory_search": return "brain.head.profile"
        case "agent_models", "agent_delegate": return "person.2"
        case "read_screen_context": return "rectangle.on.rectangle"
        case "search_notes", "read_note": return "note.text"
        case "search_files", "find_files", "list_directory": return "folder"
        case "file_metadata": return "doc.badge.gearshape"
        case "read_file": return "doc.text"
        case "search_web": return "globe"
        case "read_web": return "doc.text.magnifyingglass"
        case "list_extensions": return "square.grid.2x2"
        case "get_lima_status": return "checkmark.shield"
        case "browser_open_tabs", "browser_focus_tab", "browser_navigate_tab": return "safari"
        case "browser_click", "browser_type", "browser_submit": return "cursorarrow.click"
        case "create_text_file", "replace_text_file": return "doc.badge.plus"
        case "run_terminal_command": return "terminal"
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

    private convenience init() {
        self.init(defaults: LimaTestEnvironment.userDefaults)
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let saved = defaults.stringArray(forKey: defaultsKey)
        enabledToolIDs = saved.map(Set.init) ?? LimaAIToolRegistry.defaultEnabledToolIDs
        // Introduce only these new capabilities once; later explicit off choices remain off.
        let migrationKey = "lima.ai.context-tools-v1"
        if !defaults.bool(forKey: migrationKey) {
            enabledToolIDs.formUnion(AIContextTools.ids)
            defaults.set(Array(enabledToolIDs).sorted(), forKey: defaultsKey)
            defaults.set(true, forKey: migrationKey)
        }
        // Action schemas remain inert until their category is explicitly enabled
        // in AI Settings. Preselect them once so enabling a category is sufficient
        // and does not silently re-enable a later user opt-out.
        let actionMigrationKey = "lima.ai.computer-actions-v1"
        if !defaults.bool(forKey: actionMigrationKey) {
            enabledToolIDs.formUnion(AILocalComputerActionTools.ids)
            enabledToolIDs.formUnion([
                "browser_open_tabs", "browser_focus_tab", "browser_navigate_tab",
                "browser_click", "browser_type", "browser_submit"
            ])
            defaults.set(Array(enabledToolIDs).sorted(), forKey: defaultsKey)
            defaults.set(true, forKey: actionMigrationKey)
        }
        // Existing installations may have saved a tool list before Browser and
        // Notes reading were available. Add only read-only schemas once; actual
        // browser content still requires a site grant and a routed AI request.
        let readMigrationKey = "lima.ai.browser-notes-read-v1"
        if !defaults.bool(forKey: readMigrationKey) {
            enabledToolIDs.formUnion(AINotesTools.ids)
            enabledToolIDs.formUnion(BrowserBridgeAITools.readToolIDs)
            defaults.set(Array(enabledToolIDs).sorted(), forKey: defaultsKey)
            defaults.set(true, forKey: readMigrationKey)
        }
    }

    init(fixtures: Set<String>) {
        defaults = nil
        enabledToolIDs = fixtures
    }

    func isEnabled(_ definition: LimaAIToolDefinition) -> Bool {
        enabledToolIDs.contains(definition.id)
    }

    func isEnabled(_ group: LimaAIToolGroup) -> Bool {
        !group.toolIDs.isEmpty && group.toolIDs.isSubset(of: enabledToolIDs)
    }

    func setEnabled(_ definition: LimaAIToolDefinition, enabled: Bool) {
        if enabled { enabledToolIDs.insert(definition.id) }
        else { enabledToolIDs.remove(definition.id) }
        persist()
    }

    func setEnabled(_ group: LimaAIToolGroup, enabled: Bool) {
        if enabled { enabledToolIDs.formUnion(group.toolIDs) }
        else { enabledToolIDs.subtract(group.toolIDs) }
        persist()
    }

    private func persist() {
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
            let error = value["error"] as? [String: Any] ?? response?["error"] as? [String: Any] ?? value
            let message = AIProviderFailure.message(error: error)
            return [
                .diagnostic(AIChatDiagnostic(
                    stage: .api,
                    model: model,
                    responseID: responseID,
                    eventType: type,
                    errorCode: AIProviderFailure.code(error["code"]),
                    errorParameter: AIProviderFailure.parameter(error["param"]),
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
        AIProviderFailure.toolMessage(value)
    }
}

/// Incrementally reconstructs Responses Server-Sent Events without delaying
/// streamed output. Keeping framing separate from semantic decoding makes the
/// raw line-boundary behavior directly testable.
struct AIResponsesSSEParser {
    private let model: String?
    private var framer = AIProviderSSEFramer()
    private(set) var failed = false

    init(model: String?) { self.model = model }

    mutating func append(line: String) -> [AIChatStreamEvent] {
        guard !failed else { return [] }
        do { return decode(try framer.append(line: line)) }
        catch { return fail() }
    }

    mutating func append(byte: UInt8) -> [AIChatStreamEvent] {
        guard !failed else { return [] }
        do { return decode(try framer.append(byte)) }
        catch { return fail() }
    }

    mutating func finish() -> [AIChatStreamEvent] {
        guard !failed else { return [] }
        do { return decode(try framer.finish()) }
        catch { return fail() }
    }

    private func decode(_ frame: AIProviderSSEFrame?) -> [AIChatStreamEvent] {
        guard let frame else { return [] }
        return AIResponsesEventDecoder.events(eventType: frame.event, dataLines: [frame.data], model: model)
    }

    private mutating func fail() -> [AIChatStreamEvent] {
        failed = true
        return [.failed("The provider stream exceeded Lima's safety limit.")]
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

enum AIFileAttachmentPolicy {
    static let maximumTextBytes = 96 * 1_024
    static let maximumImageBytes = 8 * 1_024 * 1_024
    private static let imageMIMETypes: Set<String> = ["image/jpeg", "image/png", "image/gif", "image/webp"]

    static func canAttach(_ attachment: AIAttachment) -> Bool {
        if attachment.kind == .file, attachment.text != nil { return true }
        guard let path = attachment.path, let url = try? safeURL(path),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentTypeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize else { return false }
        switch attachment.kind {
        case .file:
            if values.contentType?.conforms(to: .pdf) == true { return size <= maximumImageBytes }
            return size <= maximumTextBytes && LimaAIToolRegistry.isTextFile(url: url, contentType: values.contentType)
        case .image:
            return size <= maximumImageBytes && imageMIMETypes.contains((attachment.mimeType ?? "").lowercased())
        case .clipboard, .selection:
            return attachment.text != nil
        }
    }

    static func text(for attachment: AIAttachment) throws -> String {
        if let embedded = attachment.text {
            let excerpt = String(embedded.prefix(96_000))
            return embedded.count > 96_000 ? excerpt + "\n[Attachment content truncated by Lima.]" : excerpt
        }
        guard let path = attachment.path else { throw failure("The file no longer has a readable path.") }
        let url = try safeURL(path)
        let values = try url.resourceValues(forKeys: [.contentTypeKey])
        if values.contentType?.conforms(to: .pdf) == true {
            let data = try boundedData(at: url, maximumBytes: maximumImageBytes)
            guard let document = PDFDocument(data: data) else { throw failure("This PDF could not be read.") }
            let pages = (0..<min(document.pageCount, 20)).compactMap { document.page(at: $0)?.string }
            let extracted = pages.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !extracted.isEmpty else { throw failure("This PDF has no selectable text to describe.") }
            let excerpt = String(extracted.prefix(96_000))
            return document.pageCount > 20 || extracted.count > 96_000
                ? excerpt + "\n[PDF extraction truncated by Lima.]" : excerpt
        }
        guard LimaAIToolRegistry.isTextFile(url: url, contentType: values.contentType) else {
            throw failure("Only text and source-code files can be referenced in AI chat.")
        }
        let data = try boundedData(at: url, maximumBytes: maximumTextBytes)
        guard let text = String(data: data, encoding: .utf8) else {
            throw failure("This file is not UTF-8 text.")
        }
        return text
    }

    static func image(for attachment: AIAttachment) throws -> (mediaType: String, base64: String) {
        guard let path = attachment.path else { throw failure("The image no longer has a readable path.") }
        let url = try safeURL(path)
        let mediaType = (attachment.mimeType ?? "").lowercased()
        guard imageMIMETypes.contains(mediaType) else {
            throw failure("AI chat accepts JPEG, PNG, GIF, or WebP images.")
        }
        let data = try boundedData(at: url, maximumBytes: maximumImageBytes)
        return (mediaType, data.base64EncodedString())
    }

    private static func safeURL(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let resolved = url.resolvingSymlinksInPath()
        guard url == resolved,
              !url.pathComponents.contains(where: { $0.hasPrefix(".") }),
              !LimaAIToolRegistry.isSensitivePath(url) else {
            throw failure("This path is not available to AI file context.")
        }
        return url
    }

    private static func boundedData(at url: URL, maximumBytes: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= maximumBytes else {
            throw failure("This file is unavailable or exceeds the AI attachment limit.")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw failure("This file exceeds the AI attachment limit.") }
        return data
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "LimaAIFileContext", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

struct AIInputEncoder {
    /// Keep explicit continuity payloads bounded when a provider/model cannot use
    /// a prior response ID. The durable local transcript remains unchanged.
    static let maximumContinuityCharacters = 120_000

    static func content(text: String, attachments: [AIAttachment]) throws -> [[String: Any]] {
        let attachmentContent = try attachmentContent(attachments)
        return [["type": "input_text", "text": text]] + attachmentContent
    }

    /// Reconstruct a Responses-compatible transcript when a model change resets a
    /// provider continuation. The newest user message is already part of history;
    /// attachments are added to that exact message instead of being duplicated.
    static func transcript(
        _ history: [AIProviderMessage],
        attachments: [AIAttachment],
        maximumCharacters: Int = maximumContinuityCharacters
    ) throws -> [[String: Any]] {
        let history = bounded(history, maximumCharacters: maximumCharacters)
        var result: [[String: Any]] = []
        var lastUserIndex: Int?

        for message in history {
            var parts: [[String: Any]] = []
            for item in message.content {
                switch item {
                case .text(let text):
                    guard !text.isEmpty else { continue }
                    parts.append([
                        "type": message.role == .assistant ? "output_text" : "input_text",
                        "text": text
                    ])
                case .image(let mediaType, let base64):
                    guard message.role == .user else { continue }
                    parts.append(["type": "input_image", "image_url": "data:\(mediaType);base64,\(base64)"])
                case .toolUse, .toolResult:
                    // Local transcript persistence stores user/assistant text only.
                    // Tool continuations use the provider's dedicated output path.
                    continue
                }
            }
            guard !parts.isEmpty else { continue }
            result.append([
                "role": message.role == .assistant ? "assistant" : "user",
                "content": parts
            ])
            if message.role == .user { lastUserIndex = result.indices.last }
        }

        let attachmentContent = try attachmentContent(attachments)
        guard !attachmentContent.isEmpty else { return result }
        if let index = lastUserIndex, var content = result[index]["content"] as? [[String: Any]] {
            content.append(contentsOf: attachmentContent)
            result[index]["content"] = content
        } else {
            result.append(["role": "user", "content": attachmentContent])
        }
        return result
    }

    static func attachmentContent(_ attachments: [AIAttachment]) throws -> [[String: Any]] {
        var content: [[String: Any]] = []
        for attachment in attachments {
            switch attachment.kind {
            case .clipboard, .selection:
                if let value = attachment.text {
                    content.append(["type": "input_text", "text": "\n\n[\(attachment.displayName)]\n\(String(value.prefix(96_000)))"])
                }
            case .file:
                let value = try AIFileAttachmentPolicy.text(for: attachment)
                content.append(["type": "input_text", "text": "[File: \(attachment.displayName)]\n\(value)"])
            case .image:
                let image = try AIFileAttachmentPolicy.image(for: attachment)
                content.append(["type": "input_image", "image_url": "data:\(image.mediaType);base64,\(image.base64)"])
            }
        }
        return content
    }

    private static func bounded(_ history: [AIProviderMessage], maximumCharacters: Int) -> [AIProviderMessage] {
        guard maximumCharacters > 0 else { return Array(history.suffix(1)) }
        var first = 0
        var characterCount = history.reduce(0) { partial, message in
            partial + message.content.reduce(0) { count, item in
                switch item {
                case .text(let text): return count + text.count
                case .image(_, let base64): return count + base64.count
                case .toolUse(_, _, let arguments): return count + arguments.count
                case .toolResult(_, let output): return count + output.count
                }
            }
        }
        while first < history.count - 1, characterCount > maximumCharacters {
            characterCount -= history[first].content.reduce(0) { count, item in
                switch item {
                case .text(let text): return count + text.count
                case .image(_, let base64): return count + base64.count
                case .toolUse(_, _, let arguments): return count + arguments.count
                case .toolResult(_, let output): return count + output.count
                }
            }
            first += 1
        }
        return Array(history.dropFirst(first))
    }
}

// MARK: - Markdown rendering

/// A reusable read-only Markdown document renderer for Lima workspaces.
struct LimaMarkdownDocumentView: View, Equatable {
    let markdown: String

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.markdown == rhs.markdown }

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
                    AIChatCopyButton(text: value, style: .labeled, accessibilityID: "ai-copy-code")
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
    @State private var showingFullRequest = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(LimaColors.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Review tool request").limaFont(.callout.weight(.semibold))
                    Text("\(request.serverLabel) · \(request.toolName)")
                        .limaFont(.caption)
                        .foregroundStyle(LimaColors.secondaryText)
                }
                Spacer()
            }

            Text(requestSummary)
                .limaFont(.caption)
                .foregroundStyle(LimaColors.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let arguments = formattedArguments {
                DisclosureGroup("Review full request", isExpanded: $showingFullRequest) {
                    ScrollView(.vertical) {
                        Text(arguments)
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 220)
                    .background(LimaColors.editorBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .padding(.top, 4)
                }
                .limaFont(.caption)
            }

            HStack {
                Text("Allow Once runs this request only and records the result in Activity.")
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

    private var requestSummary: String {
        let arguments = decodedArguments
        let toolID = request.localToolID ?? request.toolName
        switch toolID {
        case "browser_open_tabs":
            let urls = arguments["urls"] as? [String] ?? []
            return "Open \(urls.count) tab\(urls.count == 1 ? "" : "s")\(hostList(urls).isEmpty ? "" : " at " + hostList(urls))."
        case "browser_focus_tab":
            return "Focus \(host(arguments["expectedURL"] as? String) ?? "the requested tab")."
        case "browser_navigate_tab":
            let source = host(arguments["expectedURL"] as? String)
            let destination = host(arguments["url"] as? String)
            if let source, let destination { return "Navigate \(source) to \(destination)." }
            return "Navigate the requested browser tab."
        case "browser_click":
            return "Click \(quoted(arguments["selector"] as? String) ?? "the requested element")\(host(arguments["expectedURL"] as? String).map { " at \($0)" } ?? "")."
        case "browser_type":
            let count = (arguments["text"] as? String)?.count ?? 0
            return "Type \(count) character\(count == 1 ? "" : "s") into \(quoted(arguments["selector"] as? String) ?? "the requested field")\(host(arguments["expectedURL"] as? String).map { " at \($0)" } ?? "")."
        case "browser_submit":
            return "Submit \(quoted(arguments["selector"] as? String) ?? "the requested form")\(host(arguments["expectedURL"] as? String).map { " at \($0)" } ?? "")."
        case "create_text_file":
            return "Create \(quoted(arguments["path"] as? String) ?? "the requested file") with \(characterCount(arguments["content"])) character\(characterCount(arguments["content"]) == 1 ? "" : "s")."
        case "replace_text_file":
            return "Replace \(quoted(arguments["path"] as? String) ?? "the requested file") with \(characterCount(arguments["content"])) character\(characterCount(arguments["content"]) == 1 ? "" : "s")."
        case "run_terminal_command":
            let command = quoted(arguments["command"] as? String) ?? "the requested command"
            let directory = arguments["working_directory"] as? String
            return directory.map { "Run \(command) in \(quoted($0) ?? $0)." } ?? "Run \(command)."
        default:
            return "Review the complete request before allowing this tool to run."
        }
    }

    private var decodedArguments: [String: Any] {
        guard let arguments = request.arguments,
              let data = arguments.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any] else { return [:] }
        return object
    }

    private var formattedArguments: String? {
        guard let arguments = request.arguments, !arguments.isEmpty else { return nil }
        guard let data = arguments.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(value),
              let prettyData = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let pretty = String(data: prettyData, encoding: .utf8) else {
            return arguments
        }
        return pretty
    }

    private func host(_ value: String?) -> String? {
        guard let value, let parsed = URL(string: value), let host = parsed.host, !host.isEmpty else { return nil }
        return host
    }

    private func hostList(_ urls: [String]) -> String {
        let values = Array(Set(urls.compactMap(host))).sorted()
        return values.prefix(3).joined(separator: ", ") + (values.count > 3 ? "…" : "")
    }

    private func quoted(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return "“\(value)”"
    }

    private func characterCount(_ value: Any?) -> Int {
        (value as? String)?.count ?? 0
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
