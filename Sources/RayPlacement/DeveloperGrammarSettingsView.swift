import SwiftUI
import Combine
import RayPlacementWriting

@MainActor
struct DeveloperGrammarSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject private var modelCatalog = AIModelCatalogStore.shared
    @State private var apiKey = ""
    @State private var saveMessage: String?
    @State private var isTesting = false
    @State private var testMessage: String?
    @State private var isTestingCompatibility = false
    @State private var compatibilityMessage: String?
    @State private var isLoadingModels = false
    @State private var discoveredModels: [DeveloperGrammarModelOption] = []
    @State private var modelsMessage: String?

    private var selectedProvider: DeveloperGrammarProvider {
        settings.developerGrammarProvider
    }

    private var modelOptions: [DeveloperGrammarModelOption] {
        var result = modelCatalog.models(for: selectedProvider,
                                         compatibleModelID: settings.developerGrammarModel)
            .map { DeveloperGrammarModelOption(id: $0.id, title: $0.displayName) }
        for model in discoveredModels where !result.contains(where: { $0.id == model.id }) {
            result.append(model)
        }
        return result
    }

    var body: some View {
        Form {
            Section("Grammar Engine") {
                Picker("Correction engine", selection: $settings.grammarEngineMode) {
                    Text("Local").tag(GrammarEngineMode.local)
                    Text("AI provider").tag(GrammarEngineMode.externalAPI)
                }
                .pickerStyle(.segmented)
                Text(settings.grammarEngineMode == .local
                     ? "Local keeps all text on this Mac."
                     : "The selected AI provider receives sanitized text after protected terms are masked. CLI providers use this Mac's existing sign-in and never receive AI Chat tools or history. Failures are reported directly.")
                    .font(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
            }

            Section("Grammar Ensemble") {
                Picker("Strategy", selection: $settings.grammarEnsembleStrategy) {
                    ForEach(GrammarEnsembleStrategy.allCases) { strategy in
                        Text("\(strategy.title) · \(strategy.detail)").tag(strategy)
                    }
                }
                Text("Candidates use fixed Lima diversity seeds and different proofreader profiles. Balanced is the default.")
                    .font(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
                Toggle("Use judge when candidates disagree", isOn: $settings.grammarJudgeOnDisagreement)
                Text("The judge may select only an existing candidate edit or reject the disputed edit; it cannot invent a replacement.")
                    .font(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
            }

            Section("Grammar Debugger") {
                Toggle("Store source text and sanitized context", isOn: $settings.grammarDebugStoreSourceText)
                Text("Off by default. Candidate metadata, prompts, edits, errors, latency, and aggregate analytics are stored locally without source text.")
                    .font(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
                Stepper("Retain runs for \(settings.grammarDebugRetentionDays) days", value: $settings.grammarDebugRetentionDays, in: 1...3650)
                Stepper("Keep at most \(settings.grammarDebugMaximumRuns) runs", value: $settings.grammarDebugMaximumRuns, in: 10...100_000, step: 10)
                Button { NSApp.activate(ignoringOtherApps: true); } label: { Label("Open Grammar Debugger from the launcher", systemImage: "ladybug") }
            }

            Section("Provider and model") {
                Picker("Provider", selection: Binding(
                    get: { settings.developerGrammarProvider },
                    set: { settings.selectDeveloperGrammarProvider($0) }
                )) {
                    ForEach(AIProvider.writingProviders) { provider in
                        Text(provider.title).tag(provider)
                    }
                }

                if modelOptions.isEmpty {
                    TextField("Model identifier", text: $settings.developerGrammarModel)
                        .textFieldStyle(.roundedBorder)
                } else {
                    Picker("Model", selection: Binding(
                    get: { settings.developerGrammarModel },
                    set: { settings.developerGrammarModel = $0 }
                )) {
                        ForEach(modelOptions) { model in
                            Text(model.title).tag(model.id)
                        }
                        if !modelOptions.contains(where: { $0.id == settings.developerGrammarModel }),
                           !settings.developerGrammarModel.isEmpty {
                            Text("Custom: \(settings.developerGrammarModel)").tag(settings.developerGrammarModel)
                        }
                    }

                    TextField("Or enter a custom model identifier", text: $settings.developerGrammarModel)
                        .textFieldStyle(.roundedBorder)
                }

                if selectedProvider.access == .localCLI {
                    let installed = CLIChatProviderClient.executableURL(for: selectedProvider) != nil
                    Label(installed ? "CLI installed" : "CLI not installed",
                          systemImage: installed ? "checkmark.circle.fill" : "exclamationmark.triangle")
                        .foregroundStyle(installed ? .green : .orange)
                    Text("Uses this Mac's existing CLI login. Test Connection verifies authentication and the selected model.")
                        .font(.caption)
                        .foregroundStyle(LimaTheme.textSecondary)
                } else if selectedProvider == .openAICompatible {
                    TextField("Provider Base URL", text: $settings.developerGrammarBaseURL)
                        .textFieldStyle(.roundedBorder)
                } else {
                    DisclosureGroup("Advanced provider settings") {
                        TextField("Provider Base URL", text: $settings.developerGrammarBaseURL)
                            .textFieldStyle(.roundedBorder)
                        Text("Usually no change is needed. Use this only for a custom or OpenAI-compatible endpoint.")
                            .font(.caption)
                            .foregroundStyle(LimaTheme.textSecondary)
                    }
                }
                HStack {
                    Button {
                        loadModels()
                    } label: {
                        if isLoadingModels {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(selectedProvider.access == .localCLI ? "Load CLI models" : "Load models", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(isLoadingModels || settings.developerGrammarConfigurationForModelDiscovery == nil)
                    if let modelsMessage {
                        Text(modelsMessage)
                            .font(.caption)
                            .foregroundStyle(LimaTheme.textSecondary)
                    }
                }
            }

            if selectedProvider.access != .localCLI {
            Section("API key") {
                SecureField("API key · stored securely in Keychain", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save API Key") {
                        do {
                            try settings.saveDeveloperGrammarAPIKey(apiKey)
                            apiKey = ""
                            saveMessage = "Saved to this Mac’s Keychain."
                        } catch {
                            saveMessage = error.localizedDescription
                        }
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Clear Stored Key", role: .destructive) {
                        do {
                            try settings.saveDeveloperGrammarAPIKey("")
                            saveMessage = "Removed from this Mac’s Keychain."
                        } catch {
                            saveMessage = error.localizedDescription
                        }
                    }

                    Spacer()
                    if !settings.developerGrammarAPIKey.isEmpty {
                        Label("Stored securely in Keychain", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                if let saveMessage {
                    Text(saveMessage).font(.caption).foregroundStyle(LimaTheme.textSecondary)
                }
            }
            }

            Section("Test Connection") {
                HStack {
                    Button {
                        testProvider()
                    } label: {
                        if isTesting {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Test Connection", systemImage: "bolt.horizontal.circle")
                        }
                    }
                    .disabled(isTesting || isTestingCompatibility || settings.developerGrammarConfigurationForTesting == nil)
                    if let testMessage {
                        Text(testMessage)
                            .font(.caption)
                            .foregroundStyle(testMessage.hasPrefix("Connected") ? .green : .secondary)
                    }
                }
                Text("Tests the selected provider and model with a minimal request. For CLI providers, it checks this Mac's existing sign-in. It does not proofread text.")
                    .font(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)

                HStack {
                    Button {
                        testExternalGrammar()
                    } label: {
                        if isTestingCompatibility {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Test External Grammar", systemImage: "text.badge.checkmark")
                        }
                    }
                    .disabled(isTesting || isTestingCompatibility || settings.developerGrammarConfigurationForTesting == nil)
                    if let compatibilityMessage {
                        Text(compatibilityMessage)
                            .font(.caption)
                            .foregroundStyle(compatibilityMessage.hasPrefix("Compatible") ? .green : .secondary)
                    }
                }
                Text("Sends a sanitized full-context sample, requests atomic find/replacement edits, and validates protected values without changing your notes.")
                    .font(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
            }
            Section("Available providers") {
                Text("API providers and Codex/Claude CLI are supported. API credentials stay in macOS Keychain; CLI providers use existing local authentication. Grammar never borrows AI Chat tools or conversation history.")
                    .font(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
            }
        }
        .formStyle(.grouped)
        .padding(8)
        .frame(width: 680, height: 650)
        .onAppear {
            apiKey = ""
            discoveredModels = []
            modelsMessage = nil
        }
        .onReceive(settings.$developerGrammarProvider.dropFirst()) { _ in
            discoveredModels = []
            modelsMessage = nil
        }
    }

    private func loadModels() {
        guard let configuration = settings.developerGrammarConfigurationForModelDiscovery else {
            modelsMessage = "Complete the selected provider's required settings first."
            return
        }
        isLoadingModels = true
        modelsMessage = nil
        Task { @MainActor in
            do {
                let models = try await GrammarInferenceClient().models(configuration: configuration)
                discoveredModels = models
                modelsMessage = "Loaded \(models.count) models. Choose one from Model."
            } catch {
                modelsMessage = "Could not load models: \(error.localizedDescription)"
            }
            isLoadingModels = false
        }
    }

    private func testProvider() {
        guard let configuration = settings.developerGrammarConfigurationForTesting else {
            testMessage = "Select a valid model and complete any required provider settings first."
            return
        }
        isTesting = true
        testMessage = nil
        let started = Date()
        Task { @MainActor in
            do {
                try await GrammarInferenceClient().testConnection(configuration: configuration)
                let latency = Int(Date().timeIntervalSince(started) * 1_000)
                testMessage = "Connected · \(configuration.provider.title) · \(configuration.model) · \(latency) ms"
            } catch {
                testMessage = "Failed: \(error.localizedDescription)"
            }
            isTesting = false
        }
    }

    private func testExternalGrammar() {
        guard let configuration = settings.developerGrammarConfigurationForTesting else {
            compatibilityMessage = "Select a valid model and complete any required provider settings first."
            return
        }
        isTestingCompatibility = true
        compatibilityMessage = nil
        let source = ExternalGrammarCompatibility.corpus
        let protected = StealthGrammarService.protect(source, ignoreList: "Lima")
        let started = Date()
        Task { @MainActor in
            do {
                let changes = try await GrammarInferenceClient().correctDocument(
                    protected.contextText, configuration: configuration,
                    systemPrompt: StealthGrammarRemoteClient.systemPrompt,
                    temperature: nil, reasoningEffort: nil
                )
                let latency = Int(Date().timeIntervalSince(started) * 1_000)
                let report = protected.applyingDocumentChanges(changes)
                if ExternalGrammarCompatibility.validate(source: source, protected: protected, report: report) {
                    compatibilityMessage = "Compatible · applied \(report.appliedCount) · rejected \(report.rejectedCount) · \(latency) ms"
                } else {
                    compatibilityMessage = "Failed · the provider did not return safe atomic document changes"
                }
            } catch {
                compatibilityMessage = "Failed: \(error.localizedDescription)"
            }
            isTestingCompatibility = false
        }
    }

}

@MainActor
final class DeveloperGrammarSettingsWindowController: NSWindowController {
    init(settings: SettingsStore) {
        let view = DeveloperGrammarSettingsView(settings: settings)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        LimaWindowChrome.configure(
            window,
            title: "Grammar Engine",
            accessibilityLabel: "Lima grammar engine",
            minSize: NSSize(width: 560, height: 520)
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LimaTypographyRoot(content: view))
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
