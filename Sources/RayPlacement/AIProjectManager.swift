import Foundation

enum AIProjectManagerError: LocalizedError {
    case invalidName
    case projectLimit
    case unavailable
    case missingDirectory
    case directoryAlreadyExists
    case runningProcesses
    case invalidState

    var errorDescription: String? {
        switch self {
        case .invalidName: "Give the Project a name before creating it."
        case .projectLimit: "Lima has reached the local Project limit."
        case .unavailable: "That Project is not available in Lima."
        case .missingDirectory: "The managed Project directory is missing; no registry change was made."
        case .directoryAlreadyExists: "A Project directory already exists at that location."
        case .runningProcesses: "Project-owned processes are still running. Stop them and retry."
        case .invalidState: "That Project cannot make the requested lifecycle transition."
        }
    }
}

/// Coordinates the on-disk working tree with the workspace registry. Context-
/// only records are never materialized during decoding or startup.
@MainActor
final class AIProjectManager {
    static let shared = AIProjectManager(store: .shared, terminal: .shared, servers: .shared)

    let store: AIWorkspaceStore
    let paths: AIWorkspacePaths
    private let fileManager: FileManager
    private let terminal: AIWorkspaceTerminalCoordinator?
    private let servers: AIManagedServerManager?

    init(store: AIWorkspaceStore, paths: AIWorkspacePaths = AIWorkspacePaths(),
         fileManager: FileManager = .default,
         terminal: AIWorkspaceTerminalCoordinator? = nil,
         servers: AIManagedServerManager? = nil) {
        self.store = store
        self.paths = paths
        self.fileManager = fileManager
        self.terminal = terminal
        self.servers = servers
    }

    func create(name: String, instructions: String = "",
                origin: AIProjectOrigin = .created) throws -> AIProject {
        let name = try validatedName(name)
        guard store.projects.count < AIWorkspaceStore.maximumProjects else {
            throw AIProjectManagerError.projectLimit
        }
        let id = UUID()
        let directory = paths.project(id)
        try paths.ensureDirectory(paths.projects, fileManager: fileManager)
        guard !fileManager.fileExists(atPath: directory.path) else {
            throw AIProjectManagerError.directoryAlreadyExists
        }
        try paths.ensureDirectory(directory, fileManager: fileManager)
        let project = AIProject(
            id: id, name: name,
            instructions: String(instructions.prefix(AIWorkspaceStore.maximumProjectInstructionsCharacters)),
            workState: .materialized, directoryName: id.uuidString, origin: origin
        )
        guard store.insertManagedProject(project) else {
            try? fileManager.removeItem(at: directory)
            throw AIProjectManagerError.projectLimit
        }
        return project
    }

    func materialize(_ id: UUID, origin: AIProjectOrigin = .created) throws -> AIProject {
        guard var project = store.project(id: id) else { throw AIProjectManagerError.unavailable }
        guard project.lifecycle == .active else { throw AIProjectManagerError.invalidState }
        if project.workState == .materialized { return project }
        let directory = paths.project(id)
        try paths.ensureDirectory(paths.projects, fileManager: fileManager)
        guard !fileManager.fileExists(atPath: directory.path) else {
            throw AIProjectManagerError.directoryAlreadyExists
        }
        try paths.ensureDirectory(directory, fileManager: fileManager)
        project.workState = .materialized
        project.directoryName = id.uuidString
        project.origin = origin
        project.updatedAt = Date()
        guard store.replaceProject(project) else {
            try? fileManager.removeItem(at: directory)
            throw AIProjectManagerError.unavailable
        }
        return project
    }

    func rename(_ id: UUID, to name: String) throws -> AIProject {
        guard var project = store.project(id: id) else { throw AIProjectManagerError.unavailable }
        project.name = try validatedName(name)
        project.updatedAt = Date()
        guard store.replaceProject(project) else { throw AIProjectManagerError.unavailable }
        return project
    }

    func open(_ id: UUID) throws -> AIProject {
        guard var project = store.project(id: id) else { throw AIProjectManagerError.unavailable }
        guard project.lifecycle == .active else { throw AIProjectManagerError.invalidState }
        project.lastOpenedAt = Date()
        guard store.replaceProject(project) else { throw AIProjectManagerError.unavailable }
        return project
    }

    func archive(_ id: UUID) async throws -> AIProject {
        guard var project = store.project(id: id) else { throw AIProjectManagerError.unavailable }
        guard project.lifecycle == .active else { throw AIProjectManagerError.invalidState }
        let moved = project.workState == .materialized
        if moved {
            let source = paths.project(id)
            let destination = paths.project(id, lifecycle: .archived)
            try await stopOwnedSessions(projectID: id)
            try moveManagedDirectory(from: source, to: destination)
        }
        project.lifecycle = .archived
        project.archivedAt = Date()
        project.updatedAt = Date()
        guard store.replaceProject(project) else {
            if moved { try? fileManager.moveItem(at: paths.project(id, lifecycle: .archived), to: paths.project(id)) }
            throw AIProjectManagerError.unavailable
        }
        return project
    }

    func restore(_ id: UUID) throws -> AIProject {
        guard var project = store.project(id: id) else { throw AIProjectManagerError.unavailable }
        guard project.lifecycle == .archived else { throw AIProjectManagerError.invalidState }
        let moved = project.workState == .materialized
        if moved {
            try moveManagedDirectory(from: paths.project(id, lifecycle: .archived),
                                     to: paths.project(id))
        }
        project.lifecycle = .active
        project.archivedAt = nil
        project.updatedAt = Date()
        guard store.replaceProject(project) else {
            if moved { try? fileManager.moveItem(at: paths.project(id), to: paths.project(id, lifecycle: .archived)) }
            throw AIProjectManagerError.unavailable
        }
        return project
    }

    func remove(_ id: UUID) async throws -> AIRemovedProject {
        guard let project = store.project(id: id) else { throw AIProjectManagerError.unavailable }
        let source = paths.project(id, lifecycle: project.lifecycle)
        let destination = paths.removedProject(id)
        if project.workState == .materialized {
            try await stopOwnedSessions(projectID: id)
            try moveManagedDirectory(from: source, to: destination)
        }
        guard let record = store.removeProjectFromRegistry(id) else {
            if project.workState == .materialized {
                try? fileManager.moveItem(at: destination, to: source)
            }
            throw AIProjectManagerError.unavailable
        }
        return record
    }

    func recover(_ id: UUID) throws -> AIProject {
        guard let record = store.removedProject(id: id) else { throw AIProjectManagerError.unavailable }
        if record.project.workState == .materialized {
            try moveManagedDirectory(from: paths.removedProject(id), to: paths.project(id))
        }
        guard let project = store.restoreRemovedProject(id) else {
            if record.project.workState == .materialized {
                try? fileManager.moveItem(at: paths.project(id), to: paths.removedProject(id))
            }
            throw AIProjectManagerError.projectLimit
        }
        return project
    }

    func directory(for project: AIProject) -> URL? {
        guard project.workState == .materialized else { return nil }
        return paths.project(project.id, lifecycle: project.lifecycle)
    }

    private func validatedName(_ name: String) throws -> String {
        let result = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, result.count <= AIWorkspaceStore.maximumProjectNameCharacters else {
            throw AIProjectManagerError.invalidName
        }
        return result
    }

    private func moveManagedDirectory(from source: URL, to destination: URL) throws {
        guard fileManager.fileExists(atPath: source.path) else {
            throw AIProjectManagerError.missingDirectory
        }
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw AIProjectManagerError.directoryAlreadyExists
        }
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw AIWorkspacePathError.unsafeDirectory
        }
        try paths.ensureDirectory(destination.deletingLastPathComponent(), fileManager: fileManager)
        try fileManager.moveItem(at: source, to: destination)
    }

    private func stopOwnedSessions(projectID: UUID) async throws {
        if let servers {
            do { try await servers.stopAll(projectID: projectID) }
            catch { throw AIProjectManagerError.runningProcesses }
        }
        guard let terminal else { return }
        for session in terminal.sessions where session.workScope == .project(projectID) {
            if session.state == .running {
                if session.isInteractivePTY {
                    _ = try terminal.terminate(sessionID: session.id)
                } else {
                    _ = try terminal.interrupt(sessionID: session.id)
                }
                let deadline = ContinuousClock().now.advanced(by: .seconds(20))
                while try terminal.status(sessionID: session.id).state == .running {
                    try Task.checkCancellation()
                    guard ContinuousClock().now < deadline else {
                        throw AIProjectManagerError.runningProcesses
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            let current = try terminal.status(sessionID: session.id)
            guard current.state != .running else { throw AIProjectManagerError.runningProcesses }
            try terminal.close(sessionID: session.id)
        }
    }
}
