import Foundation

/// The Browser workspace is the single owner of live Browser authority. Routing,
/// execution and diagnostics consume this value instead of inferring mode and
/// pause state independently.
struct BrowserAuthoritySnapshot: Sendable {
    let available: Bool
    let controlMode: BrowserAIControlMode
    let tabCount: Int
    let selectedTabID: UUID?
    let explicitlyPaused: Bool
    let pageRevision: UInt64?
    let needsFreshRead: Bool
    let liveWebViews: Int
    let lastReadiness: BrowserReadiness?
    let runtimeHealthy: Bool
}

struct TerminalCapabilitySnapshot: Sendable {
    let available: Bool
    let sessionCount: Int
    let runningSessions: Int
    let lastExitStatus: Int?
}

struct AIToolEnvironmentSnapshot: Sendable {
    let runID: UUID
    let accessMode: LimaAIToolAccessMode
    let exposedTools: [LimaAIToolDefinition]
    let browser: BrowserAuthoritySnapshot
    let terminal: TerminalCapabilitySnapshot

    var exposedToolIDs: [String] { exposedTools.map(\.id) }
}

/// No prompts, arguments, outputs, URLs, paths or credentials are retained.
struct AIToolExecutionRecord: Sendable {
    let id: UUID
    let runID: UUID
    let tool: String
    let startedAt: Date
    let durationMilliseconds: Int
    let state: AIToolResultState
    let failureCode: String?
    let recoverable: Bool
}

@MainActor
final class AIToolRuntime {
    static let shared = AIToolRuntime()
    private(set) var lastResolved: AIToolEnvironmentSnapshot?
    private(set) var recentExecutions: [AIToolExecutionRecord] = []
    private init() {}

    func exposedDefinitions(
        store: LimaAIToolStore,
        configurationValid: Bool = true
    ) -> [LimaAIToolDefinition] {
        guard configurationValid, AIRequestPolicy.shared.isEnabled else { return [] }
        return LimaAIToolRegistry.enabledDefinitions(
            store.effectiveEnabledToolIDs, toolAccessMode: store.accessMode
        )
    }

    func resolveEnvironment(
        runID: UUID,
        store: LimaAIToolStore,
        configurationValid: Bool = true
    ) -> AIToolEnvironmentSnapshot {
        let terminal = AIWorkspaceTerminalCoordinator.shared.sessions
        let snapshot = AIToolEnvironmentSnapshot(
            runID: runID,
            accessMode: store.accessMode,
            exposedTools: exposedDefinitions(store: store, configurationValid: configurationValid),
            browser: BrowserWorkspaceModel.shared.authoritySnapshot,
            terminal: TerminalCapabilitySnapshot(
                available: true,
                sessionCount: terminal.count,
                runningSessions: terminal.filter { $0.state == .running }.count,
                lastExitStatus: terminal.last(where: { $0.exitStatus != nil })?.exitStatus
            )
        )
        lastResolved = snapshot
        return snapshot
    }

    /// Schemas are fixed for a turn. Execution still checks live user policy.
    func canExecute(
        _ call: AIOutputItem,
        in environment: AIToolEnvironmentSnapshot,
        store: LimaAIToolStore
    ) -> Bool {
        guard let name = call.name,
              let definition = environment.exposedTools.first(where: { $0.name == name }),
              AIRequestPolicy.shared.isEnabled,
              exposedDefinitions(store: store).contains(where: { $0.id == definition.id }) else {
            return false
        }
        return true
    }

    func execute(
        _ call: AIOutputItem,
        in environment: AIToolEnvironmentSnapshot,
        store: LimaAIToolStore,
        operation: @MainActor () async -> LimaAIToolExecution
    ) async -> LimaAIToolExecution {
        let started = Date()
        let result: LimaAIToolExecution
        if canExecute(call, in: environment, store: store) {
            result = await operation()
        } else {
            result = AIToolFailure(
                .permissionDenied,
                message: "This tool is no longer enabled by the live Lima tool policy.",
                recoverable: true,
                nextAction: "Review Tool Access and retry if the user enables it."
            ).toolExecution()
        }
        record(call: call, runID: environment.runID, startedAt: started, result: result)
        return result
    }

    func recordRejected(_ call: AIOutputItem, runID: UUID?, code: String = "tool_not_routed") {
        recentExecutions.append(AIToolExecutionRecord(
            id: UUID(), runID: runID ?? UUID(), tool: call.name ?? "unknown",
            startedAt: Date(), durationMilliseconds: 0, state: .failed,
            failureCode: code, recoverable: true
        ))
        trimRecords()
    }

    private func record(
        call: AIOutputItem, runID: UUID, startedAt: Date, result: LimaAIToolExecution
    ) {
        let failure = (try? JSONSerialization.jsonObject(with: Data(result.output.utf8))) as? [String: Any]
        let error = failure?["error"] as? [String: Any]
        let code = error?["code"] as? String
            ?? (failure?["code"] as? String)
            ?? (result.isError ? "tool_error" : nil)
        let state: AIToolResultState = result.isError ? .failed : .completed
        recentExecutions.append(AIToolExecutionRecord(
            id: UUID(), runID: runID, tool: call.name ?? "unknown",
            startedAt: startedAt,
            durationMilliseconds: max(0, Int(Date().timeIntervalSince(startedAt) * 1_000)),
            state: state, failureCode: code,
            recoverable: error?["recoverable"] as? Bool ?? result.isError
        ))
        trimRecords()
    }

    private func trimRecords() {
        if recentExecutions.count > 100 {
            recentExecutions.removeFirst(recentExecutions.count - 100)
        }
    }
}
