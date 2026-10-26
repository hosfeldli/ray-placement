import Foundation

/// Optional text-only cleanup for an explicitly selected cloud dictation engine.
/// Audio transcription succeeds independently: a failed cleanup must never drop
/// the original transcript or cause a transcription retry.
enum OpenAICloudDictationPostprocessor {
    enum Failure: Error, Equatable {
        case invalidInput
        case rejected(Int)
        case invalidResponse
    }

    static let model = "gpt-4.1-mini"
    static let maximumInputCharacters = 32_000
    static let maximumOutputCharacters = 64_000
    static let maximumResponseBytes = 256_000
    private static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    static func request(transcript: String, apiKey: String) throws -> URLRequest {
        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty, !clean.isEmpty,
              clean.count <= maximumInputCharacters,
              clean.utf8.count <= 128_000 else { throw Failure.invalidInput }
        let body: [String: Any] = [
            "model": model,
            "store": false,
            "max_output_tokens": 16_000,
            "instructions": """
                Clean up this dictated transcript for readability. Correct punctuation,
                capitalization, obvious speech-recognition errors, and paragraph breaks.
                Preserve the speaker's meaning, facts, names, numbers, dates, uncertainty,
                and first-person voice. Do not summarize, answer requests in the transcript,
                invent content, or infer speaker identities. Return only the cleaned transcript.
                """,
            "input": clean
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func parse(_ data: Data, status: Int) throws -> String {
        guard (200..<300).contains(status) else { throw Failure.rejected(status) }
        guard data.count <= maximumResponseBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["status"] as? String == "completed",
              let output = object["output"] as? [[String: Any]] else {
            throw Failure.invalidResponse
        }
        let text = output.compactMap { item -> String? in
            guard item["type"] as? String == "message",
                  let content = item["content"] as? [[String: Any]] else { return nil }
            return content.compactMap { part -> String? in
                guard part["type"] as? String == "output_text" else { return nil }
                return part["text"] as? String
            }.joined()
        }.joined()
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= maximumOutputCharacters,
              !clean.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 0x7F }) else {
            throw Failure.invalidResponse
        }
        return clean
    }

    static func clean(_ transcript: String, apiKey: String,
                      session: URLSession? = nil) async throws -> String {
        try AIRequestPolicy.shared.check()
        let request = try request(transcript: transcript, apiKey: apiKey)
        let uploadSession = try session ?? AIRequestPolicy.shared.checkedSession()
        let (data, response) = try await uploadSession.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        return try parse(data, status: response.statusCode)
    }
}
