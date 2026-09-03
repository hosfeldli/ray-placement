import Foundation
import RayPlacementCore

@MainActor
final class NotesStore: ObservableObject {
    static let maximumNotes = 250
    static let maximumCharactersPerNote = 200_000
    static let maximumRevisionsPerNote = 30

    @Published private(set) var notes: [MarkdownNote]
    @Published var selectedNoteID: UUID?
    @Published var lastError: String?

    private let persistenceQueue = DispatchQueue(label: "dev.rayplacement.notes-persistence", qos: .utility)
    private var pendingSave: DispatchWorkItem?
    private var pendingRevisionSnapshots: [UUID: NoteRevision] = [:]
    private var revisionWorkItems: [UUID: DispatchWorkItem] = [:]
    private var revisionGenerations: [UUID: UUID] = [:]

    init() {
        notes = Self.loadNotes()
        if notes.isEmpty {
            let welcome = MarkdownNote(
                title: "Welcome to Lima Notes",
                content: """
                # Welcome to Lima Notes

                Notes are private, local, and saved as portable Markdown.

                - Build clean headings, **bold**, *italic*, links, lists, tables, and code blocks without source punctuation clutter.
                - Pin active notes or favorite the ones you want to keep close.
                - Search titles and content from the sidebar.
                - Meeting dictation adds each completed segment while recording, then finishes the active segment when you stop.

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

    func selectMostRecentNote() {
        if let identifier = notes.max(by: { $0.modifiedAt < $1.modifiedAt })?.id {
            selectedNoteID = identifier
        } else {
            createNote()
        }
    }

    func createNote(template: MarkdownNoteTemplate = .blank) {
        guard notes.count < Self.maximumNotes else {
            lastError = "Lima Notes is limited to \(Self.maximumNotes) notes to keep search and autosave responsive."
            return
        }
        let note = MarkdownNote(title: template.noteTitle, content: template.content)
        notes.insert(note, at: 0)
        selectedNoteID = note.id
        lastError = nil
        scheduleSave()
    }

    func createQuickNote(with text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        guard clean.count <= Self.maximumCharactersPerNote else {
            lastError = "A quick note can contain up to \(Self.maximumCharactersPerNote.formatted()) characters."
            return
        }
        guard notes.count < Self.maximumNotes else {
            lastError = "Lima Notes is limited to \(Self.maximumNotes) notes."
            return
        }
        let title = "Quick Note · \(Date().formatted(date: .abbreviated, time: .shortened))"
        let note = MarkdownNote(title: title, content: clean)
        notes.insert(note, at: 0)
        selectedNoteID = note.id
        scheduleSave()
    }

    func replaceTags(_ tags: [String]) {
        updateSelected { note in note.tags = MarkdownNoteLinks.normalizedTags(tags) }
    }

    func addTag(_ tag: String) {
        guard let note = selectedNote else { return }
        replaceTags(note.tags + [tag])
    }

    func removeTag(_ tag: String) {
        replaceTags((selectedNote?.tags ?? []).filter { $0.caseInsensitiveCompare(tag) != .orderedSame })
    }

    func referencedNotes(for noteID: UUID? = nil) -> [MarkdownNote] {
        guard let note = noteID.flatMap({ id in notes.first { $0.id == id } }) ?? selectedNote else { return [] }
        let targets = MarkdownNoteLinks.targets(in: note.content)
        return notes.filter { candidate in
            candidate.id != note.id && targets.contains { target in
                target.caseInsensitiveCompare(candidate.displayTitle) == .orderedSame || target == candidate.id.uuidString
            }
        }
    }

    func backlinks(for noteID: UUID? = nil) -> [MarkdownNote] {
        guard let target = noteID.flatMap({ id in notes.first { $0.id == id } }) ?? selectedNote else { return [] }
        return notes.filter { note in
            guard note.id != target.id else { return false }
            return MarkdownNoteLinks.targets(in: note.content).contains { link in
                link.caseInsensitiveCompare(target.displayTitle) == .orderedSame || link == target.id.uuidString
            }
        }
    }

    func restore(_ revision: NoteRevision) {
        guard let selectedNoteID else { return }
        updateNote(selectedNoteID) { note in
            note.title = revision.title
            note.content = revision.content
        }
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
        let namedTranscript = applySpeakerNames(to: cleanTranscript, names: notes[targetIndex].speakerNames)
        let candidate = notes[targetIndex].content + separator + namedTranscript
        guard candidate.count <= Self.maximumCharactersPerNote else {
            lastError = "The meeting transcript would exceed this note's \(Self.maximumCharactersPerNote.formatted())-character limit."
            return
        }
        updateNote(targetID) { note in note.content = candidate }
    }

    func renameSpeakers(_ names: [Int: String]) {
        guard let selectedNoteID,
              let index = notes.firstIndex(where: { $0.id == selectedNoteID }) else { return }
        let oldNames = notes[index].speakerNames
        updateNote(selectedNoteID) { note in
            var content = note.content
            for number in 1...8 {
                let prior = oldNames[number]?.trimmingCharacters(in: .whitespacesAndNewlines)
                let oldLabel = (prior?.isEmpty == false ? prior! : "Speaker \(number)")
                let proposed = names[number]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let newLabel = proposed.isEmpty ? "Speaker \(number)" : proposed
                content = content.replacingOccurrences(of: "**\(oldLabel):**", with: "**\(newLabel):**")
            }
            note.content = content
            note.speakerNames = names.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
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

    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        for (identifier, snapshot) in pendingRevisionSnapshots {
            if let index = notes.firstIndex(where: { $0.id == identifier }) {
                notes[index].revisionHistory.append(snapshot)
                notes[index].revisionHistory = Array(notes[index].revisionHistory.suffix(Self.maximumRevisionsPerNote))
            }
        }
        pendingRevisionSnapshots.removeAll()
        revisionWorkItems.values.forEach { $0.cancel() }
        revisionWorkItems.removeAll()
        revisionGenerations.removeAll()
        let snapshot = notes
        persistenceQueue.sync { Self.persist(snapshot) }
    }

    private func updateSelected(_ change: (inout MarkdownNote) -> Void) {
        guard let selectedNoteID else { return }
        updateNote(selectedNoteID, change)
    }

    private func updateNote(_ identifier: UUID, _ change: (inout MarkdownNote) -> Void) {
        guard let index = notes.firstIndex(where: { $0.id == identifier }) else { return }
        let before = notes[index]
        change(&notes[index])
        let contentChanged = before.title != notes[index].title || before.content != notes[index].content
        if contentChanged { queueRevision(identifier, before: before) }
        notes[index].tags = MarkdownNoteLinks.normalizedTags(notes[index].tags)
        notes[index].modifiedAt = Date()
        lastError = nil
        scheduleSave()
    }

    private func queueRevision(_ identifier: UUID, before: MarkdownNote) {
        if pendingRevisionSnapshots[identifier] == nil {
            pendingRevisionSnapshots[identifier] = NoteRevision(title: before.title, content: before.content)
        }
        revisionWorkItems[identifier]?.cancel()
        let generation = UUID()
        revisionGenerations[identifier] = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.revisionGenerations[identifier] == generation,
                      let snapshot = self.pendingRevisionSnapshots.removeValue(forKey: identifier),
                      let index = self.notes.firstIndex(where: { $0.id == identifier }) else { return }
                self.revisionGenerations.removeValue(forKey: identifier)
                self.revisionWorkItems.removeValue(forKey: identifier)
                self.notes[index].revisionHistory.append(snapshot)
                self.notes[index].revisionHistory = Array(self.notes[index].revisionHistory.suffix(Self.maximumRevisionsPerNote))
                self.scheduleSave()
            }
        }
        revisionWorkItems[identifier] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    private func sortNotes() {
        notes.sort {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
            return $0.modifiedAt > $1.modifiedAt
        }
    }

    private func applySpeakerNames(to transcript: String, names: [Int: String]) -> String {
        names.reduce(transcript) { output, entry in
            let name = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return output }
            return output.replacingOccurrences(of: "**Speaker \(entry.key):**", with: "**\(name):**")
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
                bounded.tags = MarkdownNoteLinks.normalizedTags(note.tags)
                bounded.revisionHistory = Array(note.revisionHistory.suffix(maximumRevisionsPerNote))
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
