import Foundation
import RayPlacementCore

/// A bounded pause for workflows with no observable condition to await.
/// Prefer Terminal, server, or Browser wait tools when they can observe progress.
enum AIWorkbenchUtilityTools {
    static let ids: Set<String> = ["sleep"]

    static let definitions: [LimaAIToolDefinition] = [
        LimaAIToolDefinition(
            id: "sleep", name: "sleep",
            description: "Pause the same AI run for 1–30,000 milliseconds only when no observable wait tool is available. Prefer terminal_wait, server_wait, browser_wait, or process_status when applicable. Cancellation ends the pause.",
            parameters: [
                "type": "object",
                "properties": [
                    "milliseconds": ["type": "integer", "minimum": 1, "maximum": 30_000]
                ],
                "required": ["milliseconds"],
                "additionalProperties": false
            ],
            risk: .read
        )
    ]

    static func execute(_ call: AIOutputItem) async -> LimaAIToolExecution {
        guard call.name == "sleep", let raw = call.arguments,
              raw.utf8.count <= 1_024,
              let data = raw.data(using: .utf8),
              let arguments = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              Set(arguments.keys) == ["milliseconds"],
              case .number(let value)? = arguments["milliseconds"],
              value.isFinite, value.rounded() == value,
              (1...30_000).contains(value) else {
            return .json(["error": "milliseconds must be an integer from 1 through 30000."], isError: true)
        }
        let milliseconds = Int(value)
        do {
            try await Task.sleep(for: .milliseconds(milliseconds))
            return .json(["requested_milliseconds": milliseconds, "wait_completed": true])
        } catch {
            return .json(["requested_milliseconds": milliseconds, "wait_completed": false,
                          "error": "The AI run was cancelled while waiting."], isError: true)
        }
    }
}
