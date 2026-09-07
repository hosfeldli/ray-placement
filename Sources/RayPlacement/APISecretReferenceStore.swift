import Foundation
import Security
import RayPlacementCore

struct APISecretMaterial: Codable, Sendable {
    var bearerToken: String?
    var apiKey: String?
    var username: String?
    var password: String?

    init(bearerToken: String? = nil, apiKey: String? = nil, username: String? = nil, password: String? = nil) {
        self.bearerToken = bearerToken
        self.apiKey = apiKey
        self.username = username
        self.password = password
    }
}

@MainActor
final class APISecretReferenceStore: ObservableObject {
    static let shared = APISecretReferenceStore()
    @Published private(set) var lastError: String?
    @Published private(set) var references: [APISecretReference]

    private let metadataKey = "apiSecretReferences"
    private let service = "dev.liam.lima.api-secret-reference"

    private init() {
        if let data = UserDefaults.standard.data(forKey: metadataKey),
           let decoded = try? JSONDecoder().decode([APISecretReference].self, from: data) {
            references = decoded
        } else {
            references = []
        }
    }

    func save(_ material: APISecretMaterial, reference: APISecretReference? = nil, name: String, kind: APISecretReference.Kind) throws -> APISecretReference {
        let reference = reference ?? APISecretReference(name: name, kind: kind)
        let data = try JSONEncoder().encode(material)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference.id.uuidString,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let match: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: reference.id.uuidString
            ]
            let update: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(match as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw keychainError(updateStatus) }
        } else if status != errSecSuccess {
            throw keychainError(status)
        }
        if let index = references.firstIndex(where: { $0.id == reference.id }) {
            references[index] = APISecretReference(id: reference.id, name: name, kind: kind, createdAt: references[index].createdAt, updatedAt: Date())
        } else {
            references.append(reference)
        }
        persistMetadata()
        lastError = nil
        return reference
    }

    func resolve(_ reference: APISecretReference) -> APISecretMaterial? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference.id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(APISecretMaterial.self, from: data)
    }

    func delete(_ reference: APISecretReference) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference.id.uuidString
        ]
        _ = SecItemDelete(query as CFDictionary)
        references.removeAll { $0.id == reference.id }
        persistMetadata()
    }

    func rename(_ reference: APISecretReference, name: String) {
        guard let index = references.firstIndex(where: { $0.id == reference.id }), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        references[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        references[index].updatedAt = Date()
        persistMetadata()
    }

    private func persistMetadata() {
        if let data = try? JSONEncoder().encode(references) { UserDefaults.standard.set(data, forKey: metadataKey) }
    }

    private func keychainError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Keychain operation failed (\(status))."])
    }
}
