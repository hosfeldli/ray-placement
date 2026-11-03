import Foundation
import RayPlacementCore
import Testing
@testable import RayPlacement

private func libraryRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("LimaLibrary-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func extensionLibraryKeepsBrokenAndDuplicatePackagesVisible() throws {
    let root = try libraryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    for name in ["one", "two"] { _ = try ExtensionDeveloperKit.create(at: root.appendingPathComponent(name), id: "local.duplicate", name: name, template: .link) }
    let bad = root.appendingPathComponent("broken")
    try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: false)
    try "not JSON".write(to: bad.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    let entries = ExtensionLibraryStore.scan(root: root, linked: [])
    #expect(entries.count == 3)
    #expect(Set(entries.map(\.id)).count == 3)
    #expect(entries.allSatisfy { !$0.inspection.isValid })
    #expect(entries.filter { $0.packageID == "local.duplicate" }.allSatisfy { $0.inspection.diagnostics.contains { $0.path == "id" } })
}

@Test @MainActor func extensionLibraryLinksWithoutCopyingAndUnlinksWithoutDeletingSource() async throws {
    let root = try libraryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let installed = root.appendingPathComponent("installed"), source = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: false)
    let id = "local.link." + UUID().uuidString
    _ = try ExtensionDeveloperKit.create(at: source, id: id, name: "Linked", template: .script)
    let defaults = try #require(UserDefaults(suiteName: "LimaLibrary-" + UUID().uuidString))
    let folders = ExtensionDevelopmentFolders(defaults: defaults)
    let library = ExtensionLibraryStore(root: installed, development: folders)
    defer { ExtensionApprovalStore.revoke(extensionID: id); SettingsStore.shared.setExtensionEnabled(true, extensionID: id) }
    try await library.addFolder(source, link: true)
    #expect(folders.folders == [source.resolvingSymlinksInPath()])
    let entry = try #require(ExtensionLibraryStore.scan(root: installed, linked: folders.folders).first)
    #expect(entry.development)
    #expect(library.status(entry) == .review)
    try library.approve(entry)
    #expect(library.status(entry) == .ready)
    library.setEnabled(false, entry: entry)
    #expect(library.status(entry) == .disabled)
    try library.remove(entry)
    #expect(folders.folders.isEmpty)
    #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("bin/run").path))
}

@Test @MainActor func extensionPackageDisableRemovesAIContributionsAndKeepsCommandDefinitions() throws {
    let root = try libraryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let id = "local.ai." + UUID().uuidString
    let directory = root.appendingPathComponent("package")
    let inspection = try ExtensionDeveloperKit.create(at: directory, id: id, name: "AI Tools", template: .link)
    var manifest = try #require(inspection.manifest)
    manifest.contributions = .init(tools: [.init(id: "transform", title: "Transform", description: "Transform text", inputSchema: ["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)], execution: .hostReadOnly, hostAdapterID: "transform_text")])
    let data = try JSONEncoder().encode(manifest)
    try data.write(to: directory.appendingPathComponent("manifest.json"))
    ExtensionApprovalStore.approve(extensionID: id, manifestHash: ExtensionSecurityPolicy.manifestHash(data), capabilities: manifest.capabilities)
    defer { ExtensionApprovalStore.revoke(extensionID: id); SettingsStore.shared.setExtensionEnabled(true, extensionID: id) }
    let loader = ExtensionLoader(root: root, developmentFolders: [])
    #expect(loader.contributionCatalog().count == 1)
    SettingsStore.shared.setExtensionEnabled(false, extensionID: id)
    #expect(loader.contributionCatalog().isEmpty)
    #expect(loader.load(prepare: false, registerPackages: false).commands.count == 1)
    SettingsStore.shared.setExtensionEnabled(true, extensionID: id)
    #expect(loader.contributionCatalog().count == 1)
}

@Test @MainActor func extensionRemovalUsesTheActualFolderRatherThanAssumingTheIDIsItsName() throws {
    let root = try libraryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("friendly-folder-name")
    let id = "local.actual." + UUID().uuidString
    _ = try ExtensionDeveloperKit.create(at: source, id: id, name: "Actual", template: .link)
    let library = ExtensionLibraryStore(root: root)
    let entry = try #require(ExtensionLibraryStore.scan(root: root, linked: []).first)
    try library.remove(entry)
    #expect(!FileManager.default.fileExists(atPath: source.path))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".removed").path))
    #expect(ExtensionLibraryStore.scan(root: root, linked: []).isEmpty)
}

@Test @MainActor func cancellingOneExtensionDoesNotStopAnotherInvocation() async throws {
    let root = try libraryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let executor = ExtensionExecutor()
    func command(_ seconds: String) -> LoadedExtensionCommand {
        .init(extensionID: "local.cancel." + UUID().uuidString, extensionName: "Cancellation fixture", directory: root,
              command: .init(id: "run", title: "Wait", action: .init(type: .shell, value: "/bin/sleep", arguments: [seconds])), capabilities: [.shell, .filesystem, .externalExecution])
    }
    let first = Task { @MainActor in try await executor.executeAsync(command("2"), clipboard: ClipboardHistoryService(fixtures: [])) }
    let second = Task { @MainActor in try await executor.executeAsync(command("0.3"), clipboard: ClipboardHistoryService(fixtures: [])) }
    try await Task.sleep(for: .milliseconds(80))
    first.cancel()
    do { _ = try await first.value; Issue.record("Cancelled invocation unexpectedly succeeded") } catch {}
    _ = try await second.value
}

@Test @MainActor func generatedAIToolActuallyRunsThroughTheApprovedHostAdapter() async throws {
    try ApplicationPaths.prepare()
    let id = "local.generated." + UUID().uuidString
    let directory = ApplicationPaths.extensions.appendingPathComponent(id)
    defer { try? FileManager.default.removeItem(at: directory); ExtensionApprovalStore.revoke(extensionID: id) }
    let result = try ExtensionDeveloperKit.create(at: directory, id: id, name: "Generated Text Tool", template: .aiTool)
    let manifest = try #require(result.manifest)
    ExtensionApprovalStore.approve(extensionID: id, manifestHash: try #require(result.manifestHash), capabilities: manifest.capabilities)
    let binding = try #require(ExtensionToolHostAdapterRegistry.approvedBindings().first { $0.extensionID == id })
    let output = try await ExtensionToolHostAdapterRegistry.execute(binding, arguments: .object(["text": .string("A working tool"), "operation": .string("uppercase")]))
    #expect(output == .object(["text": .string("A WORKING TOOL")]))
}

@Test @MainActor func newPackageSwitchOverridesALegacyGroupWithoutChangingOtherPackages() {
    let id = "local.power." + UUID().uuidString
    let pack = "Legacy-" + UUID().uuidString
    let command = LoadedExtensionCommand(extensionID: id, extensionName: "Power", directory: URL(fileURLWithPath: "/tmp"),
        command: .init(id: "run", title: "Run", action: .init(type: .clipboard, value: "fixture")), pack: pack)
    var other = command; other.extensionID = id + ".other"
    let settings = SettingsStore.shared
    settings.setPackEnabled(false, for: command)
    defer { settings.setPackEnabled(true, for: command); settings.setPackageEnabled(true, extensionID: id) }
    #expect(!settings.isCommandEnabled(command))
    #expect(!settings.isCommandEnabled(other))
    settings.setPackageEnabled(true, extensionID: id)
    #expect(settings.isCommandEnabled(command))
    #expect(!settings.isCommandEnabled(other))
    settings.setPackageEnabled(false, extensionID: id)
    #expect(!settings.isCommandEnabled(command))
}

@Test @MainActor func cachedExtensionCatalogNeverAuthorizesAChangedManifestAtExecution() async throws {
    try ApplicationPaths.prepare()
    let id = "local.cache." + UUID().uuidString
    let folder = ApplicationPaths.extensions.appendingPathComponent(id)
    defer { try? FileManager.default.removeItem(at: folder); ExtensionApprovalStore.revoke(extensionID: id) }
    let inspection = try ExtensionDeveloperKit.create(at: folder, id: id, name: "Cached Tool", template: .aiTool)
    ExtensionApprovalStore.approve(extensionID: id, manifestHash: try #require(inspection.manifestHash), capabilities: [])
    let binding = try #require(ExtensionToolHostAdapterRegistry.approvedBindings().first { $0.extensionID == id })
    let manifest = folder.appendingPathComponent("manifest.json")
    let date = try #require(manifest.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    let text = try String(contentsOf: manifest, encoding: .utf8)
    try text.replacingOccurrences(of: "1.0.0", with: "2.0.0").write(to: manifest, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: manifest.path)
    do {
        _ = try await ExtensionToolHostAdapterRegistry.execute(binding, arguments: .object(["text": .string("fixture"), "operation": .string("uppercase")]))
        Issue.record("A changed manifest must require approval even when its metadata stamp is unchanged")
    } catch {}
}
