import Foundation
import Testing
@testable import RayPlacement
import RayPlacementWriting

@Test @MainActor func grammarDebugStorePersistsCandidatesFeedbackAnalyticsAndExport() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lima-grammar-debug-\(UUID().uuidString)", isDirectory: true)
    let database = directory.appendingPathComponent("debug.sqlite")
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = GrammarDebugStore(databaseURL: database)
    let runID = UUID()
    store.beginRun(id: runID, startedAt: Date(), strategy: .balanced, sourceText: nil, contextText: nil, systemPrompt: "proofread")
    let change = StealthGrammarDocumentChange(find: "is", replacement: "are")
    store.recordCandidate(GrammarDebugCandidate(
        id: "minimal-editor", runID: runID, profileID: "minimal-editor", seed: 17,
        promptVersion: "test-v1", instructions: "Be conservative", prompt: "proofread",
        temperature: 0.1, latencyMS: 42, rawChanges: [change], acceptedChanges: [change],
        rejectedCount: 0, error: nil
    ))
    store.saveFeedback(GrammarDebugFeedback(runID: runID, candidateID: "minimal-editor", decision: "approved", note: "safe", createdAt: Date()))
    store.finishRun(id: runID, status: "completed", judgeUsed: false, judgeError: nil, candidateCount: 1, appliedCount: 1, finalChanges: [change])

    #expect(store.recentRuns().first?.id == runID)
    #expect(store.candidates(for: runID).first?.acceptedChanges == [change])
    #expect(store.feedback(for: runID).first?.decision == "approved")
    #expect(store.analytics().first?.seed == 17)
    #expect(store.analytics().first?.feedbackApprovedCount == 1)

    let exportURL = try store.export(includeSource: false)
    defer { try? FileManager.default.removeItem(at: exportURL) }
    let exported = try String(contentsOf: exportURL)
    #expect(exported.contains("minimal-editor"))
    #expect(!exported.contains("sourceText"))
}
