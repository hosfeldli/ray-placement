import Foundation
import RayPlacementCore

/// Explicit, project-relative file tools. An active materialized Project ID is
/// required; ordinary conversations and Scratch never become Projects here.
@MainActor
enum AIProjectFileTools {
    nonisolated static let readIDs: Set<String> = [
        "file_read", "file_read_range", "file_list", "file_tree",
        "file_find", "file_glob", "file_search", "project_file_metadata"
    ]
    nonisolated static let actionIDs: Set<String> = [
        "file_write", "file_patch", "directory_create", "file_move",
        "file_copy", "file_delete", "directory_delete"
    ]
    nonisolated static let ids = readIDs.union(actionIDs)

    private static let project = ["type": "string", "description": "Active materialized Project UUID."]
    private static let path = ["type": "string", "description": "Relative path inside the Project; use . for the root."]

    static let definitions: [LimaAIToolDefinition] = [
        tool("file_read", "Read a bounded UTF-8 file inside an active Project.",
             properties: [:], required: []),
        tool("file_read_range", "Read numbered lines from a Project file.",
             properties: ["start_line": ["type": "integer", "minimum": 1],
                          "length": ["type": "integer", "minimum": 1, "maximum": 400]], required: []),
        tool("file_list", "List immediate entries inside a Project directory.",
             properties: [:], required: []),
        tool("file_tree", "List a bounded Project directory tree.",
             properties: ["max_depth": ["type": "integer", "minimum": 1, "maximum": 8]], required: []),
        tool("file_find", "Find Project files by case-insensitive name fragment.",
             properties: ["query": ["type": "string"]], required: ["query"]),
        tool("file_glob", "Find Project files by a bounded path glob.",
             properties: ["query": ["type": "string"]], required: ["query"]),
        tool("file_search", "Search literal text in bounded Project source files.",
             properties: ["query": ["type": "string"]], required: ["query"]),
        tool("project_file_metadata", "Read a Project path's kind, size, and modification date.",
             properties: [:], required: []),
        tool("file_write", "Create a bounded UTF-8 Project file; replacing an existing file requires overwrite: true.",
             properties: ["content": ["type": "string"], "overwrite": ["type": "boolean"]],
             required: ["content"], risk: .write),
        tool("file_patch", "Replace exactly one occurrence of old_text in a Project file, without changing another file.",
             properties: ["old_text": ["type": "string"], "new_text": ["type": "string"]],
             required: ["old_text", "new_text"], risk: .write),
        tool("directory_create", "Create one Project directory under an existing parent.",
             properties: [:], required: [], risk: .localAction),
        tool("file_move", "Move a Project file or directory to an unused relative destination.",
             properties: ["destination": ["type": "string"]], required: ["destination"], risk: .localAction),
        tool("file_copy", "Copy a Project regular file to an unused relative destination.",
             properties: ["destination": ["type": "string"]], required: ["destination"], risk: .localAction),
        tool("file_delete", "Permanently delete one Project regular file; this cannot delete a directory.",
             properties: [:], required: [], risk: .destructive),
        tool("directory_delete", "Delete one empty Project directory; never recursively delete Project data.",
             properties: [:], required: [], risk: .destructive)
    ]

    private static func tool(_ id: String, _ description: String,
                             properties: [String: Any], required: [String],
                             risk: AILocalToolRisk = .read) -> LimaAIToolDefinition {
        let all = ["project_id": project, "path": path].merging(properties) { _, new in new }
        return LimaAIToolDefinition(
            id: id, name: id, description: description,
            parameters: ["type": "object", "properties": all,
                         "required": ["project_id", "path"] + required,
                         "additionalProperties": false],
            risk: risk, actionCategory: risk == .read ? nil : .localFiles
        )
    }

    static func execute(_ call: AIOutputItem, approvalGranted: Bool,
                        manager suppliedManager: AIProjectManager? = nil,
                        filesystem suppliedFilesystem: AIProjectFilesystem? = nil,
                        actionPolicy suppliedPolicy: AIComputerActionPolicy? = nil,
                        toolAccessMode: LimaAIToolAccessMode? = nil) async -> LimaAIToolExecution {
        guard let definition = definitions.first(where: { $0.id == call.name }),
              let raw = call.arguments, raw.utf8.count <= 1_200_000,
              let data = raw.data(using: .utf8),
              let arguments = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              Set(arguments.keys).isSubset(of: Set((definition.parameters["properties"] as? [String: Any] ?? [:]).keys)),
              case .string(let rawID)? = arguments["project_id"],
              let id = UUID(uuidString: rawID),
              case .string? = arguments["path"] else {
            return .json(["error": "Invalid project-relative file-tool arguments."], isError: true)
        }
        let policy = suppliedPolicy ?? .shared
        guard policy.permits(definition, approvalGranted: approvalGranted,
                             toolAccessMode: toolAccessMode ?? LimaAIToolStore.shared.accessMode) else {
            return .json(["error": "Project file changes are disabled or still need approval."], isError: true)
        }
        let manager = suppliedManager ?? .shared
        guard let project = manager.store.project(id: id),
              project.lifecycle == .active, project.workState == .materialized else {
            return .json(["error": "Use an active materialized Project ID for file tools."], isError: true)
        }
        let filesystem = suppliedFilesystem ?? AIProjectFilesystem(paths: manager.paths)
        do {
            let result = try await filesystem.execute(definition.id, projectID: id, arguments: arguments)
            let encoded = try JSONEncoder().encode(result)
            return .json(try JSONSerialization.jsonObject(with: encoded))
        } catch {
            return .json(["error": error.localizedDescription], isError: true)
        }
    }
}
