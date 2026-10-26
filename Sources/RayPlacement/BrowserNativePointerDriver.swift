import AppKit
import ApplicationServices
import CoreGraphics
import WebKit

/// Native event delivery for the embedded Browser. Only the Browser model may
/// call the committing methods after lease validation and its independent
/// protected-data, task-scope, and financial authorization checks.
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

    /// Tagged events are delivered to Lima only. The Browser's human-input
    /// monitor ignores this tag; untagged user events revoke the input lease.
    static let automationEventTag: Int64 = 0x4c494d41564953

    private static func validatedQuartzPoint(
        _ point: BrowserVisualInputPoint,
        in webView: WKWebView,
        expectedAnchor: BrowserVisualInputAnchor
    ) throws -> CGPoint {
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
        let actualQuartz = CGPoint(x: actual.x, y: primaryScreenTop - actual.y)
        guard abs(projected.x - actualQuartz.x) <= 2,
              abs(projected.y - actualQuartz.y) <= 2 else {
            throw BrowserNativePointerError.invalidGeometry
        }
        return projected
    }

    static func click(
        _ point: BrowserVisualInputPoint,
        in webView: WKWebView,
        expectedAnchor: BrowserVisualInputAnchor
    ) throws {
        let projected = try validatedQuartzPoint(point, in: webView, expectedAnchor: expectedAnchor)
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                 mouseCursorPosition: projected, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                               mouseCursorPosition: projected, mouseButton: .left) else {
            throw BrowserNativePointerError.eventUnavailable
        }
        down.setIntegerValueField(.eventSourceUserData, value: automationEventTag)
        up.setIntegerValueField(.eventSourceUserData, value: automationEventTag)
        let pid = ProcessInfo.processInfo.processIdentifier
        down.postToPid(pid)
        up.postToPid(pid)
    }

    static func typeText(
        _ text: String,
        at point: BrowserVisualInputPoint,
        in webView: WKWebView,
        expectedAnchor: BrowserVisualInputAnchor
    ) throws {
        guard !text.isEmpty, text.utf8.count <= 1024,
              text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) &&
                  $0.value != 0x2028 && $0.value != 0x2029 }) else {
            throw BrowserNativePointerError.invalidGeometry
        }
        let projected = try validatedQuartzPoint(point, in: webView, expectedAnchor: expectedAnchor)
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                 mouseCursorPosition: projected, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                               mouseCursorPosition: projected, mouseButton: .left) else {
            throw BrowserNativePointerError.eventUnavailable
        }
        var keys: [(CGEvent, CGEvent)] = []
        keys.reserveCapacity(text.count)
        for character in text {
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                throw BrowserNativePointerError.eventUnavailable
            }
            let units = Array(String(character).utf16)
            units.withUnsafeBufferPointer { buffer in
                keyDown.keyboardSetUnicodeString(
                    stringLength: buffer.count, unicodeString: buffer.baseAddress!
                )
                keyUp.keyboardSetUnicodeString(
                    stringLength: buffer.count, unicodeString: buffer.baseAddress!
                )
            }
            keyDown.setIntegerValueField(.eventSourceUserData, value: automationEventTag)
            keyUp.setIntegerValueField(.eventSourceUserData, value: automationEventTag)
            keys.append((keyDown, keyUp))
        }
        down.setIntegerValueField(.eventSourceUserData, value: automationEventTag)
        up.setIntegerValueField(.eventSourceUserData, value: automationEventTag)
        let pid = ProcessInfo.processInfo.processIdentifier
        down.postToPid(pid)
        up.postToPid(pid)
        for (keyDown, keyUp) in keys {
            keyDown.postToPid(pid)
            keyUp.postToPid(pid)
        }
    }

    static func scroll(
        _ point: BrowserVisualInputPoint,
        deltaX: Int32,
        deltaY: Int32,
        in webView: WKWebView,
        expectedAnchor: BrowserVisualInputAnchor
    ) throws {
        let projected = try validatedQuartzPoint(point, in: webView, expectedAnchor: expectedAnchor)
        guard abs(Int64(deltaX)) <= 1200, abs(Int64(deltaY)) <= 1200,
              deltaX != 0 || deltaY != 0,
              let source = CGEventSource(stateID: .combinedSessionState),
              let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                 mouseCursorPosition: projected, mouseButton: .left),
              let wheel = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                  wheelCount: 2, wheel1: deltaY, wheel2: deltaX, wheel3: 0) else {
            throw BrowserNativePointerError.invalidGeometry
        }
        move.setIntegerValueField(.eventSourceUserData, value: automationEventTag)
        wheel.setIntegerValueField(.eventSourceUserData, value: automationEventTag)
        wheel.location = projected
        let pid = ProcessInfo.processInfo.processIdentifier
        move.postToPid(pid)
        wheel.postToPid(pid)
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
        event.setIntegerValueField(.eventSourceUserData, value: automationEventTag)
        // Address only Lima, never an arbitrary foreground application.
        event.postToPid(ProcessInfo.processInfo.processIdentifier)
    }
}
