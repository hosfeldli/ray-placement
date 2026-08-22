import ApplicationServices
import Foundation

enum SelectedTextService {
    enum SelectionError: LocalizedError {
        case accessibilityRequired
        case focusedControlUnavailable
        case selectionUnavailable
        case emptySelection
        case replacementUnavailable

        var errorDescription: String? {
            switch self {
            case .accessibilityRequired:
                return "Enable RayPlacement in System Settings → Privacy & Security → Accessibility, select text in another app, then try again."
            case .focusedControlUnavailable:
                return "RayPlacement could not find the focused text field in the previous app. Select text in an editor that supports macOS Accessibility, then try again."
            case .selectionUnavailable:
                return "The focused app did not provide its selected text through macOS Accessibility. No clipboard text was used."
            case .emptySelection:
                return "Select some text in the previous app, then run Check Spelling & Grammar again."
            case .replacementUnavailable:
                return "The previous app did not allow RayPlacement to replace its selected text. You can still copy the reviewed text."
            }
        }
    }

    static func selectedText(in processIdentifier: pid_t) throws -> String {
        guard AXIsProcessTrusted() else { throw SelectionError.accessibilityRequired }

        let application = AXUIElementCreateApplication(processIdentifier)
        var focusedValue: CFTypeRef?
        let focusedStatus = AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard focusedStatus == .success, let focusedValue else {
            throw SelectionError.focusedControlUnavailable
        }

        let focusedElement = unsafeBitCast(focusedValue, to: AXUIElement.self)
        var selectedValue: CFTypeRef?
        let selectedStatus = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        )
        guard selectedStatus == .success, let selectedText = selectedValue as? String else {
            throw SelectionError.selectionUnavailable
        }
        guard !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SelectionError.emptySelection
        }
        return selectedText
    }

    static func replaceSelectedText(_ replacement: String, in processIdentifier: pid_t) throws {
        guard AXIsProcessTrusted() else { throw SelectionError.accessibilityRequired }

        let application = AXUIElementCreateApplication(processIdentifier)
        var focusedValue: CFTypeRef?
        let focusedStatus = AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard focusedStatus == .success, let focusedValue else {
            throw SelectionError.focusedControlUnavailable
        }

        let focusedElement = unsafeBitCast(focusedValue, to: AXUIElement.self)
        var isSettable = DarwinBoolean(false)
        let settableStatus = AXUIElementIsAttributeSettable(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &isSettable
        )
        guard settableStatus == .success, isSettable.boolValue else {
            throw SelectionError.replacementUnavailable
        }
        guard AXUIElementSetAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            replacement as CFString
        ) == .success else {
            throw SelectionError.replacementUnavailable
        }
    }
}
