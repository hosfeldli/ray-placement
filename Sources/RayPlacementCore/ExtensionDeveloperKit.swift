import Foundation

public struct ExtensionDiagnostic: Codable, Equatable, Identifiable, Sendable {
    public enum Severity: String, Codable, Sendable { case error, warning }
    public let severity: Severity
    public let path: String
    public let message: String
    public let fix: String
    public var id: String { "\(severity.rawValue):\(path):\(message)" }
    public init(_ severity: Severity, _ path: String, _ message: String, fix: String) {
        self.severity = severity; self.path = path; self.message = message; self.fix = fix
    }
}

public struct ExtensionInspection: Sendable {
    public let directory: URL
    public let manifest: ExtensionManifest?
    public let manifestHash: String?
    public let diagnostics: [ExtensionDiagnostic]
    public var isValid: Bool { manifest != nil && !diagnostics.contains { $0.severity == .error } }
    public init(directory: URL, manifest: ExtensionManifest?, manifestHash: String?, diagnostics: [ExtensionDiagnostic]) {
        self.directory = directory; self.manifest = manifest; self.manifestHash = manifestHash; self.diagnostics = diagnostics
    }
}

/// Shared by the in-app library, starter builder and developer CLI. Inspection
/// reads package metadata and executable attributes; it never runs package code.
public enum ExtensionDeveloperKit {
    public enum Template: String, CaseIterable, Sendable {
        case link, script, form
        case aiTool = "ai-tool"
        public var title: String {
            switch self { case .link: return "Website shortcut"; case .script: return "Script command"; case .form: return "Form + script"; case .aiTool: return "AI text tool" }
        }
    }
    public static func readManifest(at url: URL) throws -> Data {
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey])
        guard attributes.isSymbolicLink != true, attributes.isRegularFile == true,
              (attributes.fileSize ?? Int.max) <= 2_000_000 else { throw CocoaError(.fileReadTooLarge) }
        return try Data(contentsOf: url)
    }
    public static func inspect(_ directory: URL, manifestFile: URL? = nil) -> ExtensionInspection {
        let manifestURL = manifestFile ?? directory.appendingPathComponent("manifest.json")
        var diagnostics: [ExtensionDiagnostic] = []
        func error(_ path: String, _ message: String, _ fix: String) { diagnostics.append(.init(.error, path, message, fix: fix)) }
        let data: Data
        do {
            data = try readManifest(at: manifestURL)
        } catch {
            return .init(directory: directory, manifest: nil, manifestHash: nil,
                diagnostics: [.init(.error, "manifest.json", "Cannot read the manifest: \(error.localizedDescription)", fix: "Choose an extension folder containing a regular UTF-8 manifest.json under 2 MB.")])
        }
        let manifest: ExtensionManifest
        do { manifest = try JSONDecoder().decode(ExtensionManifest.self, from: data) }
        catch {
            let path: String
            let detail: String
            switch error {
            case DecodingError.keyNotFound(let key, let context): path = (context.codingPath.map(\.stringValue) + [key.stringValue]).joined(separator: "."); detail = "Missing required field."
            case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context), DecodingError.dataCorrupted(let context): path = context.codingPath.map(\.stringValue).joined(separator: "."); detail = context.debugDescription
            default: path = "manifest.json"; detail = error.localizedDescription
            }
            return .init(directory: directory, manifest: nil, manifestHash: ExtensionSecurityPolicy.manifestHash(data),
                diagnostics: [.init(.error, path, detail, fix: "Check the field type and supported values in the v3 manifest reference.")])
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            func unknown(_ object: [String: Any], allowed: Set<String>, path: String) {
                for key in object.keys.sorted() where !allowed.contains(key) {
                    error(path.isEmpty ? key : path + "." + key, "Unknown field \(key).", "Remove it or use the field name from the v3 manifest reference.")
                }
            }
            unknown(object, allowed: ["schemaVersion", "id", "name", "version", "description", "pack", "category", "bundled", "provenance", "commands", "contributions", "capabilities", "trust", "presentation"], path: "")
            for (index, item) in ((object["commands"] as? [[String: Any]]) ?? []).enumerated() {
                unknown(item, allowed: ["id", "title", "subtitle", "keywords", "aliases", "icon", "hotkey", "runInBackground", "presentation", "invocation", "surface", "output", "action"], path: "commands[\(index)]")
                if let action = item["action"] as? [String: Any] {
                    unknown(action, allowed: ["type", "value", "operation", "target", "confirmation", "parameters", "arguments", "workingDirectory", "form", "chain"], path: "commands[\(index)].action")
                }
            }
        }
        if !(1...3).contains(manifest.schemaVersion) { error("schemaVersion", "Unsupported version \(manifest.schemaVersion).", "Use schemaVersion 3 for new extensions; versions 1–3 remain supported.") }
        if manifest.id.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) == nil { error("id", "Invalid extension identifier.", "Use a stable ID such as local.example.my-tools.") }
        if manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { error("name", "An extension needs a display name.", "Set name to a short, recognizable title.") }
        do { try manifest.validateLifecycleMetadata() }
        catch { diagnostics.append(.init(.error, "contributions", "\(error)", fix: "Check contribution IDs, declared capabilities, and supported read-only host adapters.")) }
        var ids = Set<String>()
        for (index, command) in manifest.commands.enumerated() {
            let path = "commands[\(index)]"
            if command.id.isEmpty || !ids.insert(command.id).inserted { error(path + ".id", "Missing or duplicate command ID.", "Give each command a distinct, stable id.") }
            if command.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { error(path + ".title", "Missing command title.", "Set a title describing what the command does.") }
            var required = command.action.inferredCapabilities
            let executable = command.action.type == .shell ? command.action.value : command.action.form?.execution.executable
            if executable?.hasPrefix("/") == true { required.insert(.externalExecution) }
            let missing = required.subtracting(manifest.capabilities)
            if !missing.isEmpty { error(path + ".action", "Missing permissions: " + missing.map(\.rawValue).sorted().joined(separator: ", "), "Add only these required capabilities to the manifest, then review permissions again in Lima.") }
            if let chain = command.action.chain {
                do { try ExtensionAction.validateNativeChain(chain) }
                catch { diagnostics.append(.init(.error, path + ".action.chain", "Unsupported action chain.", fix: "Use up to eight supported native actions without nested chains.")) }
            }
            if command.action.type == .url {
                guard let url = URL(string: command.action.value), let scheme = url.scheme, !["javascript", "data"].contains(scheme.lowercased()), (!["https", "http"].contains(scheme.lowercased()) || url.host != nil) else {
                    error(path + ".action.value", "Invalid website URL.", "Use a complete http:// or https:// URL."); continue
                }
            }
            if command.action.type == .nativeCapability, NativeCapabilityOperation(rawValue: command.action.operation ?? "") == nil {
                error(path + ".action.operation", "Unknown native capability operation.", "Choose an operation supported by the public native capability reference.")
            }
            if let surface = command.surface,
               (surface.kind == .form && command.action.type != .form) || (surface.kind == .generator && command.action.type != .generator) {
                error(path + ".surface", "The surface does not match the action.", "Use a form surface with a form action, or a generator surface with a generator action.")
            }
            if [.form, .generator].contains(command.action.type),
               (command.presentation ?? (command.runInBackground == true ? .background : manifest.presentation)) == .background {
                error(path + ".presentation", "Interactive commands cannot run in the background.", "Use inline or workspace presentation for forms and generators.")
            }
            if command.action.type == .form {
                guard let form = command.action.form else { error(path + ".action.form", "The form definition is missing.", "Add fields and a shell execution definition."); continue }
                var fieldIDs = Set<String>()
                for field in form.fields {
                    if field.id.isEmpty || !fieldIDs.insert(field.id).inserted { error(path + ".action.form.fields", "Missing or duplicate field ID.", "Use unique field IDs and matching {{fieldID}} arguments.") }
                }
                let args = (form.execution.arguments ?? []).joined(separator: " ")
                let expression = try? NSRegularExpression(pattern: #"\{\{([^{}]+)\}\}"#)
                for match in expression?.matches(in: args, range: NSRange(args.startIndex..., in: args)) ?? [] {
                    if let range = Range(match.range(at: 1), in: args), !fieldIDs.contains(String(args[range])) {
                        error(path + ".action.form.execution.arguments", "Unknown field reference \(args[range]).", "Use the exact id of a declared form field.")
                    }
                }
            }
            if let executable, !executable.isEmpty {
                if executable.contains("{{") { error(path + ".action", "Executable paths cannot depend on form input.", "Keep the executable fixed and pass user input as separate arguments."); continue }
                do {
                    let url = try ExtensionSecurityPolicy.resolvePath(executable, relativeTo: directory, capabilities: manifest.capabilities, executable: true)
                    if !FileManager.default.isExecutableFile(atPath: url.path) { error(path + ".action", "Executable is missing or not executable: \(executable)", "Create the file and mark it executable, for example chmod +x bin/run.") }
                } catch { diagnostics.append(.init(.error, path + ".action", error.localizedDescription, fix: "Use an executable inside this extension, or explicitly declare externalExecution for an external program.")) }
            } else if command.action.type == .shell || command.action.type == .form {
                error(path + ".action", "No executable configured.", "Set action.value for scripts or form.execution.executable for forms.")
            }
        }
        if manifest.commands.isEmpty && manifest.contributions.tools.isEmpty && manifest.contributions.skills.isEmpty && manifest.contributions.agents.isEmpty {
            diagnostics.append(.init(.warning, "commands", "This extension does not contribute anything yet.", fix: "Add a command or an AI contribution before installing."))
        }
        return .init(directory: directory, manifest: manifest, manifestHash: ExtensionSecurityPolicy.manifestHash(data), diagnostics: diagnostics)
    }

    public static func migrateProfile(_ profile: CommandProfile, commands: [LoadedExtensionCommand]) -> CommandProfile {
        let canonical = Set(commands.map(\.launcherIdentifier))
        let pairs = commands.compactMap { command -> (String, String)? in
            let legacy = command.extensionID + "." + command.command.id
            guard !legacy.hasPrefix("builtin."), !canonical.contains(legacy) else { return nil }
            return (legacy, command.launcherIdentifier)
        }
        let map = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
        func migrated(_ ids: Set<String>) -> Set<String> { Set(ids.map { map[$0] ?? $0 }) }
        var result = profile
        result.enabledCommandIDs = profile.enabledCommandIDs.map(migrated)
        result.disabledCommandIDs = migrated(profile.disabledCommandIDs)
        result.favoriteCommandIDs = migrated(profile.favoriteCommandIDs)
        result.confirmationRequiredCommandIDs = migrated(profile.confirmationRequiredCommandIDs)
        var seen = Set<String>()
        result.favoriteCommandOrder = profile.favoriteCommandOrder.map { map[$0] ?? $0 }.filter { seen.insert($0).inserted }
        return result
    }

    /// Copy only visible regular package content. Never follow links, copy
    /// hidden credentials/VCS state, or overwrite an existing destination.
    public static func copyPackage(from source: URL, to destination: URL) throws {
        let source = source.resolvingSymlinksInPath().standardizedFileURL
        let files = FileManager.default
        guard !files.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        try files.createDirectory(at: destination, withIntermediateDirectories: false)
        do {
            guard let iterator = files.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { throw CocoaError(.fileReadUnknown) }
            var count = 0, bytes = 0
            for case let file as URL in iterator {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else { throw CocoaError(.fileReadUnsupportedScheme) }
                count += 1; bytes += values.fileSize ?? 0
                guard count <= 2000, bytes <= 50_000_000 else { throw CocoaError(.fileReadTooLarge) }
                let canonical = file.resolvingSymlinksInPath().standardizedFileURL
                guard canonical.path.hasPrefix(source.path + "/") else { throw CocoaError(.fileReadNoPermission) }
                let relative = String(canonical.path.dropFirst(source.path.count + 1))
                let target = destination.appendingPathComponent(relative)
                if values.isDirectory == true { try files.createDirectory(at: target, withIntermediateDirectories: true) }
                else { try files.copyItem(at: file, to: target) }
            }
            guard inspect(destination).isValid else {
                throw NSError(domain: "LimaExtensionKit", code: 2, userInfo: [NSLocalizedDescriptionKey: "The copied package is incomplete. Keep required scripts and assets in visible package folders, not hidden folders."])
            }
        } catch { try? files.removeItem(at: destination); throw error }
    }

    @discardableResult public static func create(at directory: URL, id: String, name: String, template: Template) throws -> ExtensionInspection {
        guard id.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !FileManager.default.fileExists(atPath: directory.path) else {
            throw NSError(domain: "LimaExtensionKit", code: 1, userInfo: [NSLocalizedDescriptionKey: "Use a valid ID and name, and choose a new folder. Existing folders are never overwritten."])
        }
        var action = ExtensionAction(type: .url, value: "https://example.com")
        var capabilities: Set<ExtensionManifest.Capability> = [.network]
        if [.script, .form].contains(template) {
            capabilities = [.shell, .filesystem]
            action = .init(type: .shell, value: "bin/run")
            if template == .form {
                action = .init(type: .form, form: .init(title: name, submitLabel: "Run", fields: [
                    .init(id: "message", label: "Message", type: .text, required: true)
                ], execution: .init(type: .shell, executable: "bin/run", arguments: ["{{message}}"], timeoutSeconds: 30)))
            }
        }
        var commands: [ExtensionCommand] = [.init(id: "run", title: name, subtitle: "Run \(name)", keywords: ["local"], action: action)]
        var contributions = ExtensionContributions()
        if template == .aiTool {
            capabilities = []; commands = []
            contributions = .init(tools: [.init(id: "transform", title: name, description: "Transform text using Lima's read-only host adapter.",
                inputSchema: ["type": .string("object"), "properties": .object([
                    "text": .object(["type": .string("string")]),
                    "operation": .object(["type": .string("string"), "enum": .array([.string("trim"), .string("uppercase"), .string("lowercase"), .string("collapse_whitespace")])])
                ]), "required": .array([.string("text"), .string("operation")]), "additionalProperties": .bool(false)],
                execution: .hostReadOnly, hostAdapterID: "transform_text")])
        }
        let manifest = ExtensionManifest(schemaVersion: 3, id: id, name: name, version: "1.0.0", description: "A local Lima extension.",
            commands: commands, contributions: contributions, capabilities: capabilities)
        let staging = directory.deletingLastPathComponent().appendingPathComponent(".lima-new-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
            if [.script, .form].contains(template) {
                let bin = staging.appendingPathComponent("bin")
                try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: false)
                let executable = bin.appendingPathComponent("run")
                try "#!/bin/zsh\nset -euo pipefail\nprintf '%s\\n' \"${1:-Hello from Lima}\"\n".write(to: executable, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            }
            try "# \(name)\n\n1. Edit manifest.json and bin/run if present.\n2. Run `lima-extension check .`.\n3. In Lima → Extensions → Add Folder, select this folder and review its permissions.\n4. Use Reload while developing; a changed manifest requires a new review.\n5. Run `lima-extension pack . output.zip` to share a verified package.\n\nSchema v3 · stable extension ID: \(id) · keep command and tool IDs stable.\nScripts execute with your normal macOS account; capabilities describe host access, not an OS sandbox.\n".write(to: staging.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            try FileManager.default.moveItem(at: staging, to: directory)
            return inspect(directory)
        } catch { try? FileManager.default.removeItem(at: staging); throw error }
    }
}
