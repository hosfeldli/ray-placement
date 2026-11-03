import Foundation

/// Only a request rejected before generation may be rebuilt. Never use this to
/// replay tool outputs or restart an action whose outcome is uncertain.
enum AIResponseContinuationRecovery {
    static func shouldRebuild(status: Int, data: Data, hasPreviousResponse: Bool) -> Bool {
        guard hasPreviousResponse, [400, 404].contains(status),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return false }
        let parameter = (error["param"] as? String ?? "").lowercased()
        let code = (error["code"] as? String ?? "").lowercased()
        let message = (error["message"] as? String ?? "").lowercased()
        return parameter == "previous_response_id"
            || ["previous_response_not_found", "response_not_found"].contains(code)
            || (message.contains("previous response") && (message.contains("not found") || message.contains("expired")))
            || message.contains("no tool output found for function call")
            || (message.contains("tool calls") && message.contains("did not have") && message.contains("response"))
    }
}
