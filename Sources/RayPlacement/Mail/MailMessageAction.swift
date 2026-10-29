import Foundation

/// Message changes are initiated only from a visible, selected-account Mail
/// surface. Moving to Archive is a distinct user intent but uses Mail's native
/// move operation after resolving an exact mailbox in the same account.
enum MailMessageActionKind: Hashable, Sendable {
    case move(MailMailbox)
    case archive(MailMailbox)
    case delete

    var targetMailbox: MailMailbox? {
        switch self {
        case .move(let mailbox), .archive(let mailbox):
            return mailbox
        case .delete:
            return nil
        }
    }

    var requiredOperation: MailOperation {
        switch self {
        case .move, .archive: return .move
        case .delete: return .delete
        }
    }
}

struct MailMessageActionRequest: Hashable, Sendable {
    let reference: MailMessageReference
    let kind: MailMessageActionKind

    func validate() throws {
        guard !reference.accountID.isEmpty, reference.accountID.utf8.count <= 256,
              !reference.mailboxID.isEmpty, reference.mailboxID.utf8.count <= 256,
              reference.messageID > 0,
              reference.subject.utf8.count <= 500,
              !reference.sender.isEmpty, reference.sender.utf8.count <= 300,
              (reference.internetMessageID?.utf8.count ?? 0) <= 512,
              reference.receivedAt.timeIntervalSince1970.isFinite,
              reference.capturedAt.timeIntervalSince1970.isFinite,
              !reference.subject.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              !reference.sender.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw MailCapabilityError.invalidRequest
        }
        guard let target = kind.targetMailbox else { return }
        guard target.accountID == reference.accountID,
              target.id != reference.mailboxID,
              !target.id.isEmpty, target.id.utf8.count <= 256,
              !target.name.isEmpty, target.name.utf8.count <= 256,
              !target.path.isEmpty, target.path.utf8.count <= 1_024 else {
            throw MailCapabilityError.invalidRequest
        }
        if case .archive = kind {
            guard target.name.localizedCaseInsensitiveCompare("Archive") == .orderedSame else {
                throw MailCapabilityError.invalidRequest
            }
        }
    }
}

/// Display data only. The matching one-shot review lives in the capability
/// actor and expires quickly; possessing this value alone authorizes nothing.
struct MailMessageActionReview: Hashable, Sendable, Identifiable {
    let id: UUID
    let request: MailMessageActionRequest
    let expiresAt: Date
}

struct MailMessageActionReceipt: Hashable, Sendable {
    let request: MailMessageActionRequest
    let completedAt: Date
}

enum MailMessageActionOutcome: Hashable, Sendable {
    case completed(MailMessageActionReceipt)
    /// Mail may have applied the change. Never retry it automatically.
    case uncertain
}
