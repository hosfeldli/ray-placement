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
        MarkdownEditorFocus.shared.editor = textView
        context.coordinator.textView = textView
        textView.attachmentChangeHandler = { [weak coordinator = context.coordinator] in
            coordinator?.tableDidChange()
        }
        textView.attachmentDeleteHandler = { [weak coordinator = context.coordinator] attachment in
            coordinator?.deleteTable(attachment)
        }
        context.coordinator.render(markdown: text, preservingSelection: false)
        context.coordinator.applyStyles(immediately: true)
        scrollView.documentView = textView
        DispatchQueue.main.async { textView.updateTableOverlays() }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownTextView else { return }
        context.coordinator.text = $text
        textView.textContainerInset = compact
            ? NSSize(width: 16, height: 18)
            : NSSize(width: 32, height: 26)
        DispatchQueue.main.async { textView.updateTableOverlays() }
        if context.coordinator.lastMarkdown != text {
            context.coordinator.render(markdown: text, preservingSelection: true)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        fileprivate weak var textView: MarkdownTextView?
        var isApplyingExternalUpdate = false
        fileprivate var lastMarkdown = ""
        private var stylingWorkItem: DispatchWorkItem?

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalUpdate, let textView else { return }
            let markdown = MarkdownTableDocumentCodec.markdown(from: textView.attributedString())
            lastMarkdown = markdown
            text.wrappedValue = markdown
            applyStyles(immediately: false)
        }

        func tableDidChange() {
            guard !isApplyingExternalUpdate, let textView else { return }
            let markdown = MarkdownTableDocumentCodec.markdown(from: textView.attributedString())
            lastMarkdown = markdown
            text.wrappedValue = markdown
            textView.updateTableOverlays()
        }

        func render(markdown: String, preservingSelection: Bool) {
            guard let textView else { return }
            let selection = textView.selectedRange()
            isApplyingExternalUpdate = true
            textView.textStorage?.setAttributedString(
                MarkdownTableDocumentCodec.attributedString(
                    from: markdown,
                    onTableChange: { [weak self] in self?.tableDidChange() },
                    onTableDelete: { [weak self] attachment in self?.deleteTable(attachment) }
                )
            )
            lastMarkdown = markdown
            if preservingSelection {
                let length = textView.attributedString().length
                textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            }
            isApplyingExternalUpdate = false
            applyStyles(immediately: true)
        }

        func deleteTable(_ attachment: MarkdownTableAttachment) {
            guard let textView, let storage = textView.textStorage else { return }
            var targetRange: NSRange?
            storage.enumerateAttribute(
                .attachment,
                in: NSRange(location: 0, length: storage.length)
            ) { value, range, stop in
                if let value = value as? MarkdownTableAttachment, value === attachment {
                    targetRange = range
                    stop.pointee = true
                }
            }
            guard let targetRange,
                  textView.shouldChangeText(in: targetRange, replacementString: "") else { return }
            storage.replaceCharacters(in: targetRange, with: "")
            textView.didChangeText()
        }

        func applyStyles(immediately: Bool) {
            stylingWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let textView = self.textView else { return }
                MarkdownInlineStyler.apply(to: textView)
                textView.updateTableOverlays()
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

@MainActor
final class MarkdownEditorFocus {
    static let shared = MarkdownEditorFocus()
    weak var editor: MarkdownTextView?
}

@MainActor
enum MarkdownEditorActions {
    private static func withEditor(_ action: (MarkdownTextView) -> Void) {
        guard let editor = MarkdownEditorFocus.shared.editor, editor.window != nil else { return }
        editor.window?.makeFirstResponder(editor)
        action(editor)
    }

    static func heading(_ level: Int) { withEditor { $0.applyHeading(level: level) } }
    static func bold() { withEditor { $0.toggleBold() } }
    static func italic() { withEditor { $0.toggleItalic() } }
    static func link() { withEditor { $0.editLink() } }
    static func table() { withEditor { $0.insertTable() } }
    static func insert(_ markdown: String) { withEditor { $0.insertMarkdownBlock(markdown) } }
}

final class MarkdownTextView: NSTextView {
    var attachmentChangeHandler: (() -> Void)?
    var attachmentDeleteHandler: ((MarkdownTableAttachment) -> Void)?
    private var tableOverlays: [ObjectIdentifier: MarkdownNativeTableView] = [:]

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder { MarkdownEditorFocus.shared.editor = self }
        return becameFirstResponder
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        DispatchQueue.main.async { [weak self] in self?.updateTableOverlays() }
    }

    func updateTableOverlays() {
        guard let storage = textStorage,
              let layoutManager,
              let textContainer else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        var active: Set<ObjectIdentifier> = []
        layoutManager.ensureLayout(for: textContainer)
        storage.enumerateAttribute(.attachment, in: fullRange) { [weak self] value, range, _ in
            guard let self, let attachment = value as? MarkdownTableAttachment else { return }
            let identifier = ObjectIdentifier(attachment)
            active.insert(identifier)
            let tableView: MarkdownNativeTableView
            if let existing = self.tableOverlays[identifier] {
                tableView = existing
            } else {
                tableView = MarkdownNativeTableView(table: attachment.table)
                tableView.onChange = { [weak attachment] in attachment?.onChange?() }
                tableView.onDelete = { [weak attachment] in attachment?.onDelete?() }
                tableView.onSizeChange = { [weak self] in
                    self?.layoutManager?.invalidateLayout(
                        forCharacterRange: range,
                        actualCharacterRange: nil
                    )
                    DispatchQueue.main.async { self?.updateTableOverlays() }
                }
                self.addSubview(tableView, positioned: .above, relativeTo: nil)
                self.tableOverlays[identifier] = tableView
            }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: range,
                actualCharacterRange: nil
            )
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.x = self.textContainerOrigin.x
            rect.origin.y += self.textContainerOrigin.y
            rect.size.width = max(260, textContainer.size.width)
            rect.size.height = tableView.preferredHeight
            tableView.frame = rect.integral
        }
        for (identifier, view) in tableOverlays where !active.contains(identifier) {
            view.removeFromSuperview()
            tableOverlays.removeValue(forKey: identifier)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command, let character = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch character {
        case "b":
            toggleBold()
            return true
        case "i":
            toggleItalic()
            return true
        case "k":
            editLink()
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

    func toggleBold() {
        wrapSelection(prefix: "**", suffix: "**", placeholder: "bold text")
    }

    func toggleItalic() {
        wrapSelection(prefix: "*", suffix: "*", placeholder: "italic text")
    }

    func applyHeading(level: Int) {
        let boundedLevel = min(max(level, 1), 6)
        let source = string as NSString
        let selection = selectedRange()
        let lineRange = source.lineRange(for: NSRange(location: selection.location, length: 0))
        let rawLine = source.substring(with: lineRange).trimmingCharacters(in: .newlines)
        let cleanLine = rawLine.replacingOccurrences(
            of: #"^#{1,6}[ \t]+"#,
            with: "",
            options: .regularExpression
        )
        let replacement = String(repeating: "#", count: boundedLevel) + " " + (cleanLine.isEmpty ? "Heading" : cleanLine)
        replaceAndSelect(
            range: NSRange(location: lineRange.location, length: rawLine.utf16.count),
            replacement: replacement,
            selectionOffset: boundedLevel + 1,
            selectionLength: (replacement as NSString).length - boundedLevel - 1
        )
    }

    func insertMarkdownBlock(_ markdown: String) {
        let selection = selectedRange()
        let source = string as NSString
        let needsLeadingBreak = selection.location > 0
            && source.substring(with: NSRange(location: selection.location - 1, length: 1)) != "\n"
        let needsTrailingBreak = selection.location + selection.length < source.length
            && source.substring(with: NSRange(location: selection.location + selection.length, length: 1)) != "\n"
        let insertion = (needsLeadingBreak ? "\n" : "") + markdown + (needsTrailingBreak ? "\n" : "")
        replaceAndSelect(
            range: selection,
            replacement: insertion,
            selectionOffset: needsLeadingBreak ? 1 : 0,
            selectionLength: markdown.utf16.count
        )
    }

    func insertTable() {
        let selection = selectedRange()
        let source = string as NSString
        let needsLeadingBreak = selection.location > 0
            && source.substring(with: NSRange(location: selection.location - 1, length: 1)) != "\n"
        let needsTrailingBreak = selection.location + selection.length < source.length
            && source.substring(with: NSRange(location: selection.location + selection.length, length: 1)) != "\n"
        let table = MarkdownTableData(
            headers: ["Column 1", "Column 2", "Column 3"],
            alignments: [.leading, .leading, .leading],
            rows: [["", "", ""], ["", "", ""]]
        )
        let attachment = MarkdownTableAttachment(table: table)
        attachment.onChange = { [weak self] in self?.attachmentChangeHandler?() }
        attachment.onDelete = { [weak self, weak attachment] in
            guard let attachment else { return }
            self?.attachmentDeleteHandler?(attachment)
        }
        let insertion = NSMutableAttributedString()
        if needsLeadingBreak { insertion.append(NSAttributedString(string: "\n")) }
        insertion.append(NSAttributedString(attachment: attachment))
        if needsTrailingBreak { insertion.append(NSAttributedString(string: "\n")) }
        guard shouldChangeText(in: selection, replacementString: insertion.string) else { return }
        textStorage?.replaceCharacters(in: selection, with: insertion)
        didChangeText()
        setSelectedRange(NSRange(location: selection.location + insertion.length, length: 0))
    }

    func editLink() {
        let selection = selectedRange()
        let source = string as NSString
        let selectedText = selection.length > 0 ? source.substring(with: selection) : "Link title"
        let field = NSTextField(string: "https://")
        field.placeholderString = "https://example.com"
        field.setAccessibilityLabel("Link destination")
        let alert = NSAlert()
        alert.messageText = "Add Link"
        alert.informativeText = "Enter the destination for “\(String(selectedText.prefix(80)))”."
        alert.accessoryView = field
        alert.addButton(withTitle: "Add Link")
        alert.addButton(withTitle: "Cancel")
        let complete: (NSApplication.ModalResponse) -> Void = { [weak self, weak field] response in
            guard response == .alertFirstButtonReturn, let self, let field else { return }
            let destination = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let components = URLComponents(string: destination),
                  let scheme = components.scheme?.lowercased(),
                  ["https", "http", "mailto"].contains(scheme) else {
                NSSound.beep()
                return
            }
            let replacement = "[\(selectedText)](\(destination))"
            self.replaceAndSelect(
                range: selection,
                replacement: replacement,
                selectionOffset: 1,
                selectionLength: selectedText.utf16.count
            )
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: complete)
        } else {
            complete(alert.runModal())
        }
    }

    private func wrapSelection(prefix: String, suffix: String, placeholder: String) {
        let selection = selectedRange()
        let source = string as NSString
        let selectedText = selection.length > 0 ? source.substring(with: selection) : placeholder
        let replacement = prefix + selectedText + suffix
        replaceAndSelect(
            range: selection,
            replacement: replacement,
            selectionOffset: prefix.utf16.count,
            selectionLength: selectedText.utf16.count
        )
    }

    private func replaceAndSelect(
        range: NSRange,
        replacement: String,
        selectionOffset: Int,
        selectionLength: Int
    ) {
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + selectionOffset, length: selectionLength))
    }

}

private enum MarkdownInlineStyler {
    private static let baseFont = NSFont.systemFont(ofSize: 15.5)
    private static let monoFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    private static let codeBackground = NSColor.controlBackgroundColor.withAlphaComponent(0.78)
    private static let hiddenMarkerFont = NSFont.systemFont(ofSize: 0.1)

    static func apply(to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let source = storage.string as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        let selection = textView.selectedRanges
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3.5
        paragraph.paragraphSpacing = 7
        let fencedCodePattern = #"(?ms)^```([^\n]*)\n(.*?)^```[ \t]*$"#
        let fencedCodeMatches = matches(pattern: fencedCodePattern, in: source)
        let fencedCodeRanges = fencedCodeMatches.map(\.range)
        var attachments: [(range: NSRange, value: Any)] = []
        storage.enumerateAttribute(.attachment, in: fullRange) { value, range, _ in
            if let value { attachments.append((range, value)) }
        }

        storage.beginEditing()
        storage.setAttributes([
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ], range: fullRange)
        for attachment in attachments {
            storage.addAttribute(.attachment, value: attachment.value, range: attachment.range)
        }

        apply(pattern: #"(?m)^(#{1,6})[ \t]+(.+)$"#, to: source) { match in
            guard !intersects(match.range, any: fencedCodeRanges) else { return }
            let level = min(max(match.range(at: 1).length, 1), 6)
            let sizes: [CGFloat] = [28, 24, 21, 18, 16, 15]
            let contentRange = match.range(at: 2)
            let headingParagraph = paragraph.mutableCopy() as! NSMutableParagraphStyle
            headingParagraph.paragraphSpacingBefore = level <= 2 ? 12 : 8
            headingParagraph.paragraphSpacing = level <= 2 ? 9 : 6
            storage.addAttributes([
                .font: NSFont.systemFont(ofSize: sizes[level - 1], weight: level <= 3 ? .bold : .semibold),
                .paragraphStyle: headingParagraph
            ], range: contentRange)
            let markerRange = NSRange(location: match.range.location, length: contentRange.location - match.range.location)
            hideMarkers(markerRange, in: storage)
        }

        for match in fencedCodeMatches {
            let contentRange = match.range(at: 2)
            let codeParagraph = paragraph.mutableCopy() as! NSMutableParagraphStyle
            codeParagraph.firstLineHeadIndent = 12
            codeParagraph.headIndent = 12
            codeParagraph.tailIndent = -12
            codeParagraph.paragraphSpacing = 1
            storage.addAttributes([
                .font: monoFont,
                .backgroundColor: codeBackground,
                .paragraphStyle: codeParagraph
            ], range: contentRange)
            let openingRange = NSRange(
                location: match.range.location,
                length: max(0, contentRange.location - match.range.location)
            )
            let closingRange = NSRange(
                location: NSMaxRange(contentRange),
                length: max(0, NSMaxRange(match.range) - NSMaxRange(contentRange))
            )
            hideMarkers(openingRange, in: storage)
            hideMarkers(closingRange, in: storage)
        }

        apply(pattern: #"`([^`\n]+)`"#, to: source) { match in
            guard !intersects(match.range, any: fencedCodeRanges) else { return }
            let contentRange = match.range(at: 1)
            storage.addAttributes([.font: monoFont, .backgroundColor: codeBackground], range: contentRange)
            styleMarkers(around: contentRange, in: match.range, storage: storage)
        }

        apply(pattern: #"\*\*([^*\n]+)\*\*|__([^_\n]+)__"#, to: source) { match in
            guard !intersects(match.range, any: fencedCodeRanges) else { return }
            let contentRange = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 15, weight: .bold), range: contentRange)
            styleMarkers(around: contentRange, in: match.range, storage: storage)
        }
        apply(pattern: #"(?<!\*)\*([^*\n]+)\*(?!\*)|(?<!_)_([^_\n]+)_(?!_)"#, to: source) { match in
            guard !intersects(match.range, any: fencedCodeRanges) else { return }
            let contentRange = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
            let italic = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
            storage.addAttribute(.font, value: italic, range: contentRange)
            styleMarkers(around: contentRange, in: match.range, storage: storage)
        }

        apply(pattern: #"\[([^\]]+)\]\(([^)]+)\)"#, to: source) { match in
            guard !intersects(match.range, any: fencedCodeRanges) else { return }
            let labelRange = match.range(at: 1)
            let destinationRange = match.range(at: 2)
            storage.addAttributes([.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: labelRange)
            styleMarkers(around: labelRange, in: match.range, storage: storage)
            if let url = URL(string: source.substring(with: destinationRange)) {
                storage.addAttribute(.link, value: url, range: labelRange)
            }
        }

        apply(pattern: #"(?m)^(\s*)([-*+]|\d+[.)])\s+"#, to: source) { match in
            guard !intersects(match.range, any: fencedCodeRanges) else { return }
            storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: match.range)
        }
        apply(pattern: #"(?m)^(\s*)- \[([ xX])\]\s+(.*)$"#, to: source) { match in
            guard !intersects(match.range, any: fencedCodeRanges) else { return }
            let checked = source.substring(with: match.range(at: 2)).lowercased() == "x"
            storage.addAttribute(.foregroundColor, value: checked ? NSColor.systemGreen : NSColor.controlAccentColor, range: NSRange(location: match.range.location, length: match.range(at: 3).location - match.range.location))
            if checked {
                storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.secondaryLabelColor], range: match.range(at: 3))
            }
        }
        apply(pattern: #"(?m)^(\s*>\s?)(.*)$"#, to: source) { match in
            guard !intersects(match.range, any: fencedCodeRanges) else { return }
            storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: match.range(at: 1))
            let italic = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
            storage.addAttributes([.font: italic, .foregroundColor: NSColor.secondaryLabelColor], range: match.range(at: 2))
        }
        apply(pattern: #"(?m)^(---|\*\*\*|___)[ \t]*$"#, to: source) { match in
            guard !intersects(match.range, any: fencedCodeRanges) else { return }
            storage.addAttributes([
                .foregroundColor: NSColor.separatorColor,
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .kern: 2.2
            ], range: match.range)
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

    private static func matches(pattern: String, in source: NSString) -> [NSTextCheckingResult] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(
            in: source as String,
            range: NSRange(location: 0, length: source.length)
        )
    }

    private static func intersects(_ range: NSRange, any excludedRanges: [NSRange]) -> Bool {
        excludedRanges.contains { NSIntersectionRange(range, $0).length > 0 }
    }

    private static func styleMarkers(
        around content: NSRange,
        in full: NSRange,
        storage: NSTextStorage
    ) {
        let prefixLength = content.location - full.location
        let suffixLength = NSMaxRange(full) - NSMaxRange(content)
        if prefixLength > 0 {
            hideMarkers(NSRange(location: full.location, length: prefixLength), in: storage)
        }
        if suffixLength > 0 {
            hideMarkers(NSRange(location: NSMaxRange(content), length: suffixLength), in: storage)
        }
    }

    private static func hideMarkers(_ range: NSRange, in storage: NSTextStorage) {
        guard range.location != NSNotFound, range.length > 0 else { return }
        storage.addAttributes([
            .foregroundColor: NSColor.clear,
            .font: hiddenMarkerFont,
            .kern: -0.1
        ], range: range)
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
