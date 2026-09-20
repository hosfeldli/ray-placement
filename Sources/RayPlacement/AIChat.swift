import AppKit
import Combine
import Foundation
import Security
import SwiftUI

extension Notification.Name {
    static let limaOpenAIMCPManager = Notification.Name("Lima.openAIMCPManager")
}

enum AIChatRole: String, Codable, Sendable {
    case user
    case assistant
}

struct AIChatMessage: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var role: AIChatRole
    var text: String
    var createdAt: Date
    var responseID: String?

    init(
        id: UUID = UUID(),
        role: AIChatRole,
        text: String,
        createdAt: Date = Date(),
        responseID: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.responseID = responseID
    }
}

struct AIConversation: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var model: String
    var lastResponseID: String?
    var reasoningEffort: AIReasoningEffort
    var reasoningSummary: String?
    var activities: [AIAgentActivity]
    var attachments: [AIAttachment]
    var messages: [AIChatMessage]

    init(
        id: UUID = UUID(),
        title: String = "New Chat",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        model: String = "gpt-5",
        lastResponseID: String? = nil,
        reasoningEffort: AIReasoningEffort = .medium,
        reasoningSummary: String? = nil,
        activities: [AIAgentActivity] = [],
        attachments: [AIAttachment] = [],
        messages: [AIChatMessage] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.model = model
        self.lastResponseID = lastResponseID
        self.reasoningEffort = reasoningEffort
        self.reasoningSummary = reasoningSummary
        self.activities = activities
        self.attachments = attachments
        self.messages = messages
    }

    var preview: String {
        messages.last?.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(92)
            .description ?? "No messages yet"
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, model, lastResponseID
        case reasoningEffort, reasoningSummary, activities, attachments, messages
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        model = try values.decode(String.self, forKey: .model)
        lastResponseID = try values.decodeIfPresent(String.self, forKey: .lastResponseID)
        reasoningEffort = try values.decodeIfPresent(AIReasoningEffort.self, forKey: .reasoningEffort) ?? .medium
        reasoningSummary = try values.decodeIfPresent(String.self, forKey: .reasoningSummary)
        activities = try values.decodeIfPresent([AIAgentActivity].self, forKey: .activities) ?? []
        attachments = try values.decodeIfPresent([AIAttachment].self, forKey: .attachments) ?? []
        messages = try values.decodeIfPresent([AIChatMessage].self, forKey: .messages) ?? []
    }
}

@MainActor
final class AIChatCredentialStore: ObservableObject {
    static let shared = AIChatCredentialStore()

    @Published private(set) var hasAPIKey = false

    private let service = "dev.liam.lima.ai"
    private let account = "openai-api-key"

    private init() {
        refresh()
    }

    func saveAPIKey(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw NSError(
                domain: "LimaAI",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Enter an OpenAI API key."]
            )
        }

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            let update = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: Data(key.utf8)] as CFDictionary
            )
            guard update == errSecSuccess else { throw keychainError(update) }
        } else if status != errSecSuccess {
            throw keychainError(status)
        }
        hasAPIKey = true
    }

    func apiKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func removeAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        hasAPIKey = false
    }

    func refresh() {
        hasAPIKey = apiKey()?.isEmpty == false
    }

    private func keychainError(_ status: OSStatus = errSecAuthFailed) -> NSError {
        NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "Lima could not access the OpenAI API key in Keychain."]
        )
    }
}

@MainActor
final class AIConversationStore: ObservableObject {
    static let shared = AIConversationStore()

    static let maximumConversations = 200
    static let maximumCharactersPerConversation = 1_000_000

    @Published private(set) var conversations: [AIConversation] = []
    @Published private(set) var lastError: String?

    private let persistenceQueue = DispatchQueue(label: "dev.liam.lima.ai-chat-persistence", qos: .utility)
    private var pendingSave: DispatchWorkItem?

    private init() {
        load()
    }

    func conversation(id: UUID) -> AIConversation? {
        conversations.first { $0.id == id }
    }

    @discardableResult
    func createConversation(model: String) -> AIConversation {
        let conversation = AIConversation(model: model)
        conversations.insert(conversation, at: 0)
        scheduleSave()
        return conversation
    }

    func update(_ conversation: AIConversation) {
        guard conversation.messages.reduce(0, { $0 + $1.text.count }) <= Self.maximumCharactersPerConversation else {
            lastError = "This chat has reached Lima’s local storage limit."
            return
        }
        conversations.removeAll { $0.id == conversation.id }
        conversations.insert(conversation, at: 0)
        conversations = Array(conversations.prefix(Self.maximumConversations))
        scheduleSave()
    }

    func delete(id: UUID) {
        conversations.removeAll { $0.id == id }
        scheduleSave()
    }

    private func load() {
        let url = storageURL
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            conversations = try JSONDecoder().decode([AIConversation].self, from: data)
                .filter { $0.messages.reduce(0, { $0 + $1.text.count }) <= Self.maximumCharactersPerConversation }
                .prefix(Self.maximumConversations)
                .map { $0 }
        } catch {
            lastError = "AI chat history could not be loaded. The existing file was left in place."
        }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let snapshot = conversations
        let url = storageURL
        let work = DispatchWorkItem { [weak self] in
            do {
                try Self.persist(snapshot, to: url)
                DispatchQueue.main.async { self?.lastError = nil }
            } catch {
                DispatchQueue.main.async { self?.lastError = error.localizedDescription }
            }
        }
        pendingSave = work
        persistenceQueue.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private var storageURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("Lima", isDirectory: true)
            .appendingPathComponent("AI", isDirectory: true)
            .appendingPathComponent("conversations.json")
    }

    private nonisolated static func persist(_ conversations: [AIConversation], to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try JSONEncoder().encode(conversations)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum AIChatStreamEvent: Sendable {
    case responseCreated(String)
    case textDelta(String)
    case reasoningSummaryDelta(String)
    case activity(AIAgentActivity)
    case approval(AIToolApprovalRequest)
    case usage(AIUsageMetrics)
    case completed(String?)
    case failed(String)
}

struct AIChatResponsesClient {
    enum ClientError: LocalizedError {
        case invalidResponse
        case requestFailed(Int, String)
        case malformedStream
        case noModelsFound

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "The AI service returned an invalid response."
            case .requestFailed(let status, let message):
                return "OpenAI request failed (\(status)): \(message)"
            case .malformedStream:
                return "The AI response stream could not be read."
            case .noModelsFound:
                return "OpenAI returned no chat-capable models for this API key."
            }
        }
    }

    func listModels(apiKey: String) async throws -> [AIModelOption] {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw ClientError.requestFailed(http.statusCode, Self.safeErrorMessage(from: data))
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawModels = object["data"] as? [[String: Any]] else {
            throw ClientError.noModelsFound
        }
        let options = rawModels.compactMap { raw -> AIModelOption? in
            guard let id = raw["id"] as? String, AIModelOption.isChatModel(id) else { return nil }
            return AIModelOption(id: id)
        }
        let unique = Dictionary(options.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard !unique.isEmpty else { throw ClientError.noModelsFound }
        return unique.values.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func streamReply(
        apiKey: String,
        model: String,
        input: String,
        previousResponseID: String?,
        reasoningEffort: AIReasoningEffort,
        attachments: [AIAttachment],
        mcpServers: [MCPServer]
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        do {
            let inputContent = try AIInputEncoder.content(text: input, attachments: attachments)
            let userInput: [String: Any] = ["role": "user", "content": inputContent]
            let body = Self.replyBody(
                model: model,
                input: [userInput],
                previousResponseID: previousResponseID,
                reasoningEffort: reasoningEffort,
                tools: mcpToolPayload(for: mcpServers)
            )
            return stream(body: body, apiKey: apiKey)
        } catch {
            return AsyncThrowingStream { continuation in
                continuation.yield(.failed(error.localizedDescription))
                continuation.finish(throwing: error)
            }
        }
    }

    func streamApproval(
        apiKey: String,
        model: String,
        previousResponseID: String,
        requestID: String,
        approve: Bool,
        reason: String?,
        reasoningEffort: AIReasoningEffort,
        mcpServers: [MCPServer]
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        var approval: [String: Any] = [
            "type": "mcp_approval_response",
            "approval_request_id": requestID,
            "approve": approve
        ]
        if let reason, !reason.isEmpty { approval["reason"] = reason }
        let body = Self.replyBody(
            model: model,
            input: [approval],
            previousResponseID: previousResponseID,
            reasoningEffort: reasoningEffort,
            tools: mcpToolPayload(for: mcpServers)
        )
        return stream(body: body, apiKey: apiKey)
    }

    static func replyBody(
        model: String,
        input: [[String: Any]],
        previousResponseID: String?,
        reasoningEffort: AIReasoningEffort,
        tools: [[String: Any]]
    ) -> [String: Any] {
        let option = AIModelOption(id: model)
        var body: [String: Any] = [
            "model": model,
            "input": input,
            "stream": true,
            "store": true
        ]
        if option.supportsReasoning {
            let effort = option.supportedReasoningEfforts.contains(reasoningEffort)
                ? reasoningEffort
                : (option.supportedReasoningEfforts.last ?? .medium)
            body["reasoning"] = ["effort": effort.rawValue, "summary": "auto"]
        }
        if !tools.isEmpty { body["tools"] = tools }
        if let previousResponseID, !previousResponseID.isEmpty {
            body["previous_response_id"] = previousResponseID
        }
        return body
    }

    private func mcpToolPayload(for servers: [MCPServer]) -> [[String: Any]] {
        servers.filter(\.enabled).compactMap { server in
            let enabledTools = server.enabledTools
            guard !enabledTools.isEmpty, server.validHTTPURL != nil else { return nil }
            var tool: [String: Any] = [
                "type": "mcp",
                "server_label": server.apiLabel,
                "server_url": server.validHTTPURL?.absoluteString ?? server.url,
                "allowed_tools": enabledTools.map(\.name)
            ]
            let readTools = enabledTools.filter { !$0.risk.requiresApproval }.map(\.name)
            if readTools.isEmpty {
                tool["require_approval"] = "always"
            } else {
                tool["require_approval"] = ["never": ["tool_names": readTools]]
            }
            if let credential = MCPCredentialStore.value(serverID: server.id), !credential.isEmpty {
                tool["headers"] = ["Authorization": MCPCredentialStore.authorizationHeaderValue(credential)]
            }
            return tool
        }
    }

    private func stream(
        body: [String: Any],
        apiKey: String
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.timeoutInterval = 120
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
                    guard (200...299).contains(http.statusCode) else {
                        var errorText = ""
                        for try await line in bytes.lines {
                            errorText += line
                            if errorText.count > 2_000 { break }
                        }
                        throw ClientError.requestFailed(http.statusCode, Self.safeErrorMessage(from: Data(errorText.utf8)))
                    }

                    var eventType = ""
                    var dataLines: [String] = []
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        if line.isEmpty {
                            try emit(eventType: eventType, dataLines: dataLines, continuation: continuation)
                            eventType = ""
                            dataLines = []
                        } else if line.hasPrefix("event:") {
                            eventType = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
                        }
                    }
                    try emit(eventType: eventType, dataLines: dataLines, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(error.localizedDescription))
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func safeErrorMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(decoding: data.prefix(1_000), as: UTF8.self)
        }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return (object["message"] as? String) ?? "The provider returned an error."
    }

    private func emit(
        eventType: String,
        dataLines: [String],
        continuation: AsyncThrowingStream<AIChatStreamEvent, Error>.Continuation
    ) throws {
        let data = dataLines.joined(separator: "\n")
        guard !data.isEmpty, data != "[DONE]" else { return }
        guard let payload = data.data(using: .utf8),
              let value = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw ClientError.malformedStream
        }
        let type = (value["type"] as? String) ?? eventType
        switch type {
        case "response.created":
            let response = value["response"] as? [String: Any]
            if let id = response?["id"] as? String { continuation.yield(.responseCreated(id)) }
        case "response.output_text.delta":
            if let delta = value["delta"] as? String { continuation.yield(.textDelta(delta)) }
        case "response.reasoning_summary_text.delta", "response.reasoning_summary.delta":
            if let delta = value["delta"] as? String { continuation.yield(.reasoningSummaryDelta(delta)) }
        case "response.reasoning_summary_part.added":
            if let part = value["part"] as? [String: Any], let text = part["text"] as? String {
                continuation.yield(.reasoningSummaryDelta(text))
            }
        case "response.output_item.added":
            if let item = value["item"] as? [String: Any], let itemType = item["type"] as? String, itemType.contains("mcp") || itemType.contains("tool") {
                let name = (item["name"] as? String) ?? "Tool call"
                continuation.yield(.activity(AIAgentActivity(kind: .toolStarted, title: name, detail: item["server_label"] as? String)))
            }
            if let item = value["item"] as? [String: Any], (item["type"] as? String) == "mcp_approval_request" {
                let request = AIToolApprovalRequest(
                    remoteApprovalID: item["id"] as? String ?? item["approval_request_id"] as? String,
                    serverLabel: item["server_label"] as? String ?? "Remote MCP",
                    toolName: item["name"] as? String ?? item["tool_name"] as? String ?? "MCP tool",
                    arguments: item["arguments"] as? String
                )
                continuation.yield(.approval(request))
            }
        case "response.mcp_call.arguments.delta", "response.mcp_call_arguments.delta":
            break
        case "response.mcp_call.completed", "response.mcp_call.done":
            if let item = value["item"] as? [String: Any] {
                continuation.yield(.activity(AIAgentActivity(kind: .toolCompleted, title: item["name"] as? String ?? "Tool call", completed: true)))
            } else {
                continuation.yield(.activity(AIAgentActivity(kind: .toolCompleted, title: value["name"] as? String ?? "Tool call", completed: true)))
            }
        case "response.mcp_call.failed", "response.mcp_call.error":
            let detail = (value["error"] as? [String: Any])?["message"] as? String
                ?? value["error"] as? String
                ?? "The MCP tool failed."
            continuation.yield(.activity(AIAgentActivity(kind: .toolFailed, title: "MCP tool failed", detail: detail, completed: true)))
        case "response.output_item.done":
            if let item = value["item"] as? [String: Any], let itemType = item["type"] as? String, itemType.contains("mcp") || itemType.contains("tool") {
                let name = (item["name"] as? String) ?? "Tool call"
                if let error = item["error"] as? [String: Any] {
                    continuation.yield(.activity(AIAgentActivity(kind: .toolFailed, title: name, detail: error["message"] as? String, completed: true)))
                } else {
                    continuation.yield(.activity(AIAgentActivity(kind: .toolCompleted, title: name, completed: true)))
                }
            }
        case "response.reasoning_summary_text.done", "response.reasoning_summary_part.done":
            break
        case "response.completed":
            if let response = value["response"] as? [String: Any], let usage = response["usage"] as? [String: Any] {
                continuation.yield(.usage(AIUsageMetrics.from(responseUsage: usage)))
            }
            let response = value["response"] as? [String: Any]
            continuation.yield(.completed(response?["id"] as? String))
        case "error", "response.failed":
            let detail = (value["error"] as? [String: Any])?["message"] as? String
                ?? (value["message"] as? String)
                ?? "The AI request failed."
            continuation.yield(.failed(detail))
        default:
            break
        }
    }
}

@MainActor
final class AIChatViewModel: ObservableObject {
    @Published private(set) var selectedConversationID: UUID?
    @Published var draft = ""
    @Published var model = "gpt-5"
    @Published var reasoningEffort: AIReasoningEffort = .medium
    @Published private(set) var availableModels: [AIModelOption] = AIModelOption.fallbackModels
    @Published private(set) var isLoadingModels = false
    @Published var attachments: [AIAttachment] = []
    @Published var showActivity = true
    @Published private(set) var isStreaming = false
    @Published private(set) var streamError: String?
    @Published private(set) var pendingApproval: AIToolApprovalRequest?

    let store: AIConversationStore
    let credentials: AIChatCredentialStore
    private var streamTask: Task<Void, Never>?

    init() {
        store = .shared
        credentials = .shared
        selectedConversationID = store.conversations.first?.id
        if let selected = store.conversations.first {
            model = selected.model
            reasoningEffort = selected.reasoningEffort
            attachments = selected.attachments
        }
        ensureModelIsAvailable()
    }

    deinit { streamTask?.cancel() }

    var selectedConversation: AIConversation? {
        selectedConversationID.flatMap(store.conversation(id:))
    }

    func select(_ id: UUID) {
        selectedConversationID = id
        if let conversation = store.conversation(id: id) {
            model = conversation.model
            reasoningEffort = conversation.reasoningEffort
            attachments = conversation.attachments
            ensureModelIsAvailable()
        }
    }

    var selectedModelOption: AIModelOption {
        availableModels.first(where: { $0.id == model }) ?? AIModelOption(id: model)
    }

    var supportedReasoningEfforts: [AIReasoningEffort] {
        selectedModelOption.supportedReasoningEfforts
    }

    func refreshModels() {
        guard !isLoadingModels else { return }
        guard let apiKey = credentials.apiKey(), !apiKey.isEmpty else {
            streamError = "Save an OpenAI API key before loading available models."
            return
        }
        isLoadingModels = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isLoadingModels = false }
            do {
                let models = try await AIChatResponsesClient().listModels(apiKey: apiKey)
                self.availableModels = models
                self.ensureModelIsAvailable()
            } catch {
                self.streamError = error.localizedDescription
            }
        }
    }

    func selectModel(_ option: AIModelOption) {
        model = option.id
        if !option.supportedReasoningEfforts.contains(reasoningEffort) {
            reasoningEffort = option.supportedReasoningEfforts.last ?? .medium
        }
        if let id = selectedConversationID, var conversation = store.conversation(id: id) {
            conversation.model = model
            conversation.reasoningEffort = reasoningEffort
            store.update(conversation)
        }
    }

    func selectReasoningEffort(_ effort: AIReasoningEffort) {
        guard selectedModelOption.supportedReasoningEfforts.contains(effort) else { return }
        reasoningEffort = effort
        if let id = selectedConversationID, var conversation = store.conversation(id: id) {
            conversation.reasoningEffort = effort
            store.update(conversation)
        }
    }

    private func ensureModelIsAvailable() {
        if !availableModels.contains(where: { $0.id == model }), let first = availableModels.first {
            model = first.id
        }
        if !selectedModelOption.supportedReasoningEfforts.contains(reasoningEffort) {
            reasoningEffort = selectedModelOption.supportedReasoningEfforts.last ?? .medium
        }
    }

    func newConversation() {
        let conversation = store.createConversation(model: model)
        selectedConversationID = conversation.id
        streamError = nil
        draft = ""
    }

    func deleteSelectedConversation() {
        guard let selectedConversationID else { return }
        store.delete(id: selectedConversationID)
        self.selectedConversationID = store.conversations.first?.id
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        guard let apiKey = credentials.apiKey(), !apiKey.isEmpty else {
            streamError = "Add an OpenAI API key in the setup panel before sending a message."
            return
        }

        var conversation = selectedConversation ?? store.createConversation(model: model)
        selectedConversationID = conversation.id
        conversation.model = model
        conversation.messages.append(AIChatMessage(role: .user, text: text))
        if conversation.title == "New Chat" {
            conversation.title = String(text.prefix(64))
        }
        conversation.updatedAt = Date()

        conversation.reasoningEffort = reasoningEffort
        conversation.attachments = attachments
        conversation.activities = [AIAgentActivity(kind: .started, title: "Started", completed: false)]
        conversation.reasoningSummary = nil
        let assistantID = UUID()
        conversation.messages.append(AIChatMessage(id: assistantID, role: .assistant, text: ""))
        store.update(conversation)
        draft = ""
        streamError = nil
        pendingApproval = nil
        isStreaming = true

        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            var responseID: String?
            let stream = AIChatResponsesClient().streamReply(
                apiKey: apiKey,
                model: self.model,
                input: text,
                previousResponseID: conversation.lastResponseID,
                reasoningEffort: conversation.reasoningEffort,
                attachments: conversation.attachments,
                mcpServers: MCPServerStore.shared.servers.filter(\.enabled)
            )
            do {
                for try await event in stream {
                    guard !Task.isCancelled else { return }
                    self.apply(event, conversationID: conversation.id, assistantID: assistantID, responseID: &responseID)
                }
            } catch {
                if !Task.isCancelled, self.streamError == nil {
                    self.streamError = error.localizedDescription
                }
            }
            self.finishStream(conversationID: conversation.id, assistantID: assistantID, responseID: responseID)
        }
    }

    func cancel() {
        streamTask?.cancel()
        streamTask = nil
        pendingApproval = nil
        if let id = selectedConversationID {
            updateConversation(id) { $0.activities.append(AIAgentActivity(kind: .completed, title: "Stopped", detail: "Generation stopped by user", completed: true)) }
        }
        isStreaming = false
    }

    func add(_ attachment: AIAttachment) {
        guard !attachments.contains(where: { $0.id == attachment.id }) else { return }
        attachments.append(attachment)
    }

    func remove(_ attachment: AIAttachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.item]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { add(AIContextCapture.attachment(for: url)) }
    }

    func addClipboard() {
        if let attachment = AIContextCapture.clipboardAttachment() { add(attachment) }
    }

    func addSelection() {
        if let attachment = AIContextCapture.selectionAttachment() { add(attachment) }
        else { streamError = "No readable selection was found in the previous app. Accessibility access may be required." }
    }

    func openMCPManager() {
        NotificationCenter.default.post(name: .limaOpenAIMCPManager, object: nil)
    }

    func dismissPendingApproval() {
        pendingApproval = nil
    }

    func resolvePendingApproval(allow: Bool) {
        guard let approval = pendingApproval,
              let remoteApprovalID = approval.remoteApprovalID,
              let conversation = selectedConversation,
              let previousResponseID = conversation.lastResponseID,
              let apiKey = credentials.apiKey(), !apiKey.isEmpty else {
            pendingApproval = nil
            streamError = "The MCP approval could not be continued because the response session is unavailable."
            return
        }

        pendingApproval = nil
        updateConversation(conversation.id) {
            $0.activities.append(AIAgentActivity(
                kind: .toolApproval,
                title: allow ? "Tool allowed once" : "Tool denied",
                detail: "\(approval.serverLabel) · \(approval.toolName)",
                requiresApproval: true,
                completed: true
            ))
        }

        let assistantID: UUID
        if let existing = conversation.messages.last(where: { $0.role == .assistant }) {
            assistantID = existing.id
        } else {
            assistantID = UUID()
            updateConversation(conversation.id) { $0.messages.append(AIChatMessage(id: assistantID, role: .assistant, text: "")) }
        }

        streamError = nil
        isStreaming = true
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            var responseID: String?
            let stream = AIChatResponsesClient().streamApproval(
                apiKey: apiKey,
                model: conversation.model,
                previousResponseID: previousResponseID,
                requestID: remoteApprovalID,
                approve: allow,
                reason: allow ? nil : "Denied in Lima",
                reasoningEffort: conversation.reasoningEffort,
                mcpServers: MCPServerStore.shared.servers.filter(\.enabled)
            )
            do {
                for try await event in stream {
                    guard !Task.isCancelled else { return }
                    self.apply(event, conversationID: conversation.id, assistantID: assistantID, responseID: &responseID)
                }
            } catch {
                if !Task.isCancelled, self.streamError == nil { self.streamError = error.localizedDescription }
            }
            self.finishStream(conversationID: conversation.id, assistantID: assistantID, responseID: responseID)
        }
    }

    private func apply(
        _ event: AIChatStreamEvent,
        conversationID: UUID,
        assistantID: UUID,
        responseID: inout String?
    ) {
        switch event {
        case .responseCreated(let id):
            responseID = id
        case .textDelta(let delta):
            updateAssistant(conversationID: conversationID, assistantID: assistantID) {
                $0.text += delta
            }
        case .reasoningSummaryDelta(let delta):
            updateConversation(conversationID) { $0.reasoningSummary = ($0.reasoningSummary ?? "") + delta }
        case .activity(let activity):
            updateConversation(conversationID) { $0.activities.append(activity) }
        case .approval(let request):
            pendingApproval = request
            updateConversation(conversationID) {
                $0.activities.append(AIAgentActivity(
                    kind: .toolApproval,
                    title: "Approval needed",
                    detail: "\(request.serverLabel) · \(request.toolName)",
                    requiresApproval: true
                ))
            }
        case .usage(let usage):
            updateConversation(conversationID) { $0.activities.append(AIAgentActivity(kind: .completed, title: "Usage", usage: usage, completed: true)) }
        case .completed(let id):
            responseID = id ?? responseID
        case .failed(let message):
            streamError = message
            updateConversation(conversationID) { $0.activities.append(AIAgentActivity(kind: .error, title: "Request failed", detail: message, completed: true)) }
        }
    }

    private func finishStream(conversationID: UUID, assistantID: UUID, responseID: String?) {
        defer {
            isStreaming = false
            streamTask = nil
        }
        guard var conversation = store.conversation(id: conversationID) else { return }
        if let index = conversation.messages.firstIndex(where: { $0.id == assistantID }) {
            conversation.messages[index].responseID = responseID
            if pendingApproval == nil && conversation.messages[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                conversation.messages.remove(at: index)
            }
        }
        if let responseID { conversation.lastResponseID = responseID }
        conversation.activities.append(AIAgentActivity(kind: .completed, title: "Completed", duration: Date().timeIntervalSince(conversation.activities.first?.startedAt ?? Date()), completed: true))
        conversation.updatedAt = Date()
        store.update(conversation)
    }

    private func updateConversation(_ conversationID: UUID, _ update: (inout AIConversation) -> Void) {
        guard var conversation = store.conversation(id: conversationID) else { return }
        update(&conversation)
        conversation.updatedAt = Date()
        store.update(conversation)
    }

    private func updateAssistant(
        conversationID: UUID,
        assistantID: UUID,
        _ update: (inout AIChatMessage) -> Void
    ) {
        guard var conversation = store.conversation(id: conversationID),
              let index = conversation.messages.firstIndex(where: { $0.id == assistantID }) else {
            return
        }
        update(&conversation.messages[index])
        conversation.updatedAt = Date()
        store.update(conversation)
    }
}

@MainActor
final class AIChatWindowController: NSWindowController {
    private let model = AIChatViewModel()
    private var mcpManagerWindow: MCPManagerWindowController?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_060, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AI Chat"
        window.minSize = NSSize(width: 760, height: 520)
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LimaTypographyRoot(content: AIChatWorkspaceView(model: model)))
        super.init(window: window)
        NotificationCenter.default.addObserver(forName: .limaOpenAIMCPManager, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.mcpManagerWindow == nil { self.mcpManagerWindow = MCPManagerWindowController() }
                self.mcpManagerWindow?.present()
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct AIChatWorkspaceView: View {
    @ObservedObject var model: AIChatViewModel
    @ObservedObject private var mcpStore = MCPServerStore.shared
    @State private var apiKey = ""
    @State private var showKey = false
    @State private var keyMessage: String?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            conversation
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(LimaColors.raisedSurface)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("AI Chat", systemImage: "sparkles")
                    .limaFont(.headline)
                Spacer()
                Button(action: model.newConversation) {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .help("New chat")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            if model.store.conversations.isEmpty {
                Text("Your chats stay on this Mac.")
                    .limaFont(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(model.store.conversations) { conversation in
                            Button {
                                model.select(conversation.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(conversation.title)
                                        .lineLimit(1)
                                        .limaFont(.callout.weight(.medium))
                                    Text(conversation.preview)
                                        .lineLimit(2)
                                        .limaFont(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(9)
                                .background(
                                    model.selectedConversationID == conversation.id
                                        ? LimaColors.recessedSurface
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Delete Chat", role: .destructive) {
                                    model.store.delete(id: conversation.id)
                                    if model.selectedConversationID == conversation.id {
                                        model.select(model.store.conversations.first?.id ?? conversation.id)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 7)
                }
            }
            Spacer()
            Text(mcpStore.servers.filter(\.enabled).isEmpty ? "OpenAI Responses API · tools off" : "OpenAI Responses API · MCP tools enabled")
                .limaFont(.caption2)
                .foregroundStyle(.tertiary)
                .padding(12)
        }
        .frame(width: 260)
        .background(LimaColors.sidebarBackground)
    }

    @ViewBuilder
    private var conversation: some View {
        VStack(spacing: 0) {
            if let approval = model.pendingApproval {
                AIToolApprovalView(request: approval, allow: { model.resolvePendingApproval(allow: true) }, deny: { model.resolvePendingApproval(allow: false) })
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.selectedConversation?.title ?? "New Chat")
                        .limaFont(.headline)
                        .lineLimit(1)
                    Text(model.credentials.hasAPIKey ? "Streaming responses" : "Setup required")
                        .limaFont(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    ForEach(model.supportedReasoningEfforts) { effort in
                        Button {
                            model.selectReasoningEffort(effort)
                        } label: {
                            Label("\(effort.title) · \(effort.detail)", systemImage: model.reasoningEffort == effort ? "checkmark" : "circle")
                        }
                    }
                    if model.supportedReasoningEfforts.isEmpty {
                        Text("This model does not expose reasoning controls")
                    }
                } label: {
                    Label(model.selectedModelOption.supportsReasoning ? "Think: \(model.reasoningEffort.title)" : "Think: Off", systemImage: "brain.head.profile")
                }
                .menuStyle(.borderlessButton)
                Menu {
                    ForEach(model.availableModels) { option in
                        Button {
                            model.selectModel(option)
                        } label: {
                            Label(option.displayName, systemImage: model.model == option.id ? "checkmark" : "circle")
                        }
                    }
                    Divider()
                    Button("Refresh Available Models", action: model.refreshModels)
                } label: {
                    Label(model.selectedModelOption.displayName, systemImage: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .disabled(model.isStreaming || model.isLoadingModels)
                .help("Choose an OpenAI Responses model")
                Button(action: model.refreshModels) {
                    Image(systemName: model.isLoadingModels ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.isLoadingModels || model.isStreaming)
                .help("Load models available to this API key")
                Button {
                    model.showActivity.toggle()
                } label: {
                    Image(systemName: model.showActivity ? "clock.badge.checkmark" : "clock")
                }
                .buttonStyle(.borderless)
                .help("Show work activity")
                if model.selectedConversation != nil {
                    Button(role: .destructive, action: model.deleteSelectedConversation) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete chat")
                }
            }
            .padding(16)
            Divider()

            if !model.credentials.hasAPIKey {
                setupPanel
            } else {
                messages
            }

            if model.showActivity, let conversation = model.selectedConversation, !conversation.activities.isEmpty {
                ActivityDisclosureView(activities: conversation.activities, reasoningSummary: conversation.reasoningSummary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }

            Divider()
            composer
        }
    }

    private var setupPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer()
            Image(systemName: "key.fill")
                .font(.system(size: 28))
                .foregroundStyle(SettingsStore.shared.accentTheme.readablePrimary)
            Text("Connect OpenAI")
                .limaFont(.title2.weight(.semibold))
            Text("Your API key is saved only in your macOS Keychain. Lima sends messages directly to the OpenAI Responses API. Tools and attachments are opt-in; read tools can run automatically, while write and destructive tools ask before running.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("OpenAI API key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Save Key") {
                    do {
                        try model.credentials.saveAPIKey(apiKey)
                        apiKey = ""
                        keyMessage = "API key saved in Keychain."
                    } catch {
                        keyMessage = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                if let keyMessage {
                    Text(keyMessage)
                        .limaFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if model.selectedConversation?.messages.isEmpty ?? true {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Start a conversation")
                                .limaFont(.title3.weight(.semibold))
                            Text("Responses stream directly into this chat. Conversation metadata and message history remain local to Lima.")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 260, alignment: .center)
                    } else {
                        ForEach(model.selectedConversation?.messages ?? []) { message in
                            AIChatMessageRow(message: message)
                                .id(message.id)
                        }
                    }
                }
                .padding(22)
            }
            .onChange(of: model.selectedConversation?.messages.last?.text ?? "") { _ in
                if let id = model.selectedConversation?.messages.last?.id {
                    withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.streamError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .limaFont(.caption)
                    .foregroundStyle(.orange)
            }
            AIAttachmentStrip(attachments: model.attachments, remove: model.remove)
            HStack(alignment: .bottom, spacing: 10) {
                HStack(spacing: 8) {
                Menu {
                    Button("Attach Files…", action: model.addFiles)
                    Button("Add Clipboard", action: model.addClipboard)
                    Button("Add Current Selection", action: model.addSelection)
                    Divider()
                    Text("Tools for this chat")
                    ForEach(mcpStore.servers) { server in
                        Toggle(isOn: Binding(
                            get: { server.enabled },
                            set: { mcpStore.setEnabled(server.id, enabled: $0) }
                        )) {
                            Label("\(server.name) (\(server.enabledTools.count))", systemImage: "server.rack")
                        }
                    }
                    if mcpStore.servers.isEmpty {
                        Text("No MCP servers configured")
                    }
                    Divider()
                    Button("Manage MCP Servers…") { model.openMCPManager() }
                } label: {
                    Label("Tools \(mcpStore.servers.filter(\.enabled).count)", systemImage: "wrench.and.screwdriver")
                }
                .menuStyle(.borderlessButton)
                .help("Choose MCP servers and manage individual tools")
                TextEditor(text: $model.draft)
                    .font(.system(size: 14))
                    .frame(minHeight: 44, maxHeight: 110)
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .background(LimaColors.recessedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .disabled(model.isStreaming)
                if model.isStreaming {
                    Button(action: model.cancel) {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .help("Stop generating")
                } else {
                    Button(action: model.send) {
                        Image(systemName: "arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Send message")
                }
                }
            }
            Text("Markdown and code are supported. API keys, attachments, and chat history stay out of diagnostics.")
                .limaFont(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
    }
}

private struct ActivityDisclosureView: View {
    let activities: [AIAgentActivity]
    let reasoningSummary: String?
    @State private var isExpanded = false

    private var elapsed: TimeInterval {
        guard let start = activities.first?.startedAt else { return 0 }
        return (activities.last?.endedAt ?? Date()).timeIntervalSince(start)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 7) {
                if let reasoningSummary, !reasoningSummary.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reasoning summary").limaFont(.caption.weight(.semibold))
                        AIMarkdownView(markdown: reasoningSummary)
                    }
                    .padding(.bottom, 4)
                }
                ForEach(activities) { activity in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: activity.statusSymbol)
                            .foregroundStyle(activity.kind == .error || activity.kind == .toolFailed ? LimaColors.danger : LimaColors.success)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(activity.title).limaFont(.caption.weight(.medium))
                            if let detail = activity.detail { Text(detail).limaFont(.caption2).foregroundStyle(LimaColors.secondaryText) }
                        }
                        Spacer()
                        if let usage = activity.usage, let value = usage.displayText { Text(value).limaFont(.caption2).foregroundStyle(LimaColors.tertiaryText) }
                    }
                }
            }
            .padding(.top, 7)
        } label: {
            Label("Worked for \(elapsed, specifier: "%.1f")s", systemImage: "waveform.path.ecg")
                .limaFont(.caption.weight(.semibold))
        }
        .tint(LimaColors.primaryText)
        .padding(10)
        .background(LimaColors.recessedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(LimaColors.border, lineWidth: 1))
    }
}

private struct AIChatMessageRow: View {
    let message: AIChatMessage

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .assistant {
                Image(systemName: "sparkles")
                    .foregroundStyle(SettingsStore.shared.accentTheme.readablePrimary)
                    .frame(width: 22)
                messageBody
                Spacer(minLength: 60)
            } else {
                Spacer(minLength: 60)
                messageBody
                Image(systemName: "person.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
            }
        }
    }

    private var messageBody: some View {
        Group {
            if message.role == .assistant, !message.text.isEmpty {
                AIMarkdownView(markdown: message.text)
            } else {
                Text(message.text.isEmpty && message.role == .assistant ? "Thinking…" : message.text)
                    .textSelection(.enabled)
            }
        }
            .fixedSize(horizontal: false, vertical: true)
            .padding(11)
            .background(
                message.role == .user ? SettingsStore.shared.accentTheme.readablePrimary.opacity(0.15) : LimaColors.recessedSurface,
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
    }
}
