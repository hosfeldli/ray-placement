import Foundation
import Testing
@testable import RayPlacement

@Test func grammarRunTransitionsThroughCheckingAndApplyingExactlyOnce() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var run = GrammarExecutionRun(startedAt: start)

    #expect(run.state == .queued)
    #expect(run.isActive)
    let enteredChecking = run.transition(to: .checking, at: start.addingTimeInterval(1))
    let enteredApplying = run.transition(to: .applying, at: start.addingTimeInterval(2))
    let completed = run.transition(to: .completed, at: start.addingTimeInterval(3))
    #expect(enteredChecking)
    #expect(enteredApplying)
    #expect(completed)
    #expect(run.state == .completed)
    #expect(run.completedAt == start.addingTimeInterval(3))
    #expect(!run.isActive)
    let rejectedTerminalTransition = run.transition(to: .failed, at: start.addingTimeInterval(4))
    #expect(!rejectedTerminalTransition)
    #expect(run.completedAt == start.addingTimeInterval(3))
}

@Test func grammarRunRecordsFailureAndCancellationAsTerminalStates() {
    let start = Date(timeIntervalSince1970: 1_800_000_100)
    var failedRun = GrammarExecutionRun(startedAt: start)
    let failedRunEnteredChecking = failedRun.transition(to: .checking)
    let failedRunFinished = failedRun.transition(to: .failed, at: start.addingTimeInterval(1))
    #expect(failedRunEnteredChecking)
    #expect(failedRunFinished)
    #expect(failedRun.state == .failed)
    #expect(failedRun.completedAt == start.addingTimeInterval(1))

    var cancelledRun = GrammarExecutionRun(startedAt: start)
    let cancelledRunEnteredChecking = cancelledRun.transition(to: .checking)
    let cancelledRunFinished = cancelledRun.transition(to: .cancelled, at: start.addingTimeInterval(2))
    #expect(cancelledRunEnteredChecking)
    #expect(cancelledRunFinished)
    #expect(cancelledRun.state == .cancelled)
    #expect(!cancelledRun.isActive)
}

@Test @MainActor func grammarCorrectionUsesTheSharedTaskRegistryLifecycle() {
    let registry = TaskRegistry()
    let taskID = registry.begin(
        kind: .grammar,
        title: "Fixing writing",
        detail: "Checking selected text",
        isCancellable: true
    )

    #expect(registry.activeTasks.first?.kind == .grammar)
    #expect(registry.activeTasks.first?.kind.title == "Writing correction")
    #expect(registry.activeTasks.first?.detail == "Checking selected text")

    registry.update(taskID, detail: "Applying correction")
    #expect(registry.activeTasks.first?.detail == "Applying correction")

    registry.finish(taskID, detail: "Correction applied")
    #expect(registry.activeTasks.isEmpty)
    #expect(registry.recentTasks.first?.state == .completed)
    #expect(registry.recentTasks.first?.detail == "Correction applied")
}
