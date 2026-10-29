import AppKit
import Combine
import SwiftUI

@MainActor
final class MessagesConversationWindowController: NSObject {
    static let shared = MessagesConversationWindowController()
    private var window: NSWindow?

    func present(conversationGUID: String, title: String,
                 selectedMessageGUID: String? = nil) {
        let view = MessagesConversationView(
            conversationGUID: conversationGUID, title: title,
            selectedMessageGUID: selectedMessageGUID
        )
        if let window {
            window.contentView = NSHostingView(rootView: LimaTypographyRoot(content: view))
            window.title = title
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LimaTypographyRoot(content: view))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

private struct MessagesConversationView: View {
    let conversationGUID: String
    let title: String
    let selectedMessageGUID: String?

    @State private var messages: [MessagesMessage] = []
    @State private var participants: [String] = []
    @State private var loading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title2.weight(.semibold))
                    Text(participants.isEmpty
                         ? "Selected Messages conversation"
                         : participants.joined(separator: ", "))
                        .limaFont(.caption)
                        .foregroundStyle(LimaTheme.textSecondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Refresh") { Task { await load() } }
                    .disabled(loading)
                Button("Add to Context Shelf") {
                    Task { await addToContext() }
                }
                    .disabled(loading)
                Button("Create Note") {
                    Task { await createNote() }
                }
                    .disabled(loading || messages.isEmpty)
                Button("Compose Reply") { compose() }
                    .disabled(!MessagesCapabilityPolicyStore.load().sendEnabled ||
                              participants.isEmpty || loading)
            }
            if loading {
                ProgressView("Reading selected conversation…")
            }
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(messages) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(message.isFromMe
                                     ? "You" : (message.senderAddress ?? "Unknown sender"))
                                    .fontWeight(.semibold)
                                Spacer()
                                Text(message.sentAt.formatted(date: .abbreviated,
                                                              time: .shortened))
                                    .limaFont(.caption)
                                    .foregroundStyle(LimaTheme.textSecondary)
                            }
                            Text(message.text ?? "Content unavailable (\(message.contentStatus))")
                                .textSelection(.enabled)
                                .foregroundStyle(message.text == nil
                                                 ? LimaTheme.textSecondary : Color.primary)
                            if message.guid == selectedMessageGUID {
                                Text("Selected search result")
                                    .limaFont(.caption)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(message.guid == selectedMessageGUID
                                    ? Color.accentColor.opacity(0.12)
                                    : Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            Text("Local read-only view · recent selected scope only. Messages may contain partial or unsupported content. Sending requires a separate exact-message review.")
                .limaFont(.caption)
                .foregroundStyle(LimaTheme.textSecondary)
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: 480)
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(
            for: .limaMessagesPolicyDidChange
        )) { _ in
            messages = []
            participants = []
            if MessagesCapabilityPolicyStore.load().permits(conversationGUID) {
                Task { await load() }
            } else {
                errorMessage = MessagesCapabilityError.conversationNotPermitted.localizedDescription
            }
        }
        .onDisappear {
            messages = []
            participants = []
        }
    }

    @MainActor
    private func load() async {
        guard !loading else { return }
        loading = true
        errorMessage = nil
        defer { loading = false }
        let policy = MessagesCapabilityPolicyStore.load()
        guard policy.permits(conversationGUID) else {
            errorMessage = MessagesCapabilityError.conversationNotPermitted.localizedDescription
            messages = []
            participants = []
            return
        }
        do {
            let end = Date()
            async let rows = MessagesCapabilityService.shared.messages(
                in: conversationGUID,
                after: end.addingTimeInterval(-Double(policy.historyDays) * 86_400),
                before: end, limit: 50, origin: .userInterface
            )
            async let people = MessagesCapabilityService.shared.participants(
                in: conversationGUID, origin: .userInterface
            )
            let (newMessages, newParticipants) = try await (rows, people)
            var displayMessages = newMessages
            var selectedUnavailable = false
            if let selectedMessageGUID,
               !newMessages.contains(where: { $0.guid == selectedMessageGUID }) {
                if let selected = try? await MessagesCapabilityService.shared.message(
                    selectedMessageGUID, in: conversationGUID, origin: .userInterface
                ) {
                    displayMessages.insert(selected, at: 0)
                } else {
                    selectedUnavailable = true
                }
            }
            guard !Task.isCancelled,
                  MessagesCapabilityPolicyStore.load().permits(conversationGUID) else {
                messages = []
                participants = []
                errorMessage = MessagesCapabilityError.conversationNotPermitted.localizedDescription
                return
            }
            messages = displayMessages
            participants = newParticipants
            if selectedUnavailable {
                errorMessage = "The selected message is no longer available in this history window."
            }
        } catch {
            messages = []
            participants = []
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func addToContext() async {
        guard MessagesCapabilityPolicyStore.load().permits(conversationGUID) else {
            errorMessage = MessagesCapabilityError.conversationNotPermitted.localizedDescription
            return
        }
        let reference = MessageContextReference(
            kind: .conversation, conversationGUID: conversationGUID,
            messageGUID: nil, selectedText: nil,
            participantLabels: participants,
            messageDate: messages.first?.sentAt,
            service: messages.first?.service,
            capturedAt: Date()
        )
        guard ContextShelfIntegration.addMessageReference(reference, title: title) != nil else {
            errorMessage = "Could not add this Messages reference to Context Shelf."
            return
        }
        errorMessage = nil
    }

    @MainActor
    private func createNote() async {
        guard !loading else { return }
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            let noteID = try await MessagesNoteBridge.createRecentExcerpt(
                conversationGUID: conversationGUID, title: title
            )
            if (NSApp.delegate as? AppDelegate)?.openReviewedNote(noteID) != true {
                errorMessage = "The Messages Note was saved, but Lima could not open the Notes workspace."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func compose() {
        let proposal = MessagesOutgoingRequest(
            destination: .existingConversation(guid: conversationGUID,
                                               participants: participants),
            text: ""
        )
        _ = MessagesComposeWindowController.shared.present(
            proposal, conversationTitle: title
        )
    }
}
