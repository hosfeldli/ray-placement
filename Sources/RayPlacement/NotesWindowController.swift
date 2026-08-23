import AppKit
import RayPlacementCore
import SwiftUI

@MainActor
final class NotesWindowController: NSObject, NSWindowDelegate {
    let store: NotesStore
    let dictation: NoteDictationService
    let summarizer: NoteSummaryService
    private var window: NSWindow?
    private var dictationHUD: DictationHUDController!

    override init() {
        let store = NotesStore()
        self.store = store
        self.dictation = NoteDictationService { [weak store] transcript, destinationNoteID in
            store?.appendDictation(transcript, to: destinationNoteID)
        }
        self.summarizer = NoteSummaryService()
        super.init()
        self.dictationHUD = DictationHUDController(dictation: dictation) { [weak self] in
            self?.present()
        }
    }

    func present() {
        let window = window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func presentMostRecentAndToggleDictation() {
        store.selectMostRecentNote()
        present()
        guard dictation.phase == .idle || dictation.phase == .recording else { return }
        dictation.performPrimaryAction(
            destinationNoteID: store.selectedNoteID,
            destinationNoteTitle: store.selectedNote?.displayTitle
        )
    }

    func shutdown() {
        dictation.cancel()
        summarizer.cancel()
        store.flush()
    }

    func windowWillClose(_ notification: Notification) {
        summarizer.cancel()
        store.flush()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "RayPlacement Notes"
        window.setAccessibilityLabel("RayPlacement Notes")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 500)
        window.center()
        window.setFrameAutosaveName("RayPlacementNotesWindow")
        window.delegate = self
        window.contentView = NSHostingView(rootView: NotesView(
            store: store,
            dictation: dictation,
            summarizer: summarizer
        ))
        return window
    }
}

private struct NotesView: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var dictation: NoteDictationService
    @ObservedObject var summarizer: NoteSummaryService
    @State private var searchQuery = ""
    @State private var confirmDelete = false

    private var filteredNotes: [MarkdownNote] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return store.notes }
        return store.notes.filter { note in
            note.displayTitle.lowercased().contains(query)
                || note.content.prefix(20_000).lowercased().contains(query)
        }
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
            editor
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Delete this note?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Note", role: .destructive) { store.deleteSelectedNote() }
        } message: {
            Text("This permanently removes the selected local note.")
        }
        .sheet(isPresented: Binding(
            get: { summarizer.proposal != nil },
            set: { if !$0 { summarizer.dismissProposal() } }
        )) {
            if let proposal = summarizer.proposal {
                SummaryReviewView(
                    proposal: proposal,
                    insert: {
                        store.insertSummary(proposal.markdown, into: proposal.noteID)
                        summarizer.dismissProposal()
                    },
                    copy: summarizer.copyProposal,
                    close: summarizer.dismissProposal
                )
            }
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
                Text("Local Markdown")
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
                        text: Binding(get: { note.title }, set: store.updateTitle)
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 21, weight: .semibold))

                    Text("Markdown formats inline")
                        .font(.caption)
                        .foregroundStyle(.secondary)

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

                InlineMarkdownEditor(text: Binding(get: { note.content }, set: store.updateContent))
                    .accessibilityLabel("Inline formatted Markdown editor")

                Divider()
                noteToolbar(note)
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

    private func noteToolbar(_ note: MarkdownNote) -> some View {
        VStack(spacing: 0) {
            if let error = store.lastError ?? dictation.lastError ?? summarizer.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 7)
            }
            HStack(spacing: 7) {
                MarkdownInsertButton(symbol: "bold", help: "Bold (Command-B)") { store.appendMarkdown("**bold text**") }
                MarkdownInsertButton(symbol: "italic", help: "Italic (Command-I)") { store.appendMarkdown("*italic text*") }
                MarkdownInsertButton(symbol: "list.bullet", help: "Insert list item") { store.appendMarkdown("- List item") }
                MarkdownInsertButton(symbol: "checklist", help: "Insert task") { store.appendMarkdown("- [ ] Task") }
                MarkdownInsertButton(symbol: "chevron.left.forwardslash.chevron.right", help: "Insert code block") {
                    store.appendMarkdown("```\ncode\n```")
                }
                MarkdownInsertButton(symbol: "link", help: "Link (Command-K)") { store.appendMarkdown("[link title](https://example.com)") }

                Spacer(minLength: 8)

                if summarizer.isSummarizing {
                    Text(summarizer.progressText ?? "Summarizing with Qwen…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button("Cancel", action: summarizer.cancel)
                } else {
                    Button {
                        summarizer.summarize(note)
                    } label: {
                        Label("Summarize", systemImage: "text.quote")
                    }
                    .disabled(dictation.phase != .idle || note.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Summarize this note locally with Qwen using the Writing performance limit")
                }

                Text(dictation.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button {
                    if store.selectedNoteID == nil { store.createNote() }
                    dictation.performPrimaryAction(
                        destinationNoteID: store.selectedNoteID,
                        destinationNoteTitle: store.selectedNote?.displayTitle
                    )
                } label: {
                    Label(dictation.actionTitle, systemImage: dictation.phase == .recording ? "stop.circle.fill" : "mic.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(dictation.phase == .recording ? .red : .accentColor)
                .disabled(
                    dictation.phase == .requestingPermission
                        || dictation.phase == .transcribing
                        || summarizer.isSummarizing
                )
                .help("Record first, then transcribe into this note after Stop")
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 48)
        }
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

private struct SummaryReviewView: View {
    let proposal: NoteSummaryProposal
    let insert: () -> Void
    let copy: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Qwen Summary").font(.title2.bold())
                    Text(proposal.noteTitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close", action: close)
            }
            .padding(18)
            Divider()
            ScrollView {
                renderedSummary
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(24)
            }
            .textSelection(.enabled)
            Divider()
            HStack {
                Text("Generated locally with Qwen3 1.7B; review before inserting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy Markdown", action: copy)
                Button("Insert at Top", action: insert)
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 680, height: 520)
    }

    private var renderedSummary: Text {
        if let attributed = try? AttributedString(
            markdown: proposal.markdown,
            options: .init(interpretedSyntax: .full)
        ) {
            return Text(attributed)
        }
        return Text(proposal.markdown)
    }
}
