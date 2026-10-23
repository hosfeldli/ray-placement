import AppKit
import Foundation
import Testing
import WebKit
@testable import RayPlacement

private func observationCall(_ mode: String, tabID: UUID) throws -> AIOutputItem {
    let arguments = try JSONSerialization.data(withJSONObject: [
        "tab_id": tabID.uuidString, "mode": mode
    ])
    return AIOutputItem(
        phase: .completed, apiType: "function_call", callID: UUID().uuidString,
        name: "browser_observe", arguments: String(decoding: arguments, as: UTF8.self)
    )
}

private func observationJSON(_ execution: LimaAIToolExecution) throws -> [String: Any] {
    let data = try #require(execution.output.data(using: .utf8))
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test @MainActor func browserObserveKeepsVisualAndSemanticModesIndependent() async throws {
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .readOnly
    let tab = model.newTab()
    tab.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    tab.webView.loadHTMLString(
        "<!doctype html><html><body><h1>Observation fixture</h1><button>Search</button></body></html>",
        baseURL: URL(string: "https://example.com")!
    )
    var ready = false
    for _ in 0..<100 {
        if let page = try? await model.read(tab.id),
           page.controls.contains(where: { $0.label == "Search" }) {
            ready = true
            break
        }
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(ready)

    let visual = await BrowserWorkspaceAITools.execute(
        try observationCall("visual", tabID: tab.id), browser: model
    )
    #expect(!visual.isError)
    let visualCapture = try #require(visual.browserScreenshot)
    let visualJSON = try observationJSON(visual)
    #expect(visualJSON["visual_available"] as? Bool == true)
    #expect(visualJSON["semantic_available"] as? Bool == false)
    #expect(visualJSON["page"] == nil)
    #expect(visualJSON["image_attached"] as? Bool == false)
    #expect(!visual.output.contains(visualCapture.fileURL.path))
    #expect(!visual.output.contains("pageIdentity"))

    let semantic = await BrowserWorkspaceAITools.execute(
        try observationCall("semantic", tabID: tab.id), browser: model
    )
    #expect(!semantic.isError)
    #expect(semantic.browserScreenshot == nil)
    let semanticJSON = try observationJSON(semantic)
    #expect(semanticJSON["semantic_available"] as? Bool == true)
    #expect(semanticJSON["visual_available"] as? Bool == false)
    let semanticPage = try #require(semanticJSON["page"] as? [String: Any])
    let semanticControls = try #require(semanticPage["controls"] as? [[String: Any]])
    #expect(semanticControls.contains {
        $0["label"] as? String == "Search" && $0["target_id"] as? String != nil
    })

    let hybrid = await BrowserWorkspaceAITools.execute(
        try observationCall("hybrid", tabID: tab.id), browser: model
    )
    #expect(!hybrid.isError)
    #expect(hybrid.browserScreenshot != nil)
    let hybridJSON = try observationJSON(hybrid)
    #expect(hybridJSON["semantic_available"] as? Bool == true)
    #expect(hybridJSON["visual_available"] as? Bool == true)
    let hybridPage = try #require(hybridJSON["page"] as? [String: Any])
    #expect(hybridPage["targets_fresh"] as? Bool == true)
    #expect(hybridJSON["screenshot"] is [String: Any])
    try await model.close(tab.id)
}

@Test @MainActor func browserVisualObservationMasksPasswordWithoutSemanticRead() async throws {
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .readOnly
    let tab = model.newTab()
    tab.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    tab.webView.loadHTMLString("""
        <!doctype html><html><body><h1>Visual-only safety fixture</h1>
        <input type='password' value='visual-secret-fixture'
               style='position:absolute;left:100px;top:120px;width:180px;height:35px'>
        </body></html>
        """, baseURL: URL(string: "https://example.com")!)
    var ready = false
    for _ in 0..<100 {
        if let loaded = try? await tab.webView.evaluateJavaScript(
            "document.readyState === 'complete' && Boolean(document.querySelector('input'))"
        ) as? Bool, loaded {
            ready = true
            break
        }
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(ready)
    // Do not call browser.read: the visual safety collector must stand alone.
    let observation = await BrowserWorkspaceAITools.execute(
        try observationCall("visual", tabID: tab.id), browser: model
    )
    #expect(!observation.isError)
    let capture = try #require(observation.browserScreenshot)
    #expect(capture.redactionCount >= 1)
    #expect(!observation.output.contains("visual-secret-fixture"))
    let center = try #require(try await tab.webView.evaluateJavaScript("""
        const rect = document.querySelector('input').getBoundingClientRect();
        [rect.x + rect.width / 2, rect.y + rect.height / 2];
        """) as? [Double])
    let raster = try #require(NSBitmapImageRep(data: Data(contentsOf: capture.fileURL)))
    let x = Int(center[0] * Double(capture.pixelWidth) / capture.pointWidth)
    let y = Int(center[1] * Double(capture.pixelHeight) / capture.pointHeight)
    let color = try #require(raster.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
    #expect(color.redComponent < 0.2 && color.greenComponent < 0.2 && color.blueComponent < 0.2)
    try await model.close(tab.id)
}

@Test @MainActor func browserProtectedCaptureAllowsDynamicTextButExpiresAfterHumanAndNavigation() async throws {
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .readOnly
    let tab = model.newTab()
    tab.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    tab.webView.loadHTMLString("""
        <!doctype html><html><body><h1>Live text fixture</h1><div id='counter'>0</div>
        <script>
          window.tickCount = 0;
          setInterval(() => {
            window.tickCount++;
            document.getElementById('counter').textContent = String(window.tickCount);
          }, 10);
        </script>
        </body></html>
        """, baseURL: URL(string: "https://example.com")!)
    var ready = false
    for _ in 0..<100 {
        if let page = try? await model.read(tab.id),
           page.headings.contains("Live text fixture") {
            ready = true
            break
        }
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(ready)
    let beforeTicks = try #require(
        try await tab.webView.evaluateJavaScript("window.tickCount") as? Int
    )
    var observedLiveUpdate = false
    for _ in 0..<100 {
        try await Task.sleep(for: .milliseconds(20))
        if let ticks = try await tab.webView.evaluateJavaScript("window.tickCount") as? Int,
           ticks > beforeTicks {
            observedLiveUpdate = true
            break
        }
    }
    #expect(observedLiveUpdate)
    let capture = try await model.screenshot(tab.id)
    #expect(model.isScreenshotCurrent(capture))
    model.markPageChangedByUser(tab.id)
    #expect(!model.isScreenshotCurrent(capture))

    let second = try await model.screenshot(tab.id)
    #expect(model.isScreenshotCurrent(second))
    let revision = tab.navigationRevision
    tab.webView.loadHTMLString(
        "<!doctype html><html><body><h1>New document</h1></body></html>",
        baseURL: URL(string: "https://example.com")!
    )
    for _ in 0..<100 where tab.navigationRevision == revision {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(tab.navigationRevision > revision)
    #expect(!model.isScreenshotCurrent(second))
    try await model.close(tab.id)
}

@Test @MainActor func browserProtectedCaptureMasksEmbeddedFramePixels() async throws {
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .readOnly
    let tab = model.newTab()
    tab.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    tab.webView.loadHTMLString("""
        <!doctype html><html><body><h1>Frame mask fixture</h1>
        <iframe title='Private frame' srcdoc='<div>Protected frame text</div>'
                style='position:absolute;left:50px;top:100px;width:260px;height:140px'></iframe>
        </body></html>
        """, baseURL: URL(string: "https://example.com")!)
    var frameReady = false
    for _ in 0..<100 {
        if let ready = try? await tab.webView.evaluateJavaScript(
            "document.querySelector('iframe')?.contentDocument?.readyState === 'complete'"
        ) as? Bool, ready {
            frameReady = true
            break
        }
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(frameReady)
    let capture = try await model.screenshot(tab.id)
    #expect(capture.redactionCount >= 1)
    let center = try #require(try await tab.webView.evaluateJavaScript("""
        const rect = document.querySelector('iframe').getBoundingClientRect();
        [rect.x + rect.width / 2, rect.y + rect.height / 2];
        """) as? [Double])
    let raster = try #require(NSBitmapImageRep(data: Data(contentsOf: capture.fileURL)))
    let x = Int(center[0] * Double(capture.pixelWidth) / capture.pointWidth)
    let y = Int(center[1] * Double(capture.pixelHeight) / capture.pointHeight)
    let color = try #require(raster.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
    #expect(color.redComponent < 0.2 && color.greenComponent < 0.2 && color.blueComponent < 0.2)
    _ = try await tab.webView.evaluateJavaScript("""
        const field = document.createElement('input');
        field.type = 'password';
        field.value = 'child-secret-fixture';
        document.querySelector('iframe').contentDocument.body.appendChild(field);
        true;
        """)
    do {
        _ = try await model.screenshot(tab.id)
        Issue.record("A filled protected field inside an iframe must withhold the screenshot.")
    } catch let error as BrowserCaptureFailure {
        #expect(error == .redactionUnresolved)
    }
    try await model.close(tab.id)
}

@Test func browserCaptureSafetyAllowsTextMutationButRejectsIdentityFrameMaskAndViewportChanges() throws {
    let beforeIdentity = BrowserPageIdentity(
        documentID: "document", routeGeneration: 1, mutationRevision: 4,
        userRevision: 2, snapshotRevision: 5, url: "https://example.com/page"
    )
    let textChanged = BrowserPageIdentity(
        documentID: "document", routeGeneration: 1, mutationRevision: 9,
        userRevision: 2, snapshotRevision: 6, url: "https://example.com/page"
    )
    let routeChanged = BrowserPageIdentity(
        documentID: "document", routeGeneration: 2, mutationRevision: 9,
        userRevision: 2, snapshotRevision: 6, url: "https://example.com/next"
    )
    let mask = BrowserScreenshotMask(x: 10, y: 20, width: 100, height: 30)
    let shifted = BrowserScreenshotMask(x: 20, y: 20, width: 100, height: 30)
    let before = BrowserScreenshotRedaction(
        identity: beforeIdentity, complete: true, frameCount: 1, rects: [mask]
    )
    func inspection(_ identity: BrowserPageIdentity, frameCount: Int = 1,
                    masks: [BrowserScreenshotMask] = [mask]) -> BrowserScreenshotRedaction {
        BrowserScreenshotRedaction(
            identity: identity, complete: true, frameCount: frameCount, rects: masks
        )
    }
    func failure(_ after: BrowserScreenshotRedaction,
                 navigationUnchanged: Bool = true,
                 viewportUnchanged: Bool = true) -> BrowserCaptureFailure? {
        do {
            try before.verifyCapture(after: after,
                                     navigationUnchanged: navigationUnchanged,
                                     viewportUnchanged: viewportUnchanged)
            return nil
        } catch let error as BrowserCaptureFailure {
            return error
        } catch {
            return nil
        }
    }
    try before.verifyCapture(after: inspection(textChanged),
                             navigationUnchanged: true, viewportUnchanged: true)
    #expect(failure(inspection(routeChanged)) == .navigationChanged)
    #expect(failure(inspection(textChanged), navigationUnchanged: false) == .navigationChanged)
    #expect(failure(inspection(textChanged, frameCount: 2)) == .frameUnaccounted)
    #expect(failure(inspection(textChanged, masks: [shifted])) == .redactionUnresolved)
    #expect(failure(inspection(textChanged), viewportUnchanged: false) == .invalidViewport)
}

@Test func browserProviderOutputRetainsSemanticContextAndStripsPrivateCaptureFields() throws {
    let raw = """
        {"page":{"title":"Example","text_excerpt":"Search result"},
         "visual_available":true,
         "screenshot":{"capture_id":"fixture","fileURL":"/private/secret.jpg",
                       "authorityRevision":12,"navigationRevision":3}}
        """
    let output = AIEngineToolOutput(callID: "capture", output: raw)
    let attached = output.providerOutput(imageAttached: true)
    let attachedData = try #require(attached.data(using: .utf8))
    let attachedJSON = try #require(
        JSONSerialization.jsonObject(with: attachedData) as? [String: Any]
    )
    #expect(attachedJSON["image_attached"] as? Bool == true)
    #expect((attachedJSON["page"] as? [String: Any])?["title"] as? String == "Example")
    let screenshot = try #require(attachedJSON["screenshot"] as? [String: Any])
    #expect(screenshot["capture_id"] as? String == "fixture")
    #expect(screenshot["fileURL"] == nil)
    #expect(screenshot["authorityRevision"] == nil)
    #expect(screenshot["navigationRevision"] == nil)

    let expired = output.providerOutput(imageAttached: false, imageFailure: .expired)
    let expiredData = try #require(expired.data(using: .utf8))
    let expiredJSON = try #require(
        JSONSerialization.jsonObject(with: expiredData) as? [String: Any]
    )
    #expect(expiredJSON["visual_available"] as? Bool == false)
    #expect((expiredJSON["page"] as? [String: Any])?["text_excerpt"] as? String == "Search result")
    #expect((expiredJSON["image_error"] as? [String: Any])?["code"] as? String == "capture_expired")
}

@Test @MainActor func browserObserveWithholdsIncompleteSemanticContent() throws {
    let identity = BrowserPageIdentity(
        documentID: "partial", routeGeneration: 0, mutationRevision: 1,
        userRevision: 0, snapshotRevision: 1,
        url: "https://example.com/private/secret-echo-fixture"
    )
    let target = BrowserTarget(
        id: "unsafe-target", role: "button", label: "secret-echo-fixture",
        destination: nil, relationship: nil, x: 10, y: 10,
        width: 100, height: 30, frameID: "main", sensitive: false
    )
    let diagnostics = BrowserDiagnostics(
        textLength: 19, linkCount: 0, controlCount: 1, headingCount: 0,
        semanticRowCount: 0, shadowRootCount: 0, frameCount: 2,
        quietMS: 0, truncated: true
    )
    let page = BrowserPageSnapshot(
        identity: identity, readiness: .unstable,
        title: "secret-echo-fixture", text: "secret-echo-fixture",
        links: [], controls: [target], headings: [], rows: [],
        diagnostics: diagnostics
    )
    let execution = BrowserWorkspaceAITools.observationExecution(
        tabID: UUID(), mode: "semantic", focus: "", page: page,
        capture: nil, targetsFresh: true,
        semanticError: nil, visualError: nil
    )
    let payload = try observationJSON(execution)
    #expect(execution.isError)
    #expect(!execution.output.contains("secret-echo-fixture"))
    #expect(payload["semantic_available"] as? Bool == false)
    #expect(payload["page"] == nil)
    let safe = try #require(payload["semantic_diagnostics"] as? [String: Any])
    #expect(safe["semantic_truncated"] as? Bool == true)
    #expect((safe["partial_frames"] as? Int ?? 0) > 0)
    let error = try #require(payload["semantic_error"] as? [String: Any])
    #expect(error["code"] as? String == "page_unstable")
}
