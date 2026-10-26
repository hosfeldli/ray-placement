import Foundation
import RayPlacementCore

enum MailTaskStatus: String, Codable, Sendable {
    case proposed
    case active
    case completed
    case superseded
    case canceled
    case uncertain
}

struct MailTaskEvidence: Codable, Hashable, Sendable {
    let reference: MailMessageReference
    let excerpt: String
}

/// A proposed action is data from an untrusted message or model response, not
/// authority to read Mail, create a note, or change a message.
struct ExtractedMailTask: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let title: String
    let details: String?
    let owner: String?
    let dueDate: Date?
    let dueDateSource: String?
    let confidence: Double
    let status: MailTaskStatus
    let inferred: Bool
    let evidence: [MailTaskEvidence]
}

enum MailActionReviewError: Error, Equatable {
    case invalidProposal
    case unverifiedEvidence
    case invalidApproval
}

/// A bounded, validated review is the only input to a Mail-linked note.
/// Building one never invokes AI or Apple Events and never retains full bodies.
struct MailActionReview: Sendable {
    let tasks: [ExtractedMailTask]
    let capturedAt: Date

    private init(tasks: [ExtractedMailTask], capturedAt: Date) {
        self.tasks = tasks
        self.capturedAt = capturedAt
    }

    static func build(
        candidates: [ExtractedMailTask],
        from messages: [MailMessage],
        capturedAt: Date = Date()
    ) throws -> MailActionReview {
        guard !candidates.isEmpty, candidates.count <= 50,
              !messages.isEmpty, messages.count <= 50,
              Set(candidates.map(\.id)).count == candidates.count,
              Set(messages.map { $0.reference.id }).count == messages.count,
              messages.allSatisfy({ message in
                  message.body.utf8.count <= 128 * 1_024 &&
                  message.reference.messageID > 0 &&
                  isMetadataLine(message.reference.accountID, maximum: 256) &&
                  isMetadataLine(message.reference.mailboxID, maximum: 256) &&
                  isMetadataLine(message.reference.subject, maximum: 500) &&
                  isMetadataLine(message.reference.sender, maximum: 300) &&
                  (message.reference.internetMessageID?.utf8.count ?? 0) <= 512
              }) else {
            throw MailActionReviewError.invalidProposal
        }
        let sources = Dictionary(uniqueKeysWithValues: messages.map { ($0.reference.id, $0) })
        for task in candidates {
            guard isSingleLine(task.title, maximum: 160),
                  task.confidence.isFinite, (0...1).contains(task.confidence),
                  task.evidence.count > 0, task.evidence.count <= 10,
                  task.details.map({ isParagraph($0, maximum: 1_000) }) ?? true,
                  task.owner.map({ isSingleLine($0, maximum: 100) }) ?? true,
                  task.dueDateSource.map({ isSingleLine($0, maximum: 100) }) ?? true,
                  task.dueDate.map({ $0.timeIntervalSince1970.isFinite }) ?? true else {
                throw MailActionReviewError.invalidProposal
            }
            for evidence in task.evidence {
                guard isParagraph(evidence.excerpt, maximum: 350),
                      let source = sources[evidence.reference.id],
                      source.reference == evidence.reference,
                      source.body.contains(evidence.excerpt) else {
                    throw MailActionReviewError.unverifiedEvidence
                }
            }
        }
        return MailActionReview(tasks: candidates, capturedAt: capturedAt)
    }

    /// The UI must pass an explicit subset after review. Completed/canceled
    /// interpretations are not silently turned into new actionable checkboxes.
    func snapshotNote(
        title: String,
        approvedTaskIDs: Set<UUID>
    ) throws -> MailActionNoteDraft {
        guard Self.isSingleLine(title, maximum: 200),
              !approvedTaskIDs.isEmpty,
              approvedTaskIDs.isSubset(of: Set(tasks.map(\.id))) else {
            throw MailActionReviewError.invalidApproval
        }
        let approved = tasks.filter { approvedTaskIDs.contains($0.id) }
        guard approved.allSatisfy({ [.proposed, .active, .uncertain].contains($0.status) }) else {
            throw MailActionReviewError.invalidApproval
        }
        var lines = ["# \(Self.escapeMarkdown(title))", "", "## Action items", ""]
        var provenance: [MarkdownMailTaskProvenance] = []
        for task in approved {
            lines.append("- [ ] \(Self.escapeMarkdown(task.title))")
            if let owner = task.owner {
                lines.append("  - Owner: \(Self.escapeMarkdown(owner))")
            }
            if let due = task.dueDate {
                lines.append("  - Due: \(due.formatted(date: .abbreviated, time: .omitted))\(task.inferred ? " (inferred)" : "")")
            }
            let sources = task.evidence.map { evidence in
                MarkdownMailSource(
                    accountID: evidence.reference.accountID,
                    mailboxID: evidence.reference.mailboxID,
                    messageID: evidence.reference.messageID,
                    internetMessageID: evidence.reference.internetMessageID,
                    subject: evidence.reference.subject,
                    sender: evidence.reference.sender,
                    receivedAt: evidence.reference.receivedAt
                )
            }
            provenance.append(MarkdownMailTaskProvenance(
                taskID: task.id,
                sourceMessages: sources,
                evidenceExcerpts: task.evidence.map(\.excerpt),
                capturedAt: capturedAt
            ))
        }
        lines += ["", "## Sources", ""]
        let references = Dictionary(
            approved.flatMap(\.evidence).map { ($0.reference.id, $0.reference) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted { $0.receivedAt < $1.receivedAt }
        for reference in references {
            lines.append("- \(Self.escapeMarkdown(reference.subject)) — \(Self.escapeMarkdown(reference.sender))")
        }
        return MailActionNoteDraft(
            title: title,
            markdown: lines.joined(separator: "\n"),
            provenance: provenance
        )
    }

    private static func isSingleLine(_ text: String, maximum: Int) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !clean.isEmpty && text.count <= maximum &&
            !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func isParagraph(_ text: String, maximum: Int) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !clean.isEmpty && text.count <= maximum &&
            !text.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 0x7F })
    }

    private static func isMetadataLine(_ text: String, maximum: Int) -> Bool {
        text.utf8.count <= maximum &&
            !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func escapeMarkdown(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "`", with: "\\`")
    }
}

/// A user-authored action from one opened message. The excerpt must still be
/// found in a fresh, policy-checked read immediately before note creation.
struct MailManualActionNoteProposal: Sendable {
    let source: MailMessageReference
    let noteTitle: String
    let actionTitle: String
    let evidenceExcerpt: String
    let taskID: UUID
    let capturedAt: Date

    func draft(from message: MailMessage) throws -> MailActionNoteDraft {
        guard !evidenceExcerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              evidenceExcerpt.count <= 350,
              !evidenceExcerpt.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 0x7F }) else {
            throw MailActionReviewError.invalidProposal
        }
        guard message.reference == source else {
            throw MailActionReviewError.unverifiedEvidence
        }
        let task = ExtractedMailTask(
            id: taskID, title: actionTitle, details: nil, owner: nil,
            dueDate: nil, dueDateSource: nil, confidence: 1,
            status: .proposed, inferred: false,
            evidence: [MailTaskEvidence(reference: source, excerpt: evidenceExcerpt)]
        )
        let review = try MailActionReview.build(
            candidates: [task], from: [message], capturedAt: capturedAt
        )
        return try review.snapshotNote(title: noteTitle, approvedTaskIDs: [taskID])
    }
}

struct MailActionNoteDraft: Sendable {
    let title: String
    let markdown: String
    let provenance: [MarkdownMailTaskProvenance]

    fileprivate init(title: String, markdown: String, provenance: [MarkdownMailTaskProvenance]) {
        self.title = title
        self.markdown = markdown
        self.provenance = provenance
    }
}
