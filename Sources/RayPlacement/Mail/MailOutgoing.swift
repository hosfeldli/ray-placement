import CryptoKit
import Foundation

/// Replies and forwards retain an exact source-message reference. Recipients
/// and complete content are still reviewed as one immutable outgoing request.
enum MailOutgoingKind: Codable, Hashable, Sendable {
    case newMessage
    case reply(MailMessageReference)
    case forward(MailMessageReference)
}

/// A selected local file is rehashed before review and before Mail receives the
/// Apple Event. No file bytes or bookmark enter the send journal or AI context.
struct MailOutgoingAttachment: Codable, Hashable, Sendable {
    let path: String
    let displayName: String
    let byteCount: Int64
    let sha256: String

    static func capture(_ url: URL) throws -> MailOutgoingAttachment {
        guard url.isFileURL else { throw MailCapabilityError.invalidOutgoingMessage }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let values = try resolved.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 20 * 1_024 * 1_024,
              resolved.path.utf8.count <= 2_048,
              !resolved.path.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              !resolved.lastPathComponent.isEmpty,
              resolved.lastPathComponent.utf8.count <= 255 else {
            throw MailCapabilityError.invalidOutgoingMessage
        }
        let data = try Data(contentsOf: resolved, options: .mappedIfSafe)
        guard data.count == size else { throw MailCapabilityError.invalidOutgoingMessage }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return MailOutgoingAttachment(path: resolved.path,
                                      displayName: resolved.lastPathComponent,
                                      byteCount: Int64(size), sha256: digest)
    }

    func verifyCurrent() throws {
        guard let observed = try? Self.capture(URL(fileURLWithPath: path)),
              observed == self else {
            throw MailCapabilityError.attachmentChanged
        }
    }
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
    let attachments: [MailOutgoingAttachment]

    init(kind: MailOutgoingKind, accountID: String, senderAddress: String,
         to: [String], cc: [String], bcc: [String], subject: String, body: String,
         attachments: [MailOutgoingAttachment] = []) {
        self.kind = kind
        self.accountID = accountID
        self.senderAddress = senderAddress
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.attachments = attachments
    }

    func validate(allowIncompleteDraft: Bool = false) throws {
        guard Self.isMetadata(accountID, maximum: 256),
              Self.isAddress(senderAddress),
              (allowIncompleteDraft || !to.isEmpty), to.count <= 20,
              cc.count <= 20, bcc.count <= 20,
              to.count + cc.count + bcc.count <= 40,
              (to + cc + bcc).allSatisfy(Self.isAddress),
              Set((to + cc + bcc).map { $0.lowercased() }).count == to.count + cc.count + bcc.count,
              subject.utf8.count <= 500,
              !subject.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              (allowIncompleteDraft ||
               !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
              (allowIncompleteDraft ||
               !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
              (body.isEmpty ? attachments.isEmpty : true),
              body.utf8.count <= 128 * 1_024,
              !body.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) &&
                      $0.value != 9 && $0.value != 10 && $0.value != 13
              }),
              attachments.count <= 4,
              Set(attachments.map(\.path)).count == attachments.count,
              attachments.allSatisfy({ item in
                  item.path.hasPrefix("/") && item.path.utf8.count <= 2_048 &&
                  !item.path.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }) &&
                  !item.displayName.isEmpty && item.displayName.utf8.count <= 255 &&
                  item.byteCount > 0 && item.byteCount <= 20 * 1_024 * 1_024 &&
                  item.sha256.count == 64 &&
                  item.sha256.allSatisfy(\.isHexDigit)
              }),
              attachments.reduce(Int64(0), { $0 + $1.byteCount }) <= 40 * 1_024 * 1_024 else {
            throw MailCapabilityError.invalidOutgoingMessage
        }
        let source: MailMessageReference?
        switch kind {
        case .newMessage:
            source = nil
        case .reply(let reference), .forward(let reference):
            source = reference
        }
        if let source {
            guard source.accountID == accountID,
                  Self.isMetadata(source.mailboxID, maximum: 256),
                  source.messageID > 0,
                  source.subject.utf8.count <= 500,
                  !source.subject.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }),
                  Self.isMetadata(source.sender, maximum: 300),
                  (source.internetMessageID?.utf8.count ?? 0) <= 512,
                  !(source.internetMessageID ?? "").unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }),
                  source.receivedAt.timeIntervalSince1970.isFinite,
                  source.capturedAt.timeIntervalSince1970.isFinite else {
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

struct MailDraftReceipt: Hashable, Sendable {
    let savedAt: Date
}

enum MailDraftOutcome: Hashable, Sendable {
    case saved(MailDraftReceipt)
    /// Mail may have saved a draft; do not create a duplicate automatically.
    case uncertain
}

enum MailSendOutcome: Hashable, Sendable {
    case accepted(MailSendReceipt)
    /// The Apple Event may have sent the message. Lima must not retry it.
    case uncertain
}

/// Draft creation and sending are separate local grants. Neither can be
/// acquired by AI, workflows, or extensions; those callers may propose text
/// only for a visible user-controlled composer.
enum MailOutgoingGrant: Sendable {
    case compose
    case draft
    case send
}

struct MailOutgoingPolicy: Codable, Equatable, Sendable {
    let draftEnabled: Bool
    let sendEnabled: Bool
    let selectedAccountIDs: Set<String>

    init(draftEnabled: Bool = false, sendEnabled: Bool,
         selectedAccountIDs: Set<String>) {
        self.draftEnabled = draftEnabled
        self.sendEnabled = sendEnabled
        self.selectedAccountIDs = selectedAccountIDs
    }

    private enum CodingKeys: String, CodingKey {
        case draftEnabled, sendEnabled, selectedAccountIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Existing policies granted sending only. Migration must not silently
        // turn on a new draft-writing capability.
        draftEnabled = try container.decodeIfPresent(Bool.self, forKey: .draftEnabled) ?? false
        sendEnabled = try container.decode(Bool.self, forKey: .sendEnabled)
        selectedAccountIDs = try container.decode(Set<String>.self, forKey: .selectedAccountIDs)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(draftEnabled, forKey: .draftEnabled)
        try container.encode(sendEnabled, forKey: .sendEnabled)
        try container.encode(selectedAccountIDs, forKey: .selectedAccountIDs)
    }

    static let disabled = MailOutgoingPolicy(sendEnabled: false, selectedAccountIDs: [])

    func authorize(accountID: String, origin: MailReadOrigin,
                   grant: MailOutgoingGrant = .send) throws {
        guard case .userInterface = origin else { throw MailCapabilityError.originUnsupported }
        switch grant {
        case .compose:
            guard draftEnabled || sendEnabled else {
                throw MailCapabilityError.outgoingDisabled
            }
        case .draft:
            guard draftEnabled else { throw MailCapabilityError.draftDisabled }
        case .send:
            guard sendEnabled else { throw MailCapabilityError.outgoingDisabled }
        }
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
            (!(policy.draftEnabled || policy.sendEnabled) ||
             !policy.selectedAccountIDs.isEmpty)
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
