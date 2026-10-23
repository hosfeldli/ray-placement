import Foundation
import Testing
import WebKit
@testable import RayPlacement

private func browserVisualCall(_ name: String, _ arguments: [String: Any],
                               callID: String = UUID().uuidString) throws -> AIOutputItem {
    let data = try JSONSerialization.data(withJSONObject: arguments)
    return AIOutputItem(
        phase: .completed, apiType: "function_call", callID: callID,
        name: name, arguments: String(decoding: data, as: UTF8.self)
    )
}

private func browserVisualPoint(_ x: Double, _ y: Double,
                                in capture: BrowserScreenshotResult) -> (Double, Double) {
    (x * Double(capture.pixelWidth) / capture.pointWidth,
     y * Double(capture.pixelHeight) / capture.pointHeight)
}

@Test func browserCommitPolicyDistinguishesSelectionSearchAndFinalActions() throws {
    let identity = BrowserPageIdentity(
        documentID: "fixture", routeGeneration: 0, mutationRevision: 0,
        userRevision: 0, snapshotRevision: 1, url: "https://example.com/reservations"
    )
    let diagnostics = BrowserDiagnostics(
        textLength: 38, linkCount: 0, controlCount: 0, headingCount: 0,
        semanticRowCount: 0, shadowRootCount: 0, frameCount: 1,
        quietMS: 600, truncated: false
    )
    let page = BrowserPageSnapshot(
        identity: identity, readiness: .readyWithContent, title: "Reservation",
        text: "A $50 deposit is required.\nCancellation policy applies.",
        links: [], controls: [], headings: [], rows: [], diagnostics: diagnostics
    )
    func target(_ label: String, role: String = "button") -> BrowserTarget {
        var value = BrowserTarget(
            id: label, role: role, label: label, destination: nil,
            relationship: nil, x: 10, y: 10, width: 100, height: 30,
            frameID: "main", sensitive: false
        )
        value.formLabel = "Dinner reservation"
        return value
    }
    let tabID = UUID()
    #expect(BrowserCommitAuthorization.review(
        tabID: tabID, target: target("Friday, October 23", role: "gridcell"),
        action: .click, page: page
    ) == nil)
    #expect(BrowserCommitAuthorization.review(
        tabID: tabID, target: target("7:00 PM", role: "option"),
        action: .click, page: page
    ) == nil)
    #expect(BrowserCommitAuthorization.review(
        tabID: tabID, target: target("Find a table"),
        action: .submit, page: page
    ) == nil)
    let ambiguous = BrowserCommitAuthorization.review(
        tabID: tabID, target: target("Continue"), action: .click, page: page
    )
    #expect(ambiguous != nil)
    let final = try #require(BrowserCommitAuthorization.review(
        tabID: tabID, target: target("Confirm booking"), action: .click, page: page
    ))
    #expect(final.visibleTerms.contains { $0.contains("$50 deposit") })
    #expect(final.userSummary.contains("real transaction"))
    for label in ["Buy now", "Make payment", "Donate $10", "Transfer funds"] {
        #expect(BrowserCommitAuthorization.review(
            tabID: tabID, target: target(label), action: .click, page: page
        ) != nil)
    }
}

@Test @MainActor func browserCommitApprovalIsExactFreshAndNotConfirmation() async throws {
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .fullControl
    let tab = model.newTab()
    tab.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    tab.webView.loadHTMLString("""
        <!doctype html><html><body>
        <h1>Final-action fixture</h1>
        <p id="terms">A $50 deposit is required.</p>
        <form aria-label="Dinner reservation">
          <button type="submit">Confirm booking</button>
        </form>
        <script>
          document.querySelector('form').addEventListener('submit', event => {
            event.preventDefault();
            document.body.dataset.submitted = '1';
          });
        </script>
        </body></html>
        """, baseURL: URL(string: "https://example.com")!)
    var page: BrowserPageSnapshot?
    for _ in 0..<100 {
        if let read = try? await model.read(tab.id),
           read.controls.contains(where: { $0.label == "Confirm booking" }) {
            page = read
            break
        }
        try await Task.sleep(for: .milliseconds(25))
    }
    let first = try #require(page)
    let target = try #require(first.controls.first { $0.label == "Confirm booking" })
    let call = try browserVisualCall("browser_submit", [
        "tab_id": tab.id.uuidString, "target": target.id
    ])
    let review = try #require(await BrowserWorkspaceAITools.commitReview(for: call, browser: model))
    #expect(review.visibleTerms.contains { $0.contains("$50 deposit") })
    let denied = await BrowserWorkspaceAITools.execute(call, browser: model)
    #expect(denied.isError)
    #expect(try await tab.webView.evaluateJavaScript("document.body.dataset.submitted") as? String == nil)

    _ = try await tab.webView.evaluateJavaScript(
        "document.getElementById('terms').textContent = 'A $75 deposit is required.'"
    )
    // Do not reread: the JS mutation revision must still invalidate the
    // reviewed final action at dispatch time.
    let stale = await BrowserWorkspaceAITools.execute(call, browser: model, approvalGranted: true)
    #expect(stale.isError)
    #expect(try await tab.webView.evaluateJavaScript("document.body.dataset.submitted") as? String == nil)

    let fresh = try await model.read(tab.id)
    let freshTarget = try #require(fresh.controls.first { $0.label == "Confirm booking" })
    let freshCall = try browserVisualCall("browser_submit", [
        "tab_id": tab.id.uuidString, "target": freshTarget.id
    ])
    let freshReview = try #require(await BrowserWorkspaceAITools.commitReview(
        for: freshCall, browser: model
    ))
    #expect(freshReview.visibleTerms.contains { $0.contains("$75 deposit") })
    // Main and delegated approval routing can inspect the same exact call twice:
    // once to decide a prompt is required, then again to render its summary.
    let presentedReview = await BrowserWorkspaceAITools.commitReview(
        for: freshCall, browser: model
    )
    #expect(presentedReview == freshReview)
    let approved = await BrowserWorkspaceAITools.execute(
        freshCall, browser: model, approvalGranted: true
    )
    #expect(!approved.isError)
    let approvedData = try #require(approved.output.data(using: .utf8))
    let outcome = try JSONDecoder().decode(BrowserActionOutcome.self, from: approvedData)
    #expect(outcome.performed)
    #expect(!outcome.postActionVerified)
    #expect(try await tab.webView.evaluateJavaScript("document.body.dataset.submitted") as? String == "1")
    try await model.close(tab.id)
}

@Test @MainActor func browserCommitReviewBindsExactCallArgumentsAndCannotBeReplayed() async throws {
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .fullControl
    let tab = model.newTab()
    tab.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    tab.webView.loadHTMLString("""
        <!doctype html><html><body>
        <h1>Exact-call fixture</h1>
        <form aria-label="Dinner reservation">
          <button type="button" id="first">Confirm booking</button>
          <button type="button" id="second">Confirm appointment</button>
        </form>
        <script>
          document.getElementById('first').addEventListener('click', () => document.body.dataset.clicked = 'first');
          document.getElementById('second').addEventListener('click', () => document.body.dataset.clicked = 'second');
        </script>
        </body></html>
        """, baseURL: URL(string: "https://example.com")!)
    var page: BrowserPageSnapshot?
    for _ in 0..<100 {
        if let read = try? await model.read(tab.id),
           read.controls.contains(where: { $0.label == "Confirm appointment" }) {
            page = read
            break
        }
        try await Task.sleep(for: .milliseconds(25))
    }
    let ready = try #require(page)
    let first = try #require(ready.controls.first { $0.label == "Confirm booking" })
    let second = try #require(ready.controls.first { $0.label == "Confirm appointment" })
    let callID = UUID().uuidString
    let reviewed = try browserVisualCall("browser_click", [
        "tab_id": tab.id.uuidString, "target": first.id
    ], callID: callID)
    let forged = try browserVisualCall("browser_click", [
        "tab_id": tab.id.uuidString, "target": second.id
    ], callID: UUID().uuidString)
    let noReview = await BrowserWorkspaceAITools.execute(
        forged, browser: model, approvalGranted: true
    )
    #expect(noReview.isError)
    #expect(try await tab.webView.evaluateJavaScript("document.body.dataset.clicked") as? String == nil)

    _ = try #require(await BrowserWorkspaceAITools.commitReview(for: reviewed, browser: model))
    let changedArguments = try browserVisualCall("browser_click", [
        "tab_id": tab.id.uuidString, "target": second.id
    ], callID: callID)
    let mismatched = await BrowserWorkspaceAITools.execute(
        changedArguments, browser: model, approvalGranted: true
    )
    #expect(mismatched.isError)
    #expect(try await tab.webView.evaluateJavaScript("document.body.dataset.clicked") as? String == nil)
    let replay = await BrowserWorkspaceAITools.execute(
        reviewed, browser: model, approvalGranted: true
    )
    #expect(replay.isError)
    #expect(try await tab.webView.evaluateJavaScript("document.body.dataset.clicked") as? String == nil)
    try await model.close(tab.id)
}

@Test @MainActor func browserFinalLinkNeedsReviewedApproval() async throws {
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .fullControl
    let tab = model.newTab()
    tab.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    tab.webView.loadHTMLString("""
        <!doctype html><html><body>
        <h1>Final link fixture</h1>
        <a href="#confirmed">Confirm reservation</a>
        </body></html>
        """, baseURL: URL(string: "https://example.com")!)
    var page: BrowserPageSnapshot?
    for _ in 0..<100 {
        if let read = try? await model.read(tab.id),
           read.links.contains(where: { $0.label == "Confirm reservation" }) {
            page = read
            break
        }
        try await Task.sleep(for: .milliseconds(25))
    }
    let ready = try #require(page)
    let link = try #require(ready.links.first { $0.label == "Confirm reservation" })
    let activate = try browserVisualCall("browser_activate", [
        "tab_id": tab.id.uuidString, "target": link.id
    ])
    let open = try browserVisualCall("browser_open_link", [
        "tab_id": tab.id.uuidString, "target": link.id,
        "disposition": "current_tab"
    ])
    #expect(await BrowserWorkspaceAITools.commitReview(for: activate, browser: model) != nil)
    #expect(await BrowserWorkspaceAITools.commitReview(for: open, browser: model) != nil)
    #expect((await BrowserWorkspaceAITools.execute(activate, browser: model)).isError)
    #expect((await BrowserWorkspaceAITools.execute(open, browser: model)).isError)
    #expect(try await tab.webView.evaluateJavaScript("location.hash") as? String == "")
    try await model.close(tab.id)
}

@Test @MainActor func browserVisualHitRequiresCaptureAndExactClickReview() async throws {
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .fullControl
    let tab = model.newTab()
    tab.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    tab.webView.loadHTMLString("""
        <!doctype html><html><body>
        <h1>Visual fallback fixture</h1>
        <canvas id="time" width="180" height="80" aria-label="7:00 PM visual time"
          style="position:absolute;left:50px;top:60px;cursor:pointer"></canvas>
        <p id="status">Waiting</p>
        <script>
          const canvas = document.getElementById('time');
          canvas.getContext('2d').fillText('7:00 PM', 20, 30);
          canvas.addEventListener('click', () => {
            document.getElementById('status').textContent = 'Selected 7:00 PM';
          });
        </script>
        </body></html>
        """, baseURL: URL(string: "https://example.com")!)
    var ready = false
    for _ in 0..<100 {
        if let page = try? await model.read(tab.id),
           page.headings.contains("Visual fallback fixture") {
            ready = true
            break
        }
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(ready)
    let screenshot = await BrowserWorkspaceAITools.execute(
        try browserVisualCall("browser_screenshot", ["tab_id": tab.id.uuidString]),
        browser: model
    )
    #expect(!screenshot.isError)
    let capture = try #require(screenshot.browserScreenshot)
    #expect(screenshot.output.contains(capture.captureID.uuidString))
    #expect(!screenshot.output.contains("fileURL"))
    #expect(!screenshot.output.contains("authorityRevision"))
    #expect(!screenshot.output.contains("pageIdentity"))
    let (x, y) = browserVisualPoint(110, 90, in: capture)
    let hitResult = await BrowserWorkspaceAITools.execute(
        try browserVisualCall("browser_hit_test", [
            "tab_id": tab.id.uuidString, "capture_id": capture.captureID.uuidString,
            "x": x, "y": y
        ]), browser: model
    )
    #expect(!hitResult.isError)
    let hitData = try #require(hitResult.output.data(using: .utf8))
    let hit = try JSONDecoder().decode(BrowserVisualHit.self, from: hitData)
    #expect(hit.tabID == tab.id)
    #expect(hit.label == "7:00 PM visual time")
    #expect(hit.semanticTargetID == nil)
    #expect(model.automation?.tabID == tab.id)
    #expect(model.automation?.role == "visualReview")
    #expect(model.aiFocus?.targetID == hit.id.uuidString)

    let click = try browserVisualCall("browser_pointer_click", [
        "tab_id": tab.id.uuidString, "hit_id": hit.id.uuidString
    ])
    let review = try #require(await BrowserWorkspaceAITools.commitReview(for: click, browser: model))
    #expect(review.isVisual)
    let denied = await BrowserWorkspaceAITools.execute(click, browser: model)
    #expect(denied.isError)
    #expect(try await tab.webView.evaluateJavaScript(
        "document.getElementById('status').textContent"
    ) as? String == "Waiting")
    let approved = await BrowserWorkspaceAITools.execute(
        click, browser: model, approvalGranted: true
    )
    #expect(!approved.isError)
    let approvedData = try #require(approved.output.data(using: .utf8))
    let outcome = try JSONDecoder().decode(BrowserActionOutcome.self, from: approvedData)
    #expect(outcome.performed)
    #expect(outcome.postActionVerified)
    #expect(try await tab.webView.evaluateJavaScript(
        "document.getElementById('status').textContent"
    ) as? String == "Selected 7:00 PM")
    try await model.close(tab.id)
}


@Test @MainActor func browserVisualHitCannotClickThroughModalOverlay() async throws {
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .fullControl
    let tab = model.newTab()
    tab.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    tab.webView.loadHTMLString("""
        <!doctype html><html><body>
        <h1>Occlusion fixture</h1>
        <canvas id="tile" width="180" height="80" aria-label="Underlying visual tile"
          style="position:absolute;left:50px;top:60px;cursor:pointer"></canvas>
        <div role="dialog" aria-modal="true" aria-label="Review dialog"
          style="position:absolute;left:50px;top:60px;width:180px;height:80px;background:white;z-index:5">
          <button type="button" style="width:180px;height:80px">Close dialog</button>
        </div>
        </body></html>
        """, baseURL: URL(string: "https://example.com")!)
    var ready = false
    for _ in 0..<100 {
        if let page = try? await model.read(tab.id),
           page.headings.contains("Occlusion fixture"),
           page.activeDialog != nil {
            ready = true
            break
        }
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(ready)
    let capture = try await model.screenshot(tab.id)
    let (x, y) = browserVisualPoint(100, 95, in: capture)
    let hit = try await model.hitTest(tab.id, captureID: capture.captureID,
                                      pixelX: x, pixelY: y)
    #expect(hit.label == "Close dialog")
    #expect(hit.semanticTargetID != nil)
    #expect(await model.visualHitForReview(hit.id) == nil)
    await #expect(throws: BrowserRuntimeError.self) {
        _ = try await model.pointerClick(tab.id, hitID: hit.id, commitApproved: true)
    }
    _ = try await tab.webView.evaluateJavaScript(
        "document.querySelector('[role=dialog]').style.pointerEvents = 'none'"
    )
    _ = try await model.read(tab.id)
    let passThroughCapture = try await model.screenshot(tab.id)
    let (passThroughX, passThroughY) = browserVisualPoint(100, 95, in: passThroughCapture)
    await #expect(throws: BrowserRuntimeError.targetOccluded) {
        _ = try await model.hitTest(tab.id, captureID: passThroughCapture.captureID,
                                    pixelX: passThroughX, pixelY: passThroughY)
    }
    try await model.close(tab.id)
}

@Test @MainActor func browserVisualShadowHitDispatchesToChildAndPrefersSemanticHost() async throws {
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .fullControl
    let tab = model.newTab()
    tab.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    tab.webView.loadHTMLString("""
        <!doctype html><html><body>
        <h1>Shadow visual fixture</h1>
        <div id="visual" style="position:absolute;left:50px;top:60px"></div>
        <div id="semantic" role="button" tabindex="0" aria-label="Shadow host action"
          style="position:absolute;left:300px;top:60px"></div>
        <p id="status">Waiting</p>
        <script>
          const visual = document.getElementById('visual').attachShadow({mode:'open'});
          const tile = document.createElement('div');
          tile.setAttribute('data-action', 'select');
          tile.setAttribute('aria-label', 'Shadow visual tile');
          tile.style.cssText = 'width:180px;height:80px;cursor:pointer;background:#eee';
          const child = document.createElement('span');
          child.style.cssText = 'display:block;width:180px;height:80px;cursor:auto';
          child.textContent = '7:15 PM';
          child.addEventListener('click', () => {
            document.getElementById('status').textContent = 'Selected 7:15 PM';
          });
          tile.append(child);
          visual.append(tile);
          const semantic = document.getElementById('semantic').attachShadow({mode:'open'});
          const inner = document.createElement('span');
          inner.style.cssText = 'display:block;width:160px;height:80px;background:#ddd';
          inner.textContent = 'Semantic child';
          semantic.append(inner);
        </script>
        </body></html>
        """, baseURL: URL(string: "https://example.com")!)
    var ready = false
    for _ in 0..<100 {
        if let page = try? await model.read(tab.id),
           page.headings.contains("Shadow visual fixture"),
           page.controls.contains(where: { $0.label == "Shadow host action" }) {
            ready = true
            break
        }
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(ready)
    let capture = try await model.screenshot(tab.id)
    let (x, y) = browserVisualPoint(110, 100, in: capture)
    let hit = try await model.hitTest(tab.id, captureID: capture.captureID,
                                      pixelX: x, pixelY: y)
    #expect(hit.label == "Shadow visual tile")
    #expect(hit.semanticTargetID == nil)
    let click = try browserVisualCall("browser_pointer_click", [
        "tab_id": tab.id.uuidString, "hit_id": hit.id.uuidString
    ])
    #expect(await BrowserWorkspaceAITools.commitReview(for: click, browser: model) != nil)
    let action = await BrowserWorkspaceAITools.execute(
        click, browser: model, approvalGranted: true
    )
    #expect(!action.isError)
    #expect(try await tab.webView.evaluateJavaScript(
        "document.getElementById('status').textContent"
    ) as? String == "Selected 7:15 PM")

    let next = try await model.screenshot(tab.id)
    let (semanticX, semanticY) = browserVisualPoint(340, 100, in: next)
    let semanticHit = try await model.hitTest(
        tab.id, captureID: next.captureID, pixelX: semanticX, pixelY: semanticY
    )
    #expect(semanticHit.semanticTargetID != nil)
    #expect(await model.visualHitForReview(semanticHit.id) == nil)
    try await model.close(tab.id)
}

@Test @MainActor func browserVisualCaptureExpiresBeforePointerUse() async throws {
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .fullControl
    let tab = model.newTab()
    tab.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    tab.webView.loadHTMLString("<html><body><h1>Capture age fixture</h1></body></html>",
                               baseURL: URL(string: "https://example.com")!)
    for _ in 0..<100 {
        if let page = try? await model.read(tab.id),
           page.headings.contains("Capture age fixture") { break }
        try await Task.sleep(for: .milliseconds(25))
    }
    let fresh = try await model.screenshot(tab.id)
    #expect(model.isScreenshotCurrent(fresh))
    let expired = BrowserScreenshotResult(
        captureID: fresh.captureID, capturedAt: Date().addingTimeInterval(-121),
        tabID: fresh.tabID, fileURL: fresh.fileURL, mediaType: fresh.mediaType,
        pixelWidth: fresh.pixelWidth, pixelHeight: fresh.pixelHeight,
        pointWidth: fresh.pointWidth, pointHeight: fresh.pointHeight,
        byteCount: fresh.byteCount, authorityRevision: fresh.authorityRevision,
        readRevision: fresh.readRevision,
        navigationRevision: fresh.navigationRevision
    )
    #expect(!model.isScreenshotCurrent(expired))
    try await model.close(tab.id)
}

@Test @MainActor func browserVisualHitRejectsStaleCrossTabSemanticAndSensitiveTargets() async throws {
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .fullControl
    let tab = model.newTab()
    tab.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    tab.webView.loadHTMLString("""
        <!doctype html><html><body>
        <h1>Visual safety fixture</h1>
        <canvas id="tile" width="160" height="70" aria-label="Visual tile"
          style="position:absolute;left:40px;top:60px;cursor:pointer"></canvas>
        <button type="button" id="semantic"
          style="position:absolute;left:300px;top:60px;width:150px;height:70px">Semantic action</button>
        </body></html>
        """, baseURL: URL(string: "https://example.com")!)
    for _ in 0..<100 {
        if let page = try? await model.read(tab.id),
           page.headings.contains("Visual safety fixture") { break }
        try await Task.sleep(for: .milliseconds(25))
    }
    let capture = try await model.screenshot(tab.id)
    let (x, y) = browserVisualPoint(100, 95, in: capture)
    let hit = try await model.hitTest(tab.id, captureID: capture.captureID,
                                      pixelX: x, pixelY: y)
    let wrongTab = model.newTab()
    await #expect(throws: BrowserRuntimeError.self) {
        _ = try await model.pointerClick(wrongTab.id, hitID: hit.id, commitApproved: true)
    }
    _ = try await model.read(tab.id)
    #expect(model.automation?.role != "visualReview")
    await #expect(throws: BrowserRuntimeError.self) {
        _ = try await model.pointerClick(tab.id, hitID: hit.id, commitApproved: true)
    }
    try await model.close(wrongTab.id)

    let nextCapture = try await model.screenshot(tab.id)
    let (buttonX, buttonY) = browserVisualPoint(340, 95, in: nextCapture)
    let semanticHit = try await model.hitTest(
        tab.id, captureID: nextCapture.captureID, pixelX: buttonX, pixelY: buttonY
    )
    #expect(semanticHit.semanticTargetID != nil)
    #expect(await model.visualHitForReview(semanticHit.id) == nil)
    await #expect(throws: BrowserRuntimeError.self) {
        _ = try await model.pointerClick(tab.id, hitID: semanticHit.id,
                                         commitApproved: true)
    }

    _ = try await tab.webView.evaluateJavaScript(
        "document.getElementById('tile').setAttribute('aria-label', 'Credit card number')"
    )
    // Legacy hit testing uses semantic targets; a visual screenshot no longer
    // refreshes the semantic snapshot after a page mutation.
    _ = try await model.read(tab.id)
    let protectedCapture = try await model.screenshot(tab.id)
    #expect(protectedCapture.redactionCount >= 1)
    let raster = try #require(NSBitmapImageRep(data: Data(contentsOf: protectedCapture.fileURL)))
    let (maskedX, maskedY) = browserVisualPoint(100, 95, in: protectedCapture)
    let color = try #require(raster.colorAt(x: Int(maskedX), y: Int(maskedY))?.usingColorSpace(.deviceRGB))
    #expect(color.redComponent < 0.2 && color.greenComponent < 0.2 && color.blueComponent < 0.2)
    await #expect(throws: BrowserRuntimeError.screenshotProtected) {
        _ = try await model.hitTest(tab.id, captureID: protectedCapture.captureID,
                                    pixelX: maskedX, pixelY: maskedY)
    }
    try await model.close(tab.id)
}
