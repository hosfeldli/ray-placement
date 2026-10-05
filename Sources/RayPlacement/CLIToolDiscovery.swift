import Foundation

enum CLIToolDiscovery {
    static let name = "lima_find_tools"
    static let definition = LimaAIToolDefinition(
        id: name, name: name,
        description: "Find available Lima tools and their complete argument schemas. Search by capability, name or description; use an empty query to browse. Tools returned by this function can be requested directly by name through the same Lima tool envelope. Use next_offset for more results.",
        parameters: [
            "type": "object",
            "properties": ["query": ["type": "string"], "offset": ["type": "integer", "minimum": 0]],
            "required": ["query", "offset"], "additionalProperties": false
        ],
        risk: .read
    )

    static func execute(_ call: AIOutputItem, allowedTools: [LimaAIToolDefinition]) -> LimaAIToolExecution {
        guard let raw = call.arguments, raw.utf8.count <= 4096,
              let args = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              Set(args.keys) == ["query", "offset"],
              let query = args["query"] as? String, query.count <= 300,
              let offset = args["offset"] as? Int, offset >= 0 else {
            return .json(["error": "Supply a query and a nonnegative offset."], isError: true)
        }
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let matches = allowedTools.filter { tool in
            guard tool.name != name, tool.responsePayload != nil else { return false }
            let text = (tool.name + " " + tool.description).lowercased()
            return terms.allSatisfy { text.contains($0) }
        }
        guard offset <= matches.count else {
            return .json(["error": "The tool-list offset is out of range."], isError: true)
        }
        var page: [[String: Any]] = []
        var size = 0
        for tool in matches.dropFirst(offset).prefix(8) {
            guard let payload = tool.responsePayload,
                  let data = try? JSONSerialization.data(withJSONObject: payload) else { continue }
            guard data.count <= 48_000 else {
                return .json(["error": "This tool's schema is too large for CLI chat.", "tool": tool.name], isError: true)
            }
            if size + data.count > 48_000 { break }
            page.append(payload)
            size += data.count
        }
        let next = offset + page.count
        return .json(["tools": page, "total": matches.count,
                      "next_offset": next < matches.count ? next as Any : NSNull()])
    }
}
