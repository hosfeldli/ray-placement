import AppKit
import CryptoKit
import Foundation
import RayPlacementCore
import SwiftUI

/// The public catalog is deliberately metadata-only. Every install still
/// verifies the package digest and decodes the manifest before it is allowed
/// into the user's Extensions folder.
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
        case .invalidCatalog: return "The extension store returned an unsupported catalog."
        case .unsafeDownload: return "This extension package is not hosted by the configured Lima store."
        case .invalidPackage: return "The downloaded extension package is invalid or does not match its listing."
        case .digestMismatch: return "The extension package did not match its published SHA-256 digest."
        case .unsafeContents: return "The extension package contains unsafe symbolic links or paths."
        case .installationFailed(let detail): return "Lima could not install this extension: \(detail)"
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
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        return entries.filter {
            [$0.name, $0.summary, $0.author, $0.category, $0.id]
                .joined(separator: " ")
                .localizedCaseInsensitiveContains(trimmed)
        }
    }

    func isInstalled(_ entry: ExtensionStoreEntry) -> Bool {
        FileManager.default.fileExists(atPath: ApplicationPaths.extensions
            .appendingPathComponent(entry.id, isDirectory: true).path)
    }

    func load() {
        guard !isLoading else { return }
        isLoading = true
        status = "Checking the Lima extension store…"
        Task {
            defer { isLoading = false }
            do {
                var request = URLRequest(url: Self.catalogURL)
                request.timeoutInterval = 20
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.setValue("Lima extension store", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw ExtensionStoreError.invalidCatalog
                }
                let catalog = try JSONDecoder().decode(ExtensionStoreCatalog.self, from: data)
                guard catalog.schemaVersion == 1,
                      catalog.extensions.allSatisfy(Self.isValid) else {
                    throw ExtensionStoreError.invalidCatalog
                }
                entries = catalog.extensions.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                status = entries.isEmpty ? "No extensions are published yet." : "\(entries.count) published extension\(entries.count == 1 ? "" : "s")."
            } catch {
                status = error.localizedDescription
            }
        }
    }

    func install(_ entry: ExtensionStoreEntry) {
        guard installingID == nil else { return }
        installingID = entry.id
        status = "Downloading \(entry.name)…"
        Task {
            defer { installingID = nil }
            do {
                try await Self.install(entry)
                onInstalled()
                status = "Installed \(entry.name)."
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private static var catalogURL: URL {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "LimaExtensionStoreURL") as? String,
           let configured = URL(string: raw), configured.scheme == "https" {
            return configured
        }
        return URL(string: "https://www.liamhosfeld.com/store/extensions.json")!
    }

    private static func isValid(_ entry: ExtensionStoreEntry) -> Bool {
        !entry.id.isEmpty && !entry.name.isEmpty && !entry.version.isEmpty
            && entry.downloadURL.scheme == "https"
            && entry.downloadURL.host?.lowercased() == catalogURL.host?.lowercased()
            && entry.sha256.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil
            && entry.size > 0 && entry.size <= 50 * 1_024 * 1_024
    }

    private static func install(_ entry: ExtensionStoreEntry) async throws {
        guard isValid(entry) else { throw ExtensionStoreError.unsafeDownload }
        var request = URLRequest(url: entry.downloadURL)
        request.timeoutInterval = 90
        request.setValue("Lima extension store", forHTTPHeaderField: "User-Agent")
        let (temporaryArchive, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ExtensionStoreError.installationFailed("the server did not return a package")
        }
        let values = try temporaryArchive.resourceValues(forKeys: [.fileSizeKey])
        guard let bytes = values.fileSize, bytes > 0, bytes <= entry.size else {
            throw ExtensionStoreError.invalidPackage
        }
        guard try sha256(of: temporaryArchive).caseInsensitiveCompare(entry.sha256) == .orderedSame else {
            throw ExtensionStoreError.digestMismatch
        }

        let fileManager = FileManager.default
        try ApplicationPaths.prepare()
        let staging = fileManager.temporaryDirectory.appendingPathComponent("lima-extension-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try extract(temporaryArchive, into: staging)
        try validateContents(at: staging)
        let children = try fileManager.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        guard children.count == 1,
              (try children[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true) else {
            throw ExtensionStoreError.invalidPackage
        }
        let package = children[0]
        let manifestURL = package.appendingPathComponent("manifest.json")
        guard let manifest = try? JSONDecoder().decode(ExtensionManifest.self, from: Data(contentsOf: manifestURL)),
              manifest.id == entry.id,
              manifest.name == entry.name,
              manifest.version == entry.version,
              (1...2).contains(manifest.schemaVersion) else {
            throw ExtensionStoreError.invalidPackage
        }
        let destination = ApplicationPaths.extensions.appendingPathComponent(entry.id, isDirectory: true)
        let backup = ApplicationPaths.extensions.appendingPathComponent(".lima-store-backup-\(UUID().uuidString)", isDirectory: true)
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

    private static func extract(_ archive: URL, into destination: URL) throws {
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, destination.path]
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ExtensionStoreError.installationFailed(String(decoding: errors.fileHandleForReading.readDataToEndOfFile().prefix(500), as: UTF8.self))
        }
    }

    private static func validateContents(at root: URL) throws {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else {
            throw ExtensionStoreError.invalidPackage
        }
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw ExtensionStoreError.unsafeContents }
            guard values.isRegularFile == true || values.isDirectory == true else { throw ExtensionStoreError.unsafeContents }
        }
    }

    private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hasher.update(data: chunk) }
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
        LimaWindowChrome.configure(window, title: "Lima Extension Store", accessibilityLabel: "Lima Extension Store", minSize: NSSize(width: 620, height: 460))
        super.init(window: window)
        window.contentView = NSHostingView(rootView: LimaTypographyRoot(content: ExtensionStoreView(model: model)))
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        if !hasPresented { window?.center(); hasPresented = true }
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
                    LimaToolbarTitle(symbol: "storefront.fill", title: "Extension Store", subtitle: "Published packages · verified before install")
                    Spacer()
                    Button { model.load() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(LimaToolbarIconButtonStyle())
                        .help("Refresh store")
                }
                .padding(.horizontal, LimaDesign.toolbarPadding)
                .frame(height: LimaDesign.toolbarHeight)
                .liquidGlass(cornerRadius: LimaDesign.standardCorner, depth: .raised, accentOpacity: 0.018)

                VStack(spacing: 0) {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass").foregroundStyle(LimaDesign.secondaryText)
                        TextField("Search published extensions", text: $model.query).textFieldStyle(.plain)
                        if model.isLoading { ProgressView().controlSize(.small) }
                    }
                    .padding(.horizontal, 11)
                    .frame(height: LimaDesign.controlHeight)
                    .background(LimaDesign.recessedFill, in: PrismaticPanelShape(cut: 7))
                    .overlay(PrismaticPanelShape(cut: 7).stroke(LimaDesign.controlBorder, lineWidth: LimaDesign.borderWidth))
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
                                ExtensionStoreCard(entry: entry, isInstalling: model.installingID == entry.id, installed: model.isInstalled(entry)) {
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
            }
            .padding(LimaDesign.windowPadding)
        }
        .tint(SettingsStore.shared.accentTheme.primary)
        .preferredColorScheme(.dark)
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
                .foregroundStyle(SettingsStore.shared.accentTheme.primary)
                .frame(width: 42, height: 42)
                .background(SettingsStore.shared.accentTheme.primary.opacity(0.12), in: PrismaticPanelShape(cut: 8))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.name).limaFont(.system(size: 13, weight: .semibold))
                    Text("v\(entry.version)").limaFont(.caption.monospacedDigit()).foregroundStyle(LimaDesign.secondaryText)
                }
                Text(entry.summary).limaFont(.caption).foregroundStyle(LimaDesign.secondaryText).fixedSize(horizontal: false, vertical: true)
                Text("\(entry.category) · by \(entry.author)").limaFont(.caption2).foregroundStyle(LimaDesign.tertiaryText)
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
