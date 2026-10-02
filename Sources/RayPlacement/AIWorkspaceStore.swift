import Combine
import Foundation

/// A user-owned, local-only workspace for organizing AI chats and saving durable
/// context. Enabled memory tools can maintain durable user-supplied preferences;
/// all entries remain visible, editable, and removable in the workspace.
struct AIProject: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var instructions: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        instructions: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct AIMemory: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var title: String
    var content: String
    /// A nil project makes this a user-approved global memory.
    var projectID: UUID?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        content: String,
        projectID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.projectID = projectID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@MainActor
final class AIWorkspaceStore: ObservableObject {
    private struct Document: Codable {
        var projects: [AIProject]
        var memories: [AIMemory]
    }

    static let shared = AIWorkspaceStore()

    static let maximumProjects = 100
    static let maximumMemories = 500
    static let maximumProjectNameCharacters = 120
    static let maximumProjectInstructionsCharacters = 12_000
    static let maximumMemoryTitleCharacters = 120
    static let maximumMemoryCharacters = 12_000

    @Published private(set) var projects: [AIProject] = []
    @Published private(set) var memories: [AIMemory] = []
    @Published private(set) var lastError: String?

    private let persistsChanges: Bool
    private let persistenceQueue = DispatchQueue(label: "dev.liam.lima.ai-workspace-persistence", qos: .utility)
    private var pendingSave: DispatchWorkItem?

    private init() {
        persistsChanges = true
        load()
    }

    init(fixtures projects: [AIProject] = [], memories: [AIMemory] = []) {
        persistsChanges = false
        self.projects = projects
        self.memories = memories
    }

    func project(id: UUID?) -> AIProject? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    /// Global memories are included with the selected project's memories. This
    /// keeps intentionally global preferences useful without making them hidden.
    func memories(for projectID: UUID?) -> [AIMemory] {
        memories
            .filter { $0.projectID == nil || $0.projectID == projectID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func projectMemoryCount(for projectID: UUID?) -> Int {
        memories(for: projectID).count
    }

    @discardableResult
    func createProject(name: String, instructions: String = "") -> AIProject? {
        guard projects.count < Self.maximumProjects else {
            lastError = "Lima has reached the local project limit."
            return nil
        }
        let name = cleaned(name, maximum: Self.maximumProjectNameCharacters)
        guard !name.isEmpty else {
            lastError = "Give the project a name before saving it."
            return nil
        }
        let project = AIProject(
            name: name,
            instructions: cleaned(instructions, maximum: Self.maximumProjectInstructionsCharacters)
        )
        projects.insert(project, at: 0)
        lastError = nil
        scheduleSave()
        return project
    }

    func updateProject(_ project: AIProject, name: String, instructions: String) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        let name = cleaned(name, maximum: Self.maximumProjectNameCharacters)
        guard !name.isEmpty else {
            lastError = "Give the project a name before saving it."
            return
        }
        projects[index].name = name
        projects[index].instructions = cleaned(instructions, maximum: Self.maximumProjectInstructionsCharacters)
        projects[index].updatedAt = Date()
        lastError = nil
        scheduleSave()
    }

    /// Removing a project keeps its saved memories as global memories. Lima never
    /// silently erases user-created context when a project is reorganized.
    func deleteProject(_ id: UUID) {
        guard projects.contains(where: { $0.id == id }) else { return }
        projects.removeAll { $0.id == id }
        memories = memories.map { memory in
            var memory = memory
            if memory.projectID == id {
                memory.projectID = nil
                memory.updatedAt = Date()
            }
            return memory
        }
        lastError = nil
        scheduleSave()
    }

    @discardableResult
    func createMemory(title: String, content: String, projectID: UUID?) -> AIMemory? {
        guard memories.count < Self.maximumMemories else {
            lastError = "Lima has reached the local memory limit."
            return nil
        }
        guard projectID == nil || project(id: projectID) != nil else {
            lastError = "Choose an available project before saving this memory."
            return nil
        }
        let content = cleaned(content, maximum: Self.maximumMemoryCharacters)
        guard !content.isEmpty else {
            lastError = "Write something to remember before saving it."
            return nil
        }
        let explicitTitle = cleaned(title, maximum: Self.maximumMemoryTitleCharacters)
        let fallbackTitle = String(content
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(Self.maximumMemoryTitleCharacters))
        let memory = AIMemory(
            title: explicitTitle.isEmpty ? fallbackTitle : explicitTitle,
            content: content,
            projectID: projectID
        )
        memories.insert(memory, at: 0)
        lastError = nil
        scheduleSave()
        return memory
    }

    @discardableResult
    func updateMemory(_ id: UUID, title: String, content: String) -> AIMemory? {
        guard let index = memories.firstIndex(where: { $0.id == id }) else { return nil }
        let content = cleaned(content, maximum: Self.maximumMemoryCharacters)
        guard !content.isEmpty else { return nil }
        memories[index].title = cleaned(title, maximum: Self.maximumMemoryTitleCharacters)
        memories[index].content = content
        memories[index].updatedAt = Date()
        lastError = nil
        scheduleSave()
        return memories[index]
    }

    func deleteMemory(_ id: UUID) {
        guard memories.contains(where: { $0.id == id }) else { return }
        memories.removeAll { $0.id == id }
        lastError = nil
        scheduleSave()
    }

    /// Render only a bounded subset of explicit memories for the selected AI
    /// request. The local source of truth remains complete in workspace.json.
    func context(for projectID: UUID?, maximumCharacters: Int = 8_000) -> String {
        var remaining = maximumCharacters
        var entries: [String] = []
        for memory in memories(for: projectID) {
            let title = cleaned(memory.title, maximum: Self.maximumMemoryTitleCharacters)
            let content = cleaned(memory.content, maximum: Self.maximumMemoryCharacters)
            let entry = title.isEmpty ? "• \(content)" : "• \(title): \(content)"
            guard entry.count <= remaining else { continue }
            entries.append(entry)
            remaining -= entry.count
            if remaining < 160 { break }
        }
        return entries.joined(separator: "\n")
    }

    private func cleaned(_ value: String, maximum: Int) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximum))
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        do {
            let document = try JSONDecoder().decode(Document.self, from: data)
            projects = Array(document.projects.prefix(Self.maximumProjects))
            let projectIDs = Set(projects.map(\.id))
            memories = document.memories
                .filter { $0.projectID == nil || projectIDs.contains($0.projectID!) }
                .prefix(Self.maximumMemories)
                .map { $0 }
        } catch {
            lastError = "AI projects and memories could not be loaded. The existing file was left in place."
        }
    }

    private func scheduleSave() {
        guard persistsChanges else { return }
        pendingSave?.cancel()
        let document = Document(projects: projects, memories: memories)
        let url = storageURL
        let work = DispatchWorkItem { [weak self] in
            do {
                try Self.persist(document, to: url)
                DispatchQueue.main.async { self?.lastError = nil }
            } catch {
                DispatchQueue.main.async {
                    self?.lastError = "AI projects and memories could not be saved. Check local storage access."
                }
            }
        }
        pendingSave = work
        persistenceQueue.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private var storageURL: URL {
        if let testURL = LimaTestEnvironment.storageURL(relativePath: "AI/workspace.json") {
            return testURL
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("Lima", isDirectory: true)
            .appendingPathComponent("AI", isDirectory: true)
            .appendingPathComponent("workspace.json")
    }

    private nonisolated static func persist(_ document: Document, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try JSONEncoder().encode(document)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
