import Foundation
import RayPlacementCore

/// Explicit durable-work primitives. Research, chat, and temporary commands
/// never call these automatically; the agent chooses project_create only when
/// the requested task needs a continued local working tree.
@MainActor
enum AIProjectTools {
    nonisolated static let readIDs: Set<String> = ["project_list", "project_search", "project_info"]
    private static var discoveredRunIDs: Set<UUID> = []
    private static var newProjectChoiceQuestionIDs: [UUID: UUID] = [:]

    static func recordUserChoice(_ response: AIUserQuestionResponse,
                                 for question: AIUserQuestion) {
        guard question.purpose == .projectResolution,
              question.kind == .singleChoice,
              response.isValid(for: question),
              response.selectedOptionIDs == ["create_new_project"],
              question.options.contains(where: {
                  $0.id == "create_new_project"
                      && $0.label.localizedCaseInsensitiveCompare("Create a new project") == .orderedSame
              }) else { return }
        newProjectChoiceQuestionIDs[question.runID] = question.id
    }

    static func endDiscovery(for runID: UUID) {
        discoveredRunIDs.remove(runID)
        newProjectChoiceQuestionIDs.removeValue(forKey: runID)
    }
    nonisolated static let actionIDs: Set<String> = [
        "project_create", "project_open", "project_rename",
        "project_archive", "project_restore", "project_remove", "project_recover"
    ]
    nonisolated static let ids = readIDs.union(actionIDs)

    static let definitions: [LimaAIToolDefinition] = [
        definition("project_list",
                   "List active Projects. Optionally include archived or recently removed Projects; listing never creates a directory.",
                   properties: ["include_archived": ["type": "boolean"],
                                "include_removed": ["type": "boolean"]], required: []),
        definition("project_search",
                   "Search existing active and archived Projects by registry metadata before creating durable work. Removed Projects require include_removed=true and explicit intent.",
                   properties: ["query": ["type": "string"],
                                "include_archived": ["type": "boolean"],
                                "include_removed": ["type": "boolean"]], required: ["query"]),
        definition("project_info",
                   "Read one Project\'s lifecycle, materialized-work state, and managed directory if present.",
                   properties: ["project_id": ["type": "string"]], required: ["project_id"]),
        definition("project_create",
                   "Create a durable local Project only after project_list or project_search in this run. If a matching active or archived Project exists, ask with request_user_input using purpose=project_resolution and an option id=create_new_project, label=Create a new project; pass the returned question_id as user_choice_question_id only if the user chose it. Never create for informational or transient work.",
                   properties: ["name": ["type": "string"], "instructions": ["type": "string"],
                                "user_choice_question_id": ["type": "string"]],
                   required: ["name"], action: true),
        definition("project_open",
                   "Attach an active Project to the current AI conversation and return its working directory, if materialized.",
                   properties: ["project_id": ["type": "string"]], required: ["project_id"], action: true),
        definition("project_rename",
                   "Rename an existing Project without changing its directory or files.",
                   properties: ["project_id": ["type": "string"], "name": ["type": "string"]],
                   required: ["project_id", "name"], action: true),
        definition("project_archive",
                   "Stop known Project-owned sessions and archive a Project reversibly. Preserve files, Git history, artifacts, and context.",
                   properties: ["project_id": ["type": "string"]], required: ["project_id"], action: true),
        definition("project_restore",
                   "Restore an archived Project to the active list and move its managed tree back into Projects.",
                   properties: ["project_id": ["type": "string"]], required: ["project_id"], action: true),
        definition("project_remove",
                   "Remove a Project from Lima's normal registry and move managed files into Recently Removed. Never permanently delete Project data.",
                   properties: ["project_id": ["type": "string"]], required: ["project_id"], action: true),
        definition("project_recover",
                   "Recover a recently removed Project, including its preserved managed files and context.",
                   properties: ["project_id": ["type": "string"]], required: ["project_id"], action: true)
    ]

    private static func definition(_ name: String, _ description: String,
                                   properties: [String: Any], required: [String],
                                   action: Bool = false) -> LimaAIToolDefinition {
        LimaAIToolDefinition(
            id: name, name: name, description: description,
            parameters: ["type": "object", "properties": properties, "required": required,
                         "additionalProperties": false],
            risk: action ? .localAction : .read,
            actionCategory: action ? .localFiles : nil
        )
    }

    static func execute(_ call: AIOutputItem, approvalGranted: Bool,
                        conversationID: UUID?,
                        manager suppliedManager: AIProjectManager? = nil,
                        conversationStore suppliedConversations: AIConversationStore? = nil,
                        actionPolicy suppliedPolicy: AIComputerActionPolicy? = nil,
                        toolAccessMode: LimaAIToolAccessMode? = nil,
                        runID: UUID? = nil) async -> LimaAIToolExecution {
        guard let definition = definitions.first(where: { $0.id == call.name }) else {
            return failure("Unknown Project tool.")
        }
        let manager = suppliedManager ?? .shared
        let conversations = suppliedConversations ?? .shared
        let policy = suppliedPolicy ?? .shared
        guard policy.permits(definition, approvalGranted: approvalGranted,
                             toolAccessMode: toolAccessMode ?? LimaAIToolStore.shared.accessMode) else {
            return failure("Project changes are disabled or still need approval.")
        }
        let raw = call.arguments ?? "{}"
        guard raw.utf8.count <= 8_192, let data = raw.data(using: .utf8),
              let arguments = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              Set(arguments.keys).isSubset(of: Set((definition.parameters["properties"] as? [String: Any] ?? [:]).keys)) else {
            return failure("Invalid Project tool arguments.")
        }
        func string(_ key: String) -> String? {
            guard case .string(let value)? = arguments[key] else { return nil }
            return value
        }
        func projectID() -> UUID? { string("project_id").flatMap(UUID.init(uuidString:)) }
        func bool(_ key: String, default defaultValue: Bool) -> Bool? {
            switch arguments[key] {
            case .none, .some(.null): return defaultValue
            case .some(.bool(let value)): return value
            default: return nil
            }
        }
        func payload(_ project: AIProject) -> [String: Any] {
            var result: [String: Any] = [
                "project_id": project.id.uuidString,
                "name": project.name,
                "work_state": project.workState.rawValue,
                "lifecycle": project.lifecycle.rawValue,
                "origin": (project.origin?.rawValue as Any?) ?? NSNull(),
                "directory": (manager.directory(for: project)?.path as Any?) ?? NSNull(),
                "repository": sanitizedRepository(project.repository?.remoteURL) as Any? ?? NSNull(),
                "stack": Array(project.detectedStack.prefix(12)),
                "summary": String((project.instructions.split(whereSeparator: \.isNewline).first.map(String.init) ?? "").prefix(160)),
                "last_opened_at": project.lastOpenedAt?.timeIntervalSince1970 as Any? ?? NSNull()
            ]
            if let archivedAt = project.archivedAt {
                result["archived_at"] = archivedAt.timeIntervalSince1970
            }
            return result
        }
        do {
            switch call.name {
            case "project_list":
                guard let archived = bool("include_archived", default: false),
                      let removed = bool("include_removed", default: false) else {
                    return failure("Project list flags must be booleans.")
                }
                var result: [String: Any] = [
                    "active": manager.store.activeProjects.map(payload),
                    "archived_count": manager.store.archivedProjects.count
                ]
                if archived { result["archived"] = manager.store.archivedProjects.map(payload) }
                if removed {
                    result["recently_removed"] = manager.store.removedProjects.map {
                        ["project": payload($0.project), "removed_at": $0.removedAt.timeIntervalSince1970] as [String: Any]
                    }
                }
                if let runID { discoveredRunIDs.insert(runID) }
                return .json(result)
            case "project_search":
                guard let query = string("query")?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !query.isEmpty, query.count <= 160,
                      let archived = bool("include_archived", default: true),
                      let removed = bool("include_removed", default: false) else {
                    return failure("Supply a query of at most 160 characters and boolean search flags.")
                }
                let matches = await AIProjectResolver.shared.search(
                    query: query, projects: manager.store.projects,
                    removed: manager.store.removedProjects,
                    includeArchived: archived, includeRemoved: removed
                )
                let resolution = await AIProjectResolver.shared.resolve(
                    intent: .durableExistingWork, query: query,
                    projects: manager.store.projects.filter { archived || $0.lifecycle == .active },
                    removed: manager.store.removedProjects,
                    includeRemoved: removed
                )
                if let runID { discoveredRunIDs.insert(runID) }
                return .json(["matches": matches.map(candidatePayload),
                              "resolution": resolutionPayload(resolution),
                              "removed_included": removed])
            case "project_info":
                guard let id = projectID() else { return failure("A valid project_id is required.") }
                if let project = manager.store.project(id: id) { return .json(payload(project)) }
                if let record = manager.store.removedProject(id: id) {
                    return .json(["project": payload(record.project), "removed": true,
                                  "removed_at": record.removedAt.timeIntervalSince1970])
                }
                throw AIProjectManagerError.unavailable
            case "project_create":
                guard let conversationID, var conversation = conversations.conversation(id: conversationID) else {
                    return failure("Project creation needs the originating conversation.")
                }
                guard let name = string("name") else { return failure("A Project name is required.") }
                guard let runID, discoveredRunIDs.contains(runID) else {
                    return .json(["error": ["code": "project_discovery_required",
                                            "message": "Call project_list or project_search before creating a Project in this run."]], isError: true)
                }
                if let request = conversation.messages.last(where: { $0.role == .user })?.text {
                    let intent = AIWorkIntent.classify(request)
                    if intent == .informational || intent == .transient {
                        return .json(["error": ["code": "project_not_needed",
                                                "message": "This request is informational or transient. Use no Project or Scratch instead."]], isError: true)
                    }
                }
                // Search the original task as well as the proposed name. A model
                // must not evade reuse by inventing an unrelated new name.
                let requestedWork = conversation.messages.last(where: { $0.role == .user })?.text
                let queries = [requestedWork, name].compactMap { $0 }
                var matchingResolution: AIProjectResolution?
                for query in queries {
                    let resolution = await AIProjectResolver.shared.resolve(
                        intent: .durableNewWork, query: query, projects: manager.store.projects
                    )
                    switch resolution {
                    case .existing, .archived, .removed, .ambiguous:
                        matchingResolution = resolution
                    case .createNew, .noProjectNeeded:
                        break
                    }
                    if matchingResolution != nil { break }
                }
                let choiceID = string("user_choice_question_id")
                    .flatMap(UUID.init(uuidString:))
                let userChoseNew = choiceID != nil
                    && newProjectChoiceQuestionIDs[runID] == choiceID
                if let matchingResolution, !userChoseNew {
                    return .json(["error": ["code": "matching_project_exists",
                                            "message": "Inspect or open the existing Project, or ask the user to choose a new one using request_user_input."],
                                  "resolution": resolutionPayload(matchingResolution)], isError: true)
                }
                if string("user_choice_question_id") != nil && !userChoseNew {
                    return .json(["error": ["code": "invalid_project_choice",
                                            "message": "The create-new choice was not answered in this run."]], isError: true)
                }
                let instructions = string("instructions") ?? ""
                let project = try manager.create(name: name, instructions: instructions)
                newProjectChoiceQuestionIDs.removeValue(forKey: runID)
                conversation.projectID = project.id
                conversation.lastResponseID = nil
                if !conversations.update(conversation) {
                    return .json(["project": payload(project), "attached_to_conversation": false,
                                  "error": "The Project was created, but the conversation could not be attached."], isError: true)
                }
                return .json(["project": payload(project), "attached_to_conversation": true,
                              "post_action_verified": FileManager.default.fileExists(atPath: manager.paths.project(project.id).path)])
            case "project_open":
                guard let id = projectID(), let conversationID,
                      var conversation = conversations.conversation(id: conversationID) else {
                    return failure("A valid project_id and originating conversation are required.")
                }
                let project = try manager.open(id)
                conversation.projectID = id
                conversation.lastResponseID = nil
                guard conversations.update(conversation) else {
                    return failure("The Project could not be attached to this conversation.")
                }
                return .json(["project": payload(project), "attached_to_conversation": true])
            case "project_rename":
                guard let id = projectID(), let name = string("name") else {
                    return failure("A valid project_id and name are required.")
                }
                return .json(payload(try manager.rename(id, to: name)))
            case "project_archive":
                guard let id = projectID() else { return failure("A valid project_id is required.") }
                return .json(payload(try await manager.archive(id)))
            case "project_restore":
                guard let id = projectID() else { return failure("A valid project_id is required.") }
                return .json(payload(try manager.restore(id)))
            case "project_remove":
                guard let id = projectID() else { return failure("A valid project_id is required.") }
                let record = try await manager.remove(id)
                return .json(["project_id": record.id.uuidString, "removed": true,
                              "data_deleted": false,
                              "recovery_directory": manager.paths.removedProject(record.id).path])
            case "project_recover":
                guard let id = projectID() else { return failure("A valid project_id is required.") }
                return .json(payload(try manager.recover(id)))
            default:
                return failure("Unknown Project tool.")
            }
        } catch AIProjectManagerError.runningProcesses {
            return .json(["error": [
                "code": "project_has_running_processes", "recoverable": true,
                "suggested_tools": ["terminal_status", "terminal_terminate"]
            ]], isError: true)
        } catch {
            return failure(error.localizedDescription)
        }
    }

    private static func candidatePayload(_ candidate: AIProjectCandidate) -> [String: Any] {
        ["project_id": candidate.projectID.uuidString,
         "name": candidate.name,
         "lifecycle": candidate.lifecycle,
         "score": candidate.score,
         "reasons": candidate.reasons]
    }

    private static func resolutionPayload(_ resolution: AIProjectResolution) -> [String: Any] {
        switch resolution {
        case .existing(let id, let confidence):
            return ["kind": "existing", "project_id": id.uuidString, "confidence": confidence]
        case .archived(let id, let confidence):
            return ["kind": "archived", "project_id": id.uuidString, "confidence": confidence,
                    "next_action": "Ask whether to restore this Project or create a new one."]
        case .removed(let id, let confidence):
            return ["kind": "removed", "project_id": id.uuidString, "confidence": confidence,
                    "next_action": "Ask whether to recover this removed Project or create a new one."]
        case .ambiguous(let candidates):
            return ["kind": "ambiguous", "candidates": candidates.map(candidatePayload),
                    "next_action": "Ask the user to choose a Project."]
        case .createNew(let name):
            return ["kind": "create_new", "suggested_name": name]
        case .noProjectNeeded:
            return ["kind": "no_project_needed"]
        }
    }

    private static func sanitizedRepository(_ remote: String?) -> String? {
        guard let remote = remote?.trimmingCharacters(in: .whitespacesAndNewlines),
              !remote.isEmpty else { return nil }
        if var components = URLComponents(string: remote), components.scheme != nil {
            guard let scheme = components.scheme?.lowercased(),
                  ["http", "https", "ssh", "git"].contains(scheme),
                  components.host != nil else { return nil }
            components.user = nil
            components.password = nil
            components.query = nil
            components.fragment = nil
            return components.string.map { String($0.prefix(240)) }
        }
        // Git's scp-style remotes can contain a username or credential before
        // @. Return only a validated host/path, never the original credential.
        let withoutUser = remote.split(separator: "@").last.map(String.init) ?? remote
        guard let colon = withoutUser.firstIndex(of: ":") else { return nil }
        let host = String(withoutUser[..<colon])
        let rawPath = String(withoutUser[withoutUser.index(after: colon)...])
        let path = rawPath.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? ""
        let allowedHost = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        guard !host.isEmpty, !path.isEmpty,
              host.unicodeScalars.allSatisfy({ allowedHost.contains($0) }),
              !path.contains("@") else { return nil }
        return String((host + "/" + path).prefix(240))
    }

    private static func failure(_ message: String) -> LimaAIToolExecution {
        .json(["error": message], isError: true)
    }
}
