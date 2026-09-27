import Foundation

/// Provider errors may echo prompts, document text, URLs, or keys. Only known
/// categorical codes are retained; free-form response bodies never become logs.
enum AIProviderFailure {
    private static let messages: [String: String] = [
        "invalid_prompt": "The input is invalid.",
        "invalid_request_error": "The provider rejected the request. Check the selected model and options.",
        "invalid_api_key": "The provider rejected the API key.",
        "authentication_error": "The provider rejected the API key.",
        "permission_denied": "The provider denied access. Check the key and model permissions.",
        "permission_error": "The provider denied access. Check the key and model permissions.",
        "model_not_found": "The selected model is unavailable for this provider or key.",
        "not_found_error": "The selected model or endpoint is unavailable.",
        "rate_limit_exceeded": "The provider rate limit was reached. Try again later.",
        "rate_limit_error": "The provider rate limit was reached. Try again later.",
        "insufficient_quota": "The provider quota is exhausted. Check the account's billing settings.",
        "context_length_exceeded": "The conversation exceeds the model's context limit. Start a shorter conversation.",
        "unsupported_parameter": "The selected model does not support a requested option.",
        "overloaded_error": "The provider is busy. Try again later.",
        "server_error": "The provider could not complete the request. Try again later."
    ]

    static func code(_ raw: Any?) -> String? {
        guard let value = raw as? String, messages[value] != nil else { return nil }
        return value
    }

    static func parameter(_ raw: Any?) -> String? {
        guard let value = raw as? String,
              ["input", "model", "tools", "messages", "temperature", "max_tokens",
               "reasoning", "reasoning.effort", "stream", "system"].contains(value) else { return nil }
        return value
    }

    static func message(error: [String: Any]? = nil, status: Int? = nil) -> String {
        if let known = code(error?["code"]) ?? code(error?["type"]), let message = messages[known] {
            return message
        }
        switch status {
        case 401: return "The provider rejected the API key."
        case 403: return "The provider denied access. Check the key and model permissions."
        case 404: return "The selected model or endpoint is unavailable."
        case 429: return "The provider rate limit or quota was reached. Check the account or try again later."
        case .some(500...599): return "The provider could not complete the request. Try again later."
        default:
            return status.map { "Provider request failed (HTTP \($0))." }
                ?? "The provider reported a failed response. Check the model and request options."
        }
    }

    /// Never trust NSError userInfo: transport failures can embed URLs and keys.
    static func transport(_ error: Error) -> String {
        if error is CancellationError { return "The request was cancelled." }
        if let failure = error as? AIChatResponsesClient.ClientError {
            switch failure {
            case .requestFailed(let status, let detail):
                return messages.values.contains(detail) ? detail : message(status: status)
            case .noModelsFound: return "The provider returned no chat-capable models."
            case .invalidResponse, .malformedStream: return "The provider returned an unreadable response."
            }
        }
        if error is AIProviderSSEFramer.Failure { return "The provider stream exceeded Lima's safety limit." }
        let failure = error as NSError
        if failure.domain == NSURLErrorDomain {
            switch failure.code {
            case NSURLErrorCancelled: return "The request was cancelled."
            case NSURLErrorTimedOut: return "The provider request timed out. Try again."
            case NSURLErrorNotConnectedToInternet: return "No internet connection is available."
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
                return "The provider could not be reached. Check the endpoint and connection."
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot:
                return "The provider's secure connection could not be verified."
            default: return "The provider connection failed. Try again."
            }
        }
        if failure.domain == "LimaAIProvider", (400...599).contains(failure.code) {
            return message(status: failure.code)
        }
        return message()
    }

    static func sanitizedError(_ error: Error) -> NSError {
        let original = error as NSError
        return NSError(domain: original.domain == NSURLErrorDomain ? NSURLErrorDomain : "LimaProviderFailure",
                       code: original.domain == NSURLErrorDomain ? original.code : 1,
                       userInfo: [NSLocalizedDescriptionKey: transport(error)])
    }

    static func diagnosticMessage(_ raw: String, status: Int?) -> String {
        let fixed = [
            "Ignored malformed JSON in a streaming event.",
            "Ignored an unsupported but well-formed Responses event.",
            "Ignored an output-item event without an item payload.",
            "Ignored an unsupported Responses output item.",
            "The function call omitted call_id.",
            "The provider stream exceeded Lima's safety limit.",
            "The request was cancelled.",
            "The provider returned no chat-capable models.",
            "The provider returned an unreadable response.",
            "The provider request timed out. Try again.",
            "No internet connection is available.",
            "The provider could not be reached. Check the endpoint and connection.",
            "The provider's secure connection could not be verified.",
            "The provider connection failed. Try again."
        ]
        if fixed.contains(raw) || messages.values.contains(raw) || raw == message(status: status) { return raw }
        return message(status: status)
    }

    static func diagnosticEvent(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let known = [
            "error", "response.created", "response.in_progress", "response.completed", "response.failed",
            "response.output_text.delta", "response.output_text.done",
            "response.reasoning_summary_text.delta", "response.reasoning_summary.delta",
            "response.reasoning_summary_part.added", "response.reasoning_summary_text.done",
            "response.reasoning_summary_part.done", "response.content_part.added", "response.content_part.done",
            "response.output_item.added", "response.output_item.done",
            "response.function_call_arguments.delta", "response.function_call_arguments.done",
            "response.mcp_call.arguments.delta", "response.mcp_call_arguments.delta",
            "response.mcp_call.completed", "response.mcp_call.done", "response.mcp_call.failed", "response.mcp_call.error"
        ]
        return known.contains(raw) ? raw : "unknown"
    }

    static func toolMessage(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let object = value as? [String: Any] else { return "The MCP tool failed." }
        // Legacy servers sometimes return no category; accept only this exact
        // fixed phrase, never substrings or arbitrary free-form messages.
        if object["message"] as? String == "Permission denied" { return "Permission denied" }
        return message(error: object)
    }

    static func message(data: Data, status: Int? = nil) -> String {
        guard data.count <= 64_000,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return message(status: status)
        }
        return message(error: object["error"] as? [String: Any] ?? object, status: status)
    }
}
