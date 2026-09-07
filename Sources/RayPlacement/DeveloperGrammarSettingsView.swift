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
            Section("Developer-only BYOK") {
                Toggle("Use a remote grammar provider", isOn: $settings.developerGrammarEnabled)
                Text("This window is available only through the hidden 🤖 launcher command. Stealth Mode sends protected text to the selected provider. URLs, names, acronyms, code-like text, and preserved terms are masked before sending.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Provider and model") {
                Picker("API provider", selection: Binding(
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

                TextField("Base URL", text: $settings.developerGrammarBaseURL)
                    .textFieldStyle(.roundedBorder)
                Text("The base URL is used for custom endpoints and can be adjusted for compatible gateways or local servers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                SecureField("API key (stored in Keychain)", text: $apiKey)
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
                        Label("Key saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                if let saveMessage {
                    Text(saveMessage).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Connection test") {
                HStack {
                    Button {
                        testProvider()
                    } label: {
                        if isTesting {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Test selected model", systemImage: "bolt.horizontal.circle")
                        }
                    }
                    .disabled(isTesting || settings.developerGrammarAPIKey.isEmpty)
                    if let testMessage {
                        Text(testMessage)
                            .font(.caption)
                            .foregroundStyle(testMessage.hasPrefix("Passed") ? .green : .secondary)
                    }
                }
                Text("The test sends a short protected sample and requires the provider to return only corrected text. It does not use the selected text from another application.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Supported providers") {
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
        StealthGrammarRemoteClient().correct(sample, configuration: configuration) { result in
            isTesting = false
            switch result {
            case .success(let value) where value.contains("\u{E000}LIMA_KEEP_0000_\u{E001}"):
                testMessage = "Passed: protected token preserved."
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
        window.title = "Developer Grammar"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
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
