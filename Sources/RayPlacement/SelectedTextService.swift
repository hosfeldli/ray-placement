import AppKit
import ApplicationServices
import Foundation

enum SelectedTextService {
    struct SelectionContext {
        let processIdentifier: pid_t
        let text: String
        fileprivate let element: AXUIElement
        fileprivate let range: CFRange?
    }

    enum SelectionError: LocalizedError {
        case accessibilityRequired
        case focusedControlUnavailable
        case selectionUnavailable
        case emptySelection
        case selectionChanged
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
            case .selectionChanged:
                return "The original highlighted text changed before it could be replaced. Select it again and rerun the writing check."
            case .replacementUnavailable:
                return "The previous app did not allow RayPlacement to replace its selected text. You can still copy the reviewed text."
            }
        }
    }

    enum ReplacementObservation: Equatable {
        case replaced
        case originalStillPresent
        case changed
        case unavailable
    }

    static func selectionContext(in processIdentifier: pid_t) throws -> SelectionContext {
        guard AXIsProcessTrusted() else { throw SelectionError.accessibilityRequired }

        let elements = focusedElementCandidates(in: processIdentifier)
        guard !elements.isEmpty else { throw SelectionError.focusedControlUnavailable }

        var foundReadableSelection = false
        for element in elements {
            guard elementBelongsToProcess(element, processIdentifier) else { continue }
            if let selection = selection(in: element) {
                foundReadableSelection = true
                guard !selection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                return SelectionContext(
                    processIdentifier: processIdentifier,
                    text: selection.text,
                    element: element,
                    range: selection.range
                )
            }
        }

        throw foundReadableSelection ? SelectionError.emptySelection : SelectionError.selectionUnavailable
    }

    static func selectedText(in processIdentifier: pid_t) throws -> String {
        try selectionContext(in: processIdentifier).text
    }

    static func editableContext(in processIdentifier: pid_t) throws -> SelectionContext {
        guard AXIsProcessTrusted() else { throw SelectionError.accessibilityRequired }
        let elements = focusedElementCandidates(in: processIdentifier)
        guard !elements.isEmpty else { throw SelectionError.focusedControlUnavailable }

        for element in elements where elementBelongsToProcess(element, processIdentifier) {
            guard let selection = selection(in: element) else { continue }
            var isSettable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(
                element,
                kAXSelectedTextAttribute as CFString,
                &isSettable
            ) == .success, isSettable.boolValue else { continue }
            return SelectionContext(
                processIdentifier: processIdentifier,
                text: selection.text,
                element: element,
                range: selection.range
            )
        }
        throw SelectionError.focusedControlUnavailable
    }

    static func replaceSelectedText(_ replacement: String, using context: SelectionContext) throws {
        try restoreSelection(using: context)

        var isSettable = DarwinBoolean(false)
        let settableStatus = AXUIElementIsAttributeSettable(
            context.element,
            kAXSelectedTextAttribute as CFString,
            &isSettable
        )
        guard settableStatus == .success, isSettable.boolValue else {
            throw SelectionError.replacementUnavailable
        }
        guard AXUIElementSetAttributeValue(
            context.element,
            kAXSelectedTextAttribute as CFString,
            replacement as CFString
        ) == .success else {
            throw SelectionError.replacementUnavailable
        }

        // Verification is intentionally deferred by the caller. Editors such as
        // TextEdit can acknowledge this AX write before their text storage makes
        // the new characters observable. Treating that stale read as a failure
        // can otherwise cause a second, destructive keyboard paste.
    }

    static func observeReplacement(_ replacement: String, using context: SelectionContext) -> ReplacementObservation {
        guard let originalRange = context.range else { return .unavailable }
        let replacementRange = CFRange(
            location: originalRange.location,
            length: (replacement as NSString).length
        )
        if string(in: replacementRange, from: context.element) == replacement {
            return .replaced
        }
        if string(in: originalRange, from: context.element) == context.text {
            return .originalStillPresent
        }
        return .changed
    }

    /// Restores the exact captured selection without modifying it. Callers use
    /// this immediately before a keyboard paste when an editor exposes its
    /// selection through Accessibility but refuses direct selected-text writes.
    static func restoreSelection(using context: SelectionContext) throws {
        guard AXIsProcessTrusted() else { throw SelectionError.accessibilityRequired }
        guard elementBelongsToProcess(context.element, context.processIdentifier) else {
            throw SelectionError.focusedControlUnavailable
        }

        _ = AXUIElementSetAttributeValue(
            context.element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )

        let currentSelection = selection(in: context.element)
        let currentRangeMatches = context.range == nil || rangesMatch(currentSelection?.range, context.range)
        if currentSelection?.text != context.text || !currentRangeMatches {
            guard let range = context.range,
                  string(in: range, from: context.element) == context.text,
                  setSelectedRange(range, in: context.element) else {
                throw SelectionError.selectionChanged
            }
        }
    }

    static func replaceSelectedText(_ replacement: String, in processIdentifier: pid_t) throws {
        try replaceSelectedText(replacement, using: selectionContext(in: processIdentifier))
    }

    private static func focusedElementCandidates(in processIdentifier: pid_t) -> [AXUIElement] {
        let application = AXUIElementCreateApplication(processIdentifier)
        let systemWide = AXUIElementCreateSystemWide()
        var candidates: [AXUIElement] = []

        appendFocusedElement(from: systemWide, to: &candidates)
        appendFocusedElement(from: application, to: &candidates)
        appendFocusedWindow(from: application, to: &candidates)

        var index = 0
        while index < candidates.count, index < 80 {
            let element = candidates[index]
            appendFocusedElement(from: element, to: &candidates)
            appendParent(from: element, to: &candidates)
            appendChildren(from: element, to: &candidates, maximum: 16)
            index += 1
        }

        return candidates.filter { elementBelongsToProcess($0, processIdentifier) }
    }

    private static func appendFocusedElement(from source: AXUIElement, to candidates: inout [AXUIElement]) {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            source,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success, let value else { return }
        append(unsafeBitCast(value, to: AXUIElement.self), to: &candidates)
    }

    private static func appendFocusedWindow(from source: AXUIElement, to candidates: inout [AXUIElement]) {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            source,
            kAXFocusedWindowAttribute as CFString,
            &value
        ) == .success, let value else { return }
        append(unsafeBitCast(value, to: AXUIElement.self), to: &candidates)
    }

    private static func appendChildren(
        from source: AXUIElement,
        to candidates: inout [AXUIElement],
        maximum: Int
    ) {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            source,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success, let children = value as? [AXUIElement] else { return }
        for child in children.prefix(maximum) {
            append(child, to: &candidates)
        }
    }

    private static func appendParent(from source: AXUIElement, to candidates: inout [AXUIElement]) {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            source,
            kAXParentAttribute as CFString,
            &value
        ) == .success, let value else { return }
        append(unsafeBitCast(value, to: AXUIElement.self), to: &candidates)
    }

    private static func append(_ candidate: AXUIElement, to candidates: inout [AXUIElement]) {
        guard !candidates.contains(where: { CFEqual($0, candidate) }) else { return }
        candidates.append(candidate)
    }

    private static func elementBelongsToProcess(_ element: AXUIElement, _ processIdentifier: pid_t) -> Bool {
        var elementProcessIdentifier: pid_t = 0
        return AXUIElementGetPid(element, &elementProcessIdentifier) == .success
            && elementProcessIdentifier == processIdentifier
    }

    private static func selection(in element: AXUIElement) -> (text: String, range: CFRange?)? {
        let range = selectedRange(in: element)
        var selectedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        ) == .success {
            let directText: String?
            if let text = selectedValue as? String {
                directText = text
            } else if let attributed = selectedValue as? NSAttributedString {
                directText = attributed.string
            } else {
                directText = nil
            }

            // Some editors preserve the selected range when they become
            // inactive but temporarily expose an empty selected-text value.
            // Prefer the range-backed characters in that state so opening the
            // launcher does not make a real highlight appear empty.
            if let directText, !directText.isEmpty || (range?.length ?? 0) == 0 {
                return (directText, range)
            }
            if let range, let rangedText = string(in: range, from: element) {
                return (rangedText, range)
            }
            if let directText { return (directText, range) }
        }

        guard let range else { return nil }
        return string(in: range, from: element).map { ($0, range) }
    }

    private static func selectedRange(in element: AXUIElement) -> CFRange? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        ) == .success, let rangeValue else { return nil }
        let value = unsafeBitCast(rangeValue, to: AXValue.self)
        guard AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range) else { return nil }
        return range
    }

    private static func string(in range: CFRange, from element: AXUIElement) -> String? {
        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else { return nil }
        var selectedValue: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &selectedValue
        ) == .success {
            if let text = selectedValue as? String { return text }
            if let attributed = selectedValue as? NSAttributedString { return attributed.string }
        }

        var fullValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &fullValue
        ) == .success, let text = fullValue as? String else { return nil }
        let source = text as NSString
        guard range.location >= 0, range.length >= 0,
              range.length <= source.length,
              range.location <= source.length - range.length else { return nil }
        return source.substring(with: NSRange(location: range.location, length: range.length))
    }

    private static func setSelectedRange(_ range: CFRange, in element: AXUIElement) -> Bool {
        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else { return false }
        var isSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &isSettable
        ) == .success, isSettable.boolValue else { return false }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            rangeValue
        ) == .success
    }

    private static func rangesMatch(_ lhs: CFRange?, _ rhs: CFRange?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (.some(let lhs), .some(let rhs)):
            return lhs.location == rhs.location && lhs.length == rhs.length
        default: return false
        }
    }
}
