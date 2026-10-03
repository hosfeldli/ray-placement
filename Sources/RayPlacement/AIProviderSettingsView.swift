import SwiftUI

/// Configuration for the existing Workspace conversation, never a second runtime.
@MainActor
struct AIProviderSettingsView: View {
    @ObservedObject var model: AIChatViewModel
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var actionPolicy = AIComputerActionPolicy.shared
    @ObservedObject private var credentials: AIProviderCredentialStore
    @State private var apiKey = ""
    @State private var customModel = ""
    @State private var endpoint = ""
    @State private var message: String?
    @State private var confirmRemove = false
    @State private var confirmBroadBrowserGrants = false

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
                    Text("If Zen or Firefox has already granted https://*/*, Lima can read eligible tabs across HTTPS sites. AI may send selected page context to your configured provider. Private windows and form values remain excluded. Click, type, and submit still require individual approval. Turning this off stops Lima from using the broad grant; revoke the browser permission separately in the companion.")
                }
                Text("Off by default. This switch does not grant browser permission. It allows Lima to use a separately approved https://*/* reading grant; exact-site grants remain the default. Browser navigation and interactions still follow their separate AI action settings.")
                    .font(.caption).foregroundStyle(LimaTheme.textSecondary)
            }
            Section("Computer actions") {
                Text("Off by default. These controls apply only when AI is enabled and the matching tool is selected. Browser site grants, path safeguards, timeouts, output limits, and the Activity journal still apply.")
                    .font(.caption).foregroundStyle(LimaTheme.textSecondary)
                ForEach(AIComputerActionCategory.allCases.filter { $0 != .browserInteraction || actionPolicy.browserInteractionExperimentalEnabled }) { category in
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
                if !actionPolicy.browserInteractionExperimentalEnabled {
                    Text("Browser click, type, and submit are hidden until you enable Browser AI interaction in Advanced → Experimental Features.")
                        .font(.caption).foregroundStyle(LimaTheme.textSecondary)
                }
                Text("Browser navigation can run with the Activity journal when enabled. Browser click, type, and submit, local file creation or replacement, and terminal or code commands always ask before each action. Browser interaction also requires a compatible signed Browser Bridge companion.")
                    .font(.caption).foregroundStyle(LimaTheme.textSecondary)
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
                    ForEach(model.availableModels) { Text($0.displayName).tag($0.id) }
                }
                .disabled(busy)
                TextField("Custom model ID", text: $customModel).disabled(busy)
                if model.provider == .openAICompatible {
                    TextField("Base URL", text: $endpoint).disabled(busy)
                    Text("Use an HTTPS API endpoint, including its base path (for example /v1). HTTP is allowed only for loopback servers. Authentication is optional for compatible servers.")
                        .font(.caption).foregroundStyle(LimaTheme.textSecondary)
                }
                Button("Apply Configuration") {
                    let saved = model.provider == .openAICompatible
                        ? model.configureCompatibleProvider(baseURL: endpoint, modelID: customModel)
                        : model.selectCustomModel(customModel)
                    message = saved ? nil : "Enter a model ID and a valid HTTPS endpoint (or HTTP loopback endpoint), without URL credentials, query, or fragment."
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
            Section("Connection") {
                HStack {
                    Button("Test Connection") { message = nil; model.testConnection() }
                        .disabled(!settings.aiEnabled || busy || !model.hasProviderAPIKey || configurationChanged)
                    Button("Refresh Models") { message = nil; model.refreshModels() }
                        .disabled(!settings.aiEnabled || busy || !model.hasProviderAPIKey || configurationChanged)
                    if model.isLoadingModels {
                        ProgressView().controlSize(.small)
                        Button("Stop") { model.cancelModelDiscovery() }
                    }
                }
                Text("Test Connection checks model discovery, a basic response, and one known-valid function schema. Model discovery runs automatically after saving a key or changing a provider; Refresh Models is for manual retry.")
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
