import AppKit
import SwiftUI

struct InlineMarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var compact = false

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = MarkdownTextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = true
        textView.textContainerInset = compact
            ? NSSize(width: 16, height: 18)
            : NSSize(width: 32, height: 26)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        textView.setAccessibilityLabel("Inline Markdown editor")
        textView.string = text
        context.coordinator.textView = textView
        context.coordinator.applyStyles(immediately: true)
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownTextView else { return }
        context.coordinator.text = $text
        textView.textContainerInset = compact
            ? NSSize(width: 16, height: 18)
            : NSSize(width: 32, height: 26)
        if textView.string != text {
            let selection = textView.selectedRange()
            context.coordinator.isApplyingExternalUpdate = true
            textView.string = text
            textView.setSelectedRange(NSRange(
                location: min(selection.location, (text as NSString).length),
                length: 0
            ))
            context.coordinator.isApplyingExternalUpdate = false
            context.coordinator.applyStyles(immediately: true)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        fileprivate weak var textView: MarkdownTextView?
        var isApplyingExternalUpdate = false
        private var stylingWorkItem: DispatchWorkItem?

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalUpdate, let textView else { return }
            text.wrappedValue = textView.string
            applyStyles(immediately: false)
        }

        func applyStyles(immediately: Bool) {
            stylingWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let textView = self.textView else { return }
                MarkdownInlineStyler.apply(to: textView)
            }
            stylingWorkItem = work
            if immediately {
                work.perform()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: work)
            }
        }
    }
}

fileprivate final class MarkdownTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command, let character = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch character {
        case "b":
            wrapSelection(prefix: "**", suffix: "**", placeholder: "bold text")
            return true
        case "i":
            wrapSelection(prefix: "*", suffix: "*", placeholder: "italic text")
            return true
        case "k":
            wrapSelection(prefix: "[", suffix: "](https://)", placeholder: "link title")
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func insertNewline(_ sender: Any?) {
        let source = string as NSString
        let selection = selectedRange()
        let lineRange = source.lineRange(for: NSRange(location: selection.location, length: 0))
        let line = source.substring(with: lineRange).trimmingCharacters(in: .newlines)

        let continuation: String?
        if let match = line.firstMatch(pattern: #"^(\s*)- \[[ xX]\] (.*)$"#) {
            continuation = match[2].isEmpty ? nil : "\n\(match[1])- [ ] "
        } else if let match = line.firstMatch(pattern: #"^(\s*)[-*+] (.*)$"#) {
            continuation = match[2].isEmpty ? nil : "\n\(match[1])- "
        } else if let match = line.firstMatch(pattern: #"^(\s*)(\d+)[.)] (.*)$"#),
                  let number = Int(match[2]) {
            continuation = match[3].isEmpty ? nil : "\n\(match[1])\(number + 1). "
        } else if let match = line.firstMatch(pattern: #"^(\s*)> (.*)$"#) {
            continuation = match[2].isEmpty ? nil : "\n\(match[1])> "
        } else {
            continuation = nil
        }

        guard let continuation else {
            super.insertNewline(sender)
            return
        }
        insertText(continuation, replacementRange: selection)
    }

    private func wrapSelection(prefix: String, suffix: String, placeholder: String) {
        let selection = selectedRange()
        let source = string as NSString
        let selectedText = selection.length > 0 ? source.substring(with: selection) : placeholder
        let replacement = prefix + selectedText + suffix
        guard shouldChangeText(in: selection, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: selection, with: replacement)
        didChangeText()
        setSelectedRange(NSRange(location: selection.location + prefix.utf16.count, length: selectedText.utf16.count))
    }
}

private enum MarkdownInlineStyler {
    private static let baseFont = NSFont.systemFont(ofSize: 15)
    private static let monoFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    private static let markerColor = NSColor.tertiaryLabelColor
    private static let codeBackground = NSColor.controlBackgroundColor.withAlphaComponent(0.72)

    static func apply(to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let source = storage.string as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        let selection = textView.selectedRanges
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 5

        storage.beginEditing()
        storage.setAttributes([
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ], range: fullRange)

        apply(pattern: #"(?m)^(#{1,6})[ \t]+(.+)$"#, to: source) { match in
            let level = min(max(match.range(at: 1).length, 1), 6)
            let sizes: [CGFloat] = [28, 24, 21, 18, 16, 15]
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: sizes[level - 1], weight: .bold), range: match.range)
            storage.addAttribute(.foregroundColor, value: markerColor, range: match.range(at: 1))
        }

        apply(pattern: #"(?ms)^```([^\n]*)\n(.*?)^```[ \t]*$"#, to: source) { match in
            storage.addAttributes([.font: monoFont, .backgroundColor: codeBackground], range: match.range)
            if match.range(at: 1).location != NSNotFound {
                storage.addAttributes([.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)], range: match.range(at: 1))
            }
            if match.range.length >= 6 {
                storage.addAttribute(.foregroundColor, value: markerColor, range: NSRange(location: match.range.location, length: 3))
                storage.addAttribute(.foregroundColor, value: markerColor, range: NSRange(location: NSMaxRange(match.range) - 3, length: 3))
            }
        }

        apply(pattern: #"`([^`\n]+)`"#, to: source) { match in
            storage.addAttributes([.font: monoFont, .backgroundColor: codeBackground], range: match.range)
            storage.addAttribute(.foregroundColor, value: markerColor, range: NSRange(location: match.range.location, length: 1))
            storage.addAttribute(.foregroundColor, value: markerColor, range: NSRange(location: NSMaxRange(match.range) - 1, length: 1))
        }

        apply(pattern: #"\*\*([^*\n]+)\*\*|__([^_\n]+)__"#, to: source) { match in
            let contentRange = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 15, weight: .bold), range: contentRange)
            styleMarkers(around: contentRange, in: match.range, storage: storage)
        }
        apply(pattern: #"(?<!\*)\*([^*\n]+)\*(?!\*)|(?<!_)_([^_\n]+)_(?!_)"#, to: source) { match in
            let contentRange = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
            let italic = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
            storage.addAttribute(.font, value: italic, range: contentRange)
            styleMarkers(around: contentRange, in: match.range, storage: storage)
        }

        apply(pattern: #"\[([^\]]+)\]\(([^)]+)\)"#, to: source) { match in
            let labelRange = match.range(at: 1)
            let destinationRange = match.range(at: 2)
            storage.addAttributes([.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: labelRange)
            storage.addAttribute(.foregroundColor, value: markerColor, range: NSRange(location: match.range.location, length: labelRange.location - match.range.location))
            storage.addAttribute(.foregroundColor, value: markerColor, range: NSRange(location: NSMaxRange(labelRange), length: NSMaxRange(match.range) - NSMaxRange(labelRange)))
            if let url = URL(string: source.substring(with: destinationRange)) {
                storage.addAttribute(.link, value: url, range: labelRange)
            }
        }

        apply(pattern: #"(?m)^(\s*)([-*+]|\d+[.)])\s+"#, to: source) { match in
            storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: match.range)
        }
        apply(pattern: #"(?m)^(\s*)- \[([ xX])\]\s+(.*)$"#, to: source) { match in
            let checked = source.substring(with: match.range(at: 2)).lowercased() == "x"
            storage.addAttribute(.foregroundColor, value: checked ? NSColor.systemGreen : NSColor.controlAccentColor, range: NSRange(location: match.range.location, length: match.range(at: 3).location - match.range.location))
            if checked {
                storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.secondaryLabelColor], range: match.range(at: 3))
            }
        }
        apply(pattern: #"(?m)^(\s*>\s?)(.*)$"#, to: source) { match in
            storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: match.range(at: 1))
            let italic = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
            storage.addAttributes([.font: italic, .foregroundColor: NSColor.secondaryLabelColor], range: match.range(at: 2))
        }
        apply(pattern: #"(?m)^(---|\*\*\*|___)[ \t]*$"#, to: source) { match in
            storage.addAttribute(.foregroundColor, value: markerColor, range: match.range)
        }

        storage.endEditing()
        textView.selectedRanges = selection
        textView.typingAttributes = [.font: baseFont, .foregroundColor: NSColor.labelColor]
    }

    private static func apply(pattern: String, to source: NSString, block: (NSTextCheckingResult) -> Void) {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
        expression.enumerateMatches(in: source as String, range: NSRange(location: 0, length: source.length)) { match, _, _ in
            if let match { block(match) }
        }
    }

    private static func styleMarkers(around content: NSRange, in full: NSRange, storage: NSTextStorage) {
        let prefixLength = content.location - full.location
        let suffixLength = NSMaxRange(full) - NSMaxRange(content)
        if prefixLength > 0 {
            storage.addAttribute(.foregroundColor, value: markerColor, range: NSRange(location: full.location, length: prefixLength))
        }
        if suffixLength > 0 {
            storage.addAttribute(.foregroundColor, value: markerColor, range: NSRange(location: NSMaxRange(content), length: suffixLength))
        }
    }
}

private extension String {
    func firstMatch(pattern: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: self, range: NSRange(startIndex..<endIndex, in: self)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: self) else { return "" }
            return String(self[swiftRange])
        }
    }
}
