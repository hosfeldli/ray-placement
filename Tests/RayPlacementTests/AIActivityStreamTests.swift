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

    let unfinished = AIActivityStream.steps(from: [request, AIAgentActivity(kind: .toolStarted, title: "browser_read")], isActive: false)
    #expect(unfinished[0].status == .interrupted)
    #expect(AIActivityStream.terminalState(from: [request], steps: unfinished) == .stopped)
    #expect(AIActivityStream.terminalState(from: [request, approval, denied], steps: finished) == .needsAttention)
}

@Test func parallelSubagentStepsFollowReservedOrdinalsNotSchedulerOrder() {
    let second = AIAgentActivity(kind: .toolStarted, title: "Subagent 2",
                                 detail: "Analyze B", correlationID: "child-b")
    let first = AIAgentActivity(kind: .toolStarted, title: "Subagent 1",
                                detail: "Analyze A", correlationID: "child-a")
    let firstDone = AIAgentActivity(kind: .toolCompleted, title: "Subagent 1",
                                    correlationID: "child-a", completed: true)
    let secondDone = AIAgentActivity(kind: .toolCompleted, title: "Subagent 2",
                                     correlationID: "child-b", completed: true)
    let steps = AIActivityStream.steps(from: [second, first, firstDone, secondDone], isActive: false)
    #expect(steps.map(\.title) == ["Subagent 1", "Subagent 2"])
    #expect(steps.map(\.detail) == ["Analyze A", "Analyze B"])
    #expect(steps.map(\.correlationID) == ["child-a", "child-b"])
    #expect(steps.allSatisfy { $0.status == .completed })
}

@Test func activityFlowNestsOnlyRecordedCallsUnderTheirActualParallelAgent() {
    let events = [
        AIAgentActivity(kind: .toolStarted, title: "Subagent 2",
                        correlationID: "child-b"),
        AIAgentActivity(kind: .toolStarted, title: "browser_read",
                        correlationID: "child-b/read", parentCorrelationID: "child-b"),
        AIAgentActivity(kind: .toolStarted, title: "Subagent 1",
                        correlationID: "child-a"),
        AIAgentActivity(kind: .toolStarted, title: "terminal_read",
                        correlationID: "child-a/read", parentCorrelationID: "child-a"),
        AIAgentActivity(kind: .toolCompleted, title: "terminal_read",
                        correlationID: "child-a/read", parentCorrelationID: "child-a", completed: true),
        AIAgentActivity(kind: .toolCompleted, title: "browser_read",
                        correlationID: "child-b/read", parentCorrelationID: "child-b", completed: true),
        AIAgentActivity(kind: .toolCompleted, title: "Subagent 1",
                        correlationID: "child-a", completed: true),
        AIAgentActivity(kind: .toolCompleted, title: "Subagent 2",
                        correlationID: "child-b", completed: true),
        AIAgentActivity(kind: .toolStarted, title: "orphan_tool",
                        correlationID: "missing/read", parentCorrelationID: "missing")
    ]
    let steps = AIActivityStream.steps(from: events, isActive: true)
    let nodes = AIActivityStream.flowNodes(from: steps)
    #expect(nodes.map(\.step.correlationID) == ["child-a", "child-b", "missing/read"])
    #expect(nodes[0].children.map(\.correlationID) == ["child-a/read"])
    #expect(nodes[1].children.map(\.correlationID) == ["child-b/read"])
    #expect(nodes[2].children.isEmpty)
    #expect(nodes[0].children[0].status == .completed)
    #expect(nodes[1].children[0].status == .completed)
    #expect(nodes[2].step.status == .running)
    #expect(AIActivityStream.completedActionCount(steps) == 4)
}

@Test func parallelApprovalsPairByCallAndStayOnTheirAgentBranches() {
    let events = [
        AIAgentActivity(kind: .toolStarted, title: "Subagent 1", correlationID: "child-a"),
        AIAgentActivity(kind: .toolStarted, title: "Subagent 2", correlationID: "child-b"),
        AIAgentActivity(kind: .toolApproval, title: "Approval needed",
                        correlationID: "child-a/tool/approval", parentCorrelationID: "child-a"),
        AIAgentActivity(kind: .toolApproval, title: "Approval needed",
                        correlationID: "child-b/tool/approval", parentCorrelationID: "child-b"),
        AIAgentActivity(kind: .toolApproval, title: "Tool allowed once",
                        correlationID: "child-a/tool/approval", parentCorrelationID: "child-a", completed: true)
    ]
    let pending = AIActivityStream.flowNodes(from: AIActivityStream.steps(from: events, isActive: true))
    #expect(pending.map(\.step.title) == ["Subagent 1", "Subagent 2"])
    #expect(pending[0].children.map(\.status) == [.completed])
    #expect(pending[1].children.map(\.status) == [.waiting])

    let failedGrant = AIAgentActivity(kind: .toolApproval, title: "Directory grant unavailable",
                                      correlationID: "child-b/tool/approval", parentCorrelationID: "child-b", completed: true)
    let finished = AIActivityStream.flowNodes(from: AIActivityStream.steps(from: events + [failedGrant], isActive: false))
    #expect(finished[0].children[0].title == "Tool allowed once")
    #expect(finished[1].children[0].title == "Directory grant unavailable")
    #expect(finished[1].children[0].status == .failed)
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
