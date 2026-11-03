import Foundation
import RayPlacementCore

/// Only explicitly linked folders are observed. This runs inside Lima, never as
/// a daemon, and reloads metadata rather than executing extension code.
@MainActor
final class ExtensionDevelopmentFolders: ObservableObject {
    static let shared = ExtensionDevelopmentFolders()
    static let changed = Notification.Name("Lima.developmentExtensionsChanged")
    @Published private(set) var folders: [URL]
    private let defaults: UserDefaults
    private var monitor: Task<Void, Never>?
    private static let key = "lima.extensionDevelopmentFolders.v1"
    init(defaults: UserDefaults = LimaTestEnvironment.userDefaults) {
        self.defaults = defaults
        folders = Array(Set(defaults.stringArray(forKey: Self.key) ?? [])).sorted().map { URL(fileURLWithPath: $0) }
    }
    func link(_ directory: URL) throws {
        let url = directory.resolvingSymlinksInPath().standardizedFileURL
        let inspection = ExtensionDeveloperKit.inspect(url)
        guard inspection.isValid, let manifest = inspection.manifest, !manifest.bundled,
              manifest.provenance != .bundled, manifest.trust != .bundled, manifest.trust != .builtIn else {
            throw NSError(domain: "LimaExtensions", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose a valid, non-bundled development extension. Use Check to see its errors."])
        }
        if !folders.contains(url) { folders.append(url); save() }
    }
    func unlink(_ directory: URL) { folders.removeAll { $0.standardizedFileURL == directory.standardizedFileURL }; save() }
    private func save() {
        defaults.set(folders.map(\.path), forKey: Self.key)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
    nonisolated private static func manifestStamp(_ url: URL) -> String {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return "missing" }
        return "\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }
    func startMonitoring() {
        guard monitor == nil, !LimaTestEnvironment.isEnabled else { return }
        monitor = Task { @MainActor [weak self] in
            var previous: [String: String] = [:]
            while !Task.isCancelled {
                guard let self else { return }
                let paths = self.folders
                let current = await Task.detached(priority: .utility) {
                    Dictionary(uniqueKeysWithValues: paths.map { path in
                        (path.path, Self.manifestStamp(path.appendingPathComponent("manifest.json")))
                    })
                }.value
                if current != previous {
                    if !previous.isEmpty { NotificationCenter.default.post(name: Self.changed, object: nil) }
                    previous = current
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
