import Foundation
import CryptoKit
import RayPlacementCore

private func parseTaskLine(_ line: String) -> (checked: Bool, text: String)? {
    let pattern = #"^\s*- \[([ xX])\]\s+(.+)$"#
    guard let expression = try? NSRegularExpression(pattern: pattern),
          let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
          let stateRange = Range(match.range(at: 1), in: line),
          let textRange = Range(match.range(at: 2), in: line) else { return nil }
    return (String(line[stateRange]).lowercased() == "x", String(line[textRange]))
}

@MainActor
final class NotesStore: ObservableObject {
    static let shared = NotesStore()
    static let maximumNotes = 250
    static let maximumCharactersPerNote = 200_000
    static let maximumRevisionsPerNote = 30

    @Published private(set) var notes: [MarkdownNote]
    @Published var selectedNoteID: UUID?
    @Published var lastError: String?
    @Published private(set) var noteBackStack: [UUID] = []
    @Published private(set) var noteForwardStack: [UUID] = []
    @Published private(set) var userTemplates: [MarkdownUserTemplate]

    private var noteScrollOffsets: [String: CGFloat] = [:]
    @Published private(set) var recoveryURL: URL?

    private let persistenceQueue = DispatchQueue(label: "dev.rayplacement.notes-persistence", qos: .utility)
    private let persistenceGeneration = PersistenceGeneration()
    private let persistenceEnabled: Bool
    private var pendingSave: DispatchWorkItem?
    private var pendingRevisionSnapshots: [UUID: NoteRevision] = [:]
    private var revisionWorkItems: [UUID: DispatchWorkItem] = [:]
    private var revisionGenerations: [UUID: UUID] = [:]

    init() {
        persistenceEnabled = true
        let loaded = Self.loadNotes()
        notes = loaded.notes
        userTemplates = Self.loadUserTemplates()
        lastError = loaded.error
        recoveryURL = loaded.recoveryURL
        if notes.isEmpty && loaded.wasMissing {
            let welcome = MarkdownNote(
                title: "Welcome to Lima Notes",
                content: """
                # Welcome to Lima Notes

                Notes are private, local, and saved as portable Markdown.

                - Build clean headings, **bold**, *italic*, links, lists, tables, and code blocks without source punctuation clutter.
                - Pin active notes or favorite the ones you want to keep close.
                - Search titles and content from the sidebar.
                - Dictation conversations are kept in their own tab and never alter Notes.

                > Everything autosaves locally on this Mac.
                """
            )
            notes = [welcome]
        }
        sortNotes()
        selectedNoteID = notes.first?.id
        scheduleSave()
    }

    /// An isolated in-memory store for offscreen visual previews and fixtures.
    init(visualFixtures: [MarkdownNote]) {
        persistenceEnabled = false
        notes = visualFixtures
        selectedNoteID = visualFixtures.first?.id
        lastError = nil
        userTemplates = []
        recoveryURL = nil
        sortNotes()
    }

    func replace(with replacement: [MarkdownNote]) throws {
        guard replacement.count <= Self.maximumNotes,
              replacement.allSatisfy({ $0.title.count <= 200 && $0.content.count <= Self.maximumCharactersPerNote }) else {
            throw NSError(domain: "LimaNotes", code: 1, userInfo: [NSLocalizedDescriptionKey: "The imported notes exceed Lima's limits."])
        }
        notes = replacement
        sortNotes()
        selectedNoteID = notes.first?.id
        noteBackStack.removeAll()
        noteForwardStack.removeAll()
        noteScrollOffsets.removeAll()
        if persistenceEnabled { try Self.persist(notes) }
        lastError = nil
    }

    func exportMarkdown(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for note in notes {
            let filename = note.displayTitle.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
            let safeName = filename.isEmpty ? note.id.uuidString : filename
            let url = directory.appendingPathComponent("\(safeName).md")
            try note.content.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    func importMarkdown(_ urls: [URL]) throws {
        var imported = notes
        for url in urls where url.pathExtension.lowercased() == "md" {
            let content = try String(contentsOf: url, encoding: .utf8)
            guard content.count <= Self.maximumCharactersPerNote else { continue }
            let title = content.split(whereSeparator: { $0 == "\n" }).first.map(String.init)?.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) ?? url.deletingPathExtension().lastPathComponent
            imported.insert(MarkdownNote(title: title, content: content), at: 0)
        }
        try replace(with: Array(imported.prefix(Self.maximumNotes)))
    }

    var selectedNote: MarkdownNote? {
        guard let selectedNoteID else { return nil }
        return notes.first { $0.id == selectedNoteID }
    }

    var canNavigateBack: Bool { !noteBackStack.isEmpty }
    var canNavigateForward: Bool { !noteForwardStack.isEmpty }

    /// Selects a note by stable ID and records the previous note as a
    /// navigation location. Titles are intentionally never used as routes.
    func selectNote(_ identifier: UUID, recordHistory: Bool = true) {
        guard notes.contains(where: { $0.id == identifier }) else { return }
        guard selectedNoteID != identifier else { return }
        if recordHistory, let selectedNoteID {
            noteBackStack.append(selectedNoteID)
            noteForwardStack.removeAll()
        }
        selectedNoteID = identifier
        persistSelectedNote()
    }

    @discardableResult
    func navigateBack() -> Bool {
        pruneNavigationHistory()
        guard let destination = noteBackStack.popLast(),
              let current = selectedNoteID,
              notes.contains(where: { $0.id == destination }) else { return false }
        noteForwardStack.append(current)
        selectedNoteID = destination
        persistSelectedNote()
        return true
    }

    @discardableResult
    func navigateForward() -> Bool {
        pruneNavigationHistory()
        guard let destination = noteForwardStack.popLast(),
              let current = selectedNoteID,
              notes.contains(where: { $0.id == destination }) else { return false }
        noteBackStack.append(current)
        selectedNoteID = destination
        persistSelectedNote()
        return true
    }

    func noteScrollOffset(for identifier: UUID, compact: Bool) -> CGFloat? {
        noteScrollOffsets[scrollKey(for: identifier, compact: compact)]
    }

    func setNoteScrollOffset(_ offset: CGFloat, for identifier: UUID, compact: Bool) {
        guard offset.isFinite, offset >= 0 else { return }
        noteScrollOffsets[scrollKey(for: identifier, compact: compact)] = offset
    }

    func selectMostRecentNote() {
        if let identifier = notes.max(by: { $0.modifiedAt < $1.modifiedAt })?.id {
            selectNote(identifier)
        } else {
            createNote()
        }
    }

    func createNote(template: MarkdownUserTemplate) {
        guard notes.count < Self.maximumNotes else { return }
        let note = MarkdownNote(title: template.title, content: MarkdownNote.normalizedContent(template.content))
        notes.insert(note, at: 0)
        selectedNoteID = note.id
        scheduleSave()
    }

    func saveUserTemplate(title: String, content: String, id: UUID? = nil) {
        let cleanTitle = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        guard !cleanTitle.isEmpty, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let template = MarkdownUserTemplate(id: id ?? UUID(), title: cleanTitle, content: content)
        if let index = userTemplates.firstIndex(where: { $0.id == template.id }) {
            userTemplates[index] = template
        } else {
            userTemplates.append(template)
        }
        persistUserTemplates()
    }

    func deleteUserTemplate(_ id: UUID) {
        userTemplates.removeAll { $0.id == id }
        persistUserTemplates()
    }

    func createNote(template: MarkdownNoteTemplate = .blank) {
        guard notes.count < Self.maximumNotes else {
            lastError = "Lima Notes is limited to \(Self.maximumNotes) notes to keep search and autosave responsive."
            return
        }
        let note = MarkdownNote(title: template.noteTitle, content: MarkdownNote.normalizedContent(template.content))
        notes.insert(note, at: 0)
        selectedNoteID = note.id
        lastError = nil
        scheduleSave()
    }

    /// Create a new editable report after an AI tool's exact-content review.
    /// This path never overwrites an existing note or changes Mail state.
    @discardableResult
    func createAIReportNote(title: String, content: String) throws -> UUID {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = MarkdownNote.normalizedContent(content)
        guard !cleanTitle.isEmpty, cleanTitle.count <= 200,
              !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              normalized.count <= 32_000 else {
            throw NSError(domain: "LimaNotes", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "The report needs a title and 1 to 32,000 characters of Markdown."
            ])
        }
        guard notes.count < Self.maximumNotes else {
            throw NSError(domain: "LimaNotes", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Lima Notes has reached its \(Self.maximumNotes)-note limit."
            ])
        }
        let note = MarkdownNote(title: cleanTitle, content: normalized)
        notes.insert(note, at: 0)
        selectedNoteID = note.id
        lastError = nil
        scheduleSave()
        return note.id
    }

    /// Append only when the note still matches the content the assistant read.
    /// The existing Markdown, user edits, completion state, and revision history
    /// remain intact; a stale proposal must be reviewed against a fresh read.
    @discardableResult
    func appendAIReportMarkdown(to identifier: UUID,
                                expectedContentSHA256: String,
                                content: String) throws -> Int {
        guard let note = notes.first(where: { $0.id == identifier }) else {
            throw NSError(domain: "LimaNotes", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "That local note is unavailable."
            ])
        }
        let currentHash = SHA256.hash(data: Data(note.content.utf8))
            .map { String(format: "%02x", $0) }.joined()
        guard currentHash == expectedContentSHA256 else {
            throw NSError(domain: "LimaNotes", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "The note changed after it was read. Read it again before proposing an append."
            ])
        }
        let addition = MarkdownNote.normalizedContent(content)
        guard !addition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              addition.count <= 32_000 else {
            throw NSError(domain: "LimaNotes", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "The append needs 1 to 32,000 characters of Markdown."
            ])
        }
        let separator = note.content.isEmpty ? ""
            : note.content.hasSuffix("\n\n") ? ""
            : note.content.hasSuffix("\n") ? "\n" : "\n\n"
        let updated = note.content + separator + addition
        guard updated.count <= Self.maximumCharactersPerNote else {
            throw NSError(domain: "LimaNotes", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "This append would exceed the note's character limit."
            ])
        }
        updateNote(identifier) { $0.content = updated }
        return updated.count
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
        lastError = nil
        scheduleSave()
    }

    /// Called only after the user accepts a validated Mail action review.
    /// Existing notes are never refreshed or overwritten by this operation.
    @discardableResult
    func createMailActionNote(_ draft: MailActionNoteDraft) throws -> UUID {
        // A double-click or a late duplicate completion must never create a
        // second note or overwrite edits to the first snapshot.
        if let existing = notes.first(where: { $0.mailTaskProvenance == draft.provenance }) {
            selectedNoteID = existing.id
            return existing.id
        }
        guard notes.count < Self.maximumNotes,
              draft.title.count <= 200,
              draft.markdown.count <= Self.maximumCharactersPerNote,
              !draft.provenance.isEmpty,
              draft.provenance.count <= 50 else {
            throw MailActionReviewError.invalidApproval
        }
        let note = MarkdownNote(
            title: draft.title,
            content: MarkdownNote.normalizedContent(draft.markdown),
            mailTaskProvenance: draft.provenance
        )
        notes.insert(note, at: 0)
        selectedNoteID = note.id
        lastError = nil
        scheduleSave()
        return note.id
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
        pruneNavigationHistory()
        persistSelectedNote()
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
        updateSelected { note in note.content = MarkdownNote.normalizedContent(content) }
    }

    func appendMarkdown(_ markdown: String, to identifier: UUID) {
        guard notes.contains(where: { $0.id == identifier }) else { return }
        let previous = selectedNoteID
        selectedNoteID = identifier
        appendMarkdown(markdown)
        selectedNoteID = previous ?? identifier
    }

    func appendClipboard(to identifier: UUID, clipboard: ClipboardHistoryService) {
        guard let text = clipboard.entries.first?.text else { return }
        appendMarkdown(text, to: identifier)
    }

    func appendClipboard(to identifier: UUID) {
        appendClipboard(to: identifier, clipboard: ClipboardHistoryService.shared)
    }

    func appendDictation(_ conversation: DictationConversation, to identifier: UUID) {
        appendMarkdown(conversation.transcript, to: identifier)
    }

    /// Appends one immutable dictation delta to a note without changing the
    /// selected note or creating a paragraph boundary for each speech callback.
    func appendDictationDelta(_ delta: String, to identifier: UUID) {
        let clean = delta.trimmingCharacters(in: .newlines)
        guard !clean.isEmpty else { return }
        updateNote(identifier) { note in
            let separator = note.content.isEmpty
                || note.content.hasSuffix(" ")
                || note.content.hasSuffix("\n")
                || clean.hasPrefix(" ")
                ? ""
                : " "
            let remaining = Self.maximumCharactersPerNote - note.content.count - separator.count
            guard remaining > 0 else { return }
            note.content += separator + String(clean.prefix(remaining))
        }
    }

    struct TaskSummary: Identifiable, Equatable {
        let id: String
        let noteID: UUID
        let noteTitle: String
        let text: String
        let checked: Bool
    }

    var taskDashboard: [TaskSummary] {
        notes.flatMap { taskSummaries(in: $0) }
    }

    func tasks(for noteID: UUID) -> [TaskSummary] {
        guard let note = notes.first(where: { $0.id == noteID }) else { return [] }
        return taskSummaries(in: note)
    }

    private func taskSummaries(in note: MarkdownNote) -> [TaskSummary] {
        note.content.components(separatedBy: .newlines).enumerated().compactMap { index, line -> TaskSummary? in
            guard let parts = parseTaskLine(line) else { return nil }
            return TaskSummary(id: "\(note.id.uuidString):\(index)", noteID: note.id, noteTitle: note.displayTitle, text: parts.text, checked: parts.checked)
        }
    }

    /// Toggle one visible checklist item without touching a different line if
    /// the note changed between the inspector snapshot and the click.
    @discardableResult
    func toggleTask(_ task: TaskSummary) -> Bool {
        guard let note = notes.first(where: { $0.id == task.noteID }),
              let lineNumber = Int(task.id.split(separator: ":").last ?? "") else { return false }
        var lines = note.content.components(separatedBy: .newlines)
        guard lines.indices.contains(lineNumber),
              let parsed = parseTaskLine(lines[lineNumber]),
              parsed.text == task.text,
              parsed.checked == task.checked,
              let marker = lines[lineNumber].range(of: #"- \[[ xX]\]"#, options: .regularExpression) else {
            return false
        }
        lines[lineNumber].replaceSubrange(marker, with: task.checked ? "- [ ]" : "- [x]")
        let updated = lines.joined(separator: "\n")
        updateNote(task.noteID) { $0.content = updated }
        return true
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

    @discardableResult
    func appendShelfItems(_ items: [ContextShelfItem], to identifier: UUID? = nil) -> Bool {
        guard let markdown = authorizedShelfMarkdown(items),
              let targetID = identifier ?? selectedNoteID,
              let previous = notes.first(where: { $0.id == targetID })?.content else { return false }
        appendMarkdown(markdown, to: targetID)
        return notes.first(where: { $0.id == targetID })?.content != previous
    }

    /// Appends Shelf content to the note that Quick Note would currently target.
    /// This deliberately uses the same persisted mode and target ID as the
    /// Quick Note controller, so Shelf actions do not silently depend on the
    /// workspace's incidental selection.
    func appendShelfItemsToQuickNote(_ items: [ContextShelfItem]) -> UUID? {
        let savedTargetID = LimaTestEnvironment.userDefaults.string(forKey: "quickNoteTargetID")
            .flatMap(UUID.init(uuidString:))
        let mode = LimaTestEnvironment.userDefaults.string(forKey: "quickNoteTargetMode")
            .flatMap(QuickNoteTargetMode.init(rawValue:)) ?? .lastQuickNote
        let targetID = QuickNoteTargetResolver.resolve(
            mode: mode,
            savedTargetID: savedTargetID,
            selectedNoteID: selectedNoteID,
            notes: notes
        )
        guard let targetID, appendShelfItems(items, to: targetID) else { return nil }
        LimaTestEnvironment.userDefaults.set(targetID.uuidString, forKey: "quickNoteTargetID")
        return targetID
    }

    @discardableResult
    func createNoteFromShelf(_ items: [ContextShelfItem]) -> UUID? {
        guard let markdown = authorizedShelfMarkdown(items),
              notes.count < Self.maximumNotes else { return nil }
        let content = MarkdownNote.normalizedContent(markdown)
        guard !content.isEmpty, content.count <= Self.maximumCharactersPerNote else { return nil }
        let note = MarkdownNote(
            title: "Shelf · \(Date().formatted(date: .abbreviated, time: .shortened))",
            content: content
        )
        notes.insert(note, at: 0)
        selectedNoteID = note.id
        scheduleSave()
        return note.id
    }

    /// Mail references remain metadata-only and require current selected-account
    /// access at the moment of transfer, not just when captured on the Shelf.
    private func authorizedShelfMarkdown(_ items: [ContextShelfItem]) -> String? {
        guard !items.isEmpty else { return nil }
        let policy = MailCapabilityPolicyStore.load()
        for item in items where item.isMailReference {
            guard item.kind == .mailReference,
                  case .mailReference(let reference) = item.payload,
                  policy.readEnabled,
                  policy.selectedAccountIDs.contains(reference.accountID) else { return nil }
        }
        let markdown = ContextShelfMarkdownFormatter.format(items)
        return markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : markdown
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
        guard persistenceEnabled else { return }
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
        _ = persistenceGeneration.next()
        let snapshot = notes
        do { try persistenceQueue.sync { try Self.persist(snapshot) } } catch { lastError = error.localizedDescription }
    }

    private func scrollKey(for identifier: UUID, compact: Bool) -> String {
        "\(identifier.uuidString):\(compact ? "sideview" : "workspace")"
    }

    private func pruneNavigationHistory() {
        let validIDs = Set(notes.map(\.id))
        noteBackStack.removeAll { !validIDs.contains($0) }
        noteForwardStack.removeAll { !validIDs.contains($0) }
    }

    private func persistSelectedNote() {
        guard persistenceEnabled else { return }
        WorkspaceStateRegistry.shared.update {
            $0.selectedNoteID = selectedNoteID
            $0.notesSection = "notes"
        }
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

    private func scheduleSave() {
        guard persistenceEnabled else { return }
        pendingSave?.cancel()
        let snapshot = notes
        let generation = persistenceGeneration.next()
        let gate = persistenceGeneration
        let work = DispatchWorkItem {
            guard gate.isCurrent(generation) else { return }
            do {
                try Self.persist(snapshot)
                DispatchQueue.main.async { [weak self] in self?.lastError = nil }
            } catch {
                DispatchQueue.main.async { [weak self] in self?.lastError = error.localizedDescription }
            }
        }
        pendingSave = work
        persistenceQueue.asyncAfter(deadline: .now() + 0.55, execute: work)
    }

    private static let userTemplatesKey = "Lima.Notes.UserTemplates"

    private static func loadUserTemplates() -> [MarkdownUserTemplate] {
        guard let data = LimaTestEnvironment.userDefaults.data(forKey: userTemplatesKey),
              let templates = try? JSONDecoder().decode([MarkdownUserTemplate].self, from: data) else { return [] }
        return templates
    }

    private func persistUserTemplates() {
        guard persistenceEnabled else { return }
        if let data = try? JSONEncoder().encode(userTemplates) {
            LimaTestEnvironment.userDefaults.set(data, forKey: Self.userTemplatesKey)
        }
    }

    private static func loadNotes() -> (notes: [MarkdownNote], error: String?, recoveryURL: URL?, wasMissing: Bool) {
        let loaded = PrivateFileStore().loadJSON([MarkdownNote].self, from: ApplicationPaths.notes)
        guard let decoded = loaded.value else {
            switch loaded.result.state {
            case .missing: return ([], nil, nil, true)
            case .corrupt, .unreadable:
                return ([], "Notes could not be loaded safely. The original file was preserved and a recovery copy was created.", loaded.result.recoveryURL, false)
            case .loaded: return ([], "Notes could not be decoded.", loaded.result.recoveryURL, false)
            }
        }
        let bounded = decoded.prefix(maximumNotes).map { note in
            var bounded = note
            bounded.title = String(note.title.prefix(200))
            bounded.content = MarkdownNote.normalizedContent(String(note.content.prefix(maximumCharactersPerNote)))
            bounded.tags = MarkdownNoteLinks.normalizedTags(note.tags)
            bounded.revisionHistory = Array(note.revisionHistory.suffix(maximumRevisionsPerNote))
            return bounded
        }
        return (Array(bounded), nil, nil, false)
    }

    private nonisolated static func persist(_ notes: [MarkdownNote]) throws {
        let data = try JSONEncoder().encode(notes)
        try PrivateFileStore().write(data: data, to: ApplicationPaths.notes)
    }
}
