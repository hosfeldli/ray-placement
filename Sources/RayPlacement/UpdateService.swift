import AppKit
import CryptoKit
import Foundation
import RayPlacementCore

private let rayPlacementUpdateAssetMaximumBytes = 100 * 1_024 * 1_024

@MainActor
final class UpdateService: ObservableObject {
    struct CompletionResult: Equatable {
        let succeeded: Bool
        let message: String
    }

    struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL
            let digest: String?
            let size: Int

            enum CodingKeys: String, CodingKey {
                case name, digest, size
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: URL
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case name, body, assets
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }

        var versionText: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }
        var updateAsset: Asset? { assets.first { $0.name == "Lima-Update.zip" } }
    }

    struct SiteRelease: Decodable {
        let version: String
        let publishedAt: Date?
        let releaseURL: URL
        let update: URL?
        let updateDigest: String?
        let updateSize: Int?

        enum CodingKeys: String, CodingKey {
            case version, update, updateDigest, updateSize
            case publishedAt = "publishedAt"
            case releaseURL = "releaseUrl"
        }

        func asRelease() -> Release {
            let assets = update.map { [Release.Asset(name: "Lima-Update.zip", browserDownloadURL: $0, digest: updateDigest, size: updateSize ?? 0)] } ?? []
            return Release(tagName: version, name: "Lima \(version)", body: nil, htmlURL: releaseURL, assets: assets)
        }
    }

    enum UpdateError: LocalizedError {
        case invalidResponse
        case noRelease
        case missingAsset
        case invalidDigest
        case oversizedAsset
        case extractionFailed(String)
        case invalidPackage
        case helperFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "The Lima update source returned an unreadable response."
            case .noRelease: return "No published Lima update is available yet."
            case .missingAsset: return "The Lima release does not contain a verified update kit."
            case .invalidDigest: return "The downloaded update did not match its SHA-256 digest and was not opened."
            case .oversizedAsset: return "The update kit is unexpectedly large and was rejected."
            case .extractionFailed(let message): return message.isEmpty ? "The update kit could not be opened." : message
            case .invalidPackage: return "The update kit is incomplete or its version does not match the GitHub Release."
            case .helperFailed(let message): return message
            }
        }
    }

    static let repositoryURL = URL(string: "https://github.com/hosfeldli/ray-placement")!
    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/hosfeldli/ray-placement/releases/latest")!
    private static var siteMetadataURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "LimaUpdateMetadataURL") as? String,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return URL(string: raw)
    }

    @Published private(set) var statusText = "Updates are checked from the Lima site when Lima starts."
    @Published private(set) var isBusy = false
    @Published private(set) var latestVersion: String?
    @Published private(set) var isInstalling = false
    @Published private(set) var installationProgress = 0.0
    @Published private(set) var installationStage = ""
    @Published private(set) var installingVersion: String?
    @Published private(set) var completionResult: CompletionResult?

    var onReleaseAvailable: ((Release) -> Void)?
    var onInstallStarted: (() -> Void)?
    private let resultFile = ApplicationPaths.updates.appendingPathComponent("last-update-result.txt")
    private let progressFile = ApplicationPaths.updates.appendingPathComponent("update-progress.txt")
    private var helperProcess: Process?
    private var progressTimer: Timer?
    private var restartScheduled = false

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    func consumePreviousUpdateResult() -> (succeeded: Bool, message: String)? {
        guard let value = try? String(contentsOf: resultFile, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: resultFile)
        let lines = value.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let status = lines.first else { return nil }
        let message = lines.count > 1 ? String(lines[1]) : ""
        return (status == "success", message)
    }

    func showCompletion(succeeded: Bool, message: String) {
        isBusy = false
        isInstalling = false
        completionResult = CompletionResult(succeeded: succeeded, message: message)
        statusText = message
    }

    func dismissCompletion() {
        completionResult = nil
    }

    func checkForUpdates(manual: Bool) {
        guard !isBusy, !isInstalling else { return }
        isBusy = true
        statusText = "Checking for Lima updates…"

        let usingSiteMetadata = Self.siteMetadataURL != nil
        var request = URLRequest(url: Self.siteMetadataURL ?? Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Lima/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = false
                if let error {
                    self.statusText = manual ? "Update check failed: \(error.localizedDescription)" : "Updates are checked from the Lima site when Lima starts."
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    self.statusText = manual ? UpdateError.invalidResponse.localizedDescription : "Updates are checked from the Lima site when Lima starts."
                    return
                }
                if http.statusCode == 404 {
                    self.statusText = manual ? UpdateError.noRelease.localizedDescription : "No published update is available."
                    return
                }
                guard (200..<300).contains(http.statusCode), let data else {
                    self.statusText = manual ? UpdateError.invalidResponse.localizedDescription : "Updates are checked from the Lima site when Lima starts."
                    return
                }
                let release: Release?
                if usingSiteMetadata {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    release = try? decoder.decode(SiteRelease.self, from: data).asRelease()
                } else {
                    release = try? JSONDecoder().decode(Release.self, from: data)
                }
                guard let release,
                      let remoteVersion = SemanticVersion(release.versionText),
                      let installedVersion = SemanticVersion(self.currentVersion) else {
                    self.statusText = manual ? UpdateError.invalidResponse.localizedDescription : "Updates are checked from the Lima site when Lima starts."
                    return
                }
                self.latestVersion = release.versionText
                guard installedVersion < remoteVersion else {
                    self.statusText = "Lima \(self.currentVersion) is up to date."
                    return
                }
                self.statusText = "Lima \(release.versionText) is available."
                self.onReleaseAvailable?(release)
            }
        }.resume()
    }

    func install(_ release: Release) {
        guard !isBusy, !isInstalling else { return }
        guard let asset = release.updateAsset else {
            statusText = UpdateError.missingAsset.localizedDescription
            return
        }
        guard asset.size > 0, asset.size <= rayPlacementUpdateAssetMaximumBytes else {
            statusText = UpdateError.oversizedAsset.localizedDescription
            return
        }
        guard asset.browserDownloadURL.scheme == "https",
              asset.browserDownloadURL.host?.lowercased() == "github.com" else {
            statusText = UpdateError.invalidResponse.localizedDescription
            return
        }
        guard let digest = asset.digest?.lowercased(), digest.hasPrefix("sha256:"), digest.count == 71 else {
            statusText = UpdateError.invalidDigest.localizedDescription
            return
        }

        isBusy = true
        isInstalling = true
        installingVersion = release.versionText
        installationProgress = 0.08
        installationStage = "Downloading the verified Lima update kit…"
        statusText = installationStage
        completionResult = nil
        restartScheduled = false
        onInstallStarted?()
        var request = URLRequest(url: asset.browserDownloadURL)
        request.setValue("Lima/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.downloadTask(with: request) { [weak self] temporaryURL, response, error in
            guard let self else { return }
            if let error {
                Task { @MainActor in self.finishWithError(error) }
                return
            }
            guard let temporaryURL,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                Task { @MainActor in self.finishWithError(UpdateError.invalidResponse) }
                return
            }
            let expectedHash = String(digest.dropFirst("sha256:".count))
            Task { @MainActor in
                self.installationProgress = 0.2
                self.installationStage = "Download complete. Verifying its SHA-256 digest…"
                self.statusText = self.installationStage
            }
            DispatchQueue.global(qos: .utility).async {
                do {
                    let sourceRoot = try self.prepareUpdate(
                        downloadedArchive: temporaryURL,
                        expectedHash: expectedHash,
                        expectedVersion: release.versionText
                    )
                    Task { @MainActor in
                        self.installationProgress = 0.3
                        self.installationStage = "Update verified. Preparing Lima…"
                        self.statusText = self.installationStage
                        self.launchInstaller(sourceRoot: sourceRoot, version: release.versionText)
                    }
                } catch {
                    Task { @MainActor in self.finishWithError(error) }
                }
            }
        }.resume()
    }

    private nonisolated func prepareUpdate(
        downloadedArchive: URL,
        expectedHash: String,
        expectedVersion: String
    ) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: ApplicationPaths.updates, withIntermediateDirectories: true)
        let working = ApplicationPaths.updates.appendingPathComponent("pending", isDirectory: true)
        if fileManager.fileExists(atPath: working.path) { try fileManager.removeItem(at: working) }
        try fileManager.createDirectory(at: working, withIntermediateDirectories: true)
        let archive = working.appendingPathComponent("Lima-Update.zip")
        try fileManager.copyItem(at: downloadedArchive, to: archive)
        let attributes = try fileManager.attributesOfItem(atPath: archive.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0, size <= rayPlacementUpdateAssetMaximumBytes else { throw UpdateError.oversizedAsset }
        let actualHash = SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
        guard actualHash == expectedHash else { throw UpdateError.invalidDigest }

        let extraction = working.appendingPathComponent("extracted", isDirectory: true)
        try fileManager.createDirectory(at: extraction, withIntermediateDirectories: true)
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, extraction.path]
        process.standardError = errorPipe
        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.extractionFailed(String(decoding: errorData.prefix(8_000), as: UTF8.self))
        }

        let sourceRoot = extraction.appendingPathComponent("LimaUpdate", isDirectory: true)
        let required = [
            "Package.swift", "Uninstall Lima.command", "Packaging/Info.plist",
            "scripts/package_liamflow_app.sh", "scripts/apply_downloaded_update.sh"
        ]
        guard required.allSatisfy({ fileManager.fileExists(atPath: sourceRoot.appendingPathComponent($0).path) }),
              let packagedVersion = try? plistValue("CFBundleShortVersionString", in: sourceRoot.appendingPathComponent("Packaging/Info.plist")),
              SemanticVersion(packagedVersion) == SemanticVersion(expectedVersion) else {
            throw UpdateError.invalidPackage
        }
        return sourceRoot
    }

    private nonisolated func plistValue(_ key: String, in plist: URL) throws -> String {
        let data = try Data(contentsOf: plist)
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dictionary = object as? [String: Any], let value = dictionary[key] as? String else {
            throw UpdateError.invalidPackage
        }
        return value
    }

    private func launchInstaller(sourceRoot: URL, version: String) {
        statusText = "Preparing the verified Lima update…"
        let helper = sourceRoot.appendingPathComponent("scripts/apply_downloaded_update.sh")
        let log = ApplicationPaths.updates.appendingPathComponent("update.log")
        try? FileManager.default.removeItem(at: progressFile)
        FileManager.default.createFile(atPath: log.path, contents: Data())
        do {
            let handle = try FileHandle(forWritingTo: log)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [
                helper.path,
                String(ProcessInfo.processInfo.processIdentifier),
                Bundle.main.bundleURL.path,
                sourceRoot.path,
                version,
                resultFile.path,
                progressFile.path
            ]
            process.standardOutput = handle
            process.standardError = handle
            process.terminationHandler = { [weak self] process in
                Task { @MainActor in self?.helperDidTerminate(process) }
            }
            try process.run()
            helperProcess = process
            startProgressMonitoring()
        } catch {
            finishWithError(UpdateError.helperFailed("The verified update could not start: \(error.localizedDescription)"))
        }
    }

    private func finishWithError(_ error: Error) {
        progressTimer?.invalidate()
        progressTimer = nil
        isBusy = false
        isInstalling = false
        installationProgress = 0
        completionResult = CompletionResult(succeeded: false, message: error.localizedDescription)
        statusText = "Update failed: \(error.localizedDescription)"
    }

    private func startProgressMonitoring() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.readProgress() }
        }
        readProgress()
    }

    private func readProgress() {
        guard let value = try? String(contentsOf: progressFile, encoding: .utf8) else { return }
        let lines = value.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard lines.count == 3, let progress = Double(lines[1]) else { return }
        let state = lines[0]
        installationProgress = min(max(progress, 0), 1)
        installationStage = lines[2]
        statusText = installationStage

        if state == "failure" {
            finishWithError(UpdateError.helperFailed(lines[2]))
        } else if state == "ready", !restartScheduled {
            restartScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                guard let self, self.isInstalling else { return }
                self.installationProgress = 0.95
                self.installationStage = "Closing for the final verified swap. Lima will reopen automatically…"
                self.statusText = self.installationStage
                NSApp.terminate(nil)
            }
        }
    }

    private func helperDidTerminate(_ process: Process) {
        helperProcess = nil
        guard isInstalling, !restartScheduled else { return }
        if let result = consumePreviousUpdateResult(), !result.succeeded {
            finishWithError(UpdateError.helperFailed(result.message))
        } else if process.terminationStatus != 0 {
            finishWithError(UpdateError.helperFailed("The local updater stopped unexpectedly. Open Settings → About for the update log location."))
        }
    }
}
