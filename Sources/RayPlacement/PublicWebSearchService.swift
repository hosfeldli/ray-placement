import Combine
import Foundation
import Security

struct PublicWebSearchResult: Equatable, Sendable {
    let title: String
    let url: String
    let snippet: String
}

enum PublicWebSearchStatus: String, Sendable {
    case results
    case noResults = "no_results"
    case providerUnavailable = "provider_unavailable"
    case requestFailed = "request_failed"
    case unsupportedResponse = "unsupported_response"
}

struct PublicWebSearchResponse: Equatable, Sendable {
    let query: String
    let status: PublicWebSearchStatus
    let source: String?
    let results: [PublicWebSearchResult]
    let message: String?

    var json: [String: Any] {
        var value: [String: Any] = [
            "query": query,
            "status": status.rawValue,
            "results": results.map { ["title": $0.title, "url": $0.url, "snippet": $0.snippet] },
        ]
        if let source { value["source"] = source }
        if let message { value["message"] = message }
        return value
    }
}

enum PublicWebSearchBackendError: Error {
    case requestFailed
    case unsupportedResponse
}

protocol PublicWebSearchBackend: Sendable {
    var providerName: String { get }
    func search(query: String) async throws -> [PublicWebSearchResult]
}

/// A real-search adapter. No backend is selected implicitly: configured providers
/// are explicit dependencies, so a missing search service is not reported as 0 hits.
struct PublicWebSearchService: Sendable {
    /// The app does not silently provision a search credential. Until a user
    /// configures Brave Search in AI Settings, the tool reports provider_unavailable.
    static let shared = PublicWebSearchService(backend: nil)

    @MainActor
    static func configuredForCurrentUser() -> PublicWebSearchService {
        guard let apiKey = PublicWebSearchCredentialStore.shared.apiKey else {
            return PublicWebSearchService(backend: nil)
        }
        return PublicWebSearchService(backend: BraveWebSearchBackend(apiKey: apiKey))
    }

    private let backend: (any PublicWebSearchBackend)?

    init(backend: (any PublicWebSearchBackend)? = nil) {
        self.backend = backend
    }

    func search(query rawQuery: String) async -> PublicWebSearchResponse {
        let query = String(rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))
        guard !query.isEmpty else {
            return PublicWebSearchResponse(
                query: query, status: .requestFailed, source: nil, results: [],
                message: "Enter a search query."
            )
        }
        guard let backend else {
            return PublicWebSearchResponse(
                query: query, status: .providerUnavailable, source: nil, results: [],
                message: "No general web-search provider is configured. DuckDuckGo Instant Answers are not a general search service."
            )
        }
        do {
            let results = try await backend.search(query: query)
            let safeResults = Array(results.prefix(10)).filter(Self.isPublicResult)
            return PublicWebSearchResponse(
                query: query,
                status: safeResults.isEmpty ? .noResults : .results,
                source: backend.providerName,
                results: safeResults,
                message: safeResults.isEmpty ? "The configured search provider returned no verified web results." : nil
            )
        } catch PublicWebSearchBackendError.unsupportedResponse {
            return PublicWebSearchResponse(
                query: query, status: .unsupportedResponse, source: backend.providerName, results: [],
                message: "The search provider returned a response Lima could not interpret."
            )
        } catch {
            return PublicWebSearchResponse(
                query: query, status: .requestFailed, source: backend.providerName, results: [],
                message: "The configured search provider request failed."
            )
        }
    }

    private static func isPublicResult(_ result: PublicWebSearchResult) -> Bool {
        guard let components = URLComponents(string: result.url),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              result.title.utf8.count <= 2_048,
              result.url.utf8.count <= 2_048,
              result.snippet.utf8.count <= 4_096 else { return false }
        return true
    }
}

/// A dedicated Keychain account for general web search. Test-mode instances
/// use a separate service namespace and never read the production credential.
@MainActor
final class PublicWebSearchCredentialStore: ObservableObject {
    static let shared = PublicWebSearchCredentialStore()
    static let productionService = "dev.liam.lima.public-web-search"
    private let service: String
    private let account = "brave-search-api-key"

    @Published private(set) var isConfigured = false

    init(service: String? = nil, testMode: Bool = LimaTestEnvironment.isEnabled) {
        self.service = service ?? (testMode ? "dev.liam.lima.test.public-web-search" : Self.productionService)
        isConfigured = readAPIKey() != nil
    }

    var apiKey: String? { readAPIKey() }

    func save(_ rawValue: String) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 4_096,
              !value.unicodeScalars.contains(where: CharacterSet.newlines.contains) else {
            throw NSError(domain: "LimaWebSearch", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Enter a valid Brave Search API key."])
        }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(value.utf8)] as CFDictionary)
            guard update == errSecSuccess else { throw keychainError(update) }
        } else if status != errSecSuccess {
            throw keychainError(status)
        }
        isConfigured = true
    }

    func remove() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
        isConfigured = false
    }

    private func readAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    private func keychainError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Lima could not access the web-search API key in Keychain."])
    }
}

/// Brave's documented Web Search API is configured explicitly in AI Settings.
/// The key is sent only in its auth header.
struct BraveWebSearchBackend: PublicWebSearchBackend {
    let apiKey: String
    let session: URLSession

    var providerName: String { "Brave Search API" }

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    func search(query: String) async throws -> [PublicWebSearchResult] {
        guard !apiKey.isEmpty,
              var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search") else {
            throw PublicWebSearchBackendError.requestFailed
        }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { throw PublicWebSearchBackendError.requestFailed }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PublicWebSearchBackendError.requestFailed
        }
        guard data.count <= 1_000_000,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let web = object["web"] as? [String: Any],
              let entries = web["results"] as? [[String: Any]] else {
            throw PublicWebSearchBackendError.unsupportedResponse
        }
        return entries.compactMap { entry in
            guard let title = entry["title"] as? String,
                  let url = entry["url"] as? String,
                  let description = entry["description"] as? String else { return nil }
            return PublicWebSearchResult(
                title: String(title.prefix(2_048)),
                url: String(url.prefix(2_048)),
                snippet: String(description.prefix(4_096))
            )
        }
    }
}
