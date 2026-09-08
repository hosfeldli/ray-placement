import Foundation
import RayPlacementCore

final class ExtensionLoader {
    func prepareFolder() {
        do {
            try ApplicationPaths.prepare()
            installBundledExtensionsIfNeeded()
            let readme = ApplicationPaths.extensions.appendingPathComponent("README.txt")
            if !FileManager.default.fileExists(atPath: readme.path) {
                try Self.extensionReadme.write(to: readme, atomically: true, encoding: .utf8)
            }
        } catch {
            // The Settings screen reports load failures; launch should remain usable.
        }
    }

    private func installBundledExtensionsIfNeeded() {
        let fileManager = FileManager.default
        guard let bundledRoot = bundledExtensionsRoot(fileManager: fileManager),
              let bundledItems = try? fileManager.contentsOfDirectory(
                at: bundledRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else { return }

        for source in bundledItems {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  fileManager.fileExists(atPath: source.appendingPathComponent("manifest.json").path) else { continue }
            let destination = ApplicationPaths.extensions.appendingPathComponent(source.lastPathComponent, isDirectory: true)
            do {
                if !fileManager.fileExists(atPath: destination.path) {
                    try fileManager.copyItem(at: source, to: destination)
                } else if try bundledPackNeedsUpdate(source: source, destination: destination) {
                    try replaceBundledPack(source: source, destination: destination)
                }
            } catch {
                // A damaged or locked pack must not prevent the remaining packs
                // from loading. The issue appears when manifests are decoded.
            }
        }
        // Older releases left a one-time installation marker. It is no longer
        // used because each bundled pack is version-checked on every launch.
        try? fileManager.removeItem(at: ApplicationPaths.extensions.appendingPathComponent(".lima-bundled-extensions"))
    }

    private func bundledPackNeedsUpdate(source: URL, destination: URL) throws -> Bool {
        let decoder = JSONDecoder()
        let sourceManifest = try decoder.decode(ExtensionManifest.self, from: Data(contentsOf: source.appendingPathComponent("manifest.json")))
        let destinationManifest = try decoder.decode(ExtensionManifest.self, from: Data(contentsOf: destination.appendingPathComponent("manifest.json")))
        let destinationIsBundled = destinationManifest.bundled
            || destinationManifest.provenance == .bundled
            || destinationManifest.trust == .bundled
            || destinationManifest.trust == .builtIn
        return ExtensionBundleUpdatePolicy.shouldUpdate(
            shippedVersion: sourceManifest.version,
            installedVersion: destinationManifest.version,
            destinationIsBundled: destinationIsBundled
        )
    }

    private func replaceBundledPack(source: URL, destination: URL) throws {
        let fileManager = FileManager.default
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).update-\(UUID().uuidString)", isDirectory: true)
        try fileManager.copyItem(at: source, to: temporary)
        do {
            try fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    struct RepairReport {
        let repairedCount: Int
        let backupURL: URL?
        let errors: [String]

        var summary: String {
            if repairedCount == 0 && errors.isEmpty { return "Bundled extensions are already current" }
            let backup = backupURL.map { " Backup: \($0.lastPathComponent)." } ?? ""
            if errors.isEmpty { return "Repaired \(repairedCount) bundled extension\(repairedCount == 1 ? "" : "s").\(backup)" }
            return "Repaired \(repairedCount) extension\(repairedCount == 1 ? "" : "s") with \(errors.count) issue\(errors.count == 1 ? "" : "s")."
        }
    }

    /// Reinstalls the copies shipped inside Lima without touching unrelated
    /// user extensions. Existing bundled copies are moved to a timestamped
    /// backup first, so repairing an extension is reversible instead of a
    /// destructive overwrite.
    func repairBundledExtensions() -> RepairReport {
        let fileManager = FileManager.default
        do { try ApplicationPaths.prepare() } catch {
            return RepairReport(repairedCount: 0, backupURL: nil, errors: [error.localizedDescription])
        }
        guard let bundledRoot = bundledExtensionsRoot(fileManager: fileManager),
              let bundledItems = try? fileManager.contentsOfDirectory(
                at: bundledRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else {
            return RepairReport(repairedCount: 0, backupURL: nil, errors: ["Lima's bundled extensions are unavailable."])
        }

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backupRoot = ApplicationPaths.extensions.appendingPathComponent(".repair-backups/\(stamp)", isDirectory: true)
        var backupURL: URL?
        var repairedCount = 0
        var errors: [String] = []

        for source in bundledItems {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  fileManager.fileExists(atPath: source.appendingPathComponent("manifest.json").path) else { continue }
            let destination = ApplicationPaths.extensions.appendingPathComponent(source.lastPathComponent, isDirectory: true)
            do {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)
                    let backup = backupRoot.appendingPathComponent(source.lastPathComponent, isDirectory: true)
                    try fileManager.copyItem(at: destination, to: backup)
                    backupURL = backupRoot
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: source, to: destination)
                repairedCount += 1
            } catch {
                errors.append("\(source.lastPathComponent): \(error.localizedDescription)")
            }
        }

        try? fileManager.removeItem(at: ApplicationPaths.extensions.appendingPathComponent(".lima-bundled-extensions"))
        installBundledExtensionsIfNeeded()
        return RepairReport(repairedCount: repairedCount, backupURL: backupURL, errors: errors)
    }

    private func bundledExtensionsRoot(fileManager: FileManager) -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("BundledExtensions", isDirectory: true),
            URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent("Extensions", isDirectory: true),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Extensions", isDirectory: true)
        ].compactMap { $0 }
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    func load() -> (commands: [LoadedExtensionCommand], issues: [ExtensionIssue]) {
        prepareFolder()
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: ApplicationPaths.extensions,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return ([], []) }

        var manifestFiles: [(URL, URL)] = []
        for url in contents {
            var isDirectory: ObjCBool = false
            fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                let manifest = url.appendingPathComponent("manifest.json")
                if fileManager.fileExists(atPath: manifest.path) { manifestFiles.append((manifest, url)) }
            } else if url.pathExtension.lowercased() == "json" {
                manifestFiles.append((url, url.deletingLastPathComponent()))
            }
        }

        manifestFiles.sort { $0.0.path.localizedStandardCompare($1.0.path) == .orderedAscending }

        var loaded: [LoadedExtensionCommand] = []
        var issues: [ExtensionIssue] = []
        var seenExtensionIDs = Set<String>()
        var seenCommandIDs = Set<String>()
        let decoder = JSONDecoder()

        for (file, directory) in manifestFiles {
            do {
                let manifest = try decoder.decode(ExtensionManifest.self, from: Data(contentsOf: file))
                guard (1...2).contains(manifest.schemaVersion) else {
                    issues.append(ExtensionIssue(file: file.lastPathComponent, message: "Unsupported schema version \(manifest.schemaVersion)."))
                    continue
                }
                guard !manifest.id.isEmpty, !manifest.name.isEmpty, manifest.id.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
                    issues.append(ExtensionIssue(file: file.lastPathComponent, message: "The extension id and name are required."))
                    continue
                }
                let manifestData = try Data(contentsOf: file)
                let manifestHash = ExtensionSecurityPolicy.manifestHash(manifestData)
                let isBundled = manifest.bundled || manifest.provenance == .bundled || manifest.trust == .bundled || manifest.trust == .builtIn
                if isBundled {
                    // Bundled packs are shipped and verified with Lima; they do not
                    // require the interactive approval flow used by user extensions.
                } else if let approval = ExtensionApprovalStore.record(for: manifest.id) {
                    guard approval.manifestHash == manifestHash,
                          approval.capabilities.isSuperset(of: manifest.capabilities) else {
                        issues.append(ExtensionIssue(
                            file: file.lastPathComponent,
                            message: "This extension changed its manifest or requested additional capabilities. Re-approval is required.",
                            extensionID: manifest.id,
                            manifestHash: manifestHash,
                            capabilities: manifest.capabilities
                        ))
                        continue
                    }
                } else {
                    issues.append(ExtensionIssue(
                        file: file.lastPathComponent,
                        message: "This extension has not been approved. Review its requested capabilities before loading it.",
                        extensionID: manifest.id,
                        manifestHash: manifestHash,
                        capabilities: manifest.capabilities
                    ))
                    continue
                }
                guard seenExtensionIDs.insert(manifest.id).inserted else {
                    issues.append(ExtensionIssue(file: file.lastPathComponent, message: "Duplicate extension id: \(manifest.id)"))
                    continue
                }
                for command in manifest.commands {
                    guard !command.id.isEmpty, !command.title.isEmpty else {
                        issues.append(ExtensionIssue(file: file.lastPathComponent, message: "Every command needs a nonempty id and title."))
                        continue
                    }
                    let compositeID = "\(manifest.id).\(command.id)"
                    guard seenCommandIDs.insert(compositeID).inserted else {
                        issues.append(ExtensionIssue(file: file.lastPathComponent, message: "Duplicate command id: \(command.id)"))
                        continue
                    }
                    var required = requiredCapabilities(for: command.action)
                    if command.action.type == .shell, command.action.value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") {
                        required.insert(.externalExecution)
                    }
                    if command.action.type == .form, command.action.form?.execution.type == .shell, command.action.form?.execution.executable?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") == true {
                        required.insert(.externalExecution)
                    }
                    guard required.isSubset(of: manifest.capabilities) else {
                        let missing = required.subtracting(manifest.capabilities).map(\.rawValue).sorted().joined(separator: ", ")
                        issues.append(ExtensionIssue(file: file.lastPathComponent, message: "Command \(command.id) requires undeclared capabilities: \(missing)."))
                        continue
                    }
                    if command.action.type == .form {
                        guard let form = command.action.form, !form.fields.isEmpty else {
                            issues.append(ExtensionIssue(file: file.lastPathComponent, message: "Form command \(command.id) needs a form definition and at least one field."))
                            continue
                        }
                        let fieldIDs = form.fields.map(\.id)
                        guard Set(fieldIDs).count == fieldIDs.count,
                              fieldIDs.allSatisfy({ !$0.isEmpty }) else {
                            issues.append(ExtensionIssue(file: file.lastPathComponent, message: "Form command \(command.id) has an empty or duplicate field id."))
                            continue
                        }
                    }
                    do {
                        if command.action.type == .shell {
                            _ = try ExtensionSecurityPolicy.resolvePath(command.action.value, relativeTo: directory, capabilities: manifest.capabilities, executable: true)
                        }
                        if command.action.type == .file || command.action.type == .application {
                            _ = try ExtensionSecurityPolicy.resolvePath(command.action.value, relativeTo: directory, capabilities: manifest.capabilities, executable: false)
                        }
                    } catch {
                        issues.append(ExtensionIssue(file: file.lastPathComponent, message: "Command \(command.id) has an unsafe path: \(error.localizedDescription)."))
                        continue
                    }
                    loaded.append(LoadedExtensionCommand(
                        extensionID: manifest.id,
                        extensionName: manifest.name,
                        directory: directory,
                        command: command,
                        capabilities: manifest.capabilities,
                        trust: manifest.trust,
                        pack: manifest.pack,
                        category: manifest.category,
                        bundled: manifest.bundled,
                        version: manifest.version
                    ))
                }
            } catch {
                issues.append(ExtensionIssue(file: file.lastPathComponent, message: error.localizedDescription))
            }
        }

        return (loaded, issues)
    }

    private func requiredCapabilities(for action: ExtensionAction) -> Set<ExtensionManifest.Capability> {
        switch action.type {
        case .url: return [.network]
        case .file: return [.filesystem]
        case .application:
            guard let operation = action.operation else { return [.filesystem] }
            switch operation {
            case "quit", "forceQuit", "restart", "activate", "hide", "unhide": return [.processControl]
            default: return [.processControl]
            }
        case .shell: return [.shell, .filesystem]
        case .clipboard:
            return (action.operation ?? "copy") == "copy" ? [.clipboard] : [.clipboard, .accessibility]
        case .picker:
            switch action.operation {
            case "emoji": return [.clipboard, .accessibility]
            case "application": return [.processControl]
            case "file": return [.filesystem]
            default: return []
            }
        case .system: return [.systemControl]
        case .window: return [.accessibility]
        case .workspace:
            switch action.operation {
            case "writingReview": return [.selectedText, .clipboard, .accessibility]
            case "focusedFileLauncher": return [.filesystem]
            default: return []
            }
        case .form:
            guard action.form != nil else { return [] }
            return [.shell, .filesystem]
        }
    }

    static let extensionReadme = """
    RAYPLACEMENT EXTENSIONS

    Add a folder here with a manifest.json file. Commands can use Lima's approved
    local capabilities such as application, window, system, clipboard, picker,
    workspace, file, URL, form, and shell actions. Reload Extensions after editing.
    Scripts run locally with your user account's permissions.

    See the project's Examples folder for a complete manifest and script.
    """
}
