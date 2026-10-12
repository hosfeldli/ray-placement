import Foundation
import UniformTypeIdentifiers

/// Structured, bounded reads for understanding a local project without
/// starting a terminal or asking the provider to invent shell commands.
@MainActor
enum AIWorkspaceReadTools {
    static let ids: Set<String> = ["search_workspace_text", "inspect_directory_tree"]

    static let definitions: [LimaAIToolDefinition] = [
        LimaAIToolDefinition(
            id: "search_workspace_text",
            name: "search_workspace_text",
            description: "Search literal text inside safe UTF-8 source and text files below an absolute directory. Runs off the UI thread, skips hidden and symbolic-link paths, and returns bounded line-numbered excerpts. It does not change files or search sensitive locations.",
            parameters: [
                "type": "object",
                "properties": [
                    "directory": ["type": "string", "description": "Absolute directory to search recursively."],
                    "query": ["type": "string", "description": "Literal text to find, at most 120 characters."]
                ],
                "required": ["directory", "query"],
                "additionalProperties": false
            ],
            risk: .read
        ),
        LimaAIToolDefinition(
            id: "inspect_directory_tree",
            name: "inspect_directory_tree",
            description: "Inspect a bounded project directory tree without reading file contents. Returns safe relative paths and kinds, skips hidden and symbolic-link paths, and stops after three levels by default.",
            parameters: [
                "type": "object",
                "properties": [
                    "directory": ["type": "string", "description": "Absolute directory to inspect."],
                    "max_depth": ["type": "integer", "minimum": 1, "maximum": 4,
                                  "description": "Optional maximum descendant depth, from 1 to 4; defaults to 3."]
                ],
                "required": ["directory"],
                "additionalProperties": false
            ],
            risk: .read
        )
    ]

    static func execute(_ call: AIOutputItem) async -> LimaAIToolExecution {
        guard let directory = LimaAIToolRegistry.stringArgument(named: "directory", from: call.arguments),
              directory.hasPrefix("/"), directory.utf8.count <= 2_048 else {
            return .json(["error": "Workspace inspection needs an absolute directory path."], isError: true)
        }
        switch call.name {
        case "search_workspace_text":
            guard let query = LimaAIToolRegistry.stringArgument(named: "query", from: call.arguments),
                  !query.isEmpty, query.count <= 120,
                  !query.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                return .json(["error": "Search needs 1 to 120 characters of literal text."], isError: true)
            }
            let scan = Task.detached(priority: .utility) {
                BoundedWorkspaceScanner.search(directory: directory, query: query)
            }
            let result = await withTaskCancellationHandler {
                await scan.value
            } onCancel: {
                scan.cancel()
            }
            if let error = result.error { return .json(["error": error], isError: true) }
            return .json([
                "directory": result.directory,
                "query": query,
                "matches": result.matches.map {
                    ["path": $0.path, "line": $0.line, "excerpt": $0.excerpt] as [String: Any]
                },
                "files_scanned": result.filesScanned,
                "truncated": result.truncated
            ])
        case "inspect_directory_tree":
            let depth = LimaAIToolRegistry.integerArgument(named: "max_depth", from: call.arguments) ?? 3
            guard (1...4).contains(depth),
                  !LimaAIToolRegistry.hasArgument(named: "max_depth", from: call.arguments)
                    || LimaAIToolRegistry.integerArgument(named: "max_depth", from: call.arguments) != nil else {
                return .json(["error": "Directory depth must be an integer from 1 to 4."], isError: true)
            }
            let scan = Task.detached(priority: .utility) {
                BoundedWorkspaceScanner.tree(directory: directory, maxDepth: depth)
            }
            let result = await withTaskCancellationHandler {
                await scan.value
            } onCancel: {
                scan.cancel()
            }
            if let error = result.error { return .json(["error": error], isError: true) }
            return .json([
                "directory": result.directory,
                "max_depth": depth,
                "entries": result.entries.map {
                    ["path": $0.path, "kind": $0.kind] as [String: Any]
                },
                "truncated": result.truncated
            ])
        default:
            return .json(["error": "Unknown workspace read tool."], isError: true)
        }
    }
}

private enum BoundedWorkspaceScanner {
    struct TextMatch: Sendable {
        let path: String
        let line: Int
        let excerpt: String
    }

    struct TreeEntry: Sendable {
        let path: String
        let kind: String
    }

    struct SearchResult: Sendable {
        let directory: String
        let matches: [TextMatch]
        let filesScanned: Int
        let truncated: Bool
        let error: String?
    }

    struct TreeResult: Sendable {
        let directory: String
        let entries: [TreeEntry]
        let truncated: Bool
        let error: String?
    }

    private static let maximumTextBytes = 96 * 1_024
    private static let maximumSearchFiles = 400
    private static let maximumSearchEntries = 1_600
    private static let maximumMatches = 48
    private static let maximumTreeEntries = 180
    private static let deadline: TimeInterval = 3

    private static func root(_ directory: String) -> URL? {
        let requested = URL(fileURLWithPath: directory).standardizedFileURL
        guard (try? requested.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            return nil
        }
        let resolved = requested.resolvingSymlinksInPath()
        guard !LimaAIToolRegistry.isSensitivePath(resolved),
              !resolved.pathComponents.contains(where: { $0.hasPrefix(".") && $0 != "." && $0 != ".." }),
              (try? resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return nil
        }
        return resolved
    }

    private static func childIsSafe(_ child: URL, root: URL, values: URLResourceValues?) -> Bool {
        guard values?.isSymbolicLink != true else { return false }
        let resolved = child.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = root.path == "/" ? "/" : root.path + "/"
        return resolved.path.hasPrefix(prefix)
            && !LimaAIToolRegistry.isSensitivePath(resolved)
    }

    static func search(directory: String, query: String) -> SearchResult {
        guard let root = root(directory),
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                                             .fileSizeKey, .contentTypeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else {
            return SearchResult(directory: directory, matches: [], filesScanned: 0, truncated: false,
                                error: "That directory is unavailable, hidden, symbolic, or sensitive.")
        }
        let started = Date()
        var entriesSeen = 0
        var filesScanned = 0
        var matches: [TextMatch] = []
        var truncated = false
        while let child = enumerator.nextObject() as? URL {
            if Task.isCancelled || Date().timeIntervalSince(started) >= deadline
                || entriesSeen >= maximumSearchEntries || filesScanned >= maximumSearchFiles {
                truncated = true
                break
            }
            entriesSeen += 1
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey,
                                                              .isSymbolicLinkKey, .fileSizeKey, .contentTypeKey])
            guard childIsSafe(child, root: root, values: values) else {
                if values?.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values?.isDirectory == true { continue }
            guard values?.isRegularFile == true,
                  let size = values?.fileSize, size <= maximumTextBytes,
                  LimaAIToolRegistry.isTextFile(url: child, contentType: values?.contentType),
                  let data = try? Data(contentsOf: child), data.count <= maximumTextBytes,
                  !data.contains(0),
                  let text = String(data: data, encoding: .utf8),
                  !text.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0) && ![9, 10, 13].contains(Int($0.value))
                  }) else { continue }
            filesScanned += 1
            var fileMatches = 0
            for (number, line) in text.replacingOccurrences(of: "\r\n", with: "\n")
                .components(separatedBy: "\n").enumerated() {
                guard let range = line.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
                    continue
                }
                let start = line.index(range.lowerBound, offsetBy: -80, limitedBy: line.startIndex) ?? line.startIndex
                let end = line.index(range.lowerBound, offsetBy: 160, limitedBy: line.endIndex) ?? line.endIndex
                matches.append(TextMatch(path: child.path, line: number + 1,
                                         excerpt: String(line[start..<end])))
                fileMatches += 1
                if matches.count >= maximumMatches || fileMatches >= 3 { break }
            }
            if matches.count >= maximumMatches {
                truncated = true
                break
            }
        }
        return SearchResult(directory: root.path, matches: matches, filesScanned: filesScanned,
                            truncated: truncated, error: nil)
    }

    static func tree(directory: String, maxDepth: Int) -> TreeResult {
        guard let root = root(directory),
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else {
            return TreeResult(directory: directory, entries: [], truncated: false,
                              error: "That directory is unavailable, hidden, symbolic, or sensitive.")
        }
        let started = Date()
        var entries: [TreeEntry] = []
        var truncated = false
        while let child = enumerator.nextObject() as? URL {
            if Task.isCancelled || Date().timeIntervalSince(started) >= deadline
                || entries.count >= maximumTreeEntries {
                truncated = true
                break
            }
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard childIsSafe(child, root: root, values: values) else {
                if values?.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            let prefix = root.path == "/" ? "/" : root.path + "/"
            let relative = String(child.path.dropFirst(prefix.count))
            let depth = relative.split(separator: "/").count
            if depth > maxDepth {
                if values?.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            let isDirectory = values?.isDirectory == true
            if isDirectory && depth >= maxDepth { enumerator.skipDescendants() }
            guard isDirectory || values?.isRegularFile == true else { continue }
            entries.append(TreeEntry(path: relative, kind: isDirectory ? "directory" : "file"))
        }
        entries.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return TreeResult(directory: root.path, entries: entries, truncated: truncated, error: nil)
    }
}
