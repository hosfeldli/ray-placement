import Combine
import Foundation
import Security

/// Compatibility-only access to a credential saved by retired public web search.
/// It never reads key material and has no save or network-execution path.
@MainActor
final class LegacyWebSearchCredentialStore: ObservableObject {
    static let shared = LegacyWebSearchCredentialStore()
    static let productionService = "dev.liam.lima.public-web-search"

    private let service: String
    private let account = "brave-search-api-key"

    @Published private(set) var isConfigured = false

    init(service: String? = nil, testMode: Bool = LimaTestEnvironment.isEnabled) {
        self.service = service ?? (testMode ? "dev.liam.lima.test.public-web-search" : Self.productionService)
        refresh()
    }

    func refresh() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        isConfigured = SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func remove() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Lima could not remove the retired web-search API key from Keychain."]
            )
        }
        isConfigured = false
    }
}
