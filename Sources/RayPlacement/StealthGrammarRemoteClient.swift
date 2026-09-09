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
        case invalidResponse
        case responseTooLarge
        case noModelsFound

        var errorDescription: String? {
            switch self {
            case .invalidConfiguration: return "The Enhanced Grammar provider configuration is incomplete."
            case .requestFailed(let statusCode, let detail):
                if let detail, !detail.isEmpty { return "The Enhanced Grammar provider returned HTTP \(statusCode): \(detail)" }
                return "The Enhanced Grammar provider returned HTTP \(statusCode). Check the saved key, base URL, and model."
            case .authenticationFailed(let statusCode, let detail):
                return "Enhanced Grammar authentication failed (HTTP \(statusCode))" + (detail.map { ": \($0)" } ?? ". Check the saved key.")
            case .rateLimited: return "Enhanced Grammar is rate-limited (HTTP 429). Try again later."
            case .modelUnavailable(let statusCode, let detail):
                return "Enhanced Grammar model is unavailable (HTTP \(statusCode))" + (detail.map { ": \($0)" } ?? ". Check the selected model.")
            case .invalidJSON: return "Enhanced Grammar returned invalid JSON instead of structured edits."
            case .safetyRejected: return "Enhanced Grammar returned an edit that failed Lima’s safety checks."
            case .invalidResponse: return "The Enhanced Grammar provider returned an unreadable correction."
            case .responseTooLarge: return "The Enhanced Grammar provider returned too much data."
            case .noModelsFound: return "The provider returned no text-capable models."
            }
        }
    }

    static let systemPrompt = """
    You are a high-confidence copy editor. Return only a JSON object with this exact shape:
    {"edits":[{"start":0,"length":0,"replacement":"text"}]}

    Offsets are UTF-16 offsets into the input. Make only high-confidence grammar,
    spelling, punctuation, capitalization, and subject-verb agreement corrections.
    If uncertain, return no edit. Preserve meaning, tone, paragraph breaks, line
    breaks, formatting, and voice. Never rewrite the whole document.

    Never alter URLs, email addresses, file paths, code, shell commands,
    identifiers, version strings, acronyms, product names, application names,
    people names, company names, proper nouns, technical terms, or opaque
    protected tokens. Never change a protected token or an edit that touches one.
    """

    static let connectionSystemPrompt = "Return only the word OK. Do not explain your response."

    static let legacyCorrectionSystemPrompt = """
    You are a high-confidence copy editor. Return only the corrected text, with no explanation, labels, Markdown fences, or surrounding quotation marks.
    Preserve meaning, tone, paragraph breaks, line breaks, intentional whitespace boundaries, and formatting. Make only high-confidence grammar, spelling, punctuation, capitalization, and subject-verb agreement corrections. If uncertain, leave the text unchanged. Never rewrite style, add content, invent facts, or change the user's voice.
    """

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
                text: "Reply with the single word OK.",
                configuration: configuration,
                systemPrompt: Self.connectionSystemPrompt
              ) else {
            completion(.failure(ClientError.invalidConfiguration))
            return nil
        }
        return perform(request: request, provider: configuration.provider, completion: completion)
    }

    @discardableResult
    func correctEdits(
        _ text: String,
        configuration: DeveloperGrammarConfiguration,
        completion: @escaping (Result<[StealthGrammarEdit], Error>) -> Void
    ) -> URLSessionDataTask? {
        guard !configuration.apiKey.isEmpty,
              !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let request = makeRequest(text: text, configuration: configuration, systemPrompt: Self.systemPrompt) else {
            completion(.failure(ClientError.invalidConfiguration))
            return nil
        }
        return perform(request: request, provider: configuration.provider) { result in
            completion(result.flatMap { value in
                do { return .success(try Self.extractEdits(from: value)) }
                catch { return .failure(error) }
            })
        }
    }

    @discardableResult
    func correct(
        _ text: String,
        configuration: DeveloperGrammarConfiguration,
        completion: @escaping (Result<String, Error>) -> Void
    ) -> URLSessionDataTask? {
        guard !configuration.apiKey.isEmpty,
              !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let request = makeRequest(
                text: text,
                configuration: configuration,
                systemPrompt: Self.legacyCorrectionSystemPrompt
              ) else {
            completion(.failure(ClientError.invalidConfiguration))
            return nil
        }
        return perform(request: request, provider: configuration.provider) { result in
            completion(result.flatMap { value in
                guard !value.contains("```"), !StealthGrammarService.isChattyResponse(value) else {
                    return .failure(ClientError.invalidResponse)
                }
                return .success(value)
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

    private func makeRequest(text: String, configuration: DeveloperGrammarConfiguration, systemPrompt: String) -> URLRequest? {
        guard let base = Self.validatedBaseURL(configuration.baseURL) else { return nil }
        let url: URL?
        switch configuration.provider {
        case .openAI, .mistral, .xAI, .deepSeek, .openRouter, .openAICompatible:
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
        case .openAI, .mistral, .xAI, .deepSeek, .openRouter, .openAICompatible:
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

    private struct EditEnvelope: Decodable {
        let edits: [StealthGrammarEdit]
    }

    private static func extractEdits(from value: String) throws -> [StealthGrammarEdit] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = [trimmed]

        // Some providers ignore the “JSON only” instruction and add a Markdown
        // fence or a short preamble. Accept only the smallest JSON object we can
        // isolate; all range, overlap, and safety checks still happen later.
        if trimmed.hasPrefix("```") {
            var fenced = trimmed
            if let newline = fenced.firstIndex(of: "\n") {
                fenced = String(fenced[fenced.index(after: newline)...])
            }
            if fenced.hasSuffix("```") {
                fenced.removeLast(3)
            }
            candidates.append(fenced.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let firstBrace = trimmed.firstIndex(of: "{"),
           let lastBrace = trimmed.lastIndex(of: "}"),
           firstBrace < lastBrace {
            candidates.append(String(trimmed[firstBrace...lastBrace]))
        }

        for candidate in candidates {
            guard let data = candidate.data(using: .utf8) else { continue }
            if let envelope = try? JSONDecoder().decode(EditEnvelope.self, from: data) {
                return envelope.edits
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
        case .openAI, .mistral, .xAI, .deepSeek, .openRouter, .openAICompatible:
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
