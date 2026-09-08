import AppKit
import CryptoKit
import Foundation
import RayPlacementCore
import SwiftUI

/// Metadata published by Lima's public extension catalog. The catalog is
/// treated as untrusted input: it is validated before it is displayed and
/// validated again before any package is installed.
struct ExtensionStoreCatalog: Decodable {
    let schemaVersion: Int
    let extensions: [ExtensionStoreEntry]
}

struct ExtensionStoreEntry: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let version: String
    let summary: String
    let author: String
    let icon: String
    let category: String
    let downloadURL: URL
    let sha256: String
    let size: Int
    let homepage: URL?
}

enum ExtensionStoreError: LocalizedError {
    case invalidCatalog
    case unsafeDownload
    case invalidPackage
    case digestMismatch
    case unsafeContents
    case installationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidCatalog:
            return "The extension store returned an unsupported or invalid catalog."
        case .unsafeDownload:
            return "This extension package is not hosted by the configured Lima store."
        case .invalidPackage:
            return "The downloaded extension package is invalid or does not match its listing."
        case .digestMismatch:
            return "The extension package did not match its published SHA-256 digest."
        case .unsafeContents:
            return "The extension package contains unsafe paths, hidden files, links, or special files."
        case .installationFailed(let detail):
            return "Lima could not install this extension: \(detail)"
        }
    }
}

@MainActor
final class ExtensionStoreModel: ObservableObject {
    @Published private(set) var entries: [ExtensionStoreEntry] = []
    @Published var query = ""
    @Published private(set) var isLoading = false
    @Published private(set) var installingID: String?
    @Published private(set) var status = "Browse reviewed extensions published for Lima."

    private let onInstalled: () -> Void

    init(onInstalled: @escaping () -> Void) {
        self.onInstalled = onInstalled
    }

    var filteredEntries: [ExtensionStoreEntry] {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty else { return entries }
        return entries.filter {
            [$0.name, $0.summary, $0.author, $0.category, $0.id]
                .joined(separator: " ")
                .localizedCaseInsensitiveContains(cleanQuery)
        }
    }

    func isInstalled(_ entry: ExtensionStoreEntry) -> Bool {
        FileManager.default.fileExists(
            atPath: ApplicationPaths.extensions
                .appendingPathComponent(entry.id, isDirectory: true)
                .path
        )
    }

    func load() {
        guard !isLoading else { return }
        isLoading = true
        status = "Checking the Lima extension store…"

        Task { @MainActor in
            defer { isLoading = false }
            do {
                var request = URLRequest(url: Self.catalogURL)
                request.timeoutInterval = 20
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.setValue("Lima extension store", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    throw ExtensionStoreError.invalidCatalog
                }

                let catalog = try JSONDecoder().decode(ExtensionStoreCatalog.self, from: data)
                try Self.validate(catalog)
                entries = catalog.extensions.sorted {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                status = entries.isEmpty
                    ? "No extensions are published yet."
                    : "\(entries.count) published extension\(entries.count == 1 ? "" : "s")."
            } catch {
                entries = []
                status = error.localizedDescription
            }
        }
    }

    func install(_ entry: ExtensionStoreEntry) {
        guard installingID == nil else { return }
        installingID = entry.id
        status = "Downloading \(entry.name)…"

        Task { @MainActor in
            defer { installingID = nil }
            do {
                try await Self.install(entry)
                onInstalled()
                status = "Installed \(entry.name). Review its requested capabilities in Settings → Extensions."
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private static var catalogURL: URL {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "LimaExtensionStoreURL") as? String,
           let configured = URL(string: raw),
           configured.scheme?.lowercased() == "https" {
            return configured
        }
        return URL(string: "https://www.liamhosfeld.com/store/extensions.json")!
    }

    private static var storeHost: String {
        catalogURL.host?.lowercased() ?? "www.liamhosfeld.com"
    }

    private static func validate(_ catalog: ExtensionStoreCatalog) throws {
        guard catalog.schemaVersion == 1,
              catalog.extensions.count <= 500 else {
            throw ExtensionStoreError.invalidCatalog
        }

        var ids = Set<String>()
        var packageNames = Set<String>()
        for entry in catalog.extensions {
            guard isValid(entry), ids.insert(entry.id).inserted else {
                throw ExtensionStoreError.invalidCatalog
            }
            guard let packageName = packageName(for: entry.downloadURL),
                  packageNames.insert(packageName).inserted else {
                throw ExtensionStoreError.invalidCatalog
            }
        }
    }

    private static func isValid(_ entry: ExtensionStoreEntry) -> Bool {
        let validID = entry.id.range(
            of: "^[A-Za-z0-9][A-Za-z0-9._-]{1,127}$",
            options: .regularExpression
        ) != nil
        let validName = !entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && entry.name.count <= 120
        let validVersion = entry.version.range(
            of: "^[0-9]+\\.[0-9]+\\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$",
            options: .regularExpression
        ) != nil
        let validDigest = entry.sha256.range(
            of: "^[a-fA-F0-9]{64}$",
            options: .regularExpression
        ) != nil
        let validURL = entry.downloadURL.scheme?.lowercased() == "https"
            && entry.downloadURL.host?.lowercased() == storeHost
            && entry.downloadURL.query == nil
            && entry.downloadURL.fragment == nil
            && packageName(for: entry.downloadURL) != nil
        let validSize = entry.size > 0 && entry.size <= 50 * 1_024 * 1_024
        return validID && validName && validVersion && validDigest && validURL && validSize
    }

    private static func packageName(for url: URL) -> String? {
        let path = url.path
        let prefix = "/store/packages/"
        guard path.hasPrefix(prefix) else { return nil }
        let name = String(path.dropFirst(prefix.count))
        guard name.range(
            of: "^[a-z0-9][a-z0-9.-]{0,127}\\.zip$",
            options: [.regularExpression, .caseInsensitive]
        ) != nil else { return nil }
        return name.lowercased()
    }

    private static func install(_ entry: ExtensionStoreEntry) async throws {
        guard isValid(entry) else { throw ExtensionStoreError.unsafeDownload }

        var request = URLRequest(url: entry.downloadURL)
        request.timeoutInterval = 90
        request.setValue("Lima extension store", forHTTPHeaderField: "User-Agent")
        let (temporaryArchive, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw ExtensionStoreError.installationFailed("the server did not return a package")
        }

        let values = try temporaryArchive.resourceValues(forKeys: [.fileSizeKey])
        guard let bytes = values.fileSize, bytes == entry.size else {
            throw ExtensionStoreError.invalidPackage
        }
        guard try sha256(of: temporaryArchive).caseInsensitiveCompare(entry.sha256) == .orderedSame else {
            throw ExtensionStoreError.digestMismatch
        }

        let fileManager = FileManager.default
        try ApplicationPaths.prepare()
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("lima-extension-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        let archiveEntries = try listArchiveEntries(temporaryArchive)
        let rootName = try validateArchiveEntries(archiveEntries, expectedID: entry.id)
        try extract(temporaryArchive, into: staging)
        let package = staging.appendingPathComponent(rootName, isDirectory: true)
        try validateContents(at: staging, expectedRoot: package)

        let manifestURL = package.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: manifestData)
        guard (1...2).contains(manifest.schemaVersion),
              manifest.id == entry.id,
              manifest.name == entry.name,
              manifest.version == entry.version,
              !manifest.bundled,
              manifest.provenance != .bundled,
              manifest.trust != .bundled,
              manifest.trust != .builtIn else {
            throw ExtensionStoreError.invalidPackage
        }

        // A package can never grant itself trust. Normalize the installed
        // manifest even when the publisher omitted the optional provenance
        // fields, so ExtensionLoader always enters the approval flow.
        var installedManifest = manifest
        installedManifest.bundled = false
        installedManifest.provenance = .userInstalled
        installedManifest.trust = .unsigned
        let normalizedManifest = try JSONEncoder().encode(installedManifest)
        try normalizedManifest.write(to: manifestURL, options: .atomic)

        let destination = ApplicationPaths.extensions.appendingPathComponent(entry.id, isDirectory: true)
        let backup = ApplicationPaths.extensions.appendingPathComponent(
            ".lima-store-backup-\(UUID().uuidString)",
            isDirectory: true
        )
        var movedExisting = false
        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.moveItem(at: destination, to: backup)
                movedExisting = true
            }
            try fileManager.moveItem(at: package, to: destination)
            if movedExisting { try? fileManager.removeItem(at: backup) }
        } catch {
            try? fileManager.removeItem(at: destination)
            if movedExisting { try? fileManager.moveItem(at: backup, to: destination) }
            throw ExtensionStoreError.installationFailed(error.localizedDescription)
        }
    }

    private static func listArchiveEntries(_ archive: URL) throws -> [String] {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", archive.path]
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(
                decoding: errors.fileHandleForReading.readDataToEndOfFile().prefix(500),
                as: UTF8.self
            )
            throw ExtensionStoreError.installationFailed(detail.isEmpty ? "the ZIP archive could not be read" : detail)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let entries = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard !entries.isEmpty else { throw ExtensionStoreError.invalidPackage }
        return entries
    }

    private static func validateArchiveEntries(_ entries: [String], expectedID: String) throws -> String {
        var rootNames = Set<String>()
        var seenEntries = Set<String>()
        var hasRootDirectory = false
        var hasManifest = false

        for entry in entries {
            // ZIP paths always use `/`; accepting backslashes and normalizing
            // them would make the archive representation differ from the
            // extracted representation.
            let components = entry.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            let isDirectoryEntry = entry.hasSuffix("/")
            guard !entry.hasPrefix("/"), !entry.contains("\\"),
                  !entry.contains("\0"), !entry.contains("//"), !components.isEmpty,
                  !components.contains("."), !components.contains(".."),
                  components.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }) else {
                throw ExtensionStoreError.unsafeContents
            }
            guard seenEntries.insert(entry).inserted else {
                throw ExtensionStoreError.invalidPackage
            }

            rootNames.insert(components[0])
            if components.count == 1 {
                guard isDirectoryEntry else { throw ExtensionStoreError.invalidPackage }
                hasRootDirectory = true
                continue
            }
            if components.dropFirst().contains(where: { $0 == "manifest.json" }) {
                guard components.count == 2, components[1] == "manifest.json", !isDirectoryEntry else {
                    throw ExtensionStoreError.invalidPackage
                }
            }
            if components.count == 2, components[1] == "manifest.json" {
                guard !hasManifest else { throw ExtensionStoreError.invalidPackage }
                hasManifest = true
            }
        }

        guard rootNames.count == 1,
              let root = rootNames.first,
              root == expectedID,
              hasRootDirectory,
              hasManifest else {
            throw ExtensionStoreError.invalidPackage
        }
        return root
    }

    private static func extract(_ archive: URL, into destination: URL) throws {
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, destination.path]
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(
                decoding: errors.fileHandleForReading.readDataToEndOfFile().prefix(500),
                as: UTF8.self
            )
            throw ExtensionStoreError.installationFailed(detail.isEmpty ? "the package could not be extracted" : detail)
        }
    }

    private static func validateContents(at staging: URL, expectedRoot: URL) throws {
        let fileManager = FileManager.default
        let children = try fileManager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
        guard children.count == 1,
              children[0].standardizedFileURL == expectedRoot.standardizedFileURL else {
            throw ExtensionStoreError.invalidPackage
        }

        guard let enumerator = fileManager.enumerator(
            at: expectedRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw ExtensionStoreError.invalidPackage
        }
        for case let item as URL in enumerator {
            let relative = item.path.replacingOccurrences(of: expectedRoot.path + "/", with: "")
            let components = relative.split(separator: "/").map(String.init)
            guard components.allSatisfy({ !$0.hasPrefix(".") && !$0.contains("\0") }) else {
                throw ExtensionStoreError.unsafeContents
            }
            let attributes = try fileManager.attributesOfItem(atPath: item.path)
            let type = attributes[.type] as? FileAttributeType
            guard type == .typeRegular || type == .typeDirectory else {
                throw ExtensionStoreError.unsafeContents
            }
        }

        let manifestURL = expectedRoot.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw ExtensionStoreError.invalidPackage
        }
    }

    private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class ExtensionStoreWindowController: NSWindowController {
    private let model: ExtensionStoreModel
    private var hasPresented = false

    init(onInstalled: @escaping () -> Void) {
        model = ExtensionStoreModel(onInstalled: onInstalled)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 610),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        LimaWindowChrome.configure(
            window,
            title: "Lima Extension Store",
            accessibilityLabel: "Lima Extension Store",
            minSize: NSSize(width: 620, height: 460)
        )
        super.init(window: window)
        window.contentView = NSHostingView(rootView: LimaTypographyRoot(content: ExtensionStoreView(model: model)))
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        if !hasPresented {
            window?.center()
            hasPresented = true
        }
        if let window { WorkspaceWindowCoordinator.shared.present(window) }
        NSApp.activate(ignoringOtherApps: true)
        model.load()
    }
}

private struct ExtensionStoreView: View {
    @ObservedObject var model: ExtensionStoreModel

    var body: some View {
        ZStack {
            LiquidGlassBackdrop(material: .underWindowBackground, blendingMode: .behindWindow)
            VStack(spacing: LimaDesign.panelGap) {
                HStack(spacing: LimaDesign.controlGap) {
                    LimaToolbarTitle(
                        symbol: "storefront.fill",
                        title: "Extension Store",
                        subtitle: "Published packages · verified before install"
                    )
                    Spacer()
                    Button { model.load() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(LimaToolbarIconButtonStyle())
                    .help("Refresh store")
                }
                .padding(.horizontal, LimaDesign.toolbarPadding)
                .frame(height: LimaDesign.toolbarHeight)
                .liquidGlass(cornerRadius: LimaDesign.standardCorner, depth: .raised, accentOpacity: 0.018)

                VStack(spacing: 0) {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(LimaDesign.secondaryText)
                        TextField("Search published extensions", text: $model.query)
                            .textFieldStyle(.plain)
                        if model.isLoading { ProgressView().controlSize(.small) }
                    }
                    .padding(.horizontal, 11)
                    .frame(height: LimaDesign.controlHeight)
                    .background(LimaDesign.recessedFill, in: PrismaticPanelShape(cut: 7))
                    .overlay {
                        PrismaticPanelShape(cut: 7)
                            .strokeBorder(LimaDesign.controlBorder, lineWidth: LimaDesign.borderWidth)
                    }
                    .padding(10)

                    GlassHairline()
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            if model.filteredEntries.isEmpty, !model.isLoading {
                                VStack(spacing: 9) {
                                    Image(systemName: "puzzlepiece.extension")
                                        .limaFont(.system(size: 30))
                                        .foregroundStyle(LimaDesign.secondaryText)
                                    Text("No matching extensions").limaFont(.headline)
                                    Text("Published extensions will appear here.")
                                        .limaFont(.caption)
                                        .foregroundStyle(LimaDesign.secondaryText)
                                }
                                .padding(.top, 56)
                            }
                            ForEach(model.filteredEntries) { entry in
                                ExtensionStoreCard(
                                    entry: entry,
                                    isInstalling: model.installingID == entry.id,
                                    installed: model.isInstalled(entry)
                                ) {
                                    model.install(entry)
                                }
                            }
                        }
                        .padding(10)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .liquidGlass(cornerRadius: LimaDesign.panelCorner, depth: .recessed, accentOpacity: 0.006)

                Text(model.status)
                    .limaFont(.caption)
                    .foregroundStyle(LimaDesign.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .frame(height: LimaDesign.statusHeight)
                    .background(LimaDesign.statusFill, in: PrismaticPanelShape(cut: 7))
                    .overlay {
                        PrismaticPanelShape(cut: 7)
                            .strokeBorder(LimaDesign.controlBorder, lineWidth: LimaDesign.borderWidth)
                    }
            }
            .padding(LimaDesign.windowPadding)
        }
        .tint(SettingsStore.shared.accentTheme.readablePrimary)
        .preferredColorScheme(SettingsStore.shared.appearance.swiftUIColorScheme)
    }
}

private struct ExtensionStoreCard: View {
    let entry: ExtensionStoreEntry
    let isInstalling: Bool
    let installed: Bool
    let install: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.icon)
                .limaFont(.system(size: 19, weight: .medium))
                .foregroundStyle(SettingsStore.shared.accentTheme.readablePrimary)
                .frame(width: 42, height: 42)
                .background(
                    SettingsStore.shared.accentTheme.primary.opacity(0.12),
                    in: PrismaticPanelShape(cut: 8)
                )
                .overlay {
                    PrismaticPanelShape(cut: 8)
                        .strokeBorder(LimaDesign.controlBorder, lineWidth: LimaDesign.borderWidth)
                }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.name).limaFont(.system(size: 13, weight: .semibold))
                    Text("v\(entry.version)")
                        .limaFont(.caption.monospacedDigit())
                        .foregroundStyle(LimaDesign.secondaryText)
                }
                Text(entry.summary)
                    .limaFont(.caption)
                    .foregroundStyle(LimaDesign.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(entry.category) · by \(entry.author)")
                    .limaFont(.caption2)
                    .foregroundStyle(LimaDesign.tertiaryText)
            }
            Spacer(minLength: 8)
            Button(isInstalling ? "Installing…" : (installed ? "Update" : "Install"), action: install)
                .limaButton(prominent: true, compact: true)
                .disabled(isInstalling)
        }
        .padding(12)
        .liquidGlass(cornerRadius: 11, depth: .raised, accentOpacity: 0.008)
    }
}
