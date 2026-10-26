import Foundation
import Testing
import WebKit
@testable import RayPlacement

private func visualPolicyCall(
    _ name: String, _ arguments: [String: Any] = [:]
) throws -> AIOutputItem {
    let data = try JSONSerialization.data(withJSONObject: arguments)
    return AIOutputItem(
        phase: .completed, apiType: "function_call", callID: UUID().uuidString,
        name: name, arguments: String(decoding: data, as: UTF8.self)
    )
}

private func visualPolicyObject(_ result: LimaAIToolExecution) throws -> [String: Any] {
    let data = Data(result.output.utf8)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func visualAssessment(
    label: String, isSubmit: Bool = false, isEditable: Bool = false,
    isCanvas: Bool = false, sensitive: Bool = false,
    financialContext: Bool = false, financialTerms: [String] = [],
    protectedContext: Bool = false
) -> BrowserVisualActionAssessment {
    BrowserVisualActionAssessment(
        label: label, role: isCanvas ? "canvas" : "button",
        formLabel: "", isSubmit: isSubmit, isEditable: isEditable,
        isCanvas: isCanvas, sensitive: sensitive, disabled: false,
        financialContext: financialContext, financialTerms: financialTerms,
        protectedContext: protectedContext
    )
}

@Test @MainActor func browserAutoApprovalExpiresWithExactTaskAndSite() {
    let state = BrowserTaskApprovalState()
    state.select(.autoApproveNonpayment)
    let firstRun = UUID()
    state.begin(
        runID: firstRun,
        instruction: "Find options at https://example.com/booking",
        initialURL: nil
    )
    #expect(state.activeMode == .autoApproveNonpayment)
    #expect(state.isAutoApproved(runID: firstRun, url: "https://example.com/checkout"))
    #expect(!state.isAutoApproved(runID: UUID(), url: "https://example.com/checkout"))
    #expect(!state.isAutoApproved(runID: firstRun, url: "https://pay.example.com/checkout"))
    #expect(!state.isAutoApproved(runID: firstRun, url: "https://example.com:9443/checkout"))
    #expect(!state.isAutoApproved(runID: firstRun, url: "http://example.com/checkout"))
    #expect(!state.isAutoApproved(runID: firstRun, url: "https://other.test/"))
    #expect(state.authorizedSites == Set(["https://example.com:443"]))
    state.noteBlockedSite("https://pay.example.com/checkout?token=private")
    #expect(state.requestedSite == "https://pay.example.com:443")
    #expect(!state.isWithinScope(runID: firstRun, url: "https://pay.example.com/"))
    state.dismissRequestedSite()
    #expect(state.requestedSite == nil)
    state.noteBlockedSite("https://pay.example.com/checkout")
    state.authorizeRequestedSite()
    #expect(state.requestedSite == nil)
    #expect(state.isAutoApproved(runID: firstRun, url: "https://pay.example.com/checkout"))
    state.authorizeVisibleSite("https://other.test/page")
    #expect(state.isAutoApproved(runID: firstRun, url: "https://other.test/next"))
    state.end(runID: firstRun)
    #expect(!state.isWithinScope(runID: firstRun, url: "https://example.com/"))
    #expect(state.activeRunID == nil)
    #expect(state.requestedSite == nil)
    #expect(state.displayMode == .askForActions)

    // Arming must be explicit for the next run; no authority is inherited.
    let nextRun = UUID()
    state.begin(runID: nextRun, instruction: "Continue", initialURL: nil)
    #expect(state.activeMode == .askForActions)
    #expect(state.authorizedSites.isEmpty)
    #expect(!state.isAutoApproved(runID: nextRun, url: "https://example.com/"))
    state.end(runID: nextRun)

    state.select(.autoApproveNonpayment)
    let explicitRun = UUID()
    state.begin(runID: explicitRun,
                instruction: "Visit https://target.example/path",
                initialURL: "https://unrelated.example/account")
    #expect(state.authorizedSites == Set(["https://target.example:443"]))
    #expect(!state.isWithinScope(runID: explicitRun,
                                 url: "https://unrelated.example/account"))
    state.end(runID: explicitRun)

    state.select(.autoApproveNonpayment)
    let currentPageRun = UUID()
    state.begin(runID: currentPageRun, instruction: "Work on this page",
                initialURL: "https://current.example/page")
    #expect(state.authorizedSites == Set(["https://current.example:443"]))
    state.end(runID: currentPageRun)
}

@Test func browserVisualActionPolicySeparatesRoutinePaymentAndProtectedActions() {
    #expect(visualAssessment(label: "Select 7:00 PM").decision == .routine)
    #expect(!visualAssessment(label: "Select 7:00 PM").potentialPaymentCommitment)
    #expect(visualAssessment(
        label: "Search", isSubmit: true, financialTerms: ["$50 deposit"]
    ).decision == .routine)
    #expect(visualAssessment(
        label: "Search", isSubmit: true, financialContext: true
    ).decision == .review)
    #expect(visualAssessment(
        label: "", isCanvas: true
    ).decision == .review)
    #expect(visualAssessment(
        label: "Guest name", isEditable: true, financialContext: true
    ).decision == .routine)
    #expect(visualAssessment(
        label: "I agree to the fee", financialTerms: ["$50 fee"]
    ).decision == .review)
    #expect(visualAssessment(
        label: "Place order", isSubmit: true
    ).decision == .review)
    #expect(visualAssessment(
        label: "Place order", isSubmit: true
    ).potentialPaymentCommitment)
    #expect(visualAssessment(
        label: "", isCanvas: true, financialTerms: ["Total $50"]
    ).decision == .review)
    #expect(visualAssessment(
        label: "Continue", isSubmit: true
    ).decision == .review)
    #expect(visualAssessment(label: "Reserve").decision == .review)
    #expect(visualAssessment(label: "Book now").decision == .review)
    #expect(visualAssessment(label: "Send feedback", isSubmit: true).decision == .routine)
    #expect(visualAssessment(label: "Send feedback", isSubmit: true,
                             financialContext: true).decision == .review)
    #expect(visualAssessment(label: "Continue", isCanvas: true).decision == .review)
    #expect(!visualAssessment(
        label: "Continue", isSubmit: true
    ).potentialPaymentCommitment)
    #expect(visualAssessment(
        label: "Password", isEditable: true, sensitive: true
    ).decision == .blocked)
    #expect(visualAssessment(
        label: "Delete account", protectedContext: true
    ).decision == .blocked)
}

@Test @MainActor func browserTaskSiteRejectsUnsafeURLsAndNormalizesDefaultPort() {
    #expect(BrowserTaskApprovalState.site("https://example.com/path") == "https://example.com:443")
    #expect(BrowserTaskApprovalState.site("https://example.com:443/path") == "https://example.com:443")
    #expect(BrowserTaskApprovalState.site("https://example.com:8443/path") == "https://example.com:8443")
    #expect(BrowserTaskApprovalState.site("http://127.0.0.1:8080/") == "http://127.0.0.1:8080")
    #expect(BrowserTaskApprovalState.site("http://example.com/") == nil)
    #expect(BrowserTaskApprovalState.site("https://user:pass@example.com/") == nil)
}

@Test @MainActor func browserPauseBlocksSemanticAndNavigationAITools() async throws {
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .fullControl
    let tab = model.newTab()
    model.pauseAI(on: tab.id)
    let blockedCalls: [(String, [String: Any])] = [
        ("browser_navigate", ["tab_id": tab.id.uuidString, "url": "https://example.com/"]),
        ("browser_back", ["tab_id": tab.id.uuidString]),
        ("browser_click", ["tab_id": tab.id.uuidString, "target": "stale"]),
        ("browser_focus_tab", ["tab_id": tab.id.uuidString])
    ]
    for (name, arguments) in blockedCalls {
        let result = await BrowserWorkspaceAITools.execute(
            try visualPolicyCall(name, arguments), browser: model
        )
        #expect(result.isError)
        #expect(result.output.contains("explicitly paused"))
    }
}

@Test @MainActor func browserNavigationModeLimitsAvailableToolsIndependentlyOfPermission() async throws {
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .fullControl
    model.navigationMode = .visualOnly
    let visual = try visualPolicyObject(await BrowserWorkspaceAITools.execute(
        visualPolicyCall("browser_capabilities"), browser: model
    ))
    #expect(visual["navigation_method"] as? String == "visualOnly")
    let visualTools = try #require(visual["available_tools"] as? [String])
    #expect(visualTools.contains("browser_visual_click"))
    #expect(visualTools.contains("browser_visual_type"))
    #expect(visualTools.contains("browser_screenshot"))
    #expect(!visualTools.contains("browser_read"))
    #expect(!visualTools.contains("browser_hit_test"))

    model.navigationMode = .semanticOnly
    let semantic = try visualPolicyObject(await BrowserWorkspaceAITools.execute(
        visualPolicyCall("browser_capabilities"), browser: model
    ))
    let semanticTools = try #require(semantic["available_tools"] as? [String])
    #expect(semanticTools.contains("browser_read"))
    #expect(!semanticTools.contains("browser_screenshot"))
    #expect(!semanticTools.contains("browser_visual_click"))

    let screenshot = await BrowserWorkspaceAITools.execute(
        try visualPolicyCall("browser_screenshot", ["tab_id": UUID().uuidString]),
        browser: model
    )
    #expect(screenshot.isError)
}

@Test @MainActor func browserAskForActionsRequiresNativeApproval() async throws {
    let state = BrowserTaskApprovalState.shared
    state.select(.askForActions)
    let runID = UUID()
    state.begin(runID: runID, instruction: "Close the current tab", initialURL: nil)
    defer { state.end(runID: runID) }

    #expect(state.requiresActionPrompt(runID: runID, toolID: "browser_close_tab"))
    #expect(state.requiresActionPrompt(runID: runID, toolID: "browser_visual_scroll"))
    #expect(state.requiresActionPrompt(runID: runID, toolID: "browser_visual_type"))
    #expect(!state.requiresActionPrompt(runID: runID, toolID: "browser_screenshot"))
    #expect(!state.requiresActionPrompt(runID: UUID(), toolID: "browser_close_tab"))

    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .fullControl
    let tab = model.newTab()
    let call = try visualPolicyCall("browser_close_tab", ["tab_id": tab.id.uuidString])
    let denied = await BrowserWorkspaceAITools.execute(
        call, browser: model, runID: runID
    )
    #expect(denied.isError)
    #expect(denied.output.contains("Ask for Actions"))
    #expect(model.tabs.contains { $0.id == tab.id })

    let allowed = await BrowserWorkspaceAITools.execute(
        call, browser: model, approvalGranted: true, runID: runID
    )
    #expect(!allowed.isError)
    #expect(!model.tabs.contains { $0.id == tab.id })
}

@Test func browserScreenshotNativeInputRequiresTaskAndProviderImage() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Lima-Visual-Provenance-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = BrowserScreenshotStore(directory: directory)
    let tabID = UUID()
    let capture = try await store.save(
        Data([0xFF, 0xD8, 0xFF, 0xD9]), for: tabID,
        width: 8, height: 8, pointWidth: 8, pointHeight: 8,
        authorityRevision: 0, readRevision: 0, navigationRevision: 0,
        pageIdentity: BrowserPageIdentity(
            documentID: "fixture", routeGeneration: 0, mutationRevision: 0,
            userRevision: 0, snapshotRevision: 1, url: "https://example.com/"
        ),
        viewportWidth: 8, viewportHeight: 8, frameIDs: []
    )
    let firstRun = UUID()
    let otherRun = UUID()
    await store.markProviderImagePrepared(capture.captureID)
    #expect(!(await store.permitsNativeInput(captureID: capture.captureID, runID: firstRun)))
    #expect(await store.bindToTask(capture.captureID, runID: firstRun))
    #expect(!(await store.permitsNativeInput(captureID: capture.captureID, runID: firstRun)))
    #expect(!(await store.bindToTask(capture.captureID, runID: otherRun)))
    await store.markProviderImagePrepared(capture.captureID)
    #expect(await store.permitsNativeInput(captureID: capture.captureID, runID: firstRun))
    #expect(!(await store.permitsNativeInput(captureID: capture.captureID, runID: otherRun)))
    await store.remove(for: tabID)
    #expect(!(await store.permitsNativeInput(captureID: capture.captureID, runID: firstRun)))
    await store.clear()
}
