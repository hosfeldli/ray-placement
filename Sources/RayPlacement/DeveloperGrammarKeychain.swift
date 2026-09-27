import Foundation

@MainActor
enum DeveloperGrammarKeychain {
    static func value(for provider: DeveloperGrammarProvider) -> String {
        AIProviderCredentialStore.shared.apiKey(for: provider) ?? ""
    }

    static func set(_ value: String, for provider: DeveloperGrammarProvider) throws {
        let credentials = AIProviderCredentialStore.shared
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try credentials.removeAPIKey(for: provider)
        } else {
            try credentials.saveAPIKey(trimmed, for: provider)
        }
        credentials.refresh()
    }

}
