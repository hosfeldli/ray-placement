import Foundation
import RayPlacementCore

@MainActor
final class NotesStore: ObservableObject {
    static let maximumNotes = 250
    static let maximumCharactersPerNote = 200_000

    @Published private(set) var notes: [MarkdownNote]
    @Published var selectedNoteID: UUID?
    @Published var lastError: String?
    @Published private(set) var formatterWorkspaceOpen = false

    static let formatterWorkspaceID = UUID(uuidString: "8E65542D-D46C-4B1A-A9B5-EE4182FF22F1")!

    private let persistenceQueue = DispatchQueue(label: "dev.rayplacement.notes-persistence", qos: .utility)
    private var pendingSave: DispatchWorkItem?

    init() {
        notes = Self.loadNotes()
        if notes.isEmpty {
            let welcome = MarkdownNote(
                title: "Welcome to RayPlacement Notes",
                content: """
                # Welcome to RayPlacement Notes

                Notes are private, local, and saved as portable Markdown.

                - Build clean headings, **bold**, *italic*, links, lists, tables, and code blocks without source punctuation clutter.
                - Pin active notes or favorite the ones you want to keep close.
                - Search titles and content from the sidebar.
                - Dictation records first and transcribes only after you stop.

                > Everything autosaves locally on this Mac.
                """
            )
            notes = [welcome]
        }
        sortNotes()
        selectedNoteID = notes.first?.id
        scheduleSave()
    }

    var selectedNote: MarkdownNote? {
        guard let selectedNoteID else { return nil }
        return notes.first { $0.id == selectedNoteID }
    }

    var isFormatterSelected: Bool { selectedNoteID == Self.formatterWorkspaceID }

    func openFormatterWorkspace() {
        formatterWorkspaceOpen = true
        selectedNoteID = Self.formatterWorkspaceID
    }

    func closeFormatterWorkspace() {
        formatterWorkspaceOpen = false
        if isFormatterSelected { selectedNoteID = notes.first?.id }
    }

    func selectMostRecentNote() {
        if let identifier = notes.max(by: { $0.modifiedAt < $1.modifiedAt })?.id {
            selectedNoteID = identifier
        } else {
            createNote()
        }
    }

    func createNote() {
        guard notes.count < Self.maximumNotes else {
            lastError = "RayPlacement Notes is limited to \(Self.maximumNotes) notes to keep search and autosave responsive."
            return
        }
        let note = MarkdownNote()
        notes.insert(note, at: 0)
        selectedNoteID = note.id
        lastError = nil
        scheduleSave()
    }

    func deleteSelectedNote() {
        guard let selectedNoteID,
              let index = notes.firstIndex(where: { $0.id == selectedNoteID }) else { return }
        notes.remove(at: index)
        self.selectedNoteID = notes.indices.contains(index) ? notes[index].id : notes.last?.id
        scheduleSave()
    }

    func updateTitle(_ title: String) {
        updateSelected { note in
            note.title = String(title.prefix(200))
        }
    }

    func updateContent(_ content: String) {
        guard content.count <= Self.maximumCharactersPerNote else {
            lastError = "A note can contain up to \(Self.maximumCharactersPerNote.formatted()) characters."
            return
        }
        updateSelected { note in note.content = content }
    }

    func appendMarkdown(_ markdown: String) {
        updateSelected { note in
            let separator = note.content.isEmpty || note.content.hasSuffix("\n") ? "" : "\n"
            let candidate = note.content + separator + markdown
            if candidate.count <= Self.maximumCharactersPerNote {
                note.content = candidate
            }
        }
    }

    func appendDictation(_ transcript: String, to destinationNoteID: UUID?) {
        let cleanTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTranscript.isEmpty else { return }
        var targetID = destinationNoteID
        if targetID == nil || !notes.contains(where: { $0.id == targetID }) {
            createNote()
            targetID = selectedNoteID
        }
        guard let targetID else { return }
        guard let targetIndex = notes.firstIndex(where: { $0.id == targetID }) else { return }
        let separator = notes[targetIndex].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n\n"
        let candidate = notes[targetIndex].content + separator + cleanTranscript
        guard candidate.count <= Self.maximumCharactersPerNote else {
            lastError = "The meeting transcript would exceed this note's \(Self.maximumCharactersPerNote.formatted())-character limit."
            return
        }
        updateNote(targetID) { note in note.content = candidate }
    }

    func togglePin() {
        updateSelected { note in note.isPinned.toggle() }
        sortNotes()
    }

    func toggleFavorite() {
        updateSelected { note in note.isFavorite.toggle() }
        sortNotes()
    }

    func duplicateSelectedNote() {
        guard notes.count < Self.maximumNotes, var duplicate = selectedNote else { return }
        duplicate.id = UUID()
        duplicate.title = "\(duplicate.displayTitle) Copy"
        duplicate.createdAt = Date()
        duplicate.modifiedAt = Date()
        duplicate.isPinned = false
        duplicate.isFavorite = false
        notes.insert(duplicate, at: 0)
        selectedNoteID = duplicate.id
        scheduleSave()
    }

    func insertSummary(_ summary: String, into noteID: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == noteID }) else {
            lastError = "The original note no longer exists, so the summary was not inserted."
            return
        }
        let cleanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSummary.isEmpty else { return }
        let block = "## Qwen Summary\n\n\(cleanSummary)\n\n---\n\n"
        let candidate = block + notes[index].content
        guard candidate.count <= Self.maximumCharactersPerNote else {
            lastError = "The summary would exceed this note's \(Self.maximumCharactersPerNote.formatted())-character limit."
            return
        }
        updateNote(noteID) { note in note.content = candidate }
        selectedNoteID = noteID
    }

    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = notes
        persistenceQueue.sync { Self.persist(snapshot) }
    }

    private func updateSelected(_ change: (inout MarkdownNote) -> Void) {
        guard let selectedNoteID else { return }
        updateNote(selectedNoteID, change)
    }

    private func updateNote(_ identifier: UUID, _ change: (inout MarkdownNote) -> Void) {
        guard let index = notes.firstIndex(where: { $0.id == identifier }) else { return }
        change(&notes[index])
        notes[index].modifiedAt = Date()
        lastError = nil
        scheduleSave()
    }

    private func sortNotes() {
        notes.sort {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
            return $0.modifiedAt > $1.modifiedAt
        }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let snapshot = notes
        let work = DispatchWorkItem { Self.persist(snapshot) }
        pendingSave = work
        persistenceQueue.asyncAfter(deadline: .now() + 0.55, execute: work)
    }

    private static func loadNotes() -> [MarkdownNote] {
        guard let data = try? Data(contentsOf: ApplicationPaths.notes),
              let decoded = try? JSONDecoder().decode([MarkdownNote].self, from: data) else { return [] }
        return decoded
            .prefix(maximumNotes)
            .map { note in
                var bounded = note
                bounded.title = String(note.title.prefix(200))
                bounded.content = String(note.content.prefix(maximumCharactersPerNote))
                return bounded
            }
    }

    private nonisolated static func persist(_ notes: [MarkdownNote]) {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        try? FileManager.default.createDirectory(
            at: ApplicationPaths.applicationSupport,
            withIntermediateDirectories: true
        )
        try? data.write(to: ApplicationPaths.notes, options: .atomic)
    }
}
