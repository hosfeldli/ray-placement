import Foundation

struct GrammarScoringWeights: Codable, Equatable, Sendable {
    var preservation: Int = 30
    var grammarImprovement: Int = 30
    var consensus: Int = 25
    var minimality: Int = 15

    var total: Int { preservation + grammarImprovement + consensus + minimality }
    var isValid: Bool { total == 100 && [preservation, grammarImprovement, consensus, minimality].allSatisfy { 0...100 ~= $0 } }

    mutating func restoreDefaults() {
        self = GrammarScoringWeights()
    }
}

struct GrammarCorrectionPolicy: Codable, Equatable, Sendable {
    var maximumAtomicEditLength = 120
    var maximumRewriteRatio = 0.15
    var requireContextForShortEdits = true
    var applyValidEditsWhenAnotherProposalIsRejected = true
    var rejectPunctuationCollapse = true
    var rejectWhitespaceCollapse = true
    var rejectDuplicateAdjacentWords = true

    static let safeDefaults = GrammarCorrectionPolicy()
}

struct GrammarCandidateSettings: Codable, Equatable, Sendable {
    var enabled: Bool
    var profile: String
    var diversitySeed: UInt64
    var temperature: Double?
    var reasoningEffort: String?
    var maximumResponseTokens: Int?
    var promptVersion: String

    init(profile: GrammarCandidateProfile, enabled: Bool = true) {
        self.enabled = enabled
        self.profile = profile.id
        self.diversitySeed = profile.diversitySeed
        self.temperature = profile.temperature
        self.reasoningEffort = profile.reasoningEffort
        self.maximumResponseTokens = nil
        self.promptVersion = profile.promptVersion
    }
}

struct GrammarJudgeConfiguration: Codable, Equatable, Sendable {
    var enabled = true
    var useSeparateModel = false
    var model: String?
    var minimumDisagreement = 0.33
    var minimumConfidence = 0.75
    var rejectWhenUncertain = true
    var temperature = 0.05
    var reasoningEffort = "Low"
}

struct GrammarCandidateConfigurationSnapshot: Codable, Equatable, Sendable {
    let id: String
    let enabled: Bool
    let profile: String
    let diversitySeed: UInt64
    let temperature: Double?
    let reasoningEffort: String?
    let maximumResponseTokens: Int?
    let promptVersion: String
}

struct GrammarRunConfigurationSnapshot: Codable, Equatable, Sendable {
    let correctionMode: GrammarCorrectionMode
    let strategy: GrammarEnsembleStrategy
    let provider: String
    let model: String
    let candidates: [GrammarCandidateConfigurationSnapshot]
    let judgeEnabled: Bool
    let judgeModel: String?
    let judgeThreshold: Double
    let scoringWeights: GrammarScoringWeights
    let correctionPolicy: GrammarCorrectionPolicy
    let promptVersion: String

    @MainActor
    static func current(
        configuration: DeveloperGrammarConfiguration,
        strategy: GrammarEnsembleStrategy,
        profiles: [GrammarCandidateProfile],
        candidateSettings: [String: GrammarCandidateSettings] = [:],
        judge: GrammarJudgeConfiguration,
        scoringWeights: GrammarScoringWeights,
        correctionPolicy: GrammarCorrectionPolicy
    ) -> GrammarRunConfigurationSnapshot {
        let settings = SettingsStore.shared
        return GrammarRunConfigurationSnapshot(
            correctionMode: settings.grammarCorrectionMode,
            strategy: strategy,
            provider: configuration.provider.rawValue,
            model: configuration.model,
            candidates: profiles.map {
                let candidate = candidateSettings[$0.id] ?? GrammarCandidateSettings(profile: $0)
                return GrammarCandidateConfigurationSnapshot(
                    id: $0.id,
                    enabled: candidate.enabled,
                    profile: candidate.profile,
                    diversitySeed: candidate.diversitySeed,
                    temperature: candidate.temperature,
                    reasoningEffort: candidate.reasoningEffort,
                    maximumResponseTokens: candidate.maximumResponseTokens,
                    promptVersion: candidate.promptVersion
                )
            },
            judgeEnabled: judge.enabled,
            judgeModel: judge.useSeparateModel ? judge.model : nil,
            judgeThreshold: judge.minimumConfidence,
            scoringWeights: scoringWeights,
            correctionPolicy: correctionPolicy,
            promptVersion: profiles.map(\.promptVersion).uniqued().joined(separator: ",")
        )
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
