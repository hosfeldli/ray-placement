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
    var reasoningSummary: String?
    var activities: [AIAgentActivity]?

    init(
        id: UUID = UUID(),
        role: AIChatRole,
        text: String,
        createdAt: Date = Date(),
        responseID: String? = nil,
        reasoningSummary: String? = nil,
        activities: [AIAgentActivity]? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.responseID = responseID
        self.reasoningSummary = reasoningSummary
        self.activities = activities
    }
}

struct AIConversation: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var provider: AIProvider
    var model: String
    var lastResponseID: String?
    var reasoningEffort: AIReasoningEffort
    var agentID: String?
    var skillIDs: [String]
    var reasoningSummary: String?
    var activities: [AIAgentActivity]
    var attachments: [AIAttachment]
    var messages: [AIChatMessage]

    init(
        id: UUID = UUID(),
        title: String = "New Chat",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        provider: AIProvider = .openAI,
        model: String = "gpt-5",
        lastResponseID: String? = nil,
        reasoningEffort: AIReasoningEffort = .medium,
        agentID: String? = nil,
        skillIDs: [String] = [],
        reasoningSummary: String? = nil,
        activities: [AIAgentActivity] = [],
        attachments: [AIAttachment] = [],
        messages: [AIChatMessage] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.provider = provider
        self.model = model
        self.lastResponseID = lastResponseID
        self.reasoningEffort = reasoningEffort
        self.agentID = agentID
        self.skillIDs = skillIDs
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
        case id, title, createdAt, updatedAt, provider, model, lastResponseID
        case reasoningEffort, agentID, skillIDs, reasoningSummary, activities, attachments, messages
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        provider = try values.decodeIfPresent(AIProvider.self, forKey: .provider) ?? .openAI
        model = try values.decode(String.self, forKey: .model)
        lastResponseID = try values.decodeIfPresent(String.self, forKey: .lastResponseID)
        reasoningEffort = try values.decodeIfPresent(AIReasoningEffort.self, forKey: .reasoningEffort) ?? .medium
        agentID = try values.decodeIfPresent(String.self, forKey: .agentID)
        skillIDs = try values.decodeIfPresent([String].self, forKey: .skillIDs) ?? []
        reasoningSummary = try values.decodeIfPresent(String.self, forKey: .reasoningSummary)
        activities = try values.decodeIfPresent([AIAgentActivity].self, forKey: .activities) ?? []
        attachments = try values.decodeIfPresent([AIAttachment].self, forKey: .attachments) ?? []
        messages = try values.decodeIfPresent([AIChatMessage].self, forKey: .messages) ?? []
    }
}

struct AIChatCredentialConfiguration: Equatable, Sendable {
    static let testAPIKeyVariable = "LIMA_TEST_OPENAI_API_KEY"

    let service: String
    let account: String
    let environmentAPIKey: String?
    let fixtureAPIKey: String?
    let usesKeychain: Bool
    let isTestCredential: Bool

    static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        let isTestMode = LimaTestEnvironment.isEnabled(environment: environment)
        return Self(
            service: isTestMode ? "dev.liam.lima.ai.test" : "dev.liam.lima.ai",
            account: "openai-api-key",
            environmentAPIKey: isTestMode ? environment[testAPIKeyVariable]?.nonEmptyTrimmed : nil,
            fixtureAPIKey: nil,
            usesKeychain: true,
            isTestCredential: isTestMode
        )
    }

    static let fixture = Self(
        service: "dev.liam.lima.ai.test",
        account: "fixture-openai-api-key",
        environmentAPIKey: nil,
        fixtureAPIKey: "fixture-openai-api-key",
        usesKeychain: false,
        isTestCredential: true
    )

    static let missingFixture = Self(
        service: "dev.liam.lima.ai.test",
        account: "fixture-openai-api-key",
        environmentAPIKey: nil,
        fixtureAPIKey: nil,
        usesKeychain: false,
        isTestCredential: true
    )
}

private extension String {
    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
final class AIProviderCredentialStore: ObservableObject {
    static let shared = AIProviderCredentialStore()

    @Published private(set) var hasAPIKey = false

    let configuration: AIChatCredentialConfiguration

    init(configuration: AIChatCredentialConfiguration = .current()) {
        self.configuration = configuration
        refresh()
    }

    func saveAPIKey(_ value: String, for provider: AIProvider = .openAI) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw NSError(
                domain: "LimaAI",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Enter an API key for the selected provider."]
            )
        }

        guard configuration.fixtureAPIKey == nil, configuration.usesKeychain else { return }

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: configuration.service,
            kSecAttrAccount as String: keychainAccount(for: provider),
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: configuration.service,
                kSecAttrAccount as String: keychainAccount(for: provider)
            ]
            let update = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: Data(key.utf8)] as CFDictionary
            )
            guard update == errSecSuccess else { throw keychainError(update) }
        } else if status != errSecSuccess {
            throw keychainError(status)
        }
        hasAPIKey = apiKey(for: .openAI)?.isEmpty == false
    }

    func apiKey() -> String? {
        apiKey(for: .openAI)
    }

    func apiKey(for provider: AIProvider) -> String? {
        if provider == .openAI {
            if let fixtureAPIKey = configuration.fixtureAPIKey { return fixtureAPIKey }
            if let environmentAPIKey = configuration.environmentAPIKey { return environmentAPIKey }
        }
        guard configuration.usesKeychain else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: configuration.service,
            kSecAttrAccount as String: keychainAccount(for: provider),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data {
            return String(data: data, encoding: .utf8)
        }

        // Migrate legacy grammar credentials into the shared provider account on
        // first use; do not read the production Keychain namespace in test mode.
        guard !configuration.isTestCredential else { return nil }
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.lima.developer-grammar",
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var legacyItem: CFTypeRef?
        guard SecItemCopyMatching(legacyQuery as CFDictionary, &legacyItem) == errSecSuccess,
              let legacyData = legacyItem as? Data,
              let legacyValue = String(data: legacyData, encoding: .utf8),
              !legacyValue.isEmpty else { return nil }
        Self.migrateLegacyCredential(save: { try saveAPIKey(legacyValue, for: provider) },
                                     removeLegacy: { SecItemDelete(legacyQuery as CFDictionary) })
        return legacyValue
    }

    /// Never remove the last working credential when a Keychain migration fails.
    static func migrateLegacyCredential(save: () throws -> Void, removeLegacy: () -> OSStatus) {
        do { try save(); _ = removeLegacy() } catch { /* Preserve the legacy value for retry. */ }
    }

    func hasAPIKey(for provider: AIProvider) -> Bool {
        apiKey(for: provider)?.isEmpty == false
    }

    func removeAPIKey(for provider: AIProvider = .openAI) throws {
        guard configuration.fixtureAPIKey == nil, configuration.usesKeychain else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: configuration.service,
            kSecAttrAccount as String: keychainAccount(for: provider)
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
        if !configuration.isTestCredential {
            let legacyQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.lima.developer-grammar",
                kSecAttrAccount as String: provider.rawValue
            ]
            let legacyStatus = SecItemDelete(legacyQuery as CFDictionary)
            guard legacyStatus == errSecSuccess || legacyStatus == errSecItemNotFound else { throw keychainError(legacyStatus) }
        }
        objectWillChange.send()
        if provider == .openAI {
            hasAPIKey = configuration.environmentAPIKey != nil
        }
    }

    func refresh() {
        hasAPIKey = apiKey()?.isEmpty == false
    }

    private func keychainAccount(for provider: AIProvider) -> String {
        provider == .openAI ? configuration.account : "\(provider.rawValue.lowercased())-api-key"
    }

    private func keychainError(_ status: OSStatus = errSecAuthFailed) -> NSError {
        NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: configuration.isTestCredential
                ? "Lima could not access the test provider API key in Keychain."
                : "Lima could not access the provider API key in Keychain."]
        )
    }
}

typealias AIChatCredentialStore = AIProviderCredentialStore

@MainActor
final class AIConversationStore: ObservableObject {
    static let shared = AIConversationStore()

    static let maximumConversations = 200
    static let maximumCharactersPerConversation = 1_000_000

    @Published private(set) var conversations: [AIConversation] = []
    @Published private(set) var lastError: String?

    private let persistsChanges: Bool
    private let persistenceQueue = DispatchQueue(label: "dev.liam.lima.ai-chat-persistence", qos: .utility)
    private var pendingSave: DispatchWorkItem?

    private init() {
        persistsChanges = true
        load()
    }

    init(fixtures: [AIConversation]) {
        persistsChanges = false
        conversations = fixtures
    }

    func conversation(id: UUID) -> AIConversation? {
        conversations.first { $0.id == id }
    }

    @discardableResult
    func createConversation(provider: AIProvider = .openAI, model: String) -> AIConversation {
        let conversation = AIConversation(provider: provider, model: model)
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
        guard persistsChanges else { return }
        pendingSave?.cancel()
        let snapshot = conversations
        let url = storageURL
        let work = DispatchWorkItem { [weak self] in
            do {
                try Self.persist(snapshot, to: url)
                DispatchQueue.main.async { self?.lastError = nil }
            } catch {
                DispatchQueue.main.async { self?.lastError = "AI chat history could not be saved. Check local storage access." }
            }
        }
        pendingSave = work
        persistenceQueue.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private var storageURL: URL {
        if let testURL = LimaTestEnvironment.storageURL(relativePath: "AI/conversations.json") {
            return testURL
        }
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
    case outputItem(AIOutputItem)
    case activity(AIAgentActivity)
    case approval(AIToolApprovalRequest)
    case diagnostic(AIChatDiagnostic)
    case usage(AIUsageMetrics)
    case completed(String?)
    case failed(String)
}

/// A concise, presentation-safe description of the active assistant turn.
/// It intentionally exposes progress, not private provider reasoning.
enum AIChatTaskTone {
    case neutral
    case active
    case success
    case warning
    case danger

    @MainActor
    var color: Color {
        switch self {
        case .neutral: return LimaTheme.textSecondary
        case .active: return SettingsStore.shared.accentTheme.readablePrimary
        case .success: return LimaColors.success
        case .warning: return LimaTheme.warning
        case .danger: return LimaColors.danger
        }
    }
}

struct AIChatTaskState {
    let title: String
    let detail: String
    let symbol: String
    let tone: AIChatTaskTone
    let isActive: Bool
    let canEnd: Bool
}

protocol AIProviderClient {
    func listModels(apiKey: String) async throws -> [AIModelOption]
    func streamReply(
        apiKey: String,
        model: String,
        input: String,
        history: [AIProviderMessage],
        previousResponseID: String?,
        reasoningEffort: AIReasoningEffort,
        attachments: [AIAttachment],
        mcpServers: [MCPServer],
        localTools: [LimaAIToolDefinition],
        systemInstructions: String
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error>
    func streamApproval(
        apiKey: String,
        model: String,
        previousResponseID: String,
        requestID: String,
        approve: Bool,
        reason: String?,
        reasoningEffort: AIReasoningEffort,
        mcpServers: [MCPServer],
        localTools: [LimaAIToolDefinition],
        systemInstructions: String
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error>
    func streamToolOutputs(
        apiKey: String,
        model: String,
        previousResponseID: String,
        history: [AIProviderMessage],
        outputs: [[String: Any]],
        reasoningEffort: AIReasoningEffort,
        mcpServers: [MCPServer],
        localTools: [LimaAIToolDefinition],
        systemInstructions: String
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error>
}

typealias AIChatTransport = AIProviderClient

/// A deterministic transport for visual and UI tests. It contains no endpoint,
/// credential, or network implementation.
struct FixtureAITransport: AIChatTransport {
    var events: [AIChatStreamEvent]
    /// Optional replay pacing for deterministic streaming and cancellation tests.
    var interEventDelay: Duration? = nil
    var models: [AIModelOption] = [AIModelOption(id: "gpt-5.6-terra")]
    var modelDiscoveryDelay: Duration? = nil

    static let standard = FixtureAITransport(events: [
        .responseCreated("fixture-response"),
        .reasoningSummaryDelta("Replayed a deterministic fixture stream."),
        .textDelta("Lima works"),
        .usage(AIUsageMetrics(inputTokens: 8, outputTokens: 3)),
        .completed("fixture-response")
    ])

    func listModels(apiKey: String) async throws -> [AIModelOption] {
        if let modelDiscoveryDelay { try await Task.sleep(for: modelDiscoveryDelay) }
        return models
    }

    func streamReply(
        apiKey: String,
        model: String,
        input: String,
        history: [AIProviderMessage],
        previousResponseID: String?,
        reasoningEffort: AIReasoningEffort,
        attachments: [AIAttachment],
        mcpServers: [MCPServer],
        localTools: [LimaAIToolDefinition],
        systemInstructions: String
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> { stream() }

    func streamApproval(
        apiKey: String,
        model: String,
        previousResponseID: String,
        requestID: String,
        approve: Bool,
        reason: String?,
        reasoningEffort: AIReasoningEffort,
        mcpServers: [MCPServer],
        localTools: [LimaAIToolDefinition],
        systemInstructions: String
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> { stream() }

    func streamToolOutputs(
        apiKey: String,
        model: String,
        previousResponseID: String,
        history: [AIProviderMessage],
        outputs: [[String: Any]],
        reasoningEffort: AIReasoningEffort,
        mcpServers: [MCPServer],
        localTools: [LimaAIToolDefinition],
        systemInstructions: String
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> { stream() }

    private func stream() -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        guard let interEventDelay else {
            return AsyncThrowingStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
        return AsyncThrowingStream { continuation in
            Task {
                for event in events {
                    guard !Task.isCancelled else { break }
                    continuation.yield(event)
                    try? await Task.sleep(for: interEventDelay)
                }
                continuation.finish()
            }
        }
    }
}

struct AIChatResponsesClient: AIChatTransport {
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
        history: [AIProviderMessage],
        previousResponseID: String?,
        reasoningEffort: AIReasoningEffort,
        attachments: [AIAttachment],
        mcpServers: [MCPServer],
        localTools: [LimaAIToolDefinition],
        systemInstructions: String
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        do {
            let inputContent = try AIInputEncoder.content(text: input, attachments: attachments)
            let userInput: [String: Any] = ["role": "user", "content": inputContent]
            let body = Self.replyBody(
                model: model,
                input: [userInput],
                previousResponseID: previousResponseID,
                reasoningEffort: reasoningEffort,
                tools: mcpToolPayload(for: mcpServers) + localTools.map(\.responsePayload),
                systemInstructions: systemInstructions
            )
            return stream(body: body, apiKey: apiKey)
        } catch {
            return AsyncThrowingStream { continuation in
                continuation.yield(.failed(AIProviderFailure.message()))
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
        mcpServers: [MCPServer],
        localTools: [LimaAIToolDefinition],
        systemInstructions: String
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
            tools: mcpToolPayload(for: mcpServers) + localTools.map(\.responsePayload),
            systemInstructions: systemInstructions
        )
        return stream(body: body, apiKey: apiKey)
    }

    func streamToolOutputs(
        apiKey: String,
        model: String,
        previousResponseID: String,
        history: [AIProviderMessage],
        outputs: [[String: Any]],
        reasoningEffort: AIReasoningEffort,
        mcpServers: [MCPServer],
        localTools: [LimaAIToolDefinition],
        systemInstructions: String
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        let body = Self.replyBody(
            model: model,
            input: outputs,
            previousResponseID: previousResponseID,
            reasoningEffort: reasoningEffort,
            tools: mcpToolPayload(for: mcpServers) + localTools.map(\.responsePayload),
            systemInstructions: systemInstructions
        )
        return stream(body: body, apiKey: apiKey)
    }

    static func replyBody(
        model: String,
        input: [[String: Any]],
        previousResponseID: String?,
        reasoningEffort: AIReasoningEffort,
        tools: [[String: Any]],
        systemInstructions: String = AIReadOnlyPolicy.assistantInstructions
    ) -> [String: Any] {
        let option = AIModelOption(id: model)
        var body: [String: Any] = [
            "model": model,
            "input": input,
            "stream": true
        ]
        // `/v1/models` does not describe Responses feature support. A newly
        // discovered family gets the smallest valid streaming request until it
        // has an explicit capability profile; this avoids inheriting optional
        // storage, instructions, or reasoning fields from a different model.
        if !option.isLegacyOrUnknown {
            body["store"] = true
            body["instructions"] = systemInstructions
        }
        if option.supportsReasoning {
            let effort = option.supportedReasoningEfforts.contains(reasoningEffort)
                ? reasoningEffort
                : (option.defaultReasoningEffort ?? .medium)
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
            Self.remoteMCPToolPayload(
                server: server,
                credential: MCPCredentialStore.value(serverID: server.id)
            )
        }
    }

    static func remoteMCPToolPayload(server: MCPServer, credential: String?) -> [String: Any]? {
        let readOnlyTools = AIReadOnlyPolicy.readableMCPTools(for: server)
        guard !readOnlyTools.isEmpty, server.validHTTPURL != nil else { return nil }

        var tool: [String: Any] = [
            "type": "mcp",
            "server_label": server.apiLabel,
            "server_url": server.validHTTPURL?.absoluteString ?? server.url,
            "allowed_tools": readOnlyTools.map(\.name),
            "require_approval": ["never": ["tool_names": readOnlyTools.map(\.name)]]
        ]

        if let credential, !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tool["authorization"] = MCPCredentialStore.authorizationHeaderValue(credential)
        }
        return tool
    }

    private func stream(
        body: [String: Any],
        apiKey: String
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let model = body["model"] as? String
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
                        var errorData = Data()
                        for try await byte in bytes {
                            errorData.append(byte)
                            if errorData.count >= 64_000 { break }
                        }
                        let failure = AIProviderFailure.details(data: errorData, status: http.statusCode)
                        continuation.yield(.diagnostic(AIChatDiagnostic(
                            stage: .transport,
                            httpStatus: http.statusCode,
                            model: model,
                            errorCode: failure.code,
                            errorParameter: failure.parameter,
                            message: failure.message
                        )))
                        continuation.yield(.failed(failure.message))
                        continuation.finish()
                        return
                    }

                    var parser = AIResponsesSSEParser(model: model)
                    for try await byte in bytes {
                        if Task.isCancelled { break }
                        for event in parser.append(byte: byte) {
                            continuation.yield(event)
                        }
                        if parser.failed { break }
                    }
                    for event in parser.finish() {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.yield(.diagnostic(Self.diagnostic(for: error, model: model)))
                    continuation.yield(.failed(AIProviderFailure.transport(error)))
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func safeErrorMessage(from data: Data) -> String {
        AIProviderFailure.message(data: data)
    }

    private static func diagnostic(for error: Error, model: String?) -> AIChatDiagnostic {
        let status: Int?
        if case ClientError.requestFailed(let code, _) = error { status = code } else { status = nil }
        return AIChatDiagnostic(stage: .transport, httpStatus: status, message: AIProviderFailure.transport(error))
    }

}

@MainActor
final class AIChatViewModel: ObservableObject {
    @Published private(set) var selectedConversationID: UUID?
    @Published var conversationSearchQuery = ""
    @Published var draft = ""
    @Published var provider: AIProvider = .openAI
    @Published var model = "gpt-5"
    @Published var reasoningEffort: AIReasoningEffort = .medium
    @Published private(set) var availableModels: [AIModelOption] = AIProvider.openAI.chatModels
    @Published private(set) var isLoadingModels = false
    @Published private(set) var providerConnectionMessage: String?
    @Published var attachments: [AIAttachment] = []
    @Published var showActivity = true
    @Published private(set) var isStreaming = false
    /// Batched, ephemeral answer text. The transcript store is updated only at
    /// turn checkpoints, so provider token cadence does not drive persistence.
    @Published private(set) var streamingText = ""
    @Published private(set) var streamingReasoningSummary = ""
    @Published private(set) var streamingTextAssistantID: UUID?
    @Published private(set) var streamError: String?
    @Published private(set) var streamDiagnostics: [AIChatDiagnostic] = []
    @Published var showDiagnostics = false
    @Published private(set) var pendingApproval: AIToolApprovalRequest?

    let store: AIConversationStore
    let credentials: AIChatCredentialStore
    let mcpStore: MCPServerStore
    let nativeToolStore: LimaAIToolStore
    let providerPreferences: AIProviderPreferences
    let transport: any AIChatTransport
    private let hasInjectedTransport: Bool
    private let taskRegistry: TaskRegistry
    private var streamTask: Task<Void, Never>?
    private var modelDiscoveryTask: Task<Void, Never>?
    private var pendingLocalFunctionCall: AIOutputItem?
    private var activeAssistantID: UUID?
    private var activeConversationID: UUID?
    private var cancelledAssistantIDs = Set<UUID>()
    private var registeredTaskID: UUID?
    private var performanceMeasurementID: UUID?
    private var firstTokenPerformanceMeasurementID: UUID?
    private var pendingStreamTextChunks: [String] = []
    private var pendingStreamReasoningChunks: [String] = []
    private var streamTextFlushTask: Task<Void, Never>?

    init(
        store: AIConversationStore? = nil,
        credentials: AIChatCredentialStore? = nil,
        mcpStore: MCPServerStore? = nil,
        nativeToolStore: LimaAIToolStore? = nil,
        transport: (any AIChatTransport)? = nil,
        taskRegistry: TaskRegistry? = nil,
        providerPreferences: AIProviderPreferences? = nil
    ) {
        let store = store ?? .shared
        let credentials = credentials ?? .shared
        self.store = store
        self.credentials = credentials
        self.mcpStore = mcpStore ?? .shared
        self.nativeToolStore = nativeToolStore ?? .shared
        self.transport = transport ?? AIChatResponsesClient()
        self.hasInjectedTransport = transport != nil
        self.taskRegistry = taskRegistry ?? .shared
        self.providerPreferences = providerPreferences ?? .shared
        selectedConversationID = store.conversations.first?.id
        if let selected = store.conversations.first {
            provider = selected.provider
            availableModels = selected.provider.chatModels
            model = selected.model
            reasoningEffort = selected.reasoningEffort
            attachments = selected.attachments
        }
        ensureModelIsAvailable()
    }

    deinit { streamTask?.cancel(); modelDiscoveryTask?.cancel() }

    var selectedConversation: AIConversation? {
        selectedConversationID.flatMap(store.conversation(id:))
    }

    func visibleText(for message: AIChatMessage) -> String {
        streamingTextAssistantID == message.id ? streamingText : message.text
    }

    func visibleReasoningSummary(for message: AIChatMessage) -> String? {
        streamingTextAssistantID == message.id ? streamingReasoningSummary : message.reasoningSummary
    }

    func select(_ id: UUID) {
        guard !canEndTask, store.conversation(id: id) != nil else { return }
        if selectedConversationID != id { draft = ""; providerConnectionMessage = nil }
        selectedConversationID = id
        if let conversation = store.conversation(id: id) {
            provider = conversation.provider
            availableModels = conversation.provider.chatModels
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

    var hasProviderAPIKey: Bool {
        requestAPIKey(for: provider) != nil || transport is FixtureAITransport
    }

    private func requestAPIKey(for provider: AIProvider) -> String? {
        if provider == .openAICompatible { return credentials.apiKey(for: provider) ?? "" }
        guard let key = credentials.apiKey(for: provider), !key.isEmpty else { return nil }
        return key
    }

    private func providerClient(for provider: AIProvider) -> any AIChatTransport {
        if hasInjectedTransport { return transport }
        return AIProviderClientRegistry.client(
            for: provider,
            openAICompatibleBaseURL: providerPreferences.openAICompatibleBaseURL
        )
    }

    func selectProvider(_ provider: AIProvider) {
        guard AIProvider.chatProviders.contains(provider), self.provider != provider, !canEndTask else { return }
        self.provider = provider
        providerConnectionMessage = nil
        if provider == .openAICompatible {
            let compatibleModel = providerPreferences.openAICompatibleModelID
            availableModels = [AIModelOption(id: compatibleModel, displayName: compatibleModel, supportsReasoning: false)]
            model = compatibleModel
        } else {
            availableModels = provider.chatModels
            model = provider.defaultChatModel
        }
        reasoningEffort = .medium
        if let id = selectedConversationID, var conversation = store.conversation(id: id) {
            conversation.provider = provider
            conversation.model = model
            conversation.lastResponseID = nil
            conversation.reasoningEffort = reasoningEffort
            store.update(conversation)
        }
        ensureModelIsAvailable()
    }

    var selectedAgentID: String? { selectedConversation?.agentID }
    var selectedSkillIDs: [String] { selectedConversation?.skillIDs ?? [] }
    var availableAgentConfigurations: [AIChatAgentConfiguration] { AIChatConfigurationCatalog.agents }
    var availableSkillConfigurations: [AIChatSkillConfiguration] { AIChatConfigurationCatalog.skills }
    var selectedAgentConfiguration: AIChatAgentConfiguration? {
        selectedAgentID.flatMap(AIChatConfigurationCatalog.agent(id:))
    }
    var selectedSkillConfigurations: [AIChatSkillConfiguration] {
        selectedSkillIDs.compactMap(AIChatConfigurationCatalog.skill(id:))
    }

    private var enabledNativeTools: [LimaAIToolDefinition] {
        let enabled = LimaAIToolRegistry.enabledDefinitions(nativeToolStore.enabledToolIDs)
        guard selectedAgentID != nil else { return enabled }
        guard let allowed = selectedAgentConfiguration?.toolIDs else { return [] }
        let allowedIDs = Set(allowed)
        return enabled.filter { definition in
            allowedIDs.contains(definition.id)
                || definition.extensionBinding.map {
                    allowedIDs.contains($0.tool.id)
                } == true
        }
    }

    /// Enabled tools are an eligibility set, not a per-request payload. Route a
    /// small deterministic subset from explicit agent/skill choices and prompt
    /// intent so a generic chat does not send unrelated tool schemas.
    func routedNativeTools(for prompt: String) -> [LimaAIToolDefinition] {
        let value = prompt.lowercased()
        var requested = Set(selectedAgentConfiguration?.toolIDs ?? [])
        for skill in selectedSkillConfigurations {
            requested.formUnion(skill.preferredToolIDs)
        }

        func containsAny(_ terms: [String]) -> Bool {
            terms.contains { value.localizedStandardContains($0) }
        }

        if isBrowserPrompt(prompt) {
            requested.formUnion(["browser_tabs", "browser_current", "browser_read", "salesforce_resolve_case"])
        }
        if containsAny(["file", "folder", "directory", "path", "repository", "repo", "source code", "swift"]) {
            requested.formUnion(["search_files", "find_files", "list_directory", "file_metadata", "read_file"])
        }
        if containsAny(["search the web", "web search", "research", "latest", "online", "website", "public web", "http://", "https://"]) {
            requested.formUnion(["search_web", "read_web"])
        }
        if containsAny(["screen", "selected text", "current app", "window title"]) {
            requested.insert("read_screen_context")
        }
        if containsAny(["extension", "plugin", "installed command"]) {
            requested.insert("list_extensions")
        }
        if containsAny(["lima status", "lima version", "app status"]) {
            requested.insert("get_lima_status")
        }

        return enabledNativeTools.filter { definition in
            requested.contains(definition.id)
                || definition.extensionBinding.map { requested.contains($0.tool.id) } == true
        }
    }

    func routedMCPServers(for prompt: String) -> [MCPServer] {
        let value = prompt.lowercased()
        return mcpStore.servers.filter { server in
            guard server.enabled, !AIReadOnlyPolicy.readableMCPTools(for: server).isEmpty else { return false }
            let serverTerms = [server.name, server.apiLabel] + server.enabledTools.flatMap { [$0.name, $0.title ?? ""] }
            return serverTerms.contains { term in
                let candidate = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return candidate.count >= 3 && value.localizedStandardContains(candidate)
            }
        }
    }

    func isBrowserPrompt(_ prompt: String) -> Bool {
        let value = prompt.lowercased()
        let namedBrowserContext = ["browser", "salesforce", "force.com", "lightning"].contains {
            value.localizedStandardContains($0)
        }
        let standaloneTab = value.range(of: "\\btabs?\\b", options: .regularExpression) != nil
        return namedBrowserContext || standaloneTab
    }

    private func readOnlyBrowserActionMessage(for prompt: String) -> String? {
        let value = prompt.lowercased()
        guard isBrowserPrompt(prompt),
              ["open", "new", "navigate", "close", "focus"].contains(where: { value.localizedStandardContains($0) }) else { return nil }
        return "Lima can inspect granted browser tabs and resolve Salesforce Case links, but AI Chat is read-only and cannot open, close, focus, or navigate tabs. Ask it to identify or resolve the Case links instead."
    }

    var systemInstructions: String {
        var sections = [AIReadOnlyPolicy.assistantInstructions]
        if let agent = selectedAgentConfiguration, !agent.instructions.isEmpty {
            sections.append("Agent configuration — \(agent.name):\n\(agent.instructions)")
            if !agent.contextDefaults.isEmpty {
                sections.append("Context defaults: \(agent.contextDefaults.joined(separator: ", ")). Use only context explicitly supplied or available through enabled read-only tools.")
            }
        }
        for skill in selectedSkillConfigurations where !skill.instructions.isEmpty {
            sections.append("Skill — \(skill.name):\n\(skill.instructions)")
        }
        return String(sections.joined(separator: "\n\n").prefix(16_000))
    }

    func selectAgent(_ identifier: String?) {
        guard !canEndTask else { return }
        var conversation = configurationConversation()
        let previousProvider = conversation.provider
        let previousModel = conversation.model
        conversation.agentID = identifier

        if let agent = identifier.flatMap(AIChatConfigurationCatalog.agent(id:)) {
            conversation.skillIDs = agent.skillIDs
            if let provider = AIChatConfigurationCatalog.provider(for: agent.providerID),
               AIProvider.chatProviders.contains(provider) {
                conversation.provider = provider
                self.provider = provider
                if provider == .openAICompatible {
                    availableModels = [AIModelOption(
                        id: providerPreferences.openAICompatibleModelID,
                        supportsReasoning: false
                    )]
                } else {
                    availableModels = provider.chatModels
                }
                if let modelID = agent.modelID, !modelID.isEmpty {
                    if !availableModels.contains(where: { $0.id == modelID }) {
                        availableModels.append(AIModelOption(id: modelID))
                    }
                    conversation.model = modelID
                } else {
                    conversation.model = provider == .openAICompatible
                        ? providerPreferences.openAICompatibleModelID
                        : provider.defaultChatModel
                }
            } else if let modelID = agent.modelID, !modelID.isEmpty {
                conversation.model = modelID
                if !availableModels.contains(where: { $0.id == modelID }) {
                    availableModels.append(AIModelOption(id: modelID))
                }
            }
            let configuredOption = availableModels.first(where: { $0.id == conversation.model })
                ?? AIModelOption(id: conversation.model)
            if let effort = agent.reasoningEffort,
               configuredOption.supportedReasoningEfforts.contains(effort) {
                conversation.reasoningEffort = effort
                reasoningEffort = effort
            }
        } else {
            conversation.skillIDs = []
        }

        if previousProvider != conversation.provider || previousModel != conversation.model {
            conversation.lastResponseID = nil
        }
        provider = conversation.provider
        model = conversation.model
        reasoningEffort = conversation.reasoningEffort
        store.update(conversation)
    }

    func setSelectedSkills(_ identifiers: [String]) {
        guard !canEndTask else { return }
        let available = AIChatConfigurationCatalog.skills
        let validIDs = Set(available.map(\.id))
        var conversation = configurationConversation()
        var seen = Set<String>()
        conversation.skillIDs = identifiers.filter { validIDs.contains($0) && seen.insert($0).inserted }
        if let recommendation = conversation.skillIDs.reversed()
            .compactMap({ AIChatConfigurationCatalog.skill(id: $0) })
            .first(where: { $0.recommendedProviderID != nil || $0.recommendedModelID != nil }) {
            applyModelRecommendation(providerID: recommendation.recommendedProviderID, modelID: recommendation.recommendedModelID, to: &conversation)
        }
        store.update(conversation)
    }

    private func applyModelRecommendation(providerID: String?, modelID: String?, to conversation: inout AIConversation) {
        let previousProvider = conversation.provider
        let previousModel = conversation.model
        if let provider = AIChatConfigurationCatalog.provider(for: providerID),
           AIProvider.chatProviders.contains(provider) {
            conversation.provider = provider
            self.provider = provider
            availableModels = provider == .openAICompatible
                ? [AIModelOption(id: providerPreferences.openAICompatibleModelID, supportsReasoning: false)]
                : provider.chatModels
            conversation.model = modelID ?? (provider == .openAICompatible
                ? providerPreferences.openAICompatibleModelID
                : provider.defaultChatModel)
        } else if let modelID {
            conversation.model = modelID
        }
        if let modelID = modelID, !availableModels.contains(where: { $0.id == modelID }) {
            availableModels.append(AIModelOption(id: modelID))
        }
        if conversation.provider != previousProvider || conversation.model != previousModel {
            conversation.lastResponseID = nil
        }
        provider = conversation.provider
        model = conversation.model
    }

    private func configurationConversation() -> AIConversation {
        if let selectedConversation { return selectedConversation }
        let conversation = store.createConversation(provider: provider, model: model)
        selectedConversationID = conversation.id
        return conversation
    }

    var canEndTask: Bool {
        isStreaming || pendingApproval != nil
    }

    var currentTaskState: AIChatTaskState {
        let assistant = selectedConversation?.messages.last(where: { $0.role == .assistant })
        let activity = assistant?.activities?.last

        if let approval = pendingApproval {
            return AIChatTaskState(
                title: "Approval needed",
                detail: "\(approval.serverLabel) · \(approval.toolName)",
                symbol: "hand.raised.fill",
                tone: .warning,
                isActive: true,
                canEnd: true
            )
        }
        if let streamError {
            return AIChatTaskState(
                title: "Request needs attention",
                detail: streamError,
                symbol: "exclamationmark.triangle.fill",
                tone: .danger,
                isActive: false,
                canEnd: false
            )
        }
        if isStreaming {
            if let activity, activity.kind == .toolStarted {
                return AIChatTaskState(
                    title: "Using \(activity.displayTitle)",
                    detail: activity.detail ?? "Running a requested tool",
                    symbol: "wrench.and.screwdriver.fill",
                    tone: .active,
                    isActive: true,
                    canEnd: true
                )
            }
            if !streamingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || (assistant?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) {
                return AIChatTaskState(
                    title: "Writing response",
                    detail: "Streaming visible answer",
                    symbol: "text.line.first.and.arrowtriangle.forward",
                    tone: .active,
                    isActive: true,
                    canEnd: true
                )
            }
            if !streamingReasoningSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || (assistant?.reasoningSummary?.isEmpty == false) || activity?.kind == .reasoningSummary {
                return AIChatTaskState(
                    title: "Reasoning",
                    detail: "Working through the request",
                    symbol: "brain.head.profile",
                    tone: .active,
                    isActive: true,
                    canEnd: true
                )
            }
            return AIChatTaskState(
                title: "Thinking",
                detail: "Preparing a response",
                symbol: "sparkles",
                tone: .active,
                isActive: true,
                canEnd: true
            )
        }

        guard let activity else {
            return AIChatTaskState(
                title: "Ready",
                detail: "Ask a question or add context",
                symbol: "sparkles",
                tone: .neutral,
                isActive: false,
                canEnd: false
            )
        }

        switch activity.kind {
        case .error, .toolFailed:
            return AIChatTaskState(
                title: activity.title,
                detail: activity.detail ?? "The task did not complete.",
                symbol: "exclamationmark.triangle.fill",
                tone: .danger,
                isActive: false,
                canEnd: false
            )
        case .completed, .toolCompleted:
            let stopped = activity.title == "Stopped" || activity.title == "Task ended"
            return AIChatTaskState(
                title: stopped ? activity.title : "Response complete",
                detail: activity.detail ?? activity.usage?.displayText ?? (stopped ? "You ended this task." : "Ready for a follow-up"),
                symbol: stopped ? "stop.fill" : "checkmark.circle.fill",
                tone: stopped ? .warning : .success,
                isActive: false,
                canEnd: false
            )
        case .toolApproval:
            return AIChatTaskState(
                title: activity.title,
                detail: activity.detail ?? "A tool decision was recorded",
                symbol: "hand.raised.fill",
                tone: .warning,
                isActive: false,
                canEnd: false
            )
        case .toolStarted:
            return AIChatTaskState(
                title: activity.title,
                detail: activity.detail ?? "Tool activity recorded",
                symbol: "wrench.and.screwdriver.fill",
                tone: .neutral,
                isActive: false,
                canEnd: false
            )
        case .reasoningSummary, .thinking, .started, .attachment:
            return AIChatTaskState(
                title: activity.title,
                detail: activity.detail ?? "Task activity recorded",
                symbol: activity.kind == .attachment ? "paperclip" : "sparkles",
                tone: .neutral,
                isActive: false,
                canEnd: false
            )
        }
    }

    func refreshModels() { loadProviderModels(reportConnection: false) }
    func testConnection() { loadProviderModels(reportConnection: true) }
    func cancelModelDiscovery() { modelDiscoveryTask?.cancel() }

    private func loadProviderModels(reportConnection: Bool) {
        guard !isLoadingModels, !canEndTask else { return }
        guard credentials.configuration.usesKeychain || transport is FixtureAITransport else {
            providerConnectionMessage = "This fixture scenario does not make provider requests."
            return
        }
        guard !LimaTestEnvironment.isEnabled || LimaTestEnvironment.allowsLiveAI || transport is FixtureAITransport else {
            providerConnectionMessage = "Live AI testing is disabled for this test session."
            return
        }
        guard let apiKey = requestAPIKey(for: provider) else {
            providerConnectionMessage = "Save an API key for " + provider.title + " before testing the connection."
            return
        }
        let selectedProvider = provider
        let conversationID = selectedConversationID
        let endpoint = providerPreferences.openAICompatibleBaseURL
        let client = providerClient(for: selectedProvider)
        isLoadingModels = true
        providerConnectionMessage = nil
        let taskID = taskRegistry.begin(kind: .aiTool, title: "Checking AI provider",
            isCancellable: true, onCancel: { [weak self] in self?.cancelModelDiscovery() })
        modelDiscoveryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isLoadingModels = false; self.modelDiscoveryTask = nil }
            do {
                let models = try await client.listModels(apiKey: apiKey)
                try Task.checkCancellation()
                guard self.provider == selectedProvider, self.selectedConversationID == conversationID,
                      selectedProvider != .openAICompatible || endpoint == providerPreferences.openAICompatibleBaseURL else {
                    self.taskRegistry.finish(taskID, state: .cancelled)
                    return
                }
                self.availableModels = models
                self.ensureModelIsAvailable()

                if reportConnection {
                    let testedModel = self.model
                    var completed = false
                    var safeFailure: String?
                    var probeDiagnostic: AIChatDiagnostic?
                    let probe = client.streamReply(
                        apiKey: apiKey,
                        model: testedModel,
                        input: "Reply with exactly: Lima connection test passed.",
                        history: [],
                        previousResponseID: nil,
                        reasoningEffort: self.reasoningEffort,
                        attachments: [],
                        mcpServers: [],
                        localTools: [],
                        systemInstructions: "Connection test. Return a short confirmation only."
                    )
                    do {
                        for try await event in probe {
                            try Task.checkCancellation()
                            switch event {
                            case .completed:
                                completed = true
                            case .diagnostic(let diagnostic):
                                if diagnostic.stage == .api || diagnostic.stage == .transport {
                                    probeDiagnostic = diagnostic
                                }
                            case .failed(let message):
                                safeFailure = AIProviderFailure.presentation(
                                    provider: selectedProvider.title,
                                    model: testedModel,
                                    status: probeDiagnostic?.httpStatus,
                                    code: probeDiagnostic?.errorCode,
                                    parameter: probeDiagnostic?.errorParameter,
                                    fallback: message
                                )
                            default:
                                break
                            }
                        }
                    } catch {
                        if Task.isCancelled || error is CancellationError { throw error }
                        safeFailure = AIProviderFailure.presentation(
                            provider: selectedProvider.title,
                            model: testedModel,
                            status: probeDiagnostic?.httpStatus,
                            code: probeDiagnostic?.errorCode,
                            parameter: probeDiagnostic?.errorParameter,
                            fallback: AIProviderFailure.transport(error)
                        )
                    }
                    try Task.checkCancellation()
                    guard self.provider == selectedProvider, self.selectedConversationID == conversationID else {
                        self.taskRegistry.finish(taskID, state: .cancelled)
                        return
                    }
                    if let safeFailure {
                        self.taskRegistry.finish(taskID, state: .failed)
                        self.providerConnectionMessage = "Basic request failed · " + safeFailure
                        return
                    }
                    guard completed else {
                        self.taskRegistry.finish(taskID, state: .failed)
                        self.providerConnectionMessage = "The model request ended before a response completed."
                        return
                    }
                    self.providerConnectionMessage = "Verified " + testedModel + " with a basic response request · " + String(models.count) + " models available."
                }
                self.taskRegistry.finish(taskID)
                self.streamError = nil
            } catch {
                let cancelled = Task.isCancelled || error is CancellationError
                self.taskRegistry.finish(taskID, state: cancelled ? .cancelled : .failed)
                guard self.provider == selectedProvider, self.selectedConversationID == conversationID else { return }
                self.providerConnectionMessage = cancelled ? "Connection check stopped." : AIProviderFailure.transport(error)
            }
        }
    }

    func configureCompatibleProvider(baseURL: String, modelID: String) -> Bool {
        guard !canEndTask, !isLoadingModels, let url = AIProviderHTTP.validateBaseURL(baseURL) else { return false }
        let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.utf8.count <= 256,
              !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        providerPreferences.openAICompatibleBaseURL = url.absoluteString
        providerPreferences.openAICompatibleModelID = id
        providerConnectionMessage = nil
        if provider == .openAICompatible {
            let option = AIModelOption(id: id, displayName: id, supportsReasoning: false)
            availableModels = [option]
            selectModel(option)
        }
        return true
    }

    func selectCustomModel(_ raw: String) -> Bool {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canEndTask, !isLoadingModels, !id.isEmpty, id.utf8.count <= 256,
              !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        selectModel(provider == .openAI ? AIModelOption(id: id)
            : AIModelOption(id: id, displayName: id, supportsReasoning: false))
        return true
    }

    func selectModel(_ option: AIModelOption) {
        guard !canEndTask else { return }
        model = option.id
        if !availableModels.contains(where: { $0.id == option.id }) { availableModels.append(option) }
        if provider == .openAICompatible {
            providerPreferences.openAICompatibleModelID = model
        }
        if !option.supportedReasoningEfforts.contains(reasoningEffort) {
            reasoningEffort = option.defaultReasoningEffort ?? .medium
        }
        if let id = selectedConversationID, var conversation = store.conversation(id: id) {
            conversation.provider = provider
            conversation.model = model
            conversation.lastResponseID = nil
            conversation.reasoningEffort = reasoningEffort
            store.update(conversation)
        }
    }

    func selectReasoningEffort(_ effort: AIReasoningEffort) {
        guard !canEndTask, selectedModelOption.supportedReasoningEfforts.contains(effort) else { return }
        reasoningEffort = effort
        if let id = selectedConversationID, var conversation = store.conversation(id: id) {
            conversation.reasoningEffort = effort
            store.update(conversation)
        }
    }

    private func ensureModelIsAvailable() {
        if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model = availableModels.first?.id ?? provider.defaultChatModel
        }
        // A saved or user-entered model may be newer than the bundled catalog.
        // Never silently replace a conversation's model when restoring it.
        if !availableModels.contains(where: { $0.id == model }) {
            availableModels.append(provider == .openAICompatible
                ? AIModelOption(id: model, displayName: model, supportsReasoning: false)
                : AIModelOption(id: model))
        }
        if provider == .openAICompatible {
            providerPreferences.openAICompatibleModelID = model
        }
        if !selectedModelOption.supportedReasoningEfforts.contains(reasoningEffort) {
            reasoningEffort = selectedModelOption.defaultReasoningEffort ?? .medium
        }
    }

    func newConversation() {
        guard !canEndTask else { return }
        let conversation = store.createConversation(provider: provider, model: model)
        selectedConversationID = conversation.id
        streamError = nil
        attachments = []
        draft = ""
    }

    func deleteSelectedConversation() {
        guard let selectedConversationID else { return }
        deleteConversation(selectedConversationID)
    }

    func deleteConversation(_ id: UUID) {
        guard !canEndTask, store.conversation(id: id) != nil else { return }
        let deletingSelection = selectedConversationID == id
        store.delete(id: id)
        guard deletingSelection else { return }
        draft = ""
        attachments = []
        streamError = nil
        if let next = store.conversations.first { select(next.id) }
        else { selectedConversationID = nil }
    }

    func appendDictationText(_ delta: String) {
        guard !canEndTask, !delta.isEmpty else { return }
        if let last = draft.last, let first = delta.first,
           !last.isWhitespace, !first.isWhitespace {
            draft += " "
        }
        draft += delta
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming, pendingApproval == nil else { return }
        if let message = readOnlyBrowserActionMessage(for: text) {
            recordLocalRequestFailure(title: "Browser action unavailable", message: message, prompt: text)
            return
        }
        guard credentials.configuration.usesKeychain || transport is FixtureAITransport else {
            streamError = "This fixture scenario does not make provider requests."
            return
        }
        guard !LimaTestEnvironment.isEnabled || LimaTestEnvironment.allowsLiveAI || transport is FixtureAITransport else {
            streamError = "Live AI testing is disabled for this test session. Set LIMA_ALLOW_LIVE_AI_TESTS=1 to enable it."
            return
        }
        guard let apiKey = requestAPIKey(for: provider) else {
            streamError = "Add an \(provider.title) API key in the setup panel before sending a message."
            return
        }

        var conversation = selectedConversation ?? store.createConversation(provider: provider, model: model)
        selectedConversationID = conversation.id
        conversation.provider = provider
        conversation.model = model
        conversation.messages.append(AIChatMessage(role: .user, text: text))
        if conversation.title == "New Chat" {
            conversation.title = String(text.prefix(64))
        }
        conversation.updatedAt = Date()

        conversation.reasoningEffort = reasoningEffort
        conversation.attachments = attachments
        let assistantID = UUID()
        conversation.messages.append(AIChatMessage(
            id: assistantID,
            role: .assistant,
            text: "",
            activities: [AIAgentActivity(kind: .started, title: "Started", completed: false)]
        ))
        beginStreamingText(for: assistantID)
        activeAssistantID = assistantID
        activeConversationID = conversation.id
        store.update(conversation)
        draft = ""
        streamError = nil
        streamDiagnostics = []
        showDiagnostics = false
        pendingApproval = nil
        pendingLocalFunctionCall = nil
        isStreaming = true
        registeredTaskID = taskRegistry.begin(
            kind: .aiGeneration,
            title: "AI is working",
            detail: "Preparing a response",
            isCancellable: true,
            onCancel: { [weak self] in self?.cancel() }
        )
        performanceMeasurementID = PerformanceMonitor.shared.begin("AI request")
        firstTokenPerformanceMeasurementID = PerformanceMonitor.shared.begin("AI composer to first token")
        CrashRecoveryStore.shared.update { snapshot in
            snapshot.activeSurface = LimaSurfaceID.workspace.rawValue
            snapshot.activeWorkspaceModule = LimaWorkspaceModule.ai.rawValue
            snapshot.selectedConversationID = conversation.id
        }

        let providerHistory = AIProviderMessage.transcript(conversation.messages)
        let routedLocalTools = routedNativeTools(for: text)
        let routedMCPServers = routedMCPServers(for: text)
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            let client = self.providerClient(for: conversation.provider)
            let responseID = await self.runToolLoop(
                initialStream: client.streamReply(
                    apiKey: apiKey,
                    model: conversation.model,
                    input: text,
                    history: providerHistory,
                    previousResponseID: conversation.lastResponseID,
                    reasoningEffort: conversation.reasoningEffort,
                    attachments: conversation.attachments,
                    mcpServers: routedMCPServers,
                    localTools: routedLocalTools,
                    systemInstructions: self.systemInstructions
                ),
                client: client,
                apiKey: apiKey,
                conversationID: conversation.id,
                assistantID: assistantID,
                model: conversation.model,
                reasoningEffort: conversation.reasoningEffort,
                mcpServers: routedMCPServers,
                localTools: routedLocalTools,
                history: providerHistory,
                initialResponseID: nil
            )
            self.finishStream(conversationID: conversation.id, assistantID: assistantID, responseID: responseID)
        }
    }

    private func recordLocalRequestFailure(title: String, message: String, prompt: String) {
        var conversation = selectedConversation ?? store.createConversation(provider: provider, model: model)
        selectedConversationID = conversation.id
        conversation.provider = provider
        conversation.model = model
        conversation.messages.append(AIChatMessage(role: .user, text: prompt))
        conversation.messages.append(AIChatMessage(
            role: .assistant,
            text: "⚠︎ \(title)\n\n\(message)",
            activities: [AIAgentActivity(kind: .error, title: title, detail: message, completed: true)]
        ))
        if conversation.title == "New Chat" { conversation.title = String(prompt.prefix(64)) }
        conversation.updatedAt = Date()
        store.update(conversation)
        draft = ""
        streamError = nil
    }

    func cancel() {
        guard isStreaming else {
            endTask()
            return
        }
        streamTask?.cancel()
        streamTask = nil
        pendingApproval = nil
        pendingLocalFunctionCall = nil
        if let assistantID = activeAssistantID {
            cancelledAssistantIDs.insert(assistantID)
        }
        if let conversationID = activeConversationID ?? selectedConversationID {
            commitStreamingText(conversationID: conversationID, assistantID: activeAssistantID)
            appendTurnActivity(
                AIAgentActivity(
                    kind: .completed,
                    title: "Stopped",
                    detail: "Generation stopped by user",
                    completed: true
                ),
                conversationID: conversationID
            )
        }
        isStreaming = false
        finishSharedTask(state: .cancelled, detail: "Generation stopped by user")
    }

    /// End an active stream or dismiss an approval that has paused the task.
    /// The assistant turn remains in the local transcript with a visible end state.
    func endTask() {
        if isStreaming {
            cancel()
            return
        }
        guard let conversationID = activeConversationID ?? selectedConversationID,
              let assistantID = activeAssistantID else {
            pendingApproval = nil
            pendingLocalFunctionCall = nil
            return
        }

        pendingApproval = nil
        pendingLocalFunctionCall = nil
        updateAssistant(conversationID: conversationID, assistantID: assistantID) { assistant in
            if assistant.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                assistant.text = "Task ended before the requested tool was run."
            }
            assistant.activities = (assistant.activities ?? []) + [
                AIAgentActivity(
                    kind: .completed,
                    title: "Task ended",
                    detail: "Ended by user before approval",
                    completed: true
                )
            ]
        }
        activeAssistantID = nil
        activeConversationID = nil
        finishSharedTask(state: .cancelled, detail: "Task ended before approval")
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

    private struct StreamCycle {
        var responseID: String?
        var functionCalls: [AIOutputItem]
    }

    private func runToolLoop(
        initialStream: AsyncThrowingStream<AIChatStreamEvent, Error>,
        client: any AIChatTransport,
        apiKey: String,
        conversationID: UUID,
        assistantID: UUID,
        model: String,
        reasoningEffort: AIReasoningEffort,
        mcpServers: [MCPServer],
        localTools: [LimaAIToolDefinition],
        history: [AIProviderMessage],
        initialResponseID: String?
    ) async -> String? {
        var stream = initialStream
        var currentHistory = history
        var latestResponseID = initialResponseID
        var handledCallIDs = Set<String>()

        while !Task.isCancelled {
            let cycle = await consume(
                stream: stream,
                conversationID: conversationID,
                assistantID: assistantID,
                initialResponseID: latestResponseID
            )
            latestResponseID = cycle.responseID ?? latestResponseID
            if let latestResponseID {
                persistResponseID(latestResponseID, conversationID: conversationID)
            }
            guard !Task.isCancelled, streamError == nil, pendingApproval == nil,
                  let responseID = latestResponseID else { break }

            let calls = cycle.functionCalls.filter {
                guard let callID = $0.callID, !handledCallIDs.contains(callID) else { return false }
                handledCallIDs.insert(callID)
                return true
            }
            guard !calls.isEmpty else { break }

            if let approvalCall = calls.first(where: {
                LimaAIToolRegistry.definition(for: $0.name)?.risk.requiresApproval == true
            }) {
                queueLocalApproval(for: approvalCall, conversationID: conversationID)
                break
            }

            var outputs: [[String: Any]] = []
            for call in calls {
                guard !Task.isCancelled, streamError == nil else { break }
                if let output = await executeLocalTool(call, allowedTools: localTools, conversationID: conversationID) {
                    outputs.append(output)
                }
            }
            guard !Task.isCancelled, streamError == nil, !outputs.isEmpty else { break }
            let toolUses = calls.compactMap { call -> AIProviderMessage.Content? in
                guard let id = call.callID, let name = call.name else { return nil }
                return .toolUse(id: id, name: name, arguments: call.arguments ?? "{}")
            }
            let toolUseIDs = Set(calls.compactMap(\.callID))
            let toolResults = outputs.compactMap { output -> AIProviderMessage.Content? in
                guard let id = output["call_id"] as? String, toolUseIDs.contains(id),
                      let value = output["output"] as? String else { return nil }
                return .toolResult(id: id, output: value)
            }
            if !toolUses.isEmpty { currentHistory.append(AIProviderMessage(role: .assistant, content: toolUses)) }
            if !toolResults.isEmpty { currentHistory.append(AIProviderMessage(role: .user, content: toolResults)) }
            stream = client.streamToolOutputs(
                apiKey: apiKey,
                model: model,
                previousResponseID: responseID,
                history: currentHistory,
                outputs: outputs,
                reasoningEffort: reasoningEffort,
                mcpServers: mcpServers,
                localTools: localTools,
                systemInstructions: self.systemInstructions
            )
        }
        return latestResponseID
    }

    private func consume(
        stream: AsyncThrowingStream<AIChatStreamEvent, Error>,
        conversationID: UUID,
        assistantID: UUID,
        initialResponseID: String?
    ) async -> StreamCycle {
        var responseID = initialResponseID
        var functionCalls: [AIOutputItem] = []
        var completed = false
        do {
            for try await event in stream {
                guard !Task.isCancelled else { break }
                if case .completed = event { completed = true }
                if let call = apply(event, conversationID: conversationID, assistantID: assistantID, responseID: &responseID) {
                    functionCalls.append(call)
                }
            }
        } catch {
            if !Task.isCancelled, streamError == nil {
                streamError = "AI Chat couldn’t complete this request."
            }
        }
        if !Task.isCancelled, streamError == nil, pendingApproval == nil, !completed {
            streamError = "The provider stream ended before the response completed."
        }
        return StreamCycle(responseID: responseID, functionCalls: streamError == nil ? functionCalls : [])
    }

    private func queueLocalApproval(for call: AIOutputItem, conversationID: UUID) {
        guard let definition = LimaAIToolRegistry.definition(for: call.name),
              let callID = call.callID else {
            _ = localToolFailureOutput(for: call, conversationID: conversationID, message: "The function call did not include a usable call identifier.")
            return
        }
        pendingLocalFunctionCall = call
        pendingApproval = AIToolApprovalRequest(
            localCallID: callID,
            localToolID: definition.id,
            serverLabel: "Lima",
            toolName: definition.name,
            arguments: call.arguments
        )
        appendTurnActivity(
            AIAgentActivity(
                kind: .toolApproval,
                title: "Approval needed",
                detail: "Lima · \(definition.name)",
                requiresApproval: true
            ),
            conversationID: conversationID
        )
    }

    private func executeLocalTool(
        _ call: AIOutputItem,
        allowedTools: [LimaAIToolDefinition],
        conversationID: UUID
    ) async -> [String: Any]? {
        guard let definition = LimaAIToolRegistry.definition(for: call.name) else {
            return localToolFailureOutput(for: call, conversationID: conversationID, message: "The requested Lima tool is not registered.")
        }
        guard allowedTools.contains(where: { $0.id == definition.id }) else {
            return localToolFailureOutput(for: call, conversationID: conversationID, message: "The requested Lima tool was not routed for this request.")
        }
        guard let callID = call.callID else {
            appendTurnActivity(
                AIAgentActivity(kind: .toolFailed, title: definition.name, detail: "Missing function call ID.", completed: true),
                conversationID: conversationID
            )
            streamDiagnostics.append(AIChatDiagnostic(stage: .tool, toolName: definition.name, message: "The function call omitted call_id."))
            return nil
        }

        appendTurnActivity(
            AIAgentActivity(kind: .toolStarted, title: definition.name, detail: "Lima", completed: false),
            conversationID: conversationID
        )
        let toolStartedAt = Date()
        let result = await LimaAIToolRegistry.execute(call)
        PerformanceMonitor.shared.record(
            "AI tool duration",
            startedAt: toolStartedAt,
            duration: max(0, Date().timeIntervalSince(toolStartedAt)),
            succeeded: !result.isError
        )
        appendTurnActivity(
            AIAgentActivity(
                kind: result.isError ? .toolFailed : .toolCompleted,
                title: definition.name,
                detail: result.isError ? "Lima tool returned an error." : nil,
                completed: true
            ),
            conversationID: conversationID
        )
        return ["type": "function_call_output", "call_id": callID, "output": result.output]
    }

    private func localToolFailureOutput(
        for call: AIOutputItem,
        conversationID: UUID,
        message: String
    ) -> [String: Any]? {
        let name = call.name ?? "Lima tool"
        appendTurnActivity(
            AIAgentActivity(kind: .toolFailed, title: name, detail: message, completed: true),
            conversationID: conversationID
        )
        streamDiagnostics.append(AIChatDiagnostic(stage: .tool, toolName: call.name, message: message))
        guard let callID = call.callID else { return nil }
        let result = LimaAIToolExecution.json(["error": message], isError: true)
        return ["type": "function_call_output", "call_id": callID, "output": result.output]
    }

    func dismissPendingApproval() {
        endTask()
    }

    func resolvePendingApproval(allow: Bool) {
        guard credentials.configuration.usesKeychain || transport is FixtureAITransport else {
            pendingApproval = nil
            pendingLocalFunctionCall = nil
            streamError = "This fixture scenario does not make provider requests."
            return
        }
        guard !LimaTestEnvironment.isEnabled || LimaTestEnvironment.allowsLiveAI || transport is FixtureAITransport else {
            streamError = "Live AI testing is disabled for this test session. Set LIMA_ALLOW_LIVE_AI_TESTS=1 to enable it."
            return
        }
        guard let approval = pendingApproval,
              let conversation = selectedConversation,
              let previousResponseID = conversation.lastResponseID,
              let apiKey = requestAPIKey(for: conversation.provider) else {
            pendingApproval = nil
            pendingLocalFunctionCall = nil
            streamError = "AI Chat couldn’t continue this tool request because its response session is unavailable."
            return
        }

        let localCall = pendingLocalFunctionCall
        // Remote MCP requests are never allowed, even if a malformed or legacy
        // response manages to reach this continuation path.
        let allowed = approval.remoteApprovalID == nil && allow
        pendingApproval = nil
        pendingLocalFunctionCall = nil
        appendTurnActivity(
            AIAgentActivity(
                kind: .toolApproval,
                title: allowed ? "Tool allowed once" : "Tool denied",
                detail: "\(approval.serverLabel) · \(approval.toolName)",
                requiresApproval: true,
                completed: true
            ),
            conversationID: conversation.id
        )

        let assistantID: UUID
        if let existing = conversation.messages.last(where: { $0.role == .assistant }) {
            assistantID = existing.id
        } else {
            assistantID = UUID()
            updateConversation(conversation.id) { $0.messages.append(AIChatMessage(id: assistantID, role: .assistant, text: "")) }
        }

        activeAssistantID = assistantID
        activeConversationID = conversation.id
        streamError = nil
        isStreaming = true
        let routingPrompt = conversation.messages.last(where: { $0.role == .user })?.text ?? ""
        let routedLocalTools = routedNativeTools(for: routingPrompt)
        let routedMCPServers = routedMCPServers(for: routingPrompt)
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            let client = self.providerClient(for: conversation.provider)
            var toolHistory = AIProviderMessage.transcript(conversation.messages)

            if let localCall {
                let output: [String: Any]?
                if allowed {
                    output = await self.executeLocalTool(localCall, allowedTools: routedLocalTools, conversationID: conversation.id)
                } else if let callID = localCall.callID {
                    let denied = LimaAIToolExecution.json(["denied": true, "message": "Denied by the user in Lima."])
                    output = ["type": "function_call_output", "call_id": callID, "output": denied.output]
                } else {
                    output = self.localToolFailureOutput(for: localCall, conversationID: conversation.id, message: "The local tool request did not include a usable call identifier.")
                }

                guard let output else {
                    self.finishStream(conversationID: conversation.id, assistantID: assistantID, responseID: previousResponseID)
                    return
                }
                if let id = localCall.callID, let name = localCall.name {
                    toolHistory.append(AIProviderMessage(role: .assistant, content: [
                        .toolUse(id: id, name: name, arguments: localCall.arguments ?? "{}")
                    ]))
                    if let result = output["output"] as? String {
                        toolHistory.append(AIProviderMessage(role: .user, content: [.toolResult(id: id, output: result)]))
                    }
                }
                let responseID = await self.runToolLoop(
                    initialStream: client.streamToolOutputs(
                        apiKey: apiKey,
                        model: conversation.model,
                        previousResponseID: previousResponseID,
                        history: toolHistory,
                        outputs: [output],
                        reasoningEffort: conversation.reasoningEffort,
                        mcpServers: routedMCPServers,
                        localTools: routedLocalTools,
                        systemInstructions: self.systemInstructions
                    ),
                    client: client,
                    apiKey: apiKey,
                    conversationID: conversation.id,
                    assistantID: assistantID,
                    model: conversation.model,
                    reasoningEffort: conversation.reasoningEffort,
                    mcpServers: routedMCPServers,
                    localTools: routedLocalTools,
                    history: toolHistory,
                    initialResponseID: previousResponseID
                )
                self.finishStream(conversationID: conversation.id, assistantID: assistantID, responseID: responseID)
                return
            }

            guard let remoteApprovalID = approval.remoteApprovalID else {
                self.streamError = "AI Chat couldn’t identify the MCP approval request."
                self.finishStream(conversationID: conversation.id, assistantID: assistantID, responseID: previousResponseID)
                return
            }
            let responseID = await self.runToolLoop(
                initialStream: client.streamApproval(
                    apiKey: apiKey,
                    model: conversation.model,
                    previousResponseID: previousResponseID,
                    requestID: remoteApprovalID,
                    approve: allowed,
                    reason: allowed ? nil : "Lima AI Chat is read-only",
                    reasoningEffort: conversation.reasoningEffort,
                    mcpServers: routedMCPServers,
                    localTools: routedLocalTools,
                    systemInstructions: self.systemInstructions
                ),
                client: client,
                apiKey: apiKey,
                conversationID: conversation.id,
                assistantID: assistantID,
                model: conversation.model,
                reasoningEffort: conversation.reasoningEffort,
                mcpServers: routedMCPServers,
                localTools: routedLocalTools,
                history: toolHistory,
                initialResponseID: previousResponseID
            )
            self.finishStream(conversationID: conversation.id, assistantID: assistantID, responseID: responseID)
        }
    }

    @discardableResult
    private func apply(
        _ event: AIChatStreamEvent,
        conversationID: UUID,
        assistantID: UUID,
        responseID: inout String?
    ) -> AIOutputItem? {
        switch event {
        case .responseCreated(let id):
            responseID = id
        case .textDelta(let delta):
            if let measurementID = firstTokenPerformanceMeasurementID {
                PerformanceMonitor.shared.end(measurementID)
                firstTokenPerformanceMeasurementID = nil
            }
            appendStreamingText(delta, assistantID: assistantID)
        case .reasoningSummaryDelta(let delta):
            appendStreamingReasoning(delta, assistantID: assistantID)
        case .outputItem(let item):
            switch item.kind {
            case .mcpApprovalRequest:
                // The outgoing allowlist contains read tools only. Treat any
                // approval request as a protocol mismatch rather than offering a
                // path to run an unclassified remote action.
                let server = item.serverLabel ?? "Remote MCP"
                let tool = item.name ?? "tool"
                streamError = "Lima blocked \(server)’s \(tool) request because AI Chat is read-only."
                appendTurnActivity(
                    AIAgentActivity(
                        kind: .toolFailed,
                        title: "Blocked non-read-only tool",
                        detail: "\(server) · \(tool)",
                        completed: true
                    ),
                    conversationID: conversationID
                )
            case .functionCall:
                if item.phase == .added {
                    appendTurnActivity(
                        AIAgentActivity(kind: .toolStarted, title: item.name ?? "Lima tool", detail: "Lima"),
                        conversationID: conversationID
                    )
                } else {
                    return item
                }
            case .mcpCall, .toolCall:
                let title = item.name ?? "Tool call"
                if item.phase == .added {
                    appendTurnActivity(
                        AIAgentActivity(kind: .toolStarted, title: title, detail: item.serverLabel),
                        conversationID: conversationID
                    )
                } else {
                    appendTurnActivity(
                        AIAgentActivity(
                            kind: item.errorMessage == nil ? .toolCompleted : .toolFailed,
                            title: title,
                            detail: item.errorMessage,
                            completed: true
                        ),
                        conversationID: conversationID
                    )
                }
            case .message, .reasoning, .unknown:
                break
            }
        case .activity(let activity):
            appendTurnActivity(activity, conversationID: conversationID)
        case .approval(let request):
            pendingApproval = request
            if let registeredTaskID {
                taskRegistry.update(
                    registeredTaskID,
                    title: "AI needs attention",
                    detail: "Awaiting tool decision",
                    state: .waiting
                )
            }
            appendTurnActivity(
                AIAgentActivity(
                    kind: .toolApproval,
                    title: "Approval needed",
                    detail: "\(request.serverLabel) · \(request.toolName)",
                    requiresApproval: true
                ),
                conversationID: conversationID
            )
        case .diagnostic(let diagnostic):
            recordDiagnostic(diagnostic)
        case .usage(let usage):
            appendTurnActivity(AIAgentActivity(kind: .completed, title: "Usage", usage: usage, completed: true), conversationID: conversationID)
        case .completed(let id):
            responseID = id ?? responseID
        case .failed(let message):
            let summary = userFacingFailurePresentation(message)
            streamError = summary
            updateAssistant(conversationID: conversationID, assistantID: assistantID) { assistant in
                let pendingText = self.pendingStreamTextChunks.joined()
                let hasVisibleText = !self.streamingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !pendingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if assistant.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !hasVisibleText {
                    assistant.text = "⚠︎ Request failed\n\n\(summary)"
                }
            }
            appendTurnActivity(AIAgentActivity(kind: .error, title: "Request failed", detail: summary, completed: true), conversationID: conversationID)
        }
        return nil
    }

    private func recordDiagnostic(_ diagnostic: AIChatDiagnostic) {
        streamDiagnostics.append(diagnostic)
        if streamDiagnostics.count > 40 {
            streamDiagnostics.removeFirst(streamDiagnostics.count - 40)
        }
    }

    private func userFacingFailurePresentation(_ message: String) -> String {
        let diagnostic = streamDiagnostics.reversed().first { diagnostic in
            diagnostic.stage == .api || diagnostic.stage == .transport
        }
        return AIProviderFailure.presentation(
            provider: provider.title,
            model: model,
            status: diagnostic?.httpStatus,
            code: diagnostic?.errorCode,
            parameter: diagnostic?.errorParameter,
            fallback: message
        )
    }

    private func persistResponseID(_ responseID: String, conversationID: UUID) {
        updateConversation(conversationID) { conversation in
            conversation.lastResponseID = responseID
        }
    }

    private func appendTurnActivity(_ activity: AIAgentActivity, conversationID: UUID) {
        guard let assistantID = activeAssistantID else {
            updateConversation(conversationID) { $0.activities.append(activity) }
            return
        }
        updateAssistant(conversationID: conversationID, assistantID: assistantID) {
            $0.activities = ($0.activities ?? []) + [activity]
        }
    }

    private func beginStreamingText(for assistantID: UUID) {
        streamTextFlushTask?.cancel()
        pendingStreamTextChunks.removeAll(keepingCapacity: true)
        pendingStreamReasoningChunks.removeAll(keepingCapacity: true)
        streamingText = ""
        streamingReasoningSummary = ""
        streamingTextAssistantID = assistantID
    }

    private func appendStreamingText(_ delta: String, assistantID: UUID) {
        guard streamingTextAssistantID == assistantID, !delta.isEmpty else { return }
        pendingStreamTextChunks.append(delta)
        scheduleStreamingFlush()
    }

    private func appendStreamingReasoning(_ delta: String, assistantID: UUID) {
        guard streamingTextAssistantID == assistantID, !delta.isEmpty else { return }
        pendingStreamReasoningChunks.append(delta)
        scheduleStreamingFlush()
    }

    private func scheduleStreamingFlush() {
        guard streamTextFlushTask == nil else { return }
        streamTextFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            self?.flushStreamingText()
        }
    }

    private func flushStreamingText() {
        streamTextFlushTask?.cancel()
        streamTextFlushTask = nil
        let textBatch = pendingStreamTextChunks.joined()
        let reasoningBatch = pendingStreamReasoningChunks.joined()
        pendingStreamTextChunks.removeAll(keepingCapacity: true)
        pendingStreamReasoningChunks.removeAll(keepingCapacity: true)
        guard !textBatch.isEmpty || !reasoningBatch.isEmpty else { return }
        streamingText.append(contentsOf: textBatch)
        streamingReasoningSummary.append(contentsOf: reasoningBatch)
    }

    private func commitStreamingText(conversationID: UUID, assistantID: UUID?) {
        guard let assistantID, streamingTextAssistantID == assistantID else { return }
        flushStreamingText()
        guard var conversation = store.conversation(id: conversationID),
              let index = conversation.messages.firstIndex(where: { $0.id == assistantID }) else { return }
        conversation.messages[index].text = streamingText
        if !streamingReasoningSummary.isEmpty {
            conversation.messages[index].reasoningSummary = streamingReasoningSummary
        }
        conversation.updatedAt = Date()
        store.update(conversation)
        pendingStreamTextChunks.removeAll(keepingCapacity: true)
        pendingStreamReasoningChunks.removeAll(keepingCapacity: true)
        streamingTextAssistantID = nil
        streamingText = ""
        streamingReasoningSummary = ""
    }

    private func finishStream(conversationID: UUID, assistantID: UUID, responseID: String?) {
        let wasCancelled = cancelledAssistantIDs.remove(assistantID) != nil
        defer {
            if pendingApproval == nil {
                let state: LimaTaskState = wasCancelled ? .cancelled : (streamError == nil ? .completed : .failed)
                finishSharedTask(state: state, detail: streamError == nil ? nil : "Request needs attention")
            }
            isStreaming = false
            streamTask = nil
            if activeAssistantID == assistantID, pendingApproval == nil {
                activeAssistantID = nil
                activeConversationID = nil
            }
        }
        flushStreamingText()
        guard var conversation = store.conversation(id: conversationID) else { return }
        if let index = conversation.messages.firstIndex(where: { $0.id == assistantID }) {
            if streamingTextAssistantID == assistantID {
                if !streamingText.isEmpty { conversation.messages[index].text = streamingText }
                if !streamingReasoningSummary.isEmpty {
                    conversation.messages[index].reasoningSummary = streamingReasoningSummary
                }
            }
            conversation.messages[index].responseID = responseID
            if pendingApproval == nil && conversation.messages[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                conversation.messages[index].text = wasCancelled
                    ? "Generation stopped."
                    : "The AI service completed without returning visible text. You can retry this request."
            }
            if pendingApproval == nil && !wasCancelled {
                let start = conversation.messages[index].activities?.first?.startedAt ?? Date()
                conversation.messages[index].activities = (conversation.messages[index].activities ?? []) + [
                    AIAgentActivity(
                        kind: streamError == nil ? .completed : .error,
                        title: streamError == nil ? "Completed" : "Request failed",
                        detail: streamError,
                        duration: Date().timeIntervalSince(start),
                        completed: true
                    )
                ]
            }
        }
        if let responseID { conversation.lastResponseID = responseID }
        conversation.updatedAt = Date()
        store.update(conversation)
        if pendingApproval == nil, streamingTextAssistantID == assistantID {
            streamTextFlushTask?.cancel()
            streamTextFlushTask = nil
            pendingStreamTextChunks.removeAll(keepingCapacity: true)
            pendingStreamReasoningChunks.removeAll(keepingCapacity: true)
            streamingTextAssistantID = nil
            streamingText = ""
            streamingReasoningSummary = ""
        }
    }

    private func finishSharedTask(state: LimaTaskState, detail: String? = nil) {
        if let registeredTaskID {
            taskRegistry.finish(registeredTaskID, state: state, detail: detail)
            self.registeredTaskID = nil
        }
        if let performanceMeasurementID {
            PerformanceMonitor.shared.end(performanceMeasurementID, succeeded: state == .completed)
            self.performanceMeasurementID = nil
        }
        if let firstTokenPerformanceMeasurementID {
            PerformanceMonitor.shared.end(
                firstTokenPerformanceMeasurementID,
                succeeded: false,
                detail: "No text delta"
            )
            self.firstTokenPerformanceMeasurementID = nil
        }
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

    #if DEBUG
    func applyVisualFixture(
        isStreaming: Bool = false,
        streamError: String? = nil,
        diagnostics: [AIChatDiagnostic] = [],
        showsDiagnostics: Bool = false,
        pendingApproval: AIToolApprovalRequest? = nil
    ) {
        self.isStreaming = isStreaming
        self.streamError = streamError
        streamDiagnostics = diagnostics
        showDiagnostics = showsDiagnostics
        self.pendingApproval = pendingApproval
    }
    #endif
}

struct AIChatWorkspaceView: View {
    @ObservedObject var model: AIChatViewModel
    @ObservedObject private var conversationStore: AIConversationStore
    @ObservedObject private var mcpStore: MCPServerStore
    @ObservedObject private var nativeToolStore: LimaAIToolStore
    @ObservedObject private var browserBridge = BrowserBridgeService.shared
    let isEmbedded: Bool
    let onDictation: (() -> Void)?
    @State private var apiKey = ""

    init(model: AIChatViewModel, isEmbedded: Bool = false, onDictation: (() -> Void)? = nil) {
        self.model = model
        self.isEmbedded = isEmbedded
        self.onDictation = onDictation
        _conversationStore = ObservedObject(wrappedValue: model.store)
        _mcpStore = ObservedObject(wrappedValue: model.mcpStore)
        _nativeToolStore = ObservedObject(wrappedValue: model.nativeToolStore)
    }
    @State private var showKey = false
    @State private var showingProviderSetup = false
    @State private var keyMessage: String?

    private var filteredConversations: [AIConversation] {
        let query = model.conversationSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.store.conversations }
        return model.store.conversations.filter { conversation in
            conversation.title.localizedCaseInsensitiveContains(query)
                || conversation.preview.localizedCaseInsensitiveContains(query)
        }
    }

    private var todayConversations: [AIConversation] {
        filteredConversations.filter { Calendar.current.isDateInToday($0.updatedAt) }
    }

    private var earlierConversations: [AIConversation] {
        filteredConversations.filter { !Calendar.current.isDateInToday($0.updatedAt) }
    }

    var body: some View {
        Group {
            if isEmbedded {
                workspacePanes
                    .padding(.horizontal, 8)
                    .padding(.bottom, 5)
            } else {
                ZStack {
                    LiquidGlassBackdrop(material: .underWindowBackground, blendingMode: .behindWindow)
                    VStack(spacing: LimaDesign.panelGap) {
                        windowChrome
                            .limaNativeSurface(fill: LimaTheme.surfaceRaised, radius: LimaRadius.panel, border: LimaTheme.borderSubtle)
                        workspacePanes
                    }
                    .padding(.horizontal, LimaDesign.windowPadding)
                    .padding(.bottom, LimaDesign.windowPadding)
                    .padding(.top, 7)
                }
                .frame(minWidth: 760, minHeight: 520)
            }
        }
        .tint(SettingsStore.shared.accentTheme.readablePrimary)
    }

    @ViewBuilder
    private var workspacePanes: some View {
        if isEmbedded {
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 220)

                Rectangle()
                    .fill(LimaDesign.separator)
                    .frame(width: LimaDesign.hairlineWidth)

                conversation
                    .frame(minWidth: 470, maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            HStack(spacing: 10) {
                sidebar
                    .frame(width: 246)
                    .limaNativeSurface(fill: LimaTheme.surfaceSecondary, radius: LimaRadius.panel, border: LimaTheme.borderSubtle)

                conversation
                    .frame(minWidth: 470, maxWidth: .infinity, maxHeight: .infinity)
                    .limaNativeSurface(fill: LimaTheme.fieldBackground, radius: LimaRadius.panel, border: LimaTheme.borderSubtle)
            }
        }
    }

    private var windowChrome: some View {
        HStack(spacing: 10) {
            LimaToolbarTitle(
                symbol: "sparkles",
                title: "AI Chat",
                subtitle: "Local Responses workspace"
            )
            .frame(maxWidth: 280, alignment: .leading)

            Spacer(minLength: 8)

            Button(action: model.newConversation) {
                Label("New Chat", systemImage: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .frame(minHeight: 28)
            .limaNativeSurface(fill: LimaTheme.surfaceSecondary, radius: LimaRadius.control, border: LimaTheme.borderSubtle)
            .keyboardShortcut("n", modifiers: .command)
            .help("New chat")

            Menu {
                Button(model.showActivity ? "Hide Latest Activity" : "Show Latest Activity") {
                    model.showActivity.toggle()
                }
                if !model.streamDiagnostics.isEmpty {
                    Button(model.showDiagnostics ? "Hide Developer Diagnostics" : "Show Developer Diagnostics") {
                        model.showDiagnostics.toggle()
                    }
                }
                if model.selectedConversation != nil {
                    Divider()
                    Button("Delete Conversation", role: .destructive, action: model.deleteSelectedConversation)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 30, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: true, vertical: false)
            .limaNativeSurface(fill: LimaTheme.surfaceSecondary, radius: LimaRadius.control, border: LimaTheme.borderSubtle)
            .help("Conversation actions")
        }
        .padding(.leading, 78)
        .padding(.trailing, 10)
        .frame(height: LimaDesign.toolbarHeight)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search chats", text: $model.conversationSearchQuery)
                .textFieldStyle(.plain)
                .limaFont(.callout)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .limaNativeSurface(fill: LimaTheme.fieldBackground, radius: LimaRadius.control, border: LimaTheme.fieldBorder)
                .padding(.horizontal, 10)
                .padding(.top, 10)

            if filteredConversations.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(SettingsStore.shared.accentTheme.readablePrimary)
                    Text(model.conversationSearchQuery.isEmpty ? "No conversations yet" : "No matching chats")
                        .limaFont(.callout.weight(.semibold))
                    Text(model.conversationSearchQuery.isEmpty ? "History stays on this Mac. Messages are sent to the selected provider." : "Try another title or phrase.")
                        .limaFont(.caption)
                        .foregroundStyle(LimaTheme.textSecondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        conversationGroup("TODAY", conversations: todayConversations)
                        conversationGroup(todayConversations.isEmpty ? "CONVERSATIONS" : "EARLIER", conversations: earlierConversations)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 5) {
                Image(systemName: "lock.fill")
                Text("Local history · \(model.store.conversations.count) chats")
            }
            .limaFont(.caption2)
            .foregroundStyle(LimaTheme.textTertiary)
            .padding(12)
        }
    }

    @ViewBuilder
    private func conversationGroup(_ title: String, conversations: [AIConversation]) -> some View {
        if !conversations.isEmpty {
            Text(title)
                .limaFont(.system(size: 9, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(LimaTheme.textTertiary)
                .padding(.horizontal, 9)
                .padding(.top, 5)

            ForEach(conversations) { conversation in
                Button {
                    model.select(conversation.id)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(conversation.title)
                            .lineLimit(1)
                            .limaFont(.callout.weight(model.selectedConversationID == conversation.id ? .semibold : .medium))
                            .foregroundStyle(LimaTheme.textPrimary)
                        Text(conversation.preview)
                            .lineLimit(2)
                            .limaFont(.caption)
                            .foregroundStyle(LimaTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
                    .limaSelection(model.selectedConversationID == conversation.id, radius: LimaRadius.control)
                }
                .buttonStyle(.plain)
                .disabled(model.canEndTask)
                .contextMenu {
                    Button("Delete Chat", role: .destructive) {
                        model.deleteConversation(conversation.id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var conversation: some View {
        VStack(spacing: 0) {
            if let approval = model.pendingApproval {
                AIToolApprovalView(request: approval, allow: { model.resolvePendingApproval(allow: true) }, deny: { model.resolvePendingApproval(allow: false) })
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }
            conversationHeader
            GlassHairline()

            if model.showDiagnostics, !model.streamDiagnostics.isEmpty {
                diagnosticsPanel
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }

            if !model.hasProviderAPIKey || showingProviderSetup {
                setupPanel
            } else {
                messages
            }

            if model.currentTaskState.isActive {
                taskStatusBar
            }
            composer
        }
    }

    private var conversationHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .limaFont(.system(size: 14, weight: .bold))
                .foregroundStyle(SettingsStore.shared.accentTheme.readablePrimary)
                .frame(width: 30, height: 30)
                .background(SettingsStore.shared.accentTheme.readablePrimary.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedConversation?.title ?? "New Chat")
                    .limaFont(.headline)
                    .foregroundStyle(LimaTheme.textPrimary)
                    .lineLimit(1)
                Text(model.hasProviderAPIKey ? "Local history · " + model.provider.title : "Setup required · " + model.provider.title)
                    .limaFont(.caption2)
                    .foregroundStyle(LimaTheme.textSecondary)
            }

            Spacer(minLength: 8)

            Button(action: model.newConversation) {
                Image(systemName: "square.and.pencil")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .limaNativeSurface(fill: LimaTheme.surfaceSecondary, radius: LimaRadius.control, border: LimaTheme.borderSubtle)
            .keyboardShortcut("n", modifiers: .command)
            .disabled(model.canEndTask)
            .help("New chat")
            .accessibilityLabel("New chat")

            Menu {
                Button("Provider Settings…") { showingProviderSetup = true }
                Button(model.showActivity ? "Hide turn details" : "Show turn details") {
                    model.showActivity.toggle()
                }
                if !model.streamDiagnostics.isEmpty {
                    Button(model.showDiagnostics ? "Hide developer diagnostics" : "Show developer diagnostics") {
                        model.showDiagnostics.toggle()
                    }
                }
                if model.selectedConversation != nil {
                    Divider()
                    Button("Delete conversation", role: .destructive, action: model.deleteSelectedConversation)
                        .disabled(model.canEndTask)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: true, vertical: false)
            .limaNativeSurface(fill: LimaTheme.surfaceSecondary, radius: LimaRadius.control, border: LimaTheme.borderSubtle)
            .help("Conversation actions")
            .accessibilityLabel("Conversation actions")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var taskStatusBar: some View {
        AIChatTaskStatusBar(
            state: model.currentTaskState,
            showsTurnDetails: model.showActivity,
            toggleTurnDetails: { model.showActivity.toggle() },
            endTask: model.endTask
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 5)
    }

    private var diagnosticsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Label("Developer diagnostics", systemImage: "ladybug.fill")
                    .limaFont(.caption.weight(.semibold))
                    .foregroundStyle(LimaTheme.textPrimary)
                Spacer()
                Button("Hide") { model.showDiagnostics = false }
                    .buttonStyle(.borderless)
                    .foregroundStyle(LimaTheme.textSecondary)
            }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.streamDiagnostics) { diagnostic in
                        Text(diagnostic.developerSummary)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(LimaTheme.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 112)
        }
        .padding(10)
        .background(LimaTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous).stroke(LimaTheme.borderStrong, lineWidth: LimaDesign.borderWidth))
    }

    private var setupPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer()
            Image(systemName: "key.fill")
                .font(.system(size: 28))
                .foregroundStyle(SettingsStore.shared.accentTheme.readablePrimary)
            Text("Connect " + model.provider.title)
                .limaFont(.title2.weight(.semibold))
            Text("Choose a provider and model for this conversation. API keys are saved only in your macOS Keychain. Tools and attachments are opt-in. Every AI tool is read-only: Lima never lets AI write, delete, run, install, or approve anything.")
                .foregroundStyle(LimaTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            providerPicker
            modelPicker
            SecureField(model.provider.title + " API key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Save Key") {
                    do {
                        try model.credentials.saveAPIKey(apiKey, for: model.provider)
                        model.credentials.refresh()
                        apiKey = ""
                        keyMessage = model.provider.title + " API key saved in Keychain."
                    } catch {
                        keyMessage = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                Button("Test Connection", action: model.testConnection)
                    .disabled(model.isLoadingModels || !model.hasProviderAPIKey)
                if let message = model.providerConnectionMessage ?? keyMessage {
                    Text(message)
                        .limaFont(.caption)
                        .foregroundStyle(LimaTheme.textSecondary)
                }
                if showingProviderSetup && model.hasProviderAPIKey {
                    Button("Done") { showingProviderSetup = false }
                }
            }
            Spacer()
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    @State private var lastStreamingScrollAt = Date.distantPast

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if model.selectedConversation?.messages.isEmpty ?? true {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Start a conversation")
                                .limaFont(.title3.weight(.semibold))
                            Text("Responses stream directly into this chat. Conversation metadata and message history remain local to Lima.")
                                .foregroundStyle(LimaTheme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 260, alignment: .center)
                    } else {
                        ForEach(model.selectedConversation?.messages ?? []) { message in
                            AIChatMessageRow(
                                message: message,
                                visibleText: model.visibleText(for: message),
                                reasoningSummary: model.visibleReasoningSummary(for: message),
                                isStreaming: model.isStreaming && model.streamingTextAssistantID == message.id,
                                showActivity: model.showActivity
                            )
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
            .onChange(of: model.streamingText) { _ in
                guard model.isStreaming,
                      Date().timeIntervalSince(lastStreamingScrollAt) >= 0.1,
                      let id = model.selectedConversation?.messages.last?.id else { return }
                lastStreamingScrollAt = Date()
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 9) {
            AIAttachmentStrip(attachments: model.attachments, remove: model.remove)

            HStack(spacing: 8) {
                attachmentAndToolMenu
                if model.hasProviderAPIKey && !showingProviderSetup {
                    agentPicker
                    modelPicker
                    aiOptionsMenu
                }
                Spacer(minLength: 4)
                if model.isBrowserPrompt(model.draft) {
                    Label(
                        browserBridge.sessions.isEmpty ? "Browser access unavailable" : "Browser connected",
                        systemImage: browserBridge.sessions.isEmpty ? "exclamationmark.triangle" : "network"
                    )
                    .limaFont(.caption2.weight(.medium))
                    .foregroundStyle(browserBridge.sessions.isEmpty ? LimaTheme.warning : LimaTheme.textSecondary)
                    .help(browserBridge.sessions.isEmpty
                        ? "Enable the Browser Bridge and connect a granted Zen or Firefox tab before asking Lima to inspect it."
                        : "Lima can inspect granted browser tabs through the connected Browser Bridge.")
                }
            }
            .frame(minHeight: 28)

            HStack(alignment: .bottom, spacing: 9) {
                ZStack(alignment: .topLeading) {
                    if model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(model.canEndTask ? "Task in progress — use End Task above" : "Ask anything…")
                            .limaFont(.callout)
                            .foregroundStyle(LimaTheme.textTertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 13)
                            .allowsHitTesting(false)
                    }

                    AIChatComposerEditor(
                        text: $model.draft,
                        editable: !model.canEndTask,
                        onSend: model.send
                    )
                        .frame(height: 66)
                        .accessibilityLabel("Message")
                }
                .background(LimaTheme.fieldBackground, in: RoundedRectangle(cornerRadius: LimaRadius.searchField, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: LimaRadius.searchField, style: .continuous)
                        .stroke(LimaTheme.fieldBorder, lineWidth: LimaDesign.borderWidth)
                )

                if let onDictation {
                    Button(action: onDictation) {
                        Image(systemName: "mic")
                            .limaFont(.system(size: 13, weight: .semibold))
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.canEndTask)
                    .help("Dictate into the message")
                    .accessibilityLabel("Dictate into the message")
                }

                if !model.canEndTask {
                    Button(action: model.send) {
                        Image(systemName: "arrow.up")
                            .limaFont(.system(size: 14, weight: .bold))
                            .frame(width: 42, height: 42)
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(Circle())
                    .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Send message")
                    .accessibilityLabel("Send message")
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
        }
        .padding(12)
        .background(LimaTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: LimaRadius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: LimaRadius.panel, style: .continuous).stroke(LimaTheme.borderSubtle, lineWidth: LimaDesign.borderWidth))
        .animation(.easeInOut(duration: 0.16), value: model.canEndTask)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var enabledToolCount: Int {
        LimaAIToolRegistry.enabledDefinitions(nativeToolStore.enabledToolIDs).count
            + mcpStore.servers.filter(\.enabled).reduce(0) { $0 + AIReadOnlyPolicy.readableMCPTools(for: $1).count }
    }

    private var aiOptionsMenu: some View {
        Menu {
            providerPicker
            skillPicker
            reasoningPicker
        } label: {
            Image(systemName: "slider.horizontal.3")
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .help("Provider, skills, and reasoning settings")
        .accessibilityLabel("AI options")
    }

    private var attachmentAndToolMenu: some View {
        Menu {
            Text("Add context")
            Button("Attach Files…", action: model.addFiles)
            Button("Add Clipboard", action: model.addClipboard)
            Button("Add Current Selection", action: model.addSelection)
            Divider()
            Text("Lima tools — read-only · \(enabledToolCount) available")
            ForEach(LimaAIToolRegistry.availableDefinitions) { tool in
                Toggle(isOn: Binding(
                    get: { nativeToolStore.isEnabled(tool) },
                    set: { nativeToolStore.setEnabled(tool, enabled: $0) }
                )) {
                    Label {
                        Text("\(tool.displayName) — \(tool.userSummary)")
                    } icon: {
                        Image(systemName: tool.symbol)
                    }
                }
            }
            Divider()
            Text("Connected services — read-only")
            ForEach(mcpStore.servers) { server in
                let readableTools = AIReadOnlyPolicy.readableMCPTools(for: server)
                Toggle(isOn: Binding(
                    get: { server.enabled },
                    set: { mcpStore.setEnabled(server.id, enabled: $0) }
                )) {
                    Label("\(server.name) — \(readableTools.count) safe tool\(readableTools.count == 1 ? "" : "s")", systemImage: "server.rack")
                }
                if readableTools.isEmpty {
                    Text("No read-only tools are available from \(server.name).")
                }
            }
            if mcpStore.servers.isEmpty {
                Text("No connected services yet")
            }
            Divider()
            Text("Only tools relevant to this prompt are sent. AI Chat never writes, installs, runs, or approves tools.")
            Button("Manage Connected Services…") { model.openMCPManager() }
        } label: {
            Label("Add context", systemImage: "plus")
                .limaFont(.caption.weight(.semibold))
                .foregroundStyle(LimaTheme.textPrimary)
                .frame(minWidth: 98, minHeight: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .limaNativeSurface(fill: LimaTheme.surfaceSecondary, radius: LimaRadius.control, border: LimaTheme.borderSubtle)
        .disabled(model.canEndTask)
        .help("Add context or choose read-only tools")
        .accessibilityLabel("Add context and choose read-only tools")
    }

    private var agentPicker: some View {
        Menu {
            Button {
                model.selectAgent(nil)
            } label: {
                Label("General", systemImage: model.selectedAgentID == nil ? "checkmark" : "circle")
            }
            Divider()
            ForEach(model.availableAgentConfigurations) { agent in
                Button {
                    model.selectAgent(agent.id)
                } label: {
                    Label(agent.name, systemImage: model.selectedAgentID == agent.id ? "checkmark" : "circle")
                }
            }
        } label: {
            Label(model.selectedAgentConfiguration?.name ?? "General", systemImage: "chevron.down")
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(model.canEndTask)
        .help("Configure this conversation with an agent")
        .accessibilityLabel("Agent")

    }

    private var skillPicker: some View {
        Menu {
            ForEach(model.availableSkillConfigurations) { skill in
                Toggle(isOn: Binding(
                    get: { model.selectedSkillIDs.contains(skill.id) },
                    set: { enabled in
                        var selected = model.selectedSkillIDs
                        if enabled, !selected.contains(skill.id) { selected.append(skill.id) }
                        if !enabled { selected.removeAll { $0 == skill.id } }
                        model.setSelectedSkills(selected)
                    }
                )) {
                    Text(skill.name)
                }
            }
            if model.availableSkillConfigurations.isEmpty {
                Text("No skills available")
            }
        } label: {
            let names = model.selectedSkillConfigurations.map(\.name)
            Label(names.isEmpty ? "Skill" : names.joined(separator: ", "), systemImage: "chevron.down")
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(model.canEndTask)
        .help("Apply one or more instruction-only skills")
        .accessibilityLabel("Skills")

    }

    private var providerPicker: some View {
        Menu {
            ForEach(AIProvider.chatProviders) { provider in
                Button {
                    model.selectProvider(provider)
                    keyMessage = nil
                } label: {
                    Label(provider.title, systemImage: model.provider == provider ? "checkmark" : "circle")
                }
            }
        } label: {
            Label(model.provider.title, systemImage: "chevron.down")
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(model.canEndTask)
        .help("Choose an AI provider")
        .accessibilityLabel("AI provider")
    }

    private func modelNeedsVerification(_ option: AIModelOption) -> Bool {
        // Identifier-only discovery is uncertain only for direct OpenAI models.
        // Other providers own their catalog compatibility rules.
        model.provider == .openAI && option.isLegacyOrUnknown
    }

    private var modelPicker: some View {
        Menu {
            ForEach(model.availableModels) { option in
                Button {
                    model.selectModel(option)
                } label: {
                    HStack(spacing: 8) {
                        Label(option.displayName, systemImage: model.model == option.id ? "checkmark" : "circle")
                        if modelNeedsVerification(option) {
                            Text("Compatibility unknown")
                                .limaFont(.caption2)
                                .foregroundStyle(LimaTheme.textSecondary)
                        }
                    }
                }
            }
            Divider()
            Button("Refresh Available Models", action: model.refreshModels)
        } label: {
            HStack(spacing: 5) {
                Label(model.selectedModelOption.displayName, systemImage: "chevron.down")
                    .lineLimit(1)
                if modelNeedsVerification(model.selectedModelOption) {
                    Text("Unverified")
                        .limaFont(.caption2)
                        .foregroundStyle(LimaTheme.textTertiary)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(model.canEndTask || model.isLoadingModels)
        .help(modelNeedsVerification(model.selectedModelOption)
            ? "Compatibility unknown · Test Connection sends a basic request to this model."
            : "Choose a model for " + model.provider.title)
    }

    private var reasoningPicker: some View {
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
            Label(
                model.selectedModelOption.supportsReasoning ? model.reasoningEffort.title : "Think: Off",
                systemImage: "brain.head.profile"
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(!model.selectedModelOption.supportsReasoning || model.canEndTask)
        .help("Choose reasoning effort")
    }
}

private struct AIChatTaskStatusBar: View {
    let state: AIChatTaskState
    let showsTurnDetails: Bool
    let toggleTurnDetails: () -> Void
    let endTask: () -> Void

    private var activeFlowStep: Int {
        if state.title.hasPrefix("Using ") || state.title == "Approval needed" { return 1 }
        if state.title == "Writing response" || state.title == "Response complete" { return 2 }
        return 0
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(state.tone.color.opacity(state.isActive ? 0.16 : 0.11))
                Image(systemName: state.symbol)
                    .limaFont(.system(size: 12, weight: .bold))
                    .foregroundStyle(state.tone.color)
                if state.isActive {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(state.tone.color)
                        .padding(1)
                }
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(state.title)
                    .limaFont(.caption.weight(.semibold))
                    .foregroundStyle(LimaTheme.textPrimary)
                    .lineLimit(1)
                Text(state.detail)
                    .limaFont(.caption2)
                    .foregroundStyle(LimaTheme.textSecondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)

            AIChatFlowTrack(activeStep: activeFlowStep, isActive: state.isActive, tint: state.tone.color)
                .layoutPriority(1)

            Button(action: toggleTurnDetails) {
                Image(systemName: showsTurnDetails ? "list.bullet.rectangle.portrait.fill" : "list.bullet.rectangle.portrait")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .limaNativeSurface(fill: LimaTheme.surfaceSecondary, radius: LimaRadius.compactControl, border: LimaTheme.borderSubtle)
            .help(showsTurnDetails ? "Hide turn details" : "Show turn details")
            .accessibilityLabel(showsTurnDetails ? "Hide turn details" : "Show turn details")

            if state.canEnd {
                Button(action: endTask) {
                    Label("End", systemImage: "stop.fill")
                        .limaFont(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(LimaColors.danger)
                .help("End the current task")
                .accessibilityLabel("End current task")
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .limaNativeSurface(
            fill: state.isActive ? state.tone.color.opacity(0.065) : LimaTheme.surfaceRaised,
            radius: LimaRadius.control,
            border: state.tone.color.opacity(state.isActive ? 0.34 : 0.18)
        )
        .animation(.easeInOut(duration: 0.18), value: state.title)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Task status: \(state.title). \(state.detail)")
        .accessibilityIdentifier("ai-task-status")
    }
}

private struct AIChatFlowTrack: View {
    let activeStep: Int
    let isActive: Bool
    let tint: Color
    private let steps = ["Plan", "Read", "Answer"]

    var body: some View {
        HStack(spacing: 5) {
            flowStep("Plan", index: 0)
            flowConnector(after: 0)
            flowStep("Read", index: 1)
            flowConnector(after: 1)
            flowStep("Answer", index: 2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(LimaTheme.surfaceSecondary.opacity(0.72), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Flow: \(steps[activeStep])")
    }

    private func flowStep(_ title: String, index: Int) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(index <= activeStep ? tint : LimaTheme.borderSubtle)
                .frame(width: 6, height: 6)
                .overlay {
                    if isActive && index == activeStep {
                        Circle().stroke(tint.opacity(0.28), lineWidth: 4)
                    }
                }
            Text(title)
                .limaFont(.caption2.weight(index == activeStep ? .semibold : .regular))
                .foregroundStyle(index <= activeStep ? LimaTheme.textPrimary : LimaTheme.textTertiary)
        }
    }

    private func flowConnector(after index: Int) -> some View {
        Capsule()
            .fill(index < activeStep ? tint.opacity(0.72) : LimaTheme.borderSubtle)
            .frame(width: 12, height: 1)
    }
}

private struct ActivityDisclosureView: View {
    let activities: [AIAgentActivity]
    let reasoningSummary: String?
    let isStreaming: Bool
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
                        if isStreaming {
                            Text(reasoningSummary)
                                .textSelection(.enabled)
                        } else {
                            LimaMarkdownDocumentView(markdown: reasoningSummary)
                        }
                    }
                    .padding(.bottom, 4)
                }
                ForEach(activities) { activity in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: activity.statusSymbol)
                            .foregroundStyle(activity.kind == .error || activity.kind == .toolFailed ? LimaColors.danger : LimaColors.success)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(activity.displayTitle).limaFont(.caption.weight(.medium))
                            if let detail = activity.detail { Text(detail).limaFont(.caption2).foregroundStyle(LimaTheme.textSecondary) }
                        }
                        Spacer()
                        if let usage = activity.usage, let value = usage.displayText { Text(value).limaFont(.caption2).foregroundStyle(LimaTheme.textTertiary) }
                    }
                }
            }
            .padding(.top, 7)
        } label: {
            Label("Worked for \(elapsed, specifier: "%.1f")s", systemImage: "waveform.path.ecg")
                .limaFont(.caption.weight(.semibold))
        }
        .tint(LimaTheme.textPrimary)
        .padding(10)
        .background(LimaTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(LimaTheme.borderSubtle, lineWidth: LimaDesign.borderWidth))
    }
}

private struct AIChatMessageRow: View {
    let message: AIChatMessage
    let visibleText: String
    let reasoningSummary: String?
    let isStreaming: Bool
    let showActivity: Bool

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .assistant {
                Image(systemName: "sparkles")
                    .foregroundStyle(SettingsStore.shared.accentTheme.readablePrimary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 8) {
                    messageBody
                    if showActivity, let activities = message.activities, !activities.isEmpty {
                        ActivityDisclosureView(
                            activities: activities,
                            reasoningSummary: reasoningSummary,
                            isStreaming: isStreaming
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 60)
            } else {
                Spacer(minLength: 60)
                messageBody
                Image(systemName: "person.fill")
                    .foregroundStyle(LimaTheme.textSecondary)
                    .frame(width: 22)
            }
        }
    }

    private var messageBody: some View {
        Group {
            if message.role == .assistant, !isStreaming, !visibleText.isEmpty {
                LimaMarkdownDocumentView(markdown: visibleText)
            } else {
                Text(visibleText.isEmpty && message.role == .assistant ? "Thinking…" : visibleText)
                    .textSelection(.enabled)
            }
        }
            .fixedSize(horizontal: false, vertical: true)
            .padding(11)
            .background(
                message.role == .user ? LimaTheme.surfaceSelected : Color.clear,
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay {
                if message.role == .user {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(LimaTheme.borderSubtle, lineWidth: LimaDesign.borderWidth)
                }
            }
    }
}

enum AIChatComposerKeyboardAction: Equatable {
    case send
    case insertNewline
    case passthrough

    static func action(isReturnKey: Bool, modifiers: NSEvent.ModifierFlags) -> Self {
        guard isReturnKey else { return .passthrough }
        if modifiers.contains(.shift) || modifiers.contains(.option) {
            return .insertNewline
        }
        return .send
    }
}

private struct AIChatComposerEditor: NSViewRepresentable {
    @Binding var text: String
    let editable: Bool
    let onSend: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSend: onSend)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isEditable = editable
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 5, height: 7)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        textView.setAccessibilityLabel("Message")
        applyAppearance(to: textView)
        textView.string = text
        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        context.coordinator.onSend = onSend
        textView.isEditable = editable
        applyAppearance(to: textView)
        if textView.string != text { textView.string = text }
    }

    private func applyAppearance(to textView: NSTextView) {
        let font = NSFont.systemFont(ofSize: 14)
        // NSTextView does not reliably inherit SwiftUI foregroundStyle after an
        // appearance change. Set both the view color and typing attributes.
        textView.font = font
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]
        textView.selectedTextAttributes = [
            .foregroundColor: NSColor.selectedTextColor,
            .backgroundColor: NSColor.selectedTextBackgroundColor
        ]
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onSend: () -> Void
        weak var textView: NSTextView?

        init(text: Binding<String>, onSend: @escaping () -> Void) {
            self.text = text
            self.onSend = onSend
        }

        func textDidChange(_ notification: Notification) {
            guard let textView, text.wrappedValue != textView.string else { return }
            text.wrappedValue = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let action = AIChatComposerKeyboardAction.action(
                isReturnKey: selector == #selector(NSResponder.insertNewline(_:)),
                modifiers: NSApp.currentEvent?.modifierFlags ?? []
            )
            guard action == .send else { return false }
            onSend()
            return true
        }
    }
}
