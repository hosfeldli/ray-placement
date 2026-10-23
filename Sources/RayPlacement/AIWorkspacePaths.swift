import Foundation

/// Storage for AI-owned work. Computing a path never creates a Project or
/// touches disk; callers create a directory only when work requires it.
struct AIWorkspacePaths: Sendable {
    let root: URL

    init(root: URL? = nil) {
        if let root {
            self.root = root.standardizedFileURL
        } else if let testRoot = LimaTestEnvironment.storageURL(relativePath: "AI/Workspace") {
            self.root = testRoot.standardizedFileURL
        } else {
            self.root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Lima", isDirectory: true)
                .appendingPathComponent("AI", isDirectory: true)
                .appendingPathComponent("Workspace", isDirectory: true)
        }
    }

    var projects: URL { root.appendingPathComponent("Projects", isDirectory: true) }
    var environments: URL { root.appendingPathComponent("Environments", isDirectory: true) }
    var artifacts: URL { root.appendingPathComponent("Artifacts", isDirectory: true) }
    var scratch: URL { root.appendingPathComponent("Scratch", isDirectory: true) }
    var archived: URL { root.appendingPathComponent("Archived", isDirectory: true) }
    var removed: URL { root.appendingPathComponent("Removed", isDirectory: true) }

    func project(_ id: UUID, lifecycle: AIProjectLifecycle = .active) -> URL {
        let parent = lifecycle == .archived ? archived : projects
        return parent.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func removedProject(_ id: UUID) -> URL {
        removed.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func scratchRun(_ id: UUID) -> URL {
        scratch.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    @discardableResult
    func createScratchRun(_ id: UUID) throws -> URL {
        try ensureDirectory(scratch)
        let directory = scratchRun(id)
        try ensureDirectory(directory)
        return directory
    }

    /// Only UUID-named Scratch runs can be expired. Projects and artifacts are
    /// never included in this cleanup.
    func pruneScratch(olderThan cutoff: Date, excluding activeRunIDs: Set<UUID> = [],
                      fileManager: FileManager = .default) throws -> Int {
        guard fileManager.fileExists(atPath: scratch.path) else { return 0 }
        let rootValues = try scratch.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw AIWorkspacePathError.unsafeDirectory
        }
        let entries = try fileManager.contentsOfDirectory(
            at: scratch, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        )
        var removedCount = 0
        for entry in entries {
            guard let id = UUID(uuidString: entry.lastPathComponent),
                  !activeRunIDs.contains(id) else { continue }
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate, modified < cutoff else { continue }
            try fileManager.removeItem(at: entry)
            removedCount += 1
        }
        return removedCount
    }

    func ensureDirectory(_ directory: URL, fileManager: FileManager = .default) throws {
        let path = directory.standardizedFileURL.path
        guard path == root.path || path.hasPrefix(root.path + "/") else {
            throw AIWorkspacePathError.outsideWorkspace
        }
        if fileManager.fileExists(atPath: path) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw AIWorkspacePathError.unsafeDirectory
            }
        } else {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        }
    }
}

enum AIWorkspacePathError: Error {
    case outsideWorkspace
    case unsafeDirectory
}

/// Conversation work begins unscoped. Scratch is transient and invisible in
/// Projects; only an explicit durable-work action selects a materialized Project.
enum AIWorkScope: Hashable, Sendable {
    case none
    case scratch(UUID)
    case project(UUID)
}
