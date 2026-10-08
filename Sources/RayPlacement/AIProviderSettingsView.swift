import SwiftUI

/// Configuration for the existing Workspace conversation, never a second runtime.
@MainActor
struct AIProviderSettingsView: View {
    @ObservedObject var model: AIChatViewModel
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var actionPolicy = AIComputerActionPolicy.shared
    @ObservedObject private var toolStore = LimaAIToolStore.shared
    @ObservedObject private var credentials: AIProviderCredentialStore
    @ObservedObject private var webSearchCredentials = PublicWebSearchCredentialStore.shared
    @ObservedObject private var mcpServers = MCPServerStore.shared
    @State private var apiKey = ""
    @State private var webSearchAPIKey = ""
    @State private var webSearchMessage: String?
    @State private var customModel = ""
    @State private var endpoint = ""
    @State private var message: String?
    @State private var confirmRemove = false
    @State private var confirmBroadBrowserGrants = false
    @State private var confirmInteractionJournal = false

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
                Text("Changing modes does not erase existing tool selections or enable a disabled computer-action category. Browser site grants and required approvals remain in effect.")
                    .font(.caption).foregroundStyle(LimaTheme.textSecondary)
            }
            Section("General web search") {
                Text("Configure Brave Search for public web queries. Search terms are sent to Brave when the AI web-search tool runs. This key is stored separately in macOS Keychain and is never shown in Lima.")
                    .font(.caption).foregroundStyle(LimaTheme.textSecondary)
                SecureField(webSearchCredentials.isConfigured ? "Replacement Brave Search API key" : "Brave Search API key",
                            text: $webSearchAPIKey)
                HStack {
                    Button("Save Key") {
                        do {
                            try webSearchCredentials.save(webSearchAPIKey)
                            webSearchAPIKey = ""
                            webSearchMessage = nil
                        } catch {
                            webSearchMessage = error.localizedDescription
                        }
                    }
                    .disabled(webSearchAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Remove Key", role: .destructive) {
                        do {
                            try webSearchCredentials.remove()
                            webSearchAPIKey = ""
                            webSearchMessage = nil
                        } catch {
                            webSearchMessage = error.localizedDescription
                        }
                    }
                    .disabled(!webSearchCredentials.isConfigured)
                    Spacer()
                    Label(webSearchCredentials.isConfigured ? "Stored in Keychain" : "Not configured",
                          systemImage: webSearchCredentials.isConfigured ? "checkmark.circle.fill" : "magnifyingglass")
                        .font(.caption).foregroundStyle(LimaTheme.textSecondary)
                }
                if let webSearchMessage {
                    Text(webSearchMessage).font(.caption).foregroundStyle(LimaTheme.textSecondary)
                }
                Text("Available when Tool Access permits web research. If no valid provider key is configured, Lima reports the provider as unavailable rather than claiming there were zero results. Alternatively, Browser Search can open a Google results tab if Browser navigation is enabled and that site has a Browser Bridge grant.")
                    .font(.caption).foregroundStyle(LimaTheme.textSecondary)
            }
            Section("Connected tools (MCP)") {
                let enabledServers = mcpServers.servers.filter(\.enabled)
                let enabledToolCount = enabledServers.reduce(0) { $0 + $1.enabledTools.count }
                Text("Connect Lima to a local or network MCP server using its reachable HTTP endpoint. Enable individual tools in the MCP manager; only tools freshly declared read-only are available to AI Chat. Server credentials stay in Keychain.")
                    .font(.caption).foregroundStyle(LimaTheme.textSecondary)
                HStack {
                    Text("\(enabledServers.count) enabled MCP servers · \(enabledToolCount) read-only tools")
                        .font(.caption).foregroundStyle(LimaTheme.textSecondary)
                    Spacer()
                    Button("Manage MCP Servers") { model.openMCPManager() }
                        .accessibilityIdentifier(LimaQAIdentifiers.Settings.mcpServers)
                }
                Text("Use an HTTPS endpoint for bearer authentication. Plain HTTP is unencrypted; use it only on a trusted isolated test network without sending reusable credentials. The QA control service remains a local Unix socket and is not a LAN listener.")
                    .font(.caption).foregroundStyle(LimaTheme.textSecondary)
            }
            Section("Experimental browser access") {
                Toggle("Allow broad HTTPS browser grants", isOn: Binding(
                    get: { actionPolicy.broadBrowserGrantsExperimentalEnabled },
                    set: { enabled in
                        if enabled { confirmBroadBrowserGrants = true }
                        else { actionPolicy.setBroadBrowserGrantsExperimentalEnabled(false) }
                    }
                ))
                .alert("Use a broad HTTPS browser grant?", isPresented: $confirmBroadBrowserGrants) {
                    Button("Cancel", role: .cancel) {}
                    Button("Enable Experiment") { actionPolicy.setBroadBrowserGrantsExperimentalEnabled(true) }
                } message: {
                    Text("If Zen or Firefox has already granted https://*/*, Lima can read eligible tabs across HTTPS sites. AI may send selected page context to your configured provider. Private windows and form values remain excluded. This switch does not grant browser interactions; those need a separate exact-site grant and AI action setting. Revoke the browser permission separately in the companion.")
                }
                Text("Off by default. This switch does not grant browser permission. It allows Lima to use a separately approved https://*/* reading grant; exact-site grants remain the default. Browser navigation and interactions still follow their separate AI action settings.")
                    .font(.caption).foregroundStyle(LimaTheme.textSecondary)
            }
            Section("Computer actions") {
                Text("Off by default. To let AI run builds and tests, set Terminal and code to Ask every time; Automatic Tool Access will then expose the command tool without an extra tool toggle. Browser Search requires Browser navigation plus a grant for the search site. Path safeguards, timeouts, output limits, approvals, and the Activity journal still apply.")
                    .font(.caption).foregroundStyle(LimaTheme.textSecondary)
                ForEach(AIComputerActionCategory.allCases.filter { $0 != .browserInteraction || actionPolicy.browserInteractionExperimentalEnabled }) { category in
                    Picker(category.title, selection: Binding(
                        get: { actionPolicy.access(for: category) },
                        set: { access in
                            if category == .browserInteraction && access == .allowWithJournal {
                                confirmInteractionJournal = true
                            } else {
                                actionPolicy.setAccess(access, for: category)
                            }
                        }
                    )) {
                        ForEach(category.supportedAccesses) { access in
                            Text(access.title).tag(access)
                        }
                    }
                    Text(category.summary)
                        .font(.caption).foregroundStyle(LimaTheme.textSecondary)
                }
                if !actionPolicy.browserInteractionExperimentalEnabled {
                    Text("Browser click, type, and submit are hidden until you enable Browser AI interaction in Advanced → Experimental Features.")
                        .font(.caption).foregroundStyle(LimaTheme.textSecondary)
                }
                Text("Browser navigation, click, and type can run without repeated Lima prompts only when their category is set to Allow with journal. Click and type still need an exact-site interaction grant in the companion. Form submission, local file writes, and terminal or code commands always ask. Browser interaction requires a compatible signed companion.")
                    .font(.caption).foregroundStyle(LimaTheme.textSecondary)
                    .alert("Allow browser clicks and typing without repeated Lima prompts?", isPresented: $confirmInteractionJournal) {
                        Button("Cancel", role: .cancel) {}
                        Button("Allow with Journal") { actionPolicy.setAccess(.allowWithJournal, for: .browserInteraction) }
                    } message: {
                        Text("On sites where you separately enabled Always allow interactions in Zen or Firefox, Lima may click or type requested content without another prompt. Each action is recorded in Activity. Form submission still asks in Lima, and you can return to Ask every time or Off here.")
                    }
                Text("Approved build, test, or script commands run project code as your macOS user, not in a security sandbox. Review the full command and project before allowing it; a timeout may not stop child processes started by that code.")
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
                Text(model.provider.isCLI
                    ? "Shows the CLI default and model IDs that passed a connection test in the last 30 days. The current model stays visible even if it has not been tested."
                    : "Shows recent models from the provider’s model list. The current custom or older model stays visible until you change it.")
                    .font(.caption).foregroundStyle(LimaTheme.textSecondary)
                TextField("Custom model ID", text: $customModel).disabled(busy)
                if model.provider.isCLI {
                    Text("Uses your local CLI sign-in. Enabled Lima tools, including Browser and Notes, run through Lima’s normal grants and approvals. Enabled read-only connected-service MCP tools are discovered and executed by Lima; service credentials are never passed to the CLI. Codex CLI accepts explicitly attached images; Claude CLI remains text-only. ‘CLI default’ lets the CLI choose a model.")
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
            Section("Connection") {
                HStack {
                    Button("Test Connection") { message = nil; model.testConnection() }
                        .disabled(!settings.aiEnabled || busy || !model.hasProviderAPIKey || configurationChanged)
                    if !model.provider.isCLI {
                        Button("Refresh Models") { message = nil; model.refreshModels() }
                            .disabled(!settings.aiEnabled || busy || !model.hasProviderAPIKey || configurationChanged)
                    }
                    if model.isLoadingModels {
                        ProgressView().controlSize(.small)
                        Button("Stop") { model.cancelModelDiscovery() }
                    }
                }
                Text(model.provider.isCLI
                    ? "Test Connection sends a short text prompt through the installed CLI and verifies its local sign-in and selected model. It does not test Lima tools. CLI model discovery is unavailable; use CLI default or enter a model ID. Successfully tested IDs stay in the picker for 30 days."
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
        .onDisappear { apiKey = ""; webSearchAPIKey = "" } // Navigation never cancels provider checks.
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
