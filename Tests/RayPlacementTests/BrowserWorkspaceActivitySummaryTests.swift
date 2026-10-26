import Foundation
import Testing
@testable import RayPlacement

@Test func browserStatusUsesRecordedActionAndDoesNotClaimRemoteVerification() {
    let activity = BrowserAIActivity(id: UUID(), tabID: UUID(), title: "Reading page", state: .working)
    #expect(BrowserWorkspaceActivitySummary.resolve(activity: nil, isPaused: false) == nil)
    #expect(BrowserWorkspaceActivitySummary.resolve(activity: activity, isPaused: false)?.label
            == "Observing · Reading page")

    let acting = BrowserAIActivity(id: UUID(), tabID: UUID(), title: "Navigating", state: .working)
    #expect(BrowserWorkspaceActivitySummary.resolve(activity: acting, isPaused: false)?.label
            == "Acting · Navigating")

    let returned = BrowserAIActivity(id: UUID(), tabID: UUID(), title: "Interacting with page", state: .completed)
    #expect(BrowserWorkspaceActivitySummary.resolve(activity: returned, isPaused: false)?.label
            == "Returned · Interacting with page")
}

@Test func browserStatusPrioritizesPauseAndShowsFailuresAsBlocked() {
    let failed = BrowserAIActivity(id: UUID(), tabID: UUID(), title: "Inspecting page", state: .failed)
    #expect(BrowserWorkspaceActivitySummary.resolve(activity: failed, isPaused: false)?.label
            == "Blocked · Inspecting page")
    #expect(BrowserWorkspaceActivitySummary.resolve(activity: failed, isPaused: false)?.isBlocked == true)

    let paused = BrowserWorkspaceActivitySummary.resolve(activity: failed, isPaused: true)
    #expect(paused?.label == "Paused · AI access on this tab")
    #expect(paused?.isBlocked == false)
    #expect(BrowserWorkspaceActivitySummary.resolve(activity: nil, isPaused: true) == paused)
}
