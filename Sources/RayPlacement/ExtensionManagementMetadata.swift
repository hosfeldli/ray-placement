import Foundation
import RayPlacementCore

/// Read-only UI metadata scan. Each file is decoded once off the main actor;
/// approval and lifecycle decisions stay on the main actor after delivery.
struct ExtensionManagementMetadata: Sendable {
    let manifest: ExtensionManifest
    let hash: String

    static func read(directory: URL) -> [Self] {
        let files = FileManager.default
        guard let entries = try? files.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var seen = Set<String>()
        return entries.sorted { $0.path < $1.path }.compactMap { entry in
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            guard isDirectory || entry.pathExtension.lowercased() == "json" else { return nil }
            let url = isDirectory ? entry.appendingPathComponent("manifest.json") : entry
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2_000_000,
                  let data = try? Data(contentsOf: url),
                  let manifest = try? JSONDecoder().decode(ExtensionManifest.self, from: data),
                  (1...3).contains(manifest.schemaVersion),
                  (try? manifest.validateLifecycleMetadata()) != nil,
                  seen.insert(manifest.id).inserted else { return nil }
            return Self(manifest: manifest, hash: ExtensionSecurityPolicy.manifestHash(data))
        }
    }
}
