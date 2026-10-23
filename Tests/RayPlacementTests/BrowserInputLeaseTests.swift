import Foundation
import Testing
import WebKit
@testable import RayPlacement

private func browserInputFixture() -> (
    capture: BrowserScreenshotResult,
    anchor: BrowserVisualInputAnchor,
    taskID: UUID,
    identity: BrowserPageIdentity
) {
    let identity = BrowserPageIdentity(
        documentID: "document", routeGeneration: 2, mutationRevision: 3,
        userRevision: 4, snapshotRevision: 5, url: "https://example.com/fixture"
    )
    let anchor = BrowserVisualInputAnchor(
        windowNumber: 24, screenNumber: 1, backingScale: 2,
        windowX: 100, windowY: 200, windowWidth: 1100, windowHeight: 800,
        viewX: 10, viewY: 20, viewWidth: 800, viewHeight: 600,
        boundsX: 0, boundsY: 0, boundsWidth: 800, boundsHeight: 600,
        isFlipped: false
    )
    var capture = BrowserScreenshotResult(
        captureID: UUID(), capturedAt: Date(), tabID: UUID(),
        fileURL: URL(fileURLWithPath: "/tmp/unused-browser-lease-fixture.jpg"),
        mediaType: "image/jpeg", pixelWidth: 1000, pixelHeight: 500,
        pointWidth: 500, pointHeight: 250, byteCount: 3,
        authorityRevision: 7, readRevision: 8, navigationRevision: 9,
        pageIdentity: identity
    )
    capture.inputAnchor = anchor
    capture.cropOriginX = 40
    capture.cropOriginY = 20
    capture.viewportWidth = 800
    capture.viewportHeight = 600
    return (capture, anchor, UUID(), identity)
}

private func browserInputState(
    _ capture: BrowserScreenshotResult, taskID: UUID,
    anchor: BrowserVisualInputAnchor?, identity: BrowserPageIdentity,
    selectedTabID: UUID? = nil,
    authorityRevision: UInt64? = nil,
    protectedRects: [BrowserScreenshotMask]? = nil,
    scrollX: Double? = nil,
    scrollY: Double? = nil
) -> BrowserVisualInputState {
    BrowserVisualInputState(
        taskID: taskID,
        selectedTabID: selectedTabID ?? capture.tabID,
        authorityRevision: authorityRevision ?? capture.authorityRevision,
        readRevision: capture.readRevision,
        navigationRevision: capture.navigationRevision,
        anchor: anchor, pageIdentity: identity,
        protectedRects: protectedRects ?? capture.protectedRects,
        hasFilledSecureField: false,
        scrollX: scrollX ?? capture.scrollX,
        scrollY: scrollY ?? capture.scrollY,
        scrollFingerprint: capture.scrollFingerprint,
        frameIDs: capture.frameIDs
    )
}

@Test func browserInputLeaseMapsRetinaCropAndViewOrientation() throws {
    let fixture = browserInputFixture()
    let lease = try BrowserInputLease(taskID: fixture.taskID, capture: fixture.capture)
    let state = browserInputState(
        fixture.capture, taskID: fixture.taskID,
        anchor: fixture.anchor, identity: fixture.identity
    )
    let point = try lease.viewPoint(
        pixelX: 200, pixelY: 100, capture: fixture.capture, state: state
    )
    #expect(point == BrowserVisualInputPoint(x: 140, y: 530))

    var flippedCapture = fixture.capture
    let flippedAnchor = BrowserVisualInputAnchor(
        windowNumber: 24, screenNumber: 1, backingScale: 2,
        windowX: 100, windowY: 200, windowWidth: 1100, windowHeight: 800,
        viewX: 10, viewY: 20, viewWidth: 800, viewHeight: 600,
        boundsX: 0, boundsY: 0, boundsWidth: 800, boundsHeight: 600,
        isFlipped: true
    )
    flippedCapture.inputAnchor = flippedAnchor
    let flippedLease = try BrowserInputLease(taskID: fixture.taskID, capture: flippedCapture)
    let flippedState = browserInputState(
        flippedCapture, taskID: fixture.taskID,
        anchor: flippedAnchor, identity: fixture.identity
    )
    #expect(try flippedLease.viewPoint(
        pixelX: 200, pixelY: 100, capture: flippedCapture, state: flippedState
    ) == BrowserVisualInputPoint(x: 140, y: 70))
}

@Test func browserInputLeaseRejectsMaskedAndOutOfBoundsPixels() throws {
    let fixture = browserInputFixture()
    var capture = fixture.capture
    capture.protectedRects = [BrowserScreenshotMask(x: 130, y: 60, width: 20, height: 20)]
    capture.redactionCount = 1
    let lease = try BrowserInputLease(taskID: fixture.taskID, capture: capture)
    let state = browserInputState(
        capture, taskID: fixture.taskID,
        anchor: fixture.anchor, identity: fixture.identity
    )
    #expect(throws: BrowserRuntimeError.self) {
        _ = try lease.viewPoint(pixelX: 200, pixelY: 100, capture: capture, state: state)
    }
    #expect(throws: BrowserRuntimeError.self) {
        _ = try lease.viewPoint(pixelX: 1_000, pixelY: 100, capture: capture, state: state)
    }
    #expect(throws: BrowserRuntimeError.self) {
        _ = try lease.viewPoint(pixelX: .nan, pixelY: 100, capture: capture, state: state)
    }
    let changedMasks = browserInputState(
        capture, taskID: fixture.taskID, anchor: fixture.anchor,
        identity: fixture.identity, protectedRects: []
    )
    #expect(throws: BrowserRuntimeError.self) {
        _ = try lease.viewPoint(pixelX: 10, pixelY: 10, capture: capture, state: changedMasks)
    }
}

@Test func browserInputLeaseRejectsTaskTabWindowAndRevisionChanges() throws {
    let fixture = browserInputFixture()
    let lease = try BrowserInputLease(taskID: fixture.taskID, capture: fixture.capture)
    let otherTask = browserInputState(
        fixture.capture, taskID: UUID(),
        anchor: fixture.anchor, identity: fixture.identity
    )
    let otherTab = browserInputState(
        fixture.capture, taskID: fixture.taskID, anchor: fixture.anchor,
        identity: fixture.identity, selectedTabID: UUID()
    )
    let movedWindow = browserInputState(
        fixture.capture, taskID: fixture.taskID,
        anchor: nil, identity: fixture.identity
    )
    let revoked = browserInputState(
        fixture.capture, taskID: fixture.taskID, anchor: fixture.anchor,
        identity: fixture.identity, authorityRevision: 8
    )
    for state in [otherTask, otherTab, movedWindow, revoked] {
        #expect(throws: BrowserRuntimeError.self) {
            _ = try lease.viewPoint(
                pixelX: 200, pixelY: 100, capture: fixture.capture, state: state
            )
        }
    }
}

@Test func browserInputLeaseRejectsPageScrollAndExpiredCapture() throws {
    let fixture = browserInputFixture()
    let lease = try BrowserInputLease(taskID: fixture.taskID, capture: fixture.capture)
    let changedScroll = browserInputState(
        fixture.capture, taskID: fixture.taskID,
        anchor: fixture.anchor, identity: fixture.identity, scrollY: 100
    )
    var changedIdentity = fixture.identity
    changedIdentity = BrowserPageIdentity(
        documentID: changedIdentity.documentID,
        routeGeneration: changedIdentity.routeGeneration + 1,
        mutationRevision: changedIdentity.mutationRevision,
        userRevision: changedIdentity.userRevision,
        snapshotRevision: changedIdentity.snapshotRevision,
        url: changedIdentity.url
    )
    let changedPage = browserInputState(
        fixture.capture, taskID: fixture.taskID,
        anchor: fixture.anchor, identity: changedIdentity
    )
    for state in [changedScroll, changedPage] {
        #expect(throws: BrowserRuntimeError.self) {
            _ = try lease.viewPoint(
                pixelX: 200, pixelY: 100, capture: fixture.capture, state: state
            )
        }
    }
    var expired = fixture.capture
    expired = BrowserScreenshotResult(
        captureID: expired.captureID, capturedAt: Date().addingTimeInterval(-31),
        tabID: expired.tabID, fileURL: expired.fileURL, mediaType: expired.mediaType,
        pixelWidth: expired.pixelWidth, pixelHeight: expired.pixelHeight,
        pointWidth: expired.pointWidth, pointHeight: expired.pointHeight,
        byteCount: expired.byteCount, authorityRevision: expired.authorityRevision,
        readRevision: expired.readRevision,
        navigationRevision: expired.navigationRevision,
        pageIdentity: fixture.identity, inputAnchor: fixture.anchor,
        cropOriginX: expired.cropOriginX, cropOriginY: expired.cropOriginY
    )
    let state = browserInputState(
        expired, taskID: fixture.taskID,
        anchor: fixture.anchor, identity: fixture.identity
    )
    #expect(throws: BrowserRuntimeError.self) {
        _ = try lease.viewPoint(pixelX: 200, pixelY: 100, capture: expired, state: state)
    }
}

@Test @MainActor func browserCaptureRecordsNestedScrollWithoutSemanticRead() async throws {
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .fullControl
    let tab = model.newTab()
    tab.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    tab.webView.loadHTMLString("""
        <!doctype html><html><body>
        <div id='scroller' style='height:100px;width:300px;overflow:auto'>
          <div style='height:800px'>Tall fixture content</div>
        </div>
        </body></html>
        """, baseURL: URL(string: "https://example.com/scroll-fixture")!)
    var loaded = false
    for _ in 0..<100 {
        if let ready = try? await tab.webView.evaluateJavaScript(
            "document.readyState === 'complete' && Boolean(document.getElementById('scroller'))"
        ) as? Bool, ready {
            loaded = true
            break
        }
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(loaded)
    let before = try await model.screenshot(tab.id)
    #expect(before.scrollFingerprint.isEmpty)
    #expect(before.inputAnchor == nil)
    await #expect(throws: BrowserRuntimeError.self) {
        _ = try await model.makeVisualInputLease(
            taskID: UUID(), tabID: tab.id, captureID: before.captureID
        )
    }
    _ = try await tab.webView.evaluateJavaScript(
        "document.getElementById('scroller').scrollTop = 80; true"
    )
    let after = try await model.screenshot(tab.id)
    #expect(after.scrollFingerprint != before.scrollFingerprint)
    #expect(!after.scrollFingerprint.isEmpty)
    #expect(after.pageIdentity?.documentID == before.pageIdentity?.documentID)
    try await model.close(tab.id)
}

@Test func browserInputLeaseRequiresForegroundScreenshotAnchor() throws {
    let fixture = browserInputFixture()
    var detached = fixture.capture
    detached.inputAnchor = nil
    #expect(throws: BrowserRuntimeError.self) {
        _ = try BrowserInputLease(taskID: fixture.taskID, capture: detached)
    }
}
