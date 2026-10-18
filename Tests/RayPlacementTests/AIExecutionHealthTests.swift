import Foundation
import Testing
@testable import RayPlacement

private func healthCall(_ id: String, _ arguments: String = #"{"target":"t_12","tab_id":"tab"}"#) -> AIOutputItem {
    AIOutputItem(
        phase: .completed, apiType: "function_call", id: id,
        callID: id, name: "browser_activate", arguments: arguments
    )
}

@Test func executionHealthRecoversRepeatedEquivalentFailuresWithoutATotalCallLimit() {
    var health = AIExecutionHealth()
    let failed = #"{"state":"failed","error":{"code":"stale_target"}}"#
    for index in 1...3 {
        let call = healthCall("\(index)")
        #expect(health.decision(for: call) == .execute)
        health.observe(call, output: AIEngineToolOutput(callID: call.callID!, output: failed))
    }
    let reordered = healthCall("4", #"{"tab_id":"tab","target":"t_12"}"#)
    #expect(health.decision(for: reordered) == .suggestRecovery)
    let recovery = AIExecutionHealth.recoveryOutput(callID: "4")
    #expect(recovery.output.contains("repeated_action_without_progress"))
    health.observe(reordered, output: recovery)
    for index in 5...6 {
        let call = healthCall("\(index)")
        #expect(health.decision(for: call) == .suggestRecovery)
        health.observe(call, output: AIExecutionHealth.recoveryOutput(callID: call.callID!))
    }
    #expect(health.decision(for: healthCall("7")) == .blocked)

    let freshRead = healthCall("8", #"{"tab_id":"tab","target":"t_13"}"#)
    #expect(health.decision(for: freshRead) == .execute)
    health.observe(freshRead, output: AIEngineToolOutput(callID: "8", output: #"{"state":"completed"}"#))
    for index in 9...108 {
        let call = healthCall("\(index)")
        #expect(health.decision(for: call) == .execute)
        health.observe(call, output: AIEngineToolOutput(callID: call.callID!, output: #"{"state":"completed"}"#))
    }
}

@Test func executionHealthIgnoresSuccessfulAndNonJSONResults() {
    var health = AIExecutionHealth()
    for index in 1...20 {
        let call = healthCall("\(index)")
        #expect(health.decision(for: call) == .execute)
        health.observe(call, output: AIEngineToolOutput(callID: call.callID!, output: "plain text"))
    }
    #expect(health.decision(for: healthCall("21")) == .execute)
}
