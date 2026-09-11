import AppKit
import RayPlacementCore
import RayPlacementWriting
import SwiftUI
import UniformTypeIdentifiers

struct InlineMarkdownEditor: NSViewRepresentable {
    @ObservedObject private var typography = AppTypography.shared
    @Binding var text: String
    var compact = false
    @Binding var scrollOffset: CGFloat
    var fontStyle: NotesFontStyle = .system
    var fontSize: Double = 15.5
    var lineSpacing: Double = 3.5
    var theme: NotesVisualTheme = .prism
    var inlineGrammarCheckingEnabled: Bool = true
    var editable: Bool = true
    var wikiLinkCandidates: [MarkdownNote] = []

    init(
        text: Binding<String>,
        compact: Bool = false,
        scrollOffset: Binding<CGFloat> = .constant(0),
        fontStyle: NotesFontStyle = .system,
        fontSize: Double = 15.5,
        lineSpacing: Double = 3.5,
        theme: NotesVisualTheme = .prism,
        inlineGrammarCheckingEnabled: Bool = true,
        editable: Bool = true,
        wikiLinkCandidates: [MarkdownNote] = []
    ) {
        _text = text
        self.compact = compact
        _scrollOffset = scrollOffset
        self.fontStyle = fontStyle
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.theme = theme
        self.inlineGrammarCheckingEnabled = inlineGrammarCheckingEnabled
        self.editable = editable
        self.wikiLinkCandidates = wikiLinkCandidates
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, fontStyle: fontStyle, fontSize: fontSize, lineSpacing: lineSpacing, theme: theme, inlineGrammarCheckingEnabled: inlineGrammarCheckingEnabled, editable: editable, wikiLinkCandidates: wikiLinkCandidates)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NotesEditorPalette(theme: theme).background

        let textView = MarkdownTextView()
        textView.delegate = context.coordinator
        textView.isEditable = editable
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        // Lima owns grammar annotations so Markdown syntax, attachments, and
        // protected technical terms are handled consistently.
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.inlineGrammarCheckingEnabled = inlineGrammarCheckingEnabled
        textView.wikiLinkCandidates = wikiLinkCandidates
        textView.isEditable = editable
        scrollView.backgroundColor = NotesEditorPalette(theme: theme).background
        textView.backgroundColor = NotesEditorPalette(theme: theme).background
        textView.insertionPointColor = NotesEditorPalette(theme: theme).accent
        textView.selectedTextAttributes = NotesEditorPalette(theme: theme).selectionAttributes
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
        context.coordinator.scrollView = scrollView
        context.coordinator.scrollOffset = $scrollOffset
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak coordinator = context.coordinator, weak scrollView] _ in
            guard let coordinator, let scrollView else { return }
            Task { @MainActor in
                coordinator.captureScrollOffset(from: scrollView)
            }
        }
        textView.attachmentChangeHandler = { [weak coordinator = context.coordinator] in
            coordinator?.tableDidChange()
        }
        textView.attachmentDeleteHandler = { [weak coordinator = context.coordinator] attachment in
            coordinator?.deleteTable(attachment)
        }
        textView.documentChangeHandler = { [weak coordinator = context.coordinator] in
            coordinator?.tableDidChange()
        }
        textView.richContentRenderHandler = { [weak coordinator = context.coordinator] in
            coordinator?.rerenderCurrentDocument()
        }
        textView.wikiLinkCandidates = wikiLinkCandidates
        textView.registerForDraggedTypes([.fileURL, .string, .tiff, .png, NSPasteboard.PasteboardType(ContextShelfIntegration.itemUTType.identifier)])
        context.coordinator.render(markdown: text, preservingSelection: false)
        context.coordinator.applyStyles(immediately: true)
        scrollView.documentView = textView
        DispatchQueue.main.async {
            textView.updateTableOverlays()
            context.coordinator.applyScrollOffset()
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownTextView else { return }
        context.coordinator.text = $text
        context.coordinator.scrollOffset = $scrollOffset
        let styleChanged = context.coordinator.fontStyle != fontStyle
            || context.coordinator.fontSize != fontSize
            || context.coordinator.lineSpacing != lineSpacing
            || context.coordinator.theme != theme
        context.coordinator.fontStyle = fontStyle
        context.coordinator.fontSize = fontSize
        context.coordinator.lineSpacing = lineSpacing
        context.coordinator.theme = theme
        let inlineGrammarSettingChanged = context.coordinator.inlineGrammarCheckingEnabled != inlineGrammarCheckingEnabled
        context.coordinator.inlineGrammarCheckingEnabled = inlineGrammarCheckingEnabled
        context.coordinator.editable = editable
        context.coordinator.wikiLinkCandidates = wikiLinkCandidates
        textView.inlineGrammarCheckingEnabled = inlineGrammarCheckingEnabled
        if inlineGrammarSettingChanged {
            if inlineGrammarCheckingEnabled {
                context.coordinator.scheduleInlineGrammarCheckForUpdate()
            } else {
                context.coordinator.cancelInlineGrammarCheckForUpdate()
            }
        }
        let palette = NotesEditorPalette(theme: theme)
        scrollView.drawsBackground = true
        scrollView.backgroundColor = palette.background
        textView.drawsBackground = true
        textView.backgroundColor = palette.background
        textView.insertionPointColor = palette.accent
        textView.selectedTextAttributes = palette.selectionAttributes
        textView.textContainerInset = compact
            ? NSSize(width: 16, height: 18)
            : NSSize(width: 32, height: 26)
        DispatchQueue.main.async { textView.updateTableOverlays() }
        if context.coordinator.lastMarkdown != text {
            context.coordinator.render(markdown: text, preservingSelection: true)
        }
        DispatchQueue.main.async { context.coordinator.applyScrollOffset() }
        if context.coordinator.lastTextScale != typography.scale || styleChanged {
            context.coordinator.lastTextScale = typography.scale
            context.coordinator.applyStyles(immediately: true)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var scrollOffset: Binding<CGFloat>
        fileprivate weak var textView: MarkdownTextView?
        fileprivate weak var scrollView: NSScrollView?
        var boundsObserver: NSObjectProtocol?
        var isApplyingExternalUpdate = false
        fileprivate var lastMarkdown = ""
        fileprivate var lastTextScale = AppTypography.shared.scale
        var fontStyle: NotesFontStyle
        var fontSize: Double
        var lineSpacing: Double
        var theme: NotesVisualTheme
        var inlineGrammarCheckingEnabled: Bool
        var editable: Bool
        var wikiLinkCandidates: [MarkdownNote]
        private var stylingWorkItem: DispatchWorkItem?
        private var grammarWorkItem: DispatchWorkItem?
        private var grammarGeneration = 0
        private var grammarChecker: RuleBasedWritingChecker?

        init(text: Binding<String>, fontStyle: NotesFontStyle, fontSize: Double, lineSpacing: Double, theme: NotesVisualTheme, inlineGrammarCheckingEnabled: Bool, editable: Bool, wikiLinkCandidates: [MarkdownNote]) {
            self.text = text
            self.scrollOffset = .constant(0)
            self.fontStyle = fontStyle
            self.fontSize = fontSize
            self.lineSpacing = lineSpacing
            self.theme = theme
            self.inlineGrammarCheckingEnabled = inlineGrammarCheckingEnabled
            self.editable = editable
            self.wikiLinkCandidates = wikiLinkCandidates
            self.grammarChecker = RuleBasedWritingChecker()
        }

        deinit {
            grammarWorkItem?.cancel()
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        }

        func captureScrollOffset(from scrollView: NSScrollView) {
            guard scrollView.contentView.bounds.origin.y.isFinite else { return }
            scrollOffset.wrappedValue = max(0, scrollView.contentView.bounds.origin.y)
        }

        func applyScrollOffset() {
            guard let scrollView else { return }
            let target = max(0, scrollOffset.wrappedValue)
            guard abs(scrollView.contentView.bounds.origin.y - target) > 0.5 else { return }
            var bounds = scrollView.contentView.bounds
            let documentHeight = scrollView.documentView?.frame.height ?? 0
            let maximum = max(0, documentHeight - scrollView.contentView.bounds.height)
            bounds.origin.y = min(target, maximum)
            scrollView.contentView.setBoundsOrigin(bounds.origin)
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalUpdate, let textView else { return }
            let markdown = MarkdownTableDocumentCodec.markdown(from: textView.attributedString())
            lastMarkdown = markdown
            text.wrappedValue = markdown
            applyStyles(immediately: false)
            scheduleInlineGrammarCheck()
        }

        func tableDidChange() {
            guard !isApplyingExternalUpdate, let textView else { return }
            let markdown = MarkdownTableDocumentCodec.markdown(from: textView.attributedString())
            lastMarkdown = markdown
            text.wrappedValue = markdown
            textView.updateTableOverlays()
            applyStyles(immediately: true)
            scheduleInlineGrammarCheck()
        }

        func rerenderCurrentDocument() {
            cancelInlineGrammarCheck()
            guard let textView else { return }
            let markdown = MarkdownTableDocumentCodec.markdown(from: textView.attributedString())
            lastMarkdown = markdown
            text.wrappedValue = markdown
            DispatchQueue.main.async { [weak self] in
                self?.render(markdown: markdown, preservingSelection: true)
            }
        }

        func scheduleInlineGrammarCheckForUpdate() {
            scheduleInlineGrammarCheck()
        }

        func cancelInlineGrammarCheckForUpdate() {
            cancelInlineGrammarCheck()
        }

        private func cancelInlineGrammarCheck() {
            grammarGeneration += 1
            grammarWorkItem?.cancel()
            grammarWorkItem = nil
            grammarChecker?.cancel()
            textView?.clearGrammarAnnotations()
        }

        private func scheduleInlineGrammarCheck() {
            grammarGeneration += 1
            let generation = grammarGeneration
            grammarWorkItem?.cancel()
            grammarChecker?.cancel()
            guard inlineGrammarCheckingEnabled, let textView else {
                textView?.clearGrammarAnnotations()
                return
            }
            let source = textView.string
            let selection = textView.selectedRange()
            let nsSource = source as NSString
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  nsSource.length > 0 else {
                textView.clearGrammarAnnotations()
                return
            }
            let location = min(selection.location, nsSource.length)
            let paragraphRange = nsSource.paragraphRange(for: NSRange(location: location, length: 0))
            let paragraph = nsSource.substring(with: paragraphRange)
                .trimmingCharacters(in: .newlines)
            guard paragraph.count >= 3,
                  !paragraph.contains("```") else {
                textView.clearGrammarAnnotations()
                return
            }
            var workItem: DispatchWorkItem!
            workItem = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView, !workItem.isCancelled, self.grammarGeneration == generation else { return }
                self.grammarChecker?.checkLocal(paragraph, progress: { _ in }) { [weak self, weak textView] result in
                    guard let textView, !workItem.isCancelled, self?.grammarGeneration == generation, textView.string == source else { return }
                    switch result {
                    case .success(let review):
                        let offset = paragraphRange.location
                        textView.applyGrammarAnnotations(review.issues, offset: offset)
                    case .failure:
                        textView.clearGrammarAnnotations()
                    }
                }
            }
            grammarWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: workItem)
        }

        func render(markdown: String, preservingSelection: Bool) {
            guard let textView else { return }
            let selection = textView.selectedRange()
            isApplyingExternalUpdate = true
            let tables = MarkdownTableDocumentCodec.attributedString(
                    from: markdown,
                    onTableChange: { [weak self] in self?.tableDidChange() },
                    onTableDelete: { [weak self] attachment in self?.deleteTable(attachment) }
                )
            textView.textStorage?.setAttributedString(
                MarkdownRichDocumentCodec.enrich(tables) { [weak self] in self?.tableDidChange() }
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
                MarkdownInlineStyler.apply(
                    to: textView,
                    fontStyle: self.fontStyle,
                    fontSize: self.fontSize,
                    lineSpacing: self.lineSpacing,
                    theme: self.theme
                )
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
    static func image() { withEditor { $0.chooseImage() } }
    static func chart() { withEditor { $0.insertChart() } }
    static func checklist() { withEditor { $0.applyListPrefix("- [ ] ") } }
    static func bullets() { withEditor { $0.applyListPrefix("- ") } }
    static func insert(_ markdown: String) { withEditor { $0.insertMarkdownBlock(markdown) } }
    static func scrollToLine(_ line: Int) { withEditor { $0.scrollToLine(line) } }
    static func slashCommand(_ command: MarkdownNoteSlashCommand) { withEditor { $0.insertSlashCommand(command) } }
}

final class MarkdownTextView: NSTextView {
    var attachmentChangeHandler: (() -> Void)?
    var attachmentDeleteHandler: ((MarkdownTableAttachment) -> Void)?
    var documentChangeHandler: (() -> Void)?
    var richContentRenderHandler: (() -> Void)?
    private var tableOverlays: [ObjectIdentifier: MarkdownNativeTableView] = [:]
    var inlineGrammarCheckingEnabled = true
    var wikiLinkCandidates: [MarkdownNote] = []
    private var popupMenu: NSMenu?

    func clearGrammarAnnotations() {
        guard let layoutManager, let textStorage else { return }
        let range = NSRange(location: 0, length: textStorage.length)
        layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: range)
        layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: range)
    }

    func applyGrammarAnnotations(_ issues: [WritingIssue], offset: Int) {
        guard let layoutManager, let textStorage else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: fullRange)
        layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: fullRange)
        for issue in issues {
            let location = offset + issue.range.location
            guard issue.range.length > 0, location >= 0, location + issue.range.length <= textStorage.length else { continue }
            layoutManager.addTemporaryAttributes([
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: NSColor.systemOrange
            ], forCharacterRange: NSRange(location: location, length: issue.range.length))
        }
    }

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

    func scrollToLine(_ line: Int) {
        let lines = string.components(separatedBy: .newlines)
        let clamped = min(max(0, line), max(0, lines.count - 1))
        let location = lines.prefix(clamped).reduce(0) { $0 + $1.utf16.count + 1 }
        setSelectedRange(NSRange(location: min(location, (string as NSString).length), length: 0))
        scrollRangeToVisible(selectedRange())
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        super.insertText(insertString, replacementRange: replacementRange)
        guard isEditable else { return }
        DispatchQueue.main.async { [weak self] in self?.offerInlineCommandIfNeeded() }
    }

    private func offerInlineCommandIfNeeded() {
        let source = string as NSString
        let cursor = min(selectedRange().location, source.length)
        let lineRange = source.lineRange(for: NSRange(location: cursor, length: 0))
        let line = source.substring(with: lineRange)
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") && !trimmed.contains(" ") && !trimmed.contains("\t") {
            let prefix = String(trimmed.dropFirst()).lowercased()
            let commands = MarkdownNoteSlashCommand.allCases.filter { prefix.isEmpty || $0.rawValue.hasPrefix(prefix) }
            guard !commands.isEmpty else { return }
            let menu = NSMenu(title: "Slash Commands")
            for command in commands {
                let item = NSMenuItem(title: "/\(command.rawValue)", action: #selector(performSlashCommand(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = command.rawValue
                item.toolTip = command.detail
                menu.addItem(item)
            }
            popupMenu = menu
            let rect = firstRect(forCharacterRange: NSRange(location: cursor, length: 0), actualRange: nil)
            menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.minY), in: self)
            return
        }

        guard !wikiLinkCandidates.isEmpty else { return }
        let before = source.substring(to: cursor)
        guard let opening = before.range(of: "[[", options: .backwards) else { return }
        let start = before.utf16.distance(from: before.startIndex, to: opening.lowerBound)
        let prefix = before.substring(from: opening.upperBound)
        guard !prefix.contains("]") else { return }
        let candidates = MarkdownNoteAnalysis.wikiLinkSuggestions(in: string, prefix: prefix, candidates: wikiLinkCandidates)
        guard !candidates.isEmpty else { return }
        let menu = NSMenu(title: "Wiki Links")
        for note in candidates {
            let item = NSMenuItem(title: note.displayTitle, action: #selector(performWikiLink(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = note.displayTitle
            menu.addItem(item)
        }
        popupMenu = menu
        let rect = firstRect(forCharacterRange: NSRange(location: cursor, length: 0), actualRange: nil)
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.minY), in: self)
    }

    @objc private func performSlashCommand(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let command = MarkdownNoteSlashCommand(rawValue: raw) else { return }
        let source = string as NSString
        let cursor = min(selectedRange().location, source.length)
        let lineRange = source.lineRange(for: NSRange(location: cursor, length: 0))
        let line = source.substring(with: lineRange)
        guard let slash = line.firstIndex(of: "/") else { return }
        let offset = line.utf16.distance(from: line.startIndex, to: slash)
        replaceAndSelect(range: NSRange(location: lineRange.location + offset, length: cursor - lineRange.location - offset), replacement: command.markdown, selectionOffset: 0, selectionLength: command.markdown.utf16.count)
        popupMenu = nil
    }

    @objc private func performWikiLink(_ sender: NSMenuItem) {
        guard let title = sender.representedObject as? String else { return }
        let source = string as NSString
        let cursor = min(selectedRange().location, source.length)
        let before = source.substring(to: cursor)
        guard let opening = before.range(of: "[[", options: .backwards) else { return }
        let start = before.utf16.distance(from: before.startIndex, to: opening.lowerBound)
        replaceAndSelect(range: NSRange(location: start, length: cursor - start), replacement: "[[\(title)]]", selectionOffset: title.utf16.count + 4, selectionLength: 0)
        popupMenu = nil
    }

    func insertSlashCommand(_ command: MarkdownNoteSlashCommand) {
        let insertion = command.markdown
        replaceAndSelect(range: selectedRange(), replacement: insertion, selectionOffset: 0, selectionLength: insertion.utf16.count)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isEditable ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isEditable else { return false }
        let pasteboard = sender.draggingPasteboard
        let shelfType = NSPasteboard.PasteboardType(ContextShelfIntegration.itemUTType.identifier)
        if let data = pasteboard.data(forType: shelfType),
           let rawID = String(data: data, encoding: .utf8),
           let id = UUID(uuidString: rawID),
           let item = ContextShelfStore.shared.items.first(where: { $0.id == id }) {
            insertMarkdownBlock(ContextShelfMarkdownFormatter.format(item))
            return true
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let markdown = urls.map { url in
                if let image = NSImage(contentsOf: url), let reference = MarkdownNoteAssetStore.importImage(image) {
                    return "![\(url.deletingPathExtension().lastPathComponent)](\(reference))"
                }
                return "[\(url.lastPathComponent)](\(url.absoluteString))"
            }.joined(separator: "\n")
            insertMarkdownBlock(markdown)
            return true
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            insertPlainText(text)
            return true
        }
        return false
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

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general

        // Text always wins over image representations. Emoji and rich text
        // pasteboards can advertise image flavors as well as Unicode text;
        // checking NSImage first silently converted valid text into an image.
        if let plainText = PlainTextPastePolicy.normalize(pasteboard.string(forType: .string)) {
            if let table = TabularDataParser.parse(
                text: plainText,
                html: pasteboard.string(forType: .html)
            ), table.rows.count > 1 {
                insertTable(table)
            } else {
                insertPlainText(plainText)
            }
            return
        }

        if let html = pasteboard.string(forType: .html),
           let attributed = try? NSAttributedString(
               data: Data(html.utf8),
               options: [
                   .documentType: NSAttributedString.DocumentType.html,
                   .characterEncoding: String.Encoding.utf8.rawValue
               ],
               documentAttributes: nil
           ),
           let htmlText = PlainTextPastePolicy.normalize(attributed.string) {
            if let table = TabularDataParser.parse(text: htmlText, html: html), table.rows.count > 1 {
                insertTable(table)
            } else {
                insertPlainText(htmlText)
            }
            return
        }

        // An image is valid only when the pasteboard has no usable text.
        if let image = NSImage(pasteboard: pasteboard), insertImage(image, alt: "Pasted image") {
            return
        }

        // Keep AppKit's fallback for pasteboard types that are neither text nor
        // images, but never use it for ordinary text: NSTextView is rich-text
        // enabled and would otherwise import HTML/RTF formatting into Markdown.
        super.paste(sender)
    }

    private func insertPlainText(_ text: String) {
        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if let layoutManager, let textContainer {
            var point = local
            point.x -= textContainerOrigin.x
            point.y -= textContainerOrigin.y
            let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
            let character = layoutManager.characterIndexForGlyph(at: glyph)
            if character < attributedString().length,
               let task = attributedString().attribute(.attachment, at: character, effectiveRange: nil) as? MarkdownTaskAttachment {
                task.toggle()
                layoutManager.invalidateDisplay(forCharacterRange: NSRange(location: character, length: 1))
                return
            }
            if event.clickCount == 2, character < attributedString().length,
               let media = attributedString().attribute(.attachment, at: character, effectiveRange: nil) as? MarkdownMediaAttachment {
                let range = NSRange(location: character, length: 1)
                guard shouldChangeText(in: range, replacementString: media.markdownSource) else { return }
                textStorage?.replaceCharacters(in: range, with: media.markdownSource)
                didChangeText()
                setSelectedRange(NSRange(location: character, length: (media.markdownSource as NSString).length))
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        let source = string as NSString
        let selection = selectedRange()
        let lineRange = source.lineRange(for: NSRange(location: selection.location, length: 0))
        let line = source.substring(with: lineRange).trimmingCharacters(in: .newlines)

        // `line` has already had its paragraph terminator removed. Derive the
        // terminator from the original storage instead of checking the
        // trimmed value; otherwise the semantic path can mistake the caret
        // before CRLF/LF for a mid-line caret and skip continuation entirely.
        let lineEnd = NSMaxRange(lineRange)
        let lineTerminator: String
        if lineRange.length >= 2,
           source.substring(with: NSRange(location: lineEnd - 2, length: 2)) == "\r\n" {
            lineTerminator = "\r\n"
        } else if lineRange.length >= 1,
                  source.character(at: lineEnd - 1) == 10 {
            lineTerminator = "\n"
        } else if lineRange.length >= 1,
                  source.character(at: lineEnd - 1) == 13 {
            lineTerminator = "\r"
        } else {
            lineTerminator = ""
        }
        let lineContentEnd = lineEnd - lineTerminator.utf16.count

        // Rich Markdown stores the checkbox as one attachment character. Use
        // that semantic state first; the textual matcher below is only for
        // raw Markdown that has not yet been enriched. Continuation is an
        // end-of-line gesture; pressing Return in the middle of a task must
        // remain an ordinary newline operation.
        if selection.length == 0,
           selection.location == lineContentEnd,
           let task = semanticTaskOnCurrentLine(lineRange: lineRange) {
            let attachmentRange = task.range
            let linePrefix = source.substring(with: NSRange(location: lineRange.location, length: max(0, attachmentRange.location - lineRange.location)))
            let bodyStart = NSMaxRange(attachmentRange)
            let body = source.substring(with: NSRange(location: bodyStart, length: max(0, NSMaxRange(lineRange) - bodyStart)))
                .trimmingCharacters(in: .newlines)
                .trimmingCharacters(in: .whitespaces)
            if body.isEmpty {
                // An empty task is an exit gesture: remove the rendered task
                // marker while retaining the paragraph break, leaving a plain
                // empty line instead of creating an endless checklist.
                var contentLength = lineRange.length
                while contentLength > 0 {
                    let character = source.character(at: lineRange.location + contentLength - 1)
                    if character == 10 || character == 13 { contentLength -= 1 } else { break }
                }
                replaceRichText(
                    range: NSRange(location: lineRange.location, length: contentLength),
                    with: NSAttributedString(string: "")
                )
            } else {
                let insertionTerminator = lineTerminator.isEmpty ? "\n" : lineTerminator
                let insertion = NSMutableAttributedString(string: "\(insertionTerminator)\(linePrefix)")
                let fresh = MarkdownTaskAttachment(checked: false)
                fresh.onChange = { [weak self] in self?.attachmentChangeHandler?() }
                insertion.append(NSAttributedString(attachment: fresh))
                insertion.append(NSAttributedString(string: " "))
                // `lineRange` includes the paragraph terminator, while the
                // insertion point at the end of a line is immediately before
                // it. Consume that existing terminator so Return creates one
                // continuation line rather than an unintended blank line.
                var replacementRange = selection
                if selection.location < source.length {
                    if source.substring(with: NSRange(location: selection.location, length: min(2, source.length - selection.location))) == "\r\n" {
                        replacementRange.length = 2
                    } else if source.character(at: selection.location) == 10 || source.character(at: selection.location) == 13 {
                        replacementRange.length = 1
                    }
                }
                replaceRichText(range: replacementRange, with: insertion)
            }
            return
        }

        let continuation: String?
        if let match = line.firstMatch(pattern: #"^(\s*)- (?:\[[ xX]\]|\u{FFFC}) (.*)$"#) {
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

    private func semanticTaskOnCurrentLine(lineRange: NSRange) -> (task: MarkdownTaskAttachment, range: NSRange)? {
        guard let attributed = textStorage else { return nil }
        var found: (MarkdownTaskAttachment, NSRange)?
        attributed.enumerateAttribute(.attachment, in: lineRange) { value, range, stop in
            if let task = value as? MarkdownTaskAttachment {
                found = (task, range)
                stop.pointee = true
            }
        }
        return found.map { (task: $0.0, range: $0.1) }
    }

    private func replaceRichText(range: NSRange, with replacement: NSAttributedString) {
        guard shouldChangeText(in: range, replacementString: replacement.string) else { return }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + replacement.length, length: 0))
    }

    override func insertTab(_ sender: Any?) {
        guard let task = semanticTaskOnCurrentLine(lineRange: (string as NSString).lineRange(for: selectedRange())) else {
            super.insertTab(sender)
            return
        }
        indentChecklistLine(task.range, outdent: false)
    }

    private func indentChecklistLine(_ taskRange: NSRange, outdent: Bool) {
        let source = string as NSString
        let lineRange = source.lineRange(for: taskRange)
        let line = source.substring(with: lineRange)
        let indentation = String(line.prefix { $0 == " " || $0 == "\t" })
        if outdent {
            guard !indentation.isEmpty else { return }
            let removeCount = indentation.hasPrefix("\t") ? 1 : min(4, indentation.count)
            replaceAndSelect(range: NSRange(location: lineRange.location, length: removeCount), replacement: "", selectionOffset: max(0, selectedRange().location - lineRange.location - removeCount), selectionLength: selectedRange().length)
        } else {
            replaceAndSelect(range: NSRange(location: lineRange.location, length: 0), replacement: "    ", selectionOffset: selectedRange().location - lineRange.location + 4, selectionLength: selectedRange().length)
        }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 36, flags.contains(.shift) {
            super.insertNewline(nil)
            return
        }
        if event.keyCode == 48, flags.contains(.shift) {
            guard let task = semanticTaskOnCurrentLine(lineRange: (string as NSString).lineRange(for: selectedRange())) else {
                super.keyDown(with: event)
                return
            }
            indentChecklistLine(task.range, outdent: true)
            return
        }
        super.keyDown(with: event)
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

    func applyListPrefix(_ prefix: String) {
        let source = string as NSString
        let selection = selectedRange()
        let start = source.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let endLocation = min(source.length, selection.location + selection.length)
        let endRange = source.lineRange(for: NSRange(location: max(start, endLocation - (endLocation > start ? 1 : 0)), length: 0))
        let end = NSMaxRange(endRange)
        var replacements: [(NSRange, String)] = []
        var cursor = start
        while cursor < end {
            let lineRange = source.lineRange(for: NSRange(location: cursor, length: 0))
            let raw = source.substring(with: lineRange).trimmingCharacters(in: .newlines)
            let body = raw.replacingOccurrences(of: #"^\s*(?:[-*+] |[-*+] \[ ?\] |\u{FFFC} )"#, with: "", options: .regularExpression)
            replacements.append((NSRange(location: lineRange.location, length: raw.utf16.count), prefix + body))
            cursor = NSMaxRange(lineRange)
        }
        guard !replacements.isEmpty else { return }
        for (range, replacement) in replacements.reversed() {
            guard shouldChangeText(in: range, replacementString: replacement) else { return }
            textStorage?.replaceCharacters(in: range, with: replacement)
        }
        didChangeText()
        setSelectedRange(NSRange(location: start, length: max(0, (textStorage?.length ?? start) - start)))
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

    func insertRichMarkdownBlock(_ markdown: String) {
        insertMarkdownBlock(markdown)
        richContentRenderHandler?()
    }

    func insertTable() {
        insertTable(TabularData(rows: [
            ["Column 1", "Column 2", "Column 3"],
            ["", "", ""],
            ["", "", ""]
        ]))
    }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.title = "Add Image to Note"
        panel.prompt = "Add Image"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url,
                  let reference = MarkdownNoteAssetStore.importFile(url) else { return }
            self?.insertRichMarkdownBlock("![\(url.deletingPathExtension().lastPathComponent)](\(reference))")
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(panel.runModal()) }
    }

    func insertChart() {
        insertRichMarkdownBlock("""
        ```chart
        title: New chart
        type: bar
        Item A, 12
        Item B, 18
        Item C, 9
        ```
        """)
    }

    @discardableResult
    private func insertImage(_ image: NSImage, alt: String) -> Bool {
        guard let reference = MarkdownNoteAssetStore.importImage(image) else { return false }
        insertRichMarkdownBlock("![\(alt)](\(reference))")
        return true
    }

    private func insertTable(_ data: TabularData) {
        guard data.columnCount > 1, let firstRow = data.rows.first else { return }
        let selection = selectedRange()
        let source = string as NSString
        let needsLeadingBreak = selection.location > 0
            && source.substring(with: NSRange(location: selection.location - 1, length: 1)) != "\n"
        let needsTrailingBreak = selection.location + selection.length < source.length
            && source.substring(with: NSRange(location: selection.location + selection.length, length: 1)) != "\n"
        let table = MarkdownTableData(
            headers: firstRow.enumerated().map { index, value in
                value.isEmpty ? "Column \(index + 1)" : value
            },
            alignments: Array(repeating: .leading, count: data.columnCount),
            rows: Array(data.rows.dropFirst())
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

@MainActor
private enum MarkdownInlineStyler {
    private static let hiddenMarkerFont = NSFont.systemFont(ofSize: 0.1)

    static func apply(to textView: NSTextView, fontStyle: NotesFontStyle, fontSize: Double, lineSpacing: Double, theme: NotesVisualTheme) {
        let palette = NotesEditorPalette(theme: theme)
        textView.drawsBackground = true
        textView.backgroundColor = palette.background
        textView.insertionPointColor = palette.accent
        textView.selectedTextAttributes = palette.selectionAttributes
        let baseFont = font(style: fontStyle, size: CGFloat(fontSize), weight: .regular)
        let monoFont = NSFont.monospacedSystemFont(ofSize: AppTypography.size(CGFloat(max(12, fontSize - 1.5))), weight: .regular)
        guard let storage = textView.textStorage else { return }
        let source = storage.string as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        let selection = textView.selectedRanges
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = CGFloat(lineSpacing)
        paragraph.paragraphSpacing = 3.5 + CGFloat(lineSpacing) * 0.45
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
            .foregroundColor: palette.text,
            .backgroundColor: palette.background,
            .paragraphStyle: paragraph
        ], range: fullRange)
        for attachment in attachments {
            storage.addAttribute(.attachment, value: attachment.value, range: attachment.range)
        }
        for attachment in attachments {
            guard let task = attachment.value as? MarkdownTaskAttachment else { continue }
            let lineRange = source.lineRange(for: attachment.range)
            let textStart = min(NSMaxRange(lineRange), NSMaxRange(attachment.range) + 1)
            let textRange = NSRange(location: textStart, length: max(0, NSMaxRange(lineRange) - textStart))
            if task.checked, textRange.length > 0 {
                storage.addAttributes([
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: palette.taskCompletedText
                ], range: textRange)
            }
        }

        apply(pattern: #"(?m)^(#{1,6})[ \t]+(.+)$"#, to: source) { match in
            guard !intersects(match.range, any: fencedCodeRanges) else { return }
            let level = min(max(match.range(at: 1).length, 1), 6)
            let sizes: [CGFloat] = [24, 20, 18, 16, 15, 14]
            let contentRange = match.range(at: 2)
            let headingParagraph = paragraph.mutableCopy() as! NSMutableParagraphStyle
            headingParagraph.paragraphSpacingBefore = level <= 2 ? 8 : 5
            headingParagraph.paragraphSpacing = level <= 2 ? 6 : 4
            storage.addAttributes([
                .font: font(style: fontStyle, size: sizes[level - 1] * CGFloat(fontSize / 15.5), weight: level <= 3 ? .bold : .semibold),
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
                .backgroundColor: palette.codeBackground,
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
            storage.addAttributes([.font: monoFont, .backgroundColor: palette.codeBackground], range: contentRange)
            styleMarkers(around: contentRange, in: match.range, storage: storage)
        }

        apply(pattern: #"\*\*([^*\n]+)\*\*|__([^_\n]+)__"#, to: source) { match in
            guard !intersects(match.range, any: fencedCodeRanges) else { return }
            let contentRange = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
            storage.addAttribute(.font, value: font(style: fontStyle, size: CGFloat(fontSize), weight: .bold), range: contentRange)
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
            storage.addAttributes([.foregroundColor: palette.accent, .underlineStyle: NSUnderlineStyle.single.rawValue], range: labelRange)
            styleMarkers(around: labelRange, in: match.range, storage: storage)
            if let url = URL(string: source.substring(with: destinationRange)) {
                storage.addAttribute(.link, value: url, range: labelRange)
            }
        }

        apply(pattern: #"(?m)^(\s*)([-*+]|\d+[.)])\s+"#, to: source) { match in
            guard !intersects(match.range, any: fencedCodeRanges) else { return }
            storage.addAttribute(.foregroundColor, value: palette.accent, range: match.range)
        }
        apply(pattern: #"(?m)^(\s*)- \[([ xX])\]\s+(.*)$"#, to: source) { match in
            guard !intersects(match.range, any: fencedCodeRanges) else { return }
            let checked = source.substring(with: match.range(at: 2)).lowercased() == "x"
            storage.addAttribute(.foregroundColor, value: checked ? palette.taskChecked : palette.accent, range: NSRange(location: match.range.location, length: match.range(at: 3).location - match.range.location))
            if checked {
                storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: palette.taskCompletedText], range: match.range(at: 3))
            }
        }
        apply(pattern: #"(?m)^(\s*>\s?)(.*)$"#, to: source) { match in
            guard !intersects(match.range, any: fencedCodeRanges) else { return }
            storage.addAttribute(.foregroundColor, value: palette.accent, range: match.range(at: 1))
            let italic = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
            storage.addAttributes([
                .font: italic,
                .foregroundColor: palette.secondaryText,
                .backgroundColor: palette.quoteBackground
            ], range: match.range(at: 2))
        }
        apply(pattern: #"(?m)^(---|\*\*\*|___)[ \t]*$"#, to: source) { match in
            guard !intersects(match.range, any: fencedCodeRanges) else { return }
            storage.addAttributes([
                .foregroundColor: palette.separator,
                .font: NSFont.monospacedSystemFont(ofSize: AppTypography.size(13), weight: .regular),
                .kern: 2.2
            ], range: match.range)
        }

        storage.endEditing()
        textView.selectedRanges = selection
        textView.typingAttributes = [
            .font: baseFont,
            .foregroundColor: palette.text,
            .backgroundColor: palette.background
        ]
    }

    private static func font(style: NotesFontStyle, size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let scaled = AppTypography.size(size)
        switch style {
        case .system: return NSFont.systemFont(ofSize: scaled, weight: weight)
        case .rounded:
            let base = NSFont.systemFont(ofSize: scaled, weight: weight)
            if let descriptor = base.fontDescriptor.withDesign(.rounded),
               let designed = NSFont(descriptor: descriptor, size: scaled) { return designed }
            return base
        case .serif:
            let base = NSFont.systemFont(ofSize: scaled, weight: weight)
            if let descriptor = base.fontDescriptor.withDesign(.serif),
               let designed = NSFont(descriptor: descriptor, size: scaled) { return designed }
            return base
        case .monospaced: return NSFont.monospacedSystemFont(ofSize: scaled, weight: weight)
        }
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

@MainActor
private struct NotesEditorPalette {
    let background: NSColor
    let text: NSColor
    let secondaryText: NSColor
    let separator: NSColor
    let accent: NSColor
    let codeBackground: NSColor
    let quoteBackground: NSColor
    let taskChecked: NSColor
    let taskCompletedText: NSColor

    var selectionAttributes: [NSAttributedString.Key: Any] {
        [
            .backgroundColor: NSColor.selectedTextBackgroundColor,
            .foregroundColor: NSColor.selectedTextColor
        ]
    }

    init(theme: NotesVisualTheme) {
        let palette = NotesAppearancePalette(theme: theme)
        background = palette.background
        text = palette.textPrimary
        secondaryText = palette.textSecondary
        separator = palette.separator
        accent = palette.accent
        codeBackground = palette.codeBackground
        quoteBackground = palette.quoteBackground
        taskChecked = palette.taskChecked
        taskCompletedText = palette.taskCompletedText
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
