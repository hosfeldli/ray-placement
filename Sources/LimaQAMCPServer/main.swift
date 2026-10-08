import Darwin
import Foundation
import LimaQAProtocol

private let tools: [[String: Any]] = [
    tool("lima_status", "Read Lima QA runtime status and privacy-safe task counts."),
    tool("surface_list", "List the QA surfaces Lima can open."),
    tool("surface_open", "Open a supported Lima surface using its production presentation path.", properties: [
        "surface": ["type": "string", "enum": ["search", "notes", "ai", "context", "settings"]]
    ], required: ["surface"]),
    tool("surface_close", "Close a supported Lima surface.", properties: [
        "surface": ["type": "string", "enum": ["search", "notes", "ai", "context", "settings"]]
    ], required: ["surface"]),
    tool("ui_inspect", "Inspect a compact semantic projection of the currently visible Lima UI."),
    tool("ui_find", "Find one stable semantic QA target.", properties: [
        "target": ["type": "string"]
    ], required: ["target"]),
    tool("ui_activate", "Activate one visible semantic control using its native accessibility action.", properties: [
        "target": ["type": "string"]
    ], required: ["target"]),
    tool("ui_set_text", "Set text in an allowlisted visible Lima text field.", properties: [
        "target": ["type": "string", "maxLength": 128],
        "text": ["type": "string", "maxLength": 16_000]
    ], required: ["target", "text"]),
    tool("ui_press_key", "Press one allowlisted key in the focused Lima window.", properties: [
        "key": ["type": "string", "enum": ["return", "escape", "tab", "up", "down", "left", "right", "space", "delete"]]
    ], required: ["key"]),
    tool("app_state", "Read privacy-safe launcher, workspace, AI, Browser Bridge, window, and task state."),
    tool("tasks_list", "Read active and recent TaskRegistry status without task details."),
    tool("ai_activity", "Read actions Lima actually recorded for the selected conversation.")
]

private func tool(
    _ name: String,
    _ description: String,
    properties: [String: Any] = [:],
    required: [String] = []
) -> [String: Any] {
    [
        "name": name,
        "description": description,
        "inputSchema": [
            "type": "object",
            "properties": properties,
            "required": required,
            "additionalProperties": false
        ]
    ]
}

private func jsonLine(_ value: [String: Any]) -> Data? {
    guard let encoded = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) else { return nil }
    var line = encoded
    line.append(10)
    return line
}

private func send(_ response: [String: Any]) {
    guard let data = jsonLine(response) else { return }
    FileHandle.standardOutput.write(data)
}

private func rpcError(id: Any, code: Int, message: String) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
}

private func mcpToolCall(_ name: String, arguments: [String: Any]) -> [String: Any] {
    let method: String
    var params: [String: String] = [:]

    switch name {
    case "lima_status":
        guard arguments.isEmpty else { return toolError("lima_status takes no arguments.") }
        method = "status"
    case "surface_list":
        guard arguments.isEmpty else { return toolError("surface_list takes no arguments.") }
        method = "surfaces.list"
    case "surface_open", "surface_close":
        guard Set(arguments.keys) == ["surface"],
              let surface = arguments["surface"] as? String,
              ["search", "notes", "ai", "context", "settings"].contains(surface) else {
            return toolError("Provide one supported surface: search, notes, ai, context, or settings.")
        }
        method = name == "surface_open" ? "surface.open" : "surface.close"
        params["surface"] = surface
    case "ui_inspect":
        guard arguments.isEmpty else { return toolError("ui_inspect takes no arguments.") }
        method = "ui.inspect"
    case "ui_find", "ui_activate":
        guard Set(arguments.keys) == ["target"],
              let target = arguments["target"] as? String,
              !target.isEmpty, target.utf8.count <= 128 else {
            return toolError("Provide one semantic target identifier.")
        }
        method = name == "ui_find" ? "ui.find" : "ui.activate"
        params["target"] = target
    case "ui_set_text":
        guard Set(arguments.keys) == ["target", "text"],
              let target = arguments["target"] as? String,
              let text = arguments["text"] as? String,
              !target.isEmpty, target.utf8.count <= 128,
              text.utf8.count <= 16_000 else {
            return toolError("Provide a semantic target and text of at most 16,000 UTF-8 bytes.")
        }
        method = "ui.setText"
        params["target"] = target
        params["text"] = text
    case "ui_press_key":
        guard Set(arguments.keys) == ["key"],
              let key = arguments["key"] as? String,
              ["return", "escape", "tab", "up", "down", "left", "right", "space", "delete"].contains(key) else {
            return toolError("Provide one supported key.")
        }
        method = "ui.pressKey"
        params["key"] = key
    case "app_state":
        guard arguments.isEmpty else { return toolError("app_state takes no arguments.") }
        method = "app.state"
    case "tasks_list":
        guard arguments.isEmpty else { return toolError("tasks_list takes no arguments.") }
        method = "tasks.list"
    case "ai_activity":
        guard arguments.isEmpty else { return toolError("ai_activity takes no arguments.") }
        method = "ai.activity"
    default:
        return toolError("This Lima QA tool is not available.")
    }

    do {
        let response = try LimaQASocketClient.send(LimaQARequest(id: UUID().uuidString, method: method, params: params))
        let text = response.payload ?? response.error ?? "{}"
        return [
            "content": [["type": "text", "text": text]],
            "isError": !response.ok
        ]
    } catch {
        return toolError("Could not reach the authorized Lima QA app over its local Unix socket.")
    }
}

private func toolError(_ message: String) -> [String: Any] {
    ["content": [["type": "text", "text": message]], "isError": true]
}

private func handle(_ request: [String: Any]) -> [String: Any]? {
    guard request["jsonrpc"] as? String == "2.0",
          let method = request["method"] as? String else {
        return rpcError(id: request["id"] ?? NSNull(), code: -32600, message: "Invalid JSON-RPC request.")
    }
    let id = request["id"]

    switch method {
    case "notifications/initialized":
        return nil
    case "initialize":
        guard id != nil else { return nil }
        return [
            "jsonrpc": "2.0",
            "id": id!,
            "result": [
                "protocolVersion": request["params"].flatMap { ($0 as? [String: Any])?["protocolVersion"] as? String } ?? "2025-03-26",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "LimaQAMCPServer", "version": "1.0.0"],
                "instructions": "Controls only the explicitly QA-enabled Lima app. It exposes no shell, script execution, or credential-reading interface."
            ]
        ]
    case "ping":
        return ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": [:]]
    case "tools/list":
        return ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": ["tools": tools]]
    case "tools/call":
        guard let id else { return nil }
        guard let params = request["params"] as? [String: Any],
              let name = params["name"] as? String else {
            return rpcError(id: id, code: -32602, message: "A tool name is required.")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        return ["jsonrpc": "2.0", "id": id, "result": mcpToolCall(name, arguments: arguments)]
    default:
        guard let id else { return nil }
        return rpcError(id: id, code: -32601, message: "Method not found.")
    }
}

private enum MCPInputLine {
    case message(Data)
    case oversized
    case end
}

private var pendingBytes: [UInt8] = []
private var pendingIndex = 0

private func nextInputLine() -> MCPInputLine {
    var message = Data()
    var oversized = false
    var buffer = [UInt8](repeating: 0, count: 4_096)

    while true {
        if pendingIndex >= pendingBytes.count {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count)
            }
            guard count > 0 else {
                if oversized { return .oversized }
                return message.isEmpty ? .end : .message(message)
            }
            pendingBytes = Array(buffer.prefix(count))
            pendingIndex = 0
        }

        let byte = pendingBytes[pendingIndex]
        pendingIndex += 1
        if byte == 10 { return oversized ? .oversized : .message(message) }
        if message.count < LimaQAWire.maximumMessageBytes {
            message.append(byte)
        } else {
            oversized = true
        }
    }
}

while true {
    switch nextInputLine() {
    case .end:
        exit(0)
    case .oversized:
        send(rpcError(id: NSNull(), code: -32700, message: "Oversized JSON-RPC message."))
    case .message(let data):
        guard let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            send(rpcError(id: NSNull(), code: -32700, message: "Invalid JSON-RPC message."))
            continue
        }
        if let response = handle(request) { send(response) }
    }
}
