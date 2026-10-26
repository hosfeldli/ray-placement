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
        case .codexCLI:
            return CLIChatProviderClient.isValidModelID(id)
        case .claudeCLI:
            return value == "default" // No model catalog endpoint in this adapter.
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
    case pastedText

    var symbol: String {
        switch self {
        case .file: return "doc"
        case .image: return "photo"
        case .clipboard: return "doc.on.clipboard"
        case .selection: return "text.quote"
        case .pastedText: return "doc.text"
        }
    }
}

enum AIAttachmentSourceRoute: String, Codable, Hashable, Sendable {
    case contextShelf
    case selectedText
    case clipboard
    case dictation
    case terminal
    case extensionOutput

    var title: String {
        switch self {
        case .contextShelf: return "Context Shelf"
        case .selectedText: return "Selected text"
        case .clipboard: return "Clipboard"
        case .dictation: return "Dictation"
        case .terminal: return "Terminal"
        case .extensionOutput: return "Extension"
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
    /// For pasted text, `id` is the durable blob reference; these fields are
    /// deliberately small so conversation JSON never includes the full paste.
    var byteCount: Int?
    var lineCount: Int?
    var previewText: String?
    /// Lightweight origin for an explicit handoff; no source content is stored here.
    var sourceRoute: AIAttachmentSourceRoute?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        kind: AIAttachmentKind,
        displayName: String,
        path: String? = nil,
        text: String? = nil,
        mimeType: String? = nil,
        byteCount: Int? = nil,
        lineCount: Int? = nil,
        previewText: String? = nil,
        sourceRoute: AIAttachmentSourceRoute? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.path = path
        self.text = text
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.lineCount = lineCount
        self.previewText = previewText
        self.sourceRoute = sourceRoute
        self.createdAt = createdAt
    }

    var preview: String {
        if let previewText { return previewText }
        if let text { return text.replacingOccurrences(of: "\n", with: " ").prefix(100).description }
        return path ?? displayName
    }

    var metadataSummary: String? {
        guard kind == .pastedText, let byteCount, let lineCount else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        return "\(size) · \(lineCount.formatted()) lines"
    }

    var transferRoute: String {
        if let sourceRoute { return "\(sourceRoute.title) → AI draft" }
        switch kind {
        case .clipboard: return "Clipboard → AI draft"
        case .selection: return "Selection or Shelf → AI draft"
        case .pastedText: return "Paste → AI draft"
        case .image: return "Image → AI draft"
        case .file:
            return path == nil && mimeType == "text/markdown"
                ? "Note → AI draft" : "File → AI draft"
        }
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
        // Cached input and reasoning output are subsets reported alongside
        // input/output totals, not additional tokens to add to them.
        let values = [inputTokens, outputTokens].compactMap { $0 }.filter { $0 >= 0 }
        guard !values.isEmpty else { return nil }
        return values.reduce(0) { total, value in
            value > Int.max - total ? Int.max : total + value
        }
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
    var toolOutputReference: AIToolOutputReference?
    var correlationID: String?
    var parentCorrelationID: String?
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
        toolOutputReference: AIToolOutputReference? = nil,
        correlationID: String? = nil,
        parentCorrelationID: String? = nil,
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
        self.toolOutputReference = toolOutputReference
        self.correlationID = correlationID
        self.parentCorrelationID = parentCorrelationID
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
        case "memory_save": return "Save memory"
        case "memory_update": return "Revise memory"
        case "memory_forget": return "Forget memory"
        case "edit_text_file": return "Edit a file"
        case "agent_models": return "Choose a subagent model"
        case "agent_delegate": return "Delegate analysis"
        case "read_screen_context": return "Screen context"
        case "search_notes": return "Search Notes"
        case "read_note": return "Read Note"
        case "create_note": return "Create Note"
        case "append_to_note": return "Append to Note"
        case "search_files": return "Find files"
        case "search_workspace_text": return "Search file contents"
        case "inspect_directory_tree": return "Inspect project tree"
        case "read_file": return "Read a file"
        case "list_extensions": return "Browse extensions"
        case "get_lima_status": return "Lima status"
        case "lima_capabilities": return "Check tool capabilities"
        case "terminal_start": return "Start AI Workspace"
        case "terminal_run": return "Run Workspace command"
        case "terminal_write": return "Write to Workspace shell"
        case "terminal_status": return "Check Workspace status"
        case "terminal_read": return "Read Workspace output"
        case "terminal_wait": return "Wait for Workspace command"
        case "terminal_interrupt": return "Interrupt Workspace command"
        case "terminal_resize": return "Resize Workspace shell"
        case "terminal_terminate": return "End Workspace shell"
        case "terminal_set_directory": return "Change Workspace directory"
        case "terminal_close": return "Close AI Workspace session"
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
    var localCallID: String?
    var localToolID: String?
    var serverLabel: String
    var toolName: String
    var arguments: String?
    /// A bounded, fresh Browser review shown to the user before a final action.
    var browserReviewSummary: String?
    /// Native Browser payment-risk classification for a distinct confirmation UI.
    var browserPaymentReview: Bool?
    /// Set only for a reviewed, owned AI Workspace terminal_run request.
    var directoryGrantPath: String?
    var decision: AIToolApprovalDecision
    var createdAt: Date

    init(
        id: UUID = UUID(),
        localCallID: String? = nil,
        localToolID: String? = nil,
        serverLabel: String,
        toolName: String,
        arguments: String? = nil,
        browserReviewSummary: String? = nil,
        browserPaymentReview: Bool? = nil,
        directoryGrantPath: String? = nil,
        decision: AIToolApprovalDecision = .pending,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.localCallID = localCallID
        self.localToolID = localToolID
        self.serverLabel = serverLabel
        self.toolName = toolName
        self.arguments = arguments
        self.browserReviewSummary = browserReviewSummary
        self.browserPaymentReview = browserPaymentReview
        self.directoryGrantPath = directoryGrantPath
        self.decision = decision
        self.createdAt = createdAt
    }
}

// MARK: - Responses output and diagnostics

enum AIOutputItemKind: String, Codable, Sendable {
    case message
    case reasoning
    case functionCall = "function_call"
    case toolCall = "tool_call"
    case unknown

    init(apiType: String) {
        switch apiType {
        case "message": self = .message
        case "reasoning": self = .reasoning
        case "function_call": self = .functionCall
        default:
            self = apiType.contains("tool") ? .toolCall : .unknown
        }
    }

    var isToolActivity: Bool {
        self == .functionCall || self == .toolCall
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
        case delegation
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
            ["message", "reasoning", "function_call"].contains($0) ? $0 : "unknown"
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
            // Retained only to decode older manifests. Direct network reads are retired.
            throw ExtensionToolAdapterError.unavailable
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
            instructions: "Research through Lima's embedded Browser tabs only. Check Browser AI Control and page readiness, inspect actual page content, distinguish snippets from opened sources, and cite URLs actually returned. Report inaccessible pages or login walls without bypassing them.",
            preferredToolIDs: ["browser_capabilities", "browser_tabs", "browser_current", "browser_read", "browser_find", "browser_scroll", "browser_activate", "browser_open_link", "browser_wait"],
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
            instructions: "Answer from accessible Lima Browser pages and state uncertainty or access limits plainly.",
            providerID: nil,
            modelID: nil,
            reasoningEffort: .medium,
            skillIDs: ["skill.research"],
            toolIDs: ["browser_capabilities", "browser_tabs", "browser_current", "browser_read", "browser_find", "browser_scan", "browser_activate", "browser_open_link", "browser_wait"],
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
        guard let id,
              id != ExtensionToolHostAdapterID.readPublicWeb.rawValue,
              ExtensionToolHostAdapterID(rawValue: id) != nil else { return nil }
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

/// Immutable inputs captured for one provider turn. Keeping routed local
/// tools and instructions together prevents approval continuation from mixing
/// captured permissions with later mutable settings.
struct AIApprovalContinuationContext: Sendable {
    let localTools: [LimaAIToolDefinition]
    let systemInstructions: String

    var localToolIDs: [String] { localTools.map(\.id) }
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
    let browserTabID: UUID?
    /// Ephemeral typed handoff; image pixels never enter the textual tool output.
    let browserScreenshot: BrowserScreenshotResult?

    init(output: String, isError: Bool, browserTabID: UUID? = nil,
         browserScreenshot: BrowserScreenshotResult? = nil) {
        self.output = output
        self.isError = isError
        self.browserTabID = browserTabID
        self.browserScreenshot = browserScreenshot
    }

    static func json(_ object: Any, isError: Bool = false, browserTabID: UUID? = nil) -> Self {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return Self(output: "{\\\"error\\\":\\\"Lima could not encode the tool result.\\\"}", isError: true)
        }
        return Self(output: text, isError: isError, browserTabID: browserTabID)
    }
}

enum AIReadOnlyPolicy {
    static let toolUseInstructions = """
    Tool-first workflow: At the start of each request and after each tool result, look for a relevant routed Lima tool that can gather needed evidence, perform an authorized task step, or verify an outcome. Prefer calling it now over guessing, relying on stale knowledge, or asking the user to do work Lima can do. For research, inspect returned sources and follow useful leads. For build or repair tasks, inspect the target, act, run appropriate checks, and examine failures before concluding. Continue with targeted tool calls while the next call is likely to materially improve the answer or deliverable. Do not call tools merely to increase call count, when the supplied conversation already answers the request, or when no suitable routed tool exists. Do not initiate unrelated side effects or claim success without a confirming result.
    """

    static let assistantInstructions = """
    You are Lima’s private assistant. Treat supplied tools as your primary way to inspect, act, verify, and complete the user’s task. Use relevant routed tools proactively without requiring a keyword or a separate request for each necessary step.
    \(toolUseInstructions)
    Use tools only for their declared purpose; do not bypass a missing tool, Browser AI Control mode, user-interaction pause, path rule, sandbox, macOS permission, or an approval required by the active mode. Supported extension adapters are read-only. Subagents inherit only this turn’s routed Lima tools and current grants; they cannot bypass the active policy or delegate again. Do not attempt tools outside the supplied list. For Browser tools, distinguish a tab or loaded page from a visible window: claim that the user can see the Browser only when browser_visible is true. You may draft extension code or manifests in chat for review, but never install or run them.
    """

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
            + AIWorkspaceReadTools.definitions
            + AIProjectTools.definitions
            + AIUserQuestionTools.definitions
            + AIProjectFileTools.definitions
            + AIContextTools.definitions
            + AINotesTools.definitions
            + BrowserWorkspaceAITools.definitions
            + AILocalComputerActionTools.definitions
            + AIWorkspaceActionTools.definitions
            + AIProcessTools.definitions
            + AIManagedServerTools.definitions
            + NativeCapabilityAITools.definitions
            + AIWorkbenchUtilityTools.definitions
            + ExtensionToolHostAdapterRegistry.approvedBindings().map(extensionDefinition)
    }

    static var validDefinitions: [LimaAIToolDefinition] {
        candidateDefinitions.filter { $0.responsePayload != nil }
    }

    static var availableDefinitions: [LimaAIToolDefinition] {
        let mode = LimaAIToolStore.shared.accessMode
        return validDefinitions.filter { AIComputerActionPolicy.shared.allows($0, toolAccessMode: mode) }
    }

    static func schemaValidationMessage(for id: String) -> String? {
        candidateDefinitions.first(where: { $0.id == id })?.schemaValidationMessage
    }

    static var defaultEnabledToolIDs: Set<String> {
        Set(definitions.map(\.id))
            .union(AIWorkspaceReadTools.ids)
            .union(AIProjectTools.readIDs)
            .union(AIUserQuestionTools.ids)
            .union(AIProjectFileTools.readIDs)
            .union(AIContextTools.ids)
            .union(AINotesTools.readIDs)
            .union(AIWorkspaceActionTools.readIDs)
            .union(AIProcessTools.readIDs)
            .union(AIManagedServerTools.readIDs)
            .union(NativeCapabilityAITools.ids)
            .union(AIWorkbenchUtilityTools.ids)
    }

    static func definition(for name: String?) -> LimaAIToolDefinition? {
        guard let name else { return nil }
        return candidateDefinitions.first { $0.name == name || $0.id == name }
    }

    static func enabledDefinitions(_ ids: Set<String>,
                                   toolAccessMode requestedMode: LimaAIToolAccessMode? = nil) -> [LimaAIToolDefinition] {
        let toolAccessMode = requestedMode ?? LimaAIToolStore.shared.accessMode
        return validDefinitions.filter { definition in
            guard ids.contains(definition.id) else { return false }
            // Schema exposure is a capability snapshot, not a live permission
            // decision. Browser mode and action-category grants are rechecked
            // immediately before execution.
            if BrowserWorkspaceAITools.ids.contains(definition.id) { return true }
            if toolAccessMode == .fullControl { return true }
            return definition.actionCategory != nil || definition.risk == .read ||
                AIContextTools.delegationIDs.contains(definition.id) ||
                AINotesTools.writeIDs.contains(definition.id)
        }
    }

    static func requiresApproval(for name: String?,
                                 toolAccessMode: LimaAIToolAccessMode? = nil) -> Bool {
        guard let definition = definition(for: name) else { return false }
        return AIComputerActionPolicy.shared.requiresApproval(
            for: definition, toolAccessMode: toolAccessMode ?? LimaAIToolStore.shared.accessMode
        )
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

    static func execute(
        _ call: AIOutputItem,
        approvalGranted: Bool = false,
        conversationID: UUID? = nil,
        runID: UUID? = nil,
        projectManager: AIProjectManager? = nil,
        conversationStore: AIConversationStore? = nil,
        toolAccessMode: LimaAIToolAccessMode? = nil
    ) async -> LimaAIToolExecution {
        guard AIRequestPolicy.shared.isEnabled, !Task.isCancelled else {
            return .json(["error": AIRequestPolicy.disabledMessage], isError: true)
        }
        guard let definition = definition(for: call.name),
              definition.risk == .read || definition.actionCategory != nil
                || AINotesTools.writeIDs.contains(definition.id)
                || BrowserWorkspaceAITools.ids.contains(definition.id) else {
            return .json(["error": "Lima AI Chat only permits registered tools enabled by the current action policy."], isError: true)
        }
        // terminal_run has an additional live, session-scoped grant gate in
        // AIWorkspaceActionTools; no other action may bypass this policy check.
        guard definition.id == "terminal_run" || definition.actionCategory == nil
                || AIComputerActionPolicy.shared.permits(
                    definition, approvalGranted: approvalGranted,
                    toolAccessMode: toolAccessMode ?? LimaAIToolStore.shared.accessMode
                ) else {
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
        if AIWorkspaceReadTools.ids.contains(definition.id) {
            return await AIWorkspaceReadTools.execute(call)
        }
        if AIProjectTools.ids.contains(definition.id) {
            return await AIProjectTools.execute(call, approvalGranted: approvalGranted,
                                                conversationID: conversationID,
                                                manager: projectManager, conversationStore: conversationStore,
                                                toolAccessMode: toolAccessMode, runID: runID)
        }
        if AIProjectFileTools.ids.contains(definition.id) {
            return await AIProjectFileTools.execute(call, approvalGranted: approvalGranted)
        }
        if AINotesTools.ids.contains(definition.id) {
            return await AINotesTools.execute(call, approvalGranted: approvalGranted)
        }
        if BrowserWorkspaceAITools.ids.contains(definition.id) {
            return await BrowserWorkspaceAITools.execute(call, approvalGranted: approvalGranted, runID: runID)
        }
        if AILocalComputerActionTools.ids.contains(definition.id) {
            return await AILocalComputerActionTools.execute(call, approvalGranted: approvalGranted,
                                                            conversationID: conversationID)
        }
        if AIWorkspaceActionTools.ids.contains(definition.id) {
            return await AIWorkspaceActionTools.execute(call, approvalGranted: approvalGranted,
                                                       conversationID: conversationID)
        }
        if AIManagedServerTools.ids.contains(definition.id) {
            return await AIManagedServerTools.execute(call, approvalGranted: approvalGranted,
                                                      conversationID: conversationID)
        }
        if AIProcessTools.ids.contains(definition.id) {
            return await AIProcessTools.execute(call, approvalGranted: approvalGranted,
                                                conversationID: conversationID)
        }
        if AIWorkbenchUtilityTools.ids.contains(definition.id) {
            return await AIWorkbenchUtilityTools.execute(call)
        }
        if NativeCapabilityAITools.ids.contains(definition.id) {
            return await NativeCapabilityAITools.execute(
                call, approvalGranted: approvalGranted, runID: runID
            )
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
        case "list_extensions":
            return extensionCatalog()
        case "get_lima_status":
            return .json([
                "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
                "native_read_only_tools_enabled": enabledDefinitions(LimaAIToolStore.shared.effectiveEnabledToolIDs).filter { $0.risk == .read }.count,
                "computer_action_categories_enabled": AIComputerActionPolicy.shared.enabledCategories.map(\.rawValue).sorted()
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
        .init(id: "memory", title: "Memory", summary: "Read saved local context and review it in the inspector",
              symbol: "brain.head.profile", toolIDs: AIContextTools.memoryReadIDs),
        .init(id: "memory-changes", title: "Memory changes", summary: "Save, revise, or forget stable user context under the active Tool Access mode",
              symbol: "brain.head.profile", toolIDs: AIContextTools.memoryWriteIDs),
        .init(id: "subagents", title: "Subagents", summary: "Delegated analyses use this run’s configured concurrent and total budgets; inherits captured routed tools, API usage applies",
              symbol: "person.2", toolIDs: AIContextTools.delegationIDs),
        .init(id: "notes", title: "Notes", summary: "Search and read local Notes when relevant",
              symbol: "note.text", toolIDs: AINotesTools.readIDs),
        .init(id: "notes-writing", title: "Write Notes", summary: "Create a new editable report after exact-content review",
              symbol: "square.and.pencil", toolIDs: AINotesTools.writeIDs),
        .init(id: "calendar", title: "Calendar", summary: "Find, create, change, or delete events with exact-call review",
              symbol: "calendar", toolIDs: NativeCapabilityAITools.calendarIDs),
        .init(id: "reminders", title: "Reminders", summary: "Find, create, complete, change, or delete reminders with exact-call review",
              symbol: "checklist", toolIDs: NativeCapabilityAITools.reminderIDs),
        .init(id: "location", title: "Current location", summary: "Read one current location with macOS access and exact-call review",
              symbol: "location", toolIDs: NativeCapabilityAITools.locationIDs),
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
            summary: "Find names or text, inspect project trees, and read files",
            symbol: "folder",
            toolIDs: ["search_files", "find_files", "list_directory", "file_metadata", "read_file",
                      "search_workspace_text", "inspect_directory_tree"]
        ),
        .init(
            id: "projects",
            title: "Projects",
            summary: "Create durable work only when needed; archive, restore, or remove without deleting files",
            symbol: "folder.badge.gearshape",
            toolIDs: AIProjectTools.ids
        ),
        .init(
            id: "user-interaction",
            title: "User interaction",
            summary: "Pause the current AI run for a structured user decision, then resume it",
            symbol: "questionmark.bubble",
            toolIDs: AIUserQuestionTools.ids
        ),
        .init(
            id: "project-files",
            title: "Project files",
            summary: "Read, search, create, patch, move, copy, and explicitly delete files in active Projects",
            symbol: "doc.text.magnifyingglass",
            toolIDs: AIProjectFileTools.ids
        ),
        .init(
            id: "local-files",
            title: "Local files",
            summary: "Create, precisely edit, or replace bounded text and source files",
            symbol: "doc.badge.plus",
            toolIDs: AILocalComputerActionTools.fileToolIDs
        ),
        .init(
            id: "terminal",
            title: "Terminal and code",
            summary: "Run one bounded developer command outside the AI Workspace sandbox",
            symbol: "terminal",
            toolIDs: ["run_terminal_command"]
        ),
        .init(
            id: "ai-workspace-terminal",
            title: "AI Workspace terminal",
            summary: "Start and monitor visible sandboxed sessions under the active mode",
            symbol: "terminal.fill",
            toolIDs: AIWorkspaceActionTools.ids
        ),
        .init(
            id: "ai-workspace-processes",
            title: "AI Workspace processes",
            summary: "Inspect and control only conversation-owned Terminal processes and registered ports",
            symbol: "gearshape.2",
            toolIDs: AIProcessTools.ids
        ),
        .init(
            id: "managed-servers",
            title: "Managed servers",
            summary: "Register Project-owned localhost servers, wait for readiness, reuse Browser tabs, and verify shutdown",
            symbol: "network",
            toolIDs: AIManagedServerTools.ids
        ),
        .init(
            id: "workbench-utility",
            title: "Workbench utility",
            summary: "Use a cancellable bounded pause only when no condition can be observed",
            symbol: "clock",
            toolIDs: AIWorkbenchUtilityTools.ids
        ),
        .init(
            id: "lima-workspace",
            title: "Lima workspace",
            summary: "Inspect routed capabilities, app status, and installed extensions",
            symbol: "sparkles",
            toolIDs: AIContextTools.capabilityIDs.union(["list_extensions", "get_lima_status"])
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
        case "memory_save": return "Save memory"
        case "memory_update": return "Revise memory"
        case "memory_forget": return "Forget memory"
        case "edit_text_file": return "Edit a file"
        case "agent_models": return "Subagent models"
        case "agent_delegate": return "Delegate analysis"
        case "read_screen_context": return "Screen context"
        case "search_notes": return "Search Notes"
        case "read_note": return "Read Note"
        case "create_note": return "Create Note"
        case "append_to_note": return "Append to Note"
        case "search_files": return "Find files"
        case "search_workspace_text": return "Search file contents"
        case "inspect_directory_tree": return "Inspect project tree"
        case "read_file": return "Read a file"
        case "list_extensions": return "Browse extensions"
        case "get_lima_status": return "Lima status"
        case "lima_capabilities": return "Tool capabilities"
        case "terminal_start": return "Start AI Workspace"
        case "terminal_run": return "Run Workspace command"
        case "terminal_write": return "Write to Workspace shell"
        case "terminal_status": return "Workspace status"
        case "terminal_read": return "Workspace output"
        case "terminal_wait": return "Wait for command"
        case "terminal_interrupt": return "Interrupt command"
        case "terminal_resize": return "Resize Workspace shell"
        case "terminal_terminate": return "End Workspace shell"
        case "terminal_set_directory": return "Change Workspace directory"
        case "terminal_close": return "Close Workspace session"
        default:
            if let extensionBinding { return "\(extensionBinding.extensionName) · \(extensionBinding.tool.title)" }
            return name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var userSummary: String {
        switch id {
        case "memory_search": return "Read bounded global and current-project context"
        case "memory_save": return "Save one approved, scoped memory entry"
        case "memory_update": return "Revise one approved memory after a freshness check"
        case "memory_forget": return "Remove one approved entry; past provider context remains"
        case "read_screen_context": return "App, window, and selected text"
        case "search_notes": return "Titles and short matching excerpts"
        case "read_note": return "One bounded local note range"
        case "create_note": return "Create one editable Markdown report after review"
        case "append_to_note": return "Append reviewed Markdown if the note has not changed"
        case "search_files", "find_files": return "Names and paths only"
        case "search_workspace_text": return "Bounded text matches with line numbers"
        case "inspect_directory_tree": return "Bounded safe paths to four levels"
        case "list_directory": return "Visible direct children only"
        case "file_metadata": return "Basic file metadata only"
        case "read_file": return "Bounded numbered text ranges"
        case "list_extensions": return "Catalog only, never runs"
        case "get_lima_status": return "Private app details"
        case "browser_focus_tab": return "Select a Lima Browser tab"
        case "browser_activate": return "Activate a Browser link or control"
        case "browser_open_link": return "Open a verified semantic link"
        case "browser_navigate": return "Navigate a Lima Browser tab"
        case "browser_click": return "Click a nonsensitive Browser control"
        case "browser_type": return "Type into a nonsensitive Browser field"
        case "browser_submit": return "Submit an ordinary Browser form"
        case "create_text_file": return "Create a text file"
        case "replace_text_file": return "Replace a text file"
        case "edit_text_file": return "Replace one unique text span"
        case "run_terminal_command": return "Approved developer command outside the sandbox"
        case "terminal_start": return "Create a visible, sandboxed AI-owned session"
        case "terminal_run": return "Run in the sandbox; optionally allow this directory"
        case "terminal_status": return "Read state and verified exit status"
        case "terminal_read": return "Read up to 32 KB of session output"
        case "terminal_wait": return "Wait briefly for verified completion and output"
        case "terminal_interrupt": return "Request command cancellation"
        case "terminal_resize": return "Resize the shared PTY and verify its window size"
        case "terminal_set_directory": return "Switch to an existing Workspace directory"
        case "terminal_close": return "Close an idle session; keep its files"
        default:
            if let extensionBinding { return extensionBinding.tool.description }
            return description
        }
    }

    var symbol: String {
        switch id {
        case "memory_search", "memory_save", "memory_update", "memory_forget": return "brain.head.profile"
        case "agent_models", "agent_delegate": return "person.2"
        case "read_screen_context": return "rectangle.on.rectangle"
        case "search_notes", "read_note": return "note.text"
        case "create_note", "append_to_note": return "square.and.pencil"
        case "search_files", "find_files", "list_directory", "inspect_directory_tree": return "folder"
        case "search_workspace_text": return "text.magnifyingglass"
        case "file_metadata": return "doc.badge.gearshape"
        case "read_file": return "doc.text"
        case "list_extensions": return "square.grid.2x2"
        case "get_lima_status": return "checkmark.shield"
        case "browser_activate", "browser_click", "browser_type", "browser_submit": return "cursorarrow.click"
        case "create_text_file", "replace_text_file", "edit_text_file": return "doc.badge.plus"
        case "run_terminal_command", "terminal_run": return "terminal"
        case "terminal_start": return "terminal.fill"
        case "terminal_status", "terminal_read", "terminal_wait": return "text.alignleft"
        case "terminal_interrupt": return "stop.circle"
        case "terminal_resize": return "arrow.up.left.and.arrow.down.right"
        case "terminal_set_directory": return "folder"
        case "terminal_close": return "xmark.circle"
        default: return BrowserWorkspaceAITools.ids.contains(id) ? "safari" : "eye"
        }
    }
}

enum LimaAIToolAccessMode: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case askForActions
    case fullControl
    case custom

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .askForActions: return "Ask for actions"
        case .fullControl: return "Full Control"
        case .custom: return "Custom (existing choices)"
        }
    }

    var detail: String {
        switch self {
        case .automatic: return "Available tools follow your capability and action settings."
        case .askForActions: return "Use available tools, but ask before computer actions."
        case .fullControl: return "Expose implemented tools without ordinary Lima prompts; final Browser actions and visual clicks still require exact-call review. Browser AI Control and system boundaries apply."
        case .custom: return "Preserve your previous individual tool selections."
        }
    }
}

@MainActor
final class LimaAIToolStore: ObservableObject {
    static let shared = LimaAIToolStore()

    @Published private(set) var enabledToolIDs: Set<String>
    @Published private(set) var accessMode: LimaAIToolAccessMode
    private let defaultsKey = "lima.ai.enabled-native-tools"
    private let accessModeKey = "lima.ai.tool-access-mode"
    private let defaults: UserDefaults?

    private convenience init() {
        self.init(defaults: LimaTestEnvironment.userDefaults)
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let saved = defaults.stringArray(forKey: defaultsKey)
        enabledToolIDs = saved.map(Set.init) ?? LimaAIToolRegistry.defaultEnabledToolIDs
        accessMode = defaults.string(forKey: accessModeKey).flatMap(LimaAIToolAccessMode.init(rawValue:))
            ?? (saved == nil ? .automatic : .custom)
        // Persist the migration decision before the older migrations create a
        // saved tool list; otherwise a fresh Automatic install becomes Custom
        // on its next launch.
        if defaults.string(forKey: accessModeKey) == nil {
            defaults.set(accessMode.rawValue, forKey: accessModeKey)
        }
        // Introduce only these new capabilities once; later explicit off choices remain off.
        let migrationKey = "lima.ai.context-tools-v1"
        if !defaults.bool(forKey: migrationKey) {
            enabledToolIDs.formUnion(AIContextTools.ids)
            defaults.set(Array(enabledToolIDs).sorted(), forKey: defaultsKey)
            defaults.set(true, forKey: migrationKey)
        }
        // Preselect action schemas once. Outside Full Control, category policy
        // remains a separate gate: browser, file, and terminal start Off, while
        // saved-memory writes start reviewable.
        let actionMigrationKey = "lima.ai.computer-actions-v1"
        if !defaults.bool(forKey: actionMigrationKey) {
            enabledToolIDs.formUnion(AILocalComputerActionTools.ids)
            defaults.set(Array(enabledToolIDs).sorted(), forKey: defaultsKey)
            defaults.set(true, forKey: actionMigrationKey)
        }
        // Expose the new precise edit schema in existing custom selections once.
        // The independent Local files action category remains off unless enabled.
        let editTextMigrationKey = "lima.ai.edit-text-file-v1"
        if !defaults.bool(forKey: editTextMigrationKey) {
            enabledToolIDs.insert("edit_text_file")
            defaults.set(Array(enabledToolIDs).sorted(), forKey: defaultsKey)
            defaults.set(true, forKey: editTextMigrationKey)
        }
        // Notes reading remains a selectable capability. Embedded Browser access
        // is governed only by the Browser toolbar, never this saved tool list.
        let readMigrationKey = "lima.ai.browser-notes-read-v1"
        if !defaults.bool(forKey: readMigrationKey) {
            enabledToolIDs.formUnion(AINotesTools.readIDs)
            defaults.set(Array(enabledToolIDs).sorted(), forKey: defaultsKey)
            defaults.set(true, forKey: readMigrationKey)
        }
        let workspaceTerminalMigrationKey = "lima.ai.workspace-terminal-v1"
        if !defaults.bool(forKey: workspaceTerminalMigrationKey) {
            enabledToolIDs.formUnion(AIWorkspaceActionTools.ids)
            defaults.set(Array(enabledToolIDs).sorted(), forKey: defaultsKey)
            defaults.set(true, forKey: workspaceTerminalMigrationKey)
        }
        // Existing custom installations already passed the original Workspace
        // migration; add the new read-only wait once without resetting choices.
        let workspaceWaitMigrationKey = "lima.ai.workspace-terminal-wait-v1"
        if !defaults.bool(forKey: workspaceWaitMigrationKey) {
            enabledToolIDs.insert("terminal_wait")
            defaults.set(Array(enabledToolIDs).sorted(), forKey: defaultsKey)
            defaults.set(true, forKey: workspaceWaitMigrationKey)
        }
        // Make the new PTY actions selectable in existing Custom installations.
        // The independent Terminal category still gates their execution.
        let workspacePTYMigrationKey = "lima.ai.workspace-terminal-pty-v1"
        if !defaults.bool(forKey: workspacePTYMigrationKey) {
            enabledToolIDs.formUnion(["terminal_write", "terminal_terminate"])
            defaults.set(Array(enabledToolIDs).sorted(), forKey: defaultsKey)
            defaults.set(true, forKey: workspacePTYMigrationKey)
        }
        // Make resize available to existing Custom selections without changing
        // the independent Terminal authority or per-action approval behavior.
        let workspaceResizeMigrationKey = "lima.ai.workspace-terminal-resize-v1"
        if !defaults.bool(forKey: workspaceResizeMigrationKey) {
            enabledToolIDs.insert("terminal_resize")
            defaults.set(Array(enabledToolIDs).sorted(), forKey: defaultsKey)
            defaults.set(true, forKey: workspaceResizeMigrationKey)
        }
        // Add bounded, read-only project discovery to existing Custom selections once.
        let workspaceReadMigrationKey = "lima.ai.workspace-read-v1"
        if !defaults.bool(forKey: workspaceReadMigrationKey) {
            enabledToolIDs.formUnion(AIWorkspaceReadTools.ids)
            defaults.set(Array(enabledToolIDs).sorted(), forKey: defaultsKey)
            defaults.set(true, forKey: workspaceReadMigrationKey)
        }
        let projectFilesMigrationKey = "lima.ai.project-files-v1"
        if !defaults.bool(forKey: projectFilesMigrationKey) {
            enabledToolIDs.formUnion(AIProjectTools.ids)
            enabledToolIDs.formUnion(AIProjectFileTools.ids)
            defaults.set(Array(enabledToolIDs).sorted(), forKey: defaultsKey)
            defaults.set(true, forKey: projectFilesMigrationKey)
        }
        // Expose discovery-first Project resolution and same-run questions once.
        let projectDiscoveryMigrationKey = "lima.ai.project-discovery-questions-v1"
        if !defaults.bool(forKey: projectDiscoveryMigrationKey) {
            enabledToolIDs.insert("project_search")
            enabledToolIDs.formUnion(AIUserQuestionTools.ids)
            defaults.set(Array(enabledToolIDs).sorted(), forKey: defaultsKey)
            defaults.set(true, forKey: projectDiscoveryMigrationKey)
        }
        let terminalSessionsMigrationKey = "lima.ai.terminal-sessions-v1"
        if !defaults.bool(forKey: terminalSessionsMigrationKey) {
            enabledToolIDs.insert("terminal_sessions")
            defaults.set(Array(enabledToolIDs).sorted(), forKey: defaultsKey)
            defaults.set(true, forKey: terminalSessionsMigrationKey)
        }
        let workspaceKillMigrationKey = "lima.ai.workspace-terminal-kill-v1"
        if !defaults.bool(forKey: workspaceKillMigrationKey) {
            enabledToolIDs.insert("terminal_kill")
            defaults.set(Array(enabledToolIDs).sorted(), forKey: defaultsKey)
            defaults.set(true, forKey: workspaceKillMigrationKey)
        }
        let workspaceProcessesMigrationKey = "lima.ai.workspace-processes-v1"
        if !defaults.bool(forKey: workspaceProcessesMigrationKey) {
            enabledToolIDs.formUnion(AIProcessTools.ids)
            defaults.set(Array(enabledToolIDs).sorted(), forKey: defaultsKey)
            defaults.set(true, forKey: workspaceProcessesMigrationKey)
        }
        let workbenchUtilityMigrationKey = "lima.ai.workbench-utility-v1"
        if !defaults.bool(forKey: workbenchUtilityMigrationKey) {
            enabledToolIDs.formUnion(AIWorkbenchUtilityTools.ids)
            defaults.set(Array(enabledToolIDs).sorted(), forKey: defaultsKey)
            defaults.set(true, forKey: workbenchUtilityMigrationKey)
        }
        let managedServersMigrationKey = "lima.ai.managed-servers-v1"
        if !defaults.bool(forKey: managedServersMigrationKey) {
            enabledToolIDs.formUnion(AIManagedServerTools.ids)
            defaults.set(Array(enabledToolIDs).sorted(), forKey: defaultsKey)
            defaults.set(true, forKey: managedServersMigrationKey)
        }
        // Retain the old migration marker without adding a second Browser switch.
        let capabilityMigrationKey = "lima.ai.browser-capabilities-v1"
        if !defaults.bool(forKey: capabilityMigrationKey) {
            defaults.set(true, forKey: capabilityMigrationKey)
        }
        // A diagnostic meta-tool must remain discoverable even on installations
        // whose earlier context-tool migration already ran.
        let toolCapabilitiesMigrationKey = "lima.ai.tool-capabilities-v1"
        if !defaults.bool(forKey: toolCapabilitiesMigrationKey) {
            enabledToolIDs.formUnion(AIContextTools.capabilityIDs)
            defaults.set(Array(enabledToolIDs).sorted(), forKey: defaultsKey)
            defaults.set(true, forKey: toolCapabilitiesMigrationKey)
        }
        // Include memory mutations in existing custom lists once. The separate
        // The saved-memory category and active mode still govern writes;
        // preserve later custom opt-outs.
        let memoryWriteMigrationKey = "lima.ai.memory-writes-v1"
        if !defaults.bool(forKey: memoryWriteMigrationKey) {
            enabledToolIDs.formUnion(AIContextTools.memoryWriteIDs)
            defaults.set(Array(enabledToolIDs).sorted(), forKey: defaultsKey)
            defaults.set(true, forKey: memoryWriteMigrationKey)
        }
        // Retire Bridge and provider-web selections. The Browser toolbar is the
        // sole authority, including for installations with legacy saved choices.
        let embeddedBrowserMigrationKey = "lima.ai.embedded-browser-v1"
        if !defaults.bool(forKey: embeddedBrowserMigrationKey) {
            let retiredBrowserToolIDs: Set<String> = [
                "search_web", "read_web", "browser_search_web", "browser_open_tabs",
                "browser_navigate_tab", "salesforce_read_case_links",
                "salesforce_resolve_case", "salesforce_resolve_cases"
            ]
            enabledToolIDs.subtract(retiredBrowserToolIDs.union(BrowserWorkspaceAITools.ids))
            defaults.set(Array(enabledToolIDs).sorted(), forKey: defaultsKey)
            defaults.set(true, forKey: embeddedBrowserMigrationKey)
        }
    }

    init(fixtures: Set<String>, accessMode: LimaAIToolAccessMode = .custom) {
        defaults = nil
        enabledToolIDs = fixtures
        self.accessMode = accessMode
    }

    var effectiveEnabledToolIDs: Set<String> {
        switch accessMode {
        case .custom: return enabledToolIDs.union(BrowserWorkspaceAITools.ids)
        case .fullControl: return Set(LimaAIToolRegistry.validDefinitions.map(\.id))
        case .automatic, .askForActions: return Set(LimaAIToolRegistry.validDefinitions.map(\.id))
        }
    }

    func setAccessMode(_ mode: LimaAIToolAccessMode) {
        guard accessMode != mode else { return }
        let leavingFullControl = accessMode == .fullControl && mode != .fullControl
        accessMode = mode
        defaults?.set(mode.rawValue, forKey: accessModeKey)
        if leavingFullControl && self === Self.shared {
            AIWorkspaceTerminalCoordinator.shared.revokeNetworkSessions()
        }
    }

    func isEnabled(_ definition: LimaAIToolDefinition) -> Bool {
        effectiveEnabledToolIDs.contains(definition.id)
    }

    func isEnabled(_ group: LimaAIToolGroup) -> Bool {
        !group.toolIDs.isEmpty && group.toolIDs.isSubset(of: effectiveEnabledToolIDs)
    }

    func setEnabled(_ definition: LimaAIToolDefinition, enabled: Bool) {
        guard !BrowserWorkspaceAITools.ids.contains(definition.id) else { return }
        setAccessMode(.custom)
        if enabled { enabledToolIDs.insert(definition.id) }
        else { enabledToolIDs.remove(definition.id) }
        persist()
    }

    func setEnabled(_ group: LimaAIToolGroup, enabled: Bool) {
        guard group.toolIDs.isDisjoint(with: BrowserWorkspaceAITools.ids) else { return }
        setAccessMode(.custom)
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
            return [.textDone]
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
        case "response.function_call_arguments.delta":
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
        if item.kind == .message && phase == .completed {
            // Some providers omit output_text.done but complete the message item.
            events.append(.textDone)
        }
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
        if attachment.kind == .pastedText { return (try? AIPastedTextStore.providerText(for: attachment)) != nil }
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
        case .pastedText:
            return false
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
            case .pastedText:
                let value = try AIPastedTextStore.providerText(for: attachment)
                content.append(["type": "input_text", "text": "[Pasted Text]\n\(value)"])
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

    @State private var renderTree: LimaMarkdownRenderTree?

    var body: some View {
        Group {
            if let renderTree, renderTree.source == markdown {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(renderTree.blocks.enumerated()), id: \.offset) { _, block in
                        markdownBlock(block)
                    }
                }
            } else {
                Text(markdown)
                    .foregroundStyle(LimaTheme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: markdown) {
            renderTree = await LimaMarkdownRenderService.shared.renderTree(for: markdown)
        }
    }

    @ViewBuilder
    private func markdownBlock(_ block: LimaMarkdownRenderTree.Block) -> some View {
        switch block {
        case .paragraph(let value):
            inlineText(value)
                .foregroundStyle(LimaTheme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let value):
            inlineText(value)
                .font(headingFont(for: level))
                .foregroundStyle(LimaTheme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level == 1 ? 4 : 1)
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        listMarker(item, index: index + start - 1, ordered: ordered)
                            .frame(width: ordered ? 22 : 14, alignment: .trailing)
                            .foregroundStyle(LimaTheme.textSecondary)
                        inlineText(item)
                            .foregroundStyle(LimaTheme.textPrimary)
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
                    .foregroundStyle(LimaTheme.textPrimary)
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
        case .literal(let value):
            Text(value)
                .foregroundStyle(LimaTheme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inlineText(_ value: AttributedString) -> Text { Text(value) }

    @ViewBuilder
    private func listMarker(_ item: AttributedString, index: Int, ordered: Bool) -> some View {
        let trimmed = String(item.characters).trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[ ]") {
            Image(systemName: "square")
        } else if trimmed.lowercased().hasPrefix("[x]") {
            Image(systemName: "checkmark.square.fill")
        } else {
            Text(ordered ? "\(index + 1)." : "•")
                .limaFont(.body.weight(.medium))
        }
    }

    private func tableRow(_ cells: [AttributedString], header: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                inlineText(cell)
                    .limaFont(.callout.weight(header ? .semibold : .regular))
                    .foregroundStyle(LimaTheme.textPrimary)
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

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return .title2.weight(.semibold)
        case 2: return .title3.weight(.semibold)
        default: return .headline
        }
    }
}

struct AIMarkdownView: View {
    let markdown: String

    var body: some View {
        LimaMarkdownDocumentView(markdown: markdown)
    }

}

struct AIToolApprovalView: View {
    let request: AIToolApprovalRequest
    let allow: () -> Void
    let allowDirectory: () -> Void
    let deny: () -> Void
    @State private var showingFullRequest = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: isPaymentReview ? "creditcard" : "hand.raised.fill")
                    .foregroundStyle(LimaColors.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isPaymentReview ? "Payment review required" : "Review tool request")
                        .limaFont(.callout.weight(.semibold))
                    Text("\(request.serverLabel) · \(request.toolName)")
                        .limaFont(.caption)
                        .foregroundStyle(LimaColors.secondaryText)
                }
                Spacer()
            }

            Text(request.browserReviewSummary ?? requestSummary)
                .limaFont(.caption)
                .foregroundStyle(LimaColors.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            if isPaymentReview {
                Text("Automatic approval never covers payments. Check the current Browser page and terms before confirming this exact action.")
                    .limaFont(.caption2)
                    .foregroundStyle(LimaColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let directory = request.directoryGrantPath {
                Text("Directory scope: \(directory)")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(LimaColors.secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

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

            VStack(alignment: .leading, spacing: 7) {
                Text(isPaymentReview
                     ? "Confirm Financial Action permits only this reviewed action. It does not verify that payment or booking succeeded."
                     : request.directoryGrantPath == nil
                        ? "Allow Once runs only this request; its result appears in Activity."
                        : "Allow Once runs only this command. Allow in Directory permits later commands in this session's current sandboxed directory until revoked, changed, or closed.")
                    .limaFont(.caption2)
                    .foregroundStyle(LimaColors.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Deny", action: deny)
                    if request.directoryGrantPath != nil {
                        Button("Allow in Directory", action: allowDirectory)
                            .help("Allow later commands only in this AI Workspace session's current directory; revoke from AI Terminal")
                    }
                    Button(isPaymentReview ? "Confirm Financial Action" : "Allow Once", action: allow)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(12)
        .limaGlassContainer(region: .hud, cornerRadius: 10)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(LimaColors.warning.opacity(0.55), lineWidth: 1))
        .onAppear {
            let toolID = request.localToolID ?? request.toolName
            showingFullRequest = AIContextTools.memoryWriteIDs.contains(toolID) ||
                AINotesTools.writeIDs.contains(toolID) ||
                NativeCapabilityAITools.ids.contains(toolID)
        }
    }

    private var isPaymentReview: Bool { request.browserPaymentReview == true }

    private var requestSummary: String {
        let arguments = decodedArguments
        let toolID = request.localToolID ?? request.toolName
        if NativeCapabilityAITools.ids.contains(toolID) {
            return nativeCapabilitySummary(toolID, arguments: arguments)
        }
        switch toolID {
        case "browser_new_tab":
            return "Create a Lima Browser tab\(host(arguments["url"] as? String).map { " at \($0)" } ?? "")."
        case "browser_activate":
            return "Activate the requested Browser link or control."
        case "browser_open_link":
            return "Open a verified semantic link in the Lima Browser."
        case "browser_focus_tab":
            return "Select the requested Lima Browser tab."
        case "browser_navigate":
            return "Navigate a Lima Browser tab to \(host(arguments["url"] as? String) ?? "the requested site")."
        case "browser_click":
            return "Click the requested nonsensitive Browser control."
        case "browser_type":
            let count = (arguments["text"] as? String)?.count ?? 0
            return "Type \(count) character\(count == 1 ? "" : "s") into the requested nonsensitive Browser field."
        case "browser_submit":
            return "Submit the requested ordinary Browser form."
        case "create_note":
            let title = compactQuoted(arguments["title"] as? String) ?? "an untitled note"
            return "Create editable Note \(title) with \(characterCount(arguments["content"])) characters of Markdown. Review the full content below."
        case "append_to_note":
            let target = compactQuoted(arguments["note_id"] as? String) ?? "the selected note"
            return "Append \(characterCount(arguments["content"])) characters of Markdown to Note \(target), only if it has not changed. Review the full content below."
        case "memory_save":
            let title = compactQuoted(arguments["title"] as? String) ?? "a new entry"
            let scope = arguments["scope"] as? String ?? "selected"
            let preview = compactQuoted(arguments["content"] as? String) ?? "empty content"
            return "Save \(title) as \(scope) memory. Content: \(preview)."
        case "memory_update":
            let currentTitle = compactQuoted(arguments["expected_title"] as? String) ?? "the selected entry"
            let newTitle = compactQuoted(arguments["title"] as? String) ?? "an untitled entry"
            let preview = compactQuoted(arguments["content"] as? String) ?? "empty content"
            return "Revise saved memory \(currentTitle) to \(newTitle). New content: \(preview)."
        case "memory_forget":
            let title = compactQuoted(arguments["expected_title"] as? String) ?? "the selected entry"
            return "Forget saved memory \(title). Context already sent to a provider cannot be retracted."
        case "create_text_file":
            return "Create \(quoted(arguments["path"] as? String) ?? "the requested file") with \(characterCount(arguments["content"])) character\(characterCount(arguments["content"]) == 1 ? "" : "s")."
        case "replace_text_file":
            return "Replace \(quoted(arguments["path"] as? String) ?? "the requested file") with \(characterCount(arguments["content"])) character\(characterCount(arguments["content"]) == 1 ? "" : "s")."
        case "edit_text_file":
            return "Edit \(compactQuoted(arguments["path"] as? String) ?? "the requested file") by replacing one exact \(characterCount(arguments["old_text"]))‑character span with \(characterCount(arguments["new_text"])) characters. Review the exact text below."
        case "run_terminal_command":
            let command = compactQuoted(arguments["command"] as? String) ?? "the requested command"
            let directory = arguments["working_directory"] as? String
            return directory.map { "Run \(command) in \(compactQuoted($0) ?? "the selected directory") and show output in Terminal. This compatibility command is not sandboxed." }
                ?? "Run \(command) and show output in Terminal. This compatibility command is not sandboxed."
        case "terminal_start":
            let directory = compactQuoted(arguments["directory"] as? String)
            if let projectID = compactQuoted(arguments["project_id"] as? String) {
                return "Start a visible sandboxed AI terminal session in Project \(projectID)\(directory.map { " at \($0)" } ?? "")."
            }
            return "Start a visible sandboxed AI terminal session in temporary Scratch work."
        case "terminal_run":
            let command = compactQuoted(arguments["command"] as? String) ?? "the requested command"
            if let directory = request.directoryGrantPath {
                return "Run \(command) in \(compactQuoted(directory) ?? "the current directory"). You can allow only this command or future commands in this session and directory."
            }
            return "Run \(command) in the sandboxed AI Workspace. Review the full command before allowing."
        case "terminal_set_directory":
            return "Move the AI session to \(compactQuoted(arguments["directory"] as? String) ?? "the requested Workspace directory")."
        case "terminal_interrupt":
            return "Stop the running AI Workspace command; check its final status afterward."
        case "terminal_close":
            return "Close the idle AI terminal session. Workspace files are not deleted."
        default:
            return "Review the complete request before allowing this tool to run."
        }
    }

    private func nativeCapabilitySummary(_ toolID: String,
                                         arguments: [String: Any]) -> String {
        switch toolID {
        case "screenshot_list": return "List saved screenshot metadata, not image pixels."
        case "screenshot_search":
            return "Search saved screenshots for \(compactQuoted(arguments["query"] as? String) ?? "the requested text"), including local OCR text."
        case "screenshot_info":
            return "Read metadata for saved screenshot \(compactQuoted(arguments["id"] as? String) ?? "the requested ID")."
        case "screenshot_copy":
            return "Copy saved screenshot \(compactQuoted(arguments["id"] as? String) ?? "the requested ID") as image data to the clipboard."
        case "screenshot_delete":
            return "Permanently delete saved screenshot \(compactQuoted(arguments["id"] as? String) ?? "the requested ID") and its thumbnail."
        case "audio_list_outputs": return "List connected system audio output devices."
        case "audio_get_output": return "Read the current system default audio output."
        case "audio_set_output":
            return "Switch the system default audio output to UID \(compactQuoted(arguments["uid"] as? String) ?? "the requested device") and verify it."
        case "audio_get_volume": return "Read the current system output volume."
        case "audio_set_volume":
            return "Set the system output volume to \(arguments["percent"] ?? "the requested value")% and verify it."
        case "audio_toggle_mute": return "Toggle the system output mute state and verify it."
        default: return "Review this exact native service call before allowing it."
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

    private func quoted(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return "“\(value)”"
    }

    private func compactQuoted(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let visible = value.replacingOccurrences(of: "\r\n", with: " ⏎ ")
            .replacingOccurrences(of: "\n", with: " ⏎ ")
            .replacingOccurrences(of: "\r", with: " ⏎ ")
            .replacingOccurrences(of: "\t", with: " ⇥ ")
        let excerpt = String(visible.prefix(120))
        return "“\(excerpt)\(visible.count > 120 ? "…" : "")”"
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
            VStack(alignment: .leading, spacing: 5) {
                Label("Ready to send with your next AI message", systemImage: "arrow.right.circle")
                    .limaFont(.caption2.weight(.medium))
                    .foregroundStyle(LimaTheme.textSecondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachments) { attachment in
                            HStack(spacing: 6) {
                                Image(systemName: attachment.kind.symbol)
                                    .foregroundStyle(LimaTheme.accentInk)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(attachment.transferRoute)
                                        .foregroundStyle(LimaTheme.accentInk)
                                        .lineLimit(1)
                                    Text(attachment.displayName).lineLimit(1)
                                    if let summary = attachment.metadataSummary {
                                        Text(summary).foregroundStyle(LimaTheme.textSecondary).lineLimit(1)
                                    }
                                }
                                Button { remove(attachment) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Remove \(attachment.displayName) from AI draft")
                            }
                            .limaFont(.caption)
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .background(LimaColors.accentSoft, in: RoundedRectangle(cornerRadius: LimaRadius.control))
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
    }
}
