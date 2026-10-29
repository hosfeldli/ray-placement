import Foundation
import Testing
@testable import RayPlacement

private func projectToolCall(_ name: String, _ arguments: [String: Any] = [:]) throws -> AIOutputItem {
    let data = try JSONSerialization.data(withJSONObject: arguments)
    return AIOutputItem(
        phase: .completed, apiType: "function_call", callID: UUID().uuidString,
        name: name, arguments: String(decoding: data, as: UTF8.self)
    )
}

private func toolFields(_ result: LimaAIToolExecution) throws -> [String: Any] {
    let data = try #require(result.output.data(using: .utf8))
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test @MainActor func projectCreateRejectsInformationalChatEvenAfterDiscovery() async throws {
    let projects = AIWorkspaceStore(fixtures: [])
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LimaInformationalProjectGuard-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = AIProjectManager(store: projects, paths: AIWorkspacePaths(root: root))
    let conversation = AIConversation(title: "Explain app", messages: [
        AIChatMessage(role: .user, text: "Could you explain my existing app?")
    ])
    let conversations = AIConversationStore(fixtures: [conversation])
    let runID = UUID()
    defer { AIProjectTools.endDiscovery(for: runID) }
    let discovery = await AIProjectTools.execute(
        try projectToolCall("project_list"), approvalGranted: false,
        conversationID: conversation.id, manager: manager,
        conversationStore: conversations, toolAccessMode: .fullControl,
        runID: runID
    )
    #expect(!discovery.isError)
    let blocked = await AIProjectTools.execute(
        try projectToolCall("project_create", ["name": "Unwanted App Project"]),
        approvalGranted: false, conversationID: conversation.id, manager: manager,
        conversationStore: conversations, toolAccessMode: .fullControl,
        runID: runID
    )
    #expect(((try toolFields(blocked))["error"] as? [String: Any])?["code"] as? String
            == "project_not_needed")
    #expect(projects.projects.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: manager.paths.projects.path))
}

@Test @MainActor func projectCreateUsesOriginalTaskAndRequiresAnsweredChoiceForConflicts() async throws {
    let existing = AIProject(name: "Finance Dashboard")
    let store = AIWorkspaceStore(fixtures: [existing])
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LimaProjectTaskResolution-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = AIProjectManager(store: store, paths: AIWorkspacePaths(root: root))
    let conversation = AIConversation(title: "Dashboard work", messages: [
        AIChatMessage(role: .user, text: "Add budgeting charts to my Finance Dashboard")
    ])
    let conversations = AIConversationStore(fixtures: [conversation])
    let suite = "LimaProjectTaskResolutionPolicy.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let policy = AIComputerActionPolicy(defaults: defaults)
    policy.setAccess(.askEveryTime, for: .localFiles)
    let runID = UUID()
    defer { AIProjectTools.endDiscovery(for: runID) }
    let discovery = await AIProjectTools.execute(
        try projectToolCall("project_search", ["query": "Finance Dashboard"]),
        approvalGranted: false, conversationID: conversation.id, manager: manager,
        conversationStore: conversations, actionPolicy: policy,
        toolAccessMode: .automatic, runID: runID
    )
    #expect(!discovery.isError)

    let proposed = try projectToolCall("project_create", ["name": "Budget Charts"])
    let blocked = await AIProjectTools.execute(
        proposed, approvalGranted: true, conversationID: conversation.id,
        manager: manager, conversationStore: conversations, actionPolicy: policy,
        toolAccessMode: .automatic, runID: runID
    )
    #expect(((try toolFields(blocked))["error"] as? [String: Any])?["code"] as? String
            == "matching_project_exists")
    #expect(store.projects.count == 1)

    let question = try #require(AIUserQuestionTools.parse(
        #"{"kind":"single_choice","purpose":"project_resolution","question":"Use the existing Finance Dashboard or start a separate project?","options":[{"id":"existing","label":"Use Finance Dashboard"},{"id":"create_new_project","label":"Create a new project"}]}"#,
        runID: runID
    ))
    let createCall = try projectToolCall("project_create", [
        "name": "Budget Charts", "user_choice_question_id": question.id.uuidString
    ])
    let unconfirmed = await AIProjectTools.execute(
        createCall, approvalGranted: true, conversationID: conversation.id,
        manager: manager, conversationStore: conversations, actionPolicy: policy,
        toolAccessMode: .automatic, runID: runID
    )
    #expect(((try toolFields(unconfirmed))["error"] as? [String: Any])?["code"] as? String
            == "matching_project_exists")

    AIProjectTools.recordUserChoice(
        AIUserQuestionResponse(questionID: question.id,
            selectedOptionIDs: ["existing"], text: nil), for: question
    )
    let choseExisting = await AIProjectTools.execute(
        createCall, approvalGranted: true, conversationID: conversation.id,
        manager: manager, conversationStore: conversations, actionPolicy: policy,
        toolAccessMode: .automatic, runID: runID
    )
    #expect(choseExisting.isError)
    #expect(store.projects.count == 1)

    AIProjectTools.recordUserChoice(
        AIUserQuestionResponse(questionID: question.id,
            selectedOptionIDs: ["create_new_project"], text: nil), for: question
    )
    let created = await AIProjectTools.execute(
        createCall, approvalGranted: true, conversationID: conversation.id,
        manager: manager, conversationStore: conversations, actionPolicy: policy,
        toolAccessMode: .automatic, runID: runID
    )
    #expect(!created.isError)
    #expect(store.projects.count == 2)
    #expect(conversations.conversation(id: conversation.id)?.projectID
            == store.projects.first(where: { $0.name == "Budget Charts" })?.id)

    let reusedChoice = await AIProjectTools.execute(
        try projectToolCall("project_create", [
            "name": "Budget Charts Again", "user_choice_question_id": question.id.uuidString
        ]),
        approvalGranted: true, conversationID: conversation.id,
        manager: manager, conversationStore: conversations, actionPolicy: policy,
        toolAccessMode: .automatic, runID: runID
    )
    #expect(reusedChoice.isError)
    #expect(store.projects.count == 2)
}

@Test @MainActor func projectSearchDispatchRequiresExplicitRemovedDiscoveryAndRedactsRemotes() async throws {
    let active = AIProject(name: "Lima", instructions: "macOS productivity application",
        repository: AIRepositoryMetadata(
            remoteURL: "https://api-secret@github.com/hosfeldli/ray-placement.git?token=query-secret",
            branch: "main"),
        detectedStack: ["Swift", "SwiftUI"])
    let archived = AIProject(name: "Old Portfolio", lifecycle: .archived)
    let removedProject = AIProject(name: "Removed Tracker",
        repository: AIRepositoryMetadata(
            remoteURL: "secret-user@git.example.com:team/tracker.git?token=removed-secret",
            branch: nil))
    let removed = AIRemovedProject(project: removedProject, removedAt: Date())
    let store = AIWorkspaceStore(fixtures: [active, archived], removedProjects: [removed])
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LimaProjectSearch-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = AIProjectManager(store: store, paths: AIWorkspacePaths(root: root))
    let conversation = AIConversation(title: "Find existing work")
    let conversations = AIConversationStore(fixtures: [conversation])
    let suite = "LimaProjectSearchPolicy.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let policy = AIComputerActionPolicy(defaults: defaults)
    policy.setAccess(.askEveryTime, for: .localFiles)
    let runID = UUID()
    let separateRunID = UUID()
    defer {
        AIProjectTools.endDiscovery(for: runID)
        AIProjectTools.endDiscovery(for: separateRunID)
    }

    let listed = await AIProjectTools.execute(try projectToolCall("project_list"),
        approvalGranted: false, conversationID: conversation.id, manager: manager,
        conversationStore: conversations, actionPolicy: policy,
        toolAccessMode: .automatic, runID: runID)
    #expect(!listed.isError)
    let list = try toolFields(listed)
    #expect((list["archived_count"] as? Int) == 1)
    #expect(list["recently_removed"] == nil)
    let activeList = try #require(list["active"] as? [[String: Any]])
    let remote = try #require(activeList.first?["repository"] as? String)
    #expect(remote.contains("github.com/hosfeldli/ray-placement.git"))
    #expect(!remote.contains("api-secret") && !remote.contains("query-secret"))

    let ordinary = await AIProjectTools.execute(
        try projectToolCall("project_search", ["query": "Removed Tracker"]),
        approvalGranted: false, conversationID: conversation.id, manager: manager,
        conversationStore: conversations, actionPolicy: policy,
        toolAccessMode: .automatic, runID: runID)
    #expect(((try toolFields(ordinary))["matches"] as? [[String: Any]])?.isEmpty == true)
    let explicit = await AIProjectTools.execute(
        try projectToolCall("project_search", [
            "query": "Removed Tracker", "include_removed": true
        ]),
        approvalGranted: false, conversationID: conversation.id, manager: manager,
        conversationStore: conversations, actionPolicy: policy,
        toolAccessMode: .automatic, runID: runID)
    let explicitFields = try toolFields(explicit)
    let matches = try #require(explicitFields["matches"] as? [[String: Any]])
    #expect(matches.first?["project_id"] as? String == removed.id.uuidString)
    #expect((explicitFields["resolution"] as? [String: Any])?["kind"] as? String == "removed")
    let removedList = await AIProjectTools.execute(
        try projectToolCall("project_list", ["include_removed": true]),
        approvalGranted: false, conversationID: conversation.id, manager: manager,
        conversationStore: conversations, actionPolicy: policy,
        toolAccessMode: .automatic, runID: runID)
    let recoveredRemote = try #require(
        (((try toolFields(removedList))["recently_removed"] as? [[String: Any]])?
            .first?["project"] as? [String: Any])?["repository"] as? String
    )
    #expect(recoveredRemote == "git.example.com/team/tracker.git")
    #expect(!recoveredRemote.contains("secret") && !recoveredRemote.contains("token"))

    let archivedSearch = await AIProjectTools.execute(
        try projectToolCall("project_search", ["query": "Old Portfolio"]),
        approvalGranted: false, conversationID: conversation.id, manager: manager,
        conversationStore: conversations, actionPolicy: policy,
        toolAccessMode: .automatic, runID: runID)
    #expect(((try toolFields(archivedSearch))["resolution"] as? [String: Any])?["kind"] as? String == "archived")

    let duplicate = await AIProjectTools.execute(
        try projectToolCall("project_create", ["name": "Lima"]),
        approvalGranted: true, conversationID: conversation.id, manager: manager,
        conversationStore: conversations, actionPolicy: policy,
        toolAccessMode: .automatic, runID: runID)
    #expect(duplicate.isError)
    #expect(((try toolFields(duplicate))["error"] as? [String: Any])?["code"] as? String == "matching_project_exists")
    let undiscoveredRun = await AIProjectTools.execute(
        try projectToolCall("project_create", ["name": "New Project"]),
        approvalGranted: true, conversationID: conversation.id, manager: manager,
        conversationStore: conversations, actionPolicy: policy,
        toolAccessMode: .automatic, runID: separateRunID)
    #expect(((try toolFields(undiscoveredRun))["error"] as? [String: Any])?["code"] as? String == "project_discovery_required")
    #expect(store.projects.count == 2)
}

@Test @MainActor func projectToolDispatchRequiresApprovalAndPreservesLifecycleData() async throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("LimaProjectToolDispatch-\(UUID().uuidString)", isDirectory: true)
    defer { try? files.removeItem(at: root) }
    let paths = AIWorkspacePaths(root: root)
    let store = AIWorkspaceStore(fixtures: [])
    let manager = AIProjectManager(store: store, paths: paths)
    let conversation = AIConversation(title: "Build a dashboard")
    let conversations = AIConversationStore(fixtures: [conversation])
    let suite = "LimaProjectToolPolicy.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let policy = AIComputerActionPolicy(defaults: defaults)
    let create = try projectToolCall("project_create", ["name": "Dashboard"])
    let runID = UUID()
    defer { AIProjectTools.endDiscovery(for: runID) }

    let disabled = await AIProjectTools.execute(create, approvalGranted: true,
        conversationID: conversation.id, manager: manager, conversationStore: conversations,
        actionPolicy: policy, toolAccessMode: .automatic)
    #expect(disabled.isError)
    #expect(store.projects.isEmpty)
    #expect(!files.fileExists(atPath: paths.projects.path))

    policy.setAccess(.askEveryTime, for: .localFiles)
    let unapproved = await AIProjectTools.execute(create, approvalGranted: false,
        conversationID: conversation.id, manager: manager, conversationStore: conversations,
        actionPolicy: policy, toolAccessMode: .automatic)
    #expect(unapproved.isError)
    #expect(store.projects.isEmpty)

    let beforeDiscovery = await AIProjectTools.execute(create, approvalGranted: true,
        conversationID: conversation.id, manager: manager, conversationStore: conversations,
        actionPolicy: policy, toolAccessMode: .automatic, runID: runID)
    #expect(beforeDiscovery.isError)
    #expect(store.projects.isEmpty)
    let discovery = await AIProjectTools.execute(try projectToolCall("project_list"),
        approvalGranted: false, conversationID: conversation.id, manager: manager,
        conversationStore: conversations, actionPolicy: policy,
        toolAccessMode: .automatic, runID: runID)
    #expect(!discovery.isError)
    let created = await AIProjectTools.execute(create, approvalGranted: true,
        conversationID: conversation.id, manager: manager, conversationStore: conversations,
        actionPolicy: policy, toolAccessMode: .automatic, runID: runID)
    #expect(!created.isError)
    let creation = try toolFields(created)
    let projectFields = try #require(creation["project"] as? [String: Any])
    let id = try #require(UUID(uuidString: projectFields["project_id"] as? String ?? ""))
    #expect(conversations.conversation(id: conversation.id)?.projectID == id)
    #expect(store.project(id: id)?.workState == .materialized)
    #expect(files.fileExists(atPath: paths.project(id).path))

    let file = paths.project(id).appendingPathComponent("README.md")
    try Data("# Dashboard".utf8).write(to: file)
    let archive = await AIProjectTools.execute(
        try projectToolCall("project_archive", ["project_id": id.uuidString]),
        approvalGranted: true, conversationID: conversation.id, manager: manager,
        conversationStore: conversations, actionPolicy: policy, toolAccessMode: .automatic)
    #expect(!archive.isError)
    #expect(store.project(id: id)?.lifecycle == .archived)
    #expect(files.fileExists(atPath: paths.project(id, lifecycle: .archived)
        .appendingPathComponent("README.md").path))

    let restore = await AIProjectTools.execute(
        try projectToolCall("project_restore", ["project_id": id.uuidString]),
        approvalGranted: true, conversationID: conversation.id, manager: manager,
        conversationStore: conversations, actionPolicy: policy, toolAccessMode: .automatic)
    #expect(!restore.isError)
    #expect(files.fileExists(atPath: file.path))

    let remove = await AIProjectTools.execute(
        try projectToolCall("project_remove", ["project_id": id.uuidString]),
        approvalGranted: true, conversationID: conversation.id, manager: manager,
        conversationStore: conversations, actionPolicy: policy, toolAccessMode: .automatic)
    #expect(!remove.isError)
    #expect((try toolFields(remove))["data_deleted"] as? Bool == false)
    #expect(store.project(id: id) == nil)
    #expect(files.fileExists(atPath: paths.removedProject(id)
        .appendingPathComponent("README.md").path))

    let recover = await AIProjectTools.execute(
        try projectToolCall("project_recover", ["project_id": id.uuidString]),
        approvalGranted: true, conversationID: conversation.id, manager: manager,
        conversationStore: conversations, actionPolicy: policy, toolAccessMode: .automatic)
    #expect(!recover.isError)
    #expect(store.project(id: id)?.lifecycle == .active)
    #expect(try String(contentsOf: file, encoding: .utf8) == "# Dashboard")
}

@Test @MainActor func projectFileToolDispatchEnforcesPolicyScopeAndTraversal() async throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("LimaProjectFileDispatch-\(UUID().uuidString)", isDirectory: true)
    defer { try? files.removeItem(at: root) }
    let paths = AIWorkspacePaths(root: root)
    let store = AIWorkspaceStore(fixtures: [])
    let manager = AIProjectManager(store: store, paths: paths)
    let project = try manager.create(name: "Code")
    let suite = "LimaProjectFilePolicy.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let policy = AIComputerActionPolicy(defaults: defaults)
    let write = try projectToolCall("file_write", [
        "project_id": project.id.uuidString, "path": "main.swift",
        "content": "print(\"ready\")\n"
    ])
    let disabled = await AIProjectFileTools.execute(write, approvalGranted: true,
        manager: manager, actionPolicy: policy, toolAccessMode: .automatic)
    #expect(disabled.isError)
    policy.setAccess(.askEveryTime, for: .localFiles)
    let unapproved = await AIProjectFileTools.execute(write, approvalGranted: false,
        manager: manager, actionPolicy: policy, toolAccessMode: .automatic)
    #expect(unapproved.isError)
    let approved = await AIProjectFileTools.execute(write, approvalGranted: true,
        manager: manager, actionPolicy: policy, toolAccessMode: .automatic)
    #expect(!approved.isError)

    let read = await AIProjectFileTools.execute(
        try projectToolCall("file_read", ["project_id": project.id.uuidString, "path": "main.swift"]),
        approvalGranted: false, manager: manager, actionPolicy: policy,
        toolAccessMode: .automatic)
    #expect(!read.isError)
    #expect((try toolFields(read))["content"] as? String == "print(\"ready\")\n")

    let external = root.appendingPathComponent("outside.txt")
    try Data("private".utf8).write(to: external)
    let traversal = await AIProjectFileTools.execute(
        try projectToolCall("file_write", [
            "project_id": project.id.uuidString, "path": "../outside.txt",
            "content": "changed", "overwrite": true
        ]),
        approvalGranted: true, manager: manager, actionPolicy: policy,
        toolAccessMode: .automatic)
    #expect(traversal.isError)
    #expect(try String(contentsOf: external, encoding: .utf8) == "private")

    _ = try await manager.archive(project.id)
    let archivedRead = await AIProjectFileTools.execute(
        try projectToolCall("file_read", ["project_id": project.id.uuidString, "path": "main.swift"]),
        approvalGranted: false, manager: manager, actionPolicy: policy,
        toolAccessMode: .automatic)
    #expect(archivedRead.isError)
}

@Test @MainActor func terminalScopesScratchAndProjectWithoutImplicitProjects() async throws {
    let files = FileManager.default
    guard files.isExecutableFile(atPath: "/bin/zsh") else { return }
    let root = files.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("LimaTerminalWorkScope-\(UUID().uuidString)", isDirectory: true)
    defer { try? files.removeItem(at: root) }
    let paths = AIWorkspacePaths(root: root)
    let store = AIWorkspaceStore(fixtures: [])
    let terminal = AIWorkspaceTerminalCoordinator(paths: paths, projectStore: store)
    let manager = AIProjectManager(store: store, paths: paths, terminal: terminal)
    let conversationID = UUID()
    let scratch = try terminal.start(conversationID: conversationID)
    guard case .scratch(let scratchID) = scratch.workScope else {
        Issue.record("A temporary command should create a Scratch run, not a Project.")
        return
    }
    #expect(scratch.directory == paths.scratchRun(scratchID).path)
    #expect(store.projects.isEmpty)
    #expect(!files.fileExists(atPath: paths.projects.path))
    try terminal.close(sessionID: scratch.id)

    let project = try manager.create(name: "Dashboard")
    try paths.ensureDirectory(paths.project(project.id).appendingPathComponent("src", isDirectory: true))
    let session = try terminal.start(directory: "src", conversationID: conversationID,
                                     projectID: project.id)
    #expect(session.workScope == .project(project.id))
    #expect(session.directory == paths.project(project.id).appendingPathComponent("src").path)
    let running = try terminal.run(sessionID: session.id, command: "sleep 30", timeoutSeconds: 60)
    #expect(running.state == .running)
    _ = try await manager.archive(project.id)
    #expect(!terminal.sessions.contains { $0.id == session.id })
    #expect(store.project(id: project.id)?.lifecycle == .archived)
    #expect(throws: AIWorkspaceTerminalCoordinator.WorkspaceError.self) {
        try terminal.start(projectID: project.id)
    }
    #expect(files.fileExists(atPath: paths.scratchRun(scratchID).path))
}

@Test @MainActor func projectArchiveWaitsForInteractivePTYExitAfterOutput() async throws {
    let files = FileManager.default
    guard files.isExecutableFile(atPath: "/bin/zsh") else { return }
    let root = files.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("LimaProjectPTYArchive-\(UUID().uuidString)", isDirectory: true)
    defer { try? files.removeItem(at: root) }
    let paths = AIWorkspacePaths(root: root)
    let store = AIWorkspaceStore(fixtures: [])
    let terminal = AIWorkspaceTerminalCoordinator(paths: paths, projectStore: store)
    let manager = AIProjectManager(store: store, paths: paths, terminal: terminal)
    let project = try manager.create(name: "Interactive Project")
    let session = try terminal.start(conversationID: UUID(), interactive: true, projectID: project.id)
    defer {
        if (try? terminal.status(sessionID: session.id))?.state == .running {
            _ = try? terminal.terminate(sessionID: session.id)
        }
    }
    let cursor = session.nextOutputByte
    _ = try terminal.write(sessionID: session.id, input: "echo ARCHIVE_OUTPUT\n")
    let observed = try await terminal.wait(sessionID: session.id, from: cursor, maxWaitSeconds: 3)
    #expect(observed["interactive_pty"] as? Bool == true)
    #expect(terminal.sessions.contains { $0.id == session.id && $0.state == .running })
    _ = try await manager.archive(project.id)
    #expect(store.project(id: project.id)?.lifecycle == .archived)
    #expect(!terminal.sessions.contains { $0.id == session.id })
}
