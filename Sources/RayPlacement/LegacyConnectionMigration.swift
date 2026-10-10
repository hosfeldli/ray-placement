import Foundation
import Security

/// Retires settings and credentials owned by connection features removed from Lima.
/// The archive is intentionally retained for one release rather than discarded.
enum LegacyConnectionMigration {
    static func runAtLaunch() throws {
        let root = LimaTestEnvironment.dataRoot ?? ApplicationPaths.applicationSupport
        try archiveSettings(in: root)
        // Fixture and preview runs must never touch production Keychain records.
        removeCredentials(testOnly: LimaTestEnvironment.isEnabled)
    }

    static func archiveSettings(in root: URL, fileManager: FileManager = .default) throws {
        let sourceDirectory = root.appendingPathComponent("AI", isDirectory: true)
        let archiveDirectory = root.appendingPathComponent("Legacy Removed Features", isDirectory: true)
        let filenames = ["mcp-servers.json", "access-clients.json"]
        for filename in filenames {
            let source = sourceDirectory.appendingPathComponent(filename)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try fileManager.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: archiveDirectory.path)
            var destination = archiveDirectory.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: destination.path) {
                let stem = (filename as NSString).deletingPathExtension
                destination = archiveDirectory.appendingPathComponent("\(stem)-\(UUID().uuidString).json")
            }
            try fileManager.moveItem(at: source, to: destination)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
    }

    private static func removeCredentials(testOnly: Bool) {
        let suffixes = testOnly ? [".test"] : [""]
        for suffix in suffixes {
            for service in [
                "dev.liam.lima.mcp",
                "dev.liam.lima.access",
                "dev.liam.lima.access.network-certificate"
            ] {
                SecItemDelete([
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service + suffix
                ] as CFDictionary)
            }
            SecItemDelete([
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: Data(("dev.liam.lima.access.network-key" + suffix).utf8)
            ] as CFDictionary)
            SecItemDelete([
                kSecClass as String: kSecClassCertificate,
                kSecAttrLabel as String: "Lima Access Network TLS" + suffix
            ] as CFDictionary)
        }
    }
}
