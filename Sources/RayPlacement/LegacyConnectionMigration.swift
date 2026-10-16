import Darwin
import Foundation
import Security

/// Retires settings and credentials owned by connection features removed from Lima.
/// The archive is intentionally retained for one release rather than discarded.
enum LegacyConnectionMigration {
    static func runAtLaunch() throws {
        let root = LimaTestEnvironment.dataRoot ?? ApplicationPaths.applicationSupport
        try archiveSettings(in: root)
        retireBrowserBridgePreferences(defaults: LimaTestEnvironment.userDefaults)
        // Fixture and preview runs must never touch production browser registration or Keychain records.
        if !LimaTestEnvironment.isEnabled {
            try retireBrowserBridgeNativeHosts()
        }
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

    static func retireBrowserBridgePreferences(defaults: UserDefaults) {
        for key in [
            "lima.browserBridge.enabled", "lima.browserBridge.backgroundTabs",
            "lima.ai.experimental.broad-browser-grants", "lima.ai.experimental.browser-interaction",
            "lima.ai.computer-action.browserNavigation", "lima.ai.computer-action.browserInteraction",
            "lima.ai.browser-capabilities-v1"
        ] {
            defaults.removeObject(forKey: key)
        }
    }

    /// Remove only manifests created by Lima's retired Firefox/Zen native host.
    /// Do not follow symlinks or remove a file that another app has placed at the
    /// same path. The old browser extension itself must be removed in the browser.
    @discardableResult
    static func retireBrowserBridgeNativeHosts(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws -> Int {
        var removed = 0
        let canonicalHome = home.resolvingSymlinksInPath()
        for browser in ["Mozilla", "Zen"] {
            let manifest = canonicalHome.appendingPathComponent(
                "Library/Application Support/\(browser)/NativeMessagingHosts/com.lima.browser_bridge.json"
            )
            guard isOwnedLegacyBrowserBridgeManifest(manifest, within: canonicalHome) else { continue }
            try fileManager.removeItem(at: manifest)
            removed += 1
        }
        return removed
    }

    private static func isOwnedLegacyBrowserBridgeManifest(_ url: URL, within home: URL) -> Bool {
        var directory = url.deletingLastPathComponent()
        while true {
            var info = stat()
            guard lstat(directory.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR else { return false }
            if directory.path == home.path { break }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { return false }
            directory = parent
        }
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1,
              (0...16_384).contains(info.st_size),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(LegacyBrowserBridgeManifest.self, from: data) else {
            return false
        }
        return manifest.name == "com.lima.browser_bridge"
            && manifest.type == "stdio"
            && manifest.allowed_extensions == ["lima-browser-bridge@liamhosfeld.com"]
            && URL(fileURLWithPath: manifest.path).lastPathComponent == "LimaBrowserBridgeHost"
    }

    private struct LegacyBrowserBridgeManifest: Decodable {
        let name: String
        let path: String
        let type: String
        let allowed_extensions: [String]
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
