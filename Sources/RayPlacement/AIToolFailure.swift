import Foundation

/// A small, provider-neutral failure vocabulary for self-repairing tool loops.
/// Keep the JSON keys stable even when a tool's Swift implementation changes.
enum AIToolResultState: String, Sendable {
    case completed
    case partiallyCompleted = "partially_completed"
    case failed
    case cancelled
}

enum AIToolFailureCode: String, Sendable {
    case invalidArguments = "invalid_arguments"
    case unsupportedOperation = "unsupported_operation"
    case staleTarget = "stale_target"
    case staleFile = "stale_file"
    case targetNotVisible = "target_not_visible"
    case targetNotInteractable = "target_not_interactable"
    case pathNotFound = "path_not_found"
    case permissionDenied = "permission_denied"
    case commandNotFound = "command_not_found"
    case nonzeroExit = "nonzero_exit"
    case processTimedOut = "process_timed_out"
    case pageLoading = "page_loading"
    case pageUnstable = "page_unstable"
    case navigationFailed = "navigation_failed"
    case networkUnavailable = "network_unavailable"
    case resourceUnavailable = "resource_unavailable"
    case cancelled
}

struct AIToolFailure: Sendable, Equatable {
    let code: AIToolFailureCode
    let message: String
    let recoverable: Bool
    let nextAction: String?
    let suggestedTools: [String]

    init(_ code: AIToolFailureCode, message: String, recoverable: Bool,
         nextAction: String? = nil, suggestedTools: [String] = []) {
        self.code = code
        self.message = message
        self.recoverable = recoverable
        self.nextAction = nextAction
        self.suggestedTools = suggestedTools
    }

    var jsonObject: [String: Any] {
        var value: [String: Any] = [
            "code": code.rawValue,
            "message": message,
            "recoverable": recoverable
        ]
        if let nextAction { value["next_action"] = nextAction }
        if !suggestedTools.isEmpty { value["suggested_tools"] = suggestedTools }
        return value
    }

    func toolExecution(state: AIToolResultState = .failed) -> LimaAIToolExecution {
        .json(["state": state.rawValue, "error": jsonObject], isError: true)
    }
}
