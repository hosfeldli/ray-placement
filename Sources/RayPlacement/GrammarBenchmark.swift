import Foundation
import RayPlacementWriting

struct GrammarBenchmarkCase: Identifiable, Sendable {
    let id: String
    let source: String
    let expected: [StealthGrammarDocumentChange]
}

struct GrammarBenchmarkResult: Identifiable, Sendable {
    let id = UUID()
    let caseID: String
    let applied: Int
    let expected: Int
    let falsePositive: Int
    let latencyMS: Int
    let passed: Bool
    let apiCalls: Int
}

struct GrammarBenchmarkSummary: Sendable {
    let results: [GrammarBenchmarkResult]
    var passed: Int { results.filter(\.passed).count }
    var accuracy: Double { results.isEmpty ? 0 : Double(passed) / Double(results.count) }
    var totalLatencyMS: Int { results.reduce(0) { $0 + $1.latencyMS } }
    var apiCalls: Int { results.reduce(0) { $0 + $1.apiCalls } }
}

struct GrammarBenchmarkComparisonRow: Identifiable, Sendable {
    let strategy: GrammarEnsembleStrategy
    let summary: GrammarBenchmarkSummary
    var id: String { strategy.rawValue }
    var accuracy: Double { summary.accuracy }
    var latencyMS: Int { summary.totalLatencyMS }
    var apiCalls: Int { summary.apiCalls }
}

struct GrammarBenchmarkComparison: Sendable {
    let rows: [GrammarBenchmarkComparisonRow]
}

enum GrammarBenchmarkCorpus {
    static let cases: [GrammarBenchmarkCase] = [
        .init(id: "agreement", source: "The reports is ready for review.", expected: [.init(find: "reports is", replacement: "reports are")]),
        .init(id: "apostrophe", source: "The teams results were posted.", expected: [.init(find: "teams results", replacement: "team's results")]),
        .init(id: "punctuation", source: "Please review the file and reply.", expected: []),
        .init(id: "spelling", source: "The enviroment is stable.", expected: [.init(find: "enviroment", replacement: "environment")]),
        .init(id: "preservation", source: "EDI, AS2, and SFTP remain enabled.", expected: [])
    ]
}

@MainActor
final class GrammarBenchmarkService {
    private let coordinator: GrammarEnsembleCoordinator
    init(coordinator: GrammarEnsembleCoordinator) { self.coordinator = coordinator }

    func run(configuration: DeveloperGrammarConfiguration, strategy: GrammarEnsembleStrategy) async -> GrammarBenchmarkSummary {
        var results: [GrammarBenchmarkResult] = []
        for item in GrammarBenchmarkCorpus.cases {
            let started = Date()
            let protected = StealthGrammarService.protect(item.source, ignoreList: SettingsStore.shared.writingInstructions)
            do {
                let result = try await coordinator.run(contextText: protected.contextText, source: item.source, protected: protected, configuration: configuration, strategy: strategy, systemPrompt: StealthGrammarRemoteClient.systemPrompt, useJudgeOnDisagreement: SettingsStore.shared.grammarJudgeOnDisagreement)
                let applied = result.report.appliedCount
                let expected = item.expected.count
                let falsePositive = max(0, applied - expected)
                results.append(GrammarBenchmarkResult(caseID: item.id, applied: applied, expected: expected, falsePositive: falsePositive, latencyMS: Int(Date().timeIntervalSince(started) * 1_000), passed: expected == applied && falsePositive == 0, apiCalls: result.candidates.count + (result.judgeUsed ? 1 : 0)))
            } catch {
                results.append(GrammarBenchmarkResult(caseID: item.id, applied: 0, expected: item.expected.count, falsePositive: 0, latencyMS: Int(Date().timeIntervalSince(started) * 1_000), passed: false, apiCalls: 0))
            }
        }
        return GrammarBenchmarkSummary(results: results)
    }

    func compare(configuration: DeveloperGrammarConfiguration, strategies: [GrammarEnsembleStrategy]) async -> GrammarBenchmarkComparison {
        var seen = Set<GrammarEnsembleStrategy>()
        var rows: [GrammarBenchmarkComparisonRow] = []
        for strategy in strategies where seen.insert(strategy).inserted {
            let summary = await run(configuration: configuration, strategy: strategy)
            rows.append(GrammarBenchmarkComparisonRow(strategy: strategy, summary: summary))
        }
        return GrammarBenchmarkComparison(rows: rows)
    }
}
