import Foundation
import RayPlacementCore

/// Compatibility projection of the shared package index. New UI consumes the
/// complete entries so invalid packages remain visible and repairable.
struct ExtensionManagementMetadata: Sendable {
    let manifest: ExtensionManifest
    let hash: String
    static func read(directory: URL) -> [Self] {
        ExtensionLibraryStore.scan(root: directory, linked: []).compactMap { entry in
            guard entry.inspection.isValid, let manifest = entry.manifest,
                  let hash = entry.inspection.manifestHash else { return nil }
            return Self(manifest: manifest, hash: hash)
        }
    }
}
