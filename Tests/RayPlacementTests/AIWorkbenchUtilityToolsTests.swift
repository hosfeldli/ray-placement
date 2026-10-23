import Foundation
import Testing
@testable import RayPlacement

@Test func boundedSleepCompletesRejectsLongWaitsAndCancelsWithTheRun() async throws {
    let valid = AIOutputItem(phase: .completed, apiType: "function_call",
        callID: "sleep-valid", name: "sleep", arguments: #"{"milliseconds":5}"#)
    let completed = await AIWorkbenchUtilityTools.execute(valid)
    #expect(!completed.isError)
    #expect(completed.output.contains("\"wait_completed\":true"))
    #expect(completed.output.contains("\"requested_milliseconds\":5"))

    let tooLong = AIOutputItem(phase: .completed, apiType: "function_call",
        callID: "sleep-long", name: "sleep", arguments: #"{"milliseconds":30001}"#)
    let rejected = await AIWorkbenchUtilityTools.execute(tooLong)
    #expect(rejected.isError)

    let pending = AIOutputItem(phase: .completed, apiType: "function_call",
        callID: "sleep-cancel", name: "sleep", arguments: #"{"milliseconds":30000}"#)
    let task = Task { await AIWorkbenchUtilityTools.execute(pending) }
    task.cancel()
    let cancelled = await task.value
    #expect(cancelled.isError)
    #expect(cancelled.output.contains("\"wait_completed\":false"))
}
