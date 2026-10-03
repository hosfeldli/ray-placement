import AppKit
import Foundation
import Testing
@testable import RayPlacement

@Test func activityStreamShowsOnlyRecordedWorkAndCollapsesCompletedPairs() {
    #expect(AIActivityStream.steps(from: [], isActive: true).isEmpty)

    let started = AIAgentActivity(kind: .toolStarted, title: "read_file", detail: "Lima")
    let running = AIActivityStream.steps(from: [started], isActive: true)
    #expect(running.count == 1)
    #expect(running[0].status == .running)
    #expect(running[0].detail == nil)
    #expect(AIActivityStream.completedActionCount(running) == 0)

    let completed = AIAgentActivity(kind: .toolCompleted, title: "read_file", completed: true)
    let done = AIActivityStream.steps(from: [started, completed], isActive: false)
    #expect(done.count == 1)
    #expect(done[0].title == "Read a file")
    #expect(done[0].status == .completed)
    #expect(AIActivityStream.completedActionCount(done) == 1)
}

@Test func activityStreamTracksApprovalAndFailureWithoutFutureSteps() {
    let request = AIAgentActivity(kind: .started, title: "Started")
    let approval = AIAgentActivity(kind: .toolApproval, title: "Approval needed", detail: "Lima · open_url")
    let waiting = AIActivityStream.steps(from: [request, approval], isActive: true)
    #expect(waiting.map(\.title) == ["Approval needed"])
    #expect(waiting[0].status == .waiting)

    let denied = AIAgentActivity(kind: .toolApproval, title: "Tool denied", detail: "Lima · open_url", completed: true)
    let finished = AIActivityStream.steps(from: [request, approval, denied], isActive: false)
    #expect(finished.count == 1)
    #expect(finished[0].title == "Tool denied")
    #expect(finished[0].status == .failed)
    #expect(AIActivityStream.completedActionCount(finished) == 0)

    let unfinished = AIActivityStream.steps(from: [request, AIAgentActivity(kind: .toolStarted, title: "read_web")], isActive: false)
    #expect(unfinished[0].status == .interrupted)
    #expect(AIActivityStream.terminalState(from: [request], steps: unfinished) == .stopped)
    #expect(AIActivityStream.terminalState(from: [request, approval, denied], steps: finished) == .needsAttention)
}

@Test func activityTerminalStateRespectsExplicitStopAndSuccess() {
    let stopped = AIAgentActivity(kind: .completed, title: "Stopped", completed: true)
    #expect(AIActivityStream.terminalState(from: [stopped], steps: []) == .stopped)
    let done = AIAgentActivity(kind: .completed, title: "Response complete", completed: true)
    #expect(AIActivityStream.terminalState(from: [done], steps: []) == .done)
}

@Test @MainActor func aiCopyPreservesExactCodeAndResponseText() {
    let pasteboard = NSPasteboard.withUniqueName()
    let code = "    SELECT *\n    FROM shipments;\n"
    #expect(AIChatClipboard.copy(code, to: pasteboard))
    #expect(pasteboard.string(forType: .string) == code)

    let response = "First paragraph.\n\n- Detail one\n- Detail two"
    #expect(AIChatClipboard.copy(response, to: pasteboard))
    #expect(pasteboard.string(forType: .string) == response)
    #expect(!AIChatClipboard.copy("", to: pasteboard))
    #expect(pasteboard.string(forType: .string) == response)
}
