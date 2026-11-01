import AppKit
import Foundation
import WebKit

/// Geometry captured only while the selected WebView is in Lima's key window.
/// A screenshot without this anchor may be observed, but cannot drive native input.
struct BrowserVisualInputAnchor: Codable, Equatable, Sendable {
    let windowNumber: Int
    let screenNumber: UInt32
    let backingScale: Double
    let windowX: Double
    let windowY: Double
    let windowWidth: Double
    let windowHeight: Double
    let viewX: Double
    let viewY: Double
    let viewWidth: Double
    let viewHeight: Double
    let boundsX: Double
    let boundsY: Double
    let boundsWidth: Double
    let boundsHeight: Double
    let isFlipped: Bool

    @MainActor
    static func foreground(for webView: WKWebView) -> Self? {
        guard let window = webView.window,
              NSApp.isActive, window.isVisible, window.isKeyWindow,
              !window.isMiniaturized, window.occlusionState.contains(.visible),
              let screen = window.screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        let frame = window.frame
        let view = webView.convert(webView.bounds, to: nil)
        let bounds = webView.bounds
        let dimensions = [
            frame.minX, frame.minY, frame.width, frame.height,
            view.minX, view.minY, view.width, view.height,
            bounds.minX, bounds.minY, bounds.width, bounds.height,
            window.backingScaleFactor
        ]
        guard window.windowNumber > 0, dimensions.allSatisfy(\.isFinite),
              frame.width > 0, frame.height > 0,
              view.width > 0, view.height > 0,
              bounds.width > 0, bounds.height > 0,
              window.backingScaleFactor > 0 else { return nil }
        return Self(
            windowNumber: window.windowNumber,
            screenNumber: number.uint32Value,
            backingScale: window.backingScaleFactor,
            windowX: frame.minX, windowY: frame.minY,
            windowWidth: frame.width, windowHeight: frame.height,
            viewX: view.minX, viewY: view.minY,
            viewWidth: view.width, viewHeight: view.height,
            boundsX: bounds.minX, boundsY: bounds.minY,
            boundsWidth: bounds.width, boundsHeight: bounds.height,
            isFlipped: webView.isFlipped
        )
    }
}

struct BrowserVisualInputState: Sendable {
    let taskID: UUID
    let selectedTabID: UUID?
    let authorityRevision: UInt64
    let readRevision: UInt64
    let navigationRevision: Int
    let anchor: BrowserVisualInputAnchor?
    let pageIdentity: BrowserPageIdentity
    let protectedRects: [BrowserScreenshotMask]
    let hasFilledSecureField: Bool
    let scrollX: Double
    let scrollY: Double
    let scrollFingerprint: String
    let frameIDs: [String]
}

struct BrowserVisualInputPoint: Equatable, Sendable {
    let x: Double
    let y: Double
}

/// An internal preflight token, not permission to post events. The future
/// native driver must repeat validation immediately before each event and
/// independently enforce protected-data and financial-action policy.
struct BrowserInputLease: Sendable {
    let taskID: UUID
    let tabID: UUID
    let captureID: UUID
    let anchor: BrowserVisualInputAnchor
    let pageIdentity: BrowserPageIdentity
    let allowsCanvasUpdates: Bool

    init(taskID: UUID, capture: BrowserScreenshotResult, allowsCanvasUpdates: Bool = false) throws {
        guard let anchor = capture.inputAnchor,
              let pageIdentity = capture.pageIdentity,
              capture.protectedRects.count == capture.redactionCount,
              capture.viewportWidth == anchor.boundsWidth,
              capture.viewportHeight == anchor.boundsHeight else {
            throw BrowserRuntimeError.screenshotProtected
        }
        self.taskID = taskID
        tabID = capture.tabID
        captureID = capture.captureID
        self.anchor = anchor
        self.pageIdentity = pageIdentity
        self.allowsCanvasUpdates = allowsCanvasUpdates
    }

    func viewPoint(pixelX: Double, pixelY: Double,
                   capture: BrowserScreenshotResult,
                   state: BrowserVisualInputState) throws -> BrowserVisualInputPoint {
        guard state.taskID == taskID, state.selectedTabID == tabID,
              capture.tabID == tabID, capture.captureID == captureID,
              capture.inputAnchor == anchor, state.anchor == anchor,
              capture.pageIdentity == pageIdentity,
              pageIdentity.matchesInputRevision(state.pageIdentity, allowingCanvasUpdates: allowsCanvasUpdates),
              capture.authorityRevision == state.authorityRevision,
              capture.readRevision == state.readRevision,
              capture.navigationRevision == state.navigationRevision,
              Date().timeIntervalSince(capture.capturedAt) >= 0,
              Date().timeIntervalSince(capture.capturedAt) <= 30,
              !state.hasFilledSecureField,
              capture.scrollX == state.scrollX,
              capture.scrollY == state.scrollY,
              capture.scrollFingerprint == state.scrollFingerprint,
              capture.frameIDs == state.frameIDs,
              capture.viewportWidth == anchor.boundsWidth,
              capture.viewportHeight == anchor.boundsHeight,
              capture.protectedRects.count == capture.redactionCount,
              capture.protectedRects.count == state.protectedRects.count,
              zip(capture.protectedRects, state.protectedRects)
                .allSatisfy({ $0.isNear($1) }) else {
            throw BrowserRuntimeError.staleTarget
        }
        guard pixelX.isFinite, pixelY.isFinite,
              pixelX >= 0, pixelY >= 0,
              pixelX < Double(capture.pixelWidth),
              pixelY < Double(capture.pixelHeight),
              capture.pixelWidth > 0, capture.pixelHeight > 0,
              capture.pointWidth.isFinite, capture.pointHeight.isFinite,
              capture.pointWidth > 0, capture.pointHeight > 0 else {
            throw BrowserRuntimeError.targetNotInteractable
        }
        let pageX = capture.cropOriginX +
            pixelX * capture.pointWidth / Double(capture.pixelWidth)
        let pageY = capture.cropOriginY +
            pixelY * capture.pointHeight / Double(capture.pixelHeight)
        guard pageX.isFinite, pageY.isFinite,
              pageX >= 0, pageY >= 0,
              pageX < anchor.boundsWidth, pageY < anchor.boundsHeight else {
            throw BrowserRuntimeError.targetNotInteractable
        }
        // Match the six-point expansion used when blacking out screenshots.
        let padding = 6.0
        guard !capture.protectedRects.contains(where: {
            pageX >= $0.x - padding && pageX < $0.x + $0.width + padding &&
            pageY >= $0.y - padding && pageY < $0.y + $0.height + padding
        }) else { throw BrowserRuntimeError.sensitiveTarget }
        return BrowserVisualInputPoint(
            x: anchor.boundsX + pageX,
            y: anchor.isFlipped
                ? anchor.boundsY + pageY
                : anchor.boundsY + anchor.boundsHeight - pageY
        )
    }
}
