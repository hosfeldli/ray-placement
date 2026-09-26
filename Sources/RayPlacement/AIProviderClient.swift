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

    init(defaults: UserDefaults = .standard) {
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

private struct AIProviderSSEFrame {
    var event: String
    var data: String
}

/// Preserves blank-line event delimiters from URLSession's byte stream.
private struct AIProviderSSEFramer {
    private var line: [UInt8] = []
    private var event = ""
    private var dataLines: [String] = []

    mutating func append(_ byte: UInt8) -> AIProviderSSEFrame? {
        guard byte == 0x0A else {
            line.append(byte)
            return nil
        }
        let value = String(decoding: line, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        line.removeAll(keepingCapacity: true)
        if value.isEmpty {
            guard !dataLines.isEmpty else {
                event = ""
                return nil
            }
            let frame = AIProviderSSEFrame(event: event, data: dataLines.joined(separator: "\n"))
            event = ""
            dataLines = []
            return frame
        }
        if value.hasPrefix("event:") {
            event = String(value.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        } else if value.hasPrefix("data:") {
            dataLines.append(String(value.dropFirst(5)).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    mutating func finish() -> AIProviderSSEFrame? {
        if !line.isEmpty {
            let value = String(decoding: line, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            line.removeAll()
            if value.hasPrefix("event:") {
                event = String(value.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if value.hasPrefix("data:") {
                dataLines.append(String(value.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        guard !dataLines.isEmpty else { return nil }
        let frame = AIProviderSSEFrame(event: event, data: dataLines.joined(separator: "\n"))
        event = ""
        dataLines = []
        return frame
    }
}

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
        let raw = String(decoding: data.prefix(2_000), as: UTF8.self)
        if let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] {
            let error = object["error"] as? [String: Any]
            if let message = error?["message"] as? String { return String(message.prefix(500)) }
            if let message = object["message"] as? String { return String(message.prefix(500)) }
        }
        return "Provider request failed (HTTP \(status))."
    }

    static func validateBaseURL(_ raw: String) -> URL? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let components = URLComponents(string: value),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.fragment == nil else { return nil }
        return components.url
    }

    static func endpoint(base: URL, path: String) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        let prefix = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = prefix + "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return components.url
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
                guard let path = attachment.path else { continue }
                let url = URL(fileURLWithPath: path)
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, (values.fileSize ?? 0) <= 96 * 1_024,
                      let text = String(data: try Data(contentsOf: url), encoding: .utf8) else {
                    throw NSError(domain: "LimaAIProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "This provider accepts text attachments up to 96 KB."])
                }
                content.append(.text("[\(attachment.displayName)]\n\(text)"))
            case .image:
                guard let path = attachment.path else { continue }
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let mediaType = (attachment.mimeType ?? "").lowercased()
                guard data.count <= 8 * 1_024 * 1_024,
                      ["image/jpeg", "image/png", "image/gif", "image/webp"].contains(mediaType) else {
                    throw NSError(domain: "LimaAIProvider", code: 2, userInfo: [NSLocalizedDescriptionKey: "This provider accepts JPEG, PNG, GIF, or WebP images up to 8 MB."])
                }
                content.append(.image(mediaType: mediaType, base64: data.base64EncodedString()))
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
                return [.failed((error?["message"] as? String) ?? "Anthropic reported a failed response.")]
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
        let (data, response) = try await URLSession.shared.data(for: request)
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
        mcpServers: [MCPServer],
        localTools: [LimaAIToolDefinition]
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        do {
            var messages = history
            let attachmentContent = try AIProviderHTTP.attachmentContent(attachments)
            if !attachmentContent.isEmpty, let index = messages.indices.last {
                messages[index].content.append(contentsOf: attachmentContent)
            }
            let body = Self.body(model: model, history: messages, tools: localTools)
            return stream(body: body, model: model, apiKey: apiKey)
        } catch {
            return Self.failed(error.localizedDescription)
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
        localTools: [LimaAIToolDefinition]
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        Self.failed("This provider does not support a pending remote tool approval continuation.")
    }

    func streamToolOutputs(
        apiKey: String,
        model: String,
        previousResponseID: String,
        history: [AIProviderMessage],
        outputs: [[String: Any]],
        reasoningEffort: AIReasoningEffort,
        mcpServers: [MCPServer],
        localTools: [LimaAIToolDefinition]
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        stream(body: Self.body(model: model, history: history, tools: localTools), model: model, apiKey: apiKey)
    }

    static func body(model: String, history: [AIProviderMessage], tools: [LimaAIToolDefinition]) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 8_192,
            "stream": true,
            "system": AIReadOnlyPolicy.assistantInstructions,
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
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
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
                        if let frame = framer.append(byte) {
                            for event in decoder.decode(frame) { continuation.yield(event) }
                        }
                    }
                    if let frame = framer.finish() {
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
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
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
        mcpServers: [MCPServer],
        localTools: [LimaAIToolDefinition]
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        do {
            var messages = history
            let attachmentContent = try AIProviderHTTP.attachmentContent(attachments)
            if !attachmentContent.isEmpty, let index = messages.indices.last {
                messages[index].content.append(contentsOf: attachmentContent)
            }
            return stream(messages: messages, model: model, apiKey: apiKey, tools: localTools)
        } catch {
            return Self.failed(error.localizedDescription)
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
        localTools: [LimaAIToolDefinition]
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        Self.failed("This provider does not support a pending remote tool approval continuation.")
    }

    func streamToolOutputs(
        apiKey: String,
        model: String,
        previousResponseID: String,
        history: [AIProviderMessage],
        outputs: [[String: Any]],
        reasoningEffort: AIReasoningEffort,
        mcpServers: [MCPServer],
        localTools: [LimaAIToolDefinition]
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        stream(messages: history, model: model, apiKey: apiKey, tools: localTools)
    }

    private func stream(
        messages: [AIProviderMessage],
        model: String,
        apiKey: String,
        tools: [LimaAIToolDefinition]
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        guard let base = AIProviderHTTP.validateBaseURL(baseURL),
              let endpoint = AIProviderHTTP.endpoint(base: base, path: "chat/completions") else {
            return Self.failed("Enter a valid provider base URL.")
        }
        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "stream_options": ["include_usage": true],
            "messages": Self.chatMessages(messages)
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.parameters]] }
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return stream(request: request, model: model)
    }

    private static func chatMessages(_ history: [AIProviderMessage]) -> [[String: Any]] {
        var messages: [[String: Any]] = [["role": "system", "content": AIReadOnlyPolicy.assistantInstructions]]
        for message in history {
            for item in message.content {
                switch item {
                case .text(let text):
                    messages.append(["role": message.role == .assistant ? "assistant" : "user", "content": text])
                case .image(let mediaType, let base64):
                    let url = "data:\(mediaType);base64,\(base64)"
                    messages.append(["role": message.role == .assistant ? "assistant" : "user", "content": [["type": "image_url", "image_url": ["url": url]]]])
                case .toolUse(let id, let name, let arguments):
                    messages.append(["role": "assistant", "tool_calls": [["id": id, "type": "function", "function": ["name": name, "arguments": arguments]]]])
                case .toolResult(let id, let output):
                    messages.append(["role": "tool", "tool_call_id": id, "content": output])
                }
            }
        }
        return messages
    }

    private struct ToolDelta {
        var id = ""
        var name = ""
        var arguments = ""
    }

    private func stream(request: URLRequest, model: String) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                    guard (200..<300).contains(http.statusCode) else {
                        var data = Data()
                        for try await byte in bytes { data.append(byte); if data.count >= 2_000 { break } }
                        continuation.yield(.failed(AIProviderHTTP.failure(http.statusCode, data)))
                        continuation.finish()
                        return
                    }
                    var framer = AIProviderSSEFramer()
                    var tools: [Int: ToolDelta] = [:]
                    for try await byte in bytes {
                        if Task.isCancelled { break }
                        guard let frame = framer.append(byte) else { continue }
                        if frame.data == "[DONE]" {
                            for (index, tool) in tools.sorted(by: { $0.key < $1.key }) {
                                let id = tool.id.isEmpty ? "tool-\(index)" : tool.id
                                continuation.yield(.outputItem(AIOutputItem(phase: .completed, apiType: "function_call", id: id, callID: id, name: tool.name, arguments: tool.arguments)))
                            }
                            continuation.yield(.completed(nil))
                            continue
                        }
                        guard let data = frame.data.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let error = object["error"] as? [String: Any] {
                            continuation.yield(.failed((error["message"] as? String) ?? "The provider reported an error."))
                            continue
                        }
                        if let usage = object["usage"] as? [String: Any] {
                            continuation.yield(.usage(AIUsageMetrics(inputTokens: usage["prompt_tokens"] as? Int, outputTokens: usage["completion_tokens"] as? Int)))
                        }
                        guard let choice = (object["choices"] as? [[String: Any]])?.first,
                              let delta = choice["delta"] as? [String: Any] else { continue }
                        if let text = delta["content"] as? String, !text.isEmpty { continuation.yield(.textDelta(text)) }
                        if let fragments = delta["tool_calls"] as? [[String: Any]] {
                            for fragment in fragments {
                                let index = fragment["index"] as? Int ?? 0
                                var tool = tools[index] ?? ToolDelta()
                                if let id = fragment["id"] as? String { tool.id += id }
                                if let function = fragment["function"] as? [String: Any] {
                                    if let name = function["name"] as? String { tool.name += name }
                                    if let arguments = function["arguments"] as? String { tool.arguments += arguments }
                                }
                                tools[index] = tool
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    if !Task.isCancelled { continuation.yield(.failed("The provider could not complete the request.")) }
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
        let (data, response) = try await URLSession.shared.data(for: request)
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
        mcpServers: [MCPServer],
        localTools: [LimaAIToolDefinition]
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        do {
            var messages = history
            let attachmentContent = try AIProviderHTTP.attachmentContent(attachments)
            if !attachmentContent.isEmpty, let index = messages.indices.last {
                messages[index].content.append(contentsOf: attachmentContent)
            }
            return stream(messages: messages, model: model, apiKey: apiKey, tools: localTools)
        } catch {
            return Self.failed(error.localizedDescription)
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
        localTools: [LimaAIToolDefinition]
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        Self.failed("This provider does not support a pending remote tool approval continuation.")
    }

    func streamToolOutputs(
        apiKey: String,
        model: String,
        previousResponseID: String,
        history: [AIProviderMessage],
        outputs: [[String: Any]],
        reasoningEffort: AIReasoningEffort,
        mcpServers: [MCPServer],
        localTools: [LimaAIToolDefinition]
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        stream(messages: history, model: model, apiKey: apiKey, tools: localTools)
    }

    private func stream(
        messages: [AIProviderMessage],
        model: String,
        apiKey: String,
        tools: [LimaAIToolDefinition]
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        guard let name = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(name):streamGenerateContent") else {
            return Self.failed("The Gemini model endpoint is invalid.")
        }
        components.queryItems = [URLQueryItem(name: "alt", value: "sse")]
        guard let endpoint = components.url else { return Self.failed("The Gemini model endpoint is invalid.") }
        let contents = Self.geminiContents(messages)
        var body: [String: Any] = [
            "systemInstruction": ["parts": [["text": AIReadOnlyPolicy.assistantInstructions]]],
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

    private static func geminiContents(_ history: [AIProviderMessage]) -> [[String: Any]] {
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
                    let response = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) ?? output
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
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
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
                    for try await byte in bytes {
                        if Task.isCancelled { break }
                        guard let frame = framer.append(byte), frame.data != "[DONE]",
                              let data = frame.data.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        let candidate = (object["candidates"] as? [[String: Any]])?.first
                        let parts = ((candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
                        for part in parts {
                            if let text = part["text"] as? String, !text.isEmpty { continuation.yield(.textDelta(text)) }
                            if let call = part["functionCall"] as? [String: Any], let name = call["name"] as? String {
                                let arguments = call["args"] as? [String: Any] ?? [:]
                                let encoded = (try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                                let id = "gemini-\(UUID().uuidString)"
                                continuation.yield(.outputItem(AIOutputItem(phase: .completed, apiType: "function_call", id: id, callID: id, name: name, arguments: encoded)))
                            }
                        }
                        if let usage = object["usageMetadata"] as? [String: Any] {
                            continuation.yield(.usage(AIUsageMetrics(inputTokens: usage["promptTokenCount"] as? Int, outputTokens: usage["candidatesTokenCount"] as? Int)))
                        }
                    }
                    if let frame = framer.finish(),
                       let data = frame.data.data(using: .utf8),
                       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let usage = object["usageMetadata"] as? [String: Any] {
                        continuation.yield(.usage(AIUsageMetrics(inputTokens: usage["promptTokenCount"] as? Int, outputTokens: usage["candidatesTokenCount"] as? Int)))
                    }
                    continuation.yield(.completed(responseID))
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
