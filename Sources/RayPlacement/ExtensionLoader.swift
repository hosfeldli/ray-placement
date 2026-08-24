import Foundation
import RayPlacementCore

final class ExtensionLoader {
    func prepareFolder() {
        do {
            try ApplicationPaths.prepare()
            let readme = ApplicationPaths.extensions.appendingPathComponent("README.txt")
            if !FileManager.default.fileExists(atPath: readme.path) {
                try Self.extensionReadme.write(to: readme, atomically: true, encoding: .utf8)
            }
        } catch {
            // The Settings screen reports load failures; launch should remain usable.
        }
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
                guard manifest.schemaVersion == 1 else {
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
