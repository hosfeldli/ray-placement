import Foundation
import RayPlacementWriting

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
        useJudgeOnDisagreement: Bool = true
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
                systemPrompt: systemPrompt
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
                let decisions = try await remoteClient.judgeDocument(
                    contextText: contextText,
                    candidateSummary: summary,
                    configuration: configuration
                )
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
        systemPrompt: String
    ) async throws -> [CandidateResult] {
        try await withThrowingTaskGroup(of: CandidateResult.self, returning: [CandidateResult].self) { group in
            for profile in profiles {
                group.addTask { [remoteClient] in
                    let started = Date()
                    do {
                        let changes = try await remoteClient.correctDocument(
                            contextText,
                            configuration: configuration,
                            systemPrompt: await Self.prompt(base: systemPrompt, profile: profile),
                            temperature: profile.temperature,
                            reasoningEffort: profile.reasoningEffort
                        )
                        let accepted = await Self.individuallySafeChanges(changes, protected: protected)
                        let latency = Int(Date().timeIntervalSince(started) * 1_000)
                        return CandidateResult(
                            id: profile.id,
                            profile: profile,
                            changes: changes,
                            acceptedChanges: accepted.changes,
                            rejectedCount: accepted.rejectedCount,
                            latencyMS: latency,
                            errorDescription: nil,
                            inputTokens: max(1, contextText.count / 4),
                            outputTokens: max(1, changes.reduce(0) { $0 + $1.find.count + $1.replacement.count } / 4),
                            apiCallCount: 1,
                            requestID: UUID().uuidString,
                            rejectionReasons: Array(repeating: "unsafe_change", count: accepted.rejectedCount)
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        let latency = Int(Date().timeIntervalSince(started) * 1_000)
                        return CandidateResult(
                            id: profile.id,
                            profile: profile,
                            changes: [],
                            acceptedChanges: [],
                            rejectedCount: 0,
                            latencyMS: latency,
                            errorDescription: error.localizedDescription,
                            inputTokens: max(1, contextText.count / 4),
                            outputTokens: 0,
                            apiCallCount: 1,
                            requestID: UUID().uuidString,
                            rejectionReasons: [error.localizedDescription]
                        )
                    }
                }
            }

            var collected: [CandidateResult] = []
            for try await result in group { collected.append(result) }
            let sorted = collected.sorted { lhs, rhs in
                profiles.firstIndex { $0.id == lhs.id } ?? 0 < profiles.firstIndex { $0.id == rhs.id } ?? 0
            }
            for candidate in sorted { Self.record(candidate, runID: runID, systemPrompt: systemPrompt, store: GrammarDebugStore.shared) }
            return sorted
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
