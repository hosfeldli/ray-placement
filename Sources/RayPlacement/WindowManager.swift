import AppKit
import ApplicationServices
import Foundation

enum WindowManager {
    static func apply(_ layout: WindowLayout, to processIdentifier: pid_t?) -> Result<Void, Error> {
        guard let processIdentifier else { return .failure(WindowError.noApplication) }
        guard trusted(prompt: true) else { return .failure(WindowError.accessibilityPermission) }

        let app = AXUIElementCreateApplication(processIdentifier)
        var rawWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &rawWindow) == .success,
              let window = rawWindow,
              CFGetTypeID(window) == AXUIElementGetTypeID() else { return .failure(WindowError.noWindow) }

        let windowElement = window as! AXUIElement
        guard let current = frame(of: windowElement), let screen = screen(containing: current) else {
            return .failure(WindowError.noWindow)
        }
        let available = accessibilityFrame(for: screen)
        let target: CGRect

        switch layout {
        case .leftHalf:
            target = CGRect(x: available.minX, y: available.minY, width: available.width / 2, height: available.height)
        case .rightHalf:
            target = CGRect(x: available.midX, y: available.minY, width: available.width / 2, height: available.height)
        case .topHalf:
            target = CGRect(x: available.minX, y: available.minY, width: available.width, height: available.height / 2)
        case .bottomHalf:
            target = CGRect(x: available.minX, y: available.midY, width: available.width, height: available.height / 2)
        case .maximize:
            target = available
        case .center:
            let width = min(current.width, available.width * 0.8)
            let height = min(current.height, available.height * 0.8)
            target = CGRect(x: available.midX - width / 2, y: available.midY - height / 2, width: width, height: height)
        }

        var position = target.origin
        var size = target.size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return .failure(WindowError.noWindow) }
        let positionResult = AXUIElementSetAttributeValue(windowElement, kAXPositionAttribute as CFString, positionValue)
        let sizeResult = AXUIElementSetAttributeValue(windowElement, kAXSizeAttribute as CFString, sizeValue)
        guard positionResult == .success, sizeResult == .success else { return .failure(WindowError.notResizable) }
        return .success(())
    }

    static func trusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
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

    private static func screen(containing accessibilityRect: CGRect) -> NSScreen? {
        let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
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

    private static func accessibilityFrame(for screen: NSScreen) -> CGRect {
        let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
        let visible = screen.visibleFrame
        return CGRect(x: visible.minX, y: mainTop - visible.maxY, width: visible.width, height: visible.height)
    }

    enum WindowError: LocalizedError {
        case noApplication
        case accessibilityPermission
        case noWindow
        case notResizable

        var errorDescription: String? {
            switch self {
            case .noApplication: return "There is no previous app to resize."
            case .accessibilityPermission: return "Enable RayPlacement in System Settings → Privacy & Security → Accessibility, then try again."
            case .noWindow: return "The frontmost app does not have a movable window."
            case .notResizable: return "That window cannot be resized."
            }
        }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
