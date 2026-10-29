import AppKit
import SwiftUI

/// Presents an editable proposal, then a separate immutable exact-message
/// review. Only the final button invokes `sendReviewed`; creating or editing a
/// proposal never grants authority or sends an Apple Event.
struct MailComposeReviewView: View {
    private let kind: MailOutgoingKind
    private let accountID: String
    private let service: MailCapabilityService
    private let onOutcome: (MailSendOutcome) -> Void
    private let onDismiss: (@MainActor () -> Void)?
    private let onBusyChanged: (@MainActor (Bool) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var senderAddress: String
    @State private var toInput: String
    @State private var ccInput: String
    @State private var bccInput: String
    @State private var subject: String
    @State private var bodyText: String
    @State private var attachments: [MailOutgoingAttachment]
    @State private var review: MailOutgoingReview?
    @State private var isWorking = false
    @State private var isPreparingIdentity = false
    @State private var isPresented = false
    @State private var finished = false
    @State private var status: String?
    @State private var statusIsWarning = false

    init(proposal: MailOutgoingRequest,
         service: MailCapabilityService = .shared,
         onOutcome: @escaping (MailSendOutcome) -> Void = { _ in },
         onDismiss: (@MainActor () -> Void)? = nil,
         onBusyChanged: (@MainActor (Bool) -> Void)? = nil) {
        kind = proposal.kind
        accountID = proposal.accountID
        self.service = service
        self.onOutcome = onOutcome
        self.onDismiss = onDismiss
        self.onBusyChanged = onBusyChanged
        _senderAddress = State(initialValue: proposal.senderAddress)
        _toInput = State(initialValue: proposal.to.joined(separator: ", "))
        _ccInput = State(initialValue: proposal.cc.joined(separator: ", "))
        _bccInput = State(initialValue: proposal.bcc.joined(separator: ", "))
        _subject = State(initialValue: proposal.subject)
        _bodyText = State(initialValue: proposal.body)
        _attachments = State(initialValue: proposal.attachments)
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
                    if !review.request.attachments.isEmpty {
                        ForEach(review.request.attachments, id: \.path) { attachment in
                            LabeledContent("Attachment", value: "\(attachment.path) (\(attachment.byteCount) bytes)")
                        }
                    }
                    switch review.request.kind {
                    case .newMessage:
                        EmptyView()
                    case .reply(let source):
                        LabeledContent("Reply to", value: source.subject)
                        LabeledContent("Source account", value: source.accountID)
                        LabeledContent("Source message", value: source.internetMessageID ?? String(source.messageID))
                    case .forward(let source):
                        LabeledContent("Forward of", value: source.subject)
                        LabeledContent("Source account", value: source.accountID)
                        LabeledContent("Source message", value: source.internetMessageID ?? String(source.messageID))
                    }
                    ScrollView {
                        Text(review.request.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 130, maxHeight: 260)
                    Text("Review every recipient, the complete message, and each attachment path. Files are rechecked before sending. Sending this exact email needs a separate click; changes require a new review.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Cancel") { cancel() }
                        .disabled(isWorking || finished)
                    Button("Edit Message") {
                        let oldID = review.id
                        self.review = nil
                        Task { await service.discardOutgoingReview(oldID) }
                    }
                    .disabled(isWorking || finished)
                    Spacer()
                    Button("Save Draft") {
                        Task { await saveDraft(exactReview: review) }
                    }
                    .disabled(isWorking || finished || !MailOutgoingPolicyStore.load().draftEnabled)
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
                        .disabled(isPreparingIdentity)
                    if senderAddress.isEmpty && !isPreparingIdentity {
                        Button("Retry Mail Account Lookup") {
                            Task { await prepareSender() }
                        }
                        .disabled(isWorking)
                    }
                    TextField("To", text: $toInput)
                        .disabled(isPreparingIdentity)
                    TextField("Cc", text: $ccInput)
                    TextField("Bcc", text: $bccInput)
                    TextField("Subject", text: $subject)
                    TextEditor(text: $bodyText)
                        .frame(minHeight: 150)
                    HStack {
                        Button("Add Attachments…") { chooseAttachments() }
                        Spacer()
                        Text("Up to four files, 20 MB each")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(attachments, id: \.path) { attachment in
                        HStack {
                            Text("\(attachment.displayName) (\(attachment.byteCount) bytes)")
                                .lineLimit(1)
                            Spacer()
                            Button("Remove") {
                                attachments.removeAll { $0.path == attachment.path }
                            }
                        }
                    }
                    switch kind {
                    case .newMessage:
                        EmptyView()
                    case .reply(let source):
                        Text("Replying to \(source.subject) from \(source.sender). Lima checks the source and reply address again before sending.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .forward(let source):
                        Text("Forwarding \(source.subject) from \(source.sender). Lima checks the source again before sending. Original attachments are not included automatically; add any files explicitly.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Cancel") { cancel() }
                        .disabled(isWorking)
                    Button("Save Draft in Apple Mail") {
                        Task { await saveDraft() }
                    }
                    .disabled(isWorking || isPreparingIdentity || senderAddress.isEmpty ||
                              !MailOutgoingPolicyStore.load().draftEnabled)
                    Spacer()
                    Button("Review Exact Email") {
                        Task { await stage() }
                    }
                    .disabled(isWorking || isPreparingIdentity || senderAddress.isEmpty ||
                              !MailOutgoingPolicyStore.load().sendEnabled)
                }
            } else {
                Button("Close") { cancel() }
            }

            if isPreparingIdentity {
                ProgressView("Confirming Mail account and sender…")
                    .controlSize(.small)
            } else if isWorking {
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
        .onAppear {
            isPresented = true
            if senderAddress.isEmpty {
                Task { await prepareSender() }
            }
        }
        .onDisappear {
            isPresented = false
            if let review {
                Task { await service.discardOutgoingReview(review.id) }
            }
        }
    }

    @MainActor
    private func prepareSender() async {
        guard isPresented, !finished, !isWorking, !isPreparingIdentity,
              senderAddress.isEmpty else { return }
        isPreparingIdentity = true
        status = nil
        defer { isPreparingIdentity = false }
        do {
            switch kind {
            case .newMessage:
                let senders = try await service.availableSenders(
                    accountID: accountID, origin: .userInterface
                )
                guard isPresented else { return }
                senderAddress = senders[0]
            case .reply(let source):
                let resolved = try await service.replyProposal(
                    to: source, origin: .userInterface
                )
                guard isPresented else { return }
                senderAddress = resolved.senderAddress
                toInput = resolved.to.joined(separator: ", ")
                if subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    subject = resolved.subject
                }
            case .forward(let source):
                let resolved = try await service.forwardProposal(
                    of: source, origin: .userInterface
                )
                guard isPresented else { return }
                senderAddress = resolved.senderAddress
                if subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    subject = resolved.subject
                }
            }
        } catch {
            guard isPresented else { return }
            status = error.localizedDescription
            statusIsWarning = true
        }
    }

    private func addresses(_ input: String) -> [String] {
        input.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    @MainActor
    private func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        do {
            let selected = try panel.urls.map(MailOutgoingAttachment.capture)
            let combined = attachments + selected
            guard combined.count <= 4,
                  Set(combined.map(\.path)).count == combined.count,
                  combined.reduce(Int64(0), { $0 + $1.byteCount }) <= 40 * 1_024 * 1_024 else {
                throw MailCapabilityError.invalidOutgoingMessage
            }
            attachments = combined
            status = nil
        } catch {
            status = (error as? MailCapabilityError)?.localizedDescription ??
                "Lima could not read a selected attachment."
            statusIsWarning = true
        }
    }

    private func currentProposal() -> MailOutgoingRequest {
        MailOutgoingRequest(
            kind: kind, accountID: accountID, senderAddress: senderAddress,
            to: addresses(toInput), cc: addresses(ccInput),
            bcc: addresses(bccInput), subject: subject, body: bodyText,
            attachments: attachments
        )
    }

    @MainActor
    private func cancel() {
        guard !isWorking else { return }
        if let review {
            self.review = nil
            Task { await service.discardOutgoingReview(review.id) }
        }
        if let onDismiss { onDismiss() } else { dismiss() }
    }

    @MainActor
    private func saveDraft(exactReview: MailOutgoingReview? = nil) async {
        guard !isWorking, !isPreparingIdentity, !finished else { return }
        isWorking = true
        onBusyChanged?(true)
        status = nil
        statusIsWarning = false
        defer {
            isWorking = false
            onBusyChanged?(false)
        }
        let proposal = exactReview?.request ?? currentProposal()
        if let exactReview {
            // Saving a draft is a different action. Revoke the one-shot send
            // review before Mail receives any draft Apple Event.
            review = nil
            await service.discardOutgoingReview(exactReview.id)
        }
        do {
            let outcome = try await service.saveDraft(proposal, origin: .userInterface)
            guard isPresented else { return }
            finished = true
            switch outcome {
            case .saved:
                status = "Apple Mail accepted this draft for saving. Open Drafts in Mail to continue editing it."
            case .uncertain:
                status = "Mail may have saved this draft. Check Drafts before creating another copy; Lima will not retry it."
                statusIsWarning = true
            }
        } catch {
            status = error.localizedDescription
            statusIsWarning = true
        }
    }

    @MainActor
    private func stage() async {
        guard !isWorking, !isPreparingIdentity else { return }
        isWorking = true
        onBusyChanged?(true)
        status = nil
        statusIsWarning = false
        defer {
            isWorking = false
            onBusyChanged?(false)
        }
        let proposal = currentProposal()
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
        onBusyChanged?(true)
        status = nil
        statusIsWarning = false
        defer {
            isWorking = false
            onBusyChanged?(false)
        }
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
