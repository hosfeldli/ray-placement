import AppKit
import ApplicationServices
import CoreGraphics
import WebKit

/// Native pointer delivery for the embedded Browser. This is deliberately not
/// an AI tool: coordinate clicks and typing require a separate, complete
/// financial/protected-data authorization path before they can be exposed.
enum BrowserNativePointerError: LocalizedError {
    case accessibilityRequired
    case staleForeground
    case invalidGeometry
    case targetObscured
    case eventUnavailable

    var errorDescription: String? {
        switch self {
        case .accessibilityRequired:
            "Accessibility access is required for native Browser input."
        case .staleForeground:
            "The intended Lima Browser window is no longer foreground."
        case .invalidGeometry:
            "The screenshot point no longer maps to the visible Browser viewport."
        case .targetObscured:
            "Another Lima view covers the intended Browser point."
        case .eventUnavailable:
            "macOS could not create the native pointer event."
        }
    }
}

@MainActor
enum BrowserNativePointerDriver {
    /// Project a lease-validated WebView point to Quartz's primary-display-top
    /// coordinate system. Keeping this pure makes mixed-scale and negative-origin
    /// display geometry testable without posting an event.
    static func quartzPoint(
        _ point: BrowserVisualInputPoint,
        anchor: BrowserVisualInputAnchor,
        primaryScreenTop: Double
    ) throws -> CGPoint {
        let values = [
            point.x, point.y, primaryScreenTop,
            anchor.windowX, anchor.windowY, anchor.viewX, anchor.viewY,
            anchor.viewWidth, anchor.viewHeight,
            anchor.boundsX, anchor.boundsY, anchor.boundsWidth, anchor.boundsHeight
        ]
        guard values.allSatisfy(\.isFinite),
              anchor.viewWidth > 0, anchor.viewHeight > 0,
              anchor.boundsWidth > 0, anchor.boundsHeight > 0 else {
            throw BrowserNativePointerError.invalidGeometry
        }
        let x = (point.x - anchor.boundsX) / anchor.boundsWidth
        let y = (point.y - anchor.boundsY) / anchor.boundsHeight
        guard x > 0, x < 1, y > 0, y < 1 else {
            throw BrowserNativePointerError.invalidGeometry
        }
        let screenX = anchor.windowX + anchor.viewX + x * anchor.viewWidth
        let appKitY = anchor.windowY + anchor.viewY +
            (anchor.isFlipped ? 1 - y : y) * anchor.viewHeight
        let result = CGPoint(x: screenX, y: primaryScreenTop - appKitY)
        guard result.x.isFinite, result.y.isFinite else {
            throw BrowserNativePointerError.invalidGeometry
        }
        return result
    }

    /// Post only a non-committing move. The model repeats the screenshot safety
    /// preflight immediately before calling this method; this synchronous
    /// boundary then rechecks the foreground window and AppKit hit path.
    static func move(
        _ point: BrowserVisualInputPoint,
        in webView: WKWebView,
        expectedAnchor: BrowserVisualInputAnchor
    ) throws {
        guard AXIsProcessTrusted() else {
            throw BrowserNativePointerError.accessibilityRequired
        }
        guard BrowserVisualInputAnchor.foreground(for: webView) == expectedAnchor,
              let window = webView.window,
              let contentView = window.contentView,
              let primaryScreenTop = NSScreen.screens.first?.frame.maxY else {
            throw BrowserNativePointerError.staleForeground
        }
        let viewPoint = CGPoint(x: point.x, y: point.y)
        guard webView.bounds.contains(viewPoint) else {
            throw BrowserNativePointerError.invalidGeometry
        }
        let windowPoint = webView.convert(viewPoint, to: nil)
        let contentPoint = contentView.convert(windowPoint, from: nil)
        guard let hit = contentView.hitTest(contentPoint),
              hit === webView || hit.isDescendant(of: webView) else {
            throw BrowserNativePointerError.targetObscured
        }
        let projected = try quartzPoint(
            point, anchor: expectedAnchor,
            primaryScreenTop: Double(primaryScreenTop)
        )
        let actual = window.convertPoint(toScreen: windowPoint)
        let actualQuartz = CGPoint(
            x: actual.x, y: primaryScreenTop - actual.y
        )
        guard abs(projected.x - actualQuartz.x) <= 2,
              abs(projected.y - actualQuartz.y) <= 2 else {
            throw BrowserNativePointerError.invalidGeometry
        }
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let event = CGEvent(
                mouseEventSource: source, mouseType: .mouseMoved,
                mouseCursorPosition: projected, mouseButton: .left
              ) else {
            throw BrowserNativePointerError.eventUnavailable
        }
        // Address only Lima, never an arbitrary foreground application.
        event.postToPid(ProcessInfo.processInfo.processIdentifier)
    }
}
