import AppKit
import RayPlacementCore
import SwiftUI

@MainActor
final class NotesWindowController: NSObject, NSWindowDelegate {
    let store: NotesStore
    let dictation: NoteDictationService
    private var window: NSWindow?

    override init() {
        let store = NotesStore()
        self.store = store
        self.dictation = NoteDictationService { [weak store] transcript, destinationNoteID in
            store?.appendDictation(transcript, to: destinationNoteID)
        }
        super.init()
    }

    func present() {
        let window = window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func shutdown() {
        dictation.cancel()
        store.flush()
    }

    func windowWillClose(_ notification: Notification) {
        dictation.cancel()
        store.flush()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "RayPlacement Notes"
        window.setAccessibilityLabel("RayPlacement Notes")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 500)
        window.center()
        window.setFrameAutosaveName("RayPlacementNotesWindow")
        window.delegate = self
        window.contentView = NSHostingView(rootView: NotesView(store: store, dictation: dictation))
        return window
    }
}

private struct NotesView: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var dictation: NoteDictationService
    @State private var searchQuery = ""
    @State private var confirmDelete = false
    @State private var previewBlocks: [MarkdownBlock] = []
    @State private var previewWorkItem: DispatchWorkItem?

    private var filteredNotes: [MarkdownNote] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return store.notes }
        return store.notes.filter { note in
            note.displayTitle.lowercased().contains(query)
                || note.content.prefix(20_000).lowercased().contains(query)
        }
    }

    private var selectedContent: String { store.selectedNote?.content ?? "" }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
            editor
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { schedulePreview(selectedContent, immediately: true) }
        .onChange(of: selectedContent) { content in schedulePreview(content) }
        .onChange(of: store.selectedNoteID) { _ in schedulePreview(selectedContent, immediately: true) }
        .alert("Delete this note?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Note", role: .destructive) { store.deleteSelectedNote() }
        } message: {
            Text("This permanently removes the selected local note.")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Search notes", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                Button {
                    store.createNote()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .help("New Note (Command-N)")
                .keyboardShortcut("n", modifiers: .command)
            }
            .padding(12)

            Divider()

            List(selection: $store.selectedNoteID) {
                ForEach(filteredNotes) { note in
                    NoteListRow(note: note)
                        .tag(note.id)
                        .accessibilityLabel("\(note.displayTitle), \(note.preview)")
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack {
                Text("\(store.notes.count) \(store.notes.count == 1 ? "note" : "notes")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Local only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let note = store.selectedNote {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    TextField(
                        "Untitled Note",
                        text: Binding(
                            get: { note.title },
                            set: store.updateTitle
                        )
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 21, weight: .semibold))

                    Button {
                        store.togglePin()
                    } label: {
                        Image(systemName: note.isPinned ? "pin.fill" : "pin")
                    }
                    .buttonStyle(.borderless)
                    .help(note.isPinned ? "Unpin Note" : "Pin Note")

                    Menu {
                        Button("Duplicate Note") { store.duplicateSelectedNote() }
                        Divider()
                        Button("Delete Note…", role: .destructive) { confirmDelete = true }
                            .keyboardShortcut(.delete, modifiers: .command)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 28)
                }
                .padding(.horizontal, 16)
                .frame(height: 54)

                Divider()

                HSplitView {
                    markdownEditor(note)
                        .frame(minWidth: 270, maxWidth: .infinity, maxHeight: .infinity)
                    markdownPreview
                        .frame(minWidth: 270, maxWidth: .infinity, maxHeight: .infinity)
                }

                Divider()
                noteToolbar
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "note.text.badge.plus")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text("No note selected").font(.headline)
                Button("Create Note") { store.createNote() }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func markdownEditor(_ note: MarkdownNote) -> some View {
        VStack(spacing: 0) {
            PaneHeader(title: "MARKDOWN", detail: "Autosaved")
            Divider()
            TextEditor(text: Binding(get: { note.content }, set: store.updateContent))
                .font(.system(size: 14, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .accessibilityLabel("Markdown editor")
        }
    }

    private var markdownPreview: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "PREVIEW", detail: "Rendered Markdown")
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if previewBlocks.isEmpty {
                        Text("Start writing to see a rendered preview.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(previewBlocks.prefix(2_000).enumerated()), id: \.offset) { _, block in
                            MarkdownBlockView(block: block)
                        }
                        if previewBlocks.count > 2_000 {
                            Text("Preview limited to the first 2,000 blocks to stay responsive.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(18)
            }
            .textSelection(.enabled)
            .accessibilityLabel("Markdown preview")
        }
    }

    private var noteToolbar: some View {
        VStack(spacing: 0) {
            if let error = store.lastError ?? dictation.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 7)
            }
            HStack(spacing: 7) {
                MarkdownInsertButton(symbol: "bold", help: "Insert bold Markdown") { store.appendMarkdown("**bold text**") }
                MarkdownInsertButton(symbol: "italic", help: "Insert italic Markdown") { store.appendMarkdown("*italic text*") }
                MarkdownInsertButton(symbol: "list.bullet", help: "Insert list item") { store.appendMarkdown("- List item") }
                MarkdownInsertButton(symbol: "checklist", help: "Insert task") { store.appendMarkdown("- [ ] Task") }
                MarkdownInsertButton(symbol: "chevron.left.forwardslash.chevron.right", help: "Insert code block") {
                    store.appendMarkdown("```\ncode\n```")
                }
                MarkdownInsertButton(symbol: "link", help: "Insert link") { store.appendMarkdown("[link title](https://example.com)") }

                Spacer()
                Text(dictation.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button {
                    if store.selectedNoteID == nil { store.createNote() }
                    dictation.performPrimaryAction(destinationNoteID: store.selectedNoteID)
                } label: {
                    Label(dictation.actionTitle, systemImage: dictation.phase == .recording ? "stop.circle.fill" : "mic.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(dictation.phase == .recording ? .red : .accentColor)
                .disabled(dictation.phase == .requestingPermission || dictation.phase == .transcribing)
                .help("Record first, then transcribe into this note after Stop")
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
        }
    }

    private func schedulePreview(_ content: String, immediately: Bool = false) {
        previewWorkItem?.cancel()
        var work: DispatchWorkItem!
        work = DispatchWorkItem {
            let blocks = MarkdownBlockParser.parse(content)
            DispatchQueue.main.async {
                guard !work.isCancelled else { return }
                previewBlocks = blocks
            }
        }
        previewWorkItem = work
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + (immediately ? 0 : 0.28),
            execute: work
        )
    }
}

private struct NoteListRow: View {
    let note: MarkdownNote

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if note.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 3)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(note.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(note.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(note.modifiedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PaneHeader: View {
    let title: String
    let detail: String

    var body: some View {
        HStack {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }
}

private struct MarkdownInsertButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    @ViewBuilder
    var body: some View {
        switch block {
        case .heading(let level, let text):
            inlineText(text)
                .font(.system(size: max(15, 28 - CGFloat(level * 2)), weight: .bold))
                .padding(.top, level == 1 ? 6 : 2)
        case .paragraph(let text):
            inlineText(text)
                .font(.body)
                .lineSpacing(3)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text("•").foregroundStyle(Color.accentColor)
                inlineText(text)
            }
        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text("\(number).")
                    .foregroundStyle(Color.accentColor)
                    .frame(minWidth: 20, alignment: .trailing)
                inlineText(text)
            }
        case .task(let checked, let text):
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked ? Color.green : Color.secondary)
                inlineText(text)
                    .strikethrough(checked, color: .secondary)
                    .foregroundStyle(checked ? Color.secondary : Color.primary)
            }
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(width: 3)
                inlineText(text)
                    .italic()
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        case .code(let language, let text):
            VStack(alignment: .leading, spacing: 7) {
                if let language {
                    Text(language.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(text)
                    .font(.system(size: 12.5, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(11)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        case .divider:
            Divider().padding(.vertical, 5)
        }
    }

    private func inlineText(_ markdown: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(markdown)
    }
}
