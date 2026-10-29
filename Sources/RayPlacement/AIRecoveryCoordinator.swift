import Foundation

/// The only policy engine for provider retries. Adapters classify; they never
/// run independent retry loops.
actor AIRecoveryCoordinator {
    static let shared = AIRecoveryCoordinator()

    enum Decision: Sendable {
        case retryNow
        case waitForProvider(until: Date)
        case waitForConfiguration(String)
        case reconcileEffects(String)
        case stop(String)
    }

    func decide(
        event: AIProviderFailureEvent,
        checkpoint: AIExecutionCheckpoint,
        policy: AIRecoveryPolicy,
        now: Date = Date()
    ) async -> Decision {
        guard checkpoint.runID == event.runID else {
            return .stop("The recovery checkpoint did not match this run.")
        }
        guard !checkpoint.mayHaveConsequentialEffects,
              event.requestExecutionState != .toolsMayHaveRun,
              event.requestExecutionState != .effectUncertain else {
            return .reconcileEffects(
                "A tool may already have changed external state. Lima preserved the task but will not repeat the action until its outcome is reconciled."
            )
        }
        guard policy.automaticRetryEnabled, checkpoint.automaticResume else {
            return .waitForConfiguration("Automatic recovery is off. Resume this task when you are ready.")
        }
        guard event.recommendedAction != .terminate else {
            return .stop(event.safeExplanation)
        }
        if event.category == .unsupportedParameter,
           event.providerID == AIProvider.openAI.rawValue,
           ["reasoning", "reasoning.effort", "reasoning_effort", "reasoning.summary"]
               .contains(event.invalidParameter ?? ""),
           AIModelOption(id: event.modelID).supportsReasoning,
           let selectedEffort = checkpoint.originalReasoningEffort,
           selectedEffort != .none,
           checkpoint.recoveryReasoningEffort == nil {
            do {
                try await AIExecutionCheckpointStore.shared.update(runID: event.runID) {
                    $0.recoveryReasoningEffort = AIReasoningEffort.none
                }
                return .retryNow
            } catch {
                return .waitForConfiguration(
                    "Lima could not save the recognized reasoning-option repair. Automatic retry is paused."
                )
            }
        }
        guard event.isTransient else {
            return .waitForConfiguration(event.safeExplanation)
        }
        if event.category == .periodicUsageLimit {
            guard let reset = event.retryAfter, reset > now else {
                return .waitForConfiguration(
                    "The provider still reports a usage limit without a future reset time. Lima will not probe repeatedly."
                )
            }
            return .waitForProvider(until: reset)
        }

        let fingerprint = [
            event.providerID, event.modelID, event.category.rawValue,
            event.providerErrorCode ?? "", String(event.httpStatus ?? 0)
        ].joined(separator: "|")
        let authoritativeRetry = event.retryAfter.flatMap { $0 > now ? $0 : nil }
        if let authoritativeRetry,
           authoritativeRetry.timeIntervalSince(now) >= 3_600 {
            // Long provider windows are one scheduled pause, not repeated
            // probes or a rapidly consumed transient retry budget.
            return .waitForProvider(until: authoritativeRetry)
        }
        let priorCount = checkpoint.recoveryFingerprint == fingerprint
            ? checkpoint.recoveryAttempts : 0
        guard priorCount < max(1, min(policy.maximumTransientAttempts, 6)) else {
            return .stop("Provider recovery stopped after repeated failures without progress.")
        }
        let nextCount = priorCount + 1
        do {
            try await AIExecutionCheckpointStore.shared.update(runID: event.runID) { saved in
                saved.recoveryFingerprint = fingerprint
                saved.recoveryAttempts = nextCount
            }
        } catch {
            return .waitForConfiguration("Lima could not save the recovery attempt. Automatic retry is paused.")
        }

        if let authoritativeRetry {
            return .waitForProvider(until: authoritativeRetry)
        }
        if nextCount == 1, event.category == .networkUnavailable {
            return .waitForProvider(until: now.addingTimeInterval(2))
        }
        // Bounded exponential backoff with jitter applies only when the
        // provider did not give an authoritative retry time.
        let base = min(60.0, pow(2.0, Double(nextCount - 1)))
        let jitter = Double.random(in: 0...(base * 0.2))
        return .waitForProvider(until: now.addingTimeInterval(base + jitter))
    }

    func recordProgress(runID: UUID) {
        // A completed run removes its durable checkpoint at the same boundary.
    }

    func cancel(runID: UUID) {
        // Cancellation is persisted on the checkpoint; no volatile budget exists.
    }
}
