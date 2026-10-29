import SwiftUI

private struct MailReplyComposeSheet: Identifiable {
    let id = UUID()
    let proposal: MailOutgoingRequest
}

private struct MailActionNoteSheet: Identifiable {
    let id = UUID()
    let message: MailMessage
}

/// A deliberately user-initiated Mail browser. Opening this view does not
/// issue Apple Events; each search is limited to one selected account, an
/// explicit bounded date range, and 50 results. Bodies live only in view state.
struct MailSearchView: View {
    let account: MailAccount
    let service: MailCapabilityService

    @State private var query = ""
    @State private var daysBack = 7
    @State private var mailboxes: [MailMailbox] = []
    @State private var selectedMailboxIDs: Set<String> = []
    @State private var isLoadingMailboxes = false
    @State private var results: [MailMessageSummary] = []
    @State private var coverage: MailSearchCoverage?
    @State private var selectedReference: MailMessageReference?
    @State private var openedMessage: MailMessage?
    @State private var status: String?
    @State private var isSearching = false
    @State private var isReading = false
    @State private var isPreparingReply = false
    @State private var isOpeningInMail = false
    @State private var isAddingToContext = false
    @State private var isPreparingMessageAction = false
    @State private var messageActionReview: MailMessageActionReview?
    @State private var supportedOperations: Set<MailOperation> = []
    @State private var composeSheet: MailReplyComposeSheet?
    @State private var actionNoteSheet: MailActionNoteSheet?
    @State private var generation = UUID()
    @State private var mailboxGeneration = UUID()
    @State private var searchTask: Task<Void, Never>?
    @State private var mailboxTask: Task<Void, Never>?
    @State private var readTask: Task<Void, Never>?
    @State private var replyTask: Task<Void, Never>?
    @State private var openTask: Task<Void, Never>?
    @State private var contextTask: Task<Void, Never>?
    @State private var messageActionTask: Task<Void, Never>?

    init(account: MailAccount, service: MailCapabilityService = .shared) {
        self.account = account
        self.service = service
    }

    private var canComposeInSelectedAccount: Bool {
        let policy = MailOutgoingPolicyStore.load()
        return policy.selectedAccountIDs.contains(account.id) &&
            (policy.draftEnabled || policy.sendEnabled) &&
            (supportedOperations.contains(.createDraft) || supportedOperations.contains(.send))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mail — \(account.name)")
                .font(.title2.weight(.semibold))
            Text("Search only this selected account. Use sender:, recipient:, subject:, or content: to narrow a field. Results may be partial; Lima never searches other accounts automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                TextField("Search Mail or use sender:, recipient:, subject:, content:", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { startSearch() }
                    .disabled(isSearching || isLoadingMailboxes)
                    .accessibilityLabel("Mail search query")
                Button("Search Mail") { startSearch() }
                    .disabled(isSearching || isLoadingMailboxes || query.utf8.count > 256)
                if isSearching {
                    Button("Cancel Search") { cancelSearch() }
                }
            }

            HStack {
                Picker("Date range", selection: $daysBack) {
                    Text("Past day").tag(1)
                    Text("Past 7 days").tag(7)
                    Text("Past 14 days").tag(14)
                    Text("Past 30 days").tag(30)
                }
                .frame(width: 180)
                if mailboxes.isEmpty {
                    Button(isLoadingMailboxes ? "Loading Mailboxes…" : "Load Mailboxes") {
                        loadMailboxes()
                    }
                    .disabled(isLoadingMailboxes)
                } else {
                    Menu(selectedMailboxIDs.isEmpty
                         ? "All Mailboxes"
                         : "\(selectedMailboxIDs.count) Mailbox\(selectedMailboxIDs.count == 1 ? "" : "es")") {
                        Button("All Mailboxes") { selectedMailboxIDs = [] }
                        Divider()
                        ForEach(mailboxes) { mailbox in
                            Button {
                                if selectedMailboxIDs.contains(mailbox.id) {
                                    selectedMailboxIDs.remove(mailbox.id)
                                } else {
                                    selectedMailboxIDs.insert(mailbox.id)
                                }
                            } label: {
                                Label(mailbox.path,
                                      systemImage: selectedMailboxIDs.contains(mailbox.id)
                                      ? "checkmark" : "tray")
                            }
                        }
                    }
                }
            }

            if let coverage {
                Text(coverage.isPartial
                     ? "Partial results: \(results.count) shown from \(coverage.candidateCount) candidates. Not all Mail was searched."
                     : "\(results.count) results from \(coverage.candidateCount) candidates in this account.")
                    .font(.caption)
                    .foregroundStyle(coverage.isPartial ? Color.orange : Color.secondary)
            }
            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            HStack(alignment: .top, spacing: 12) {
                List(results) { summary in
                    Button {
                        startRead(summary.reference)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(summary.reference.subject.isEmpty ? "(No subject)" : summary.reference.subject)
                                .fontWeight(summary.isRead ? .regular : .semibold)
                                .lineLimit(2)
                            Text(summary.reference.sender)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(summary.reference.receivedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(selectedReference == summary.reference ? Color.accentColor.opacity(0.12) : Color.clear)
                }
                .frame(minWidth: 260)

                VStack(alignment: .leading, spacing: 10) {
                    if isReading {
                        ProgressView("Reading selected message…")
                    } else if let openedMessage {
                        Text(openedMessage.reference.subject.isEmpty ? "(No subject)" : openedMessage.reference.subject)
                            .font(.headline)
                        Text("From: \(openedMessage.reference.sender)")
                            .font(.subheadline)
                        Text(openedMessage.reference.receivedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Divider()
                        ScrollView {
                            Text(openedMessage.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        HStack {
                            if supportedOperations.contains(.openMessage) {
                                Button("Open in Apple Mail") {
                                    startOpenInMail(openedMessage.reference)
                                }
                                .disabled(isOpeningInMail)
                            }
                            Button("Create Action Note…") {
                                actionNoteSheet = MailActionNoteSheet(message: openedMessage)
                            }
                            Button("Add Reference to Context") {
                                startAddToContext(openedMessage.reference)
                            }
                            .disabled(isAddingToContext)
                            if supportedOperations.contains(.reply) && canComposeInSelectedAccount {
                                Button("Reply…") {
                                    startReply(to: openedMessage.reference)
                                }
                                .disabled(isPreparingReply)
                            }
                            if supportedOperations.contains(.forward) && canComposeInSelectedAccount {
                                Button("Forward…") {
                                    startForward(openedMessage.reference)
                                }
                                .disabled(isPreparingReply)
                            }
                            if supportedOperations.contains(.move) ||
                               supportedOperations.contains(.delete) {
                                Menu("Organize") {
                                    if supportedOperations.contains(.move) {
                                        let archiveTargets = mailboxes.filter {
                                            $0.id != openedMessage.reference.mailboxID &&
                                                $0.name.localizedCaseInsensitiveCompare("Archive") == .orderedSame
                                        }
                                        if archiveTargets.count == 1,
                                           let archive = archiveTargets.first {
                                            Button("Archive…") {
                                                startMessageAction(MailMessageActionRequest(
                                                    reference: openedMessage.reference,
                                                    kind: .archive(archive)
                                                ))
                                            }
                                        }
                                        if !mailboxes.isEmpty {
                                            Menu("Move to") {
                                                ForEach(mailboxes.filter {
                                                    $0.id != openedMessage.reference.mailboxID
                                                }) { mailbox in
                                                    Button(mailbox.path) {
                                                        startMessageAction(MailMessageActionRequest(
                                                            reference: openedMessage.reference,
                                                            kind: .move(mailbox)
                                                        ))
                                                    }
                                                }
                                            }
                                        } else {
                                            Text("Load Mailboxes to move or archive")
                                        }
                                    }
                                    if supportedOperations.contains(.delete) {
                                        Button("Delete…", role: .destructive) {
                                            startMessageAction(MailMessageActionRequest(
                                                reference: openedMessage.reference,
                                                kind: .delete
                                            ))
                                        }
                                    }
                                }
                                .disabled(isPreparingMessageAction || isReading)
                            }
                            if isPreparingReply || isOpeningInMail || isPreparingMessageAction {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    } else {
                        Text(results.isEmpty ? "Search to find messages." : "Select a message to read it.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 500)
        .task {
            supportedOperations = await service.supportedOperations()
        }
        .onDisappear {
            generation = UUID()
            mailboxGeneration = UUID()
            searchTask?.cancel()
            mailboxTask?.cancel()
            readTask?.cancel()
            replyTask?.cancel()
            openTask?.cancel()
            contextTask?.cancel()
            messageActionTask?.cancel()
            searchTask = nil
            mailboxTask = nil
            readTask = nil
            replyTask = nil
            openTask = nil
            contextTask = nil
            messageActionTask = nil
            isSearching = false
            isReading = false
            isPreparingReply = false
            isOpeningInMail = false
            isAddingToContext = false
            isPreparingMessageAction = false
            messageActionReview = nil
            selectedReference = nil
            openedMessage = nil
            mailboxes = []
            selectedMailboxIDs = []
            isLoadingMailboxes = false
            results = []
            coverage = nil
            composeSheet = nil
            actionNoteSheet = nil
        }
        .sheet(item: $composeSheet) { sheet in
            MailComposeReviewView(proposal: sheet.proposal, service: service)
        }
        .sheet(item: $actionNoteSheet) { sheet in
            MailActionNoteReviewView(message: sheet.message, service: service)
        }
        .sheet(item: $messageActionReview) { review in
            MailMessageActionReviewView(review: review, service: service) { receipt in
                handleMessageActionCompletion(receipt)
            }
        }
    }

    @MainActor
    private func loadMailboxes() {
        guard !isLoadingMailboxes else { return }
        isLoadingMailboxes = true
        status = nil
        let currentGeneration = mailboxGeneration
        mailboxTask = Task {
            defer {
                if mailboxGeneration == currentGeneration {
                    isLoadingMailboxes = false
                    mailboxTask = nil
                }
            }
            do {
                let result = try await service.mailboxes(
                    accountID: account.id, origin: .userInterface
                )
                guard mailboxGeneration == currentGeneration, !Task.isCancelled else { return }
                mailboxes = result.sorted {
                    $0.path.localizedStandardCompare($1.path) == .orderedAscending
                }
                selectedMailboxIDs.formIntersection(Set(mailboxes.map(\.id)))
            } catch is CancellationError {
                return
            } catch {
                guard mailboxGeneration == currentGeneration else { return }
                status = safeErrorText(error)
            }
        }
    }

    @MainActor
    private func startSearch() {
        guard !isLoadingMailboxes else { return }
        searchTask?.cancel()
        readTask?.cancel()
        replyTask?.cancel()
        openTask?.cancel()
        contextTask?.cancel()
        messageActionTask?.cancel()
        messageActionReview = nil
        isPreparingMessageAction = false
        replyTask = nil
        openTask = nil
        contextTask = nil
        isPreparingReply = false
        isOpeningInMail = false
        isAddingToContext = false
        let nextGeneration = UUID()
        generation = nextGeneration
        selectedReference = nil
        openedMessage = nil
        isReading = false
        results = []
        coverage = nil
        status = nil
        searchTask = Task { await search(for: nextGeneration) }
    }

    @MainActor
    private func cancelSearch() {
        generation = UUID()
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
        status = "Search canceled. Apple Mail may still be finishing the request."
    }

    @MainActor
    private func search(for searchGeneration: UUID) async {
        isSearching = true
        defer {
            if generation == searchGeneration {
                isSearching = false
                searchTask = nil
            }
        }
        let end = Date()
        let request = MailSearchRequest(
            accountIDs: [account.id], mailboxIDs: selectedMailboxIDs,
            query: query.trimmingCharacters(in: .whitespacesAndNewlines),
            receivedAfter: end.addingTimeInterval(-Double(daysBack) * 24 * 60 * 60),
            receivedBefore: end, limit: 50
        )
        do {
            let result = try await service.search(request, origin: .userInterface)
            guard generation == searchGeneration, !Task.isCancelled else { return }
            results = result.messages
            coverage = result.coverage
        } catch is CancellationError {
            guard generation == searchGeneration else { return }
            status = "Search canceled. Apple Mail may still be finishing the request."
        } catch {
            guard generation == searchGeneration else { return }
            status = safeErrorText(error)
        }
    }

    @MainActor
    private func startRead(_ reference: MailMessageReference) {
        readTask?.cancel()
        replyTask?.cancel()
        openTask?.cancel()
        contextTask?.cancel()
        messageActionTask?.cancel()
        messageActionReview = nil
        isPreparingMessageAction = false
        replyTask = nil
        openTask = nil
        contextTask = nil
        isPreparingReply = false
        isOpeningInMail = false
        isAddingToContext = false
        let nextGeneration = UUID()
        generation = nextGeneration
        selectedReference = reference
        openedMessage = nil
        status = nil
        readTask = Task { await read(reference, generation: nextGeneration) }
    }

    @MainActor
    private func read(_ reference: MailMessageReference, generation readGeneration: UUID) async {
        isReading = true
        defer {
            if generation == readGeneration {
                isReading = false
                readTask = nil
            }
        }
        do {
            let message = try await service.message(reference, origin: .userInterface)
            guard generation == readGeneration, !Task.isCancelled else { return }
            openedMessage = message
        } catch is CancellationError {
            return
        } catch {
            guard generation == readGeneration else { return }
            status = safeErrorText(error)
        }
    }

    @MainActor
    private func startOpenInMail(_ reference: MailMessageReference) {
        guard !isOpeningInMail else { return }
        isOpeningInMail = true
        status = nil
        let currentGeneration = generation
        openTask = Task {
            defer {
                if generation == currentGeneration {
                    isOpeningInMail = false
                    openTask = nil
                }
            }
            do {
                try await service.openInMail(reference, origin: .userInterface)
                guard generation == currentGeneration, !Task.isCancelled,
                      openedMessage?.reference == reference else { return }
                status = "Opened the selected message in Apple Mail."
            } catch is CancellationError {
                return
            } catch {
                guard generation == currentGeneration else { return }
                status = safeErrorText(error)
            }
        }
    }

    @MainActor
    private func startForward(_ reference: MailMessageReference) {
        guard !isPreparingReply else { return }
        isPreparingReply = true
        status = nil
        let currentGeneration = generation
        replyTask = Task { await prepareForward(reference, generation: currentGeneration) }
    }

    @MainActor
    private func prepareForward(_ reference: MailMessageReference,
                                generation forwardGeneration: UUID) async {
        defer {
            if generation == forwardGeneration {
                isPreparingReply = false
                replyTask = nil
            }
        }
        do {
            let proposal = try await service.forwardProposal(of: reference, origin: .userInterface)
            guard forwardGeneration == generation, !Task.isCancelled,
                  openedMessage?.reference == reference else { return }
            composeSheet = MailReplyComposeSheet(proposal: proposal)
        } catch is CancellationError {
            return
        } catch {
            guard forwardGeneration == generation else { return }
            status = safeErrorText(error)
        }
    }

    @MainActor
    private func startReply(to reference: MailMessageReference) {
        guard !isPreparingReply else { return }
        isPreparingReply = true
        status = nil
        let currentGeneration = generation
        replyTask = Task { await prepareReply(to: reference, generation: currentGeneration) }
    }

    @MainActor
    private func prepareReply(to reference: MailMessageReference, generation replyGeneration: UUID) async {
        defer {
            if generation == replyGeneration {
                isPreparingReply = false
                replyTask = nil
            }
        }
        do {
            let proposal = try await service.replyProposal(to: reference, origin: .userInterface)
            guard replyGeneration == generation, !Task.isCancelled,
                  openedMessage?.reference == reference else { return }
            composeSheet = MailReplyComposeSheet(proposal: proposal)
        } catch is CancellationError {
            return
        } catch {
            guard replyGeneration == generation else { return }
            status = safeErrorText(error)
        }
    }

    @MainActor
    private func startMessageAction(_ request: MailMessageActionRequest) {
        guard !isPreparingMessageAction,
              openedMessage?.reference == request.reference else { return }
        isPreparingMessageAction = true
        status = nil
        let currentGeneration = generation
        messageActionTask = Task {
            defer {
                if generation == currentGeneration {
                    isPreparingMessageAction = false
                    messageActionTask = nil
                }
            }
            do {
                let review = try await service.stageMessageAction(
                    request, origin: .userInterface
                )
                guard generation == currentGeneration, !Task.isCancelled,
                      openedMessage?.reference == request.reference else {
                    await service.discardMessageActionReview(review.id)
                    return
                }
                messageActionReview = review
            } catch is CancellationError {
                return
            } catch {
                guard generation == currentGeneration else { return }
                status = safeErrorText(error)
            }
        }
    }

    @MainActor
    private func handleMessageActionCompletion(_ receipt: MailMessageActionReceipt) {
        guard let current = openedMessage?.reference,
              current.identifiesSameMessage(as: receipt.request.reference) else { return }
        results.removeAll {
            $0.reference.identifiesSameMessage(as: receipt.request.reference)
        }
        selectedReference = nil
        openedMessage = nil
        switch receipt.request.kind {
        case .move(let mailbox):
            status = "Moved the selected message to \(mailbox.path) in Apple Mail."
        case .archive:
            status = "Archived the selected message in Apple Mail."
        case .delete:
            status = "Deleted the selected message in Apple Mail."
        }
    }

    @MainActor
    private func startAddToContext(_ reference: MailMessageReference) {
        guard !isAddingToContext else { return }
        isAddingToContext = true
        status = nil
        let currentGeneration = generation
        contextTask = Task {
            defer {
                if generation == currentGeneration {
                    isAddingToContext = false
                    contextTask = nil
                }
            }
            do {
                let validated = try await service.referenceForShelf(reference, origin: .userInterface)
                guard generation == currentGeneration, !Task.isCancelled,
                      openedMessage?.reference == validated else { return }
                _ = ContextShelfIntegration.addMailReference(validated)
                status = "Added a message reference to Context. The email body was not stored."
            } catch is CancellationError {
                return
            } catch {
                guard generation == currentGeneration else { return }
                status = safeErrorText(error)
            }
        }
    }

    private func safeErrorText(_ error: Error) -> String {
        if let mailError = error as? MailCapabilityError {
            return mailError.localizedDescription
        }
        return "Lima could not complete the Mail request. Try again or check Apple Mail."
    }
}
