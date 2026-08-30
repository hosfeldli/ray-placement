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
        let marker = ApplicationPaths.extensions.appendingPathComponent(".liamflow-bundled-extensions")
        guard !fileManager.fileExists(atPath: marker.path),
              let bundledRoot = Bundle.main.resourceURL?.appendingPathComponent("BundledExtensions", isDirectory: true),
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
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            try? fileManager.copyItem(at: source, to: destination)
        }
        try? "Bundled extensions were installed with LiamFlow.\n".write(to: marker, atomically: true, encoding: .utf8)
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
                guard !manifest.id.isEmpty, !manifest.name.isEmpty else {
                    issues.append(ExtensionIssue(file: file.lastPathComponent, message: "The extension id and name are required."))
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
                    loaded.append(LoadedExtensionCommand(
                        extensionID: manifest.id,
                        extensionName: manifest.name,
                        directory: directory,
                        command: command
                    ))
                }
            } catch {
                issues.append(ExtensionIssue(file: file.lastPathComponent, message: error.localizedDescription))
            }
        }

        return (loaded, issues)
    }

    static let extensionReadme = """
    RAYPLACEMENT EXTENSIONS

    Add a folder here with a manifest.json file. Commands can open a URL, file, or app;
    copy or paste text; open native tools such as the formatter; or run a local
    executable script. Reload Extensions from the launcher after editing. Scripts
    run locally with your user account's permissions.

    See the project's Examples folder for a complete manifest and script.
    """
}
