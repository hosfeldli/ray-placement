import Foundation

public struct PostmanKeyValue: Codable, Hashable, Sendable {
    public var key: String
    public var value: String
    public var enabled: Bool

    public init(key: String, value: String, enabled: Bool = true) {
        self.key = key
        self.value = value
        self.enabled = enabled
    }
}

public struct PostmanAuthorization: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case none, bearer, basic, apiKey
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
        authorization: PostmanAuthorization = .init(kind: .none)
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
    }
}

public struct PostmanCollection: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var requests: [PostmanRequest]
    public var variables: [String: String]

    public init(id: UUID = UUID(), name: String, requests: [PostmanRequest], variables: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.requests = requests
        self.variables = variables
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
        var requests: [PostmanRequest] = []
        parseItems(
            root["item"] as? [[String: Any]] ?? [],
            folders: [],
            inheritedAuth: rootAuth,
            output: &requests
        )
        return PostmanCollection(
            name: name,
            requests: requests,
            variables: parseVariables(root["variable"] as? [[String: Any]] ?? [])
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
        output: inout [PostmanRequest]
    ) {
        for item in items {
            let name = string(item["name"]) ?? "Untitled request"
            let itemAuth = parseAuthorization(item["auth"] as? [String: Any]) ?? inheritedAuth
            if let children = item["item"] as? [[String: Any]] {
                parseItems(children, folders: folders + [name], inheritedAuth: itemAuth, output: &output)
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
            output.append(PostmanRequest(
                name: name,
                folderPath: folders,
                method: (string(request["method"]) ?? "GET").uppercased(),
                url: url.raw,
                parameters: url.query,
                headers: headerRows,
                body: body.text,
                contentType: explicitContentType ?? body.contentType,
                authorization: requestAuth
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

    private static func parseBody(_ body: [String: Any]?) -> (text: String, contentType: String?) {
        guard let body else { return ("", nil) }
        switch string(body["mode"]) {
        case "raw":
            let language = ((body["options"] as? [String: Any])?["raw"] as? [String: Any]).flatMap { string($0["language"]) }
            let type = language == "json" ? "application/json" : (language == "xml" ? "application/xml" : nil)
            return (string(body["raw"]) ?? "", type)
        case "urlencoded":
            let rows = parseRows(body["urlencoded"] as? [[String: Any]] ?? [])
            let text = rows.filter(\.enabled).map {
                let key = $0.key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.key
                let value = $0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value
                return "\(key)=\(value)"
            }.joined(separator: "&")
            return (text, "application/x-www-form-urlencoded")
        default: return ("", nil)
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

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }
}

public enum PostmanVariableResolver {
    public static func resolve(_ input: String, values: [String: String]) -> String {
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
            if let value = values[key] { result.replaceSubrange(wholeRange, with: value) }
        }
        return result
    }
}
