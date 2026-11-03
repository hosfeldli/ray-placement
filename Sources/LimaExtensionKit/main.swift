import Foundation
import RayPlacementCore

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8)); exit(code)
}
func folder(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardizedFileURL }
func checked(_ directory: URL) -> ExtensionInspection {
    let result = ExtensionDeveloperKit.inspect(directory)
    for issue in result.diagnostics { print("\(issue.severity.rawValue.uppercased()) \(issue.path): \(issue.message)\n  Fix: \(issue.fix)") }
    guard result.isValid else { fail("Extension check failed. No code was executed.") }
    return result
}
func launch(_ executable: URL, arguments: [String], directory: URL, timeout: Int = 60) throws -> Int32 {
    let process = Process(); process.executableURL = executable; process.arguments = arguments; process.currentDirectoryURL = directory
    process.standardInput = FileHandle.standardInput; process.standardOutput = FileHandle.standardOutput; process.standardError = FileHandle.standardError
    try process.run()
    let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout), execute: deadline)
    process.waitUntilExit(); deadline.cancel(); return process.terminationStatus
}
let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("Use lima-extension help", code: 2) }
do {
    switch command {
    case "help", "--help", "-h":
        print("""
        Lima Extension Kit · schema v3

        init <new-folder> --id <stable-id> --name <name> [--template link|script|form|ai-tool]
        check <folder> [--json]                Inspect without executing code
        run <folder> <command-id> [field=value ...]   Explicit local script/form test
        pack <folder> <output.zip>             Validate and build a shareable package

        Build once: swift build --product lima-extension
        Then use .build/debug/lima-extension, or swift run lima-extension <command>.
        In Lima: Extensions → Add Folder → review permissions → enable.
        """)
    case "init":
        guard args.count >= 2 else { fail("Provide a new folder.", code: 2) }
        func option(_ flag: String) -> String? { guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }; return args[index + 1] }
        guard let id = option("--id"), let name = option("--name"), let template = ExtensionDeveloperKit.Template(rawValue: option("--template") ?? "script") else { fail("Provide --id and --name, and a template of link, script, form or ai-tool.", code: 2) }
        let result = try ExtensionDeveloperKit.create(at: folder(args[1]), id: id, name: name, template: template)
        guard result.isValid else { fail("Starter validation failed.") }
        print("Created \(result.directory.path)\nNext: lima-extension check \(args[1]); then add the folder in Lima.")
    case "check":
        guard args.count >= 2 else { fail("Provide an extension folder.", code: 2) }
        let inspection = ExtensionDeveloperKit.inspect(folder(args[1]))
        if args.contains("--json") {
            let data = try JSONEncoder().encode(inspection.diagnostics)
            print(String(decoding: data, as: UTF8.self))
        } else {
            for issue in inspection.diagnostics { print("\(issue.severity.rawValue.uppercased()) \(issue.path): \(issue.message)\n  Fix: \(issue.fix)") }
            if inspection.isValid, let manifest = inspection.manifest { print("Ready: \(manifest.name) · \(manifest.commands.count) commands · schema \(manifest.schemaVersion)") }
        }
        if !inspection.isValid { exit(1) }
    case "run":
        guard args.count >= 3 else { fail("Use run <folder> <command-id> [field=value ...].", code: 2) }
        let root = folder(args[1]); let inspection = checked(root)
        guard let manifest = inspection.manifest, let entry = manifest.commands.first(where: { $0.id == args[2] }) else { fail("No command with that ID.") }
        var values: [String: String] = [:]
        for pair in args.dropFirst(3) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { fail("Pass each field as field=value.", code: 2) }; values[String(parts[0])] = String(parts[1])
        }
        var executable: String, arguments: [String], workingDirectory: String?
        var timeout = 60
        if entry.action.type == .shell { executable = entry.action.value; arguments = entry.action.arguments ?? []; workingDirectory = entry.action.workingDirectory }
        else if let form = entry.action.form, entry.action.type == .form {
            guard Set(values.keys).isSubset(of: Set(form.fields.map(\.id))) else { fail("Unknown form field. Use the IDs declared in the manifest.", code: 2) }
            for field in form.fields where values[field.id] == nil { values[field.id] = field.defaultValue ?? (field.type == .toggle ? "false" : "") }
            for field in form.fields where field.required == true {
                let visible = field.visibleWhen.map { condition in
                    (condition.equals.map { values[condition.field] == $0 } ?? true) && (condition.notEquals.map { values[condition.field] != $0 } ?? true)
                } ?? true
                guard !visible || !(values[field.id] ?? "").isEmpty else { fail("Provide required field \(field.id)=value.", code: 2) }
            }
            timeout = min(300, max(1, form.execution.timeoutSeconds ?? 60))
            executable = form.execution.executable ?? ""; arguments = (form.execution.arguments ?? []).map { ExtensionTemplate.render($0, values: values) }; workingDirectory = form.execution.workingDirectory
        } else { fail("Test native commands in Lima. The CLI runs only explicitly selected script or form commands.") }
        let program = try ExtensionSecurityPolicy.resolvePath(executable, relativeTo: root, capabilities: manifest.capabilities, executable: true)
        let cwd = try workingDirectory.map { try ExtensionSecurityPolicy.resolvePath($0, relativeTo: root, capabilities: manifest.capabilities, executable: false) } ?? root
        exit(try launch(program, arguments: arguments, directory: cwd, timeout: timeout))
    case "pack":
        guard args.count == 3 else { fail("Use pack <folder> <output.zip>.", code: 2) }
        let root = folder(args[1]); let inspection = checked(root); let output = folder(args[2])
        guard let manifest = inspection.manifest, !manifest.id.hasPrefix("."), !manifest.bundled, manifest.provenance != .bundled,
              !FileManager.default.fileExists(atPath: output.path), !output.path.hasPrefix(root.path + "/") else {
            fail("Choose a new ZIP outside a non-bundled extension folder.")
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("lima-pack-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let target = temp.appendingPathComponent(manifest.id)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try ExtensionDeveloperKit.copyPackage(from: root, to: target)
        let archive = temp.appendingPathComponent("package.zip")
        let status = try launch(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-c", "-k", "--keepParent", "--norsrc", "--noextattr", "--noqtn", target.path, archive.path], directory: temp)
        guard status == 0 else { fail("Could not create package.") }
        try FileManager.default.moveItem(at: archive, to: output)
        print("Created \(output.path)\nHidden files, including .git and .env files, are excluded.")
    default: fail("Unknown command \(command). Use lima-extension help.", code: 2)
    }
} catch { fail(error.localizedDescription) }
