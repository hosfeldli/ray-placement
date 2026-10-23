import Darwin
import Foundation
import RayPlacementCore

/// Serializes bounded, project-relative file work. No operation accepts an
/// arbitrary absolute path or follows a symbolic link below a managed Project.
actor AIProjectFilesystem {
    enum FileError: LocalizedError {
        case invalidPath, missing, wrongKind, exists, tooLarge, invalidArguments, ambiguousPatch
        var errorDescription: String? {
            switch self {
            case .invalidPath: "Use a relative path inside the active Project; symbolic links and traversal are not allowed."
            case .missing: "The requested Project path does not exist."
            case .wrongKind: "The Project path has the wrong file type for this operation."
            case .exists: "The destination already exists; no data was replaced."
            case .tooLarge: "The file or result exceeds the bounded Project file-tool limit."
            case .invalidArguments: "The Project file-tool arguments are invalid."
            case .ambiguousPatch: "The patch target must occur exactly once."
            }
        }
    }

    private let paths: AIWorkspacePaths
    private let files: FileManager
    private let maximumReadBytes = 160 * 1_024
    private let maximumWriteBytes = 1_024 * 1_024

    init(paths: AIWorkspacePaths = AIWorkspacePaths(), files: FileManager = .default) {
        self.paths = paths
        self.files = files
    }

    private func root(_ id: UUID) throws -> URL {
        let parent = paths.projects
        let directory = paths.project(id)
        guard directory.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL,
              UUID(uuidString: directory.lastPathComponent) == id else { throw FileError.invalidPath }
        try require(directory, directory: true)
        return directory
    }

    private func require(_ url: URL, directory: Bool? = nil) throws {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        } catch { throw FileError.missing }
        guard values.isSymbolicLink != true else { throw FileError.invalidPath }
        if let directory {
            guard directory ? values.isDirectory == true : values.isRegularFile == true else {
                throw FileError.wrongKind
            }
        }
    }

    private func path(_ raw: String, root: URL, allowRoot: Bool = false) throws -> URL {
        guard !raw.isEmpty, raw.utf8.count <= 2_048, !raw.hasPrefix("/"),
              !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw FileError.invalidPath
        }
        if raw == "." {
            guard allowRoot else { throw FileError.invalidPath }
            return root
        }
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !parts.contains(where: { $0 == ".git" || $0 == ".env" || $0 == ".ssh" }) else {
            throw FileError.invalidPath
        }
        var url = root
        for part in parts {
            url.appendPathComponent(String(part))
            if files.fileExists(atPath: url.path) || (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                try require(url)
            }
        }
        guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            throw FileError.invalidPath
        }
        return url
    }

    private func string(_ key: String, _ args: [String: JSONValue]) throws -> String {
        guard case .string(let value)? = args[key] else { throw FileError.invalidArguments }
        return value
    }

    private func integer(_ key: String, _ args: [String: JSONValue], default fallback: Int) throws -> Int {
        guard let value = args[key] else { return fallback }
        guard case .number(let number) = value, number.isFinite,
              number.rounded() == number, number >= 0, number < Double(Int.max) else {
            throw FileError.invalidArguments
        }
        return Int(number)
    }

    private func boolean(_ key: String, _ args: [String: JSONValue], default fallback: Bool) throws -> Bool {
        guard let value = args[key] else { return fallback }
        guard case .bool(let result) = value else { throw FileError.invalidArguments }
        return result
    }

    private func readText(_ url: URL) throws -> String {
        try require(url, directory: false)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumReadBytes else { throw FileError.tooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumReadBytes, !data.contains(0),
              let content = String(data: data, encoding: .utf8) else { throw FileError.wrongKind }
        return content
    }

    private func writeText(_ content: String, to url: URL) throws {
        let data = Data(content.utf8)
        guard data.count <= maximumWriteBytes else { throw FileError.tooLarge }
        try require(url.deletingLastPathComponent(), directory: true)
        try data.write(to: url, options: .atomic)
    }

    private func entries(_ root: URL, maxDepth: Int, maximum: Int = 400) throws -> [(String, URL, Bool)] {
        try require(root, directory: true)
        guard let enumerator = files.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else { throw FileError.missing }
        var result: [(String, URL, Bool)] = []
        while let child = enumerator.nextObject() as? URL {
            if result.count >= maximum { break }
            let relative = String(child.path.dropFirst(root.path.count + 1))
            let depth = relative.split(separator: "/").count
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true || relative.split(separator: "/").contains(where: {
                $0 == ".git" || $0 == ".env" || $0 == ".ssh"
            }) {
                enumerator.skipDescendants()
                continue
            }
            if depth > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            let directory = values.isDirectory == true
            if directory && depth >= maxDepth { enumerator.skipDescendants() }
            guard directory || values.isRegularFile == true else { continue }
            result.append((relative, child, directory))
        }
        return result.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    private func strings(_ items: [String]) -> JSONValue { .array(items.map(JSONValue.string)) }

    func execute(_ operation: String, projectID: UUID,
                 arguments args: [String: JSONValue]) throws -> JSONValue {
        let base = try root(projectID)
        let rawPath = try string("path", args)
        let target = try path(rawPath, root: base, allowRoot: true)
        switch operation {
        case "file_read":
            return .object(["path": .string(rawPath), "content": .string(try readText(target))])
        case "file_read_range":
            let content = try readText(target)
            let start = try integer("start_line", args, default: 1)
            let length = try integer("length", args, default: 200)
            guard start >= 1, (1...400).contains(length) else { throw FileError.invalidArguments }
            let lines = content.components(separatedBy: "\n")
            let selected = Array(lines.dropFirst(start - 1).prefix(length)).enumerated()
                .map { "\(start + $0.offset)\t\($0.element)" }.joined(separator: "\n")
            return .object(["path": .string(rawPath), "start_line": .number(Double(start)),
                            "total_lines": .number(Double(lines.count)), "content": .string(selected)])
        case "file_write":
            guard rawPath != "." else { throw FileError.invalidPath }
            let overwrite = try boolean("overwrite", args, default: false)
            if files.fileExists(atPath: target.path) {
                try require(target, directory: false)
                guard overwrite else { throw FileError.exists }
            }
            let content = try string("content", args)
            try writeText(content, to: target)
            return .object(["path": .string(rawPath), "bytes": .number(Double(content.utf8.count)),
                            "written": .bool(true)])
        case "file_patch":
            let old = try string("old_text", args)
            let replacement = try string("new_text", args)
            guard !old.isEmpty, old != replacement else { throw FileError.invalidArguments }
            let content = try readText(target)
            let occurrences = content.components(separatedBy: old).count - 1
            guard occurrences == 1 else { throw FileError.ambiguousPatch }
            let revised = content.replacingOccurrences(of: old, with: replacement)
            try writeText(revised, to: target)
            return .object(["path": .string(rawPath), "patched": .bool(true)])
        case "file_list", "file_tree":
            try require(target, directory: true)
            let depth = operation == "file_list" ? 1 : try integer("max_depth", args, default: 4)
            guard (1...8).contains(depth) else { throw FileError.invalidArguments }
            let items = try entries(target, maxDepth: depth)
            return .object(["path": .string(rawPath),
                            "entries": .array(items.map { .object([
                                "path": .string($0.0), "kind": .string($0.2 ? "directory" : "file")
                            ]) }), "truncated": .bool(items.count >= 400)])
        case "file_find", "file_glob", "file_search":
            try require(target, directory: true)
            let query = try string("query", args)
            guard !query.isEmpty, query.utf8.count <= 160 else { throw FileError.invalidArguments }
            let items = try entries(target, maxDepth: 12, maximum: 1_000).filter { !$0.2 }
            if operation == "file_search" {
                var matches: [JSONValue] = []
                for item in items {
                    guard let content = try? readText(item.1) else { continue }
                    for (index, line) in content.components(separatedBy: "\n").enumerated() {
                        if line.localizedCaseInsensitiveContains(query) {
                            matches.append(.object(["path": .string(item.0),
                                                    "line": .number(Double(index + 1)),
                                                    "excerpt": .string(String(line.prefix(240)))]))
                            if matches.count >= 80 { break }
                        }
                    }
                    if matches.count >= 80 { break }
                }
                return .object(["path": .string(rawPath), "matches": .array(matches),
                                "truncated": .bool(matches.count >= 80 || items.count >= 1_000)])
            }
            let found = items.map(\.0).filter { name in
                operation == "file_find" ? name.localizedCaseInsensitiveContains(query)
                    : fnmatch(query, name, 0) == 0
            }
            return .object(["path": .string(rawPath), "matches": strings(Array(found.prefix(200))),
                            "truncated": .bool(found.count > 200 || items.count >= 1_000)])
        case "project_file_metadata":
            try require(target)
            let values = try target.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            return .object(["path": .string(rawPath), "kind": .string(values.isDirectory == true ? "directory" : "file"),
                            "bytes": .number(Double(values.fileSize ?? 0)),
                            "modified_at": .number(values.contentModificationDate?.timeIntervalSince1970 ?? 0)])
        case "directory_create":
            guard rawPath != ".", !files.fileExists(atPath: target.path) else { throw FileError.exists }
            try require(target.deletingLastPathComponent(), directory: true)
            try files.createDirectory(at: target, withIntermediateDirectories: false)
            return .object(["path": .string(rawPath), "created": .bool(true)])
        case "file_move", "file_copy":
            guard rawPath != "." else { throw FileError.invalidPath }
            try require(target, directory: operation == "file_copy" ? false : nil)
            let destinationName = try string("destination", args)
            let destination = try path(destinationName, root: base)
            guard !files.fileExists(atPath: destination.path) else { throw FileError.exists }
            try require(destination.deletingLastPathComponent(), directory: true)
            if operation == "file_copy" { try files.copyItem(at: target, to: destination) }
            else { try files.moveItem(at: target, to: destination) }
            return .object(["path": .string(rawPath), "destination": .string(destinationName),
                            "completed": .bool(true)])
        case "file_delete", "directory_delete":
            guard rawPath != "." else { throw FileError.invalidPath }
            let directory = operation == "directory_delete"
            try require(target, directory: directory)
            if directory {
                guard try files.contentsOfDirectory(atPath: target.path).isEmpty else { throw FileError.wrongKind }
            }
            try files.removeItem(at: target)
            return .object(["path": .string(rawPath), "deleted": .bool(true)])
        default:
            throw FileError.invalidArguments
        }
    }
}
