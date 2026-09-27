import Foundation
import Testing
@testable import RayPlacement

private enum InstallFixtureError: LocalizedError {
    case rejected

    var errorDescription: String? { "fixture rejected the package" }
}

@MainActor
@Test func failedExtensionUpdateRestoresTheCompletePreviousRecord() async {
    let suiteName = "LimaExtensionPackageManagerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let manager = ExtensionPackageManager(defaults: defaults)
    manager.register(
        id: "test.extension.rollback",
        name: "Old Extension",
        version: "1.2.0",
        provenance: .catalogInstalled,
        state: .installed,
        manifestHash: "previous-manifest-hash"
    )
    let original = manager.record(for: "test.extension.rollback")
    let transaction = await manager.performInstall(
        id: "test.extension.rollback",
        name: "Updated Extension",
        version: "2.0.0",
        provenance: .catalogInstalled
    ) {
        throw InstallFixtureError.rejected
    }

    let restored = manager.record(for: "test.extension.rollback")
    #expect(transaction.committed == false)
    #expect(transaction.previous?.version == "1.2.0")
    #expect(restored?.name == original?.name)
    #expect(restored?.version == "1.2.0")
    #expect(restored?.provenance == .catalogInstalled)
    #expect(restored?.state == .installed)
    #expect(restored?.manifestHash == "previous-manifest-hash")
    #expect(restored?.lastError == InstallFixtureError.rejected.localizedDescription)
}

@MainActor
@Test func failedFirstExtensionInstallRemainsRetryableAndVisible() async {
    let suiteName = "LimaExtensionPackageManagerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let manager = ExtensionPackageManager(defaults: defaults)
    let transaction = await manager.performInstall(
        id: "test.extension.first-install",
        name: "New Extension",
        version: "1.0.0",
        provenance: .catalogInstalled
    ) {
        throw InstallFixtureError.rejected
    }

    let record = manager.record(for: "test.extension.first-install")
    #expect(transaction.committed == false)
    #expect(record?.state == .failed)
    #expect(record?.version == "1.0.0")
    #expect(record?.lastError == InstallFixtureError.rejected.localizedDescription)
}

@MainActor
@Test func extensionInstallRecordsTheInstalledVersionAfterCommit() async {
    let suiteName = "LimaExtensionPackageManagerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let manager = ExtensionPackageManager(defaults: defaults)
    let transaction = await manager.performInstall(
        id: "test.extension.install",
        name: "Fixture Extension",
        version: "1.0.0",
        provenance: .catalogInstalled
    ) {}

    let record = manager.record(for: "test.extension.install")
    #expect(transaction.committed)
    #expect(transaction.validationPassed)
    #expect(record?.state == .installed)
    #expect(record?.version == "1.0.0")
    #expect(record?.installedAt != nil)
}
