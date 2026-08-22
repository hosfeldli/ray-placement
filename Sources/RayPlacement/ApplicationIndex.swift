import AppKit
import Foundation

final class ApplicationIndex {
    func scan(completion: @escaping ([ApplicationRecord]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default
            let roots = [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                URL(fileURLWithPath: "/System/Applications", isDirectory: true),
                fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
            ]
            var records: [ApplicationRecord] = []
            var seen = Set<String>()

            for root in roots where fileManager.fileExists(atPath: root.path) {
                guard let enumerator = fileManager.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }

                for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
                    enumerator.skipDescendants()
                    let canonicalPath = url.resolvingSymlinksInPath().path
                    guard seen.insert(canonicalPath).inserted else { continue }
                    let bundle = Bundle(url: url)
                    let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                        ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                        ?? url.deletingPathExtension().lastPathComponent
                    records.append(ApplicationRecord(url: url, name: name, bundleIdentifier: bundle?.bundleIdentifier))
                }
            }

            records.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async { completion(records) }
        }
    }
}
