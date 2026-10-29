import SwiftUI

/// Exact, one-shot review for local Mail organization. The displayed message
/// and destination are immutable; a different action requires a new review.
struct MailMessageActionReviewView: View {
    let review: MailMessageActionReview
    let service: MailCapabilityService
    let onCompleted: (MailMessageActionReceipt) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isSubmitting = false
    @State private var didSubmit = false
    @State private var status: String?

    private var actionTitle: String {
        switch review.request.kind {
        case .move: return "Move This Email"
        case .archive: return "Archive This Email"
        case .delete: return "Delete This Email"
        }
    }

    private var actionDescription: String {
        switch review.request.kind {
        case .move(let mailbox):
            return "Move from its current mailbox to \(mailbox.path)."
        case .archive(let mailbox):
            return "Move from its current mailbox to \(mailbox.path)."
        case .delete:
            return "Ask Apple Mail to delete this message. Mail may move it to Trash according to the account’s settings."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review Mail Change")
                .font(.title2.weight(.semibold))
            Text(actionDescription)
                .foregroundStyle(.secondary)
            LabeledContent("Account", value: review.request.reference.accountID)
            LabeledContent("From", value: review.request.reference.sender)
            LabeledContent("Subject", value: review.request.reference.subject.isEmpty
                           ? "(No subject)" : review.request.reference.subject)
            LabeledContent("Received", value: review.request.reference.receivedAt
                .formatted(date: .abbreviated, time: .shortened))
            if let target = review.request.kind.targetMailbox {
                LabeledContent("Destination", value: target.path)
            }
            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            HStack {
                Button("Close") { dismiss() }
                Spacer()
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(actionTitle) { submit() }
                    .disabled(isSubmitting || didSubmit)
            }
        }
        .padding(20)
        .frame(minWidth: 440)
        .onDisappear {
            Task { await service.discardMessageActionReview(review.id) }
        }
    }

    @MainActor
    private func submit() {
        guard !didSubmit, !isSubmitting else { return }
        isSubmitting = true
        didSubmit = true
        status = nil
        Task {
            defer { isSubmitting = false }
            do {
                switch try await service.applyReviewedMessageAction(
                    review, origin: .userInterface
                ) {
                case .completed(let receipt):
                    onCompleted(receipt)
                    dismiss()
                case .uncertain:
                    status = "Apple Mail may have applied this change. Check Mail before taking another action; Lima will not retry automatically."
                }
            } catch let error as MailCapabilityError {
                status = error.localizedDescription
            } catch {
                status = "Lima could not finish this Mail change. Check Apple Mail before trying again."
            }
        }
    }
}
