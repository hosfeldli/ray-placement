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

struct MailActionNoteUpdateResult: Sendable {
    let noteID: UUID
    let addedTaskCount: Int
    let skippedDuplicateCount: Int
    /// Only reviewed tasks represented by a checklist line and matching Mail
    /// provenance in the saved Note may be linked to new Reminders.
    let reminderEligibleTaskIDs: Set<UUID>
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
        return try applyReviewedAIContent(
            to: identifier, expectedContentSHA256: expectedContentSHA256
        ) { _ in updated }
    }

    /// Replace one complete, uniquely identified line-aligned block. The hash
    /// comparison and mutation run together on the main actor, so a concurrent
    /// user edit cannot be silently overwritten after the AI's read.
    @discardableResult
    func replaceAIBlock(in identifier: UUID, expectedContentSHA256: String,
                        oldText: String, newText: String) throws -> Int {
        guard !oldText.isEmpty, oldText.count <= 32_000, newText.count <= 32_000,
              !newText.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 0x7F }) else {
            throw aiEditError(8, "A block edit needs 1 to 32,000 characters of existing text and at most 32,000 replacement characters.")
        }
        return try applyReviewedAIContent(to: identifier, expectedContentSHA256: expectedContentSHA256) { content in
            guard let range = content.range(of: oldText),
                  content.range(of: oldText, range: range.upperBound..<content.endIndex) == nil else {
                throw aiEditError(9, "The exact block is missing or appears more than once. Read the note again and choose a unique block.")
            }
            let startsOnLine = range.lowerBound == content.startIndex ||
                content[content.index(before: range.lowerBound)] == "\n"
            let endsOnLine = range.upperBound == content.endIndex ||
                content[range.upperBound] == "\n"
            guard startsOnLine && endsOnLine else {
                throw aiEditError(10, "Replace a complete line, paragraph, table row, or section rather than part of a line.")
            }
            return content.replacingCharacters(in: range, with: newText)
        }
    }

    /// Add native Markdown checklists to one existing section without replacing
    /// its other content or re-adding tasks already present in the note.
    @discardableResult
    func addAITasks(to identifier: UUID, expectedContentSHA256: String,
                    sectionHeading: String, tasks: [String]) throws -> Int {
        guard (1...25).contains(tasks.count),
              sectionHeading.count <= 200,
              !sectionHeading.contains("\n"),
              tasks.allSatisfy({ task in
                  let clean = task.trimmingCharacters(in: .whitespacesAndNewlines)
                  return task == clean && !clean.isEmpty && clean.count <= 500 &&
                      !task.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
                      !task.contains("![") && !task.localizedCaseInsensitiveContains("<img")
              }) else {
            throw aiEditError(11, "Add 1 to 25 plain-text task titles of at most 500 characters under one existing heading.")
        }
        let titles = tasks
        guard Set(titles.map { $0.lowercased() }).count == titles.count else {
            throw aiEditError(12, "The proposed checklist contains duplicate tasks.")
        }
        return try applyReviewedAIContent(to: identifier, expectedContentSHA256: expectedContentSHA256) { content in
            var lines = content.components(separatedBy: "\n")
            let visibleLines = visibleMarkdownLineIndices(lines)
            let headingPositions = lines.indices.filter {
                visibleLines.contains($0) && lines[$0] == sectionHeading
            }
            let level = sectionHeading.prefix(while: { $0 == "#" }).count
            let headingTitle = String(sectionHeading.dropFirst(level))
                .trimmingCharacters(in: .whitespaces)
            guard headingPositions.count == 1, (1...6).contains(level),
                  sectionHeading.dropFirst(level).hasPrefix(" "),
                  !headingTitle.isEmpty else {
                throw aiEditError(13, "The exact section heading is missing or ambiguous. Read the note again.")
            }
            let headingIndex = headingPositions[0]
            let existingTasks = Set(lines.compactMap { parseTaskLine($0)?.text.lowercased() })
            guard titles.allSatisfy({ !existingTasks.contains($0.lowercased()) }) else {
                throw aiEditError(14, "A proposed task already exists in this note.")
            }
            var sectionEnd = lines.count
            for index in (headingIndex + 1)..<lines.count {
                let candidate = lines[index]
                let candidateLevel = candidate.prefix(while: { $0 == "#" }).count
                if visibleLines.contains(index),
                   (1...level).contains(candidateLevel),
                   candidate.dropFirst(candidateLevel).hasPrefix(" ") {
                    sectionEnd = index
                    break
                }
            }
            var insertAt = sectionEnd
            while insertAt > headingIndex + 1 &&
                lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                insertAt -= 1
            }
            var additions = titles.map { "- [ ] " + $0 }
            if insertAt > headingIndex + 1 && !lines[insertAt - 1].isEmpty {
                additions.insert("", at: 0)
            }
            if insertAt < lines.count && !lines[insertAt].isEmpty {
                additions.append("")
            }
            lines.insert(contentsOf: additions, at: insertAt)
            return lines.joined(separator: "\n")
        }
    }

    /// Complete exactly one unchecked checklist line. A stale hash or repeated
    /// task title fails closed instead of checking an unintended item.
    @discardableResult
    func completeAITask(in identifier: UUID, expectedContentSHA256: String,
                        taskLine: String) throws -> Int {
        guard taskLine.count <= 600, !taskLine.contains("\n"),
              let parsed = parseTaskLine(taskLine), !parsed.checked,
              !parsed.text.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw aiEditError(15, "Choose one exact, unchecked Markdown checklist line from the note.")
        }
        return try applyReviewedAIContent(to: identifier, expectedContentSHA256: expectedContentSHA256) { content in
            var lines = content.components(separatedBy: "\n")
            let visibleLines = visibleMarkdownLineIndices(lines)
            let matches = lines.indices.filter {
                visibleLines.contains($0) && lines[$0] == taskLine
            }
            guard matches.count == 1, let checkbox = lines[matches[0]].range(of: "[ ]") else {
                throw aiEditError(16, "The unchecked task is missing or ambiguous. Read the note again.")
            }
            lines[matches[0]].replaceSubrange(checkbox, with: "[x]")
            return lines.joined(separator: "\n")
        }
    }

    /// Update one exact native checklist row and its direct Due/Priority
    /// metadata. Unrelated child rows and other tasks remain byte-for-byte
    /// intact; the full Note hash still guards against concurrent user edits.
    @discardableResult
    func updateAITask(
        in identifier: UUID, expectedContentSHA256: String,
        taskLine: String, newTitle: String?,
        deadline: String, priority: String, completion: String
    ) throws -> Int {
        let titleValid = newTitle.map { title in
            title == title.trimmingCharacters(in: .whitespacesAndNewlines) &&
                !title.isEmpty && title.count <= 500 &&
                !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
                !title.contains("![") && !title.localizedCaseInsensitiveContains("<img")
        } ?? true
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate]
        let dateValid = deadline == "keep" || deadline == "none" ||
            (dateFormatter.date(from: deadline).map { dateFormatter.string(from: $0) == deadline } ?? false)
        let indentation = String(taskLine.prefix(while: { $0 == " " }))
        guard taskLine.count <= 600, !taskLine.contains("\n"),
              let parsed = parseTaskLine(taskLine),
              taskLine.hasPrefix(indentation + "- ["), indentation.count <= 16,
              titleValid, dateValid,
              ["keep", "none", "low", "normal", "high", "urgent"].contains(priority),
              ["keep", "open", "done"].contains(completion),
              newTitle != nil || deadline != "keep" || priority != "keep" || completion != "keep" else {
            throw aiEditError(24, "Choose one exact checklist row and valid title, YYYY-MM-DD deadline, priority, or completion change.")
        }
        return try applyReviewedAIContent(
            to: identifier, expectedContentSHA256: expectedContentSHA256
        ) { content in
            var lines = content.components(separatedBy: "\n")
            let visible = visibleMarkdownLineIndices(lines)
            let matches = lines.indices.filter {
                visible.contains($0) && lines[$0] == taskLine
            }
            guard matches.count == 1 else {
                throw aiEditError(16, "The task row is missing or ambiguous. Read the Note again.")
            }
            let index = matches[0]
            var updatedLine = taskLine
            if let newTitle {
                guard updatedLine.hasSuffix(parsed.text) else {
                    throw aiEditError(24, "The checklist title could not be identified safely.")
                }
                updatedLine = String(updatedLine.dropLast(parsed.text.count)) + newTitle
            }
            if completion != "keep" {
                guard let marker = updatedLine.range(of: #"\[[ xX]\]"#, options: .regularExpression) else {
                    throw aiEditError(24, "The checklist state could not be identified safely.")
                }
                updatedLine.replaceSubrange(marker, with: completion == "done" ? "[x]" : "[ ]")
            }
            lines[index] = updatedLine

            let duePrefix = indentation + "  - Due:"
            let priorityPrefix = indentation + "  - Priority:"
            var dueRows: [Int] = []
            var priorityRows: [Int] = []
            if index + 1 < lines.count {
                for row in (index + 1)..<lines.count {
                    let line = lines[row]
                    if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                    let depth = line.prefix(while: { $0 == " " }).count
                    if depth <= indentation.count || parseTaskLine(line) != nil { break }
                    guard visible.contains(row) else { continue }
                    if line.hasPrefix(duePrefix) { dueRows.append(row) }
                    if line.hasPrefix(priorityPrefix) { priorityRows.append(row) }
                }
            }
            guard dueRows.count <= 1, priorityRows.count <= 1 else {
                throw aiEditError(25, "This task has repeated Due or Priority rows. Resolve them manually before updating it.")
            }

            var replacements: [(index: Int, value: String?)] = []
            var additions: [String] = []
            if deadline != "keep" {
                let value = deadline == "none" ? nil : duePrefix + " " + deadline
                if let row = dueRows.first {
                    replacements.append((row, value))
                } else if let value {
                    additions.append(value)
                }
            }
            if priority != "keep" {
                let value = priority == "none" ? nil : priorityPrefix + " " + priority.capitalized
                if let row = priorityRows.first {
                    replacements.append((row, value))
                } else if let value {
                    additions.append(value)
                }
            }
            for replacement in replacements.sorted(by: { $0.index > $1.index }) {
                if let value = replacement.value {
                    lines[replacement.index] = value
                } else {
                    lines.remove(at: replacement.index)
                }
            }
            lines.insert(contentsOf: additions, at: index + 1)
            return lines.joined(separator: "\n")
        }
    }

    /// Apply a reviewed set of exact, non-overlapping block edits as one
    /// revision. Every old block must appear once in the content the agent read.
    @discardableResult
    func updateAIBlocks(
        in identifier: UUID, expectedContentSHA256: String,
        edits: [(oldText: String, newText: String)]
    ) throws -> Int {
        guard (1...10).contains(edits.count),
              edits.reduce(0, { $0 + $1.oldText.count + $1.newText.count }) <= 64_000,
              edits.allSatisfy({ edit in
                  !edit.oldText.isEmpty && edit.oldText.count <= 32_000 &&
                  edit.newText.count <= 32_000 &&
                  !edit.newText.unicodeScalars.contains(where: {
                      $0.value == 0 || $0.value == 0x7F
                  })
              }) else {
            throw aiEditError(18, "Update 1 to 10 exact blocks with at most 32,000 characters each and 64,000 reviewed characters total.")
        }
        return try applyReviewedAIContent(
            to: identifier, expectedContentSHA256: expectedContentSHA256
        ) { content in
            var located: [(range: Range<String.Index>, replacement: String)] = []
            for edit in edits {
                guard let range = content.range(of: edit.oldText),
                      content.range(of: edit.oldText,
                          range: range.upperBound..<content.endIndex) == nil else {
                    throw aiEditError(9, "An old block is missing or repeated. Read the Note again and choose unique blocks.")
                }
                let beginsOnLine = range.lowerBound == content.startIndex ||
                    content[content.index(before: range.lowerBound)] == "\n"
                let endsOnLine = range.upperBound == content.endIndex ||
                    content[range.upperBound] == "\n"
                guard beginsOnLine && endsOnLine else {
                    throw aiEditError(10, "Each update must replace complete lines or blocks.")
                }
                located.append((range, edit.newText))
            }
            located.sort { $0.range.lowerBound < $1.range.lowerBound }
            for pair in zip(located, located.dropFirst()) {
                guard pair.0.range.upperBound <= pair.1.range.lowerBound else {
                    throw aiEditError(19, "The proposed block edits overlap.")
                }
            }
            var output = ""
            var cursor = content.startIndex
            for edit in located {
                output += content[cursor..<edit.range.lowerBound]
                output += edit.replacement
                cursor = edit.range.upperBound
            }
            output += content[cursor..<content.endIndex]
            return output
        }
    }

    struct AIMoveResult: Sendable {
        let sourceCharacters: Int
        let destinationCharacters: Int
    }

    /// Move one complete exact block between two unchanged Notes. Both hashes
    /// are checked before either Note changes, then both revisions are saved
    /// together on the main actor.
    @discardableResult
    func moveAIBlock(
        from sourceID: UUID, sourceSHA256: String,
        to destinationID: UUID, destinationSHA256: String,
        block: String, afterText: String?
    ) throws -> AIMoveResult {
        guard sourceID != destinationID,
              !block.isEmpty, block.count <= 32_000,
              let sourceIndex = notes.firstIndex(where: { $0.id == sourceID }),
              let destinationIndex = notes.firstIndex(where: { $0.id == destinationID }) else {
            throw aiEditError(20, "Choose two different available Notes and one nonempty block.")
        }
        let source = notes[sourceIndex]
        let destination = notes[destinationIndex]
        func hash(_ text: String) -> String {
            SHA256.hash(data: Data(text.utf8))
                .map { String(format: "%02x", $0) }.joined()
        }
        guard hash(source.content) == sourceSHA256,
              hash(destination.content) == destinationSHA256 else {
            throw aiEditError(5, "A Note changed after it was read. Read both Notes again before moving content.")
        }
        guard let range = source.content.range(of: block),
              source.content.range(of: block,
                  range: range.upperBound..<source.content.endIndex) == nil else {
            throw aiEditError(9, "The source block is missing or repeated.")
        }
        let beginsOnLine = range.lowerBound == source.content.startIndex ||
            source.content[source.content.index(before: range.lowerBound)] == "\n"
        let endsOnLine = range.upperBound == source.content.endIndex ||
            source.content[range.upperBound] == "\n"
        guard beginsOnLine && endsOnLine else {
            throw aiEditError(10, "Move a complete line-aligned paragraph, table, or section.")
        }
        // Mail-linked tasks have separate structured source identity. A
        // checklist block in a Note with Mail provenance cannot be moved by
        // text alone, including after its user-visible title was edited.
        let containsChecklist = block.components(separatedBy: "\n")
            .contains { parseTaskLine($0) != nil }
        guard source.mailTaskProvenance.isEmpty || !containsChecklist else {
            throw aiEditError(21, "A Mail-linked checklist needs a provenance-aware move. Leave it in this Note.")
        }
        let linkedTitles = source.mailTaskProvenance.compactMap(\.taskTitle)
        guard !linkedTitles.contains(where: { block.localizedCaseInsensitiveContains($0) }) else {
            throw aiEditError(21, "A Mail-linked task needs a provenance-aware move. Leave it in this Note.")
        }
        let sourceUpdated = source.content.replacingCharacters(in: range, with: "")
        let destinationUpdated: String
        if let afterText {
            guard !afterText.isEmpty, afterText.count <= 32_000,
                  let anchor = destination.content.range(of: afterText),
                  destination.content.range(of: afterText,
                      range: anchor.upperBound..<destination.content.endIndex) == nil else {
                throw aiEditError(22, "The destination anchor is missing or repeated.")
            }
            let anchorOnLine = anchor.lowerBound == destination.content.startIndex ||
                destination.content[destination.content.index(before: anchor.lowerBound)] == "\n"
            let anchorEndsOnLine = anchor.upperBound == destination.content.endIndex ||
                destination.content[anchor.upperBound] == "\n"
            guard anchorOnLine && anchorEndsOnLine else {
                throw aiEditError(23, "Choose a complete destination line or block as the anchor.")
            }
            destinationUpdated = String(destination.content[..<anchor.upperBound]) +
                "\n\n" + block + String(destination.content[anchor.upperBound...])
        } else {
            let separator = destination.content.isEmpty ? "" :
                destination.content.hasSuffix("\n\n") ? "" :
                destination.content.hasSuffix("\n") ? "\n" : "\n\n"
            destinationUpdated = destination.content + separator + block
        }
        guard destinationUpdated.count <= Self.maximumCharactersPerNote else {
            throw aiEditError(7, "The destination Note would exceed its character limit.")
        }
        recordImmediateAIRevision(at: sourceIndex)
        recordImmediateAIRevision(at: destinationIndex)
        notes[sourceIndex].content = sourceUpdated
        notes[destinationIndex].content = destinationUpdated
        let now = Date()
        notes[sourceIndex].modifiedAt = now
        notes[destinationIndex].modifiedAt = now
        selectedNoteID = destinationID
        lastError = nil
        scheduleSave()
        return AIMoveResult(
            sourceCharacters: sourceUpdated.count,
            destinationCharacters: destinationUpdated.count
        )
    }

    /// Commit a separate undoable revision for an approved AI edit. Any pending
    /// user-edit snapshot is committed first, so the AI change has its own
    /// restore point in the existing Note revision history.
    private func applyReviewedAIContent(
        to identifier: UUID, expectedContentSHA256: String,
        transform: (String) throws -> String
    ) throws -> Int {
        guard let index = notes.firstIndex(where: { $0.id == identifier }) else {
            throw aiEditError(4, "That local note is unavailable.")
        }
        let before = notes[index]
        let currentHash = SHA256.hash(data: Data(before.content.utf8))
            .map { String(format: "%02x", $0) }.joined()
        guard currentHash == expectedContentSHA256 else {
            throw aiEditError(5, "The note changed after it was read. Read it again before proposing an edit.")
        }
        let updated = try transform(before.content)
        guard updated != before.content else {
            throw aiEditError(17, "The proposed edit would not change the note.")
        }
        guard updated.count <= Self.maximumCharactersPerNote else {
            throw aiEditError(7, "This edit would exceed the note's character limit.")
        }
        recordImmediateAIRevision(at: index)
        notes[index].content = updated
        notes[index].modifiedAt = Date()
        lastError = nil
        scheduleSave()
        return updated.count
    }

    private func recordImmediateAIRevision(at index: Int) {
        let before = notes[index]
        let identifier = before.id
        if let pending = pendingRevisionSnapshots.removeValue(forKey: identifier) {
            revisionWorkItems[identifier]?.cancel()
            revisionWorkItems.removeValue(forKey: identifier)
            revisionGenerations.removeValue(forKey: identifier)
            notes[index].revisionHistory.append(pending)
        }
        notes[index].revisionHistory.append(NoteRevision(
            title: before.title, content: before.content,
            mailTaskProvenance: before.mailTaskProvenance
        ))
        notes[index].revisionHistory = Array(notes[index].revisionHistory.suffix(Self.maximumRevisionsPerNote))
    }

    private func aiEditError(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "LimaNotes", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// A bounded Markdown fence scan for checklist edits. A different marker
    /// inside an open fence is content, not the fence's closing delimiter.
    private func visibleMarkdownLineIndices(_ lines: [String]) -> Set<Int> {
        var visible = Set<Int>()
        var fenceMarker: Character?
        var fenceLength = 0
        for (index, line) in lines.enumerated() {
            let indentation = line.prefix(while: { $0 == " " }).count
            if indentation <= 3 {
                let remainder = line.dropFirst(indentation)
                if let first = remainder.first,
                   first.asciiValue == 96 || first.asciiValue == 126 {
                    let runLength = remainder.prefix(while: { $0 == first }).count
                    if runLength >= 3 {
                        if let openMarker = fenceMarker {
                            if first == openMarker, runLength >= fenceLength,
                               String(remainder.dropFirst(runLength))
                                .trimmingCharacters(in: .whitespaces).isEmpty {
                                fenceMarker = nil
                                fenceLength = 0
                                continue
                            }
                        } else {
                            fenceMarker = first
                            fenceLength = runLength
                            continue
                        }
                    }
                }
            }
            if fenceMarker == nil { visible.insert(index) }
        }
        return visible
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
        // A later AI run assigns fresh proposal UUIDs and capture times. Match
        // reviewed task titles plus an original source identity so processing
        // the same conversation again does not create a duplicate Note.
        func normalized(_ title: String) -> String {
            title.split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ").lowercased()
        }
        func sameSource(_ a: MarkdownMailSource, _ b: MarkdownMailSource) -> Bool {
            guard a.accountID == b.accountID else { return false }
            if let left = a.internetMessageID, let right = b.internetMessageID {
                return left == right
            }
            return a.mailboxID == b.mailboxID && a.messageID == b.messageID
        }
        if !draft.entries.isEmpty,
           let existing = notes.first(where: { note in
               draft.entries.allSatisfy { entry in
                   note.mailTaskProvenance.contains { prior in
                       guard prior.taskTitle.map(normalized) == normalized(entry.title) else {
                           return false
                       }
                       return prior.sourceMessages.contains { oldSource in
                           entry.provenance.sourceMessages.contains { newSource in
                               sameSource(oldSource, newSource)
                           }
                       }
                   }
               }
           }) {
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

    /// Append only new, reviewed Mail tasks to an existing note. A stale content
    /// hash fails before either Markdown or provenance changes. Existing prose,
    /// checked boxes, and user-authored task lines are never rewritten.
    @discardableResult
    func updateMailActionNote(
        _ draft: MailActionNoteDraft, in identifier: UUID,
        expectedContentSHA256: String
    ) throws -> MailActionNoteUpdateResult {
        guard let index = notes.firstIndex(where: { $0.id == identifier }),
              !draft.entries.isEmpty, draft.entries.count <= 50 else {
            throw MailActionReviewError.invalidApproval
        }
        let note = notes[index]
        let currentHash = SHA256.hash(data: Data(note.content.utf8))
            .map { String(format: "%02x", $0) }.joined()
        guard currentHash == expectedContentSHA256 else {
            throw aiEditError(5, "The note changed during Mail review. Review the current note before adding these tasks.")
        }
        func key(_ title: String) -> String {
            title.split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ").lowercased()
        }
        let checklistLines = note.content.components(separatedBy: .newlines)
            .compactMap(parseTaskLine)
        let checklistTitles = Set(checklistLines.map { key($0.text) })
        let openChecklistTitles = Set(checklistLines.filter { !$0.checked }.map { key($0.text) })
        var knownTitles = Set(note.mailTaskProvenance.compactMap(\.taskTitle).map(key))
        knownTitles.formUnion(checklistTitles)
        func sameSource(_ a: MarkdownMailSource, _ b: MarkdownMailSource) -> Bool {
            guard a.accountID == b.accountID else { return false }
            if let left = a.internetMessageID, let right = b.internetMessageID {
                return left == right
            }
            return a.mailboxID == b.mailboxID && a.messageID == b.messageID
        }
        var additions: [MailActionNoteEntry] = []
        var reminderEligibleTaskIDs: Set<UUID> = []
        for entry in draft.entries {
            let title = key(entry.title)
            let markdownTitle = key(MailActionReview.escapeMarkdown(entry.title))
            if knownTitles.contains(title) || knownTitles.contains(markdownTitle) {
                // A matching user-written title or stale provenance is not a
                // source-backed Note task and must not create a linked Reminder.
                let represented = (openChecklistTitles.contains(title) ||
                    openChecklistTitles.contains(markdownTitle)) &&
                    note.mailTaskProvenance.contains { prior in
                        prior.taskTitle.map(key) == title &&
                            prior.sourceMessages.contains { oldSource in
                                entry.provenance.sourceMessages.contains { newSource in
                                    sameSource(oldSource, newSource)
                                }
                            }
                    }
                if represented { reminderEligibleTaskIDs.insert(entry.provenance.taskID) }
                continue
            }
            guard !entry.markdownLines.isEmpty else {
                throw MailActionReviewError.invalidApproval
            }
            knownTitles.insert(title)
            knownTitles.insert(markdownTitle)
            additions.append(entry)
            reminderEligibleTaskIDs.insert(entry.provenance.taskID)
        }
        selectedNoteID = identifier
        guard !additions.isEmpty else {
            return MailActionNoteUpdateResult(
                noteID: identifier, addedTaskCount: 0,
                skippedDuplicateCount: draft.entries.count,
                reminderEligibleTaskIDs: reminderEligibleTaskIDs
            )
        }
        let section = (["## Mail action items", ""] +
            additions.flatMap(\.markdownLines)).joined(separator: "\n")
        _ = try appendAIReportMarkdown(
            to: identifier, expectedContentSHA256: expectedContentSHA256,
            content: section
        )
        guard let updatedIndex = notes.firstIndex(where: { $0.id == identifier }) else {
            throw aiEditError(4, "That local note is unavailable.")
        }
        notes[updatedIndex].mailTaskProvenance.append(contentsOf: additions.map(\.provenance))
        notes[updatedIndex].modifiedAt = Date()
        lastError = nil
        scheduleSave()
        return MailActionNoteUpdateResult(
            noteID: identifier, addedTaskCount: additions.count,
            skippedDuplicateCount: draft.entries.count - additions.count,
            reminderEligibleTaskIDs: reminderEligibleTaskIDs
        )
    }

    /// Recheck the live Note immediately before a user-invoked Mail task is
    /// linked to Reminders. Provenance alone may outlive an edited or completed
    /// checkbox, so both the open checklist line and original source must match.
    func containsOpenMailTask(_ task: ExtractedMailTask, in identifier: UUID) -> Bool {
        guard let note = notes.first(where: { $0.id == identifier }),
              !task.evidence.isEmpty else { return false }
        func key(_ title: String) -> String {
            title.split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ").lowercased()
        }
        let title = key(task.title)
        let markdownTitle = key(MailActionReview.escapeMarkdown(task.title))
        guard note.content.components(separatedBy: .newlines)
            .compactMap(parseTaskLine)
            .contains(where: { !$0.checked &&
                (key($0.text) == title || key($0.text) == markdownTitle) }) else { return false }
        return note.mailTaskProvenance.contains { prior in
            guard prior.taskTitle.map(key) == title else { return false }
            return prior.sourceMessages.contains { source in
                task.evidence.contains { evidence in
                    let reference = evidence.reference
                    guard source.accountID == reference.accountID else { return false }
                    if let left = source.internetMessageID,
                       let right = reference.internetMessageID {
                        return left == right
                    }
                    return source.mailboxID == reference.mailboxID &&
                        source.messageID == reference.messageID
                }
            }
        }
    }

    func contentSHA256(for identifier: UUID) -> String? {
        guard let note = notes.first(where: { $0.id == identifier }) else { return nil }
        return SHA256.hash(data: Data(note.content.utf8))
            .map { String(format: "%02x", $0) }.joined()
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
            if let provenance = revision.mailTaskProvenance {
                note.mailTaskProvenance = provenance
            }
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
        for item in items where item.isBrowserReference {
            guard item.kind == .browserReference,
                  case .browserReference(let reference) = item.payload,
                  reference.isValid else { return nil }
        }
        let messagesPolicy = MessagesCapabilityPolicyStore.load()
        for item in items where item.isMessageReference {
            guard item.kind == .messageReference,
                  case .messageReference(let reference) = item.payload,
                  reference.isValid,
                  messagesPolicy.permits(reference.conversationGUID) else { return nil }
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
            pendingRevisionSnapshots[identifier] = NoteRevision(
                title: before.title, content: before.content,
                mailTaskProvenance: before.mailTaskProvenance
            )
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
