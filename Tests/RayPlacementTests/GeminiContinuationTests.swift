import Foundation
import Testing
@testable import RayPlacement

private func geminiFrame(_ object: [String: Any]) throws -> AIProviderSSEFrame {
    AIProviderSSEFrame(event: "", data: String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
}

@Test func geminiTrailingFramePreservesTextToolsAndUsage() throws {
    let object: [String: Any] = [
        "candidates": [["content": ["parts": [
            ["text": "private thought", "thought": true],
            ["text": "visible answer"],
            ["functionCall": ["name": "get_lima_status", "args": [:]]]
        ]], "finishReason": "STOP"]],
        "usageMetadata": ["promptTokenCount": 2, "candidatesTokenCount": 3]
    ]
    let frame = try geminiFrame(object)
    var framer = AIProviderSSEFramer()
    var decoder = AIGeminiStreamDecoder(responseID: "fixture")
    // Deliberately omit the final newline: the transport must decode the EOF frame.
    for byte in Data(("data: " + frame.data).utf8) { #expect(try framer.append(byte) == nil) }
    let trailingFrame = try framer.finish()
    let events = decoder.decode(try #require(trailingFrame))
    #expect(events.contains { if case .textDelta(let text) = $0 { return text == "visible answer" }; return false })
    #expect(!events.contains { if case .textDelta(let text) = $0 { return text.contains("private thought") }; return false })
    #expect(events.contains { if case .outputItem(let item) = $0 { return item.name == "get_lima_status" && item.arguments == "{}" }; return false })
    #expect(events.contains { if case .usage(let value) = $0 { return value.totalKnownTokens == 5 }; return false })
    let completion = decoder.finish()
    #expect(completion.count == 1)
    #expect(completion.contains { if case .completed(let id) = $0 { return id == "fixture" }; return false })
    #expect(decoder.finish().isEmpty)
    #expect(decoder.decode(frame).isEmpty)
}

@Test func geminiRejectsErrorsTruncationAndMalformedCalls() throws {
    let frames = [
        try geminiFrame(["error": ["message": "private-secret", "code": 401]]),
        try geminiFrame(["promptFeedback": ["blockReason": "SAFETY"]]),
        try geminiFrame(["candidates": [["finishReason": "MAX_TOKENS"]]]),
        try geminiFrame(["candidates": [["content": ["parts": [["functionCall": ["name": "read_file", "args": "invalid"]]]]]]]),
        AIProviderSSEFrame(event: "", data: "{bad")
    ]
    for frame in frames {
        var decoder = AIGeminiStreamDecoder(responseID: "fixture")
        #expect(decoder.decode(frame).contains {
            if case .failed(let message) = $0 { return !message.contains("private-secret") }
            return false
        })
        #expect(decoder.finish().isEmpty)
    }
    var truncated = AIGeminiStreamDecoder(responseID: "fixture")
    _ = truncated.decode(try geminiFrame(["candidates": [["content": ["parts": [["text": "partial"]]]]]]))
    #expect(truncated.finish().contains { if case .failed = $0 { return true }; return false })
    var missingStop = AIGeminiStreamDecoder(responseID: "fixture")
    #expect(missingStop.decode(AIProviderSSEFrame(event: "", data: "[DONE]")).contains {
        if case .failed = $0 { return true }; return false
    })
}

@Test func geminiRejectsPostCompletionContentAndExcessiveToolCalls() throws {
    var completed = AIGeminiStreamDecoder(responseID: "fixture")
    _ = completed.decode(try geminiFrame(["candidates": [["finishReason": "STOP"]]]))
    #expect(completed.decode(try geminiFrame(["candidates": [["content": ["parts": [["text": "late"]]]]]])).contains {
        if case .failed = $0 { return true }; return false
    })
    var bounded = AIGeminiStreamDecoder(responseID: "fixture")
    let calls = Array(repeating: ["functionCall": ["name": "read_file", "args": [:]]] as [String: Any], count: 65)
    #expect(bounded.decode(try geminiFrame(["candidates": [["content": ["parts": calls], "finishReason": "STOP"]]])).contains {
        if case .failed = $0 { return true }; return false
    })
}

@Test func geminiToolResultsAlwaysEncodeAsObjects() {
    for output in ["plain text", "[1,2]", "{\"ok\":true}"] {
        let history = [
            AIProviderMessage(role: .assistant, content: [.toolUse(id: "a", name: "read_file", arguments: "{}")]),
            AIProviderMessage(role: .user, content: [.toolResult(id: "a", output: output)])
        ]
        let rows = GeminiAIProviderClient.geminiContents(history)
        let parts = rows.last?["parts"] as? [[String: Any]]
        let response = parts?.first?["functionResponse"] as? [String: Any]
        #expect(response?["name"] as? String == "read_file")
        #expect(response?["response"] is [String: Any])
    }
}
