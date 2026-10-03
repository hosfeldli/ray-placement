import Foundation

/// Explicit, read-only access to Lima Notes for AI Chat. Search returns small
/// excerpts; full content requires a second bounded read by stable note ID.
enum AINotesTools {
    static let definitions: [LimaAIToolDefinition] = [
        LimaAIToolDefinition(
            id: "search_notes",
            name: "search_notes",
            description: "Search local Lima Notes by title and content. Return at most 10 IDs, titles, and short matching excerpts. Does not change or export notes. Use only when the user asks about their notes.",
            parameters: [
                "type": "object",
                "properties": ["query": ["type": "string",
                                         "description": "Words to find in the user's local Lima Notes (1–160 characters)."]],
                "required": ["query"],
                "additionalProperties": false
            ],
            risk: .read
        ),
        LimaAIToolDefinition(
            id: "read_note",
            name: "read_note",
            description: "Read up to 10,000 characters from one local Lima Note by ID returned by search_notes. Supply an offset for later chunks. Does not change the note. Use only when the user asks about their notes.",
            parameters: [
                "type": "object",
                "properties": [
                    "note_id": ["type": "string", "description": "Exact note ID returned by search_notes."],
                    "offset": ["type": ["integer", "null"], "minimum": 0,
                               "description": "Character offset, or null to start at the beginning."],
                    "length": ["type": ["integer", "null"], "minimum": 1, "maximum": 10000,
                               "description": "Number of characters, or null for 8,000."]
                ],
                "required": ["note_id", "offset", "length"],
                "additionalProperties": false
            ],
            risk: .read
        )
    ]

    static let ids: Set<String> = Set(definitions.map(\.id))

    @MainActor
    static func execute(_ call: AIOutputItem, store suppliedStore: NotesStore? = nil) async -> LimaAIToolExecution {
        let store = suppliedStore ?? .shared
        switch call.name {
        case "search_notes":
            guard let query = LimaAIToolRegistry.stringArgument(named: "query", from: call.arguments),
                  !query.isEmpty, query.count <= 160 else {
                return .json(["error": "Notes search needs a query of 1 to 160 characters."], isError: true)
            }
            let notes = store.notes
            return await Task.detached(priority: .utility) {
                let matching = notes.filter {
                    $0.displayTitle.localizedStandardContains(query)
                        || $0.content.localizedStandardContains(query)
                }
                let formatter = ISO8601DateFormatter()
                let results: [[String: Any]] = matching.prefix(10).map { note in
                    let start = note.content.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])?.lowerBound
                        ?? note.content.startIndex
                    let lower = note.content.index(start, offsetBy: -80, limitedBy: note.content.startIndex)
                        ?? note.content.startIndex
                    let upper = note.content.index(lower, offsetBy: 320, limitedBy: note.content.endIndex)
                        ?? note.content.endIndex
                    return [
                        "note_id": note.id.uuidString,
                        "title": note.displayTitle,
                        "excerpt": String(note.content[lower..<upper]),
                        "modified_at": formatter.string(from: note.modifiedAt)
                    ]
                }
                return LimaAIToolExecution.json(["matches": results, "total_matches": matching.count,
                                                  "truncated": matching.count > results.count])
            }.value

        case "read_note":
            guard let rawID = LimaAIToolRegistry.stringArgument(named: "note_id", from: call.arguments),
                  let id = UUID(uuidString: rawID),
                  let note = store.notes.first(where: { $0.id == id }) else {
                return .json(["error": "That local note is unavailable."], isError: true)
            }
            let offset = LimaAIToolRegistry.integerArgument(named: "offset", from: call.arguments) ?? 0
            let length = LimaAIToolRegistry.integerArgument(named: "length", from: call.arguments) ?? 8_000
            guard offset >= 0, offset <= NotesStore.maximumCharactersPerNote,
                  (1...10_000).contains(length) else {
                return .json(["error": "Read Note needs an offset from 0 to 200,000 and a length from 1 to 10,000."], isError: true)
            }
            return await Task.detached(priority: .utility) {
                let content = note.content
                let start = content.index(content.startIndex, offsetBy: min(offset, content.count))
                let end = content.index(start, offsetBy: length, limitedBy: content.endIndex) ?? content.endIndex
                let chunk = String(content[start..<end])
                let nextOffset = offset + chunk.count
                return LimaAIToolExecution.json([
                    "note_id": note.id.uuidString,
                    "title": note.displayTitle,
                    "content": chunk,
                    "offset": offset,
                    "next_offset": nextOffset < content.count ? nextOffset as Any : NSNull(),
                    "total_characters": content.count
                ])
            }.value

        default:
            return .json(["error": "The requested Notes tool is unavailable."], isError: true)
        }
    }
}
