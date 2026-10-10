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
