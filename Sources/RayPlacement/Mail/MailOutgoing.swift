import CryptoKit
import Foundation

/// A reply is tied to one exact message. There is no reply-all or attachment
/// support until those operations have their own account and content review.
enum MailOutgoingKind: Codable, Hashable, Sendable {
    case newMessage
    case reply(MailMessageReference)
}

struct MailOutgoingRequest: Codable, Hashable, Sendable {
    let kind: MailOutgoingKind
    let accountID: String
    let senderAddress: String
    let to: [String]
    let cc: [String]
    let bcc: [String]
    let subject: String
    let body: String

    func validate() throws {
        guard Self.isMetadata(accountID, maximum: 256),
              Self.isAddress(senderAddress),
              !to.isEmpty, to.count <= 20,
              cc.count <= 20, bcc.count <= 20,
              to.count + cc.count + bcc.count <= 40,
              (to + cc + bcc).allSatisfy(Self.isAddress),
              Set((to + cc + bcc).map { $0.lowercased() }).count == to.count + cc.count + bcc.count,
              Self.isMetadata(subject, maximum: 500),
              !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              body.utf8.count <= 128 * 1_024,
              !body.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 0x7F }) else {
            throw MailCapabilityError.invalidOutgoingMessage
        }
        if case .reply(let reference) = kind {
            guard reference.accountID == accountID,
                  Self.isMetadata(reference.mailboxID, maximum: 256),
                  reference.messageID > 0,
                  reference.subject.utf8.count <= 500,
                  reference.sender.utf8.count <= 300,
                  (reference.internetMessageID?.utf8.count ?? 0) <= 512,
                  reference.receivedAt.timeIntervalSince1970.isFinite,
                  reference.capturedAt.timeIntervalSince1970.isFinite,
                  to.count == 1, cc.isEmpty, bcc.isEmpty else {
                throw MailCapabilityError.invalidOutgoingMessage
            }
        }
    }

    static func isAddress(_ value: String) -> Bool {
        guard value.utf8.count <= 320,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
              }),
              !value.contains(where: { "<>,;()[]".contains($0) }) else { return false }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty, parts[0].utf8.count <= 64,
              !parts[1].isEmpty, parts[1].utf8.count <= 255,
              parts[1].contains("."),
              !parts[1].hasPrefix("."), !parts[1].hasSuffix("."),
              !parts[0].hasPrefix("."), !parts[0].hasSuffix(".") else { return false }
        return true
    }

    private static func isMetadata(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum &&
            !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}

struct MailReplyTarget: Hashable, Sendable {
    let reference: MailMessageReference
    let recipientAddress: String
}

/// This is display data, not authority by itself. The capability actor holds
/// the matching one-shot record and compares every field at submission.
struct MailOutgoingReview: Hashable, Sendable, Identifiable {
    let id: UUID
    let request: MailOutgoingRequest
    let expiresAt: Date
}

struct MailSendReceipt: Hashable, Sendable {
    let acceptedAt: Date
    let providerMessageID: String?
}

enum MailSendOutcome: Hashable, Sendable {
    case accepted(MailSendReceipt)
    /// The Apple Event may have sent the message. Lima must not retry it.
    case uncertain
}

/// Read selection and outgoing authority are independent. AI, workflows, and
/// extensions may propose text but cannot acquire this direct-send grant.
struct MailOutgoingPolicy: Codable, Equatable, Sendable {
    let sendEnabled: Bool
    let selectedAccountIDs: Set<String>

    static let disabled = MailOutgoingPolicy(sendEnabled: false, selectedAccountIDs: [])

    func authorize(accountID: String, origin: MailReadOrigin) throws {
        guard case .userInterface = origin else { throw MailCapabilityError.originUnsupported }
        guard sendEnabled else { throw MailCapabilityError.outgoingDisabled }
        guard selectedAccountIDs.contains(accountID) else {
            throw MailCapabilityError.accountNotSelected
        }
    }
}

enum MailOutgoingPolicyStore {
    private static let key = "lima.mail.sendPolicy.v1"

    private static func isValid(_ policy: MailOutgoingPolicy) -> Bool {
        policy.selectedAccountIDs.count <= 100 &&
            policy.selectedAccountIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) &&
            (!policy.sendEnabled || !policy.selectedAccountIDs.isEmpty)
    }

    static func load(defaults: UserDefaults = LimaTestEnvironment.userDefaults) -> MailOutgoingPolicy {
        guard let data = defaults.data(forKey: key),
              let policy = try? JSONDecoder().decode(MailOutgoingPolicy.self, from: data),
              isValid(policy) else { return .disabled }
        return policy
    }

    static func save(_ policy: MailOutgoingPolicy,
                     defaults: UserDefaults = LimaTestEnvironment.userDefaults) throws {
        guard isValid(policy) else { throw MailCapabilityError.invalidRequest }
        defaults.set(try JSONEncoder().encode(policy), forKey: key)
    }

    static func disconnect(defaults: UserDefaults = LimaTestEnvironment.userDefaults) {
        defaults.removeObject(forKey: key)
    }
}

/// A pending digest is written before issuing an Apple Event. If the process
/// exits or the call times out, the same exact message is blocked across
/// launches until Mail's sent state can be reconciled. No body is persisted.
enum MailSendAttemptStore {
    private static let saltKey = "lima.mail.sendJournal.salt.v1"
    private static let pendingKey = "lima.mail.sendJournal.pending.v1"
    private static let maximumPending = 256

    static func markPending(_ request: MailOutgoingRequest,
                            defaults: UserDefaults = LimaTestEnvironment.userDefaults) throws -> String {
        let fingerprint = try fingerprint(request, defaults: defaults)
        var pending = try loadPending(defaults: defaults)
        guard !pending.contains(fingerprint) else {
            throw MailCapabilityError.sendOutcomeUncertain
        }
        guard pending.count < maximumPending else { throw MailCapabilityError.sendJournalUnavailable }
        pending.insert(fingerprint)
        defaults.set(Array(pending).sorted(), forKey: pendingKey)
        guard defaults.synchronize(),
              defaults.stringArray(forKey: pendingKey)?.contains(fingerprint) == true else {
            throw MailCapabilityError.sendJournalUnavailable
        }
        return fingerprint
    }

    static func clearAccepted(_ fingerprint: String,
                              defaults: UserDefaults = LimaTestEnvironment.userDefaults) throws {
        var pending = try loadPending(defaults: defaults)
        let previous = Array(pending).sorted()
        pending.remove(fingerprint)
        defaults.set(Array(pending).sorted(), forKey: pendingKey)
        guard defaults.synchronize(),
              defaults.stringArray(forKey: pendingKey)?.contains(fingerprint) == false else {
            // A failed flush after Mail accepted the send must not make the
            // attempt appear safe to retry in this process.
            defaults.set(previous, forKey: pendingKey)
            throw MailCapabilityError.sendJournalUnavailable
        }
    }

    static func hasPending(_ request: MailOutgoingRequest,
                           defaults: UserDefaults = LimaTestEnvironment.userDefaults) throws -> Bool {
        try loadPending(defaults: defaults).contains(fingerprint(request, defaults: defaults))
    }

    private static func loadPending(defaults: UserDefaults) throws -> Set<String> {
        guard let raw = defaults.object(forKey: pendingKey) else { return [] }
        guard let values = raw as? [String],
              values.count <= maximumPending,
              values.allSatisfy({ value in
                  value.count == 64 && value.allSatisfy({ character in character.isHexDigit })
              }) else {
            throw MailCapabilityError.sendJournalUnavailable
        }
        return Set(values)
    }

    private static func fingerprint(_ request: MailOutgoingRequest,
                                    defaults: UserDefaults) throws -> String {
        let salt: Data
        if let existing = defaults.object(forKey: saltKey) {
            guard let data = existing as? Data, data.count == 32 else {
                throw MailCapabilityError.sendJournalUnavailable
            }
            salt = data
        } else {
            // A journal without its original salt cannot identify prior attempts.
            guard defaults.object(forKey: pendingKey) == nil else {
                throw MailCapabilityError.sendJournalUnavailable
            }
            salt = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
            defaults.set(salt, forKey: saltKey)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(request)
        let digest = SHA256.hash(data: salt + payload)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
