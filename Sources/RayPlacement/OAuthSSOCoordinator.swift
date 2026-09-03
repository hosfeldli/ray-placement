import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import RayPlacementCore
import Security

@MainActor
final class OAuthSSOCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var completion: ((Result<OAuthTokenRecord, Error>) -> Void)?
    private weak var window: NSWindow?

    func start(configuration: PostmanOAuthConfiguration, window: NSWindow?, completion: @escaping (Result<OAuthTokenRecord, Error>) -> Void) {
        self.completion = completion
        self.window = window

        do {
            let authorizationURL = try Self.authorizationURL(for: configuration)
            let verifier = Self.randomString(length: 64)
            let state = Self.randomString(length: 32)
            let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
            var components = try Self.components(for: authorizationURL)
            var items = components.queryItems ?? []
            items += [
                URLQueryItem(name: "client_id", value: configuration.clientID),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
                URLQueryItem(name: "scope", value: configuration.scope),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256")
            ]
            if !configuration.audience.isEmpty {
                items.append(URLQueryItem(name: "audience", value: configuration.audience))
            }
            components.queryItems = items
            guard let url = components.url else { throw OAuthSSOError.invalidAuthorizationURL }

            let callbackScheme = URL(string: configuration.redirectURI)?.scheme ?? "rayplacement"
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] callbackURL, error in
                Task { @MainActor [weak self] in
                    self?.handle(callbackURL: callbackURL, error: error, configuration: configuration, verifier: verifier, state: state)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            guard session.start() else {
                self.finish(.failure(OAuthSSOError.couldNotStartBrowser))
                return
            }
        } catch {
            finish(.failure(error))
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        window ?? NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }

    private func handle(callbackURL: URL?, error: Error?, configuration: PostmanOAuthConfiguration, verifier: String, state: String) {
        if let error {
            finish(.failure(error))
            return
        }
        guard let callbackURL,
              let callbackComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let items = callbackComponents.queryItems else {
            finish(.failure(OAuthSSOError.missingCallback))
            return
        }
        if let callbackError = items.first(where: { $0.name == "error" })?.value {
            let description = items.first(where: { $0.name == "error_description" })?.value
            finish(.failure(OAuthSSOError.authorizationDenied(description ?? callbackError)))
            return
        }
        guard items.first(where: { $0.name == "state" })?.value == state else {
            finish(.failure(OAuthSSOError.invalidState))
            return
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            finish(.failure(OAuthSSOError.missingAuthorizationCode))
            return
        }

        Task { @MainActor [weak self] in
            do {
                let token = try await Self.exchangeCode(code, verifier: verifier, configuration: configuration)
                self?.finish(.success(token))
            } catch {
                self?.finish(.failure(error))
            }
        }
    }

    private func finish(_ result: Result<OAuthTokenRecord, Error>) {
        session = nil
        let completion = completion
        self.completion = nil
        completion?(result)
    }

    private static func authorizationURL(for configuration: PostmanOAuthConfiguration) throws -> URL {
        guard !configuration.authorizationURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: configuration.authorizationURL),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil,
              !configuration.clientID.isEmpty else {
            throw OAuthSSOError.invalidConfiguration
        }
        return url
    }

    private static func components(for url: URL) throws -> URLComponents {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw OAuthSSOError.invalidAuthorizationURL
        }
        return components
    }

    private static func exchangeCode(_ code: String, verifier: String, configuration: PostmanOAuthConfiguration) async throws -> OAuthTokenRecord {
        guard let tokenURL = URL(string: configuration.tokenURL),
              ["https", "http"].contains(tokenURL.scheme?.lowercased() ?? ""),
              tokenURL.host != nil,
              !configuration.clientID.isEmpty else {
            throw OAuthSSOError.invalidTokenURL
        }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var fields = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("client_id", configuration.clientID),
            ("redirect_uri", configuration.redirectURI),
            ("code_verifier", verifier)
        ] + (configuration.audience.isEmpty ? [] : [("audience", configuration.audience)])
        if !configuration.clientSecret.isEmpty {
            fields.append(("client_secret", configuration.clientSecret))
        }
        var form = URLComponents()
        form.queryItems = fields.map { URLQueryItem(name: $0.0, value: $0.1) }
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OAuthSSOError.invalidTokenResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw OAuthSSOError.tokenExchangeFailed(Self.safeMessage(from: data, status: http.statusCode))
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["access_token"] as? String, !token.isEmpty else {
            throw OAuthSSOError.invalidTokenResponse
        }
        return OAuthTokenRecord(
            accessToken: token,
            refreshToken: object["refresh_token"] as? String,
            expiresIn: (object["expires_in"] as? NSNumber)?.doubleValue,
            issuedAt: Date()
        )
    }

    private static func safeMessage(from data: Data, status: Int) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "HTTP \(status)"
        }
        let message = (object["error_description"] as? String) ?? (object["error"] as? String) ?? "HTTP \(status)"
        return String(message.prefix(240))
    }

    private static func randomString(length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String((0..<length).compactMap { _ in alphabet.randomElement() })
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum OAuthSSOError: LocalizedError {
    case invalidConfiguration
    case invalidAuthorizationURL
    case invalidTokenURL
    case couldNotStartBrowser
    case missingCallback
    case authorizationDenied(String)
    case invalidState
    case missingAuthorizationCode
    case invalidTokenResponse
    case tokenExchangeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "Enter an authorization URL and client ID before starting SSO."
        case .invalidAuthorizationURL: return "The SSO authorization URL is invalid."
        case .invalidTokenURL: return "The OAuth token URL is invalid."
        case .couldNotStartBrowser: return "macOS could not start the SSO browser session."
        case .missingCallback: return "The SSO provider did not return a callback."
        case .authorizationDenied(let message): return "SSO authorization was denied: \(message)"
        case .invalidState: return "The SSO callback state did not match. No token was accepted."
        case .missingAuthorizationCode: return "The SSO callback did not include an authorization code."
        case .invalidTokenResponse: return "The SSO provider returned an invalid token response."
        case .tokenExchangeFailed(let message): return "The SSO token exchange failed: \(message)"
        }
    }
}

struct OAuthTokenRecord: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresIn: TimeInterval?
    var issuedAt: Date?

    var isExpired: Bool {
        guard let expiresIn, let issuedAt else { return false }
        return Date() >= issuedAt.addingTimeInterval(expiresIn - 60)
    }
}

enum OAuthTokenVault {
    private static let service = "dev.liam.rayplacement.oauth"

    static func account(for configuration: PostmanOAuthConfiguration) -> String {
        "\(configuration.clientID)|\(configuration.authorizationURL)|\(configuration.tokenURL)"
    }

    static func save(_ token: OAuthTokenRecord, for configuration: PostmanOAuthConfiguration) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        let account = account(for: configuration)
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(match as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = match
            item.merge(attributes) { _, new in new }
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func load(for configuration: PostmanOAuthConfiguration) -> OAuthTokenRecord? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: configuration),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(OAuthTokenRecord.self, from: data)
    }

    static func saveClientSecret(_ secret: String, for configuration: PostmanOAuthConfiguration) {
        let account = account(for: configuration) + "|client-secret"
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if secret.isEmpty {
            SecItemDelete(match as CFDictionary)
            return
        }
        let data = Data(secret.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(match as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = match
            item.merge(attributes) { _, new in new }
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func loadClientSecret(for configuration: PostmanOAuthConfiguration) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: configuration) + "|client-secret",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func delete(for configuration: PostmanOAuthConfiguration) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: configuration)
        ] as CFDictionary)
    }
}
