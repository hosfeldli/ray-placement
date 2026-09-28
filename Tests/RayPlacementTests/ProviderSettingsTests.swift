import Foundation
import Security
import Testing
@testable import RayPlacement

@Test func settingsSidebarExposesEveryConfigurationSection() {
    #expect(SettingsSection.sidebarSections == SettingsSection.allCases)
    #expect(SettingsSection.sidebarSections.contains(.browser))
    #expect(SettingsSection.sidebarSections.contains(.ai))
    #expect(SettingsSection.ai.matches("compatible endpoint"))
    #expect(SettingsSection.browser.matches("zen"))
}

@Test func providerEndpointsRejectSecretsAndInsecureRemoteTransport() {
    for raw in ["https://example.test/v1", "http://localhost:1234/v1", "http://127.0.0.1:11434/v1", "http://[::1]:1234/v1"] {
        #expect(AIProviderHTTP.validateBaseURL(raw) != nil)
    }
    for raw in ["http://example.test/v1", "http://localhost.evil.test/v1", "https://user:secret@example.test/v1",
                "https://example.test/v1?key=secret", "https://example.test/v1#fragment", "file:///tmp/server",
                "https://exa mple.test/v1", "https://example.test/\npath", String(repeating: "a", count: 4097)] {
        #expect(AIProviderHTTP.validateBaseURL(raw) == nil)
    }
}

@Test @MainActor func failedCredentialMigrationNeverDeletesTheLegacyKey() {
    struct Failure: Error {}
    var removed = false
    AIProviderCredentialStore.migrateLegacyCredential(save: { throw Failure() }, removeLegacy: { removed = true; return errSecSuccess })
    #expect(!removed)
    var saved = false
    AIProviderCredentialStore.migrateLegacyCredential(save: { saved = true }, removeLegacy: {
        #expect(saved)
        removed = true
        return errSecSuccess
    })
    #expect(removed)
}

@MainActor
private func providerSettingsFixture(
    conversations: [AIConversation] = [],
    transport: FixtureAITransport = .standard,
    preferences: AIProviderPreferences? = nil,
    registry: TaskRegistry? = nil,
    modelCatalog: AIModelCatalogStore? = nil
) -> AIChatViewModel {
    AIChatViewModel(
        store: AIConversationStore(fixtures: conversations),
        credentials: AIChatCredentialStore(configuration: .fixture),
        mcpStore: MCPServerStore(fixtures: []),
        nativeToolStore: LimaAIToolStore(fixtures: []),
        transport: transport,
        taskRegistry: registry ?? TaskRegistry(),
        providerPreferences: preferences,
        modelCatalog: modelCatalog
    )
}

@Test @MainActor func savedCustomModelsSurviveRestorationAndDiscovery() async throws {
    let conversation = AIConversation(provider: .openAI, model: "future-private-model", lastResponseID: "prior-response")
    let model = providerSettingsFixture(conversations: [conversation])
    #expect(model.model == "future-private-model")
    #expect(model.availableModels.contains { $0.id == "future-private-model" })
    model.refreshModels()
    for _ in 0..<100 where model.isLoadingModels { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!model.isLoadingModels)
    #expect(model.model == "future-private-model")
    #expect(model.store.conversation(id: conversation.id)?.lastResponseID == "prior-response")
    #expect(model.selectCustomModel("another-private-model"))
    #expect(model.store.conversation(id: conversation.id)?.model == "another-private-model")
    #expect(model.store.conversation(id: conversation.id)?.lastResponseID == nil)
    #expect(!model.selectCustomModel(" \n "))
}

@Test @MainActor func providerModelCatalogPersistsAcrossConversationSwitches() {
    let suite = "dev.liam.lima.tests.model-catalog.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let catalog = AIModelCatalogStore(defaults: defaults, storageKey: "catalog")
    let live = AIModelOption(id: "gpt-6-luna", displayName: "GPT-6 Luna")
    catalog.replace([live], for: .openAI)

    let first = AIConversation(provider: .openAI, model: "gpt-5.4")
    let second = AIConversation(provider: .openAI, model: "gpt-6-luna")
    let model = providerSettingsFixture(conversations: [first, second], modelCatalog: catalog)
    #expect(model.availableModels.contains(live))

    model.select(second.id)
    #expect(model.availableModels.contains(live))

    let restored = AIModelCatalogStore(defaults: defaults, storageKey: "catalog")
    #expect(restored.models(for: .openAI, compatibleModelID: "").contains(live))
}

@Test @MainActor func compatibleConfigurationIsValidatedAndDoesNotRequireAKey() {
    let suite = "dev.liam.lima.tests.provider-settings.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AIProviderPreferences(defaults: defaults)
    let model = providerSettingsFixture(preferences: preferences)
    model.selectProvider(.openAICompatible)
    #expect(model.configureCompatibleProvider(baseURL: "http://localhost:11434/v1/", modelID: "my-local-model"))
    #expect(model.model == "my-local-model")
    #expect(preferences.openAICompatibleBaseURL == "http://localhost:11434/v1")
    #expect(model.credentials.apiKey(for: .openAICompatible) == nil)
    #expect(model.hasProviderAPIKey)
    #expect(!model.configureCompatibleProvider(baseURL: "https://example.test/?token=secret", modelID: "bad"))
    #expect(!model.configureCompatibleProvider(baseURL: "https://example.test/v1", modelID: ""))
    #expect(preferences.openAICompatibleModelID == "my-local-model")
    #expect(AIProviderPreferences(defaults: defaults).openAICompatibleModelID == "my-local-model")
    model.newConversation()
    #expect(model.selectedConversation?.provider == .openAICompatible)
    #expect(model.selectedConversation?.model == "my-local-model")
}

@Test @MainActor func newAndDeletedChatsDoNotLeakDraftsOrAttachments() {
    let attachment = AIAttachment(kind: .selection, displayName: "Fixture", text: "Private fixture")
    let first = AIConversation(provider: .openAI, model: "custom-openai", attachments: [attachment])
    let second = AIConversation(provider: .anthropic, model: "custom-claude")
    let model = providerSettingsFixture(conversations: [first, second])
    #expect(model.attachments == [attachment])
    model.draft = "unsent"
    model.newConversation()
    #expect(model.draft.isEmpty)
    #expect(model.attachments.isEmpty)
    model.select(first.id)
    model.draft = "unsent"
    model.deleteSelectedConversation()
    #expect(model.draft.isEmpty)
    #expect(model.attachments.isEmpty)
    model.select(second.id)
    #expect(model.model == "custom-claude")
    #expect(model.provider == .anthropic)
    model.select(UUID())
    #expect(model.selectedConversationID == second.id)
}

@Test @MainActor func sidebarDeletionPreservesOtherDraftsAndClearsLastSelection() {
    let attachment = AIAttachment(kind: .selection, displayName: "Fixture", text: "Private fixture")
    let first = AIConversation(provider: .openAI, model: "custom", attachments: [attachment])
    let other = AIConversation(provider: .anthropic, model: "other")
    let model = providerSettingsFixture(conversations: [first, other])
    model.select(first.id)
    model.draft = "unsent"
    model.deleteConversation(other.id)
    #expect(model.selectedConversationID == first.id)
    #expect(model.draft == "unsent")
    #expect(model.attachments == [attachment])
    model.deleteConversation(first.id)
    #expect(model.selectedConversationID == nil)
    #expect(model.store.conversations.isEmpty)
    #expect(model.draft.isEmpty)
    #expect(model.attachments.isEmpty)
}

@Test @MainActor func providerCheckRegistersWorkAndStopsOnlyExplicitly() async throws {
    let registry = TaskRegistry()
    var transport = FixtureAITransport.standard
    transport.modelDiscoveryDelay = .seconds(30)
    let conversation = AIConversation(provider: .openAI, model: "custom")
    let other = AIConversation(provider: .openAI, model: "other")
    let model = providerSettingsFixture(conversations: [conversation, other], transport: transport, registry: registry)
    model.testConnection()
    #expect(model.isLoadingModels)
    let task = try #require(registry.activeTasks.first)
    #expect(task.title == "Checking AI provider")
    model.select(other.id) // Navigation does not cancel the check.
    #expect(registry.task(id: task.id)?.state == .running)
    registry.cancel(task.id)
    for _ in 0..<100 where model.isLoadingModels { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!model.isLoadingModels)
    #expect(registry.task(id: task.id)?.state == .cancelled)
    #expect(model.providerConnectionMessage == nil) // No stale status in the other chat.
    #expect(model.model == "other")
}

@Test @MainActor func testConnectionVerifiesTheSelectedModelWithABasicResponse() async throws {
    let conversation = AIConversation(provider: .openAI, model: "gpt-6-luna")
    let model = providerSettingsFixture(conversations: [conversation])
    model.testConnection()
    for _ in 0..<100 where model.isLoadingModels {
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(!model.isLoadingModels)
    #expect(model.providerConnectionMessage?.contains(
        "Verified gpt-6-luna with a basic response request"
    ) == true)
    #expect(model.store.conversation(id: conversation.id)?.messages.isEmpty == true)
}

@Test @MainActor func configurationCannotChangeDuringGeneration() {
    let conversation = AIConversation(provider: .openAI, model: "custom")
    var transport = FixtureAITransport.standard
    transport.interEventDelay = .seconds(30)
    let model = providerSettingsFixture(conversations: [conversation], transport: transport)
    model.draft = "Fixture request"
    model.send()
    #expect(model.canEndTask)
    defer { model.endTask() }
    model.selectProvider(.anthropic)
    model.selectModel(AIModelOption(id: "another"))
    #expect(!model.selectCustomModel("another"))
    model.newConversation()
    model.deleteSelectedConversation()
    model.deleteConversation(conversation.id)
    #expect(model.provider == .openAI)
    #expect(model.model == "custom")
    #expect(model.selectedConversationID == conversation.id)
    #expect(model.store.conversations.count == 1)
}

@Test func writingRequestsUseSharedEndpointAndCredentialPolicy() {
    let client = StealthGrammarRemoteClient()
    var configuration = DeveloperGrammarConfiguration(provider: .openAICompatible, apiKey: "", model: "local", baseURL: "http://127.0.0.1:1234/v1")
    let listing = client.makeModelsRequest(configuration: configuration)
    #expect(listing?.url?.path == "/v1/models")
    #expect(listing?.value(forHTTPHeaderField: "Authorization") == nil)
    let request = client.makeRequest(text: "fixture", configuration: configuration, systemPrompt: "fixture")
    #expect(request?.url?.path == "/v1/chat/completions")
    #expect(request?.value(forHTTPHeaderField: "Authorization") == nil)
    configuration = DeveloperGrammarConfiguration(provider: .gemini, apiKey: "fixture-secret", model: "fixture-model", baseURL: "https://example.test/v1beta")
    for request in [client.makeModelsRequest(configuration: configuration),
                    client.makeRequest(text: "fixture", configuration: configuration, systemPrompt: "fixture")] {
        #expect(request?.url?.query == nil)
        #expect(request?.url?.absoluteString.contains("fixture-secret") == false)
        #expect(request?.value(forHTTPHeaderField: "x-goog-api-key") == "fixture-secret")
    }
    configuration = DeveloperGrammarConfiguration(provider: .openAICompatible, apiKey: "fixture-secret", model: "local", baseURL: "http://example.test/v1")
    #expect(client.makeModelsRequest(configuration: configuration) == nil)
    #expect(client.makeRequest(text: "fixture", configuration: configuration, systemPrompt: "fixture") == nil)
}
