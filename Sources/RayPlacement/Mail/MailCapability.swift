import Foundation

// Mail content is untrusted user data. These records are deliberately separate
// from AI prompts, telemetry, and Apple Events so every consumer uses one policy
// boundary and can retain lightweight references without caching message bodies.
struct MailAccount: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
}

struct MailMailbox: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let accountID: String
    let name: String
    let path: String
}

struct MailMessageReference: Codable, Hashable, Sendable, Identifiable {
    let accountID: String
    let mailboxID: String
    let messageID: Int64
    let internetMessageID: String?
    let subject: String
    let sender: String
    let receivedAt: Date
    let capturedAt: Date

    // Length-prefix components: account and mailbox identifiers may contain ':'
    // and must not collide when used as dictionary or UI identities.
    var id: String {
        "\(accountID.utf8.count):\(accountID)\(mailboxID.utf8.count):\(mailboxID)\(messageID)"
    }
}

struct MailMessageSummary: Codable, Hashable, Sendable, Identifiable {
    let reference: MailMessageReference
    let isRead: Bool
    let isFlagged: Bool

    var id: String { reference.id }
}

struct MailMessage: Codable, Hashable, Sendable {
    let reference: MailMessageReference
    let body: String
}

struct MailSearchRequest: Sendable {
    let accountIDs: Set<String>
    let mailboxIDs: Set<String>
    let query: String
    let receivedAfter: Date
    let receivedBefore: Date
    let limit: Int
}

struct MailSearchCoverage: Codable, Hashable, Sendable {
    let accountIDs: Set<String>
    let mailboxIDs: Set<String>
    let candidateCount: Int
    let isPartial: Bool
    let partialReason: String?
}

struct MailSearchResult: Sendable {
    let messages: [MailMessageSummary]
    let coverage: MailSearchCoverage
}

enum MailReadOrigin: Sendable {
    case userInterface
    case ai
    case workflow
    case extensionCommand
}

enum MailCapabilityError: LocalizedError, Equatable, Sendable {
    case disabled
    case accountNotSelected
    case aiAccessDenied
    case originUnsupported
    case invalidRequest
    case providerScopeViolation
    case messageTooLarge
    case unavailable
    case busy
    case timedOut
    case automationDenied
    case malformedResponse
    case outgoingDisabled
    case invalidOutgoingMessage
    case reviewExpired
    case reviewMismatch
    case sendOutcomeUncertain
    case sendJournalUnavailable

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "Mail access is off in Lima."
        case .accountNotSelected:
            return "Select the Mail account in Lima before reading its messages."
        case .aiAccessDenied:
            return "Sharing Mail content with AI is off in Lima."
        case .originUnsupported:
            return "This Mail operation is not available from this surface yet."
        case .invalidRequest:
            return "The Mail search request must use selected accounts, a bounded date range, and at most 100 results."
        case .providerScopeViolation:
            return "Apple Mail returned a message outside the reviewed account or mailbox scope."
        case .messageTooLarge:
            return "This message is too large for Lima's bounded Mail reader."
        case .unavailable:
            return "Apple Mail is unavailable or this operation is not supported."
        case .busy:
            return "Apple Mail is still handling another Lima request. Try again."
        case .timedOut:
            return "Apple Mail did not answer before the request deadline. The operation may still be finishing in Mail."
        case .automationDenied:
            return "macOS denied Lima permission to automate Apple Mail. Review Automation in System Settings."
        case .malformedResponse:
            return "Apple Mail returned an unreadable response."
        case .outgoingDisabled:
            return "Sending Mail is off in Lima."
        case .invalidOutgoingMessage:
            return "Review the sender, recipients, subject, and message before sending."
        case .reviewExpired:
            return "This email review expired. Review the exact message again."
        case .reviewMismatch:
            return "The outgoing message changed after review. Review it again before sending."
        case .sendOutcomeUncertain:
            return "This message may already have been sent. Check Mail's Sent mailbox before composing a new message; Lima will not retry it."
        case .sendJournalUnavailable:
            return "Lima cannot safely record the send attempt, so it did not send the message."
        }
    }
}

enum MailOperation: String, CaseIterable, Sendable {
    case listAccounts
    case listMailboxes
    case search
    case getMessage
    case createDraft
    case reply
    case send
    case flag
    case move
    case delete
}

protocol MailProvider: Sendable {
    /// Advertises implementation support, not macOS Automation or Lima policy approval.
    func supportedOperations() async -> Set<MailOperation>
    func accounts() async throws -> [MailAccount]
    func mailboxes(accountID: String) async throws -> [MailMailbox]
    func search(_ request: MailSearchRequest) async throws -> MailSearchResult
    func message(_ reference: MailMessageReference) async throws -> MailMessage
    func sendingIdentities(accountID: String) async throws -> [String]
    func replyTarget(_ reference: MailMessageReference) async throws -> MailReplyTarget
    func send(_ request: MailOutgoingRequest) async throws -> MailSendReceipt
}

extension MailProvider {
    func sendingIdentities(accountID: String) async throws -> [String] {
        throw MailCapabilityError.unavailable
    }

    func replyTarget(_ reference: MailMessageReference) async throws -> MailReplyTarget {
        throw MailCapabilityError.unavailable
    }

    func send(_ request: MailOutgoingRequest) async throws -> MailSendReceipt {
        throw MailCapabilityError.unavailable
    }
}

struct MailCapabilityPolicy: Codable, Equatable, Sendable {
    let readEnabled: Bool
    let selectedAccountIDs: Set<String>
    let allowsAIRead: Bool

    static let disabled = MailCapabilityPolicy(
        readEnabled: false, selectedAccountIDs: [], allowsAIRead: false
    )

    func authorize(accountIDs: Set<String>, origin: MailReadOrigin) throws {
        guard readEnabled else { throw MailCapabilityError.disabled }
        guard !accountIDs.isEmpty, accountIDs.isSubset(of: selectedAccountIDs) else {
            throw MailCapabilityError.accountNotSelected
        }
        switch origin {
        case .userInterface:
            break
        case .ai:
            guard allowsAIRead else { throw MailCapabilityError.aiAccessDenied }
        case .workflow, .extensionCommand:
            // The initial Mail bridge has no background or extension grant.
            throw MailCapabilityError.originUnsupported
        }
    }
}

/// Stores only selected account identifiers and access switches. Corrupt or
/// incompatible preferences fail closed; no message metadata or body is saved.
enum MailCapabilityPolicyStore {
    private static let key = "lima.mail.readPolicy.v1"

    private static func isValid(_ policy: MailCapabilityPolicy) -> Bool {
        policy.selectedAccountIDs.count <= 100 &&
            policy.selectedAccountIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) &&
            (!policy.readEnabled || !policy.selectedAccountIDs.isEmpty) &&
            (!policy.allowsAIRead || policy.readEnabled)
    }

    static func load(defaults: UserDefaults = LimaTestEnvironment.userDefaults) -> MailCapabilityPolicy {
        guard let data = defaults.data(forKey: key),
              let policy = try? JSONDecoder().decode(MailCapabilityPolicy.self, from: data),
              isValid(policy) else {
            return .disabled
        }
        return policy
    }

    static func save(_ policy: MailCapabilityPolicy,
                     defaults: UserDefaults = LimaTestEnvironment.userDefaults) throws {
        guard isValid(policy) else { throw MailCapabilityError.invalidRequest }
        defaults.set(try JSONEncoder().encode(policy), forKey: key)
    }

    static func disconnect(defaults: UserDefaults = LimaTestEnvironment.userDefaults) {
        defaults.removeObject(forKey: key)
    }
}

/// A testable host boundary for selected-account Mail reads. No caller can
/// widen the requested scope from a provider result, and this layer never
/// persists bodies or forwards them to a model.
actor MailCapabilityService {
    static let shared = MailCapabilityService(
        provider: AppleMailAdapter(),
        policyLoader: { MailCapabilityPolicyStore.load() },
        outgoingPolicyLoader: { MailOutgoingPolicyStore.load() }
    )

    private let provider: any MailProvider
    private var policy: MailCapabilityPolicy
    private let policyLoader: (@Sendable () -> MailCapabilityPolicy)?
    private var outgoingPolicy: MailOutgoingPolicy
    private let outgoingPolicyLoader: (@Sendable () -> MailOutgoingPolicy)?
    private let sendJournalDefaults: UserDefaults
    private let clock: @Sendable () -> Date
    private var pendingOutgoingReviews: [UUID: MailOutgoingReview] = [:]
    private let maximumBodyBytes = 128 * 1_024

    init(provider: any MailProvider, policy: MailCapabilityPolicy = .disabled,
         policyLoader: (@Sendable () -> MailCapabilityPolicy)? = nil,
         outgoingPolicy: MailOutgoingPolicy = .disabled,
         outgoingPolicyLoader: (@Sendable () -> MailOutgoingPolicy)? = nil,
         sendJournalDefaults: UserDefaults = LimaTestEnvironment.userDefaults,
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.policy = policy
        self.policyLoader = policyLoader
        self.outgoingPolicy = outgoingPolicy
        self.outgoingPolicyLoader = outgoingPolicyLoader
        self.sendJournalDefaults = sendJournalDefaults
        self.clock = clock
    }

    func applyUserReviewedPolicy(_ policy: MailCapabilityPolicy) {
        self.policy = policy
    }

    func applyUserReviewedOutgoingPolicy(_ policy: MailOutgoingPolicy) {
        self.outgoingPolicy = policy
    }

    private func effectiveOutgoingPolicy() -> MailOutgoingPolicy {
        outgoingPolicyLoader?() ?? outgoingPolicy
    }

    private func effectivePolicy() -> MailCapabilityPolicy {
        policyLoader?() ?? policy
    }

    func supportedOperations() async -> Set<MailOperation> {
        await provider.supportedOperations()
    }

    func discoverAccounts(origin: MailReadOrigin) async throws -> [MailAccount] {
        guard case .userInterface = origin else { throw MailCapabilityError.originUnsupported }
        try Task.checkCancellation()
        // Only explicit Settings UI setup may trigger an Automation prompt.
        let accounts = try await provider.accounts()
        try Task.checkCancellation()
        guard accounts.count <= 100,
              Set(accounts.map(\.id)).count == accounts.count,
              accounts.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 256 &&
                                    !$0.name.isEmpty && $0.name.utf8.count <= 256 }) else {
            throw MailCapabilityError.malformedResponse
        }
        return accounts
    }

    func mailboxes(accountID: String, origin: MailReadOrigin) async throws -> [MailMailbox] {
        try effectivePolicy().authorize(accountIDs: [accountID], origin: origin)
        try Task.checkCancellation()
        let mailboxes = try await provider.mailboxes(accountID: accountID)
        try Task.checkCancellation()
        try effectivePolicy().authorize(accountIDs: [accountID], origin: origin)
        guard mailboxes.count <= 500,
              Set(mailboxes.map(\.id)).count == mailboxes.count,
              mailboxes.allSatisfy({ $0.accountID == accountID &&
                                    !$0.id.isEmpty && $0.id.utf8.count <= 256 &&
                                    !$0.name.isEmpty && $0.name.utf8.count <= 256 &&
                                    !$0.path.isEmpty && $0.path.utf8.count <= 1_024 }) else {
            throw MailCapabilityError.providerScopeViolation
        }
        return mailboxes
    }

    func search(_ request: MailSearchRequest, origin: MailReadOrigin) async throws -> MailSearchResult {
        try effectivePolicy().authorize(accountIDs: request.accountIDs, origin: origin)
        guard request.limit > 0, request.limit <= 100,
              request.accountIDs.count <= 100,
              request.query.utf8.count <= 256,
              request.receivedAfter.timeIntervalSince1970.isFinite,
              request.receivedBefore.timeIntervalSince1970.isFinite,
              request.receivedAfter < request.receivedBefore,
              request.receivedBefore.timeIntervalSince(request.receivedAfter) <= 31 * 24 * 60 * 60,
              request.mailboxIDs.count <= 100,
              request.mailboxIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else {
            throw MailCapabilityError.invalidRequest
        }
        try Task.checkCancellation()
        let result = try await provider.search(request)
        try Task.checkCancellation()
        try effectivePolicy().authorize(accountIDs: request.accountIDs, origin: origin)
        let returnedIDs = result.messages.map(\.id)
        guard result.messages.count <= request.limit,
              Set(returnedIDs).count == returnedIDs.count,
              result.coverage.candidateCount >= result.messages.count,
              result.coverage.accountIDs.isSubset(of: request.accountIDs),
              (result.coverage.isPartial ||
               result.coverage.accountIDs == request.accountIDs),
              (result.coverage.isPartial || result.coverage.partialReason == nil),
              (!result.coverage.isPartial ||
               !(result.coverage.partialReason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)),
              (request.mailboxIDs.isEmpty ||
               result.coverage.mailboxIDs.isSubset(of: request.mailboxIDs)),
              (request.mailboxIDs.isEmpty || result.coverage.isPartial ||
               result.coverage.mailboxIDs == request.mailboxIDs),
              result.messages.allSatisfy({ summary in
                  let reference = summary.reference
                  return request.accountIDs.contains(reference.accountID) &&
                      result.coverage.accountIDs.contains(reference.accountID) &&
                      result.coverage.mailboxIDs.contains(reference.mailboxID) &&
                      (request.mailboxIDs.isEmpty ||
                       request.mailboxIDs.contains(reference.mailboxID)) &&
                      reference.messageID > 0 &&
                      !reference.mailboxID.isEmpty &&
                      reference.subject.utf8.count <= 500 &&
                      reference.sender.utf8.count <= 300 &&
                      (reference.internetMessageID?.utf8.count ?? 0) <= 512 &&
                      reference.receivedAt.timeIntervalSince1970.isFinite &&
                      reference.capturedAt.timeIntervalSince1970.isFinite &&
                      reference.receivedAt >= request.receivedAfter &&
                      reference.receivedAt <= request.receivedBefore
              }) else {
            throw MailCapabilityError.providerScopeViolation
        }
        return result
    }

    func message(_ reference: MailMessageReference, origin: MailReadOrigin) async throws -> MailMessage {
        try effectivePolicy().authorize(accountIDs: [reference.accountID], origin: origin)
        guard !reference.mailboxID.isEmpty, reference.messageID > 0 else {
            throw MailCapabilityError.invalidRequest
        }
        try Task.checkCancellation()
        let message = try await provider.message(reference)
        try Task.checkCancellation()
        try effectivePolicy().authorize(accountIDs: [reference.accountID], origin: origin)
        guard message.reference.accountID == reference.accountID,
              message.reference.mailboxID == reference.mailboxID,
              message.reference.messageID == reference.messageID,
              (reference.internetMessageID == nil ||
               message.reference.internetMessageID == reference.internetMessageID) else {
            throw MailCapabilityError.providerScopeViolation
        }
        guard message.body.utf8.count <= maximumBodyBytes else {
            throw MailCapabilityError.messageTooLarge
        }
        return message
    }

    /// Authorize a lightweight Shelf reference without reading or retaining a
    /// body. This is UI-only and rechecks the current selected-account policy.
    func referenceForShelf(_ reference: MailMessageReference,
                           origin: MailReadOrigin) async throws -> MailMessageReference {
        guard case .userInterface = origin else { throw MailCapabilityError.originUnsupported }
        try effectivePolicy().authorize(accountIDs: [reference.accountID], origin: origin)
        guard !reference.accountID.isEmpty, reference.accountID.utf8.count <= 256,
              !reference.mailboxID.isEmpty, reference.mailboxID.utf8.count <= 256,
              reference.messageID > 0,
              reference.subject.utf8.count <= 500,
              reference.sender.utf8.count <= 300,
              (reference.internetMessageID?.utf8.count ?? 0) <= 512,
              reference.receivedAt.timeIntervalSince1970.isFinite,
              reference.capturedAt.timeIntervalSince1970.isFinite,
              !reference.subject.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !reference.sender.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw MailCapabilityError.invalidRequest
        }
        try Task.checkCancellation()
        let operations = await provider.supportedOperations()
        guard operations.contains(.getMessage) else { throw MailCapabilityError.unavailable }
        try Task.checkCancellation()
        try effectivePolicy().authorize(accountIDs: [reference.accountID], origin: origin)
        return reference
    }

    /// Called only after a user opens a compose surface. This returns configured
    /// sender addresses for one already-selected account, not message content.
    func availableSenders(accountID: String, origin: MailReadOrigin) async throws -> [String] {
        try effectiveOutgoingPolicy().authorize(accountID: accountID, origin: origin)
        guard effectivePolicy().selectedAccountIDs.contains(accountID) else {
            throw MailCapabilityError.accountNotSelected
        }
        let operations = await provider.supportedOperations()
        guard operations.contains(.send) else { throw MailCapabilityError.unavailable }
        let identities = try await provider.sendingIdentities(accountID: accountID)
        try effectiveOutgoingPolicy().authorize(accountID: accountID, origin: origin)
        guard effectivePolicy().selectedAccountIDs.contains(accountID) else {
            throw MailCapabilityError.accountNotSelected
        }
        guard !identities.isEmpty, identities.count <= 20,
              identities.allSatisfy(MailOutgoingRequest.isAddress),
              Set(identities.map { $0.lowercased() }).count == identities.count else {
            throw MailCapabilityError.malformedResponse
        }
        return identities
    }

    /// Prefill an editable reply from one scoped source message. This is not a
    /// send review: the user must edit, stage, and approve the exact message.
    func replyProposal(to reference: MailMessageReference,
                       origin: MailReadOrigin) async throws -> MailOutgoingRequest {
        guard case .userInterface = origin else { throw MailCapabilityError.originUnsupported }
        try effectivePolicy().authorize(accountIDs: [reference.accountID], origin: origin)
        try effectiveOutgoingPolicy().authorize(accountID: reference.accountID, origin: origin)
        guard !reference.mailboxID.isEmpty, reference.messageID > 0,
              reference.subject.utf8.count <= 500,
              reference.sender.utf8.count <= 300,
              (reference.internetMessageID?.utf8.count ?? 0) <= 512,
              reference.receivedAt.timeIntervalSince1970.isFinite,
              reference.capturedAt.timeIntervalSince1970.isFinite else {
            throw MailCapabilityError.invalidRequest
        }
        try Task.checkCancellation()
        let operations = await provider.supportedOperations()
        guard operations.contains(.send), operations.contains(.reply) else {
            throw MailCapabilityError.unavailable
        }
        let senders = try await availableSenders(accountID: reference.accountID, origin: origin)
        let target = try await provider.replyTarget(reference)
        try Task.checkCancellation()
        try effectivePolicy().authorize(accountIDs: [reference.accountID], origin: origin)
        try effectiveOutgoingPolicy().authorize(accountID: reference.accountID, origin: origin)
        guard target.reference == reference,
              MailOutgoingRequest.isAddress(target.recipientAddress) else {
            throw MailCapabilityError.providerScopeViolation
        }
        let sourceSubject = reference.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject: String
        if sourceSubject.lowercased().hasPrefix("re:") {
            subject = sourceSubject
        } else if sourceSubject.utf8.count <= 496 {
            subject = "Re: " + sourceSubject
        } else {
            // Do not truncate source text or silently change the user-visible
            // thread subject. The composer still permits an explicit edit.
            subject = sourceSubject
        }
        return MailOutgoingRequest(
            kind: .reply(reference), accountID: reference.accountID,
            senderAddress: senders[0], to: [target.recipientAddress],
            cc: [], bcc: [], subject: subject, body: ""
        )
    }

    /// Prepare display data for one exact outgoing message. This never sends.
    /// Direct AI, workflow, and extension callers cannot create send reviews.
    func stageOutgoing(_ request: MailOutgoingRequest,
                       origin: MailReadOrigin) async throws -> MailOutgoingReview {
        try request.validate()
        try authorizeOutgoing(request, origin: origin)
        try Task.checkCancellation()
        try await verifyOutgoingProvider(request)
        try Task.checkCancellation()
        try authorizeOutgoing(request, origin: origin)
        let hasPendingSend = try MailSendAttemptStore.hasPending(request, defaults: sendJournalDefaults)
        guard !hasPendingSend else {
            throw MailCapabilityError.sendOutcomeUncertain
        }
        // Start the review lifetime only after potentially slow Mail lookups.
        let now = clock()
        pendingOutgoingReviews = pendingOutgoingReviews.filter { $0.value.expiresAt > now }
        guard pendingOutgoingReviews.count < 20 else { throw MailCapabilityError.busy }
        let review = MailOutgoingReview(
            id: UUID(), request: request, expiresAt: now.addingTimeInterval(120)
        )
        pendingOutgoingReviews[review.id] = review
        return review
    }

    func discardOutgoingReview(_ id: UUID) {
        pendingOutgoingReviews.removeValue(forKey: id)
    }

    /// Called only from the visible Mail review button. The one-shot record is
    /// consumed before the provider call. Any failed/timeout/canceled call after
    /// dispatch remains pending and cannot be retried by Lima.
    func sendReviewed(_ review: MailOutgoingReview,
                      origin: MailReadOrigin) async throws -> MailSendOutcome {
        let now = clock()
        guard case .userInterface = origin else { throw MailCapabilityError.originUnsupported }
        guard let staged = pendingOutgoingReviews[review.id] else {
            throw MailCapabilityError.reviewExpired
        }
        guard staged == review else { throw MailCapabilityError.reviewMismatch }
        guard now < staged.expiresAt else {
            pendingOutgoingReviews.removeValue(forKey: review.id)
            throw MailCapabilityError.reviewExpired
        }
        try authorizeOutgoing(staged.request, origin: origin)
        try Task.checkCancellation()
        try await verifyOutgoingProvider(staged.request)
        try Task.checkCancellation()
        // Recheck persisted account selections, review lifetime, and the live
        // review immediately before the write. Closing or editing the review
        // during a slow identity lookup must revoke the pending send.
        try authorizeOutgoing(staged.request, origin: origin)
        guard pendingOutgoingReviews[review.id] == staged else {
            throw MailCapabilityError.reviewExpired
        }
        guard clock() < staged.expiresAt else {
            pendingOutgoingReviews.removeValue(forKey: review.id)
            throw MailCapabilityError.reviewExpired
        }
        pendingOutgoingReviews.removeValue(forKey: review.id)
        let fingerprint = try MailSendAttemptStore.markPending(
            staged.request, defaults: sendJournalDefaults
        )
        do {
            let receipt = try await provider.send(staged.request)
            guard receipt.acceptedAt.timeIntervalSince1970.isFinite,
                  (receipt.providerMessageID?.utf8.count ?? 0) <= 512 else {
                return .uncertain
            }
            try MailSendAttemptStore.clearAccepted(fingerprint, defaults: sendJournalDefaults)
            return .accepted(receipt)
        } catch {
            // A provider error cannot prove that Mail did not send the message.
            return .uncertain
        }
    }

    private func authorizeOutgoing(_ request: MailOutgoingRequest,
                                   origin: MailReadOrigin) throws {
        try effectiveOutgoingPolicy().authorize(accountID: request.accountID, origin: origin)
        let readPolicy = effectivePolicy()
        guard readPolicy.selectedAccountIDs.contains(request.accountID) else {
            throw MailCapabilityError.accountNotSelected
        }
        if case .reply(let reference) = request.kind {
            try readPolicy.authorize(accountIDs: [reference.accountID], origin: origin)
        }
    }

    private func verifyOutgoingProvider(_ request: MailOutgoingRequest) async throws {
        let operations = await provider.supportedOperations()
        guard operations.contains(.send) else { throw MailCapabilityError.unavailable }
        if case .reply = request.kind {
            guard operations.contains(.reply) else { throw MailCapabilityError.unavailable }
        }
        let identities = try await provider.sendingIdentities(accountID: request.accountID)
        guard !identities.isEmpty, identities.count <= 20,
              identities.allSatisfy(MailOutgoingRequest.isAddress),
              Set(identities.map { $0.lowercased() }).count == identities.count else {
            throw MailCapabilityError.malformedResponse
        }
        guard identities.contains(where: {
            $0.caseInsensitiveCompare(request.senderAddress) == .orderedSame
        }) else {
            throw MailCapabilityError.providerScopeViolation
        }
        if case .reply(let reference) = request.kind {
            let target = try await provider.replyTarget(reference)
            guard target.reference == reference,
                  MailOutgoingRequest.isAddress(target.recipientAddress),
                  request.to[0].caseInsensitiveCompare(target.recipientAddress) == .orderedSame else {
                throw MailCapabilityError.providerScopeViolation
            }
        }
    }
}
