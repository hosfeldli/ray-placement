import AppKit
import ApplicationServices
import Foundation

/// Native host service exposed to extensions through the generic `window`
/// action. The service intentionally owns Accessibility and coordinate
/// conversion details so bundled and user extensions use the same API.
enum WindowManager {
    private static var frameHistory: [pid_t: [CGRect]] = [:]
    private static let maximumHistoryDepth = 4

    static func apply(_ layout: WindowLayout, to processIdentifier: pid_t?) -> Result<Void, Error> {
        apply(layout.rawValue, to: processIdentifier)
    }

    static func apply(
        _ operation: String,
        to processIdentifier: pid_t?,
        displayIdentifier: CGDirectDisplayID? = nil
    ) -> Result<Void, Error> {
        guard let processIdentifier else { return .failure(WindowError.noApplication) }
        guard trusted(prompt: true) else { return .failure(WindowError.accessibilityPermission) }

        let app = AXUIElementCreateApplication(processIdentifier)
        guard let window = focusedWindow(in: app) else { return .failure(WindowError.noWindow) }
        guard let current = frame(of: window) else { return .failure(WindowError.noWindow) }

        if operation == WindowLayout.restorePrevious.rawValue {
            guard var history = frameHistory[processIdentifier], let previous = history.popLast() else {
                return .failure(WindowError.noPreviousPosition)
            }
            frameHistory[processIdentifier] = history
            guard setFrame(previous, of: window) else { return .failure(WindowError.notResizable) }
            return .success(())
        }

        guard let sourceScreen = screen(containingAccessibilityRect: current) else {
            return .failure(WindowError.noDisplay)
        }

        let targetScreen: NSScreen
        if let displayIdentifier,
           let selectedDisplay = NSScreen.screens.first(where: { screen in
               (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                   .map { CGDirectDisplayID($0.uint32Value) } == displayIdentifier
           }) {
            targetScreen = selectedDisplay
        } else {
            switch operation {
            case WindowLayout.nextDisplay.rawValue:
                targetScreen = adjacentScreen(from: sourceScreen, offset: 1) ?? sourceScreen
            case WindowLayout.previousDisplay.rawValue:
                targetScreen = adjacentScreen(from: sourceScreen, offset: -1) ?? sourceScreen
            case WindowLayout.mainDisplay.rawValue:
                targetScreen = NSScreen.main ?? NSScreen.screens.first ?? sourceScreen
            default:
                targetScreen = sourceScreen
            }
        }

        let target: CGRect
        if displayIdentifier != nil
            || operation == WindowLayout.nextDisplay.rawValue
            || operation == WindowLayout.previousDisplay.rawValue
            || operation == WindowLayout.mainDisplay.rawValue {
            target = preserveRelativeFrame(current, from: sourceScreen, to: targetScreen)
        } else {
            guard let layout = WindowLayout(rawValue: operation), let available = accessibilityFrame(for: targetScreen) else {
                return .failure(WindowError.unknownOperation(operation))
            }
            target = frame(for: layout, current: current, available: available)
        }

        remember(current, for: processIdentifier)
        guard setFrame(target, of: window) else { return .failure(WindowError.notResizable) }
        return .success(())
    }

    static func trusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    private static func focusedWindow(in app: AXUIElement) -> AXUIElement? {
        var rawWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &rawWindow) == .success,
              let rawWindow,
              CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else { return nil }
        return (rawWindow as! AXUIElement)
    }

    private static func frame(for layout: WindowLayout, current: CGRect, available: CGRect) -> CGRect {
        let third = available.width / 3
        let halfHeight = available.height / 2
        let quarterWidth = available.width / 2
        let quarterHeight = available.height / 2

        switch layout {
        case .leftHalf:
            return CGRect(x: available.minX, y: available.minY, width: available.width / 2, height: available.height)
        case .rightHalf:
            return CGRect(x: available.midX, y: available.minY, width: available.width / 2, height: available.height)
        case .topHalf:
            return CGRect(x: available.minX, y: available.minY, width: available.width, height: halfHeight)
        case .bottomHalf:
            return CGRect(x: available.minX, y: available.midY, width: available.width, height: halfHeight)
        case .maximize:
            return available
        case .center:
            let width = min(current.width, available.width * 0.8)
            let height = min(current.height, available.height * 0.8)
            return CGRect(x: available.midX - width / 2, y: available.midY - height / 2, width: width, height: height)
        case .leftThird:
            return CGRect(x: available.minX, y: available.minY, width: third, height: available.height)
        case .centerThird:
            return CGRect(x: available.minX + third, y: available.minY, width: third, height: available.height)
        case .rightThird:
            return CGRect(x: available.maxX - third, y: available.minY, width: third, height: available.height)
        case .leftTwoThirds:
            return CGRect(x: available.minX, y: available.minY, width: third * 2, height: available.height)
        case .rightTwoThirds:
            return CGRect(x: available.maxX - third * 2, y: available.minY, width: third * 2, height: available.height)
        case .topLeftQuarter:
            return CGRect(x: available.minX, y: available.midY, width: quarterWidth, height: quarterHeight)
        case .topRightQuarter:
            return CGRect(x: available.midX, y: available.midY, width: quarterWidth, height: quarterHeight)
        case .bottomLeftQuarter:
            return CGRect(x: available.minX, y: available.minY, width: quarterWidth, height: quarterHeight)
        case .bottomRightQuarter:
            return CGRect(x: available.midX, y: available.minY, width: quarterWidth, height: quarterHeight)
        case .restorePrevious, .nextDisplay, .previousDisplay, .mainDisplay:
            return current
        }
    }

    private static func preserveRelativeFrame(_ current: CGRect, from source: NSScreen, to target: NSScreen) -> CGRect {
        guard let sourceAvailable = accessibilityFrame(for: source),
              let targetAvailable = accessibilityFrame(for: target),
              sourceAvailable.width > 0,
              sourceAvailable.height > 0 else { return current }

        let widthRatio = min(max(current.width / sourceAvailable.width, 0.05), 1)
        let heightRatio = min(max(current.height / sourceAvailable.height, 0.05), 1)
        let xRatio = min(max((current.minX - sourceAvailable.minX) / sourceAvailable.width, 0), 1 - widthRatio)
        let yRatio = min(max((current.minY - sourceAvailable.minY) / sourceAvailable.height, 0), 1 - heightRatio)
        return CGRect(
            x: targetAvailable.minX + targetAvailable.width * xRatio,
            y: targetAvailable.minY + targetAvailable.height * yRatio,
            width: targetAvailable.width * widthRatio,
            height: targetAvailable.height * heightRatio
        )
    }

    private static func adjacentScreen(from screen: NSScreen, offset: Int) -> NSScreen? {
        let screens = NSScreen.screens.sorted { first, second in
            if first.frame.minX == second.frame.minX { return first.frame.minY < second.frame.minY }
            return first.frame.minX < second.frame.minX
        }
        guard let index = screens.firstIndex(of: screen), !screens.isEmpty else { return nil }
        let targetIndex = (index + offset + screens.count) % screens.count
        return screens[targetIndex]
    }

    private static func remember(_ frame: CGRect, for processIdentifier: pid_t) {
        var history = frameHistory[processIdentifier, default: []]
        history.append(frame)
        if history.count > maximumHistoryDepth {
            history.removeFirst(history.count - maximumHistoryDepth)
        }
        frameHistory[processIdentifier] = history
    }

    private static func setFrame(_ frame: CGRect, of window: AXUIElement) -> Bool {
        var position = frame.origin
        var size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return false }
        let positionResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        let sizeResult = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        return positionResult == .success && sizeResult == .success
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var rawPosition: CFTypeRef?
        var rawSize: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &rawPosition) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &rawSize) == .success,
              let rawPosition,
              let rawSize,
              CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        let positionValue = rawPosition as! AXValue
        let sizeValue = rawSize as! AXValue
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private static func screen(containingAccessibilityRect accessibilityRect: CGRect) -> NSScreen? {
        let mainTop = NSScreen.screens.map(\.frame.maxY).max() ?? 0
        let cocoaRect = CGRect(
            x: accessibilityRect.minX,
            y: mainTop - accessibilityRect.maxY,
            width: accessibilityRect.width,
            height: accessibilityRect.height
        )
        return NSScreen.screens.max { first, second in
            first.frame.intersection(cocoaRect).area < second.frame.intersection(cocoaRect).area
        }
    }

    private static func accessibilityFrame(for screen: NSScreen) -> CGRect? {
        let mainTop = NSScreen.screens.map(\.frame.maxY).max() ?? 0
        let visible = screen.visibleFrame
        return CGRect(x: visible.minX, y: mainTop - visible.maxY, width: visible.width, height: visible.height)
    }

    enum WindowError: LocalizedError {
        case noApplication
        case accessibilityPermission
        case noWindow
        case noDisplay
        case noPreviousPosition
        case notResizable
        case unknownOperation(String)

        var errorDescription: String? {
            switch self {
            case .noApplication: return "There is no previous app to manage."
            case .accessibilityPermission: return "Enable Lima in System Settings → Privacy & Security → Accessibility, then try again."
            case .noWindow: return "The frontmost app does not have a movable window."
            case .noDisplay: return "Lima could not determine the window's display."
            case .noPreviousPosition: return "There is no saved window position to restore."
            case .notResizable: return "That window cannot be moved or resized."
            case .unknownOperation(let operation): return "Unsupported window operation: \(operation)."
            }
        }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
