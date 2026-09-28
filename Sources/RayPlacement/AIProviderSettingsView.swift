import SwiftUI

/// Configuration for the existing Workspace conversation, never a second runtime.
@MainActor
struct AIProviderSettingsView: View {
    @ObservedObject var model: AIChatViewModel
    @ObservedObject private var credentials: AIProviderCredentialStore
    @State private var apiKey = ""
    @State private var customModel = ""
    @State private var endpoint = ""
    @State private var message: String?
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
                        .disabled(busy || !model.hasProviderAPIKey || configurationChanged)
                    Button("Refresh Models") { message = nil; model.refreshModels() }
                        .disabled(busy || !model.hasProviderAPIKey || configurationChanged)
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
