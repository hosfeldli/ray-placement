import AppKit
import Foundation
import RayPlacementCore

struct ExtensionLibraryEntry: Identifiable, Sendable {
    let inspection: ExtensionInspection
    let manifestURL: URL
    let development: Bool
    var id: String { manifestURL.path }
    var manifest: ExtensionManifest? { inspection.manifest }
    var name: String { manifest?.name ?? inspection.directory.lastPathComponent }
    var packageID: String? { manifest?.id }
    var bundled: Bool { manifest.map { $0.bundled || $0.provenance == .bundled || $0.trust == .bundled || $0.trust == .builtIn } ?? false }
    var source: String { development ? "Development" : bundled ? "Built-in" : "Installed" }
    var searchableText: String { ([name, packageID ?? "", manifest?.description ?? ""] + (manifest?.commands.map(\.title) ?? [])).joined(separator: " ") }
}

enum ExtensionLibraryArea: String, CaseIterable, Identifiable {
    case library = "My Extensions", discover = "Discover", build = "Build"
    var id: String { rawValue }
}

enum ExtensionLibraryStatus: String, CaseIterable {
    case ready = "Ready", disabled = "Disabled", review = "Needs review", invalid = "Needs fixing", removed = "Removed"
    var symbol: String {
        switch self { case .ready: return "checkmark.circle.fill"; case .disabled: return "pause.circle"; case .review: return "hand.raised.fill"; case .invalid: return "exclamationmark.triangle.fill"; case .removed: return "archivebox" }
    }
}

@MainActor
final class ExtensionLibraryStore: ObservableObject {
    static let shared = ExtensionLibraryStore()
    @Published private(set) var entries: [ExtensionLibraryEntry] = []
    @Published private(set) var isLoading = false
    @Published var message: String?
    @Published var requestedArea: ExtensionLibraryArea?
    private var refreshTask: Task<Void, Never>?
    private var generation = UUID()
    let root: URL
    let development: ExtensionDevelopmentFolders
    init(root: URL = ApplicationPaths.extensions, development: ExtensionDevelopmentFolders? = nil) {
        self.root = root; self.development = development ?? .shared
    }
    func refresh() {
        refreshTask?.cancel(); let generation = UUID(); self.generation = generation
        isLoading = true; let root = root; let linked = development.folders
        refreshTask = Task { @MainActor in
            let entries = await Task.detached(priority: .userInitiated) { Self.scan(root: root, linked: linked) }.value
            guard !Task.isCancelled, self.generation == generation else { return }
            self.entries = entries; isLoading = false
        }
    }
    nonisolated static func scan(root: URL, linked: [URL]) -> [ExtensionLibraryEntry] {
        let children = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        var result: [ExtensionLibraryEntry] = []
        for url in children {
            let folder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            guard folder || url.pathExtension.lowercased() == "json" else { continue }
            let directory = folder ? url : url.deletingLastPathComponent()
            let manifest = folder ? url.appendingPathComponent("manifest.json") : url
            result.append(.init(inspection: ExtensionDeveloperKit.inspect(directory, manifestFile: manifest), manifestURL: manifest, development: false))
        }
        for url in linked where !result.contains(where: { $0.inspection.directory.standardizedFileURL == url.standardizedFileURL }) {
            result.append(.init(inspection: ExtensionDeveloperKit.inspect(url), manifestURL: url.appendingPathComponent("manifest.json"), development: true))
        }
        // Keep duplicate and malformed packages visible, with their own stable
        // path identities; never let Dictionary(uniqueKeysWithValues:) crash.
        let groups = Dictionary(grouping: result.filter { $0.packageID != nil }, by: { $0.packageID! })
        result = result.map { entry in
            guard let id = entry.packageID, (groups[id]?.count ?? 0) > 1 else { return entry }
            let issue = ExtensionDiagnostic(.error, "id", "Another package uses \(id).", fix: "Remove the duplicate folder or give the development package a new stable ID.")
            return .init(inspection: .init(directory: entry.inspection.directory, manifest: entry.manifest,
                manifestHash: entry.inspection.manifestHash, diagnostics: entry.inspection.diagnostics + [issue]), manifestURL: entry.manifestURL, development: entry.development)
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func status(_ entry: ExtensionLibraryEntry) -> ExtensionLibraryStatus {
        guard entry.inspection.isValid, let manifest = entry.manifest else { return .invalid }
        if ExtensionPackageManager.shared.isLogicallyRemoved(manifest.id) { return .removed }
        if !entry.bundled {
            guard let approval = ExtensionApprovalStore.record(for: manifest.id), approval.manifestHash == entry.inspection.manifestHash,
                  approval.capabilities.isSuperset(of: manifest.capabilities) else { return .review }
        }
        return SettingsStore.shared.isManifestEnabled(manifest) ? .ready : .disabled
    }
    func approve(_ entry: ExtensionLibraryEntry) throws {
        let fresh = ExtensionDeveloperKit.inspect(entry.inspection.directory, manifestFile: entry.manifestURL)
        guard fresh.isValid, fresh.manifestHash == entry.inspection.manifestHash, let manifest = fresh.manifest,
              manifest.id == entry.packageID, !entry.bundled,
              !entries.contains(where: { $0.id != entry.id && $0.packageID == entry.packageID }) else {
            throw error("This package changed or has errors. Check it again before approving.")
        }
        ExtensionApprovalStore.approve(extensionID: manifest.id, manifestHash: fresh.manifestHash!, capabilities: manifest.capabilities)
        SettingsStore.shared.setPackageEnabled(true, extensionID: manifest.id)
        message = "Enabled \(manifest.name)."; refresh()
    }
    func setEnabled(_ enabled: Bool, entry: ExtensionLibraryEntry) {
        guard let id = entry.packageID else { return }
        SettingsStore.shared.setPackageEnabled(enabled, extensionID: id)
        ExtensionPackageManager.shared.transition(enabled ? .installed : .disabled, id: id)
        objectWillChange.send()
    }
    func addFolder(_ source: URL, link: Bool) async throws {
        let source = source.resolvingSymlinksInPath().standardizedFileURL
        let inspection = await Task.detached(priority: .userInitiated) { ExtensionDeveloperKit.inspect(source) }.value
        guard inspection.isValid, let manifest = inspection.manifest, !manifest.id.hasPrefix("."), !manifest.bundled,
              manifest.provenance != .bundled, manifest.trust != .bundled, manifest.trust != .builtIn else { throw error("Choose a valid user extension. Use Check Folder to see any errors.") }
        let rootSnapshot = root; let linkedSnapshot = development.folders
        let existing = await Task.detached { Self.scan(root: rootSnapshot, linked: linkedSnapshot) }.value
        guard !existing.contains(where: { $0.packageID == manifest.id }),
              !development.folders.contains(where: { $0 == source }) else { throw error("An extension with this ID is already present. Remove or unlink it before adding a replacement.") }
        if link { try development.link(source) }
        else {
            let root = root
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let staged = root.appendingPathComponent(".lima-import-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: staged) }
                try ExtensionDeveloperKit.copyPackage(from: source, to: staged)
                var normalized = manifest; normalized.provenance = .userInstalled; normalized.trust = .unsigned; normalized.bundled = false
                try JSONEncoder().encode(normalized).write(to: staged.appendingPathComponent("manifest.json"), options: .atomic)
                try FileManager.default.moveItem(at: staged, to: root.appendingPathComponent(manifest.id))
            }.value
        }
        SettingsStore.shared.setPackageEnabled(false, extensionID: manifest.id)
        message = link ? "Development folder linked. Review permissions to enable it; manifest edits reload automatically while Lima runs." : "Added \(manifest.name). Review permissions to enable it."
        refresh()
    }
    func remove(_ entry: ExtensionLibraryEntry) throws {
        if entry.bundled, let id = entry.packageID { ExtensionPackageManager.shared.logicallyRemoveBundled(id: id) }
        else if entry.development { development.unlink(entry.inspection.directory) }
        else {
            let directoryPackage = entry.manifestURL.lastPathComponent == "manifest.json" && entry.inspection.directory.resolvingSymlinksInPath() != root.resolvingSymlinksInPath()
            let file = directoryPackage ? entry.inspection.directory : entry.manifestURL
            let canonicalRoot = root.resolvingSymlinksInPath().path + "/"
            guard file.resolvingSymlinksInPath().path.hasPrefix(canonicalRoot) else { throw error("This path is not an installed package. Unlink development folders instead.") }
            let removed = root.appendingPathComponent(".removed/" + UUID().uuidString)
            try FileManager.default.createDirectory(at: removed, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: file, to: removed.appendingPathComponent(file.lastPathComponent))
        }
        if let id = entry.packageID, !entry.bundled {
            ExtensionApprovalStore.revoke(extensionID: id)
            ExtensionPackageManager.shared.transition(.notInstalled, id: id)
        }
        message = entry.development ? "Folder unlinked. Your source files were kept." : "Extension removed. Command preferences were kept."
        refresh()
    }
    private func error(_ text: String) -> NSError { NSError(domain: "LimaExtensions", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
