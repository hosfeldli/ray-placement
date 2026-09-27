import Foundation
import Darwin

public struct BrowserBridgeNativeManifest: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    public var path: String
    public var type: String
    public var allowed_extensions: [String]

    public init(executable: URL) {
        name = BrowserBridgeIdentity.hostName
        description = "Lima Zen / Firefox Browser Bridge"
        path = executable.path
        type = "stdio"
        allowed_extensions = [BrowserBridgeIdentity.extensionID]
    }
}

public enum BrowserBridgeInstallation {
    public static func manifestURLs(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        // Mozilla is Firefox's standard macOS path. Zen may use that path or its
        // product-specific equivalent; install the same restricted manifest in both.
        ["Mozilla", "Zen"].map {
            home.appendingPathComponent("Library/Application Support/\($0)/NativeMessagingHosts/\(BrowserBridgeIdentity.hostName).json")
        }
    }

    public static func install(executable: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        guard executable.isFileURL, executable.path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(BrowserBridgeNativeManifest(executable: executable))
        let urls = manifestURLs(home: home)
        // Validate all destinations before changing either browser registration.
        for url in urls {
            try validateDirectory(url.deletingLastPathComponent())
            if existsWithoutFollowingLinks(url) { try verifyOwnedManifest(at: url) }
        }
        let originals = try urls.map { existsWithoutFollowingLinks($0) ? try Data(contentsOf: $0) : nil }
        var changed: [Int] = []
        do {
            for (index, url) in urls.enumerated() {
                try ensureDirectory(url.deletingLastPathComponent())
                try data.write(to: url, options: .atomic)
                changed.append(index)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        } catch {
            for index in changed.reversed() {
                if let original = originals[index] {
                    try? original.write(to: urls[index], options: .atomic)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: urls[index].path)
                } else {
                    try? FileManager.default.removeItem(at: urls[index])
                }
            }
            throw error
        }
    }

    public static func uninstall(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let urls = manifestURLs(home: home)
        for url in urls {
            try validateDirectory(url.deletingLastPathComponent())
            if existsWithoutFollowingLinks(url) { try verifyOwnedManifest(at: url) }
        }
        for url in urls where existsWithoutFollowingLinks(url) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public static func isInstalled(executable: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return false }
        return manifestURLs(home: home).allSatisfy { url in
            guard (try? validateDirectory(url.deletingLastPathComponent())) != nil,
                  (try? verifyOwnedManifest(at: url)) != nil,
                  let data = try? Data(contentsOf: url),
                  let manifest = try? JSONDecoder().decode(BrowserBridgeNativeManifest.self, from: data) else { return false }
            return manifest == BrowserBridgeNativeManifest(executable: executable)
        }
    }

    private static func verifyOwnedManifest(at url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_size <= 16_384,
              let manifest = try? JSONDecoder().decode(BrowserBridgeNativeManifest.self, from: Data(contentsOf: url)),
              manifest.name == BrowserBridgeIdentity.hostName, manifest.type == "stdio",
              manifest.allowed_extensions == [BrowserBridgeIdentity.extensionID] else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    private static func existsWithoutFollowingLinks(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func validateDirectory(_ url: URL) throws {
        var current = url
        while current.path != "/" {
            var info = stat()
            if lstat(current.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFDIR else { throw CocoaError(.fileWriteNoPermission) }
            }
            current.deleteLastPathComponent()
        }
    }

    public static func ensureDirectory(_ url: URL) throws {
        try validateDirectory(url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
    }
}
