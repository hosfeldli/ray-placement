import Combine
import Foundation
import Security

public enum LimaSecretKind: String, Codable, CaseIterable, Sendable {
    case localSecret
    case environmentValue

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = value == "environmentValue" ? .environmentValue : .localSecret
    }

    public var title: String {
        switch self {
        case .localSecret: return "Local secret"
        case .environmentValue: return "Environment value"
        }
    }
}

public struct LimaSecretReference: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: LimaSecretKind
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, kind: LimaSecretKind, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@MainActor
final class LimaSecretStore: ObservableObject {
    static let shared = LimaSecretStore()
    @Published private(set) var references: [LimaSecretReference]

    private let metadataKey = "lima.secretReferences"
    private let service = "dev.liam.lima.secrets"

    private init() {
        references = (try? JSONDecoder().decode([LimaSecretReference].self, from: UserDefaults.standard.data(forKey: metadataKey) ?? Data())) ?? []
    }

    @discardableResult
    func save(_ value: String, name: String, kind: LimaSecretKind, id: UUID? = nil) throws -> LimaSecretReference {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw NSError(domain: "LimaSecrets", code: 1, userInfo: [NSLocalizedDescriptionKey: "A secret name is required."]) }
        let reference = id.flatMap({ existing in references.first(where: { $0.id == existing }) }).map {
            LimaSecretReference(id: $0.id, name: cleanName, kind: kind, createdAt: $0.createdAt, updatedAt: Date())
        } ?? LimaSecretReference(id: id ?? UUID(), name: cleanName, kind: kind)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference.id.uuidString,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: reference.id.uuidString]
            guard SecItemUpdate(match as CFDictionary, [kSecValueData as String: Data(value.utf8)] as CFDictionary) == errSecSuccess else { throw keychainError() }
        } else if status != errSecSuccess { throw keychainError() }
        references.removeAll { $0.id == reference.id }
        references.append(reference)
        persist()
        return reference
    }

    func reference(id: UUID) -> LimaSecretReference? {
        references.first { $0.id == id }
    }

    func resolve(id: UUID) -> String? {
        guard let reference = reference(id: id) else { return nil }
        return resolve(reference)
    }

    func resolve(_ reference: LimaSecretReference) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: reference.id.uuidString, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func reference(named name: String) -> LimaSecretReference? {
        references.first { $0.name == name }
    }

    func resolve(named name: String) -> String? {
        guard let reference = reference(named: name) else { return nil }
        return resolve(reference)
    }

    func delete(_ reference: LimaSecretReference) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: reference.id.uuidString]
        SecItemDelete(query as CFDictionary)
        references.removeAll { $0.id == reference.id }
        persist()
    }

    func rename(_ reference: LimaSecretReference, name: String) {
        guard let index = references.firstIndex(where: { $0.id == reference.id }) else { return }
        references[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        references[index].updatedAt = Date()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(references) else { return }
        UserDefaults.standard.set(data, forKey: metadataKey)
    }

    private func keychainError() -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(errSecAuthFailed), userInfo: [NSLocalizedDescriptionKey: "Could not access Lima's Keychain secrets."])
    }
}

@MainActor
enum LimaSecretInterpolation {
    static func resolve(_ input: String) -> String {
        var result = input
        for _ in 0..<5 {
            guard let regex = try? NSRegularExpression(pattern: #"\{\{secret\.([A-Za-z0-9._-]+)\}\}"#) else { return result }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            let matches = regex.matches(in: result, range: range).reversed()
            var changed = false
            for match in matches {
                guard let whole = Range(match.range(at: 0), in: result), let nameRange = Range(match.range(at: 1), in: result), let value = LimaSecretStore.shared.resolve(named: String(result[nameRange])) else { continue }
                result.replaceSubrange(whole, with: value)
                changed = true
            }
            if !changed { break }
        }
        return result
    }
}
