import Foundation
import Testing
@testable import RayPlacement

private func compatibleFrame(_ object: [String: Any]) throws -> AIProviderSSEFrame {
    AIProviderSSEFrame(event: "", data: String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
}

@Test func compatibleMessagesGroupParallelToolsAndMultimodalContent() throws {
    let history = [
        AIProviderMessage(role: .user, content: [.text("inspect"), .image(mediaType: "image/png", base64: "fixture")]),
        AIProviderMessage(role: .assistant, content: [
            .toolUse(id: "a", name: "read_file", arguments: "{}"),
            .toolUse(id: "b", name: "search_files", arguments: "{}")]),
        AIProviderMessage(role: .user, content: [.toolResult(id: "a", output: "one"), .toolResult(id: "b", output: "two")])
    ]
    let messages = OpenAICompatibleAIProviderClient.chatMessages(history, systemInstructions: "agent instructions")
    #expect(messages.count == 5)
    #expect(messages[0]["content"] as? String == "agent instructions")
    #expect((messages[1]["content"] as? [[String: Any]])?.count == 2)
    #expect((messages[2]["tool_calls"] as? [[String: Any]])?.count == 2)
    #expect(messages[3]["tool_call_id"] as? String == "a")
    #expect(messages[4]["tool_call_id"] as? String == "b")
}

@Test func compatibleDecoderFinalizesToolsOnceAndPreservesUsage() throws {
    var decoder = AICompatibleStreamDecoder()
    let first = try compatibleFrame(["choices": [["delta": ["tool_calls": [
        ["index": 0, "id": "call_1", "function": ["name": "read_file", "arguments": "{"]]
    ]]]]])
    #expect(decoder.decode(first).isEmpty)
    let second = try compatibleFrame(["choices": [["delta": ["tool_calls": [
        ["index": 0, "function": ["arguments": "}"]]
    ]], "finish_reason": "tool_calls"]]])
    #expect(decoder.decode(second).isEmpty)
    let usage = decoder.decode(try compatibleFrame(["choices": [], "usage": ["prompt_tokens": 2, "completion_tokens": 3]]))
    #expect(usage.contains { if case .usage(let value) = $0 { return value.totalKnownTokens == 5 }; return false })
    let done = decoder.decode(AIProviderSSEFrame(event: "", data: "[DONE]"))
    #expect(done.count == 2)
    #expect(done.contains { if case .outputItem(let item) = $0 { return item.callID == "call_1" && item.arguments == "{}" }; return false })
    #expect(done.contains { if case .completed(let id) = $0 { return id == decoder.responseID }; return false })
    #expect(decoder.decode(AIProviderSSEFrame(event: "", data: "[DONE]")).isEmpty)
    #expect(decoder.finish().isEmpty)
}

@Test func compatibleDecoderFailsClosedOnErrorsTruncationAndMissingIDs() throws {
    for frame in [
        try compatibleFrame(["error": ["message": "private-secret", "type": "authentication_error"]]),
        AIProviderSSEFrame(event: "", data: "{bad"),
        try compatibleFrame(["choices": [["finish_reason": "length", "delta": [:]]]])
    ] {
        var decoder = AICompatibleStreamDecoder()
        let events = decoder.decode(frame)
        #expect(events.contains { if case .failed(let message) = $0 { return !message.contains("private-secret") }; return false })
        #expect(decoder.decode(AIProviderSSEFrame(event: "", data: "[DONE]")).isEmpty)
    }
    var truncated = AICompatibleStreamDecoder()
    #expect(truncated.finish().contains { if case .failed = $0 { return true }; return false })
    var incomplete = AICompatibleStreamDecoder()
    _ = incomplete.decode(try compatibleFrame(["choices": [["delta": ["tool_calls": [
        ["index": 0, "function": ["name": "read_file", "arguments": "{}"]]
    ]]]]]))
    #expect(incomplete.decode(AIProviderSSEFrame(event: "", data: "[DONE]")).contains {
        if case .failed = $0 { return true }; return false
    })
}

@Test @MainActor func failedAndTruncatedStreamsNeverExecuteQueuedTools() async throws {
    for includeFailure in [false, true] {
        var events: [AIChatStreamEvent] = [
            .responseCreated("fixture"),
            .outputItem(AIOutputItem(phase: .completed, apiType: "function_call",
                callID: "call_status", name: "get_lima_status", arguments: "{}"))
        ]
        if includeFailure { events.append(.failed("The provider rejected the request.")) }
        let registry = TaskRegistry()
        let model = AIChatViewModel(
            store: AIConversationStore(fixtures: []),
            credentials: AIChatCredentialStore(configuration: .fixture),
                nativeToolStore: LimaAIToolStore(fixtures: ["get_lima_status"]),
            transport: FixtureAITransport(events: events),
            taskRegistry: registry
        )
        model.draft = "fixture"
        model.send()
        for _ in 0..<200 where model.isStreaming { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.isStreaming)
        #expect(model.streamError != nil)
        #expect(model.selectedConversation?.activities.contains { $0.kind == .toolStarted || $0.kind == .toolCompleted } == false)
        #expect(registry.activeTasks.isEmpty)
    }
}
