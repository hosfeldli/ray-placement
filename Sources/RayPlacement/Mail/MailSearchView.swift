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
/// issue Apple Events; each search is limited to one selected account, seven
/// days, and 50 results. Message bodies live only in this view's state.
struct MailSearchView: View {
    let account: MailAccount
    let service: MailCapabilityService

    @State private var query = ""
    @State private var results: [MailMessageSummary] = []
    @State private var coverage: MailSearchCoverage?
    @State private var selectedReference: MailMessageReference?
    @State private var openedMessage: MailMessage?
    @State private var status: String?
    @State private var isSearching = false
    @State private var isReading = false
    @State private var isPreparingReply = false
    @State private var isAddingToContext = false
    @State private var supportedOperations: Set<MailOperation> = []
    @State private var composeSheet: MailReplyComposeSheet?
    @State private var actionNoteSheet: MailActionNoteSheet?
    @State private var generation = UUID()
    @State private var searchTask: Task<Void, Never>?
    @State private var readTask: Task<Void, Never>?
    @State private var replyTask: Task<Void, Never>?
    @State private var contextTask: Task<Void, Never>?

    init(account: MailAccount, service: MailCapabilityService = .shared) {
        self.account = account
        self.service = service
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mail — \(account.name)")
                .font(.title2.weight(.semibold))
            Text("Search only this selected account's last seven days. Results may be partial; Lima never searches other accounts automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                TextField("Search subject or sender", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { startSearch() }
                    .disabled(isSearching)
                    .accessibilityLabel("Mail search query")
                Button("Search Mail") { startSearch() }
                    .disabled(isSearching || query.utf8.count > 256)
                if isSearching {
                    Button("Cancel Search") { cancelSearch() }
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
                            Button("Create Action Note…") {
                                actionNoteSheet = MailActionNoteSheet(message: openedMessage)
                            }
                            Button("Add Reference to Context") {
                                startAddToContext(openedMessage.reference)
                            }
                            .disabled(isAddingToContext)
                            if supportedOperations.contains(.reply) && supportedOperations.contains(.send) {
                                Button("Reply…") {
                                    startReply(to: openedMessage.reference)
                                }
                                .disabled(isPreparingReply)
                            }
                            if isPreparingReply {
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
            searchTask?.cancel()
            readTask?.cancel()
            replyTask?.cancel()
            contextTask?.cancel()
            searchTask = nil
            readTask = nil
            replyTask = nil
            contextTask = nil
            isSearching = false
            isReading = false
            isPreparingReply = false
            isAddingToContext = false
            selectedReference = nil
            openedMessage = nil
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
    }

    @MainActor
    private func startSearch() {
        searchTask?.cancel()
        readTask?.cancel()
        replyTask?.cancel()
        contextTask?.cancel()
        replyTask = nil
        contextTask = nil
        isPreparingReply = false
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
            accountIDs: [account.id], mailboxIDs: [],
            query: query.trimmingCharacters(in: .whitespacesAndNewlines),
            receivedAfter: end.addingTimeInterval(-7 * 24 * 60 * 60),
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
        contextTask?.cancel()
        replyTask = nil
        contextTask = nil
        isPreparingReply = false
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
