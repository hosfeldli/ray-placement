import Foundation
import Testing
@testable import RayPlacement

@Test func legacyConnectionSettingsArchiveWithoutLosingContents() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LimaLegacyMigration-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let ai = root.appendingPathComponent("AI")
    try FileManager.default.createDirectory(at: ai, withIntermediateDirectories: true)
    let server = ai.appendingPathComponent("mcp-servers.json")
    let clients = ai.appendingPathComponent("access-clients.json")
    try Data("servers".utf8).write(to: server)
    try Data("clients".utf8).write(to: clients)

    try LegacyConnectionMigration.archiveSettings(in: root)
    let archive = root.appendingPathComponent("Legacy Removed Features")
    #expect(!FileManager.default.fileExists(atPath: server.path))
    #expect(!FileManager.default.fileExists(atPath: clients.path))
    #expect(try String(contentsOf: archive.appendingPathComponent("mcp-servers.json")) == "servers")
    #expect(try String(contentsOf: archive.appendingPathComponent("access-clients.json")) == "clients")
    try LegacyConnectionMigration.archiveSettings(in: root)
    #expect(try FileManager.default.contentsOfDirectory(atPath: archive.path).count == 2)
}

@Test func legacyConnectionArchiveDoesNotOverwritePriorArchive() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LimaLegacyMigration-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let ai = root.appendingPathComponent("AI")
    let archive = root.appendingPathComponent("Legacy Removed Features")
    try FileManager.default.createDirectory(at: ai, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    let previous = archive.appendingPathComponent("mcp-servers.json")
    try Data("previous".utf8).write(to: previous)
    try Data("new".utf8).write(to: ai.appendingPathComponent("mcp-servers.json"))

    try LegacyConnectionMigration.archiveSettings(in: root)
    #expect(try String(contentsOf: previous) == "previous")
    let names = try FileManager.default.contentsOfDirectory(atPath: archive.path)
    #expect(names.count == 2)
    let migratedName = try #require(names.first { $0 != "mcp-servers.json" })
    #expect(migratedName.hasPrefix("mcp-servers-"))
    #expect(try String(contentsOf: archive.appendingPathComponent(migratedName)) == "new")
}

@Test func retiredBrowserBridgePreferencesAreRemovedWithoutTouchingBrowserMode() throws {
    let suite = "LegacyBrowserBridgePreferences.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "lima.browserBridge.enabled")
    defaults.set("allowWithJournal", forKey: "lima.ai.computer-action.browserInteraction")
    defaults.set("readOnly", forKey: "limaBrowserAIControlMode")

    LegacyConnectionMigration.retireBrowserBridgePreferences(defaults: defaults)

    #expect(defaults.object(forKey: "lima.browserBridge.enabled") == nil)
    #expect(defaults.object(forKey: "lima.ai.computer-action.browserInteraction") == nil)
    #expect(defaults.string(forKey: "limaBrowserAIControlMode") == "readOnly")
}

@Test func retiredBrowserBridgeMigrationRemovesOnlyOwnedNativeHostManifests() throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent("LimaLegacyBrowserHost-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: home) }
    let mozilla = home.appendingPathComponent("Library/Application Support/Mozilla/NativeMessagingHosts/com.lima.browser_bridge.json")
    let zen = home.appendingPathComponent("Library/Application Support/Zen/NativeMessagingHosts/com.lima.browser_bridge.json")
    try fm.createDirectory(at: mozilla.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.createDirectory(at: zen.deletingLastPathComponent(), withIntermediateDirectories: true)
    let owned: [String: Any] = [
        "name": "com.lima.browser_bridge", "type": "stdio",
        "path": "/Applications/Lima.app/Contents/MacOS/LimaBrowserBridgeHost",
        "allowed_extensions": ["lima-browser-bridge@liamhosfeld.com"]
    ]
    try JSONSerialization.data(withJSONObject: owned).write(to: mozilla)
    var foreign = owned
    foreign["allowed_extensions"] = ["some-other-extension@example.com"]
    try JSONSerialization.data(withJSONObject: foreign).write(to: zen)

    #expect(try LegacyConnectionMigration.retireBrowserBridgeNativeHosts(home: home) == 1)
    #expect(!fm.fileExists(atPath: mozilla.path))
    #expect(fm.fileExists(atPath: zen.path))
    #expect(try LegacyConnectionMigration.retireBrowserBridgeNativeHosts(home: home) == 0)
}
