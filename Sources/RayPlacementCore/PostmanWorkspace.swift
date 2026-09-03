import Foundation

public struct PostmanKeyValue: Codable, Hashable, Sendable {
    public var key: String
    public var value: String
    public var enabled: Bool
    public var type: String?
    public var filePath: String?

    public init(
        key: String,
        value: String,
        enabled: Bool = true,
        type: String? = nil,
        filePath: String? = nil
    ) {
        self.key = key
        self.value = value
        self.enabled = enabled
        self.type = type
        self.filePath = filePath
    }
}

public struct PostmanAuthorization: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case none, bearer, basic, apiKey, oauth2
    }

    public var kind: Kind
    public var values: [String: String]

    public init(kind: Kind, values: [String: String] = [:]) {
        self.kind = kind
        self.values = values
    }
}

public struct PostmanRequest: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var folderPath: [String]
    public var method: String
    public var url: String
    public var parameters: [PostmanKeyValue]
    public var headers: [PostmanKeyValue]
    public var body: String
    public var contentType: String?
    public var authorization: PostmanAuthorization
    public var preRequestScript: String?
    public var testScript: String?
    public var bodyMode: String?
    public var bodyFields: [PostmanKeyValue]?
    public var binaryFilePath: String?

    public init(
        id: UUID = UUID(),
        name: String,
        folderPath: [String] = [],
        method: String,
        url: String,
        parameters: [PostmanKeyValue] = [],
        headers: [PostmanKeyValue] = [],
        body: String = "",
        contentType: String? = nil,
        authorization: PostmanAuthorization = .init(kind: .none),
        preRequestScript: String? = nil,
        testScript: String? = nil,
        bodyMode: String? = nil,
        bodyFields: [PostmanKeyValue]? = nil,
        binaryFilePath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.folderPath = folderPath
        self.method = method
        self.url = url
        self.parameters = parameters
        self.headers = headers
        self.body = body
        self.contentType = contentType
        self.authorization = authorization
        self.preRequestScript = preRequestScript
        self.testScript = testScript
        self.bodyMode = bodyMode
        self.bodyFields = bodyFields
        self.binaryFilePath = binaryFilePath
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, folderPath, method, url, parameters, headers, body, contentType, authorization
        case preRequestScript, testScript, bodyMode, bodyFields, binaryFilePath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled request"
        folderPath = try container.decodeIfPresent([String].self, forKey: .folderPath) ?? []
        method = try container.decodeIfPresent(String.self, forKey: .method) ?? "GET"
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        parameters = try container.decodeIfPresent([PostmanKeyValue].self, forKey: .parameters) ?? []
        headers = try container.decodeIfPresent([PostmanKeyValue].self, forKey: .headers) ?? []
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        contentType = try container.decodeIfPresent(String.self, forKey: .contentType)
        authorization = try container.decodeIfPresent(PostmanAuthorization.self, forKey: .authorization) ?? .init(kind: .none)
        preRequestScript = try container.decodeIfPresent(String.self, forKey: .preRequestScript)
        testScript = try container.decodeIfPresent(String.self, forKey: .testScript)
        bodyMode = try container.decodeIfPresent(String.self, forKey: .bodyMode)
        bodyFields = try container.decodeIfPresent([PostmanKeyValue].self, forKey: .bodyFields)
        binaryFilePath = try container.decodeIfPresent(String.self, forKey: .binaryFilePath)
    }
}

public struct PostmanCollection: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var requests: [PostmanRequest]
    public var variables: [String: String]
    public var preRequestScript: String?
    public var testScript: String?

    public init(
        id: UUID = UUID(),
        name: String,
        requests: [PostmanRequest],
        variables: [String: String] = [:],
        preRequestScript: String? = nil,
        testScript: String? = nil
    ) {
        self.id = id
        self.name = name
        self.requests = requests
        self.variables = variables
        self.preRequestScript = preRequestScript
        self.testScript = testScript
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, requests, variables, preRequestScript, testScript
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Imported collection"
        requests = try container.decodeIfPresent([PostmanRequest].self, forKey: .requests) ?? []
        variables = try container.decodeIfPresent([String: String].self, forKey: .variables) ?? [:]
        preRequestScript = try container.decodeIfPresent(String.self, forKey: .preRequestScript)
        testScript = try container.decodeIfPresent(String.self, forKey: .testScript)
    }
}

public struct PostmanEnvironment: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var values: [PostmanKeyValue]

    public init(id: UUID = UUID(), name: String, values: [PostmanKeyValue]) {
        self.id = id
        self.name = name
        self.values = values
    }

    public var resolvedValues: [String: String] {
        Dictionary(uniqueKeysWithValues: values.filter(\.enabled).map { ($0.key, $0.value) })
    }
}

public struct PostmanTestResult: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var passed: Bool
    public var message: String

    public init(id: UUID = UUID(), name: String, passed: Bool, message: String) {
        self.id = id
        self.name = name
        self.passed = passed
        self.message = message
    }
}

public struct PostmanOAuthConfiguration: Codable, Hashable, Sendable {
    public var authorizationURL: String
    public var tokenURL: String
    public var clientID: String
    public var clientSecret: String
    public var scope: String
    public var redirectURI: String
    public var audience: String
    public var tokenParameterName: String

    public init(
        authorizationURL: String = "",
        tokenURL: String = "",
        clientID: String = "",
        clientSecret: String = "",
        scope: String = "openid profile",
        redirectURI: String = "rayplacement://oauth/callback",
        audience: String = "",
        tokenParameterName: String = "access_token"
    ) {
        self.authorizationURL = authorizationURL
        self.tokenURL = tokenURL
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scope = scope
        self.redirectURI = redirectURI
        self.audience = audience
        self.tokenParameterName = tokenParameterName
    }

    private enum CodingKeys: String, CodingKey {
        case authorizationURL, tokenURL, clientID, clientSecret, scope, redirectURI, audience, tokenParameterName
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(authorizationURL, forKey: .authorizationURL)
        try container.encode(tokenURL, forKey: .tokenURL)
        try container.encode(clientID, forKey: .clientID)
        try container.encode(scope, forKey: .scope)
        try container.encode(redirectURI, forKey: .redirectURI)
        try container.encode(audience, forKey: .audience)
        try container.encode(tokenParameterName, forKey: .tokenParameterName)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        authorizationURL = try container.decodeIfPresent(String.self, forKey: .authorizationURL) ?? ""
        tokenURL = try container.decodeIfPresent(String.self, forKey: .tokenURL) ?? ""
        clientID = try container.decodeIfPresent(String.self, forKey: .clientID) ?? ""
        clientSecret = try container.decodeIfPresent(String.self, forKey: .clientSecret) ?? ""
        scope = try container.decodeIfPresent(String.self, forKey: .scope) ?? "openid profile"
        redirectURI = try container.decodeIfPresent(String.self, forKey: .redirectURI) ?? "rayplacement://oauth/callback"
        audience = try container.decodeIfPresent(String.self, forKey: .audience) ?? ""
        tokenParameterName = try container.decodeIfPresent(String.self, forKey: .tokenParameterName) ?? "access_token"
    }
}

public struct PostmanResponseSnapshot: Sendable {
    public var statusCode: Int
    public var statusText: String
    public var body: String
    public var headers: [String: String]

    public init(statusCode: Int, statusText: String = "", body: String = "", headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.statusText = statusText
        self.body = body
        self.headers = headers
    }
}

public enum PostmanImport: Sendable {
    case collection(PostmanCollection)
    case environment(PostmanEnvironment)
}

public enum PostmanImportError: LocalizedError {
    case invalidDocument
    case unsupportedDocument

    public var errorDescription: String? {
        switch self {
        case .invalidDocument: return "The file is not valid Postman JSON."
        case .unsupportedDocument: return "The JSON is not a Postman collection or environment."
        }
    }
}

public enum PostmanImporter {
    public static func decode(_ data: Data) throws -> PostmanImport {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PostmanImportError.invalidDocument
        }
        if root["item"] is [[String: Any]], root["info"] is [String: Any] {
            return .collection(parseCollection(root))
        }
        if root["values"] is [[String: Any]], root["name"] != nil {
            return .environment(parseEnvironment(root))
        }
        throw PostmanImportError.unsupportedDocument
    }

    private static func parseCollection(_ root: [String: Any]) -> PostmanCollection {
        let info = root["info"] as? [String: Any]
        let name = string(info?["name"]) ?? "Imported collection"
        let rootAuth = parseAuthorization(root["auth"] as? [String: Any])
        let rootScripts = parseEventScripts(root["event"])
        var requests: [PostmanRequest] = []
        parseItems(
            root["item"] as? [[String: Any]] ?? [],
            folders: [],
            inheritedAuth: rootAuth,
            inheritedPreRequestScript: rootScripts.preRequest,
            inheritedTestScript: rootScripts.test,
            output: &requests
        )
        return PostmanCollection(
            name: name,
            requests: requests,
            variables: parseVariables(root["variable"] as? [[String: Any]] ?? []),
            preRequestScript: rootScripts.preRequest,
            testScript: rootScripts.test
        )
    }

    private static func parseEnvironment(_ root: [String: Any]) -> PostmanEnvironment {
        let rows = (root["values"] as? [[String: Any]] ?? []).compactMap { item -> PostmanKeyValue? in
            guard let key = string(item["key"]), !key.isEmpty else { return nil }
            return PostmanKeyValue(
                key: key,
                value: string(item["value"]) ?? "",
                enabled: (item["enabled"] as? Bool) ?? true
            )
        }
        return PostmanEnvironment(name: string(root["name"]) ?? "Imported environment", values: rows)
    }

    private static func parseItems(
        _ items: [[String: Any]],
        folders: [String],
        inheritedAuth: PostmanAuthorization?,
        inheritedPreRequestScript: String?,
        inheritedTestScript: String?,
        output: inout [PostmanRequest]
    ) {
        for item in items {
            let name = string(item["name"]) ?? "Untitled request"
            let itemAuth = parseAuthorization(item["auth"] as? [String: Any]) ?? inheritedAuth
            let itemScripts = parseEventScripts(item["event"])
            let preRequestScript = combine(inheritedPreRequestScript, itemScripts.preRequest)
            let testScript = combine(inheritedTestScript, itemScripts.test)
            if let children = item["item"] as? [[String: Any]] {
                parseItems(
                    children,
                    folders: folders + [name],
                    inheritedAuth: itemAuth,
                    inheritedPreRequestScript: preRequestScript,
                    inheritedTestScript: testScript,
                    output: &output
                )
                continue
            }
            guard let rawRequest = item["request"] else { continue }
            let request: [String: Any]
            if let dictionary = rawRequest as? [String: Any] { request = dictionary }
            else if let url = string(rawRequest) { request = ["method": "GET", "url": url] }
            else { continue }

            let url = parseURL(request["url"])
            let headerRows = parseRows(request["header"] as? [[String: Any]] ?? [])
            let bodyObject = request["body"] as? [String: Any]
            let body = parseBody(bodyObject)
            let explicitContentType = headerRows.first { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
            let requestAuth = parseAuthorization(request["auth"] as? [String: Any]) ?? itemAuth ?? .init(kind: .none)
            let requestScripts = parseEventScripts(request["event"])
            output.append(PostmanRequest(
                name: name,
                folderPath: folders,
                method: (string(request["method"]) ?? "GET").uppercased(),
                url: url.raw,
                parameters: url.query,
                headers: headerRows,
                body: body.text,
                contentType: explicitContentType ?? body.contentType,
                authorization: requestAuth,
                preRequestScript: combine(preRequestScript, requestScripts.preRequest),
                testScript: combine(testScript, requestScripts.test),
                bodyMode: body.mode,
                bodyFields: body.fields,
                binaryFilePath: body.binaryFilePath
            ))
        }
    }

    private static func parseURL(_ object: Any?) -> (raw: String, query: [PostmanKeyValue]) {
        if let raw = string(object) { return (raw, []) }
        guard let url = object as? [String: Any] else { return ("", []) }
        var raw = string(url["raw"]) ?? ""
        if raw.isEmpty {
            let protocolName = string(url["protocol"]) ?? "https"
            let host: String
            if let values = url["host"] as? [Any] { host = values.compactMap(string).joined(separator: ".") }
            else { host = string(url["host"]) ?? "" }
            let path: String
            if let values = url["path"] as? [Any] { path = values.compactMap(string).joined(separator: "/") }
            else { path = string(url["path"]) ?? "" }
            raw = "\(protocolName)://\(host)" + (path.isEmpty ? "" : "/\(path)")
        }
        return (raw, parseRows(url["query"] as? [[String: Any]] ?? []))
    }

    private static func parseBody(_ body: [String: Any]?) -> (text: String, contentType: String?, mode: String?, fields: [PostmanKeyValue]?, binaryFilePath: String?) {
        guard let body else { return ("", nil, nil, nil, nil) }
        let mode = string(body["mode"])
        switch mode {
        case "raw":
            let language = ((body["options"] as? [String: Any])?["raw"] as? [String: Any]).flatMap { string($0["language"]) }
            let type = language == "json" ? "application/json" : (language == "xml" ? "application/xml" : nil)
            return (string(body["raw"]) ?? "", type, mode, nil, nil)
        case "urlencoded":
            let rows = parseRows(body["urlencoded"] as? [[String: Any]] ?? [])
            let text = rows.filter(\.enabled).map {
                let key = $0.key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.key
                let value = $0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value
                return "\(key)=\(value)"
            }.joined(separator: "&")
            return (text, "application/x-www-form-urlencoded", mode, rows, nil)
        case "formdata":
            return ("", "multipart/form-data", mode, parseBodyRows(body["formdata"] as? [[String: Any]] ?? []), nil)
        case "file":
            let source = (body["file"] as? [String: Any]).flatMap { string($0["src"]) }
            return ("", nil, mode, nil, source)
        default:
            return ("", nil, mode, nil, nil)
        }
    }

    private static func parseBodyRows(_ rows: [[String: Any]]) -> [PostmanKeyValue] {
        rows.compactMap { row in
            guard let key = string(row["key"]), !key.isEmpty else { return nil }
            let type = string(row["type"])?.lowercased()
            let value: String
            if type == "file", let source = (row["src"] as? String) ?? ((row["src"] as? [String])?.first) {
                value = source
            } else {
                value = string(row["value"]) ?? ""
            }
            return PostmanKeyValue(
                key: key,
                value: value,
                enabled: !(row["disabled"] as? Bool ?? false),
                type: type,
                filePath: type == "file" ? value : nil
            )
        }
    }

    private static func parseAuthorization(_ auth: [String: Any]?) -> PostmanAuthorization? {
        guard let auth, let type = string(auth["type"])?.lowercased() else { return nil }
        if type == "noauth" { return .init(kind: .none) }
        let rows = auth[type] as? [[String: Any]] ?? []
        let values = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, String)? in
            guard let key = string(row["key"]) else { return nil }
            return (key, string(row["value"]) ?? "")
        })
        switch type {
        case "bearer": return .init(kind: .bearer, values: values)
        case "basic": return .init(kind: .basic, values: values)
        case "apikey": return .init(kind: .apiKey, values: values)
        case "oauth2": return .init(kind: .oauth2, values: values)
        default: return nil
        }
    }

    private static func parseRows(_ rows: [[String: Any]]) -> [PostmanKeyValue] {
        rows.compactMap { row in
            guard let key = string(row["key"]), !key.isEmpty else { return nil }
            return PostmanKeyValue(
                key: key,
                value: string(row["value"]) ?? "",
                enabled: !(row["disabled"] as? Bool ?? false)
            )
        }
    }

    private static func parseVariables(_ rows: [[String: Any]]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, String)? in
            guard let key = string(row["key"]), !(row["disabled"] as? Bool ?? false) else { return nil }
            return (key, string(row["value"]) ?? "")
        })
    }

    private static func parseEventScripts(_ object: Any?) -> (preRequest: String?, test: String?) {
        guard let events = object as? [[String: Any]] else { return (nil, nil) }
        var preRequest: [String] = []
        var test: [String] = []
        for event in events {
            guard let listen = string(event["listen"])?.lowercased(),
                  let script = event["script"] as? [String: Any] else { continue }
            let source: String
            if let lines = script["exec"] as? [String] { source = lines.joined(separator: "\n") }
            else { source = string(script["exec"]) ?? "" }
            guard !source.isEmpty else { continue }
            if listen == "prerequest" { preRequest.append(source) }
            if listen == "test" { test.append(source) }
        }
        return (
            preRequest.isEmpty ? nil : preRequest.joined(separator: "\n\n"),
            test.isEmpty ? nil : test.joined(separator: "\n\n")
        )
    }

    private static func combine(_ first: String?, _ second: String?) -> String? {
        switch (first?.isEmpty == false ? first : nil, second?.isEmpty == false ? second : nil) {
        case let (first?, second?): return first + "\n\n" + second
        case let (first?, nil): return first
        case let (nil, second?): return second
        case (nil, nil): return nil
        }
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }
}

public enum PostmanVariableResolver {
    public static func resolve(_ input: String, values: [String: String]) -> String {
        var result = input
        for _ in 0..<5 {
            let next = resolveOnce(result, values: values)
            if next == result { break }
            result = next
        }
        return result
    }

    private static func resolveOnce(_ input: String, values: [String: String]) -> String {
        guard input.contains("{{") else { return input }
        let pattern = #"\{\{\s*([^{}]+?)\s*\}\}"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return input }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        var result = input
        for match in expression.matches(in: input, range: range).reversed() {
            guard match.numberOfRanges == 2,
                  let keyRange = Range(match.range(at: 1), in: input),
                  let wholeRange = Range(match.range(at: 0), in: result) else { continue }
            let key = input[keyRange].trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement: String?
            switch key {
            case "$guid": replacement = UUID().uuidString
            case "$timestamp": replacement = String(Int(Date().timeIntervalSince1970))
            case "$randomInt": replacement = String(Int.random(in: 0...99999))
            default: replacement = values[key]
            }
            if let replacement { result.replaceSubrange(wholeRange, with: replacement) }
        }
        return result
    }
}

public enum PostmanScriptInterpreter {
    public static func apply(_ source: String?, to variables: inout [String: String]) {
        guard let source, !source.isEmpty else { return }
        let pattern = #"pm\.(?:variables|environment|collectionVariables)\.set\(\s*['\"]([^'\"]+)['\"]\s*,\s*(['\"])(.*?)\2\s*\)"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        for match in expression.matches(in: source, range: range) {
            guard match.numberOfRanges >= 4,
                  let keyRange = Range(match.range(at: 1), in: source),
                  let valueRange = Range(match.range(at: 3), in: source) else { continue }
            variables[String(source[keyRange])] = PostmanVariableResolver.resolve(String(source[valueRange]), values: variables)
        }
    }
}

public enum PostmanTestEvaluator {
    public static func evaluate(_ source: String?, response: PostmanResponseSnapshot) -> [PostmanTestResult] {
        guard let source, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let tests = namedTests(in: source)
        if tests.isEmpty {
            let evaluation = evaluateAssertions(source, response: response)
            return [PostmanTestResult(name: "Postman assertions", passed: evaluation.passed, message: evaluation.message)]
        }
        return tests.map { name, body in
            let evaluation = evaluateAssertions(body, response: response)
            return PostmanTestResult(name: name, passed: evaluation.passed, message: evaluation.message)
        }
    }

    private static func namedTests(in source: String) -> [(String, String)] {
        let pattern = #"pm\.test\(\s*['\"]([^'\"]+)['\"]\s*,\s*function\s*\([^)]*\)\s*\{([\s\S]*?)\}\s*\)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return expression.matches(in: source, range: range).compactMap { match in
            guard match.numberOfRanges == 3,
                  let nameRange = Range(match.range(at: 1), in: source),
                  let bodyRange = Range(match.range(at: 2), in: source) else { return nil }
            return (String(source[nameRange]), String(source[bodyRange]))
        }
    }

    private static func evaluateAssertions(_ source: String, response: PostmanResponseSnapshot) -> (passed: Bool, message: String) {
        if let error = capture(#"throw\s+new\s+Error\(\s*['\"]([^'\"]+)['\"]"#, in: source) {
            return (false, error)
        }
        if source.range(of: #"pm\.expect\(\s*true\s*\)\.to\.be\.true"#, options: .regularExpression) != nil {
            return (true, "Expected true")
        }
        if source.range(of: #"pm\.expect\(\s*false\s*\)\.to\.be\.false"#, options: .regularExpression) != nil {
            return (true, "Expected false")
        }
        if let expected = capture(#"pm\.response\.to\.have\.status\(\s*(\d+)\s*\)"#, in: source),
           let code = Int(expected) {
            return response.statusCode == code
                ? (true, "HTTP status is \(code)")
                : (false, "Expected HTTP \(code), received \(response.statusCode)")
        }
        if source.range(of: #"pm\.response\.to\.be\.ok"#, options: .regularExpression) != nil {
            return (200..<400).contains(response.statusCode)
                ? (true, "Response is OK")
                : (false, "Expected a successful response, received \(response.statusCode)")
        }
        if let expected = capture(#"pm\.expect\(\s*pm\.response\.code\s*\)\.to\.(?:equal|eql)\(\s*(\d+)\s*\)"#, in: source),
           let code = Int(expected) {
            return response.statusCode == code
                ? (true, "Response code equals \(code)")
                : (false, "Expected response code \(code), received \(response.statusCode)")
        }
        if let expected = capture(#"pm\.expect\(\s*pm\.response\.text\(\)\s*\)\.to\.include\(\s*['\"]([^'\"]*)['\"]\s*\)"#, in: source) {
            return response.body.contains(expected)
                ? (true, "Response contains expected text")
                : (false, "Response does not contain \"\(expected)\"")
        }
        let pair = captures(#"pm\.expect\(\s*pm\.response\.json\(\)\.([A-Za-z0-9_]+)\s*\)\.to\.(?:equal|eql)\(\s*['\"]([^'\"]*)['\"]\s*\)"#, in: source)
        if pair.count >= 2 {
            let key = pair[0]
            let expected = pair[1]
            guard let value = jsonValue(response.body, key: key) else {
                return (false, "Response JSON did not contain field \(key)")
            }
            return value == expected
                ? (true, "JSON field \(key) matched")
                : (false, "Expected JSON field \(key) to equal \"\(expected)\", received \"\(value)\"")
        }
        if let allowed = capture(#"pm\.expect\(\s*pm\.response\.code\s*\)\.to\.be\.oneOf\(\s*\[([^]]*)\]\s*\)"#, in: source) {
            let codes = captures(#"\d+"#, in: allowed).compactMap(Int.init)
            return codes.contains(response.statusCode)
                ? (true, "Response code is allowed")
                : (false, "Response code \(response.statusCode) is not allowed")
        }
        return (true, "Script retained; no unsupported assertion was evaluated")
    }

    private static func jsonValue(_ body: String, key: String) -> String? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object[key] else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let boolean = value as? Bool { return boolean ? "true" : "false" }
        return nil
    }

    private static func capture(_ pattern: String, in source: String) -> String? {
        captures(pattern, in: source).first
    }

    private static func captures(_ pattern: String, in source: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = expression.firstMatch(in: source, range: range) else { return [] }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let captureRange = Range(match.range(at: index), in: source) else { return nil }
            return String(source[captureRange])
        }
    }
}

public enum PostmanDataFileParser {
    public static func parse(_ data: Data, fileExtension: String) throws -> [[String: String]] {
        let ext = fileExtension.lowercased()
        if ext == "json" {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw PostmanDataFileError.invalidFormat
            }
            return object.map { row in
                row.reduce(into: [String: String]()) { result, entry in
                    if let value = entry.value as? String { result[entry.key] = value }
                    else if let value = entry.value as? NSNumber { result[entry.key] = value.stringValue }
                }
            }
        }
        guard let text = String(data: data, encoding: .utf8) else { throw PostmanDataFileError.invalidFormat }
        let rows = parseCSV(text)
        guard let headers = rows.first, !headers.isEmpty else { throw PostmanDataFileError.invalidFormat }
        return rows.dropFirst().filter { !$0.allSatisfy(\.isEmpty) }.map { values in
            Dictionary(uniqueKeysWithValues: headers.enumerated().map { index, header in
                (header, index < values.count ? values[index] : "")
            })
        }
    }

    private static func parseCSV(_ text: String) -> [[String]] {
        var rows = [[String]]()
        var row = [String]()
        var field = ""
        var quoted = false
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            if quoted {
                if character == "\"" {
                    // A doubled quote is the CSV escape for a literal quote.
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") }
                        else {
                            quoted = false
                            if next == "," { row.append(field); field = "" }
                            else if next == "\n" { row.append(field); rows.append(row); row = []; field = "" }
                            else { field.append(next) }
                        }
                    } else { quoted = false }
                } else { field.append(character) }
            } else {
                switch character {
                case "\"": quoted = true
                case ",": row.append(field); field = ""
                case "\n": row.append(field); rows.append(row); row = []; field = ""
                case "\r": break
                default: field.append(character)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}

public enum PostmanDataFileError: LocalizedError {
    case invalidFormat

    public var errorDescription: String? { "The runner data file must be a JSON array, CSV file, or TSV-like CSV file." }
}
