import Foundation
import Testing
@testable import RayPlacementCore

@Test func privateFileStoreDistinguishesMissingAndCorruptData() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lima-private-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PrivateFileStore()
    let url = directory.appendingPathComponent("state.json")
    #expect(store.loadData(from: url).state == .missing)
    try store.write(data: Data("{not-json".utf8), to: url, backupExisting: false)
    let loaded = store.loadJSON([String: String].self, from: url)
    #expect(loaded.result.state == .corrupt)
    #expect(loaded.value == nil)
    #expect(loaded.result.recoveryURL != nil)
}

@Test func privateFileStoreWritesPrivatePermissions() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lima-permissions-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PrivateFileStore()
    let url = directory.appendingPathComponent("private.json")
    try store.write(data: Data("{}".utf8), to: url, backupExisting: false)
    let fileMode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
    #expect(fileMode?.intValue == 0o600)
    #expect(directoryMode?.intValue == 0o700)
}
