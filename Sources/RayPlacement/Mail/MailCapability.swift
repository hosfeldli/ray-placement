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

    /// Capture time is a freshness marker, not part of Mail's message identity.
    func identifiesSameMessage(as other: MailMessageReference) -> Bool {
        accountID == other.accountID &&
            mailboxID == other.mailboxID &&
            messageID == other.messageID &&
            internetMessageID == other.internetMessageID &&
            subject == other.subject &&
            sender == other.sender &&
            receivedAt == other.receivedAt
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
    case draftDisabled
    case invalidOutgoingMessage
    case attachmentChanged
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
        case .draftDisabled:
            return "Saving Apple Mail drafts is off in Lima."
        case .invalidOutgoingMessage:
            return "Review the sender, recipients, subject, message, and up to four selected attachments before continuing."
        case .attachmentChanged:
            return "A selected attachment changed or is no longer readable. Choose it again before saving or sending."
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
    case openMessage
    case createDraft
    case reply
    case forward
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
    func openMessage(_ reference: MailMessageReference) async throws
    func saveDraft(_ request: MailOutgoingRequest) async throws -> MailDraftReceipt
    func send(_ request: MailOutgoingRequest) async throws -> MailSendReceipt
    func applyMessageAction(_ request: MailMessageActionRequest) async throws
}

extension MailProvider {
    func sendingIdentities(accountID: String) async throws -> [String] {
        throw MailCapabilityError.unavailable
    }

    func replyTarget(_ reference: MailMessageReference) async throws -> MailReplyTarget {
        throw MailCapabilityError.unavailable
    }

    func openMessage(_ reference: MailMessageReference) async throws {
        throw MailCapabilityError.unavailable
    }

    func saveDraft(_ request: MailOutgoingRequest) async throws -> MailDraftReceipt {
        throw MailCapabilityError.unavailable
    }

    func send(_ request: MailOutgoingRequest) async throws -> MailSendReceipt {
        throw MailCapabilityError.unavailable
    }

    func applyMessageAction(_ request: MailMessageActionRequest) async throws {
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
    private var pendingMessageActionReviews: [UUID: MailMessageActionReview] = [:]
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
        guard message.reference.identifiesSameMessage(as: reference) else {
            // A Shelf or search result may point to a message that changed,
            // moved, disappeared, or was replaced. Never return a different
            // message body under an older reference.
            throw MailCapabilityError.providerScopeViolation
        }
        guard message.body.utf8.count <= maximumBodyBytes else {
            throw MailCapabilityError.messageTooLarge
        }
        return message
    }

    /// Open only the exact selected-account message in Apple Mail. The provider
    /// re-resolves source identity immediately before opening its native window.
    func openInMail(_ reference: MailMessageReference,
                    origin: MailReadOrigin) async throws {
        guard case .userInterface = origin else { throw MailCapabilityError.originUnsupported }
        try effectivePolicy().authorize(accountIDs: [reference.accountID], origin: origin)
        guard !reference.mailboxID.isEmpty, reference.messageID > 0 else {
            throw MailCapabilityError.invalidRequest
        }
        let operations = await provider.supportedOperations()
        guard operations.contains(.openMessage) else { throw MailCapabilityError.unavailable }
        try Task.checkCancellation()
        try effectivePolicy().authorize(accountIDs: [reference.accountID], origin: origin)
        try await provider.openMessage(reference)
    }

    /// Stage an exact source and destination for a visible, one-shot review.
    /// No AI, background, or extension caller can obtain a mutation review.
    func stageMessageAction(_ request: MailMessageActionRequest,
                            origin: MailReadOrigin) async throws -> MailMessageActionReview {
        guard case .userInterface = origin else { throw MailCapabilityError.originUnsupported }
        try await validateMessageAction(request, origin: origin)
        try Task.checkCancellation()
        let now = clock()
        pendingMessageActionReviews = pendingMessageActionReviews.filter {
            $0.value.expiresAt > now
        }
        guard pendingMessageActionReviews.count < 20 else { throw MailCapabilityError.busy }
        let review = MailMessageActionReview(
            id: UUID(), request: request, expiresAt: now.addingTimeInterval(120)
        )
        pendingMessageActionReviews[review.id] = review
        return review
    }

    func discardMessageActionReview(_ id: UUID) {
        pendingMessageActionReviews.removeValue(forKey: id)
    }

    /// Consume the review before dispatching the Apple Event. An error or
    /// timeout after dispatch is uncertain; Lima never replays the operation.
    func applyReviewedMessageAction(_ review: MailMessageActionReview,
                                    origin: MailReadOrigin) async throws -> MailMessageActionOutcome {
        guard case .userInterface = origin else { throw MailCapabilityError.originUnsupported }
        guard let staged = pendingMessageActionReviews[review.id] else {
            throw MailCapabilityError.reviewExpired
        }
        guard staged == review else { throw MailCapabilityError.reviewMismatch }
        guard clock() < staged.expiresAt else {
            pendingMessageActionReviews.removeValue(forKey: review.id)
            throw MailCapabilityError.reviewExpired
        }
        try await validateMessageAction(staged.request, origin: origin)
        try Task.checkCancellation()
        guard pendingMessageActionReviews[review.id] == staged,
              clock() < staged.expiresAt else {
            pendingMessageActionReviews.removeValue(forKey: review.id)
            throw MailCapabilityError.reviewExpired
        }
        pendingMessageActionReviews.removeValue(forKey: review.id)
        do {
            try await provider.applyMessageAction(staged.request)
            return .completed(MailMessageActionReceipt(
                request: staged.request, completedAt: clock()
            ))
        } catch {
            return .uncertain
        }
    }

    private func validateMessageAction(_ request: MailMessageActionRequest,
                                       origin: MailReadOrigin) async throws {
        try request.validate()
        try effectivePolicy().authorize(accountIDs: [request.reference.accountID], origin: origin)
        let operations = await provider.supportedOperations()
        guard operations.contains(request.kind.requiredOperation) else {
            throw MailCapabilityError.unavailable
        }
        if let destination = request.kind.targetMailbox {
            let current = try await mailboxes(
                accountID: request.reference.accountID, origin: origin
            )
            guard current.contains(destination) else {
                throw MailCapabilityError.invalidRequest
            }
        }
        let currentMessage = try await message(request.reference, origin: origin)
        guard currentMessage.reference.identifiesSameMessage(as: request.reference) else {
            throw MailCapabilityError.providerScopeViolation
        }
        try Task.checkCancellation()
        try effectivePolicy().authorize(accountIDs: [request.reference.accountID], origin: origin)
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
        try effectiveOutgoingPolicy().authorize(accountID: accountID, origin: origin, grant: .compose)
        guard effectivePolicy().selectedAccountIDs.contains(accountID) else {
            throw MailCapabilityError.accountNotSelected
        }
        let operations = await provider.supportedOperations()
        guard operations.contains(.send) || operations.contains(.createDraft) else {
            throw MailCapabilityError.unavailable
        }
        let identities = try await provider.sendingIdentities(accountID: accountID)
        try effectiveOutgoingPolicy().authorize(accountID: accountID, origin: origin, grant: .compose)
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
        try effectiveOutgoingPolicy().authorize(accountID: reference.accountID, origin: origin, grant: .compose)
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
        guard (operations.contains(.send) || operations.contains(.createDraft)),
              operations.contains(.reply) else {
            throw MailCapabilityError.unavailable
        }
        let senders = try await availableSenders(accountID: reference.accountID, origin: origin)
        let target = try await provider.replyTarget(reference)
        try Task.checkCancellation()
        try effectivePolicy().authorize(accountIDs: [reference.accountID], origin: origin)
        try effectiveOutgoingPolicy().authorize(accountID: reference.accountID, origin: origin, grant: .compose)
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

    /// Prefill an editable forward, preserving the source identity without
    /// giving this proposal any authority to send.
    func forwardProposal(of reference: MailMessageReference,
                         origin: MailReadOrigin) async throws -> MailOutgoingRequest {
        guard case .userInterface = origin else { throw MailCapabilityError.originUnsupported }
        try effectivePolicy().authorize(accountIDs: [reference.accountID], origin: origin)
        try effectiveOutgoingPolicy().authorize(accountID: reference.accountID, origin: origin, grant: .compose)
        let operations = await provider.supportedOperations()
        guard (operations.contains(.send) || operations.contains(.createDraft)),
              operations.contains(.forward) else {
            throw MailCapabilityError.unavailable
        }
        let senders = try await availableSenders(accountID: reference.accountID, origin: origin)
        let observed = try await message(reference, origin: origin)
        guard observed.reference.subject == reference.subject,
              observed.reference.sender == reference.sender else {
            throw MailCapabilityError.providerScopeViolation
        }
        try effectiveOutgoingPolicy().authorize(accountID: reference.accountID, origin: origin, grant: .compose)
        let sourceSubject = reference.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = sourceSubject.lowercased().hasPrefix("fwd:") ? sourceSubject :
            (sourceSubject.utf8.count <= 495 ? "Fwd: " + sourceSubject : sourceSubject)
        return MailOutgoingRequest(
            kind: .forward(reference), accountID: reference.accountID,
            senderAddress: senders[0], to: [], cc: [], bcc: [],
            subject: subject, body: ""
        )
    }

    /// Save even an incomplete draft only from the visible composer. A timeout
    /// or provider error may mean Mail saved it; Lima never retries automatically.
    func saveDraft(_ request: MailOutgoingRequest,
                   origin: MailReadOrigin) async throws -> MailDraftOutcome {
        try request.validate(allowIncompleteDraft: true)
        try authorizeOutgoing(request, origin: origin, grant: .draft)
        try Task.checkCancellation()
        try await verifyOutgoingProvider(request, requiredOperation: .createDraft)
        try Task.checkCancellation()
        try authorizeOutgoing(request, origin: origin, grant: .draft)
        do {
            return .saved(try await provider.saveDraft(request))
        } catch {
            return .uncertain
        }
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
                                   origin: MailReadOrigin,
                                   grant: MailOutgoingGrant = .send) throws {
        try effectiveOutgoingPolicy().authorize(accountID: request.accountID,
                                                origin: origin, grant: grant)
        let readPolicy = effectivePolicy()
        guard readPolicy.selectedAccountIDs.contains(request.accountID) else {
            throw MailCapabilityError.accountNotSelected
        }
        switch request.kind {
        case .newMessage:
            break
        case .reply(let reference), .forward(let reference):
            try readPolicy.authorize(accountIDs: [reference.accountID], origin: origin)
        }
    }

    private func verifyOutgoingProvider(_ request: MailOutgoingRequest,
                                        requiredOperation: MailOperation = .send) async throws {
        let attachments = request.attachments
        try await Task.detached(priority: .utility) {
            for attachment in attachments { try attachment.verifyCurrent() }
        }.value
        let operations = await provider.supportedOperations()
        guard operations.contains(requiredOperation) else { throw MailCapabilityError.unavailable }
        switch request.kind {
        case .newMessage:
            break
        case .reply:
            guard operations.contains(.reply) else { throw MailCapabilityError.unavailable }
        case .forward:
            guard operations.contains(.forward) else { throw MailCapabilityError.unavailable }
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
        switch request.kind {
        case .newMessage:
            break
        case .reply(let reference):
            let target = try await provider.replyTarget(reference)
            guard target.reference == reference,
                  MailOutgoingRequest.isAddress(target.recipientAddress),
                  (requiredOperation == .createDraft && request.to.isEmpty ||
                   request.to.first?.caseInsensitiveCompare(target.recipientAddress) == .orderedSame) else {
                throw MailCapabilityError.providerScopeViolation
            }
        case .forward(let reference):
            let observed = try await provider.message(reference)
            guard observed.reference.accountID == reference.accountID,
                  observed.reference.mailboxID == reference.mailboxID,
                  observed.reference.messageID == reference.messageID,
                  observed.reference.subject == reference.subject,
                  observed.reference.sender == reference.sender,
                  (reference.internetMessageID == nil ||
                   observed.reference.internetMessageID == reference.internetMessageID) else {
                throw MailCapabilityError.providerScopeViolation
            }
        }
    }
}
