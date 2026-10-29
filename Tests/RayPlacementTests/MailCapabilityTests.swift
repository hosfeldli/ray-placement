import Foundation
import Testing
@testable import RayPlacement

private actor FixtureMailProvider: MailProvider {
    var accountCallCount = 0
    var returnedAccounts = [
        MailAccount(id: "work", name: "Work"),
        MailAccount(id: "personal", name: "Personal")
    ]
    var searchCallCount = 0
    var messageCallCount = 0
    var returnedAccountID = "work"
    var coverageAccountIDs: Set<String>?
    var coverageMailboxIDs: Set<String>?
    var returnedMailboxes: [MailMailbox]?
    var returnedMessageReference: MailMessageReference?
    var returnedBody = "Please review the schedule."

    func supportedOperations() async -> Set<MailOperation> {
        [.listAccounts, .listMailboxes, .search, .getMessage]
    }

    func accounts() async throws -> [MailAccount] {
        accountCallCount += 1
        return returnedAccounts
    }

    func mailboxes(accountID: String) async throws -> [MailMailbox] {
        returnedMailboxes ?? [MailMailbox(id: "inbox", accountID: accountID, name: "Inbox", path: "Inbox")]
    }

    func search(_ request: MailSearchRequest) async throws -> MailSearchResult {
        searchCallCount += 1
        let reference = MailMessageReference(
            accountID: returnedAccountID, mailboxID: "inbox", messageID: 42,
            internetMessageID: "<fixture@example.invalid>",
            subject: "Schedule", sender: "Team",
            receivedAt: Date(timeIntervalSince1970: 1_000),
            capturedAt: Date(timeIntervalSince1970: 2_000)
        )
        return MailSearchResult(
            messages: [MailMessageSummary(reference: reference, isRead: false, isFlagged: false)],
            coverage: MailSearchCoverage(accountIDs: coverageAccountIDs ?? [returnedAccountID], mailboxIDs: coverageMailboxIDs ?? ["inbox"],
                                         candidateCount: 1, isPartial: false, partialReason: nil)
        )
    }

    func message(_ reference: MailMessageReference) async throws -> MailMessage {
        messageCallCount += 1
        return MailMessage(reference: returnedMessageReference ?? reference, body: returnedBody)
    }

    func setReturnedAccounts(_ value: [MailAccount]) { returnedAccounts = value }
    func setReturnedAccountID(_ value: String) { returnedAccountID = value }
    func setCoverageAccountIDs(_ value: Set<String>) { coverageAccountIDs = value }
    func setCoverageMailboxIDs(_ value: Set<String>) { coverageMailboxIDs = value }
    func setReturnedMailboxes(_ value: [MailMailbox]) { returnedMailboxes = value }
    func setReturnedMessageReference(_ value: MailMessageReference) { returnedMessageReference = value }
    func setReturnedBody(_ value: String) { returnedBody = value }
}

private func mailFixtureRequest(accountIDs: Set<String> = ["work"],
                                limit: Int = 20) -> MailSearchRequest {
    MailSearchRequest(accountIDs: accountIDs, mailboxIDs: ["inbox"], query: "schedule",
                      receivedAfter: Date(timeIntervalSince1970: 0),
                      receivedBefore: Date(timeIntervalSince1970: 86_400),
                      limit: limit)
}

@Test func mailAIToolDefinitionsSerializeForStrictProviders() {
    let policy = MailCapabilityPolicy(readEnabled: true,
                                      selectedAccountIDs: ["work"], allowsAIRead: true)
    let outgoing = MailOutgoingPolicy(sendEnabled: true, selectedAccountIDs: ["work"])
    let definitions = AIMailTools.definitions(policy: policy, outgoing: outgoing)
    #expect(Set(definitions.map(\.id)) == AIMailTools.ids)
    #expect(definitions.allSatisfy { $0.responsePayload != nil })
    #expect(AIMailTools.definitions(policy: .disabled, outgoing: outgoing).isEmpty)
}

@Test func mailAccountDiscoveryIsUIOnlyAndRejectsMalformedRecords() async throws {
    let provider = FixtureMailProvider()
    let service = MailCapabilityService(provider: provider)
    do {
        _ = try await service.discoverAccounts(origin: .ai)
        Issue.record("AI must not trigger Mail account discovery or an Automation prompt.")
    } catch let error as MailCapabilityError {
        #expect(error == .originUnsupported)
    }
    #expect(await provider.accountCallCount == 0)

    let accounts = try await service.discoverAccounts(origin: .userInterface)
    #expect(accounts.map(\.id) == ["work", "personal"])
    #expect(await provider.accountCallCount == 1)

    await provider.setReturnedAccounts([
        MailAccount(id: "duplicate", name: "One"),
        MailAccount(id: "duplicate", name: "Two")
    ])
    do {
        _ = try await service.discoverAccounts(origin: .userInterface)
        Issue.record("Duplicate account identifiers must not reach Settings.")
    } catch let error as MailCapabilityError {
        #expect(error == .malformedResponse)
    }
}

@Test func mailCapabilityFailsClosedBeforeProviderRead() async {
    let provider = FixtureMailProvider()
    let service = MailCapabilityService(provider: provider)
    do {
        _ = try await service.search(mailFixtureRequest(), origin: .userInterface)
        Issue.record("Mail must be off by default.")
    } catch let error as MailCapabilityError {
        #expect(error == .disabled)
    } catch {
        Issue.record("Unexpected Mail policy error: \(error)")
    }
    #expect(await provider.searchCallCount == 0)

    await service.applyUserReviewedPolicy(MailCapabilityPolicy(
        readEnabled: true, selectedAccountIDs: ["work"], allowsAIRead: false
    ))
    do {
        _ = try await service.search(mailFixtureRequest(accountIDs: ["personal"]), origin: .userInterface)
        Issue.record("An unselected account must not be searched.")
    } catch let error as MailCapabilityError {
        #expect(error == .accountNotSelected)
    } catch {
        Issue.record("Unexpected Mail scope error: \(error)")
    }
    #expect(await provider.searchCallCount == 0)
}

@Test func mailCapabilitySeparatesUIAndAIReadAuthority() async throws {
    let provider = FixtureMailProvider()
    let service = MailCapabilityService(provider: provider, policy: MailCapabilityPolicy(
        readEnabled: true, selectedAccountIDs: ["work"], allowsAIRead: false
    ))
    let result = try await service.search(mailFixtureRequest(), origin: .userInterface)
    #expect(result.messages.count == 1)

    do {
        _ = try await service.search(mailFixtureRequest(), origin: .ai)
        Issue.record("UI Mail access must not imply AI Mail access.")
    } catch let error as MailCapabilityError {
        #expect(error == .aiAccessDenied)
    } catch {
        Issue.record("Unexpected AI Mail policy error: \(error)")
    }
    #expect(await provider.searchCallCount == 1)
}

@Test func mailCapabilityRejectsOutOfScopeResultsAndUnboundedRequests() async {
    let provider = FixtureMailProvider()
    let service = MailCapabilityService(provider: provider, policy: MailCapabilityPolicy(
        readEnabled: true, selectedAccountIDs: ["work"], allowsAIRead: false
    ))
    do {
        _ = try await service.search(mailFixtureRequest(limit: 101), origin: .userInterface)
        Issue.record("Mail search must be bounded.")
    } catch let error as MailCapabilityError {
        #expect(error == .invalidRequest)
    } catch {
        Issue.record("Unexpected bound error: \(error)")
    }
    #expect(await provider.searchCallCount == 0)

    await provider.setReturnedAccountID("personal")
    do {
        _ = try await service.search(mailFixtureRequest(), origin: .userInterface)
        Issue.record("Provider results must never widen the selected account scope.")
    } catch let error as MailCapabilityError {
        #expect(error == .providerScopeViolation)
    } catch {
        Issue.record("Unexpected provider scope error: \(error)")
    }
}

@Test func mailCapabilityRejectsFalseCompleteCoverage() async {
    let provider = FixtureMailProvider()
    await provider.setCoverageAccountIDs(["work"])
    let service = MailCapabilityService(provider: provider, policy: MailCapabilityPolicy(
        readEnabled: true, selectedAccountIDs: ["work", "personal"], allowsAIRead: false
    ))
    do {
        _ = try await service.search(
            mailFixtureRequest(accountIDs: ["work", "personal"]), origin: .userInterface
        )
        Issue.record("A one-account search cannot claim complete two-account coverage.")
    } catch let error as MailCapabilityError {
        #expect(error == .providerScopeViolation)
    } catch {
        Issue.record("Unexpected coverage error: \(error)")
    }
}

@Test func appleMailAdapterAdvertisesImplementedNativeOperations() async {
    let adapter = AppleMailAdapter()
    #expect(await adapter.supportedOperations() == [
        .listAccounts, .listMailboxes, .search, .getMessage,
        .openMessage, .createDraft, .reply, .forward, .send,
        .move, .delete
    ])
}

@Test func mailShelfReferenceRequiresCurrentSelectedUIAccessWithoutReadingBody() async throws {
    let provider = FixtureMailProvider()
    let service = MailCapabilityService(provider: provider, policy: MailCapabilityPolicy(
        readEnabled: true, selectedAccountIDs: ["work"], allowsAIRead: false
    ))
    let result = try await service.search(mailFixtureRequest(), origin: .userInterface)
    let reference = try #require(result.messages.first?.reference)
    #expect(try await service.referenceForShelf(reference, origin: .userInterface) == reference)
    #expect(await provider.messageCallCount == 0)

    do {
        _ = try await service.referenceForShelf(reference, origin: .ai)
        Issue.record("A Mail Shelf reference must be created only from UI review.")
    } catch let error as MailCapabilityError {
        #expect(error == .originUnsupported)
    }
    await service.applyUserReviewedPolicy(.disabled)
    do {
        _ = try await service.referenceForShelf(reference, origin: .userInterface)
        Issue.record("Revoked Mail account access must prevent a new Shelf reference.")
    } catch let error as MailCapabilityError {
        #expect(error == .disabled)
    }
    #expect(await provider.messageCallCount == 0)
}

@Test func mailCapabilityBoundsOnDemandMessageBodies() async {
    let provider = FixtureMailProvider()
    let service = MailCapabilityService(provider: provider, policy: MailCapabilityPolicy(
        readEnabled: true, selectedAccountIDs: ["work"], allowsAIRead: false
    ))
    let reference = MailMessageReference(
        accountID: "work", mailboxID: "inbox", messageID: 42,
        internetMessageID: nil, subject: "Schedule", sender: "Team",
        receivedAt: Date(timeIntervalSince1970: 1_000),
        capturedAt: Date(timeIntervalSince1970: 2_000)
    )
    await provider.setReturnedBody(String(repeating: "x", count: 128 * 1_024 + 1))
    do {
        _ = try await service.message(reference, origin: .userInterface)
        Issue.record("Oversized Mail bodies must not leave the capability boundary.")
    } catch let error as MailCapabilityError {
        #expect(error == .messageTooLarge)
    } catch {
        Issue.record("Unexpected message bound error: \(error)")
    }
    #expect(await provider.messageCallCount == 1)
}

@Test func mailPolicyStorePersistsOnlyExplicitValidScopeAndDisconnects() throws {
    let suiteName = "dev.liam.lima.mail-tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(MailCapabilityPolicyStore.load(defaults: defaults) == .disabled)
    let selected = MailCapabilityPolicy(
        readEnabled: true, selectedAccountIDs: ["synthetic-work"], allowsAIRead: false
    )
    try MailCapabilityPolicyStore.save(selected, defaults: defaults)
    #expect(MailCapabilityPolicyStore.load(defaults: defaults) == selected)

    let latentAIGrant = MailCapabilityPolicy(
        readEnabled: false, selectedAccountIDs: ["synthetic-work"], allowsAIRead: true
    )
    do {
        try MailCapabilityPolicyStore.save(latentAIGrant, defaults: defaults)
        Issue.record("A disabled Mail policy must not retain a latent AI grant.")
    } catch let error as MailCapabilityError {
        #expect(error == .invalidRequest)
    }
    #expect(MailCapabilityPolicyStore.load(defaults: defaults) == selected)

    defaults.set(Data("not-json".utf8), forKey: "lima.mail.readPolicy.v1")
    #expect(MailCapabilityPolicyStore.load(defaults: defaults) == .disabled)
    MailCapabilityPolicyStore.disconnect(defaults: defaults)
    #expect(MailCapabilityPolicyStore.load(defaults: defaults) == .disabled)
}

private actor RevokingMailProvider: MailProvider {
    let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    func supportedOperations() async -> Set<MailOperation> { [.search] }
    func accounts() async throws -> [MailAccount] { [] }
    func mailboxes(accountID: String) async throws -> [MailMailbox] { [] }

    func search(_ request: MailSearchRequest) async throws -> MailSearchResult {
        MailCapabilityPolicyStore.disconnect(defaults: defaults)
        return MailSearchResult(
            messages: [],
            coverage: MailSearchCoverage(accountIDs: request.accountIDs,
                                         mailboxIDs: request.mailboxIDs,
                                         candidateCount: 0,
                                         isPartial: false,
                                         partialReason: nil)
        )
    }

    func message(_ reference: MailMessageReference) async throws -> MailMessage {
        throw MailCapabilityError.unavailable
    }
}

@Test func mailCapabilityRejectsResultsAfterPolicyRevocation() async throws {
    let suiteName = "dev.liam.lima.mail-tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    try MailCapabilityPolicyStore.save(MailCapabilityPolicy(
        readEnabled: true, selectedAccountIDs: ["work"], allowsAIRead: false
    ), defaults: defaults)
    let provider = RevokingMailProvider(defaults: defaults)
    let service = MailCapabilityService(
        provider: provider,
        policyLoader: {
            guard let currentDefaults = UserDefaults(suiteName: suiteName) else { return .disabled }
            return MailCapabilityPolicyStore.load(defaults: currentDefaults)
        }
    )
    do {
        _ = try await service.search(mailFixtureRequest(), origin: .userInterface)
        Issue.record("A result must not escape after the selected-account policy is revoked.")
    } catch let error as MailCapabilityError {
        #expect(error == .disabled)
    }
}

@Test func mailCapabilityRejectsDuplicateOrCrossAccountMailboxes() async {
    let provider = FixtureMailProvider()
    let service = MailCapabilityService(provider: provider, policy: MailCapabilityPolicy(
        readEnabled: true, selectedAccountIDs: ["work"], allowsAIRead: false
    ))
    let inbox = MailMailbox(id: "inbox", accountID: "work", name: "Inbox", path: "Inbox")
    await provider.setReturnedMailboxes([inbox, inbox])
    do {
        _ = try await service.mailboxes(accountID: "work", origin: .userInterface)
        Issue.record("Duplicate mailbox IDs must not leave the capability boundary.")
    } catch let error as MailCapabilityError {
        #expect(error == .providerScopeViolation)
    } catch {
        Issue.record("Unexpected mailbox error: \(error)")
    }
    await provider.setReturnedMailboxes([
        MailMailbox(id: "inbox", accountID: "personal", name: "Inbox", path: "Inbox")
    ])
    do {
        _ = try await service.mailboxes(accountID: "work", origin: .userInterface)
        Issue.record("A mailbox from another account must not leave the capability boundary.")
    } catch let error as MailCapabilityError {
        #expect(error == .providerScopeViolation)
    } catch {
        Issue.record("Unexpected mailbox scope error: \(error)")
    }
}

@Test func mailCapabilityRejectsFalseCompleteMailboxCoverage() async {
    let provider = FixtureMailProvider()
    await provider.setCoverageMailboxIDs([])
    let service = MailCapabilityService(provider: provider, policy: MailCapabilityPolicy(
        readEnabled: true, selectedAccountIDs: ["work"], allowsAIRead: false
    ))
    do {
        _ = try await service.search(mailFixtureRequest(), origin: .userInterface)
        Issue.record("A result cannot claim complete coverage while omitting its mailbox.")
    } catch let error as MailCapabilityError {
        #expect(error == .providerScopeViolation)
    } catch {
        Issue.record("Unexpected coverage error: \(error)")
    }
}

@Test func mailCapabilityRejectsSubstitutedMessageIdentity() async {
    let provider = FixtureMailProvider()
    let service = MailCapabilityService(provider: provider, policy: MailCapabilityPolicy(
        readEnabled: true, selectedAccountIDs: ["work"], allowsAIRead: false
    ))
    let reference = MailMessageReference(
        accountID: "work", mailboxID: "inbox", messageID: 42,
        internetMessageID: "<original@example.invalid>",
        subject: "Schedule", sender: "Team",
        receivedAt: Date(timeIntervalSince1970: 1_000),
        capturedAt: Date(timeIntervalSince1970: 2_000)
    )
    let substitute = MailMessageReference(
        accountID: "work", mailboxID: "inbox", messageID: 42,
        internetMessageID: "<different@example.invalid>",
        subject: "Schedule", sender: "Team",
        receivedAt: reference.receivedAt, capturedAt: reference.capturedAt
    )
    await provider.setReturnedMessageReference(substitute)
    do {
        _ = try await service.message(reference, origin: .userInterface)
        Issue.record("A different Internet Message-ID must not satisfy the requested body read.")
    } catch let error as MailCapabilityError {
        #expect(error == .providerScopeViolation)
    } catch {
        Issue.record("Unexpected message identity error: \(error)")
    }
}

@Test func mailSearchReadToReviewedActionNoteRechecksSelectedAccount() async throws {
    let provider = FixtureMailProvider()
    let policy = MailCapabilityPolicy(
        readEnabled: true, selectedAccountIDs: ["work"], allowsAIRead: false
    )
    let service = MailCapabilityService(provider: provider, policy: policy)
    let result = try await service.search(mailFixtureRequest(), origin: .userInterface)
    let reference = try #require(result.messages.first?.reference)
    let firstRead = try await service.message(reference, origin: .userInterface)
    #expect(firstRead.body.contains("Please review the schedule."))

    let proposal = MailManualActionNoteProposal(
        source: reference, noteTitle: "Schedule follow-up",
        actionTitle: "Review the schedule",
        evidenceExcerpt: "Please review the schedule.",
        taskID: UUID(), capturedAt: Date(timeIntervalSince1970: 3_000)
    )
    await service.applyUserReviewedPolicy(.disabled)
    do {
        _ = try await service.message(reference, origin: .userInterface)
        Issue.record("Revoked account selection must prevent the note's final read.")
    } catch let error as MailCapabilityError {
        #expect(error == .disabled)
    }
    #expect(await provider.messageCallCount == 1)

    await service.applyUserReviewedPolicy(policy)
    let freshRead = try await service.message(reference, origin: .userInterface)
    let draft = try proposal.draft(from: freshRead)
    let created = try await MainActor.run { () throws -> Bool in
        let store = NotesStore(visualFixtures: [])
        let id = try store.createMailActionNote(draft)
        return store.notes.count == 1 &&
            store.notes.first?.id == id &&
            store.notes.first?.mailTaskProvenance.count == 1
    }
    #expect(created)
    #expect(await provider.messageCallCount == 2)
}

@Test func mailReferenceIdentityDoesNotCollideAcrossColonBoundaries() {
    let first = MailMessageReference(
        accountID: "a:b", mailboxID: "c", messageID: 42,
        internetMessageID: nil, subject: "One", sender: "Team",
        receivedAt: Date(timeIntervalSince1970: 1_000),
        capturedAt: Date(timeIntervalSince1970: 2_000)
    )
    let second = MailMessageReference(
        accountID: "a", mailboxID: "b:c", messageID: 42,
        internetMessageID: nil, subject: "Two", sender: "Team",
        receivedAt: first.receivedAt, capturedAt: first.capturedAt
    )
    #expect(first.id != second.id)
}
