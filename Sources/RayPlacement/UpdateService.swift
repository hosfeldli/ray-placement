import AppKit
import CryptoKit
import Foundation
import RayPlacementCore

private let rayPlacementUpdateAssetMaximumBytes = 100 * 1_024 * 1_024
private let rayPlacementUpdateMetadataTimeout: TimeInterval = 20
private let rayPlacementUpdateDownloadTimeout: TimeInterval = 15 * 60
private let rayPlacementUpdateTrustPolicyVersion = 1

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
        case metadataUnavailable(stage: String, detail: String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "The Lima update source returned an unreadable response."
            case .noRelease: return "No published Lima update is available yet."
            case .missingAsset: return "The Lima release does not contain a verified update kit."
            case .invalidDigest: return "The downloaded update did not match its SHA-256 digest and was not opened."
            case .oversizedAsset: return "This release contains an unexpectedly large update kit, so Lima refused to install it. Retry after the release is repaired or use the full DMG."
            case .extractionFailed(let message): return message.isEmpty ? "The update kit could not be opened." : message
            case .invalidPackage: return "The update kit is incomplete or its version does not match the GitHub Release."
            case .helperFailed(let message): return message
            case .metadataUnavailable(let stage, let detail):
                return "Update check failed during \(stage): \(detail)"
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
    @Published private(set) var downloadedBytes: Int64 = 0
    @Published private(set) var totalDownloadBytes: Int64 = 0
    @Published private(set) var installationStartedAt: Date?

    var onReleaseAvailable: ((Release) -> Void)?
    var onInstallStarted: (() -> Void)?
    private let resultFile = ApplicationPaths.updates.appendingPathComponent("last-update-result.txt")
    private let progressFile = ApplicationPaths.updates.appendingPathComponent("update-progress.txt")
    private var helperProcess: Process?
    private var progressTimer: Timer?
    private var downloadProgressTimer: Timer?
    private var downloadTask: URLSessionDownloadTask?
    private var restartScheduled = false
    private var lastRelease: Release?

    var canCancelInstallation: Bool {
        isInstalling && downloadTask != nil && helperProcess == nil && !restartScheduled
    }

    var canRetryInstallation: Bool { !isInstalling && lastRelease != nil }

    var formattedDownloadProgress: String? {
        guard totalDownloadBytes > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: downloadedBytes)) of \(formatter.string(fromByteCount: totalDownloadBytes))"
    }

    /// The updater must use one canonical identity for the running bundle.
    /// LaunchServices may start Lima through a symlink, alias, or a stale Dock
    /// reference; passing those spellings between Swift and the shell updater
    /// made a valid installation look like an invalid path.
    private nonisolated var canonicalBundleURL: URL {
        Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    func consumePreviousUpdateResult() -> (succeeded: Bool, message: String)? {
        guard let value = try? String(contentsOf: resultFile, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: resultFile)
        let lines = value.split(separator: "\n", omittingEmptySubsequences: false)
        guard let status = lines.first else { return nil }
        let message = lines.count > 1 ? String(lines[1]) : ""
        if status == "success", lines.count >= 5 {
            let expectedPath = URL(fileURLWithPath: String(lines[4])).standardizedFileURL.resolvingSymlinksInPath().path
            let runningPath = canonicalBundleURL.path
            let runningBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            guard String(lines[2]) == currentVersion, String(lines[3]) == runningBuild, expectedPath == runningPath else {
                return (false, "The update was installed at \(expectedPath), but this is Lima \(currentVersion) at \(runningPath). Quit this copy and open the updated app from Finder; replace any Dock shortcut pointing at the old copy.")
            }
        }
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
        fetchReleaseMetadata(manual: manual, candidates: Self.metadataCandidates())
    }

    private static func metadataCandidates() -> [(url: URL, isSite: Bool)] {
        var candidates: [(url: URL, isSite: Bool)] = []
        if let siteMetadataURL {
            candidates.append((siteMetadataURL, true))
        }
        candidates.append((latestReleaseURL, false))
        return candidates
    }

    private func fetchReleaseMetadata(
        manual: Bool,
        candidates: [(url: URL, isSite: Bool)],
        index: Int = 0,
        failures: [String] = []
    ) {
        guard index < candidates.count else {
            isBusy = false
            let detail = failures.isEmpty
                ? "Neither the configured update feed nor GitHub returned a usable release."
                : failures.joined(separator: "; ")
            let error = UpdateError.metadataUnavailable(
                stage: "metadata",
                detail: detail
            )
            statusText = manual ? error.localizedDescription : "Updates are checked from the Lima site and GitHub when Lima starts."
            return
        }

        let candidate = candidates[index]
        var request = URLRequest(url: candidate.url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = rayPlacementUpdateMetadataTimeout
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Lima/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                guard let self else { return }
                let sourceName = candidate.isSite ? "site metadata" : "GitHub metadata"
                if let error {
                    self.fetchReleaseMetadata(
                        manual: manual,
                        candidates: candidates,
                        index: index + 1,
                        failures: failures + ["\(sourceName): \(error.localizedDescription)"]
                    )
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    self.fetchReleaseMetadata(
                        manual: manual,
                        candidates: candidates,
                        index: index + 1,
                        failures: failures + ["\(sourceName): invalid HTTP response"]
                    )
                    return
                }
                guard (200..<300).contains(http.statusCode), let data else {
                    self.fetchReleaseMetadata(
                        manual: manual,
                        candidates: candidates,
                        index: index + 1,
                        failures: failures + ["\(sourceName): HTTP \(http.statusCode)"]
                    )
                    return
                }

                let release: Release?
                if candidate.isSite {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    release = try? decoder.decode(SiteRelease.self, from: data).asRelease()
                } else {
                    release = try? JSONDecoder().decode(Release.self, from: data)
                }
                guard let release else {
                    self.fetchReleaseMetadata(
                        manual: manual,
                        candidates: candidates,
                        index: index + 1,
                        failures: failures + ["\(sourceName): invalid release metadata"]
                    )
                    return
                }
                self.finishUpdateCheck(release, manual: manual)
            }
        }.resume()
    }

    private func finishUpdateCheck(_ release: Release, manual: Bool) {
        isBusy = false
        guard let remoteVersion = SemanticVersion(release.versionText),
              let installedVersion = SemanticVersion(currentVersion) else {
            let error = UpdateError.metadataUnavailable(stage: "version validation", detail: "The release version is not semantic.")
            statusText = manual ? error.localizedDescription : "Updates are checked from the Lima site and GitHub when Lima starts."
            return
        }
        latestVersion = release.versionText
        guard installedVersion < remoteVersion else {
            statusText = "Lima \(currentVersion) is up to date."
            return
        }
        statusText = "Lima \(release.versionText) is available."
        onReleaseAvailable?(release)
    }

    func install(_ release: Release) {
        guard !isBusy, !isInstalling else { return }
        lastRelease = release
        guard let asset = release.updateAsset else {
            rejectInstall(UpdateError.missingAsset, release: release)
            return
        }
        guard asset.size > 0, asset.size <= rayPlacementUpdateAssetMaximumBytes else {
            rejectInstall(UpdateError.oversizedAsset, release: release)
            return
        }
        guard asset.browserDownloadURL.scheme?.lowercased() == "https",
              let host = asset.browserDownloadURL.host,
              !host.isEmpty,
              asset.browserDownloadURL.user == nil,
              asset.browserDownloadURL.password == nil else {
            rejectInstall(UpdateError.invalidResponse, release: release)
            return
        }
        guard let digest = asset.digest?.lowercased(), digest.hasPrefix("sha256:"), digest.count == 71 else {
            rejectInstall(UpdateError.invalidDigest, release: release)
            return
        }

        isBusy = true
        isInstalling = true
        installingVersion = release.versionText
        installationStartedAt = Date()
        downloadedBytes = 0
        totalDownloadBytes = Int64(asset.size)
        installationProgress = 0.04
        installationStage = "Downloading the signed Lima update…"
        statusText = installationStage
        completionResult = nil
        restartScheduled = false
        onInstallStarted?()
        var request = URLRequest(url: asset.browserDownloadURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = rayPlacementUpdateDownloadTimeout
        request.setValue("Lima/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let installedVersion = currentVersion
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = rayPlacementUpdateDownloadTimeout
        configuration.timeoutIntervalForResource = rayPlacementUpdateDownloadTimeout
        let task = URLSession(configuration: configuration).downloadTask(with: request) { [weak self] temporaryURL, response, error in
            guard let self else { return }
            Task { @MainActor in self.stopDownloadProgressMonitoring() }
            if let error {
                Task { @MainActor in
                    guard self.isInstalling else { return }
                    self.finishWithError(error)
                }
                return
            }
            guard let temporaryURL,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                Task { @MainActor in self.finishWithError(UpdateError.invalidResponse) }
                return
            }
            // URLSession deletes temporaryURL when this callback returns.
            // Preserve it before handing verification to another queue.
            let retainedDownload = FileManager.default.temporaryDirectory.appendingPathComponent("Lima-download-\(UUID().uuidString).zip")
            do {
                try FileManager.default.copyItem(at: temporaryURL, to: retainedDownload)
            } catch {
                Task { @MainActor in self.finishWithError(error) }
                return
            }
            let expectedHash = String(digest.dropFirst("sha256:".count))
            Task { @MainActor in
                self.installationProgress = 0.2
                self.installationStage = "Download complete. Verifying its SHA-256 digest…"
                self.statusText = self.installationStage
            }
            DispatchQueue.global(qos: .utility).async {
                defer { try? FileManager.default.removeItem(at: retainedDownload) }
                do {
                    let sourceRoot = try self.prepareUpdate(
                        downloadedArchive: retainedDownload,
                        expectedHash: expectedHash,
                        expectedVersion: release.versionText,
                        installedVersion: installedVersion
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
        }
        downloadTask = task
        startDownloadProgressMonitoring(task: task, expectedBytes: Int64(asset.size))
        task.resume()
    }

    func cancelInstallation() {
        guard canCancelInstallation else { return }
        downloadTask?.cancel()
        stopDownloadProgressMonitoring()
        finishWithError(UpdateError.helperFailed("Update canceled. Lima was not changed."))
    }

    func retryInstallation() {
        guard let release = lastRelease, !isInstalling else { return }
        completionResult = nil
        install(release)
    }

    func revealUpdateLog() {
        let log = ApplicationPaths.updates.appendingPathComponent("update.log")
        try? ApplicationPaths.prepare()
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: Data())
        }
        NSWorkspace.shared.activateFileViewerSelecting([log])
    }

    func openManualDownload() {
        if let release = lastRelease { NSWorkspace.shared.open(release.htmlURL) }
        else { NSWorkspace.shared.open(Self.repositoryURL.appendingPathComponent("releases/latest")) }
    }

    private func rejectInstall(_ error: Error, release: Release) {
        installingVersion = release.versionText
        installationStartedAt = Date()
        completionResult = CompletionResult(succeeded: false, message: error.localizedDescription)
        statusText = "Update not installed: \(error.localizedDescription)"
        onInstallStarted?()
    }

    private nonisolated func prepareUpdate(
        downloadedArchive: URL,
        expectedHash: String,
        expectedVersion: String,
        installedVersion: String
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
        let actualHash = try sha256(of: archive)
        guard actualHash == expectedHash else { throw UpdateError.invalidDigest }
        // Apply the pure policy before any archive extraction. The process-level
        // checks below remain necessary because zipinfo is the source of type
        // information for macOS archives.
        try validateArchive(archive)

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
        try validateExtractedTree(extraction)

        let sourceRoot = extraction.appendingPathComponent("LimaUpdate", isDirectory: true)
        let required = ["Prebuilt/Lima.app/Contents/MacOS/Lima", "Prebuilt/Lima.app/Contents/Info.plist"]
        let extractedFiles = Set(required.filter { fileManager.fileExists(atPath: sourceRoot.appendingPathComponent($0).path) })
        do { try UpdateVerificationPolicy.validateRequiredFiles(extractedFiles, required: required) }
        catch { throw UpdateError.invalidPackage }
        let prebuiltInfo = sourceRoot.appendingPathComponent("Prebuilt/Lima.app/Contents/Info.plist")
        guard try plistValue("CFBundleIdentifier", in: prebuiltInfo) == "dev.liam.lima",
              try plistValue("CFBundleShortVersionString", in: prebuiltInfo) == expectedVersion else {
            throw UpdateError.invalidPackage
        }
        do { try UpdateVerificationPolicy.validateNewerVersion(expectedVersion, than: installedVersion) }
        catch { throw UpdateError.invalidPackage }
        let expectedBuild = try plistValue("CFBundleVersion", in: prebuiltInfo)
        try runTrustedVerification(sourceRoot.appendingPathComponent("Prebuilt/Lima.app"), expectedVersion: expectedVersion, expectedBuild: expectedBuild)
        return sourceRoot
    }

    private nonisolated func validateArchive(_ archive: URL) throws {
        let list = try runProcess("/usr/bin/zipinfo", arguments: ["-1", archive.path])
        let entries = list.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        do { try UpdateVerificationPolicy.validateArchiveEntries(entries) }
        catch { throw UpdateError.invalidPackage }

        let longListing = try runProcess("/usr/bin/zipinfo", arguments: ["-l", archive.path])
        var types: [(path: String, type: UpdateArchiveEntryType)] = []
        for line in longListing.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let permissions = fields.first, permissions.count >= 1,
                  let path = fields.last.map(String.init), path != "name" else { continue }
            let type: UpdateArchiveEntryType
            switch permissions.first {
            case "d": type = .directory
            case "-": type = .regularFile
            case "l": type = .symbolicLink
            case "h": type = .hardLink
            case "p": type = .fifo
            default: type = .socket
            }
            types.append((path, type))
        }
        do { try UpdateVerificationPolicy.validateArchiveTypes(types) }
        catch { throw UpdateError.invalidPackage }

        let details = try runProcess("/usr/bin/zipinfo", arguments: ["-Z", "-v", archive.path]).lowercased()
        guard !details.contains("symbolic link"), !details.contains("hard link"), !details.contains("fifo"), !details.contains("character device"), !details.contains("block device") else { throw UpdateError.invalidPackage }
    }

    private nonisolated func validateExtractedTree(_ root: URL) throws {
        let fm = FileManager.default
        var count = 0
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey], options: []) else { throw UpdateError.invalidPackage }
        for case let url as URL in enumerator {
            count += 1
            guard count <= 100_000 else { throw UpdateError.invalidPackage }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else { throw UpdateError.invalidPackage }
        }
    }

    private nonisolated func runTrustedVerification(_ app: URL, expectedVersion: String, expectedBuild: String) throws {
        let verifier = canonicalBundleURL.appendingPathComponent("Contents/Resources/Updater/verify_update_app.sh")
        guard FileManager.default.isExecutableFile(atPath: verifier.path) else { throw UpdateError.invalidPackage }
        let policy = Bundle.main.infoDictionary ?? [:]
        guard (policy["LimaUpdatePolicyVersion"] as? Int ?? 0) == rayPlacementUpdateTrustPolicyVersion,
              let identity = policy["LimaUpdateExpectedSigningIdentity"] as? String,
              let certificate = policy["LimaUpdateExpectedCertificateSHA256"] as? String,
              !identity.isEmpty, !certificate.isEmpty else { throw UpdateError.invalidPackage }
        _ = try runProcess("/bin/zsh", arguments: [verifier.path, app.path, expectedVersion, expectedBuild, identity, certificate, canonicalBundleURL.path])
    }

    private nonisolated func runProcess(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data.prefix(32_000), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw UpdateError.extractionFailed(text) }
        return text
    }

    private nonisolated func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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
        let helper = canonicalBundleURL.appendingPathComponent("Contents/Resources/Updater/apply_trusted_update.sh")
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
                canonicalBundleURL.path,
                sourceRoot.standardizedFileURL.path,
                version,
                resultFile.path,
                progressFile.path,
                canonicalBundleURL.path
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
        stopDownloadProgressMonitoring()
        progressTimer?.invalidate()
        progressTimer = nil
        isBusy = false
        isInstalling = false
        installationProgress = 0
        completionResult = CompletionResult(succeeded: false, message: error.localizedDescription)
        statusText = "Update failed: \(error.localizedDescription)"
    }

    private func startDownloadProgressMonitoring(task: URLSessionDownloadTask, expectedBytes: Int64) {
        downloadProgressTimer?.invalidate()
        totalDownloadBytes = expectedBytes
        downloadProgressTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self, weak task] _ in
            Task { @MainActor in
                guard let self, let task, self.isInstalling else { return }
                let received = max(0, task.countOfBytesReceived)
                let total = task.countOfBytesExpectedToReceive > 0 ? task.countOfBytesExpectedToReceive : expectedBytes
                self.downloadedBytes = received
                self.totalDownloadBytes = max(0, total)
                guard total > 0 else { return }
                let fraction = min(max(Double(received) / Double(total), 0), 1)
                self.installationProgress = 0.04 + fraction * 0.20
                let formatter = ByteCountFormatter()
                formatter.countStyle = .file
                self.installationStage = "Downloading \(formatter.string(fromByteCount: received)) of \(formatter.string(fromByteCount: total))…"
                self.statusText = self.installationStage
            }
        }
    }

    private func stopDownloadProgressMonitoring() {
        downloadProgressTimer?.invalidate()
        downloadProgressTimer = nil
        downloadTask = nil
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
