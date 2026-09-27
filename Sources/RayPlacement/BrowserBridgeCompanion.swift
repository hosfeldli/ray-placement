import Foundation

/// Exports only the package already verified during app packaging and protected by
/// the app's code signature. Mozilla trust is still checked by the browser.
enum BrowserBridgeCompanion {
    static let fileName = "lima-browser-bridge-signed.xpi"
    static let maximumBytes = 4 * 1024 * 1024

    enum ExportError: Error { case unavailable, invalidDestination }

    static func package(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    static func isAvailable(in directory: URL) -> Bool {
        guard let values = try? package(in: directory).resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        ), values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= maximumBytes else { return false }
        return true
    }

    static func export(from directory: URL, to destination: URL) throws {
        try export(from: directory, to: destination) { package in
            (try? isReviewedPackage(at: package)) == true
        }
    }

    static func export(from directory: URL, to destination: URL, validatePackage: (URL) -> Bool) throws {
        let source = package(in: directory)
        guard isAvailable(in: directory), validatePackage(source) else { throw ExportError.unavailable }
        guard destination.isFileURL, destination.pathExtension.lowercased() == "xpi",
              destination.resolvingSymlinksInPath().standardizedFileURL !=
                source.resolvingSymlinksInPath().standardizedFileURL,
              !isSymlink(destination) else {
            throw ExportError.invalidDestination
        }
        let data = try Data(contentsOf: source, options: [.mappedIfSafe])
        guard !data.isEmpty, data.count <= maximumBytes else { throw ExportError.unavailable }
        // Do not unzip, rewrite the manifest, or otherwise alter Mozilla-signed bytes.
        try data.write(to: destination, options: .atomic)
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func isReviewedPackage(at package: URL) throws -> Bool {
        let executable = Bundle.main.executableURL
        let root = executable?.deletingLastPathComponent().deletingLastPathComponent()
        let verifier = root?.appendingPathComponent("Resources/Documentation/verify_browser_bridge_package.py")
        let verifierPath = verifier?.path ?? "scripts/verify_browser_bridge_package.py"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [verifierPath, package.path, "--require-signature"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
