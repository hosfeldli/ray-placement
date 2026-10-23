import Foundation
import Testing
import WebKit
@testable import RayPlacement

private func visualPixel(_ x: Double, _ y: Double,
                         in capture: BrowserScreenshotResult) -> (Double, Double) {
    (x * Double(capture.pixelWidth) / capture.pointWidth,
     y * Double(capture.pixelHeight) / capture.pointHeight)
}

@MainActor
private func loadVisualFreshnessFixture(_ model: BrowserWorkspaceModel) async throws -> BrowserTab {
    let tab = model.newTab()
    tab.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    tab.webView.loadHTMLString("""
        <!doctype html><html><body>
        <h1>Visual freshness fixture</h1>
        <canvas id='tile' width='160' height='70' aria-label='Visual tile'
          style='position:absolute;left:40px;top:60px;cursor:pointer'></canvas>
        <div id='scroller' style='position:absolute;left:400px;top:60px;
          width:150px;height:100px;overflow:auto'>
          <div style='height:800px'>Tall content</div>
        </div>
        <script>
          document.getElementById('tile').addEventListener('click', () => {
            document.body.dataset.clicked = 'yes';
          });
        </script>
        </body></html>
        """, baseURL: URL(string: "https://example.com/visual-fixture")!)
    for _ in 0..<100 {
        if let page = try? await model.read(tab.id),
           page.headings.contains("Visual freshness fixture") {
            return tab
        }
        try await Task.sleep(for: .milliseconds(25))
    }
    throw BrowserRuntimeError.missingSnapshot
}

@Test @MainActor func browserVisualHitAndReviewedClickRejectNestedScroll() async throws {
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .fullControl
    let tab = try await loadVisualFreshnessFixture(model)
    let capture = try await model.screenshot(tab.id)
    let (x, y) = visualPixel(100, 95, in: capture)
    let hit = try await model.hitTest(
        tab.id, captureID: capture.captureID, pixelX: x, pixelY: y
    )
    #expect(hit.semanticTargetID == nil)
    #expect(await model.visualHitForReview(hit.id) != nil)

    _ = try await tab.webView.evaluateJavaScript(
        "document.getElementById('scroller').scrollTop = 80; true"
    )
    let actualScroll = try #require(
        try await tab.webView.evaluateJavaScript(
            "document.getElementById('scroller').scrollTop"
        ) as? Int
    )
    #expect(actualScroll == 80)
    #expect(await model.visualHitForReview(hit.id) == nil)
    await #expect(throws: BrowserRuntimeError.staleTarget) {
        _ = try await model.pointerClick(tab.id, hitID: hit.id, commitApproved: true)
    }
    await #expect(throws: BrowserRuntimeError.staleTarget) {
        _ = try await model.hitTest(
            tab.id, captureID: capture.captureID, pixelX: x, pixelY: y
        )
    }
    #expect(try await tab.webView.evaluateJavaScript(
        "document.body.dataset.clicked"
    ) as? String == nil)
    try await model.close(tab.id)
}

@Test @MainActor func browserVisualHitRejectsResizedViewport() async throws {
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .fullControl
    let tab = try await loadVisualFreshnessFixture(model)
    let capture = try await model.screenshot(tab.id)
    let (x, y) = visualPixel(100, 95, in: capture)
    tab.webView.frame = CGRect(x: 0, y: 0, width: 600, height: 600)
    await #expect(throws: BrowserRuntimeError.staleTarget) {
        _ = try await model.hitTest(
            tab.id, captureID: capture.captureID, pixelX: x, pixelY: y
        )
    }
    try await model.close(tab.id)
}
