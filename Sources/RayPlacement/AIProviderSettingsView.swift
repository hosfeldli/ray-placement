import SwiftUI

/// Configuration for the existing Workspace conversation, never a second runtime.
@MainActor
struct AIProviderSettingsView: View {
    @ObservedObject var model: AIChatViewModel
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var actionPolicy = AIComputerActionPolicy.shared
    @ObservedObject private var toolStore = LimaAIToolStore.shared
    @ObservedObject private var browser = BrowserWorkspaceModel.shared
    @ObservedObject private var terminal = AIWorkspaceTerminalCoordinator.shared
    @ObservedObject private var workbench = AIWorkbenchSelfTest.shared
    @ObservedObject private var credentials: AIProviderCredentialStore
    @ObservedObject private var legacyWebSearchCredentials = LegacyWebSearchCredentialStore.shared
    @State private var apiKey = ""
    @State private var customModel = ""
    @State private var endpoint = ""
    @State private var message: String?
    @State private var webSearchRemovalMessage: String?
    @State private var confirmRemove = false

    init(model: AIChatViewModel) {
        self.model = model
        self.credentials = model.credentials
    }

    private var busy: Bool { model.canEndTask || model.isLoadingModels }
    private var configurationChanged: Bool {
        customModel.trimmingCharacters(in: .whitespacesAndNewlines) != model.model ||
        (model.provider == .openAICompatible && endpoint != model.providerPreferences.openAICompatibleBaseURL)
    }

    var body: some View {
        Form {
            Section("AI availability") {
                Toggle("Enable AI throughout Lima", isOn: $settings.aiEnabled)
                Text("Turning this off stops AI chats, provider requests, AI tools, and grammar assistance. Local dictation, search, files, notes, and saved chats remain available. Keys, model preferences, and action choices are retained.")
                    .font(.caption).foregroundStyle(LimaTheme.textSecondary)
            }
            Section("Tool Access") {
                Picker("Mode", selection: Binding(
                    get: { toolStore.accessMode },
                    set: { toolStore.setAccessMode($0) }
                )) {
                    ForEach(LimaAIToolAccessMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Text(toolStore.accessMode.detail)
                    .font(.caption).foregroundStyle(LimaTheme.textSecondary)
                Text(toolStore.accessMode == .fullControl
                    ? "Full Control exposes implemented Lima tools and skips ordinary per-action prompts. Final Browser actions and visual clicks still require exact-call review. Saved category choices return when you leave this mode. Browser AI Control, macOS permissions, sandbox boundaries, and execution limits still apply."
                    : "Changing modes does not erase existing tool selections. Outside Full Control, disabled computer-action categories remain unavailable and required Lima prompts remain in effect.")
                    .font(.caption).foregroundStyle(LimaTheme.textSecondary)
            }
            Section("Agent execution") {
                Picker("Maximum simultaneous agents", selection: $settings.aiMaximumConcurrentSubagents) {
                    ForEach(1...AIExecutionSubagentBudget.maximumConcurrentCeiling, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                Text("Applies to new AI runs; each run captures its simultaneous-agent limit. Sequential child requests have no total quota. Recursive delegation stays disabled.")
                    .font(.caption).foregroundStyle(LimaTheme.textSecondary)
            }
            Section("Browser research") {
                Text("AI research uses Lima's embedded Browser tabs. Browser AI Control determines whether AI can read, navigate, and interact; the page remains visible to you. Lima does not use a background web-search provider or fetch pages outside its Browser.")
                    .font(.caption).foregroundStyle(LimaTheme.textSecondary)
                if legacyWebSearchCredentials.isConfigured {
                    Text("A Brave Search key saved for the retired tool remains in Keychain. Lima no longer uses it.")
                        .font(.caption).foregroundStyle(LimaTheme.textSecondary)
                    Button("Remove Saved Brave Key", role: .destructive) {
                        do {
                            try legacyWebSearchCredentials.remove()
                            webSearchRemovalMessage = nil
                        } catch {
                            webSearchRemovalMessage = error.localizedDescription
                        }
                    }
                }
                if let webSearchRemovalMessage {
                    Text(webSearchRemovalMessage).font(.caption).foregroundStyle(LimaTheme.textSecondary)
                }
            }
            Section("Computer actions") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Outside Full Control, Terminal and code start Off. AI Workspace sessions remain sandboxed without network or unrelated home access in every mode.", systemImage: "terminal")
                    Label("Outside Full Control, saved memory starts at Ask every time. Full Control can save stable user-supplied context without a Lima prompt.", systemImage: "brain.head.profile")
                    Label("Browser AI access is controlled separately in Browser settings and the Browser toolbar.", systemImage: "globe")
                }
                .font(.caption)
                .foregroundStyle(LimaTheme.textSecondary)
                ForEach(AIComputerActionCategory.allCases) { category in
                    if toolStore.accessMode == .fullControl {
                        HStack {
                            Text(category.title)
                            Spacer()
                            Label("Included", systemImage: "checkmark.circle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(LimaTheme.success)
                        }
                        Text("\(category.summary). Saved setting: \(actionPolicy.access(for: category).title) resumes when you leave Full Control.")
                            .font(.caption).foregroundStyle(LimaTheme.textSecondary)
                    } else {
                        Picker(category.title, selection: Binding(
                            get: { actionPolicy.access(for: category) },
                            set: { actionPolicy.setAccess($0, for: category) }
                        )) {
                            ForEach(category.supportedAccesses) { access in
                                Text(access.title).tag(access)
                            }
                        }
                        Text(category.summary)
                            .font(.caption).foregroundStyle(LimaTheme.textSecondary)
                    }
                }
                Text("Full Control makes implemented computer action tools available without ordinary Lima prompts. Final Browser actions and visual clicks still require exact-call review; Browser AI Control and sensitive-field protections remain separate. Outside Full Control, the category choices above govern other computer actions.")
                    .font(.caption).foregroundStyle(LimaTheme.textSecondary)
                Text("All AI terminal commands appear in Terminal. AI Workspace commands use a no-network macOS sandbox with writes confined to the session's current working directory and unrelated home reads denied. Outside Full Control, Allow in Directory can cover one session until revoked or its directory changes. Full Control skips Lima prompts, including for the older unsandboxed Run Terminal Command compatibility tool. A timeout may not stop child processes started by code.")
                    .font(.caption).foregroundStyle(LimaTheme.textSecondary)
            }
            Section("Conversation configuration") {
                Text("Changes apply to the selected Workspace conversation and new conversations created from it. Writing and agents keep their own model selections.")
                    .font(.caption).foregroundStyle(LimaTheme.textSecondary)
                Picker("Provider", selection: Binding(get: { model.provider }, set: { model.selectProvider($0) })) {
                    ForEach(AIProvider.chatProviders) { Text($0.title).tag($0) }
                }
                .disabled(busy)
                Picker("Model", selection: Binding(get: { model.model }, set: { id in
                    if let option = model.availableModels.first(where: { $0.id == id }) { model.selectModel(option) }
                })) {
                    ForEach(model.pickerModels) { Text($0.displayName).tag($0.id) }
                }
                .disabled(busy)
                Text(model.provider == .codexCLI
                    ? "Models come from your installed Codex app-server catalog. Listed models are not guaranteed to be available for your account; a successful request verifies access. Your selection stays visible and is never silently reset."
                    : model.provider.isCLI
                        ? "Shows the CLI default and model IDs that passed a connection test in the last 30 days. The current model stays visible even if it has not been tested."
                        : "Shows recent models from the provider’s model list. The current custom or older model stays visible until you change it.")
                    .font(.caption).foregroundStyle(LimaTheme.textSecondary)
                TextField("Custom model ID", text: $customModel).disabled(busy)
                if model.provider.isCLI {
                    Text("Uses your local CLI sign-in. Lima tools follow the active Tool Access mode; embedded Browser actions also follow Browser AI Control. Full Control skips ordinary Lima computer-action prompts, not exact-call final Browser or visual-click reviews. Codex CLI accepts explicitly attached images; Claude CLI remains text-only. ‘CLI default’ lets the CLI choose a model.")
                        .font(.caption).foregroundStyle(LimaTheme.textSecondary)
                }
                if model.provider == .openAICompatible {
                    TextField("Base URL", text: $endpoint).disabled(busy)
                    Text("Use an HTTPS API endpoint, including its base path (for example /v1). HTTP is allowed only for loopback servers. Authentication is optional for compatible servers.")
                        .font(.caption).foregroundStyle(LimaTheme.textSecondary)
                }
                Button("Apply Configuration") {
                    let saved = model.provider == .openAICompatible
                        ? model.configureCompatibleProvider(baseURL: endpoint, modelID: customModel)
                        : model.selectCustomModel(customModel)
                    message = saved ? nil : (model.provider.isCLI
                        ? "Enter a CLI model ID of at most 128 letters, digits, periods, underscores, colons, slashes, or hyphens; it cannot start with a hyphen."
                        : "Enter a model ID and a valid HTTPS endpoint (or HTTP loopback endpoint), without URL credentials, query, or fragment.")
                    if saved { loadConfiguration() }
                }
                .disabled(busy || !configurationChanged)
                if !model.supportedReasoningEfforts.isEmpty {
                    Picker("Reasoning", selection: Binding(get: { model.reasoningEffort }, set: { model.selectReasoningEffort($0) })) {
                        ForEach(model.supportedReasoningEfforts, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .disabled(busy)
                }
                if model.canEndTask {
                    Text("Stop the active AI task before changing its configuration.")
                        .font(.caption).foregroundStyle(LimaTheme.textSecondary)
                }
            }
            if !model.provider.isCLI {
            Section("Provider credentials") {
                SecureField(credentials.hasAPIKey(for: model.provider) ? "Replacement API key" : "API key", text: $apiKey)
                    .disabled(busy)
                HStack {
                    Button("Save Key") {
                        do {
                            try credentials.saveAPIKey(apiKey, for: model.provider)
                            apiKey = ""
                            message = nil
                            model.credentialsDidChange()
                        } catch { message = error.localizedDescription }
                    }
                    .disabled(busy || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Remove Key", role: .destructive) { confirmRemove = true }
                        .disabled(busy || !credentials.hasAPIKey(for: model.provider))
                    Spacer()
                    Text(credentials.hasAPIKey(for: model.provider) ? "Stored in Keychain" : "No stored key")
                        .font(.caption).foregroundStyle(LimaTheme.textSecondary)
                }
                Text("Keys are shared by provider across AI Chat and Writing. Removing a key affects both; endpoints and model selections remain separate.")
                    .font(.caption).foregroundStyle(LimaTheme.textSecondary)
            }
            }
            Section("AI Workbench Diagnostics") {
                LabeledContent("Provider", value: model.provider.title)
                LabeledContent("Tools exposed", value: AIToolRuntime.shared.exposedDefinitions(store: toolStore).count.formatted())
                LabeledContent("Browser", value: "\(browser.aiControlMode.rawValue) · \(browser.tabs.count) tabs")
                LabeledContent("Terminal", value: "\(terminal.sessions.count) sessions")
                LabeledContent("Recent tool failures", value: AIToolRuntime.shared.recentExecutions.filter { $0.state == .failed }.count.formatted())
                Text("The self-test uses isolated, local Browser, PTY, and file fixtures. Its provider bridge check sends a short request to the selected model and asks it to call lima_capabilities; it does not modify the current conversation.")
                    .font(.caption).foregroundStyle(LimaTheme.textSecondary)
                HStack {
                    Button("Run Self Test") {
                        Task {
                            await workbench.run(provider: model.provider, model: model.model,
                                                endpoint: model.providerPreferences.openAICompatibleBaseURL)
                        }
                    }
                    .disabled(workbench.isRunning || busy || !settings.aiEnabled || configurationChanged)
                    if workbench.isRunning { ProgressView().controlSize(.small) }
                }
                ForEach(workbench.checks) { check in
                    Label("\(check.title): \(check.detail)",
                          systemImage: check.state == .passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(check.state == .passed ? LimaTheme.success : LimaTheme.warning)
                        .font(.caption)
                }
                if workbench.lastRunAt != nil {
                    Text(workbench.passed ? "All Workbench checks passed." : "Workbench checks did not all pass; do not release this build.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(workbench.passed ? LimaTheme.success : LimaTheme.warning)
                }
            }
            Section("Connection") {
                HStack {
                    Button("Test Connection") { message = nil; model.testConnection() }
                        .disabled(!settings.aiEnabled || busy || !model.hasProviderAPIKey || configurationChanged)
                    if !model.provider.isCLI || model.provider == .codexCLI {
                        Button("Refresh Models") { message = nil; model.refreshModels() }
                            .disabled(!settings.aiEnabled || busy || !model.hasProviderAPIKey || configurationChanged)
                    }
                    if model.isLoadingModels {
                        ProgressView().controlSize(.small)
                        Button("Stop") { model.cancelModelDiscovery() }
                    }
                }
                Text(model.provider == .codexCLI
                    ? "Codex models load from the installed app-server and refresh automatically when the catalog is older than 24 hours. Refresh Models only updates the catalog; Test Connection sends a short request to verify your sign-in and selected model."
                    : model.provider.isCLI
                        ? "Test Connection sends a short text prompt through the installed CLI and verifies its local sign-in and selected model. It does not test Lima tools. Use CLI default or enter a model ID."
                        : "Test Connection checks model discovery, a basic response, and one known-valid function schema. Model discovery runs automatically after saving a key or changing a provider; Refresh Models is for manual retry.")
                    .font(.caption).foregroundStyle(LimaTheme.textSecondary)
                if let status = message ?? model.providerConnectionMessage {
                    Text(status).font(.caption).foregroundStyle(LimaTheme.textSecondary).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .controlSize(.small)
        .onAppear { loadConfiguration() }
        .onChange(of: model.provider) { _ in apiKey = ""; message = nil; loadConfiguration() }
        .onChange(of: model.model) { _ in loadConfiguration() }
        .onChange(of: model.selectedConversationID) { _ in apiKey = ""; message = nil; loadConfiguration() }
        .onDisappear { apiKey = "" } // Navigation never cancels provider checks.
        .alert("Remove shared provider key?", isPresented: $confirmRemove) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                guard !busy else { return }
                do { try credentials.removeAPIKey(for: model.provider); apiKey = ""; message = nil }
                catch { message = error.localizedDescription }
            }
        } message: {
            Text("AI Chat and Writing will no longer have this provider credential.")
        }
    }

    private func loadConfiguration() {
        customModel = model.model
        endpoint = model.providerPreferences.openAICompatibleBaseURL
    }
}
