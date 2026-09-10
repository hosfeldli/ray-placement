import CryptoKit
import Foundation

public enum ExtensionSecurityError: Error, Equatable, Sendable {
    case traversalOutsideExtension
    case externalExecutionNotApproved
    case invalidExecutablePath
}

public enum ExtensionSecurityPolicy {
    /// Resolves an extension-provided path without allowing relative traversal
    /// outside the extension directory. Absolute paths are treated as external
    /// executables and require the explicit externalExecution capability.
    public static func resolvePath(
        _ rawPath: String,
        relativeTo extensionDirectory: URL,
        capabilities: Set<ExtensionManifest.Capability>,
        executable: Bool
    ) throws -> URL {
        let expanded = NSString(string: rawPath).expandingTildeInPath
        guard !expanded.isEmpty, !expanded.contains("\0") else {
            throw ExtensionSecurityError.invalidExecutablePath
        }
        if expanded.hasPrefix("/") {
            guard !executable || capabilities.contains(.externalExecution) else {
                throw ExtensionSecurityError.externalExecutionNotApproved
            }
            // Non-executable file/application actions may intentionally open an
            // external user-selected resource. Executable actions are the
            // security boundary and require explicit externalExecution.
            return URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL
        }

        let root = extensionDirectory.resolvingSymlinksInPath().standardizedFileURL
        var resolved = root
        for component in expanded.split(separator: "/", omittingEmptySubsequences: true) {
            resolved.appendPathComponent(String(component))
            // resolvingSymlinksInPath() only resolves links that are part of
            // the existing path. Resolve each existing prefix before appending
            // a potentially nonexistent child, so a link such as
            // `linked/new-script` cannot evade the containment check.
            resolved = resolved.resolvingSymlinksInPath().standardizedFileURL
            guard isContained(resolved, in: root) else {
                throw ExtensionSecurityError.traversalOutsideExtension
            }
        }
        guard isContained(resolved, in: root) else {
            throw ExtensionSecurityError.traversalOutsideExtension
        }
        return resolved
    }

    public static func manifestHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isContained(_ child: URL, in root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return child.path == root.path || child.path.hasPrefix(rootPath)
    }
}
