import Foundation
import Testing
@testable import RayPlacementCore

@Test func browserBridgeInstallationPreflightsAllDestinationsBeforeChangingAnyManifest() throws {
    let root = URL(fileURLWithPath: "/private/tmp/bridge-preflight-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = BrowserBridgeInstallation.manifestURLs(home: root)
    try FileManager.default.createDirectory(at: paths[1].deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("foreign".utf8).write(to: paths[1])
    #expect(throws: (any Error).self) {
        try BrowserBridgeInstallation.install(executable: URL(fileURLWithPath: "/usr/bin/true"), home: root)
    }
    #expect(!FileManager.default.fileExists(atPath: paths[0].path))
    #expect(try String(contentsOf: paths[1], encoding: .utf8) == "foreign")
}

@Test func browserBridgeInstallerRejectsDanglingManifestAndParentSymlinks() throws {
    let root = URL(fileURLWithPath: "/private/tmp/bridge-links-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let path = BrowserBridgeInstallation.manifestURLs(home: root)[0]
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    let missing = root.appendingPathComponent("missing")
    try FileManager.default.createSymbolicLink(at: path, withDestinationURL: missing)
    #expect(throws: (any Error).self) {
        try BrowserBridgeInstallation.install(executable: URL(fileURLWithPath: "/usr/bin/true"), home: root)
    }
    #expect(throws: (any Error).self) { try BrowserBridgeInstallation.uninstall(home: root) }
    #expect(!FileManager.default.fileExists(atPath: missing.path))
    try FileManager.default.removeItem(at: path)
    try FileManager.default.removeItem(at: path.deletingLastPathComponent())
    let external = root.appendingPathComponent("external")
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: path.deletingLastPathComponent(), withDestinationURL: external)
    #expect(throws: (any Error).self) {
        try BrowserBridgeInstallation.install(executable: URL(fileURLWithPath: "/usr/bin/true"), home: root)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
}
