import Foundation
import RayPlacementCore

/// Inactive, byte-for-byte preservation of definitions from the retired
/// Workflows product. Nothing in this type can execute a saved command.
struct LegacyWorkflowArchive {
    let sourceURL: URL
    let archiveDirectory: URL
    private let files = FileManager.default
    private let privateStore = PrivateFileStore()

    init(applicationSupport: URL = ApplicationPaths.applicationSupport) {
        sourceURL = applicationSupport.appendingPathComponent("workflows.json")
        archiveDirectory = applicationSupport.appendingPathComponent("Archived Workflows", isDirectory: true)
    }

    /// Idempotent across launches; preserve the original file and any previous
    /// snapshots. A changed legacy file gets another snapshot, never a replace.
    @discardableResult
    func archiveIfNeeded() throws -> URL? {
        guard files.fileExists(atPath: sourceURL.path) else { return archivedFiles().last }
        let bytes = try Data(contentsOf: sourceURL)
        if let matching = archivedFiles().first(where: { (try? Data(contentsOf: $0)) == bytes }) {
            return matching
        }
        try privateStore.prepareDirectory(archiveDirectory)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let target = archiveDirectory.appendingPathComponent("workflows-\(stamp)-\(UUID().uuidString).json")
        try privateStore.write(data: bytes, to: target, backupExisting: false)
        return target
    }

    func archivedFiles() -> [URL] {
        guard let urls = try? files.contentsOfDirectory(at: archiveDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        return urls.filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("workflows-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    var hasSavedDefinitions: Bool {
        let candidates = [sourceURL] + archivedFiles()
        for url in candidates where files.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url) else { return true }
            if let definitions = try? JSONDecoder().decode([WorkflowDefinition].self, from: data) {
                if !definitions.isEmpty { return true }
            } else if !data.isEmpty {
                // Malformed user data still deserves a visible export path.
                return true
            }
        }
        return false
    }

    /// Call only for a user-chosen destination. Exports the newest preserved
    /// snapshot, and does not alter either the source or the archive.
    func exportLatest(to destination: URL) throws {
        guard let source = try archiveIfNeeded() else {
            throw CocoaError(.fileNoSuchFile)
        }
        let bytes = try Data(contentsOf: source)
        try bytes.write(to: destination, options: .atomic)
    }

    /// Destructive cleanup is deliberately separate from launch migration and
    /// must only be invoked after an explicit user-facing confirmation.
    func removeLegacyCopies() throws {
        if files.fileExists(atPath: sourceURL.path) { try files.removeItem(at: sourceURL) }
        for url in archivedFiles() { try files.removeItem(at: url) }
    }
}
