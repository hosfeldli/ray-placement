import Foundation

/// Safe, provider-neutral facts about one failed inference attempt. Never store
/// response bodies, prompts, credentials, or raw CLI diagnostics in this value.
struct AIProviderFailureEvent: Codable, Hashable, Sendable {
    enum Category: String, Codable, Hashable, Sendable {
        case temporaryRateLimit
        case periodicUsageLimit
        case billingLimit
        case authenticationFailure
        case permissionDenied
        case expiredLogin
        case modelUnavailable
        case unsupportedParameter
        case invalidToolSchema
        case contextExceeded
        case networkUnavailable
        case networkSecurityFailure
        case serverOverload
        case requestTimeout
        case cliProcessFailure
        case cliExecutableMissing
        case cliProtocolFailure
        case interruptedStream
        case localToolFailure
        case resourceFailure
        case userCancellation
        case unknown
    }

    enum Confidence: String, Codable, Hashable, Sendable {
        case verified
        case likely
        case unknown
    }

    enum RecoveryAction: String, Codable, Hashable, Sendable {
        case retry
        case retryAfter
        case repairConfiguration
        case restartCLI
        case resume
        case suspend
        case requestUserAction
        case terminate
    }

    enum ExecutionState: String, Codable, Hashable, Sendable {
        case beforeRequest
        case streaming
        case toolsMayHaveRun
        case effectUncertain
    }

    let providerID: String
    let modelID: String
    let runID: UUID
    let category: Category
    let providerErrorCode: String?
    let httpStatus: Int?
    let cliExitCode: Int32?
    let retryAfter: Date?
    let retryAfterSource: String?
    let isTransient: Bool
    let confidence: Confidence
    let safeExplanation: String
    let recommendedAction: RecoveryAction
    let requestExecutionState: ExecutionState
    let invalidParameter: String?
    let correlationID: String?

    var requiresUserAction: Bool {
        recommendedAction == .requestUserAction || recommendedAction == .terminate
    }

    var cooldownKey: String {
        // Credential identities are deliberately not persisted. Until the
        // adapter supplies a safe account bucket, scope to provider and model.
        providerID + "|" + modelID
    }
}
