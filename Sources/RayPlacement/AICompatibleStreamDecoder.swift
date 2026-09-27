import Foundation

/// Semantic decoder is shared by normal frames and the trailing EOF frame.
/// Tools are published only once, after a successful terminal marker.
struct AICompatibleStreamDecoder {
    private struct ToolDelta {
        var id = ""
        var name = ""
        var arguments = ""
    }
    let responseID = "compatible-\(UUID().uuidString)"
    private var tools: [Int: ToolDelta] = [:]
    private(set) var terminated = false

    mutating func decode(_ frame: AIProviderSSEFrame) -> [AIChatStreamEvent] {
        guard !terminated else { return [] }
        if frame.data == "[DONE]" {
            terminated = true
            var result: [AIChatStreamEvent] = []
            for (_, tool) in tools.sorted(by: { $0.key < $1.key }) {
                guard !tool.id.isEmpty, !tool.name.isEmpty,
                      let data = tool.arguments.data(using: .utf8),
                      (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                    tools = [:]
                    return [.failed("The provider returned an incomplete tool call.")]
                }
                result.append(.outputItem(AIOutputItem(phase: .completed, apiType: "function_call",
                    id: tool.id, callID: tool.id, name: tool.name, arguments: tool.arguments)))
            }
            tools = [:]
            result.append(.completed(responseID))
            return result
        }
        guard let data = frame.data.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return fail("The provider returned an unreadable stream event.")
        }
        if let error = object["error"] as? [String: Any] { return fail(AIProviderFailure.message(error: error)) }
        var result: [AIChatStreamEvent] = []
        if let usage = object["usage"] as? [String: Any] {
            result.append(.usage(AIUsageMetrics(inputTokens: usage["prompt_tokens"] as? Int,
                                               outputTokens: usage["completion_tokens"] as? Int)))
        }
        guard let choice = (object["choices"] as? [[String: Any]])?.first else { return result }
        if let reason = choice["finish_reason"] as? String, !["stop", "tool_calls", "function_call"].contains(reason) {
            return fail("The provider stopped before completing the response. Try a shorter request.")
        }
        guard let delta = choice["delta"] as? [String: Any] else { return result }
        if let text = delta["content"] as? String, !text.isEmpty { result.append(.textDelta(text)) }
        if let fragments = delta["tool_calls"] as? [[String: Any]] {
            for fragment in fragments {
                guard let index = fragment["index"] as? Int, (0..<64).contains(index) else {
                    return fail("The provider returned an invalid tool call.")
                }
                var tool = tools[index] ?? ToolDelta()
                if let id = fragment["id"] as? String { tool.id += id }
                if let function = fragment["function"] as? [String: Any] {
                    if let name = function["name"] as? String { tool.name += name }
                    if let arguments = function["arguments"] as? String { tool.arguments += arguments }
                }
                guard tool.id.utf8.count <= 256, tool.name.utf8.count <= 256,
                      tool.arguments.utf8.count <= 262_144 else {
                    return fail("The provider tool call exceeded Lima's safety limit.")
                }
                tools[index] = tool
            }
        }
        return result
    }

    mutating func finish() -> [AIChatStreamEvent] {
        guard !terminated else { return [] }
        return fail("The provider stream ended before the response completed.")
    }

    private mutating func fail(_ message: String) -> [AIChatStreamEvent] {
        terminated = true
        tools = [:]
        return [.failed(message)]
    }
}
