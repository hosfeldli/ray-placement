import Foundation
import Testing
@testable import RayPlacement

private actor SyntheticOutgoingMailProvider: MailProvider {
    var sendCallCount = 0
    var sentRequests: [MailOutgoingRequest] = []
    var identities = ["owner@example.invalid"]
    var replyRecipient = "sender@example.invalid"
    var sendError: MailCapabilityError?
    var supportsReply = true
    var supportsRead = false
    var searchCallCount = 0
    var messageCallCount = 0
    var returnedReplyReference: MailMessageReference?
    var identityLookupCount = 0
    var clockToAdvanceOnIdentityLookup: (SyntheticMailClock, Int, TimeInterval)?
    var identityGateOnLookup: (SyntheticMailIdentityGate, Int)?

    func supportedOperations() async -> Set<MailOperation> {
        var operations: Set<MailOperation> = [.send]
        if supportsReply { operations.insert(.reply) }
        if supportsRead { operations.formUnion([.search, .getMessage]) }
        return operations
    }

    func accounts() async throws -> [MailAccount] { [] }
    func mailboxes(accountID: String) async throws -> [MailMailbox] { [] }
    func search(_ request: MailSearchRequest) async throws -> MailSearchResult {
        guard supportsRead else { throw MailCapabilityError.unavailable }
        searchCallCount += 1
        let reference = outgoingReference()
        return MailSearchResult(
            messages: [MailMessageSummary(reference: reference, isRead: false, isFlagged: false)],
            coverage: MailSearchCoverage(
                accountIDs: [reference.accountID], mailboxIDs: [reference.mailboxID],
                candidateCount: 1, isPartial: false, partialReason: nil
            )
        )
    }
    func message(_ reference: MailMessageReference) async throws -> MailMessage {
        guard supportsRead else { throw MailCapabilityError.unavailable }
        messageCallCount += 1
        return MailMessage(reference: reference, body: "Please review the schedule.")
    }
    func sendingIdentities(accountID: String) async throws -> [String] {
        identityLookupCount += 1
        if let (clock, lookup, interval) = clockToAdvanceOnIdentityLookup,
           identityLookupCount == lookup {
            clock.advance(by: interval)
        }
        if let (gate, lookup) = identityGateOnLookup,
           identityLookupCount == lookup {
            await gate.pause()
        }
        return identities
    }
    func replyTarget(_ reference: MailMessageReference) async throws -> MailReplyTarget {
        MailReplyTarget(
            reference: returnedReplyReference ?? reference,
            recipientAddress: replyRecipient
        )
    }
    func send(_ request: MailOutgoingRequest) async throws -> MailSendReceipt {
        sendCallCount += 1
        sentRequests.append(request)
        if let sendError { throw sendError }
        return MailSendReceipt(
            acceptedAt: Date(timeIntervalSince1970: 3_000),
            providerMessageID: "synthetic-sent-\(sendCallCount)"
        )
    }

    func setIdentities(_ value: [String]) { identities = value }
    func setReplyRecipient(_ value: String) { replyRecipient = value }
    func setReturnedReplyReference(_ value: MailMessageReference) { returnedReplyReference = value }
    func setSendError(_ value: MailCapabilityError?) { sendError = value }
    func setSupportsReply(_ value: Bool) { supportsReply = value }
    func setSupportsRead(_ value: Bool) { supportsRead = value }
    func advanceClock(_ clock: SyntheticMailClock, onIdentityLookup lookup: Int,
                      by interval: TimeInterval) {
        clockToAdvanceOnIdentityLookup = (clock, lookup, interval)
    }
    func pauseIdentityLookup(_ gate: SyntheticMailIdentityGate, onLookup lookup: Int) {
        identityGateOnLookup = (gate, lookup)
    }
}

private final class SyntheticMailClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date

    init(_ instant: Date) { self.instant = instant }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        instant = instant.addingTimeInterval(interval)
        lock.unlock()
    }
}

private actor SyntheticMailIdentityGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
            entered = true
            let waiters = enteredWaiters
            enteredWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

private final class FailingMailJournalDefaults: UserDefaults {
    var failSynchronize = false

    override func synchronize() -> Bool {
        failSynchronize ? false : super.synchronize()
    }
}

private func outgoingReference() -> MailMessageReference {
    MailMessageReference(
        accountID: "work", mailboxID: "inbox", messageID: 42,
        internetMessageID: "<source@example.invalid>",
        subject: "Schedule", sender: "sender@example.invalid",
        receivedAt: Date(timeIntervalSince1970: 1_000),
        capturedAt: Date(timeIntervalSince1970: 2_000)
    )
}

private func outgoingRequest(kind: MailOutgoingKind = .newMessage,
                             senderAddress: String = "owner@example.invalid",
                             to: [String] = ["sender@example.invalid"],
                             cc: [String] = [],
                             bcc: [String] = [],
                             body: String = "The revised schedule is attached next week.") -> MailOutgoingRequest {
    MailOutgoingRequest(
        kind: kind, accountID: "work", senderAddress: senderAddress,
        to: to, cc: cc, bcc: bcc, subject: "Revised schedule", body: body
    )
}

private func outgoingService(
    provider: SyntheticOutgoingMailProvider,
    defaults: UserDefaults,
    readEnabled: Bool = true,
    sendEnabled: Bool = true,
    clock: @escaping @Sendable () -> Date = { Date() }
) -> MailCapabilityService {
    MailCapabilityService(
        provider: provider,
        policy: MailCapabilityPolicy(
            readEnabled: readEnabled, selectedAccountIDs: ["work"], allowsAIRead: false
        ),
        outgoingPolicy: MailOutgoingPolicy(
            sendEnabled: sendEnabled, selectedAccountIDs: ["work"]
        ),
        sendJournalDefaults: defaults,
        clock: clock
    )
}

private func isolatedMailDefaults() throws -> (UserDefaults, String) {
    let suite = "dev.liam.lima.mail-outgoing-tests.\(UUID().uuidString)"
    return (try #require(UserDefaults(suiteName: suite)), suite)
}

@Test func mailOutgoingIsDeniedWithoutSeparateSendPolicyOrUIOrigin() async throws {
    let (defaults, suite) = try isolatedMailDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let provider = SyntheticOutgoingMailProvider()
    let service = outgoingService(provider: provider, defaults: defaults, sendEnabled: false)
    do {
        _ = try await service.stageOutgoing(outgoingRequest(), origin: .userInterface)
        Issue.record("Read access must not imply sending authority.")
    } catch let error as MailCapabilityError {
        #expect(error == .outgoingDisabled)
    }
    await service.applyUserReviewedOutgoingPolicy(
        MailOutgoingPolicy(sendEnabled: true, selectedAccountIDs: ["work"])
    )
    for origin: MailReadOrigin in [.ai, .workflow, .extensionCommand] {
        do {
            _ = try await service.stageOutgoing(outgoingRequest(), origin: origin)
            Issue.record("Non-UI origins cannot create send reviews.")
        } catch let error as MailCapabilityError {
            #expect(error == .originUnsupported)
        }
    }
    #expect(await provider.sendCallCount == 0)
}

@Test func mailOutgoingExactReviewSendsOnceAndRejectsTampering() async throws {
    let (defaults, suite) = try isolatedMailDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let provider = SyntheticOutgoingMailProvider()
    let service = outgoingService(provider: provider, defaults: defaults)
    let original = outgoingRequest()
    let review = try await service.stageOutgoing(original, origin: .userInterface)
    let tampered = MailOutgoingReview(
        id: review.id,
        request: outgoingRequest(body: "Send every file instead."),
        expiresAt: review.expiresAt
    )
    do {
        _ = try await service.sendReviewed(tampered, origin: .userInterface)
        Issue.record("A changed message must not reuse an approval.")
    } catch let error as MailCapabilityError {
        #expect(error == .reviewMismatch)
    }
    #expect(await provider.sendCallCount == 0)
    let outcome = try await service.sendReviewed(review, origin: .userInterface)
    #expect(outcome == .accepted(MailSendReceipt(
        acceptedAt: Date(timeIntervalSince1970: 3_000),
        providerMessageID: "synthetic-sent-1"
    )))
    #expect(await provider.sentRequests == [original])
    #expect(try !MailSendAttemptStore.hasPending(original, defaults: defaults))
    do {
        _ = try await service.sendReviewed(review, origin: .userInterface)
        Issue.record("A send review must be one-shot.")
    } catch let error as MailCapabilityError {
        #expect(error == .reviewExpired)
    }
    #expect(await provider.sendCallCount == 1)
}

@Test func mailOutgoingRejectsExpiredReviewsAndRevokedAccountScope() async throws {
    let (defaults, suite) = try isolatedMailDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let provider = SyntheticOutgoingMailProvider()
    let clock = SyntheticMailClock(Date(timeIntervalSince1970: 4_000))
    let service = outgoingService(
        provider: provider, defaults: defaults, clock: { clock.now() }
    )
    let review = try await service.stageOutgoing(
        outgoingRequest(), origin: .userInterface
    )
    clock.advance(by: 121)
    do {
        _ = try await service.sendReviewed(review, origin: .userInterface)
        Issue.record("Expired review must never send.")
    } catch let error as MailCapabilityError {
        #expect(error == .reviewExpired)
    }
    let fresh = try await service.stageOutgoing(outgoingRequest(), origin: .userInterface)
    await service.applyUserReviewedOutgoingPolicy(.disabled)
    do {
        _ = try await service.sendReviewed(fresh, origin: .userInterface)
        Issue.record("Revoking send authority must block the staged message.")
    } catch let error as MailCapabilityError {
        #expect(error == .outgoingDisabled)
    }
    #expect(await provider.sendCallCount == 0)
}


@Test func mailOutgoingReviewExpiresDuringSlowSenderRecheck() async throws {
    let (defaults, suite) = try isolatedMailDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let provider = SyntheticOutgoingMailProvider()
    let clock = SyntheticMailClock(Date(timeIntervalSince1970: 8_000))
    await provider.advanceClock(clock, onIdentityLookup: 2, by: 121)
    let service = outgoingService(
        provider: provider, defaults: defaults, clock: { clock.now() }
    )
    let review = try await service.stageOutgoing(
        outgoingRequest(), origin: .userInterface
    )
    #expect(review.expiresAt == Date(timeIntervalSince1970: 8_120))
    do {
        _ = try await service.sendReviewed(review, origin: .userInterface)
        Issue.record("A slow sender recheck must not extend an expired approval.")
    } catch let error as MailCapabilityError {
        #expect(error == .reviewExpired)
    }
    #expect(await provider.sendCallCount == 0)
    #expect(try !MailSendAttemptStore.hasPending(review.request, defaults: defaults))
}

@Test func mailOutgoingReviewLifetimeBeginsAfterProviderLookup() async throws {
    let (defaults, suite) = try isolatedMailDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let provider = SyntheticOutgoingMailProvider()
    let clock = SyntheticMailClock(Date(timeIntervalSince1970: 9_000))
    await provider.advanceClock(clock, onIdentityLookup: 1, by: 30)
    let service = outgoingService(
        provider: provider, defaults: defaults, clock: { clock.now() }
    )
    let review = try await service.stageOutgoing(
        outgoingRequest(), origin: .userInterface
    )
    #expect(review.expiresAt == Date(timeIntervalSince1970: 9_150))
    #expect(await provider.sendCallCount == 0)
}


@Test func mailReplyProposalPrefillsButNeverApprovesOrSends() async throws {
    let (defaults, suite) = try isolatedMailDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let provider = SyntheticOutgoingMailProvider()
    let service = outgoingService(provider: provider, defaults: defaults)
    let reference = outgoingReference()
    let proposal = try await service.replyProposal(to: reference, origin: .userInterface)
    #expect(proposal.kind == .reply(reference))
    #expect(proposal.senderAddress == "owner@example.invalid")
    #expect(proposal.to == ["sender@example.invalid"])
    #expect(proposal.cc.isEmpty && proposal.bcc.isEmpty)
    #expect(proposal.subject == "Re: Schedule")
    #expect(proposal.body.isEmpty)
    #expect(await provider.sendCallCount == 0)
    do {
        _ = try await service.stageOutgoing(proposal, origin: .userInterface)
        Issue.record("A reply proposal with no reviewed body cannot be sent.")
    } catch let error as MailCapabilityError {
        #expect(error == .invalidOutgoingMessage)
    }
    do {
        _ = try await service.replyProposal(to: reference, origin: .ai)
        Issue.record("AI must not acquire a user-interface reply proposal.")
    } catch let error as MailCapabilityError {
        #expect(error == .originUnsupported)
    }
}

@Test func mailReplyRequiresExactTargetReadScopeAndProviderSupport() async throws {
    let (defaults, suite) = try isolatedMailDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let provider = SyntheticOutgoingMailProvider()
    let reply = outgoingRequest(kind: .reply(outgoingReference()))
    let readOff = outgoingService(provider: provider, defaults: defaults, readEnabled: false)
    do {
        _ = try await readOff.stageOutgoing(reply, origin: .userInterface)
        Issue.record("Reply target reading needs its own read grant.")
    } catch let error as MailCapabilityError {
        #expect(error == .disabled)
    }
    let service = outgoingService(provider: provider, defaults: defaults)
    await provider.setSupportsReply(false)
    do {
        _ = try await service.stageOutgoing(reply, origin: .userInterface)
        Issue.record("Unsupported reply operation must not be exposed.")
    } catch let error as MailCapabilityError {
        #expect(error == .unavailable)
    }
    await provider.setSupportsReply(true)
    await provider.setReplyRecipient("different@example.invalid")
    do {
        _ = try await service.stageOutgoing(reply, origin: .userInterface)
        Issue.record("A different reply recipient must block staging.")
    } catch let error as MailCapabilityError {
        #expect(error == .providerScopeViolation)
    }
    await provider.setReplyRecipient("sender@example.invalid")
    let review = try await service.stageOutgoing(reply, origin: .userInterface)
    _ = try await service.sendReviewed(review, origin: .userInterface)
    #expect(await provider.sentRequests == [reply])
}

@Test func mailOutgoingRevalidatesSenderAndReplyIdentityBeforeSend() async throws {
    let (defaults, suite) = try isolatedMailDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let provider = SyntheticOutgoingMailProvider()
    let service = outgoingService(provider: provider, defaults: defaults)
    let review = try await service.stageOutgoing(
        outgoingRequest(kind: .reply(outgoingReference())), origin: .userInterface
    )
    await provider.setIdentities(["changed@example.invalid"])
    do {
        _ = try await service.sendReviewed(review, origin: .userInterface)
        Issue.record("Account identity changes must block a staged send.")
    } catch let error as MailCapabilityError {
        #expect(error == .providerScopeViolation)
    }
    #expect(await provider.sendCallCount == 0)
}

@Test func mailOutgoingUncertainOutcomeBlocksRetryAcrossServices() async throws {
    let (defaults, suite) = try isolatedMailDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let provider = SyntheticOutgoingMailProvider()
    await provider.setSendError(.timedOut)
    let service = outgoingService(provider: provider, defaults: defaults)
    let request = outgoingRequest()
    let review = try await service.stageOutgoing(request, origin: .userInterface)
    let outcome = try await service.sendReviewed(review, origin: .userInterface)
    #expect(outcome == .uncertain)
    #expect(try MailSendAttemptStore.hasPending(request, defaults: defaults))
    let restarted = outgoingService(provider: provider, defaults: defaults)
    do {
        _ = try await restarted.stageOutgoing(request, origin: .userInterface)
        Issue.record("A timed-out send must not be retried after restarting the service.")
    } catch let error as MailCapabilityError {
        #expect(error == .sendOutcomeUncertain)
    }
    #expect(await provider.sendCallCount == 1)
}

@Test func mailOutgoingRejectsInvalidRecipientsAndCorruptJournal() async throws {
    let (defaults, suite) = try isolatedMailDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let provider = SyntheticOutgoingMailProvider()
    let service = outgoingService(provider: provider, defaults: defaults)
    for request in [
        outgoingRequest(to: ["one@example.invalid", "one@example.invalid"]),
        outgoingRequest(to: ["not an address"]),
        outgoingRequest(cc: ["extra@example.invalid"], bcc: ["extra@example.invalid"]),
        outgoingRequest(body: "   ")
    ] {
        do {
            _ = try await service.stageOutgoing(request, origin: .userInterface)
            Issue.record("Invalid or duplicate outgoing fields must not reach Mail.")
        } catch let error as MailCapabilityError {
            #expect(error == .invalidOutgoingMessage)
        }
    }
    defaults.set(["not-a-fingerprint"], forKey: "lima.mail.sendJournal.pending.v1")
    do {
        _ = try await service.stageOutgoing(outgoingRequest(), origin: .userInterface)
        Issue.record("A corrupt send journal must fail closed.")
    } catch let error as MailCapabilityError {
        #expect(error == .sendJournalUnavailable)
    }
    #expect(await provider.sendCallCount == 0)
}

@Test func mailOutgoingPolicyPersistsSeparatelyAndDisconnects() throws {
    let (defaults, suite) = try isolatedMailDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(MailOutgoingPolicyStore.load(defaults: defaults) == .disabled)
    let policy = MailOutgoingPolicy(sendEnabled: true, selectedAccountIDs: ["synthetic-work"])
    try MailOutgoingPolicyStore.save(policy, defaults: defaults)
    #expect(MailOutgoingPolicyStore.load(defaults: defaults) == policy)
    do {
        try MailOutgoingPolicyStore.save(
            MailOutgoingPolicy(sendEnabled: true, selectedAccountIDs: []),
            defaults: defaults
        )
        Issue.record("A send switch without an account cannot be persisted.")
    } catch let error as MailCapabilityError {
        #expect(error == .invalidRequest)
    }
    MailOutgoingPolicyStore.disconnect(defaults: defaults)
    #expect(MailOutgoingPolicyStore.load(defaults: defaults) == .disabled)
}

@Test func mailOutgoingDismissedReviewCannotSend() async throws {
    let (defaults, suite) = try isolatedMailDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let provider = SyntheticOutgoingMailProvider()
    let service = outgoingService(provider: provider, defaults: defaults)
    let review = try await service.stageOutgoing(outgoingRequest(), origin: .userInterface)
    await service.discardOutgoingReview(review.id)
    do {
        _ = try await service.sendReviewed(review, origin: .userInterface)
        Issue.record("Closing an exact-message review must revoke its send opportunity.")
    } catch let error as MailCapabilityError {
        #expect(error == .reviewExpired)
    }
    #expect(await provider.sendCallCount == 0)
}



@Test func mailOutgoingDismissedDuringSenderRecheckCannotSend() async throws {
    let (defaults, suite) = try isolatedMailDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let provider = SyntheticOutgoingMailProvider()
    let gate = SyntheticMailIdentityGate()
    await provider.pauseIdentityLookup(gate, onLookup: 2)
    let service = outgoingService(provider: provider, defaults: defaults)
    let review = try await service.stageOutgoing(
        outgoingRequest(), origin: .userInterface
    )
    let sendTask = Task {
        try await service.sendReviewed(review, origin: .userInterface)
    }
    await gate.waitUntilEntered()
    await service.discardOutgoingReview(review.id)
    await gate.resume()
    do {
        _ = try await sendTask.value
        Issue.record("Closing the review during preflight must prevent sending.")
    } catch let error as MailCapabilityError {
        #expect(error == .reviewExpired)
    }
    #expect(await provider.sendCallCount == 0)
    #expect(try !MailSendAttemptStore.hasPending(review.request, defaults: defaults))
}

@Test func mailOutgoingFailedJournalClearKeepsAttemptBlocked() throws {
    let suite = "dev.liam.lima.mail-outgoing-journal-tests.\(UUID().uuidString)"
    let defaults = try #require(FailingMailJournalDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let request = outgoingRequest()
    let fingerprint = try MailSendAttemptStore.markPending(request, defaults: defaults)
    defaults.failSynchronize = true
    do {
        try MailSendAttemptStore.clearAccepted(fingerprint, defaults: defaults)
        Issue.record("A failed journal clear must not report a safe retry.")
    } catch let error as MailCapabilityError {
        #expect(error == .sendJournalUnavailable)
    }
    #expect(try MailSendAttemptStore.hasPending(request, defaults: defaults))
}

@Test func mailOutgoingMissingJournalSaltFailsClosed() async throws {
    let (defaults, suite) = try isolatedMailDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let request = outgoingRequest()
    let fingerprint = try MailSendAttemptStore.markPending(request, defaults: defaults)
    #expect(fingerprint.count == 64)
    defaults.removeObject(forKey: "lima.mail.sendJournal.salt.v1")
    let provider = SyntheticOutgoingMailProvider()
    let service = outgoingService(provider: provider, defaults: defaults)
    do {
        _ = try await service.stageOutgoing(request, origin: .userInterface)
        Issue.record("Missing journal salt must not make an ambiguous send look new.")
    } catch let error as MailCapabilityError {
        #expect(error == .sendJournalUnavailable)
    }
    #expect(await provider.sendCallCount == 0)
}

@Test func mailSearchReadReplyJourneyRequiresExactSendApproval() async throws {
    let (defaults, suite) = try isolatedMailDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let provider = SyntheticOutgoingMailProvider()
    await provider.setSupportsRead(true)
    let service = outgoingService(provider: provider, defaults: defaults)
    let search = MailSearchRequest(
        accountIDs: ["work"], mailboxIDs: ["inbox"], query: "schedule",
        receivedAfter: Date(timeIntervalSince1970: 0),
        receivedBefore: Date(timeIntervalSince1970: 86_400), limit: 10
    )
    let result = try await service.search(search, origin: .userInterface)
    let summary = try #require(result.messages.first)
    let message = try await service.message(summary.reference, origin: .userInterface)
    #expect(message.reference == summary.reference)
    #expect(message.body == "Please review the schedule.")

    let proposal = try await service.replyProposal(
        to: message.reference, origin: .userInterface
    )
    #expect(proposal.kind == .reply(message.reference))
    #expect(proposal.body.isEmpty)
    #expect(await provider.sendCallCount == 0)

    await service.applyUserReviewedPolicy(.disabled)
    do {
        _ = try await service.replyProposal(to: message.reference, origin: .userInterface)
        Issue.record("A revoked read grant must block a reply even after reading the message.")
    } catch let error as MailCapabilityError {
        #expect(error == .disabled)
    }
    await service.applyUserReviewedPolicy(MailCapabilityPolicy(
        readEnabled: true, selectedAccountIDs: ["work"], allowsAIRead: false
    ))

    let exactReply = MailOutgoingRequest(
        kind: proposal.kind, accountID: proposal.accountID,
        senderAddress: proposal.senderAddress, to: proposal.to,
        cc: proposal.cc, bcc: proposal.bcc,
        subject: proposal.subject, body: "I will review it today."
    )
    let review = try await service.stageOutgoing(exactReply, origin: .userInterface)
    #expect(review.request == exactReply)
    #expect(await provider.sendCallCount == 0)
    let outcome = try await service.sendReviewed(review, origin: .userInterface)
    #expect(outcome == .accepted(MailSendReceipt(
        acceptedAt: Date(timeIntervalSince1970: 3_000),
        providerMessageID: "synthetic-sent-1"
    )))
    #expect(await provider.sentRequests == [exactReply])
    #expect(await provider.searchCallCount == 1)
    #expect(await provider.messageCallCount == 1)
}
