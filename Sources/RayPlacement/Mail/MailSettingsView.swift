import AppKit
import SwiftUI

private struct MailComposeSheet: Identifiable {
    let id = UUID()
    let proposal: MailOutgoingRequest
}

private struct MailSearchSheet: Identifiable {
    let id = UUID()
    let account: MailAccount
}

/// Account discovery is deliberately user initiated. Merely opening Settings
/// must never send an Apple Event, launch Mail, or request Automation access.
struct MailSettingsView: View {
    @State private var policy = MailCapabilityPolicyStore.load()
    @State private var outgoingPolicy = MailOutgoingPolicyStore.load()
    @State private var accounts: [MailAccount] = []
    @State private var hasDiscoveredAccounts = false
    @State private var isDiscoveringAccounts = false
    @State private var statusMessage: String?
    @State private var confirmDisconnect = false
    @State private var discoveryGeneration = UUID()
    @State private var supportedOperations: Set<MailOperation> = []
    @State private var composeSheet: MailComposeSheet?
    @State private var searchSheet: MailSearchSheet?
    @State private var isOpeningComposer = false
    @State private var mailAvailable = false
    @State private var automationPermission: MailAutomationPermission = .notChecked

    var body: some View {
        Group {
            Section("Connection") {
            LabeledContent("Apple Mail", value: mailAvailable ? "Available" : "Not found")
            LabeledContent("macOS Automation", value: automationPermission.label)
            LabeledContent("Selected account scope", value: "\(policy.selectedAccountIDs.count) account\(policy.selectedAccountIDs.count == 1 ? "" : "s")")
            Text("Apple Mail access is scoped to accounts you select. Finding accounts may open Mail and request macOS Automation access; it reads account names and identifiers, not messages.")
                .limaFont(.caption)
                .foregroundStyle(LimaTheme.textSecondary)

            HStack {
                Button("Find Apple Mail Accounts") {
                    Task { await discoverAccounts() }
                }
                .disabled(isDiscoveringAccounts)

                Button("Test Connection") {
                    Task { await discoverAccounts() }
                }
                .disabled(isDiscoveringAccounts)

                if isDiscoveringAccounts {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Button("Open macOS Automation Settings") {
                PermissionCenter.shared.openSystemSettings(for: "Privacy_Automation")
            }
            .buttonStyle(.link)
            Text("Automation status is checked without a prompt while Mail is running. Test Connection is the explicit action that may request permission; macOS controls the final grant.")
                .limaFont(.caption)
                .foregroundStyle(LimaTheme.textSecondary)

            if hasDiscoveredAccounts {
                if accounts.isEmpty {
                    Text("No configured Apple Mail accounts were found.")
                        .foregroundStyle(LimaTheme.textSecondary)
                } else {
                    ForEach(accounts) { account in
                        Toggle(account.name, isOn: selectionBinding(for: account.id))
                    }
                    Text("Only checked accounts are stored in Lima's local Mail policy. Account names and message content are not saved by this setup screen.")
                        .limaFont(.caption)
                        .foregroundStyle(LimaTheme.textSecondary)
                }

                let missingCount = policy.selectedAccountIDs.subtracting(Set(accounts.map(\.id))).count
                if missingCount > 0 {
                    Text("\(missingCount) previously selected account\(missingCount == 1 ? "" : "s") could not be found. Disconnect to clear the old selection.")
                        .limaFont(.caption)
                        .foregroundStyle(.orange)
                }
            } else if !policy.selectedAccountIDs.isEmpty {
                Text("\(policy.selectedAccountIDs.count) account\(policy.selectedAccountIDs.count == 1 ? "" : "s") selected previously. Find accounts to review the selection.")
                    .limaFont(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
            }

            }

            Section("Reading") {
            Toggle("Permit reads from selected accounts", isOn: readEnabledBinding)
                .disabled(!policy.readEnabled &&
                          (!hasDiscoveredAccounts || policy.selectedAccountIDs.isEmpty ||
                           !policy.selectedAccountIDs.isSubset(of: Set(accounts.map(\.id)))))
            Text(supportedOperations.contains(.search) && supportedOperations.contains(.getMessage)
                 ? "Selected-account Mail search and message reading are available. AI access and sending remain separately controlled."
                 : "Mailbox search and message reading are unavailable in this build. AI access and sending remain off until their native operations are available.")
                .limaFont(.caption)
                .foregroundStyle(LimaTheme.textSecondary)

            Toggle("Allow selected-account Mail in AI conversations", isOn: aiReadBinding)
                .disabled(!policy.readEnabled || !supportedOperations.contains(.search) ||
                          !supportedOperations.contains(.getMessage))
            Text("When on, an AI tool may read Mail from only your selected accounts. Message content may be sent to your configured AI provider when you use it in a conversation. Turning this off stops new AI Mail reads.")
                .limaFont(.caption)
                .foregroundStyle(LimaTheme.textSecondary)

            if supportedOperations.contains(.search), supportedOperations.contains(.getMessage),
               policy.readEnabled, hasDiscoveredAccounts {
                ForEach(accounts.filter { policy.selectedAccountIDs.contains($0.id) }) { account in
                    Button("Search Mail in \(account.name)") {
                        searchSheet = MailSearchSheet(account: account)
                    }
                }
            }

            }

            Section("Writing") {
            Toggle("Allow draft creation", isOn: draftEnabledBinding)
                .disabled(!supportedOperations.contains(.createDraft) || outgoingPolicy.selectedAccountIDs.isEmpty)
                .accessibilityIdentifier("mail-enable-drafts")
            Toggle("Enable email sending", isOn: sendEnabledBinding)
                .disabled(!supportedOperations.contains(.send) || outgoingPolicy.selectedAccountIDs.isEmpty)
                .accessibilityIdentifier("mail-enable-sending")
                .limaOnboardingTarget("mail")
            Text("Every email requires review of the final sender, recipients, subject, and body before it is submitted to Apple Mail.")
                .limaFont(.caption)
                .foregroundStyle(LimaTheme.textSecondary)

            if supportedOperations.contains(.send) || supportedOperations.contains(.createDraft) {
                if hasDiscoveredAccounts {
                    ForEach(accounts.filter { policy.selectedAccountIDs.contains($0.id) }) { account in
                        Toggle("Allow drafts or sending from \(account.name)", isOn: writingSelectionBinding(for: account.id))
                    }
                }
                if (outgoingPolicy.sendEnabled || outgoingPolicy.draftEnabled) && hasDiscoveredAccounts {
                    ForEach(accounts.filter { outgoingPolicy.selectedAccountIDs.contains($0.id) }) { account in
                        Button("Compose from \(account.name)") {
                            Task { await beginCompose(accountID: account.id) }
                        }
                        .disabled(isOpeningComposer)
                    }
                }
                Text("Draft creation and sending are separate switches for selected accounts. Replies and forwards also require source-message read access. AI and extensions cannot send directly.")
                    .limaFont(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
            } else {
                Text("Sending, drafts, replies, and forwards are unavailable in this build. The final-message review remains off until native Mail operations are present.")
                    .limaFont(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
            }

            }

            Section("Privacy") {
            Text("Account choices stay local. Mail content is not shared with cloud AI by this setup screen, and Mail-access diagnostics do not contain message bodies.")
                .limaFont(.caption)
                .foregroundStyle(LimaTheme.textSecondary)
            if let statusMessage {
                Text(statusMessage)
                    .limaFont(.caption)
                    .foregroundStyle(.orange)
            }

            Button("Disconnect and Forget Mail Selection", role: .destructive) {
                confirmDisconnect = true
            }
            .disabled(policy == .disabled && outgoingPolicy == .disabled && accounts.isEmpty)
            }
        }
        .onAppear {
            policy = MailCapabilityPolicyStore.load()
            outgoingPolicy = MailOutgoingPolicyStore.load()
            mailAvailable = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail") != nil
        }
        .task {
            supportedOperations = await MailCapabilityService.shared.supportedOperations()
            await refreshAutomationPermission()
        }
        .confirmationDialog("Disconnect Apple Mail from Lima?", isPresented: $confirmDisconnect) {
            Button("Disconnect and Forget Selection", role: .destructive) {
                discoveryGeneration = UUID()
                MailCapabilityPolicyStore.disconnect()
                MailOutgoingPolicyStore.disconnect()
                ContextShelfStore.shared.removeMailReferences()
                policy = .disabled
                outgoingPolicy = .disabled
                composeSheet = nil
                searchSheet = nil
                accounts = []
                hasDiscoveredAccounts = false
                statusMessage = nil
                automationPermission = .notChecked
            }
        } message: {
            Text("Lima will remove the selected-account policy. This does not change your Apple Mail accounts or macOS Automation permission.")
        }
        .sheet(item: $composeSheet) { sheet in
            MailComposeReviewView(proposal: sheet.proposal)
        }
        .sheet(item: $searchSheet) { sheet in
            MailSearchView(account: sheet.account)
        }
    }

    private var readEnabledBinding: Binding<Bool> {
        Binding(
            get: { policy.readEnabled },
            set: { enabled in
                save(MailCapabilityPolicy(
                    readEnabled: enabled,
                    selectedAccountIDs: policy.selectedAccountIDs,
                    allowsAIRead: enabled && policy.allowsAIRead
                ))
            }
        )
    }

    private var aiReadBinding: Binding<Bool> {
        Binding(
            get: { policy.allowsAIRead },
            set: { enabled in
                save(MailCapabilityPolicy(
                    readEnabled: policy.readEnabled,
                    selectedAccountIDs: policy.selectedAccountIDs,
                    allowsAIRead: enabled && policy.readEnabled
                ))
            }
        )
    }

    private func selectionBinding(for accountID: String) -> Binding<Bool> {
        Binding(
            get: { policy.selectedAccountIDs.contains(accountID) },
            set: { selected in
                var ids = policy.selectedAccountIDs
                if selected {
                    ids.insert(accountID)
                } else {
                    ids.remove(accountID)
                }
                save(MailCapabilityPolicy(
                    readEnabled: policy.readEnabled && !ids.isEmpty,
                    selectedAccountIDs: ids,
                    allowsAIRead: policy.allowsAIRead && policy.readEnabled && !ids.isEmpty
                ))
                if !selected && outgoingPolicy.selectedAccountIDs.contains(accountID) {
                    let remaining = outgoingPolicy.selectedAccountIDs.subtracting([accountID])
                    saveOutgoing(MailOutgoingPolicy(
                        draftEnabled: outgoingPolicy.draftEnabled && !remaining.isEmpty,
                        sendEnabled: outgoingPolicy.sendEnabled && !remaining.isEmpty,
                        selectedAccountIDs: remaining
                    ))
                }
            }
        )
    }

    private var draftEnabledBinding: Binding<Bool> {
        Binding(
            get: { supportedOperations.contains(.createDraft) && outgoingPolicy.draftEnabled },
            set: { enabled in
                saveOutgoing(MailOutgoingPolicy(
                    draftEnabled: enabled,
                    sendEnabled: outgoingPolicy.sendEnabled,
                    selectedAccountIDs: outgoingPolicy.selectedAccountIDs
                ))
            }
        )
    }

    private var sendEnabledBinding: Binding<Bool> {
        Binding(
            get: { supportedOperations.contains(.send) && outgoingPolicy.sendEnabled },
            set: { enabled in
                saveOutgoing(MailOutgoingPolicy(
                    draftEnabled: outgoingPolicy.draftEnabled,
                    sendEnabled: enabled,
                    selectedAccountIDs: outgoingPolicy.selectedAccountIDs
                ))
            }
        )
    }

    private func writingSelectionBinding(for accountID: String) -> Binding<Bool> {
        Binding(
            get: { outgoingPolicy.selectedAccountIDs.contains(accountID) },
            set: { selected in
                var ids = outgoingPolicy.selectedAccountIDs
                if selected { ids.insert(accountID) } else { ids.remove(accountID) }
                saveOutgoing(MailOutgoingPolicy(
                    draftEnabled: outgoingPolicy.draftEnabled && !ids.isEmpty,
                    sendEnabled: outgoingPolicy.sendEnabled && !ids.isEmpty,
                    selectedAccountIDs: ids
                ))
            }
        )
    }

    private func saveOutgoing(_ next: MailOutgoingPolicy) {
        do {
            try MailOutgoingPolicyStore.save(next)
            outgoingPolicy = next
            statusMessage = nil
        } catch {
            statusMessage = "Lima could not save the selected Mail writing accounts."
        }
    }

    private func save(_ next: MailCapabilityPolicy) {
        do {
            try MailCapabilityPolicyStore.save(next)
            let removedAccounts = policy.selectedAccountIDs.subtracting(next.selectedAccountIDs)
            if !next.readEnabled {
                ContextShelfStore.shared.removeMailReferences()
            } else if !removedAccounts.isEmpty {
                ContextShelfStore.shared.removeMailReferences(accountIDs: removedAccounts)
            }
            policy = next
            statusMessage = nil
        } catch {
            statusMessage = "Lima could not save the selected Mail accounts."
        }
    }

    @MainActor
    private func beginCompose(accountID: String) async {
        guard !isOpeningComposer else { return }
        isOpeningComposer = true
        statusMessage = nil
        let generation = discoveryGeneration
        defer { isOpeningComposer = false }
        do {
            let addresses = try await MailCapabilityService.shared.availableSenders(
                accountID: accountID, origin: .userInterface
            )
            guard generation == discoveryGeneration,
                  (outgoingPolicy.sendEnabled || outgoingPolicy.draftEnabled),
                  outgoingPolicy.selectedAccountIDs.contains(accountID) else { return }
            composeSheet = MailComposeSheet(proposal: MailOutgoingRequest(
                kind: .newMessage, accountID: accountID,
                senderAddress: addresses[0], to: [], cc: [], bcc: [],
                subject: "", body: ""
            ))
        } catch {
            if generation == discoveryGeneration { statusMessage = error.localizedDescription }
        }
    }

    @MainActor
    private func refreshAutomationPermission() async {
        let generation = discoveryGeneration
        let processID = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.mail"
        ).first?.processIdentifier
        let result = await Task.detached(priority: .utility) {
            MailAutomationPermissionProbe.status(forPID: processID)
        }.value
        if generation == discoveryGeneration { automationPermission = result }
    }

    @MainActor
    private func discoverAccounts() async {
        guard !isDiscoveringAccounts else { return }
        isDiscoveringAccounts = true
        statusMessage = nil
        let generation = discoveryGeneration
        defer { isDiscoveringAccounts = false }
        do {
            let discovered = try await MailCapabilityService.shared.discoverAccounts(origin: .userInterface)
            guard generation == discoveryGeneration else { return }
            accounts = discovered.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            hasDiscoveredAccounts = true
        } catch is CancellationError {
            if generation == discoveryGeneration { statusMessage = "Account discovery was canceled." }
        } catch let error as MailCapabilityError {
            if generation == discoveryGeneration { statusMessage = error.localizedDescription }
        } catch {
            if generation == discoveryGeneration { statusMessage = "Lima could not discover Apple Mail accounts." }
        }
        await refreshAutomationPermission()
    }
}
