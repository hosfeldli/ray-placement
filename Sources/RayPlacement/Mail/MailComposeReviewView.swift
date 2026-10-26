import SwiftUI

/// Presents an editable proposal, then a separate immutable exact-message
/// review. Only the final button invokes `sendReviewed`; creating or editing a
/// proposal never grants authority or sends an Apple Event.
struct MailComposeReviewView: View {
    private let kind: MailOutgoingKind
    private let accountID: String
    private let service: MailCapabilityService
    private let onOutcome: (MailSendOutcome) -> Void

    @State private var senderAddress: String
    @State private var toInput: String
    @State private var ccInput: String
    @State private var bccInput: String
    @State private var subject: String
    @State private var bodyText: String
    @State private var review: MailOutgoingReview?
    @State private var isWorking = false
    @State private var isPresented = false
    @State private var finished = false
    @State private var status: String?
    @State private var statusIsWarning = false

    init(proposal: MailOutgoingRequest,
         service: MailCapabilityService = .shared,
         onOutcome: @escaping (MailSendOutcome) -> Void = { _ in }) {
        kind = proposal.kind
        accountID = proposal.accountID
        self.service = service
        self.onOutcome = onOutcome
        _senderAddress = State(initialValue: proposal.senderAddress)
        _toInput = State(initialValue: proposal.to.joined(separator: ", "))
        _ccInput = State(initialValue: proposal.cc.joined(separator: ", "))
        _bccInput = State(initialValue: proposal.bcc.joined(separator: ", "))
        _subject = State(initialValue: proposal.subject)
        _bodyText = State(initialValue: proposal.body)
    }

    var body: some View {
        Form {
            if let review {
                Section("Review exact email") {
                    LabeledContent("From account", value: review.request.accountID)
                    LabeledContent("From address", value: review.request.senderAddress)
                    LabeledContent("To", value: review.request.to.joined(separator: ", "))
                    if !review.request.cc.isEmpty {
                        LabeledContent("Cc", value: review.request.cc.joined(separator: ", "))
                    }
                    if !review.request.bcc.isEmpty {
                        LabeledContent("Bcc", value: review.request.bcc.joined(separator: ", "))
                    }
                    LabeledContent("Subject", value: review.request.subject)
                    if case .reply(let source) = review.request.kind {
                        LabeledContent("Reply to", value: source.subject)
                        LabeledContent("Source account", value: source.accountID)
                        LabeledContent("Source message", value: source.internetMessageID ?? String(source.messageID))
                    }
                    ScrollView {
                        Text(review.request.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 130, maxHeight: 260)
                    Text("Review every recipient and the complete message. Sending this exact email needs a separate click; changes require a new review.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Edit Message") {
                        let oldID = review.id
                        self.review = nil
                        Task { await service.discardOutgoingReview(oldID) }
                    }
                    .disabled(isWorking || finished)
                    Spacer()
                    Button("Send This Email") {
                        Task { await send(review) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking || finished)
                }
            } else if !finished {
                Section("Compose email") {
                    LabeledContent("From account", value: accountID)
                    TextField("From address", text: $senderAddress)
                    TextField("To", text: $toInput)
                    if case .newMessage = kind {
                        TextField("Cc", text: $ccInput)
                        TextField("Bcc", text: $bccInput)
                    }
                    TextField("Subject", text: $subject)
                    TextEditor(text: $bodyText)
                        .frame(minHeight: 150)
                    if case .reply(let source) = kind {
                        Text("Replying to \(source.subject) from \(source.sender). Lima checks the original message and the reply address again before sending.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Review Exact Email") {
                    Task { await stage() }
                }
                .disabled(isWorking)
            }

            if isWorking {
                ProgressView()
                    .controlSize(.small)
            }
            if let status {
                Section("Mail status") {
                    Text(status)
                        .foregroundStyle(statusIsWarning ? Color.orange : Color.primary)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 460)
        .interactiveDismissDisabled(isWorking)
        .onAppear { isPresented = true }
        .onDisappear {
            isPresented = false
            if let review {
                Task { await service.discardOutgoingReview(review.id) }
            }
        }
    }

    private func addresses(_ input: String) -> [String] {
        input.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    @MainActor
    private func stage() async {
        guard !isWorking else { return }
        isWorking = true
        status = nil
        statusIsWarning = false
        defer { isWorking = false }
        let proposal = MailOutgoingRequest(
            kind: kind, accountID: accountID, senderAddress: senderAddress,
            to: addresses(toInput),
            cc: kind.isReply ? [] : addresses(ccInput),
            bcc: kind.isReply ? [] : addresses(bccInput),
            subject: subject, body: bodyText
        )
        do {
            let staged = try await service.stageOutgoing(proposal, origin: .userInterface)
            guard isPresented else {
                await service.discardOutgoingReview(staged.id)
                return
            }
            review = staged
        } catch {
            status = error.localizedDescription
            statusIsWarning = true
        }
    }

    @MainActor
    private func send(_ exactReview: MailOutgoingReview) async {
        guard !isWorking, !finished else { return }
        isWorking = true
        status = nil
        statusIsWarning = false
        defer { isWorking = false }
        do {
            let outcome = try await service.sendReviewed(
                exactReview, origin: .userInterface
            )
            review = nil
            finished = true
            switch outcome {
            case .accepted:
                status = "Apple Mail accepted this email for sending. Delivery may still be pending."
            case .uncertain:
                status = "Mail may have sent this email. Check Sent in Apple Mail before taking any further action; Lima will not retry it."
                statusIsWarning = true
            }
            onOutcome(outcome)
        } catch {
            // A failed final preflight consumes this approval. Re-open the
            // exact-message review rather than leaving a stale Send button.
            review = nil
            await service.discardOutgoingReview(exactReview.id)
            if let mailError = error as? MailCapabilityError,
               mailError == .sendOutcomeUncertain {
                finished = true
            }
            status = error.localizedDescription
            statusIsWarning = true
        }
    }
}

private extension MailOutgoingKind {
    var isReply: Bool {
        if case .reply = self { return true }
        return false
    }
}
