import SwiftUI
import Combine

@MainActor
struct DeveloperGrammarSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @State private var apiKey = ""
    @State private var saveMessage: String?
    @State private var isTesting = false
    @State private var testMessage: String?
    @State private var isLoadingModels = false
    @State private var discoveredModels: [DeveloperGrammarModelOption] = []
    @State private var modelsMessage: String?

    private var selectedProvider: DeveloperGrammarProvider {
        settings.developerGrammarProvider
    }

    private var modelOptions: [DeveloperGrammarModelOption] {
        var result = selectedProvider.modelOptions
        for model in discoveredModels where !result.contains(where: { $0.id == model.id }) {
            result.append(model)
        }
        return result
    }

    var body: some View {
        Form {
            Section("Grammar Engine") {
                Toggle("Use Enhanced Grammar", isOn: $settings.developerGrammarEnabled)
                Text("Local keeps all text on this Mac. Enhanced sends the text being checked to your selected provider after URLs, names, acronyms, code-like text, and preserved terms are protected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Fall back to Local", isOn: $settings.grammarFallbackToLocal)
                Text("If Enhanced is unavailable, Lima keeps the local result and shows a quiet status instead of replacing text with an unsafe response.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Provider and model") {
                Picker("Provider", selection: Binding(
                    get: { settings.developerGrammarProvider },
                    set: { settings.selectDeveloperGrammarProvider($0) }
                )) {
                    ForEach(DeveloperGrammarProvider.allCases) { provider in
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

                if selectedProvider == .openAICompatible {
                    TextField("Provider Base URL", text: $settings.developerGrammarBaseURL)
                        .textFieldStyle(.roundedBorder)
                } else {
                    DisclosureGroup("Advanced provider settings") {
                        TextField("Provider Base URL", text: $settings.developerGrammarBaseURL)
                            .textFieldStyle(.roundedBorder)
                        Text("Usually no change is needed. Use this only for a custom or OpenAI-compatible endpoint.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button {
                        loadModels()
                    } label: {
                        if isLoadingModels {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Load models using saved key", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(isLoadingModels || settings.developerGrammarAPIKey.isEmpty)
                    if let modelsMessage {
                        Text(modelsMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

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
                    Text(saveMessage).font(.caption).foregroundStyle(.secondary)
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
                    .disabled(isTesting || settings.developerGrammarAPIKey.isEmpty)
                    if let testMessage {
                        Text(testMessage)
                            .font(.caption)
                            .foregroundStyle(testMessage.hasPrefix("Connected") ? .green : .secondary)
                    }
                }
                Text("The test sends a short protected sample and reports whether the provider returns a safe proofreading response.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Available providers") {
                Text("OpenAI, Anthropic, Google Gemini, Mistral, xAI, DeepSeek, OpenRouter, and generic OpenAI-compatible endpoints are supported. Credentials are stored in macOS Keychain and are not written to UserDefaults, logs, usage records, or the source tree.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            modelsMessage = "Save a key and base URL first."
            return
        }
        isLoadingModels = true
        modelsMessage = nil
        StealthGrammarRemoteClient().fetchModels(configuration: configuration) { result in
            isLoadingModels = false
            switch result {
            case .success(let models):
                discoveredModels = models
                modelsMessage = "Loaded \(models.count) text models. Choose one from Model."
            case .failure(let error):
                modelsMessage = "Could not load models: \(error.localizedDescription)"
            }
        }
    }

    private func testProvider() {
        guard let configuration = settings.developerGrammarConfigurationForTesting else {
            testMessage = "Save a key, model, and base URL first."
            return
        }
        isTesting = true
        testMessage = nil
        let sample = "This are a grammer sentence with \u{E000}LIMA_KEEP_0000_\u{E001}."
        let started = Date()
        StealthGrammarRemoteClient().correct(sample, configuration: configuration) { result in
            let latency = Int(Date().timeIntervalSince(started) * 1_000)
            isTesting = false
            switch result {
            case .success(let value) where value.contains("\u{E000}LIMA_KEEP_0000_\u{E001}"):
                testMessage = "Connected · \(selectedProvider.title) · \(settings.developerGrammarModel) · \(latency) ms"
            case .success:
                testMessage = "Failed: the provider changed the protected token."
            case .failure(let error):
                testMessage = "Failed: \(error.localizedDescription)"
            }
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
