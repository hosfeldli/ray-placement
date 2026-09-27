import Foundation
import RayPlacementWriting

struct GrammarExecutionBudget: Sendable, Equatable {
    let softCandidateDeadline: Duration
    let hardCandidateDeadline: Duration
    let judgeDeadline: Duration
    let totalDeadline: Duration
    let minimumCandidates: Int

    static let fast = GrammarExecutionBudget(softCandidateDeadline: .seconds(4), hardCandidateDeadline: .seconds(8), judgeDeadline: .seconds(5), totalDeadline: .seconds(12), minimumCandidates: 2)
    static let balanced = GrammarExecutionBudget(softCandidateDeadline: .seconds(6), hardCandidateDeadline: .seconds(12), judgeDeadline: .seconds(6), totalDeadline: .seconds(18), minimumCandidates: 2)
    static let thorough = GrammarExecutionBudget(softCandidateDeadline: .seconds(10), hardCandidateDeadline: .seconds(18), judgeDeadline: .seconds(8), totalDeadline: .seconds(28), minimumCandidates: 3)

    static func forStrategy(_ strategy: GrammarEnsembleStrategy) -> GrammarExecutionBudget {
        switch strategy {
        case .fast: return .fast
        case .balanced: return .balanced
        case .thorough: return .thorough
        }
    }
}

enum GrammarExecutionError: LocalizedError {
    case timedOut

    var errorDescription: String? {
        switch self {
        case .timedOut: return "Grammar checking reached its time limit. Safe results were kept."
        }
    }
}

/// Runs the controlled candidate ensemble and assembles only locally safe,
/// edit-level corrections. HTTP/provider details remain in
/// StealthGrammarRemoteClient; this type owns consensus and adjudication.
@MainActor
final class GrammarEnsembleCoordinator {
    struct CandidateResult: Identifiable, Sendable {
        let id: String
        let profile: GrammarCandidateProfile
        let changes: [StealthGrammarDocumentChange]
        let acceptedChanges: [StealthGrammarDocumentChange]
        let rejectedCount: Int
        let latencyMS: Int
        let errorDescription: String?
        let inputTokens: Int
        let outputTokens: Int
        let apiCallCount: Int
        let requestID: String?
        let rejectionReasons: [String]

        var isEligible: Bool { errorDescription == nil }
    }

    struct Result: Sendable {
        let runID: UUID
        let report: StealthGrammarApplyReport
        let candidates: [CandidateResult]
        let judgeUsed: Bool
        let judgeErrorDescription: String?
        let hasProposals: Bool

        var successfulCandidateCount: Int {
            candidates.filter(\.isEligible).count
        }
    }

    private actor CandidateIterator {
        var iterator: AsyncStream<CandidateResult>.AsyncIterator

        init(stream: AsyncStream<CandidateResult>) {
            self.iterator = stream.makeAsyncIterator()
        }

        func next() async -> CandidateResult? {
            var local = iterator
            let value = await local.next()
            iterator = local
            return value
        }
    }

    private struct ConsensusBucket: Sendable {
        let issueID: String
        let change: StealthGrammarDocumentChange
        var candidateIDs: Set<String>
        let order: Int
    }

    private let remoteClient: StealthGrammarRemoteClient

    init(remoteClient: StealthGrammarRemoteClient) {
        self.remoteClient = remoteClient
    }

    func run(
        contextText: String,
        source: String,
        protected: StealthProtectedText,
        configuration: DeveloperGrammarConfiguration,
        strategy: GrammarEnsembleStrategy,
        systemPrompt: String,
        useJudgeOnDisagreement: Bool = true,
        budget: GrammarExecutionBudget? = nil
    ) async throws -> Result {
        let runID = UUID()
        let startedAt = Date()
        let debugStore = GrammarDebugStore.shared
        let settings = SettingsStore.shared
        let allProfiles = GrammarCandidateProfile.profiles(for: strategy)
        let candidateSettings = Dictionary(uniqueKeysWithValues: allProfiles.map { profile in
            (profile.id, settings.grammarCandidateSettings(for: profile))
        })
        let profiles = allProfiles.compactMap { profile -> GrammarCandidateProfile? in
            let candidate = candidateSettings[profile.id] ?? GrammarCandidateSettings(profile: profile)
            return candidate.enabled ? profile.applying(candidate) : nil
        }
        let judgeConfiguration = settings.grammarJudgeConfiguration
        let executionBudget = budget ?? .forStrategy(strategy)
        let deadline = ContinuousClock.now + executionBudget.totalDeadline
        let configurationSnapshot = GrammarRunConfigurationSnapshot.current(
            configuration: configuration,
            strategy: strategy,
            profiles: allProfiles,
            candidateSettings: candidateSettings,
            judge: judgeConfiguration,
            scoringWeights: settings.grammarScoringWeights,
            correctionPolicy: settings.grammarCorrectionPolicy
        )
        guard !profiles.isEmpty else {
            throw StealthGrammarRemoteClient.ClientError.invalidConfiguration
        }
        debugStore.beginRun(
            id: runID,
            startedAt: startedAt,
            strategy: strategy,
            sourceText: settings.grammarDebugStoreSourceText ? source : nil,
            contextText: settings.grammarDebugStoreSourceText ? contextText : nil,
            systemPrompt: settings.grammarRecordCandidatePrompts ? systemPrompt : nil,
            configurationSnapshot: configurationSnapshot,
            provider: configuration.provider.rawValue,
            model: configuration.model
        )
        do {
            let candidates = try await runCandidates(
                runID: runID,
                profiles: profiles,
                contextText: contextText,
                protected: protected,
                configuration: configuration,
                systemPrompt: systemPrompt,
                budget: executionBudget,
                deadline: deadline
            )
            let eligible = candidates.filter(\.isEligible)
            guard !eligible.isEmpty else {
                debugStore.finishRun(id: runID, status: "failed", error: "All candidates failed", judgeUsed: false, judgeError: nil, candidateCount: candidates.count, appliedCount: 0, finalChanges: [])
                debugStore.prune(maxRuns: settings.grammarDebugMaximumRuns, retentionDays: settings.grammarDebugRetentionDays)
                throw StealthGrammarRemoteClient.ClientError.invalidResponse
            }

        let hasProposals = eligible.contains { !$0.changes.isEmpty }
        guard hasProposals else {
            for candidate in candidates { Self.record(candidate, runID: runID, systemPrompt: systemPrompt, store: debugStore) }
            debugStore.finishRun(id: runID, status: "completed", judgeUsed: false, judgeError: nil, candidateCount: candidates.count, appliedCount: 0, finalChanges: [], totalLatencyMS: Int(Date().timeIntervalSince(startedAt) * 1_000), inputTokens: candidates.reduce(0) { $0 + $1.inputTokens }, outputTokens: candidates.reduce(0) { $0 + $1.outputTokens }, apiCallCount: candidates.reduce(0) { $0 + $1.apiCallCount }, requestIDs: candidates.compactMap(\.requestID), safetyRejectedCount: candidates.reduce(0) { $0 + $1.rejectedCount }, rejectionReasons: candidates.flatMap(\.rejectionReasons).reduce(into: [:]) { $0[$1, default: 0] += 1 }, agreementScore: Self.agreementScore(candidates))
            debugStore.prune(maxRuns: settings.grammarDebugMaximumRuns, retentionDays: settings.grammarDebugRetentionDays)
            return Result(
                runID: runID,
                report: protected.applyingDocumentChanges([]),
                candidates: candidates,
                judgeUsed: false,
                judgeErrorDescription: nil,
                hasProposals: false
            )
        }

        let buckets = Self.buckets(from: eligible)
        let threshold = Self.consensusThreshold(for: profiles.count)
        let automatic = buckets.filter { $0.candidateIDs.count >= threshold }
        let disputed = buckets.filter { $0.candidateIDs.count < threshold }

        var selected = automatic
        var judgeUsed = false
        var judgeErrorDescription: String?

        // A unanimous candidate set needs no fourth request. Any edit that
        // fails the configured majority threshold is sent to the judge as an
        // existing choice; the judge cannot invent a new correction.
        if !disputed.isEmpty, useJudgeOnDisagreement && judgeConfiguration.enabled {
            judgeUsed = true
            let summary = Self.judgeSummary(buckets: buckets, candidates: eligible)
            do {
                let decisions = try await withTimeout(executionBudget.judgeDeadline, deadline: deadline) {
                    try await self.remoteClient.judgeDocument(
                        contextText: contextText,
                        candidateSummary: summary,
                        configuration: configuration
                    )
                }
                let decisionsByIssue = Dictionary(uniqueKeysWithValues: decisions.map { ($0.issueID, $0) })
                for bucket in disputed {
                    guard let decision = decisionsByIssue[bucket.issueID],
                          let winner = decision.winner,
                          decision.confidence >= judgeConfiguration.minimumConfidence,
                          bucket.candidateIDs.contains(winner) else { continue }
                    selected.append(bucket)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Preserve safe majority edits when adjudication fails. A
                // run containing only disputed proposals remains unchanged and
                // is handled by the caller's single operation-level retry.
                judgeErrorDescription = error.localizedDescription
            }
        }

        let report = protected.applyingDocumentChanges(
            selected.sorted { $0.order < $1.order }.map(\.change)
        )
        guard StealthGrammarService.isSafeReplacement(source, report.text) else {
            throw StealthGrammarRemoteClient.ClientError.safetyRejected
        }

        let result = Result(
            runID: runID,
            report: report,
            candidates: candidates,
            judgeUsed: judgeUsed,
            judgeErrorDescription: judgeErrorDescription,
            hasProposals: hasProposals
        )
        debugStore.finishRun(id: runID, status: "completed", judgeUsed: judgeUsed, judgeError: judgeErrorDescription, candidateCount: candidates.count, appliedCount: report.appliedCount, finalChanges: selected.sorted { $0.order < $1.order }.map(\.change), totalLatencyMS: Int(Date().timeIntervalSince(startedAt) * 1_000), inputTokens: candidates.reduce(0) { $0 + $1.inputTokens }, outputTokens: candidates.reduce(0) { $0 + $1.outputTokens }, apiCallCount: candidates.reduce(0) { $0 + $1.apiCallCount } + (judgeUsed ? 1 : 0), requestIDs: candidates.compactMap(\.requestID), safetyRejectedCount: candidates.reduce(0) { $0 + $1.rejectedCount }, rejectionReasons: candidates.flatMap(\.rejectionReasons).reduce(into: [:]) { $0[$1, default: 0] += 1 }, agreementScore: Self.agreementScore(candidates))
        debugStore.prune(maxRuns: settings.grammarDebugMaximumRuns, retentionDays: settings.grammarDebugRetentionDays)
        return result
        } catch is CancellationError {
            debugStore.finishRun(id: runID, status: "cancelled", error: "Cancelled", judgeUsed: false, judgeError: nil, candidateCount: profiles.count, appliedCount: 0, finalChanges: [])
            throw CancellationError()
        } catch {
            debugStore.finishRun(id: runID, status: "failed", error: error.localizedDescription, judgeUsed: false, judgeError: nil, candidateCount: profiles.count, appliedCount: 0, finalChanges: [])
            debugStore.prune(maxRuns: settings.grammarDebugMaximumRuns, retentionDays: settings.grammarDebugRetentionDays)
            throw error
        }
    }

    private static func record(_ candidate: CandidateResult, runID: UUID, systemPrompt: String, store: GrammarDebugStore) {
        store.recordCandidate(GrammarDebugCandidate(
            id: candidate.id, runID: runID, profileID: candidate.profile.id, seed: candidate.profile.diversitySeed,
            promptVersion: candidate.profile.promptVersion, instructions: candidate.profile.instructions,
            prompt: prompt(base: systemPrompt, profile: candidate.profile), temperature: candidate.profile.temperature,
            latencyMS: candidate.latencyMS, rawChanges: candidate.changes, acceptedChanges: candidate.acceptedChanges,
            rejectedCount: candidate.rejectedCount, error: candidate.errorDescription, inputTokens: candidate.inputTokens, outputTokens: candidate.outputTokens, apiCallCount: candidate.apiCallCount, requestID: candidate.requestID, rejectionReasons: candidate.rejectionReasons
        ))
        if let requestID = candidate.requestID {
            store.recordRequest(GrammarDebugRequest(id: requestID, runID: runID, kind: "candidate", provider: nil, model: nil, status: candidate.errorDescription == nil ? "completed" : "failed", latencyMS: candidate.latencyMS, inputTokens: candidate.inputTokens, outputTokens: candidate.outputTokens, createdAt: Date()))
        }
    }

    private func runCandidates(
        runID: UUID,
        profiles: [GrammarCandidateProfile],
        contextText: String,
        protected: StealthProtectedText,
        configuration: DeveloperGrammarConfiguration,
        systemPrompt: String,
        budget: GrammarExecutionBudget,
        deadline: ContinuousClock.Instant
    ) async throws -> [CandidateResult] {
        var tasks: [Task<Void, Never>] = []
        let stream = AsyncStream<CandidateResult> { continuation in
            for profile in profiles {
                let task = Task { [remoteClient] in
                    let started = Date()
                    let candidate: CandidateResult
                    do {
                        let changes = try await self.withTimeout(budget.hardCandidateDeadline, deadline: deadline) {
                            try await remoteClient.correctDocument(
                                contextText,
                                configuration: configuration,
                                systemPrompt: await Self.prompt(base: systemPrompt, profile: profile),
                                temperature: profile.temperature,
                                reasoningEffort: profile.reasoningEffort
                            )
                        }
                        let accepted = Self.individuallySafeChanges(changes, protected: protected)
                        candidate = CandidateResult(
                            id: profile.id,
                            profile: profile,
                            changes: changes,
                            acceptedChanges: accepted.changes,
                            rejectedCount: accepted.rejectedCount,
                            latencyMS: Int(Date().timeIntervalSince(started) * 1_000),
                            errorDescription: nil,
                            inputTokens: max(1, contextText.count / 4),
                            outputTokens: max(1, changes.reduce(0) { $0 + $1.find.count + $1.replacement.count } / 4),
                            apiCallCount: 1,
                            requestID: UUID().uuidString,
                            rejectionReasons: Array(repeating: "unsafe_change", count: accepted.rejectedCount)
                        )
                    } catch is CancellationError {
                        return
                    } catch {
                        candidate = CandidateResult(
                            id: profile.id,
                            profile: profile,
                            changes: [],
                            acceptedChanges: [],
                            rejectedCount: 0,
                            latencyMS: Int(Date().timeIntervalSince(started) * 1_000),
                            errorDescription: error.localizedDescription,
                            inputTokens: max(1, contextText.count / 4),
                            outputTokens: 0,
                            apiCallCount: 1,
                            requestID: UUID().uuidString,
                            rejectionReasons: [error.localizedDescription]
                        )
                    }
                    continuation.yield(candidate)
                }
                tasks.append(task)
            }
        }

        defer { tasks.forEach { $0.cancel() } }
        let candidateIterator = CandidateIterator(stream: stream)
        var collected: [CandidateResult] = []
        let softDeadline = min(deadline, ContinuousClock.now + budget.softCandidateDeadline)
        let hardDeadline = min(deadline, ContinuousClock.now + budget.hardCandidateDeadline)
        var reachedSoftDeadline = false

        while collected.count < profiles.count {
            let now = ContinuousClock.now
            let cutoff = reachedSoftDeadline ? hardDeadline : softDeadline
            guard now < cutoff else {
                reachedSoftDeadline = true
                if Self.hasQuorumAgreement(collected, minimum: budget.minimumCandidates) || ContinuousClock.now >= hardDeadline {
                    break
                }
                continue
            }

            do {
                let remaining = cutoff - now
                guard let candidate = try await Self.nextCandidate(
                    from: candidateIterator,
                    before: remaining
                ) else { break }
                collected.append(candidate)

                if collected.count == profiles.count { break }
                if reachedSoftDeadline && Self.hasQuorumAgreement(collected, minimum: budget.minimumCandidates) {
                    break
                }
            } catch is GrammarExecutionError {
                reachedSoftDeadline = true
                if Self.hasQuorumAgreement(collected, minimum: budget.minimumCandidates) || ContinuousClock.now >= hardDeadline {
                    break
                }
            }
        }

        // If the soft deadline passed without agreement, allow the remaining
        // candidates to complete until the hard deadline. At that point the
        // caller receives every valid result already available.
        if !reachedSoftDeadline { reachedSoftDeadline = true }
        while ContinuousClock.now < hardDeadline && collected.count < profiles.count {
            do {
                let remaining = hardDeadline - ContinuousClock.now
                guard let candidate = try await Self.nextCandidate(from: candidateIterator, before: remaining) else { break }
                collected.append(candidate)
            } catch {
                break
            }
        }

        let sorted = collected.sorted { lhs, rhs in
            profiles.firstIndex { $0.id == lhs.id } ?? 0 < profiles.firstIndex { $0.id == rhs.id } ?? 0
        }
        for candidate in sorted { Self.record(candidate, runID: runID, systemPrompt: systemPrompt, store: GrammarDebugStore.shared) }
        return sorted
    }

    private static func hasQuorumAgreement(_ candidates: [CandidateResult], minimum: Int) -> Bool {
        let eligible = candidates.filter(\.isEligible)
        guard eligible.count >= minimum else { return false }
        let buckets = buckets(from: eligible)
        guard !buckets.isEmpty else { return true }
        return buckets.contains { $0.candidateIDs.count >= minimum }
    }

    private static func nextCandidate(
        from iterator: CandidateIterator,
        before timeout: Duration
    ) async throws -> CandidateResult? {
        try await withThrowingTaskGroup(of: CandidateResult?.self) { group in
            group.addTask { await iterator.next() }
            group.addTask {
                try await ContinuousClock().sleep(for: timeout)
                throw GrammarExecutionError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }

    private func withTimeout<T: Sendable>(
        _ timeout: Duration,
        deadline: ContinuousClock.Instant,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let remaining = min(timeout, max(.zero, deadline - ContinuousClock.now))
        guard remaining > .zero else { throw GrammarExecutionError.timedOut }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await ContinuousClock().sleep(for: remaining)
                throw GrammarExecutionError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw GrammarExecutionError.timedOut }
            return result
        }
    }

    private static func consensusThreshold(for candidateCount: Int) -> Int {
        candidateCount <= 2 ? candidateCount : (candidateCount + 1) / 2
    }

    private static func prompt(base: String, profile: GrammarCandidateProfile) -> String {
        """
        \(base)

        Candidate profile: \(profile.id)
        Lima diversity seed: \(profile.diversitySeed)
        Prompt version: \(profile.promptVersion)

        \(profile.instructions)
        """
    }

    private static func individuallySafeChanges(
        _ changes: [StealthGrammarDocumentChange],
        protected: StealthProtectedText
    ) -> (changes: [StealthGrammarDocumentChange], rejectedCount: Int) {
        let original = protected.applyingDocumentChanges([]).text
        var accepted: [StealthGrammarDocumentChange] = []
        for change in changes {
            let report = protected.applyingDocumentChanges([change])
            if report.appliedCount == 1, report.text != original {
                accepted.append(change)
            }
        }
        return (accepted, changes.count - accepted.count)
    }

    private static func buckets(from candidates: [CandidateResult]) -> [ConsensusBucket] {
        var buckets: [String: ConsensusBucket] = [:]
        var order = 0
        for candidate in candidates {
            var seen = Set<String>()
            for change in candidate.acceptedChanges {
                let key = key(for: change)
                guard seen.insert(key).inserted else { continue }
                if var bucket = buckets[key] {
                    bucket.candidateIDs.insert(candidate.id)
                    buckets[key] = bucket
                } else {
                    buckets[key] = ConsensusBucket(
                        issueID: "issue_\(order)",
                        change: change,
                        candidateIDs: [candidate.id],
                        order: order
                    )
                    order += 1
                }
            }
        }
        return buckets.values.sorted { $0.order < $1.order }
    }

    private static func judgeSummary(
        buckets: [ConsensusBucket],
        candidates: [CandidateResult]
    ) -> String {
        let candidateOrder = candidates.map(\.id)
        return buckets.map { bucket in
            let votes = bucket.candidateIDs.sorted { left, right in
                (candidateOrder.firstIndex(of: left) ?? .max) < (candidateOrder.firstIndex(of: right) ?? .max)
            }.joined(separator: ", ")
            let before = bucket.change.before.map { " before=\($0.debugDescription)" } ?? ""
            let after = bucket.change.after.map { " after=\($0.debugDescription)" } ?? ""
            return "\(bucket.issueID) | candidates=\(votes) | find=\(bucket.change.find.debugDescription) | replacement=\(bucket.change.replacement.debugDescription)\(before)\(after)"
        }.joined(separator: "\n")
    }

    private static func agreementScore(_ candidates: [CandidateResult]) -> Double? {
        let eligible = candidates.filter(\.isEligible)
        guard eligible.count > 1 else { return eligible.isEmpty ? nil : 1 }
        let sets = eligible.map { Set($0.acceptedChanges.map(key(for:))) }
        let union = sets.reduce(into: Set<String>()) { $0.formUnion($1) }
        guard !union.isEmpty else { return 1 }
        let shared = union.filter { value in sets.filter { $0.contains(value) }.count > 1 }.count
        return Double(shared) / Double(union.count)
    }

    private static func key(for change: StealthGrammarDocumentChange) -> String {
        [change.find, change.replacement, change.before ?? "", change.after ?? ""].joined(separator: "\u{1F}")
    }
}
