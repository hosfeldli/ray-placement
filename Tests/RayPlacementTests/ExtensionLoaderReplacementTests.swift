import Foundation
import Testing
@testable import RayPlacement

private enum ExtensionReplacementFixtureError: Error {
    case activationFailed
}

@MainActor
private func extensionReplacementFixture() throws -> (
    root: URL, source: URL, destination: URL
) {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        "LimaExtensionReplacementTests-\(UUID().uuidString)", isDirectory: true
    )
    let source = root.appendingPathComponent("shipped/demo", isDirectory: true)
    let destination = root.appendingPathComponent("installed/demo", isDirectory: true)
    try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
    try "shipped".write(
        to: source.appendingPathComponent("marker.txt"),
        atomically: true, encoding: .utf8
    )
    try "installed".write(
        to: destination.appendingPathComponent("marker.txt"),
        atomically: true, encoding: .utf8
    )
    return (root, source, destination)
}

@Test @MainActor func bundledExtensionRepairKeepsPreviousCopyAsBackup() throws {
    let fixture = try extensionReplacementFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let backup = fixture.root.appendingPathComponent(
        "installed/.repair-backups/demo", isDirectory: true
    )

    try ExtensionLoader.replaceBundledPack(
        source: fixture.source, destination: fixture.destination, backup: backup
    )

    #expect(try String(
        contentsOf: fixture.destination.appendingPathComponent("marker.txt"),
        encoding: .utf8
    ) == "shipped")
    #expect(try String(
        contentsOf: backup.appendingPathComponent("marker.txt"),
        encoding: .utf8
    ) == "installed")
}

@Test @MainActor func failedBundledExtensionActivationRestoresOriginal() throws {
    let fixture = try extensionReplacementFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    #expect(throws: ExtensionReplacementFixtureError.self) {
        try ExtensionLoader.replaceBundledPack(
            source: fixture.source, destination: fixture.destination
        ) { _, _ in
            throw ExtensionReplacementFixtureError.activationFailed
        }
    }

    #expect(try String(
        contentsOf: fixture.destination.appendingPathComponent("marker.txt"),
        encoding: .utf8
    ) == "installed")
    let installedRoot = fixture.destination.deletingLastPathComponent()
    let names = try FileManager.default.contentsOfDirectory(
        at: installedRoot, includingPropertiesForKeys: nil
    ).map(\.lastPathComponent)
    #expect(names == ["demo"])
}

@Test @MainActor func partialBundledExtensionActivationRestoresOriginal() throws {
    let fixture = try extensionReplacementFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    #expect(throws: ExtensionReplacementFixtureError.self) {
        try ExtensionLoader.replaceBundledPack(
            source: fixture.source, destination: fixture.destination
        ) { staged, destination in
            try FileManager.default.copyItem(at: staged, to: destination)
            throw ExtensionReplacementFixtureError.activationFailed
        }
    }

    #expect(try String(
        contentsOf: fixture.destination.appendingPathComponent("marker.txt"),
        encoding: .utf8
    ) == "installed")
    let names = try FileManager.default.contentsOfDirectory(
        at: fixture.destination.deletingLastPathComponent(),
        includingPropertiesForKeys: nil
    ).map(\.lastPathComponent)
    #expect(names == ["demo"])
}

@Test @MainActor func missingShippedExtensionDoesNotRemoveInstalledCopy() throws {
    let fixture = try extensionReplacementFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try FileManager.default.removeItem(at: fixture.source)

    #expect(throws: Error.self) {
        try ExtensionLoader.replaceBundledPack(
            source: fixture.source, destination: fixture.destination
        )
    }
    #expect(try String(
        contentsOf: fixture.destination.appendingPathComponent("marker.txt"),
        encoding: .utf8
    ) == "installed")
}
