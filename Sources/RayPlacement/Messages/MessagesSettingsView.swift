import AppKit
import SwiftUI

private struct MessagesComposeSheet: Identifiable {
    let id = UUID()
    let proposal: MessagesOutgoingRequest
    let title: String
}

/// Opening Settings does not read Messages history or send Apple Events.
/// Discovery is an explicit, bounded user action after history access is on.
struct MessagesSettingsView: View {
    @State private var policy = MessagesCapabilityPolicyStore.load()
    @State private var chats: [MessagesConversation] = []
    @State private var hasDiscoveredChats = false
    @State private var isDiscovering = false
    @State private var isPreparingCompose = false
    @State private var messagesAvailable = false
    @State private var readStatus = "Not checked"
    @State private var statusMessage: String?
    @State private var composeSheet: MessagesComposeSheet?
    @State private var confirmDisconnect = false
    @State private var generation = UUID()

    var body: some View {
        Group {
            Section("Messages connection") {
                LabeledContent("Messages", value: messagesAvailable ? "Available" : "Not found")
                LabeledContent("History read test", value: readStatus)
                LabeledContent("macOS Automation", value: "Checked when sending")
                Text("Reading local Messages history requires Full Disk Access. This is a broad macOS grant; the conversation choices below restrict Lima's own reads, not the OS grant. Finding conversations only reads local metadata.")
                    .limaFont(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
                HStack {
                    Button("Open Full Disk Access Settings") {
                        PermissionCenter.shared.openSystemSettings(for: "Privacy_AllFiles")
                    }
                    .buttonStyle(.link)
                    Button("Open Automation Settings") {
                        PermissionCenter.shared.openSystemSettings(for: "Privacy_Automation")
                    }
                    .buttonStyle(.link)
                }
                Button("Find Recent Conversations") {
                    Task { await discoverChats() }
                }
                .disabled(!policy.readEnabled || isDiscovering)
                if isDiscovering {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Section("Messages reading") {
                Toggle("Enable local conversation-history access", isOn: readEnabledBinding)
                Toggle("Allow selected conversations in AI", isOn: aiReadBinding)
                    .disabled(!policy.readEnabled || policy.selectedConversationGUIDs.isEmpty)
                Text("AI reads are limited to selected, non-excluded conversations. Content can reach the configured AI provider when you ask it to use Messages; incoming messages are never instructions to Lima.")
                    .limaFont(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
                Stepper("Default history window: \(policy.historyDays) days",
                        value: historyDaysBinding, in: 1...365)
                if hasDiscoveredChats {
                    if chats.isEmpty {
                        Text("No recent conversations were found.")
                            .foregroundStyle(LimaTheme.textSecondary)
                    } else {
                        ForEach(chats) { chat in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Toggle(chat.title, isOn: selectionBinding(for: chat.guid))
                                    if policy.selectedConversationGUIDs.contains(chat.guid) {
                                        Button(policy.excludedConversationGUIDs.contains(chat.guid)
                                               ? "Allow" : "Exclude") {
                                            toggleExcluded(chat.guid)
                                        }
                                        .buttonStyle(.link)
                                    }
                                }
                                Text(chat.service ?? (chat.isGroup ? "Group conversation" : "Direct conversation"))
                                    .limaFont(.caption)
                                    .foregroundStyle(LimaTheme.textSecondary)
                                if policy.permits(chat.guid) {
                                    Button("Add conversation to Context Shelf") {
                                        Task { await addToContext(chat) }
                                    }
                                    .buttonStyle(.link)
                                }
                                if policy.sendEnabled && policy.permits(chat.guid) {
                                    Button("Compose in this conversation") {
                                        Task { await beginCompose(in: chat) }
                                    }
                                    .buttonStyle(.link)
                                    .disabled(isPreparingCompose)
                                }
                            }
                        }
                    }
                } else if !policy.selectedConversationGUIDs.isEmpty {
                    Text("\(policy.selectedConversationGUIDs.count) conversation(s) selected previously. Find conversations to review the selection.")
                        .limaFont(.caption)
                        .foregroundStyle(LimaTheme.textSecondary)
                }
            }

            Section("Messages sending") {
                Toggle("Enable sending through Messages", isOn: sendEnabledBinding)
                    .disabled(!messagesAvailable)
                Toggle("Allow AI to prepare messages for review", isOn: aiComposeBinding)
                    .disabled(!policy.sendEnabled)
                Text("Every send requires a separate review of the actual destination and exact text. This text-only composer does not support file attachments. An uncertain send is never retried automatically; its pending journal remains even if Messages is disconnected.")
                    .limaFont(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
            }

            Section("Messages monitoring") {
                Text("Incoming-message monitoring is off. It is not yet available from this Settings surface.")
                    .limaFont(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
            }

            Section("Messages privacy") {
                Text("History reads stay local until an authorized AI operation uses selected content. Lima does not modify the Messages database. Full Disk Access must be removed in macOS Settings if you no longer want the OS-level grant.")
                    .limaFont(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
                if let statusMessage {
                    Text(statusMessage)
                        .limaFont(.caption)
                        .foregroundStyle(.orange)
                }
                Button("Disconnect Messages from Lima", role: .destructive) {
                    confirmDisconnect = true
                }
                .disabled(policy == .disabled && chats.isEmpty)
            }
        }
        .onAppear {
            policy = MessagesCapabilityPolicyStore.load()
            messagesAvailable = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iChat") != nil
        }
        .confirmationDialog("Disconnect Messages from Lima?", isPresented: $confirmDisconnect) {
            Button("Disconnect Messages", role: .destructive) {
                generation = UUID()
                MessagesCapabilityPolicyStore.disconnect()
                ContextShelfStore.shared.removeMessageReferences()
                policy = .disabled
                chats = []
                hasDiscoveredChats = false
                composeSheet = nil
                readStatus = "Not checked"
                statusMessage = nil
            }
        } message: {
            Text("Lima will forget its conversation selections and disable Messages access. It will not change Messages, Full Disk Access, Automation, or unresolved send-journal entries.")
        }
        .sheet(item: $composeSheet) { sheet in
            MessagesComposeReviewView(proposal: sheet.proposal,
                                      conversationTitle: sheet.title)
        }
    }

    private var readEnabledBinding: Binding<Bool> {
        Binding(get: { policy.readEnabled }, set: { enabled in
            var next = policy
            next.readEnabled = enabled
            if !enabled {
                next.aiReadEnabled = false
                next.monitorEnabled = false
                generation = UUID()
                chats = []
                hasDiscoveredChats = false
                readStatus = "Not checked"
            }
            save(next)
        })
    }

    private var aiReadBinding: Binding<Bool> {
        Binding(get: { policy.aiReadEnabled }, set: { enabled in
            var next = policy
            next.aiReadEnabled = enabled && next.readEnabled &&
                !next.selectedConversationGUIDs.isEmpty
            save(next)
        })
    }

    private var sendEnabledBinding: Binding<Bool> {
        Binding(get: { policy.sendEnabled }, set: { enabled in
            var next = policy
            next.sendEnabled = enabled
            if !enabled { next.aiComposeEnabled = false }
            save(next)
        })
    }

    private var aiComposeBinding: Binding<Bool> {
        Binding(get: { policy.aiComposeEnabled }, set: { enabled in
            var next = policy
            next.aiComposeEnabled = enabled && next.sendEnabled
            save(next)
        })
    }

    private var historyDaysBinding: Binding<Int> {
        Binding(get: { policy.historyDays }, set: { days in
            var next = policy
            next.historyDays = days
            save(next)
        })
    }

    private func selectionBinding(for guid: String) -> Binding<Bool> {
        Binding(get: { policy.selectedConversationGUIDs.contains(guid) },
                set: { selected in
            var next = policy
            if selected {
                next.selectedConversationGUIDs.insert(guid)
            } else {
                next.selectedConversationGUIDs.remove(guid)
                next.excludedConversationGUIDs.remove(guid)
                if next.selectedConversationGUIDs.isEmpty {
                    next.aiReadEnabled = false
                }
            }
            save(next)
        })
    }

    private func toggleExcluded(_ guid: String) {
        var next = policy
        if next.excludedConversationGUIDs.contains(guid) {
            next.excludedConversationGUIDs.remove(guid)
        } else {
            next.excludedConversationGUIDs.insert(guid)
        }
        save(next)
    }

    private func save(_ next: MessagesCapabilityPolicy) {
        do {
            try MessagesCapabilityPolicyStore.save(next)
            if !next.readEnabled {
                ContextShelfStore.shared.removeMessageReferences()
            } else {
                let oldAllowed = policy.selectedConversationGUIDs
                    .subtracting(policy.excludedConversationGUIDs)
                let newAllowed = next.selectedConversationGUIDs
                    .subtracting(next.excludedConversationGUIDs)
                let revoked = oldAllowed.subtracting(newAllowed)
                if !revoked.isEmpty {
                    ContextShelfStore.shared.removeMessageReferences(conversationGUIDs: revoked)
                }
            }
            policy = next
            statusMessage = nil
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    @MainActor
    private func discoverChats() async {
        guard !isDiscovering, policy.readEnabled else { return }
        isDiscovering = true
        statusMessage = nil
        let requestGeneration = generation
        defer { isDiscovering = false }
        do {
            let found = try await MessagesCapabilityService.shared.discoverChats(limit: 100)
            guard requestGeneration == generation, policy.readEnabled else { return }
            chats = found
            hasDiscoveredChats = true
            readStatus = "Read test succeeded"
        } catch {
            guard requestGeneration == generation else { return }
            readStatus = "Unavailable"
            statusMessage = error.localizedDescription
        }
    }

    @MainActor
    private func addToContext(_ chat: MessagesConversation) async {
        guard policy.permits(chat.guid) else { return }
        statusMessage = nil
        let requestGeneration = generation
        do {
            let participants = try await MessagesCapabilityService.shared.participants(
                in: chat.guid, origin: .userInterface
            )
            guard requestGeneration == generation, policy.permits(chat.guid) else { return }
            let reference = MessageContextReference(
                kind: .conversation, conversationGUID: chat.guid,
                messageGUID: nil, selectedText: nil,
                participantLabels: participants, messageDate: chat.lastMessageAt,
                service: chat.service, capturedAt: Date()
            )
            guard ContextShelfIntegration.addMessageReference(reference, title: chat.title) != nil else {
                statusMessage = "Could not add this Messages reference to Context Shelf."
                return
            }
        } catch {
            if requestGeneration == generation { statusMessage = error.localizedDescription }
        }
    }

    @MainActor
    private func beginCompose(in chat: MessagesConversation) async {
        guard !isPreparingCompose, policy.sendEnabled, policy.permits(chat.guid) else { return }
        isPreparingCompose = true
        statusMessage = nil
        let requestGeneration = generation
        defer { isPreparingCompose = false }
        do {
            let participants = try await MessagesCapabilityService.shared.participants(
                in: chat.guid, origin: .userInterface
            )
            guard requestGeneration == generation,
                  policy.sendEnabled, policy.permits(chat.guid) else { return }
            let request = MessagesOutgoingRequest(
                destination: .existingConversation(guid: chat.guid,
                                                   participants: participants),
                text: ""
            )
            composeSheet = MessagesComposeSheet(proposal: request, title: chat.title)
        } catch {
            if requestGeneration == generation {
                statusMessage = error.localizedDescription
            }
        }
    }
}
