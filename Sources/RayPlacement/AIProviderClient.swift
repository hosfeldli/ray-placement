import Foundation

/// Provider-neutral conversation content used only while a request is in flight.
/// Tool arguments/results are not persisted to diagnostics or activity metadata.
struct AIProviderMessage: Sendable {
    enum Content: Sendable {
        case text(String)
        case image(mediaType: String, base64: String)
        case toolUse(id: String, name: String, arguments: String)
        case toolResult(id: String, output: String)
    }

    var role: AIChatRole
    var content: [Content]

    init(role: AIChatRole, text: String) {
        self.role = role
        self.content = [.text(text)]
    }

    init(role: AIChatRole, content: [Content]) {
        self.role = role
        self.content = content
    }

    static func transcript(_ messages: [AIChatMessage]) -> [AIProviderMessage] {
        messages.compactMap { message in
            guard !message.text.isEmpty else { return nil }
            return AIProviderMessage(role: message.role, text: message.text)
        }
    }
}

@MainActor
final class AIProviderPreferences: ObservableObject {
    static let shared = AIProviderPreferences()

    @Published var openAICompatibleBaseURL: String {
        didSet { defaults.set(openAICompatibleBaseURL, forKey: Self.baseURLKey) }
    }

    @Published var openAICompatibleModelID: String {
        didSet { defaults.set(openAICompatibleModelID, forKey: Self.modelKey) }
    }

    private static let baseURLKey = "lima.ai.openai-compatible.base-url"
    private static let modelKey = "lima.ai.openai-compatible.model-id"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = LimaTestEnvironment.userDefaults) {
        self.defaults = defaults
        openAICompatibleBaseURL = defaults.string(forKey: Self.baseURLKey) ?? AIProvider.openAICompatible.defaultBaseURL
        openAICompatibleModelID = defaults.string(forKey: Self.modelKey) ?? "local-model"
    }
}

enum AIProviderClientRegistry {
    static func client(
        for provider: AIProvider,
        openAICompatibleBaseURL: String
    ) -> any AIProviderClient {
        switch provider {
        case .codexCLI, .claudeCLI:
            return CLIChatProviderClient(provider: provider)
        case .openAI:
            return AIChatResponsesClient()
        case .anthropic:
            return AnthropicAIProviderClient()
        case .gemini:
            return GeminiAIProviderClient()
        case .openAICompatible:
            return OpenAICompatibleAIProviderClient(baseURL: openAICompatibleBaseURL)
        case .mistral, .xAI, .deepSeek, .openRouter:
            return OpenAICompatibleAIProviderClient(
                baseURL: provider.defaultBaseURL,
                provider: provider
            )
        }
    }
}

// Byte framing for provider streaming is implemented by AIProviderSSEFramer.

enum AIProviderHTTP {
    static func request(
        endpoint: URL,
        key: String,
        keyHeader: String,
        model: String,
        body: [String: Any]
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(key, forHTTPHeaderField: keyHeader)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func failure(_ status: Int, _ data: Data) -> String {
        AIProviderFailure.message(data: data, status: status)
    }

    static func validateBaseURL(_ raw: String) -> URL? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let components = URLComponents(string: value),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              value.utf8.count <= 4096,
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else { return nil }
        let host = components.host?.lowercased() ?? ""
        guard components.scheme?.lowercased() == "https" ||
                ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) else { return nil }
        return components.url
    }

    static func endpoint(base: URL, path: String) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        let prefix = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = prefix + "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return components.url
    }

    /// Limit context sent again by stateless providers. Start at a user turn so
    /// the resulting transcript remains valid, and always retain the latest turn.
    static func boundedConversation(_ history: [AIProviderMessage], maximumCharacters: Int = 120_000) -> [AIProviderMessage] {
        guard history.count > 1 else { return history }
        func size(_ message: AIProviderMessage) -> Int {
            message.content.reduce(0) { total, item in
                switch item {
                case .text(let value): return total + value.count
                case .image(_, let base64): return total + base64.count
                case .toolUse(_, _, let arguments): return total + arguments.count
                case .toolResult(_, let output): return total + output.count
                }
            }
        }
        var first = 0
        var characters = history.reduce(0) { $0 + size($1) }
        while characters > maximumCharacters, first < history.count - 1 {
            characters -= size(history[first])
            first += 1
        }
        while first < history.count - 1, history[first].role != .user { first += 1 }
        return Array(history.dropFirst(first))
    }

    static func messages(_ history: [AIProviderMessage], assistantRole: String = "assistant") -> [[String: Any]] {
        var result: [[String: Any]] = []
        for message in history {
            let role = message.role == .assistant ? assistantRole : "user"
            let content: [[String: Any]] = message.content.compactMap { item in
                switch item {
                case .text(let text):
                    return ["type": "text", "text": text]
                case .image(let mediaType, let base64):
                    return ["type": "image", "source": ["type": "base64", "media_type": mediaType, "data": base64]]
                case .toolUse(let id, let name, let arguments):
                    let input = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
                    return ["type": "tool_use", "id": id, "name": name, "input": input]
                case .toolResult(let id, let output):
                    return ["type": "tool_result", "tool_use_id": id, "content": output]
                }
            }
            guard !content.isEmpty else { continue }
            if let lastIndex = result.indices.last, result[lastIndex]["role"] as? String == role,
               var previous = result[lastIndex]["content"] as? [[String: Any]] {
                previous.append(contentsOf: content)
                result[lastIndex]["content"] = previous
            } else {
                result.append(["role": role, "content": content])
            }
        }
        return result
    }

    static func attachmentContent(_ attachments: [AIAttachment]) throws -> [AIProviderMessage.Content] {
        var content: [AIProviderMessage.Content] = []
        for attachment in attachments {
            switch attachment.kind {
            case .clipboard, .selection:
                if let text = attachment.text, !text.isEmpty {
                    content.append(.text("[\(attachment.displayName)]\n\(String(text.prefix(96_000)))"))
                }
            case .file:
                let text = try AIFileAttachmentPolicy.text(for: attachment)
                content.append(.text("[File: \(attachment.displayName)]\n\(text)"))
            case .image:
                let image = try AIFileAttachmentPolicy.image(for: attachment)
                content.append(.image(mediaType: image.mediaType, base64: image.base64))
            }
        }
        return content
    }
}

struct AnthropicAIProviderClient: AIProviderClient {
    private struct ToolBlock {
        var id: String
        var name: String
        var arguments: String
    }

    private struct StreamDecoder {
        let model: String
        var responseID: String?
        var inputTokens: Int?
        var toolBlocks: [Int: ToolBlock] = [:]

        mutating func decode(_ frame: AIProviderSSEFrame) -> [AIChatStreamEvent] {
            guard let data = frame.data.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            switch frame.event {
            case "message_start":
                let message = object["message"] as? [String: Any]
                responseID = message?["id"] as? String
                inputTokens = (message?["usage"] as? [String: Any])?["input_tokens"] as? Int
                var events: [AIChatStreamEvent] = []
                if let responseID { events.append(.responseCreated(responseID)) }
                if let inputTokens { events.append(.usage(AIUsageMetrics(inputTokens: inputTokens, outputTokens: nil))) }
                return events
            case "content_block_start":
                guard let index = object["index"] as? Int,
                      let block = object["content_block"] as? [String: Any],
                      block["type"] as? String == "tool_use",
                      let id = block["id"] as? String,
                      let name = block["name"] as? String else { return [] }
                toolBlocks[index] = ToolBlock(id: id, name: name, arguments: "")
                return [.outputItem(AIOutputItem(phase: .added, apiType: "function_call", id: id, callID: id, name: name))]
            case "content_block_delta":
                guard let index = object["index"] as? Int,
                      let delta = object["delta"] as? [String: Any] else { return [] }
                if delta["type"] as? String == "text_delta", let text = delta["text"] as? String {
                    return [.textDelta(text)]
                }
                if delta["type"] as? String == "input_json_delta",
                   let partial = delta["partial_json"] as? String {
                    toolBlocks[index]?.arguments += partial
                }
                return []
            case "content_block_stop":
                guard let index = object["index"] as? Int,
                      let tool = toolBlocks.removeValue(forKey: index) else { return [] }
                return [.outputItem(AIOutputItem(
                    phase: .completed,
                    apiType: "function_call",
                    id: tool.id,
                    callID: tool.id,
                    name: tool.name,
                    arguments: tool.arguments.isEmpty ? "{}" : tool.arguments
                ))]
            case "message_delta":
                guard let usage = object["usage"] as? [String: Any] else { return [] }
                return [.usage(AIUsageMetrics(
                    inputTokens: (usage["input_tokens"] as? Int) ?? inputTokens,
                    outputTokens: usage["output_tokens"] as? Int
                ))]
            case "message_stop":
                return [.completed(responseID)]
            case "error":
                let error = object["error"] as? [String: Any]
                return [.failed(AIProviderFailure.message(error: error))]
            default:
                return []
            }
        }
    }

    func listModels(apiKey: String) async throws -> [AIModelOption] {
        var components = URLComponents(string: "https://api.anthropic.com/v1/models")!
        components.queryItems = [URLQueryItem(name: "limit", value: "100")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await AIRequestPolicy.shared.checkedSession().data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "LimaAIProvider", code: 10, userInfo: [NSLocalizedDescriptionKey: "Anthropic returned an invalid response."])
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "LimaAIProvider", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: AIProviderHTTP.failure(http.statusCode, data)])
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]] else {
            throw NSError(domain: "LimaAIProvider", code: 11, userInfo: [NSLocalizedDescriptionKey: "Anthropic returned an unreadable model list."])
        }
        let models = rows.compactMap { row -> AIModelOption? in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            let title = row["display_name"] as? String ?? AIModelOption(id: id).displayName
            return AIModelOption(id: id, displayName: title, supportsReasoning: false)
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        guard !models.isEmpty else {
            throw NSError(domain: "LimaAIProvider", code: 12, userInfo: [NSLocalizedDescriptionKey: "Anthropic returned no available models."])
        }
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
        localTools: [LimaAIToolDefinition],
        systemInstructions: String
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        do {
            var messages = AIProviderHTTP.boundedConversation(history)
            let attachmentContent = try AIProviderHTTP.attachmentContent(attachments)
            if !attachmentContent.isEmpty, let index = messages.indices.last {
                messages[index].content.append(contentsOf: attachmentContent)
            }
            let body = Self.body(model: model, history: messages, tools: localTools, systemInstructions: systemInstructions)
            return stream(body: body, model: model, apiKey: apiKey)
        } catch {
            return Self.failed("The request could not be prepared. Check the selected attachments and model.")
        }
    }

    func streamToolOutputs(
        apiKey: String,
        model: String,
        previousResponseID: String,
        history: [AIProviderMessage],
        outputs: [[String: Any]],
        reasoningEffort: AIReasoningEffort,
        localTools: [LimaAIToolDefinition],
        systemInstructions: String
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        stream(body: Self.body(model: model, history: history, tools: localTools, systemInstructions: systemInstructions), model: model, apiKey: apiKey)
    }

    static func body(model: String, history: [AIProviderMessage], tools: [LimaAIToolDefinition], systemInstructions: String) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 8_192,
            "stream": true,
            "system": systemInstructions,
            "messages": AIProviderHTTP.messages(history)
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { tool in
                ["name": tool.name, "description": tool.description, "input_schema": tool.parameters]
            }
        }
        return body
    }

    private func stream(body: [String: Any], model: String, apiKey: String) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
                    var request = try AIProviderHTTP.request(endpoint: endpoint, key: apiKey, keyHeader: "x-api-key", model: model, body: body)
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    let (bytes, response) = try await AIRequestPolicy.shared.checkedSession().bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                    guard (200..<300).contains(http.statusCode) else {
                        var data = Data()
                        for try await byte in bytes { data.append(byte); if data.count >= 2_000 { break } }
                        continuation.yield(.failed(AIProviderHTTP.failure(http.statusCode, data)))
                        continuation.finish()
                        return
                    }
                    var framer = AIProviderSSEFramer()
                    var decoder = StreamDecoder(model: model)
                    for try await byte in bytes {
                        if Task.isCancelled { break }
                        if let frame = try framer.append(byte) {
                            for event in decoder.decode(frame) { continuation.yield(event) }
                        }
                    }
                    if let frame = try framer.finish() {
                        for event in decoder.decode(frame) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    if !Task.isCancelled { continuation.yield(.failed("Anthropic could not complete the request.")) }
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func failed(_ message: String) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.failed(message))
            continuation.finish()
        }
    }
}

struct OpenAICompatibleAIProviderClient: AIProviderClient {
    let baseURL: String
    var provider: AIProvider = .openAICompatible

    init(baseURL: String, provider: AIProvider = .openAICompatible) {
        self.baseURL = baseURL
        self.provider = provider
    }

    func listModels(apiKey: String) async throws -> [AIModelOption] {
        guard let base = AIProviderHTTP.validateBaseURL(baseURL),
              let url = AIProviderHTTP.endpoint(base: base, path: "models") else {
            throw NSError(domain: "LimaAIProvider", code: 3, userInfo: [NSLocalizedDescriptionKey: "Enter a valid provider base URL."])
        }
        var request = URLRequest(url: url)
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await AIRequestPolicy.shared.checkedSession().data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]] else {
            throw NSError(domain: "LimaAIProvider", code: 4, userInfo: [NSLocalizedDescriptionKey: "The provider could not list available models."])
        }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return AIModelOption(id: id, supportsReasoning: false)
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func streamReply(
        apiKey: String,
        model: String,
        input: String,
        history: [AIProviderMessage],
        previousResponseID: String?,
        reasoningEffort: AIReasoningEffort,
        attachments: [AIAttachment],
        localTools: [LimaAIToolDefinition],
        systemInstructions: String
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        do {
            var messages = AIProviderHTTP.boundedConversation(history)
            let attachmentContent = try AIProviderHTTP.attachmentContent(attachments)
            if !attachmentContent.isEmpty, let index = messages.indices.last {
                messages[index].content.append(contentsOf: attachmentContent)
            }
            return stream(messages: messages, model: model, apiKey: apiKey, tools: localTools, systemInstructions: systemInstructions)
        } catch {
            return Self.failed("The request could not be prepared. Check the selected attachments and model.")
        }
    }

    func streamToolOutputs(
        apiKey: String,
        model: String,
        previousResponseID: String,
        history: [AIProviderMessage],
        outputs: [[String: Any]],
        reasoningEffort: AIReasoningEffort,
        localTools: [LimaAIToolDefinition],
        systemInstructions: String
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        stream(messages: history, model: model, apiKey: apiKey, tools: localTools, systemInstructions: systemInstructions)
    }

    private func stream(
        messages: [AIProviderMessage],
        model: String,
        apiKey: String,
        tools: [LimaAIToolDefinition],
        systemInstructions: String
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        guard let base = AIProviderHTTP.validateBaseURL(baseURL),
              let endpoint = AIProviderHTTP.endpoint(base: base, path: "chat/completions") else {
            return Self.failed("Enter a valid provider base URL.")
        }
        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "stream_options": ["include_usage": true],
            "messages": Self.chatMessages(messages, systemInstructions: systemInstructions)
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.parameters]] }
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return stream(request: request, model: model)
    }

    static func chatMessages(_ history: [AIProviderMessage], systemInstructions: String) -> [[String: Any]] {
        var messages: [[String: Any]] = [["role": "system", "content": systemInstructions]]
        for message in history {
            var content: [[String: Any]] = []
            var calls: [[String: Any]] = []
            var results: [[String: Any]] = []
            for item in message.content {
                switch item {
                case .text(let text): content.append(["type": "text", "text": text])
                case .image(let mediaType, let base64):
                    content.append(["type": "image_url", "image_url": ["url": "data:\(mediaType);base64,\(base64)"]])
                case .toolUse(let id, let name, let arguments):
                    calls.append(["id": id, "type": "function", "function": ["name": name, "arguments": arguments]])
                case .toolResult(let id, let output):
                    results.append(["role": "tool", "tool_call_id": id, "content": output])
                }
            }
            if !content.isEmpty || !calls.isEmpty {
                var row: [String: Any] = ["role": message.role == .assistant ? "assistant" : "user"]
                if !content.isEmpty { row["content"] = content }
                if !calls.isEmpty { row["tool_calls"] = calls }
                messages.append(row)
            }
            messages += results
        }
        return messages
    }

    private func stream(request: URLRequest, model: String) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await AIRequestPolicy.shared.checkedSession().bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                    guard (200..<300).contains(http.statusCode) else {
                        var data = Data()
                        for try await byte in bytes { data.append(byte); if data.count >= 2_000 { break } }
                        continuation.yield(.failed(AIProviderHTTP.failure(http.statusCode, data)))
                        continuation.finish()
                        return
                    }
                    var framer = AIProviderSSEFramer()
                    var decoder = AICompatibleStreamDecoder()
                    continuation.yield(.responseCreated(decoder.responseID))
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        if let frame = try framer.append(byte) {
                            for event in decoder.decode(frame) { continuation.yield(event) }
                        }
                        if decoder.terminated { break }
                    }
                    if !decoder.terminated, let frame = try framer.finish() {
                        for event in decoder.decode(frame) { continuation.yield(event) }
                    }
                    for event in decoder.finish() { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    if !Task.isCancelled { continuation.yield(.failed(AIProviderFailure.message())) }
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func failed(_ message: String) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.failed(message))
            continuation.finish()
        }
    }
}

struct GeminiAIProviderClient: AIProviderClient {
    func listModels(apiKey: String) async throws -> [AIModelOption] {
        let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await AIRequestPolicy.shared.checkedSession().data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "LimaAIProvider", code: 20, userInfo: [NSLocalizedDescriptionKey: "Gemini returned an invalid response."])
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "LimaAIProvider", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: AIProviderHTTP.failure(http.statusCode, data)])
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["models"] as? [[String: Any]] else {
            throw NSError(domain: "LimaAIProvider", code: 21, userInfo: [NSLocalizedDescriptionKey: "Gemini returned an unreadable model list."])
        }
        let models = rows.compactMap { row -> AIModelOption? in
            let methods = row["supportedGenerationMethods"] as? [String] ?? []
            guard methods.contains("generateContent"),
                  let rawName = row["name"] as? String else { return nil }
            let id = rawName.hasPrefix("models/") ? String(rawName.dropFirst("models/".count)) : rawName
            guard !id.isEmpty else { return nil }
            return AIModelOption(id: id, displayName: row["displayName"] as? String ?? AIModelOption(id: id).displayName, supportsReasoning: false)
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        guard !models.isEmpty else {
            throw NSError(domain: "LimaAIProvider", code: 22, userInfo: [NSLocalizedDescriptionKey: "Gemini returned no content-generation models."])
        }
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
        localTools: [LimaAIToolDefinition],
        systemInstructions: String
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        do {
            var messages = AIProviderHTTP.boundedConversation(history)
            let attachmentContent = try AIProviderHTTP.attachmentContent(attachments)
            if !attachmentContent.isEmpty, let index = messages.indices.last {
                messages[index].content.append(contentsOf: attachmentContent)
            }
            return stream(messages: messages, model: model, apiKey: apiKey, tools: localTools, systemInstructions: systemInstructions)
        } catch {
            return Self.failed("The request could not be prepared. Check the selected attachments and model.")
        }
    }

    func streamToolOutputs(
        apiKey: String,
        model: String,
        previousResponseID: String,
        history: [AIProviderMessage],
        outputs: [[String: Any]],
        reasoningEffort: AIReasoningEffort,
        localTools: [LimaAIToolDefinition],
        systemInstructions: String
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        stream(messages: history, model: model, apiKey: apiKey, tools: localTools, systemInstructions: systemInstructions)
    }

    private func stream(
        messages: [AIProviderMessage],
        model: String,
        apiKey: String,
        tools: [LimaAIToolDefinition],
        systemInstructions: String
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        guard let name = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(name):streamGenerateContent") else {
            return Self.failed("The Gemini model endpoint is invalid.")
        }
        components.queryItems = [URLQueryItem(name: "alt", value: "sse")]
        guard let endpoint = components.url else { return Self.failed("The Gemini model endpoint is invalid.") }
        let contents = Self.geminiContents(messages)
        var body: [String: Any] = [
            "systemInstruction": ["parts": [["text": systemInstructions]]],
            "contents": contents,
            "generationConfig": ["temperature": 0.7]
        ]
        if !tools.isEmpty {
            body["tools"] = [["functionDeclarations": tools.map { ["name": $0.name, "description": $0.description, "parameters": $0.parameters] }]]
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return stream(request: request, model: model)
    }

    static func geminiContents(_ history: [AIProviderMessage]) -> [[String: Any]] {
        history.compactMap { message in
            let role = message.role == .assistant ? "model" : "user"
            let parts: [[String: Any]] = message.content.compactMap { item in
                switch item {
                case .text(let text): return ["text": text]
                case .image(let mediaType, let base64): return ["inline_data": ["mime_type": mediaType, "data": base64]]
                case .toolUse(_, let name, let arguments):
                    let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
                    return ["functionCall": ["name": name, "args": args]]
                case .toolResult(let id, let output):
                    let name = history.lazy.flatMap(\.content).compactMap { content -> String? in
                        if case .toolUse(let toolID, let toolName, _) = content, toolID == id { return toolName }
                        return nil
                    }.first ?? "unknown_tool"
                    let response = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any]
                        ?? ["result": output]
                    return ["functionResponse": ["name": name, "response": response]]
                }
            }
            return parts.isEmpty ? nil : ["role": role, "parts": parts]
        }
    }

    private func stream(request: URLRequest, model: String) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let responseID = "gemini-\(UUID().uuidString)"
            let task = Task {
                do {
                    let (bytes, response) = try await AIRequestPolicy.shared.checkedSession().bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                    guard (200..<300).contains(http.statusCode) else {
                        var data = Data()
                        for try await byte in bytes { data.append(byte); if data.count >= 2_000 { break } }
                        continuation.yield(.failed(AIProviderHTTP.failure(http.statusCode, data)))
                        continuation.finish()
                        return
                    }
                    continuation.yield(.responseCreated(responseID))
                    var framer = AIProviderSSEFramer()
                    var decoder = AIGeminiStreamDecoder(responseID: responseID)
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        if let frame = try framer.append(byte) {
                            for event in decoder.decode(frame) { continuation.yield(event) }
                        }
                        if decoder.terminated { break }
                    }
                    try Task.checkCancellation()
                    if !decoder.terminated, let frame = try framer.finish() {
                        for event in decoder.decode(frame) { continuation.yield(event) }
                    }
                    for event in decoder.finish() { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    if !Task.isCancelled { continuation.yield(.failed("Gemini could not complete the request.")) }
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func failed(_ message: String) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.failed(message))
            continuation.finish()
        }
    }
}
