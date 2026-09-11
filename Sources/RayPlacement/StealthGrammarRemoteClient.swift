import Foundation
import RayPlacementWriting

final class StealthGrammarRemoteClient {
    enum ClientError: LocalizedError {
        case invalidConfiguration
        case requestFailed(statusCode: Int, detail: String? = nil)
        case authenticationFailed(statusCode: Int, detail: String? = nil)
        case rateLimited
        case modelUnavailable(statusCode: Int, detail: String? = nil)
        case invalidJSON
        case safetyRejected
        case compatibilityFailed
        case invalidResponse
        case responseTooLarge
        case noModelsFound

        var errorDescription: String? {
            switch self {
            case .invalidConfiguration: return "The external grammar provider configuration is incomplete."
            case .requestFailed(let statusCode, let detail):
                if let detail, !detail.isEmpty { return "The external grammar provider returned HTTP \(statusCode): \(detail)" }
                return "The external grammar provider returned HTTP \(statusCode). Check the saved key, base URL, and model."
            case .authenticationFailed(let statusCode, let detail):
                return "External grammar authentication failed (HTTP \(statusCode))" + (detail.map { ": \($0)" } ?? ". Check the saved key.")
            case .rateLimited: return "External grammar is rate-limited (HTTP 429). Try again later."
            case .modelUnavailable(let statusCode, let detail):
                return "External grammar model is unavailable (HTTP \(statusCode))" + (detail.map { ": \($0)" } ?? ". Check the selected model.")
            case .invalidJSON: return "External grammar returned invalid JSON instead of structured edits."
            case .safetyRejected: return "External grammar returned an edit that failed Lima’s safety checks."
            case .compatibilityFailed: return "External grammar returned no effective grammar correction for the compatibility sample."
            case .invalidResponse: return "The external grammar provider returned an unreadable correction."
            case .responseTooLarge: return "The external grammar provider returned too much data."
            case .noModelsFound: return "The provider returned no text-capable models."
            }
        }
    }

    static let systemPrompt = """
    You are a high-confidence copy editor. You receive one complete sanitized
    document with ordinary placeholders such as [NAME_0] and [URL_0]. Return only
    a JSON object with this exact shape:
    {"changes":[{"find":"This are","replacement":"This is","before":null,"after":null}]}

    Return only small atomic replacements against the supplied document. `find`
    must be copied exactly from that document. If a phrase occurs more than once,
    include before and/or after context; otherwise omit the change. Never include
    a placeholder in find or replacement. Preserve all untouched whitespace,
    paragraph breaks, punctuation, Markdown structure, URLs, names, technical
    terms, and voice. Never rewrite a sentence or document and never return
    explanations.
    """

    /// The live correction path intentionally uses a plain-text response. The
    /// model must not spend its response budget producing an edit protocol when
    /// the caller only needs the corrected sentence/text.
    static let plainTextSystemPrompt = """
    You are a meticulous grammar and spelling corrector. Correct the supplied
    sentence or text as accurately as possible.

    Your entire response must be ONLY the corrected sentence or text itself.
    Return the corrected text and absolutely nothing else. Do not explain any
    correction. Do not describe what you changed. Do not add an introduction,
    conclusion, label, heading, commentary, apology, or summary. Do not return
    JSON, XML, Markdown, a list, quotation marks around the answer, or code
    fences. Do not say "Here is the corrected text" or anything similar.

    Preserve the author's meaning, voice, formatting, paragraph breaks,
    punctuation, Markdown structure, and whitespace wherever it is not necessary
    to correct an error. Never invent content and never rewrite correct text. If
    the supplied sentence/text is already correct, return it unchanged. Treat
    ordinary placeholders such as [NAME_0] and [URL_0] as immutable text and
    reproduce them exactly.
    """

    static let connectionSystemPrompt = "Return only the word OK. Do not explain your response."

    static let openAIStructuredOutputFormat: [String: Any] = [
        "type": "json_schema", "name": "grammar_correction", "strict": true,
        "schema": [
            "type": "object", "properties": [
                "changes": ["type": "array", "items": [
                    "type": "object", "properties": [
                        "find": ["type": "string"],
                        "replacement": ["type": "string"], "before": ["type": ["string", "null"]],
                        "after": ["type": ["string", "null"]]
                    ], "required": ["find", "replacement", "before", "after"],
                    "additionalProperties": false
                ]]
            ], "required": ["changes"], "additionalProperties": false
        ]
    ]

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    @discardableResult
    func fetchModels(
        configuration: DeveloperGrammarConfiguration,
        completion: @escaping (Result<[DeveloperGrammarModelOption], Error>) -> Void
    ) -> URLSessionDataTask? {
        guard !configuration.apiKey.isEmpty,
              let request = makeModelsRequest(configuration: configuration) else {
            completion(.failure(ClientError.invalidConfiguration))
            return nil
        }
        let task = session.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    completion(.failure(ClientError.requestFailed(statusCode: 0, detail: nil)))
                    return
                }
                guard (200..<300).contains(http.statusCode),
                      let data else {
                    completion(.failure(ClientError.requestFailed(statusCode: http.statusCode, detail: Self.responseDetail(data))))
                    return
                }
                guard data.count <= 2_000_000 else {
                    completion(.failure(ClientError.responseTooLarge))
                    return
                }
                do {
                    let models = try Self.extractModels(data: data, provider: configuration.provider)
                    completion(.success(models))
                } catch {
                    completion(.failure(error))
                }
            }
        }
        task.resume()
        return task
    }

    @discardableResult
    func testConnection(
        configuration: DeveloperGrammarConfiguration,
        completion: @escaping (Result<String, Error>) -> Void
    ) -> URLSessionDataTask? {
        guard !configuration.apiKey.isEmpty,
              !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let request = makeRequest(
                text: configuration.provider == .openAI ? "{\"changes\":[]}" : "Reply with the single word OK.",
                configuration: configuration,
                systemPrompt: configuration.provider == .openAI
                    ? "Return an empty changes array to confirm the atomic document correction contract."
                    : Self.connectionSystemPrompt
              ) else {
            completion(.failure(ClientError.invalidConfiguration))
            return nil
        }
        return perform(request: request, provider: configuration.provider) { result in
            guard configuration.provider == .openAI else {
                completion(result)
                return
            }
            completion(result.flatMap { value in
                do {
                    _ = try Self.extractDocumentChanges(from: value)
                    return .success("OK")
                } catch {
                    return .failure(error)
                }
            })
        }
    }

    private static func segmentRequestText(_ segments: [StealthEditableSegment]) -> String? {
        let publicSegments = segments.map { ["id": $0.id, "text": $0.text] }
        guard let data = try? JSONSerialization.data(withJSONObject: ["segments": publicSegments]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func correctText(
        _ text: String,
        configuration: DeveloperGrammarConfiguration,
        systemPrompt: String = StealthGrammarRemoteClient.plainTextSystemPrompt,
        completion: @escaping (Result<String, Error>) -> Void
    ) -> URLSessionDataTask? {
        guard !configuration.apiKey.isEmpty,
              !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !text.isEmpty,
              let request = makeRequest(
                text: text,
                configuration: configuration,
                systemPrompt: systemPrompt,
                plainTextResponse: true
              ) else {
            completion(.failure(ClientError.invalidConfiguration))
            return nil
        }
        return perform(request: request, provider: configuration.provider, completion: completion)
    }

    /// Candidate forms make the client tolerant of a model that disobeys the
    /// no-wrapper instruction once, without accepting explanations or changing
    /// the caller's protected-text validation rules.
    static func plainTextCandidates(from value: String) -> [String] {
        let raw = value
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = [raw]
        if trimmed != raw { candidates.append(trimmed) }

        if trimmed.hasPrefix("```") && trimmed.hasSuffix("```") {
            var body = trimmed
            body.removeFirst(3)
            body.removeLast(3)
            if let newline = body.firstIndex(of: "\n") {
                let language = body[..<newline].trimmingCharacters(in: .whitespacesAndNewlines)
                if language.isEmpty || language.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
                    body = String(body[body.index(after: newline)...])
                }
            }
            candidates.append(body.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if trimmed.count >= 2 {
            let pairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("“", "”"), ("‘", "’")]
            for (opening, closing) in pairs where trimmed.first == opening && trimmed.last == closing {
                candidates.append(String(trimmed.dropFirst().dropLast()))
            }
        }

        var unique: [String] = []
        for candidate in candidates where !unique.contains(candidate) {
            unique.append(candidate)
        }
        return unique
    }

    @discardableResult
    func correctDocument(
        _ contextText: String,
        configuration: DeveloperGrammarConfiguration,
        systemPrompt: String = StealthGrammarRemoteClient.systemPrompt,
        completion: @escaping (Result<[StealthGrammarDocumentChange], Error>) -> Void
    ) -> URLSessionDataTask? {
        guard !configuration.apiKey.isEmpty,
              !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !contextText.isEmpty,
              let request = makeRequest(text: contextText, configuration: configuration, systemPrompt: systemPrompt) else {
            completion(.failure(ClientError.invalidConfiguration))
            return nil
        }
        return perform(request: request, provider: configuration.provider) { result in
            completion(result.flatMap { value in
                do { return .success(try Self.extractDocumentChanges(from: value)) }
                catch { return .failure(error) }
            })
        }
    }

    @discardableResult
    func correctSegments(
        _ segments: [StealthEditableSegment],
        configuration: DeveloperGrammarConfiguration,
        systemPrompt: String = StealthGrammarRemoteClient.systemPrompt,
        completion: @escaping (Result<[StealthGrammarAnchoredChange], Error>) -> Void
    ) -> URLSessionDataTask? {
        guard !configuration.apiKey.isEmpty,
              !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let requestText = Self.segmentRequestText(segments),
              let request = makeRequest(text: requestText, configuration: configuration, systemPrompt: systemPrompt) else {
            completion(.failure(ClientError.invalidConfiguration))
            return nil
        }
        return perform(request: request, provider: configuration.provider) { result in
            completion(result.flatMap { value in
                do { return .success(try Self.extractAnchoredChanges(from: value)) }
                catch { return .failure(error) }
            })
        }
    }

    @discardableResult
    private func perform(
        request: URLRequest,
        provider: DeveloperGrammarProvider,
        completion: @escaping (Result<String, Error>) -> Void
    ) -> URLSessionDataTask? {
        let task = session.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    completion(.failure(ClientError.requestFailed(statusCode: 0, detail: nil)))
                    return
                }
                guard (200..<300).contains(http.statusCode), let data else {
                    completion(.failure(Self.httpError(statusCode: http.statusCode, detail: Self.responseDetail(data))))
                    return
                }
                guard data.count <= 1_000_000 else {
                    completion(.failure(ClientError.responseTooLarge))
                    return
                }
                do {
                    completion(.success(try Self.extractText(data: data, provider: provider)))
                } catch {
                    completion(.failure(error))
                }
            }
        }
        task.resume()
        return task
    }

    private static func httpError(statusCode: Int, detail: String?) -> ClientError {
        switch statusCode {
        case 401, 403: return .authenticationFailed(statusCode: statusCode, detail: detail)
        case 404: return .modelUnavailable(statusCode: statusCode, detail: detail)
        case 429: return .rateLimited
        default: return .requestFailed(statusCode: statusCode, detail: detail)
        }
    }


    private static func responseDetail(_ data: Data?) -> String? {
        guard let data, !data.isEmpty else { return nil }
        let raw = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["error", "message", "detail"] {
                if let value = object[key] as? String, !value.isEmpty { return String(value.prefix(500)) }
                if let value = object[key] as? [String: Any],
                   let message = value["message"] as? String, !message.isEmpty {
                    return String(message.prefix(500))
                }
            }
        }
        return String(raw.prefix(500))
    }

    private static func validatedBaseURL(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutTrailingSlash = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: withoutTrailingSlash),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil,
              !withoutTrailingSlash.contains("\n"),
              !withoutTrailingSlash.contains("\r") else { return nil }
        return withoutTrailingSlash
    }

    private func makeModelsRequest(configuration: DeveloperGrammarConfiguration) -> URLRequest? {
        guard let base = Self.validatedBaseURL(configuration.baseURL) else { return nil }
        var components = URLComponents(string: base + "/models")
        if configuration.provider == .gemini {
            components?.queryItems = [URLQueryItem(name: "key", value: configuration.apiKey)]
        }
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if configuration.provider == .anthropic {
            request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if configuration.provider != .gemini {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func makeRequest(
        text: String,
        configuration: DeveloperGrammarConfiguration,
        systemPrompt: String,
        plainTextResponse: Bool = false
    ) -> URLRequest? {
        guard let base = Self.validatedBaseURL(configuration.baseURL) else { return nil }
        let url: URL?
        switch configuration.provider {
        case .openAI:
            url = URL(string: base + "/responses")
        case .mistral, .xAI, .deepSeek, .openRouter, .openAICompatible:
            url = URL(string: base + "/chat/completions")
        case .anthropic:
            url = URL(string: base + "/messages")
        case .gemini:
            var components = URLComponents(string: base + "/models/" + configuration.model + ":generateContent")
            components?.queryItems = [URLQueryItem(name: "key", value: configuration.apiKey)]
            url = components?.url
        }
        guard let url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch configuration.provider {
        case .openAI:
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
            var payload: [String: Any] = [
                "model": configuration.model,
                "input": [
                    ["role": "system", "content": [["type": "input_text", "text": systemPrompt]]],
                    ["role": "user", "content": [["type": "input_text", "text": text]]]
                ]
            ]
            if !plainTextResponse {
                payload["text"] = ["format": Self.openAIStructuredOutputFormat]
            }
            request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        case .mistral, .xAI, .deepSeek, .openRouter, .openAICompatible:
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": configuration.model,
                "temperature": 0,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": text]
                ]
            ])
        case .anthropic:
            request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": configuration.model,
                "max_tokens": 8_000,
                "temperature": 0,
                "system": systemPrompt,
                "messages": [["role": "user", "content": text]]
            ])
        case .gemini:
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "systemInstruction": ["parts": [["text": systemPrompt]]],
                "contents": [["role": "user", "parts": [["text": text]]]],
                "generationConfig": ["temperature": 0]
            ])
        }
        return request
    }

    private static func extractModels(
        data: Data,
        provider: DeveloperGrammarProvider
    ) throws -> [DeveloperGrammarModelOption] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.invalidResponse
        }

        let rawModels: [[String: Any]]
        if provider == .gemini {
            rawModels = object["models"] as? [[String: Any]] ?? []
        } else {
            rawModels = object["data"] as? [[String: Any]] ?? object["models"] as? [[String: Any]] ?? []
        }

        let models = rawModels.compactMap { model -> DeveloperGrammarModelOption? in
            let rawID = (model["id"] as? String) ?? (model["name"] as? String)
            guard var id = rawID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
            if provider == .gemini, id.hasPrefix("models/") {
                id.removeFirst("models/".count)
            }
            guard !id.isEmpty, Self.isTextModel(model, id: id, provider: provider) else { return nil }
            let display = (model["display_name"] as? String)
                ?? (model["displayName"] as? String)
                ?? (model["name"] as? String)?.replacingOccurrences(of: "models/", with: "")
                ?? id
            return DeveloperGrammarModelOption(id: id, title: display)
        }
        .reduce(into: [DeveloperGrammarModelOption]()) { result, model in
            if !result.contains(where: { $0.id == model.id }) { result.append(model) }
        }
        .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }

        guard !models.isEmpty else { throw ClientError.noModelsFound }
        return Array(models.prefix(250))
    }

    private static func isTextModel(
        _ model: [String: Any],
        id: String,
        provider: DeveloperGrammarProvider
    ) -> Bool {
        if provider == .gemini,
           let methods = model["supportedGenerationMethods"] as? [String],
           !methods.contains(where: { $0.caseInsensitiveCompare("generateContent") == .orderedSame }) {
            return false
        }
        let lower = id.lowercased()
        let nonTextMarkers = [
            "embedding", "embed-", "moderation", "rerank", "whisper", "transcrib",
            "tts", "text-to-speech", "dall-e", "image-generation", "image-gen",
            "gpt-image", "stable-diffusion", "flux-"
        ]
        return !nonTextMarkers.contains(where: lower.contains)
    }

    private static func extractChatCompletionText(from object: [String: Any]) -> String? {
        guard let choices = object["choices"] as? [[String: Any]],
              let first = choices.first else { return nil }
        if let message = first["message"] as? [String: Any] {
            if let content = message["content"] as? String { return content }
            if let parts = message["content"] as? [[String: Any]] {
                return parts.compactMap { $0["text"] as? String }.joined()
            }
        }
        return first["text"] as? String
    }

    private static func extractResponsesText(from object: [String: Any]) -> String? {
        if let text = object["output_text"] as? String, !text.isEmpty { return text }
        guard let output = object["output"] as? [[String: Any]] else { return nil }
        return output.flatMap { item -> [String] in
            guard let content = item["content"] as? [[String: Any]] else { return [] }
            return content.compactMap { $0["text"] as? String }
        }.joined()
    }

    private struct ChangeEnvelope: Decodable {
        let changes: [StealthGrammarAnchoredChange]
    }

    private struct DocumentChangeEnvelope: Decodable {
        let changes: [StealthGrammarDocumentChange]
    }

    private static func extractDocumentChanges(from value: String) throws -> [StealthGrammarDocumentChange] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = [trimmed]
        if let first = trimmed.firstIndex(of: "{"), let last = trimmed.lastIndex(of: "}"), first < last {
            candidates.append(String(trimmed[first...last]))
        }
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8) else { continue }
            if let envelope = try? JSONDecoder().decode(DocumentChangeEnvelope.self, from: data) {
                return envelope.changes
            }
        }
        throw ClientError.invalidJSON
    }

    private static func extractAnchoredChanges(from value: String) throws -> [StealthGrammarAnchoredChange] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = [trimmed]
        if let first = trimmed.firstIndex(of: "{"), let last = trimmed.lastIndex(of: "}"), first < last {
            candidates.append(String(trimmed[first...last]))
        }
        for candidate in candidates where candidate.data(using: .utf8) != nil {
            if let data = candidate.data(using: .utf8), let envelope = try? JSONDecoder().decode(ChangeEnvelope.self, from: data) {
                return envelope.changes
            }
        }
        throw ClientError.invalidJSON
    }

    private static func extractText(data: Data, provider: DeveloperGrammarProvider) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.invalidJSON
        }
        let value: String?
        switch provider {
        case .openAI:
            value = Self.extractResponsesText(from: object)
        case .mistral, .xAI, .deepSeek, .openRouter, .openAICompatible:
            value = Self.extractChatCompletionText(from: object)
        case .anthropic:
            value = (object["content"] as? [[String: Any]])?
                .compactMap { $0["text"] as? String }
                .joined()
        case .gemini:
            value = ((((object["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? [])
                .compactMap { $0["text"] as? String }
                .joined()
        }
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClientError.invalidResponse }
        return value
    }
}
