import Foundation

/// Stateless, read-only MCP JSON-RPC surface for one authenticated Lima Access client.
/// No external client can call the QA control API or bypass AI Chat approval flow.
@MainActor
enum LimaAccessMCP {
    static let protocolVersion = "2025-06-18"

    static func handle(_ data: Data, access: LimaAccessProfile,
                       notes: NotesStore, transport: LimaAccessTransport = .local) async -> Data? {
        guard data.count <= LimaAccessHTTP.maximumRequestBytes,
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              request["jsonrpc"] as? String == "2.0",
              let method = request["method"] as? String else {
            return encode(error(code: -32600, message: "Invalid JSON-RPC request.", id: NSNull()))
        }
        let id = request["id"]
        if method.hasPrefix("notifications/") { return nil }
        guard let id, id is String || id is NSNumber else {
            return encode(error(code: -32600, message: "A request ID is required.", id: NSNull()))
        }
        let params: [String: Any]
        if let supplied = request["params"] {
            guard let object = supplied as? [String: Any] else {
                return encode(error(code: -32602, message: "Request parameters must be an object.", id: id))
            }
            params = object
        } else {
            params = [:]
        }
        let result: [String: Any]
        switch method {
        case "initialize":
            result = [
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": [:] as [String: Any], "resources": [:] as [String: Any]],
                "serverInfo": ["name": "Lima", "version":
                    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"],
                "instructions": "This Lima Access connection is read-only. Only listed resources and tools are available."
            ]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": toolCatalog(access: access)]
        case "tools/call":
            guard let name = params["name"] as? String else {
                return encode(error(code: -32602, message: "A tool name is required.", id: id))
            }
            let arguments: [String: Any]
            if let supplied = params["arguments"] {
                guard let object = supplied as? [String: Any] else {
                    return encode(error(code: -32602, message: "Tool arguments must be an object.", id: id))
                }
                arguments = object
            } else {
                arguments = [:]
            }
            guard toolNames.contains(name) else {
                return encode(error(code: -32602, message: "This read-only connection cannot use that tool.", id: id))
            }
            let execution: LimaAIToolExecution
            switch name {
            case "search_notes", "read_note":
                guard JSONSerialization.isValidJSONObject(arguments),
                      let argumentData = try? JSONSerialization.data(withJSONObject: arguments),
                      let argumentText = String(data: argumentData, encoding: .utf8) else {
                    return encode(error(code: -32602, message: "Invalid tool arguments.", id: id))
                }
                let call = AIOutputItem(phase: .completed, apiType: "function_call",
                                        name: name, arguments: argumentText)
                execution = await AINotesTools.execute(call, store: notes)
            case "get_lima_status":
                execution = .json([
                    "app": "Lima",
                    "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
                    "access": access.title,
                    "transport": transport == .network ? "network_tls" : "loopback_http",
                    "network_enabled": transport == .network
                ])
            case "lima_capabilities":
                execution = .json([
                    "access": access.title,
                    "notes": "read",
                    "chats": "unavailable",
                    "context": "unavailable",
                    "clipboard": "unavailable",
                    "browser": "unavailable",
                    "computer_actions": "unavailable",
                    "network": transport == .network
                ])
            default:
                return encode(error(code: -32602, message: "This tool is unavailable.", id: id))
            }
            result = ["content": [["type": "text", "text": execution.output]],
                      "isError": execution.isError]
        case "resources/templates/list":
            result = ["resourceTemplates": [[
                "uriTemplate": "lima://notes/{id}",
                "name": "Lima Note",
                "mimeType": "application/json",
                "description": "Read the first bounded chunk of a local note by its ID."
            ]]]
        case "resources/list":
            let entries: [[String: Any]] = [
                ["uri": "lima://notes", "name": "Lima Notes", "mimeType": "application/json",
                 "description": "Bounded list of local note IDs and titles."],
                ["uri": "lima://state", "name": "Lima State", "mimeType": "application/json",
                 "description": "Non-sensitive application and connection status."]
            ] + notes.notes.map { note in
                [
                    "uri": "lima://notes/\(note.id.uuidString)",
                    "name": String(note.displayTitle.prefix(160)),
                    "mimeType": "application/json",
                    "description": "A bounded local note; use read_note for further chunks."
                ] as [String: Any]
            }
            result = ["resources": entries]
        case "resources/read":
            guard let uri = params["uri"] as? String else {
                return encode(error(code: -32602, message: "A resource URI is required.", id: id))
            }
            let value: [String: Any]
            if uri == "lima://notes" {
                value = [
                    "notes": notes.notes.map {
                        ["id": $0.id.uuidString, "title": String($0.displayTitle.prefix(160))]
                    },
                    "count": notes.notes.count
                ]
            } else if uri == "lima://state" {
                value = [
                    "app": "Lima",
                    "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
                    "access": access.title,
                    "network_enabled": transport == .network
                ]
            } else if uri.hasPrefix("lima://notes/"),
                      let noteID = UUID(uuidString: String(uri.dropFirst("lima://notes/".count))),
                      let note = notes.notes.first(where: { $0.id == noteID }) {
                let chunk = String(note.content.prefix(10_000))
                value = [
                    "id": note.id.uuidString,
                    "title": String(note.displayTitle.prefix(160)),
                    "content": chunk,
                    "total_characters": note.content.count,
                    "next_offset": chunk.count < note.content.count ? chunk.count as Any : NSNull()
                ]
            } else {
                return encode(error(code: -32602, message: "This resource is unavailable.", id: id))
            }
            guard let text = jsonText(value) else {
                return encode(error(code: -32603, message: "The resource could not be encoded.", id: id))
            }
            result = ["contents": [["uri": uri, "mimeType": "application/json", "text": text]]]
        default:
            return encode(error(code: -32601, message: "Unknown MCP method.", id: id))
        }
        return encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static let toolNames: Set<String> = [
        "lima_capabilities", "get_lima_status", "search_notes", "read_note"
    ]

    private static func toolCatalog(access: LimaAccessProfile) -> [[String: Any]] {
        let custom: [[String: Any]] = [
            [
                "name": "lima_capabilities",
                "description": "Read this connection's effective Lima capabilities without exposing credentials.",
                "inputSchema": ["type": "object", "properties": [:] as [String: Any],
                                "additionalProperties": false],
                "annotations": ["readOnlyHint": true]
            ],
            [
                "name": "get_lima_status",
                "description": "Read non-sensitive Lima application and connection status.",
                "inputSchema": ["type": "object", "properties": [:] as [String: Any],
                                "additionalProperties": false],
                "annotations": ["readOnlyHint": true]
            ]
        ]
        let notes = AINotesTools.definitions.map { definition in
            [
                "name": definition.name,
                "description": definition.description,
                "inputSchema": definition.parameters,
                "annotations": ["readOnlyHint": true]
            ] as [String: Any]
        }
        return custom + notes
    }

    private static func error(code: Int, message: String, id: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private static func encode(_ value: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private static func jsonText(_ value: [String: Any]) -> String? {
        guard let data = encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
