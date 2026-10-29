import Foundation

enum AIProviderFailureClassifier {
    static func diagnostic(
        response: HTTPURLResponse,
        data: Data,
        model: String? = nil,
        stage: AIChatDiagnostic.Stage = .transport
    ) -> AIChatDiagnostic {
        let details = AIProviderFailure.details(data: data, status: response.statusCode)
        let retry = retryTime(response: response)
        return AIChatDiagnostic(
            stage: stage,
            httpStatus: response.statusCode,
            model: model,
            errorCode: details.code,
            errorParameter: details.parameter,
            retryAfter: retry?.date,
            retryAfterSource: retry?.source,
            correlationID: safeRequestID(response.value(forHTTPHeaderField: "x-request-id")
                ?? response.value(forHTTPHeaderField: "request-id")),
            message: details.message
        )
    }

    static func classify(
        run: AIExecutionRun,
        diagnostic: AIChatDiagnostic?,
        requestState: AIProviderFailureEvent.ExecutionState
    ) -> AIProviderFailureEvent {
        let status = diagnostic?.httpStatus
        let code = diagnostic?.errorCode
        let parameter = diagnostic?.errorParameter
        let category: AIProviderFailureEvent.Category
        let confidence: AIProviderFailureEvent.Confidence

        switch (code, status) {
        case ("insufficient_quota", _), ("billing_hard_limit_reached", _):
            category = .billingLimit; confidence = .verified
        case ("context_length_exceeded", _):
            category = .contextExceeded; confidence = .verified
        case ("model_not_found", _):
            category = .modelUnavailable; confidence = .verified
        case ("unsupported_parameter", _):
            category = .unsupportedParameter; confidence = .verified
        case ("invalid_tool_schema", _):
            category = .invalidToolSchema; confidence = .verified
        case ("usage_limit_reached", _):
            category = .periodicUsageLimit; confidence = .verified
        case ("rate_limit_exceeded", _), ("rate_limit_error", _), (_, 429):
            // A rate-limit reset header alone does not prove a weekly or
            // account-level usage window. Only an explicit provider code does.
            category = .temporaryRateLimit
            confidence = code == nil ? .likely : .verified
        case ("invalid_api_key", _), ("authentication_error", _), (_, 401):
            category = .authenticationFailure; confidence = code == nil ? .likely : .verified
        case ("permission_denied", _), ("permission_error", _), (_, 403):
            category = .permissionDenied; confidence = code == nil ? .likely : .verified
        case ("overloaded_error", _), ("server_error", _),
             (_, 500), (_, 502), (_, 503), (_, 504):
            category = .serverOverload; confidence = code == nil ? .likely : .verified
        case (_, 404):
            category = .modelUnavailable; confidence = .likely
        case (_, 400) where parameter != nil:
            category = parameter?.hasPrefix("tools") == true ? .invalidToolSchema : .unsupportedParameter
            confidence = .likely
        default:
            if diagnostic?.message == AIProviderFailure.timeoutMessage {
                category = .requestTimeout; confidence = .verified
            } else if diagnostic?.eventType == "cli_executable_missing" {
                category = .cliExecutableMissing; confidence = .verified
            } else if diagnostic?.eventType == "app_server_disconnected" {
                category = .cliProcessFailure; confidence = .verified
            } else if diagnostic?.eventType == "cli_process_failure" {
                category = .cliProcessFailure; confidence = .likely
            } else if diagnostic?.eventType == "tool_continuation_rejected" {
                category = .cliProtocolFailure; confidence = .verified
            } else if diagnostic?.eventType == "cli_protocol_failure" {
                category = .cliProtocolFailure; confidence = .likely
            } else if diagnostic?.eventType == "network_unavailable" {
                category = .networkUnavailable; confidence = .verified
            } else if diagnostic?.eventType == "interrupted_stream" {
                category = .interruptedStream; confidence = .verified
            } else {
                category = .unknown; confidence = .unknown
            }
        }

        let transient: Bool
        switch category {
        case .temporaryRateLimit, .periodicUsageLimit, .networkUnavailable,
             .serverOverload, .requestTimeout, .cliProcessFailure, .interruptedStream:
            transient = true
        default:
            transient = false
        }
        let action: AIProviderFailureEvent.RecoveryAction
        switch category {
        case .temporaryRateLimit, .periodicUsageLimit, .serverOverload:
            action = .retryAfter
        case .networkUnavailable, .requestTimeout, .interruptedStream:
            action = .retry
        case .cliProcessFailure:
            action = .restartCLI
        case .unsupportedParameter, .invalidToolSchema:
            action = .repairConfiguration
        case .userCancellation:
            action = .terminate
        default:
            action = .requestUserAction
        }
        return AIProviderFailureEvent(
            providerID: run.providerConfigurationSnapshot.providerID,
            modelID: run.providerConfigurationSnapshot.modelID,
            runID: run.id,
            category: category,
            providerErrorCode: code,
            httpStatus: status,
            cliExitCode: diagnostic?.cliExitCode,
            retryAfter: diagnostic?.retryAfter,
            retryAfterSource: diagnostic?.retryAfterSource,
            isTransient: transient,
            confidence: diagnostic?.eventType == "cli_text_diagnostic" && confidence == .verified
                ? .likely : confidence,
            safeExplanation: diagnostic?.message ?? "The provider request stopped before completion.",
            recommendedAction: action,
            requestExecutionState: requestState,
            invalidParameter: parameter,
            correlationID: diagnostic?.correlationID
        )
    }

    private static func retryTime(response: HTTPURLResponse) -> (date: Date, source: String)? {
        let now = Date()
        if let value = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines) {
            if let seconds = TimeInterval(value), (0...604_800).contains(seconds) {
                return (now.addingTimeInterval(seconds), "retry-after")
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: value), date > now,
               date.timeIntervalSince(now) <= 604_800 {
                return (date, "retry-after")
            }
        }
        for header in ["anthropic-ratelimit-requests-reset", "x-ratelimit-reset-requests"] {
            guard let value = response.value(forHTTPHeaderField: header),
                  let date = ISO8601DateFormatter().date(from: value),
                  date > now, date.timeIntervalSince(now) <= 604_800 else { continue }
            return (date, "rate-limit-reset")
        }
        return nil
    }

    private static func safeRequestID(_ value: String?) -> String? {
        guard let value, (8...128).contains(value.count),
              value.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
              }) else { return nil }
        return value
    }
}
