import Foundation

/// GUI apps do not inherit the interactive shell's PATH. Find the installed
/// launcher and its runtime without executing shell startup files.
enum CLILaunchEnvironment {
    struct Plan {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
    }

    static func directories(environment: [String: String], home: URL, executable: URL? = nil) -> [String] {
        let bunRoot = environment["BUN_INSTALL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? home.appendingPathComponent(".bun").path
        var paths = [bunRoot + "/bin", bunRoot + "/install/global/node_modules/.bin", home.appendingPathComponent(".bun/bin").path]
        if let globalBin = environment["BUN_INSTALL_GLOBAL_BIN"] { paths.insert(globalBin, at: 0) }
        if let executable {
            paths.insert(executable.deletingLastPathComponent().path, at: 0)
            let resolved = executable.resolvingSymlinksInPath().path
            if let range = resolved.range(of: "/install/global/node_modules/") {
                paths.insert(String(resolved[..<range.lowerBound]) + "/bin", at: 0)
            }
        }
        paths += [home.appendingPathComponent(".opencode/bin").path,
                  home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        paths += (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return paths.filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    }

    static func configuredPath(for provider: AIProvider) -> String {
        LimaTestEnvironment.userDefaults.string(forKey: "lima.cli.executable." + provider.rawValue) ?? ""
    }

    static func setConfiguredPath(_ path: String, for provider: AIProvider) throws {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.isEmpty || (path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path)) else {
            throw CocoaError(.fileNoSuchFile)
        }
        LimaTestEnvironment.userDefaults.set(path, forKey: "lima.cli.executable." + provider.rawValue)
    }

    static func find(_ name: String, environment: [String: String], home: URL, override: String = "") -> URL? {
        if !override.isEmpty {
            return FileManager.default.isExecutableFile(atPath: override) ? URL(fileURLWithPath: override) : nil
        }
        return directories(environment: environment, home: home).lazy.map {
            URL(fileURLWithPath: $0).appendingPathComponent(name)
        }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func plan(executable: URL, arguments: [String], environment inherited: [String: String],
                     home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Plan {
        var environment = inherited
        let paths = directories(environment: inherited, home: home, executable: executable)
        environment["PATH"] = paths.joined(separator: ":")
        let resolved = executable.resolvingSymlinksInPath()
        let shebang: String = {
            guard let file = try? FileHandle(forReadingFrom: resolved) else { return "" }
            defer { try? file.close() }
            let data = (try? file.read(upToCount: 256)) ?? Data()
            return String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
        }()
        let bunRoot = inherited["BUN_INSTALL"] ?? home.appendingPathComponent(".bun").path
        let managedByBun = resolved.path.hasPrefix(bunRoot + "/") || resolved.path.contains("/install/global/node_modules/")
        let nodeExists = paths.contains { FileManager.default.isExecutableFile(atPath: $0 + "/node") }
        let interpreter = shebang.hasPrefix("#!") ? String(shebang.dropFirst(2)).split(whereSeparator: \.isWhitespace).map(String.init) : []
        let program = interpreter.first.map { URL(fileURLWithPath: $0).lastPathComponent }
        let usesNode = program == "node" || (program == "env" && interpreter.dropFirst().first(where: { !$0.hasPrefix("-") }) == "node")
        if usesNode,
           managedByBun || !nodeExists,
           let bun = paths.map({ URL(fileURLWithPath: $0).appendingPathComponent("bun") })
                .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return Plan(executable: bun, arguments: ["run", "--bun", resolved.path] + arguments, environment: environment)
        }
        return Plan(executable: executable, arguments: arguments, environment: environment)
    }
}
