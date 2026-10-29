import AppKit
import SwiftUI

/// Editing is separate from the immutable, one-shot review. No Apple Event is
/// issued until the user clicks the final send button in this view.
struct MessagesComposeReviewView: View {
    private let destination: MessagesDestination
    private let conversationTitle: String
    private let service: MessagesCapabilityService
    private let onDismiss: (@MainActor () -> Void)?
    private let onBusyChanged: (@MainActor (Bool) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var messageText: String
    @State private var review: MessagesOutgoingReview?
    @State private var isWorking = false
    @State private var finished = false
    @State private var isPresented = false
    @State private var status: String?
    @State private var statusIsWarning = false

    init(proposal: MessagesOutgoingRequest,
         conversationTitle: String,
         service: MessagesCapabilityService = .shared,
         onDismiss: (@MainActor () -> Void)? = nil,
         onBusyChanged: (@MainActor (Bool) -> Void)? = nil) {
        destination = proposal.destination
        self.conversationTitle = conversationTitle
        self.service = service
        self.onDismiss = onDismiss
        self.onBusyChanged = onBusyChanged
        _messageText = State(initialValue: proposal.text)
    }

    var body: some View {
        Form {
            if let review {
                Section("Review exact message") {
                    LabeledContent("Conversation", value: conversationTitle)
                    LabeledContent("Destination", value: review.request.destination.displayAddress)
                    switch review.request.destination {
                    case .existingConversation(let guid, let participants):
                        LabeledContent("Conversation ID", value: guid)
                        Text("Participants (\(participants.count))")
                            .fontWeight(.semibold)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(participants, id: \.self) { address in
                                    Text(address).textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 110)
                    case .direct(_, let serviceID):
                        LabeledContent("Messaging service", value: serviceID)
                    }
                    ScrollView {
                        Text(review.request.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 130, maxHeight: 260)
                    Text("This sends the exact text above to the destination shown. Changes require a new review. Messages accepting the request does not confirm delivery.")
                        .limaFont(.caption)
                        .foregroundStyle(LimaTheme.textSecondary)
                }
                HStack {
                    Button("Cancel") { close() }
                        .disabled(isWorking)
                    Button("Edit Message") {
                        let id = review.id
                        self.review = nil
                        Task { await service.discardOutgoingReview(id) }
                    }
                    .disabled(isWorking)
                    Spacer()
                    Button("Send This Message") {
                        Task { await send(review) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking)
                }
            } else if !finished {
                Section("Compose message") {
                    LabeledContent("Conversation", value: conversationTitle)
                    LabeledContent("Destination", value: destination.displayAddress)
                    if case .direct(_, let serviceID) = destination {
                        LabeledContent("Messaging service", value: serviceID)
                    }
                    TextEditor(text: $messageText)
                        .frame(minHeight: 150)
                    Text("Only text is supported in this composer. A prepared message is not sent until you review the final destination and text and click Send This Message.")
                        .limaFont(.caption)
                        .foregroundStyle(LimaTheme.textSecondary)
                }
                HStack {
                    Button("Cancel") { close() }
                        .disabled(isWorking)
                    Spacer()
                    Button("Review Exact Message") {
                        Task { await stage() }
                    }
                    .disabled(isWorking || messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Button("Close") { close() }
            }

            if isWorking {
                ProgressView()
                    .controlSize(.small)
            }
            if let status {
                Section("Messages status") {
                    Text(status)
                        .foregroundStyle(statusIsWarning ? Color.orange : Color.primary)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 430)
        .interactiveDismissDisabled(isWorking)
        .onAppear { isPresented = true }
        .onDisappear {
            isPresented = false
            if let review {
                Task { await service.discardOutgoingReview(review.id) }
            }
        }
    }

    @MainActor
    private func close() {
        guard !isWorking else { return }
        if let review {
            self.review = nil
            Task { await service.discardOutgoingReview(review.id) }
        }
        if let onDismiss { onDismiss() } else { dismiss() }
    }

    @MainActor
    private func stage() async {
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
            let request = MessagesOutgoingRequest(destination: destination, text: messageText)
            let staged = try await service.prepareOutgoing(request, origin: .userInterface)
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
    private func send(_ exactReview: MessagesOutgoingReview) async {
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
            _ = try await service.sendReviewed(exactReview, origin: .userInterface)
            review = nil
            finished = true
            status = "Messages accepted this request. Sending and delivery may still be pending."
        } catch {
            review = nil
            finished = true
            status = error.localizedDescription
            statusIsWarning = true
        }
    }
}
