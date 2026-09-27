import Foundation

struct AIGeminiStreamDecoder {
    let responseID: String
    private var sawCompletion = false
    private(set) var terminated = false
    private var toolCount = 0

    init(responseID: String) {
        self.responseID = responseID
    }

    mutating func decode(_ frame: AIProviderSSEFrame) -> [AIChatStreamEvent] {
        guard !terminated else { return [] }
        if frame.data == "[DONE]" { return finish() }
        guard let data = frame.data.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return fail("The provider returned an unreadable stream event.")
        }
        if let error = object["error"] as? [String: Any] { return fail(AIProviderFailure.message(error: error)) }
        if let feedback = object["promptFeedback"] as? [String: Any],
           let reason = feedback["blockReason"] as? String, reason != "BLOCK_REASON_UNSPECIFIED" {
            return fail("The provider blocked this request. Review the prompt before trying again.")
        }
        let candidate = (object["candidates"] as? [[String: Any]])?.first
        if sawCompletion, candidate != nil {
            return fail("The provider returned content after completing the response.")
        }
        if let reason = candidate?["finishReason"] as? String {
            guard reason == "STOP" else {
                return fail("The provider stopped before completing the response. Try a shorter request.")
            }
            sawCompletion = true
        }
        var result: [AIChatStreamEvent] = []
        let parts = ((candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        for part in parts {
            if part["thought"] as? Bool != true, let text = part["text"] as? String, !text.isEmpty {
                result.append(.textDelta(text))
            }
            if let rawCall = part["functionCall"] {
                guard let call = rawCall as? [String: Any],
                      let name = call["name"] as? String, !name.isEmpty,
                      call["args"] == nil || call["args"] is [String: Any] else {
                    return fail("The provider returned an unreadable tool call.")
                }
                toolCount += 1
                let arguments = call["args"] as? [String: Any] ?? [:]
                let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
                guard let data, data.count <= 262_144, name.utf8.count <= 256, toolCount <= 64 else {
                    return fail("The provider tool call exceeded Lima's safety limit.")
                }
                let id = "gemini-\(UUID().uuidString)"
                result.append(.outputItem(AIOutputItem(phase: .completed, apiType: "function_call",
                    id: id, callID: id, name: name, arguments: String(decoding: data, as: UTF8.self))))
            }
        }
        if let usage = object["usageMetadata"] as? [String: Any] {
            result.append(.usage(AIUsageMetrics(inputTokens: usage["promptTokenCount"] as? Int,
                                               outputTokens: usage["candidatesTokenCount"] as? Int)))
        }
        return result
    }

    mutating func finish() -> [AIChatStreamEvent] {
        guard !terminated else { return [] }
        guard sawCompletion else { return fail("The provider stream ended before the response completed.") }
        terminated = true
        return [.completed(responseID)]
    }

    private mutating func fail(_ message: String) -> [AIChatStreamEvent] {
        terminated = true
        return [.failed(message)]
    }
}
