import AppKit
import SwiftUI

@MainActor
final class FocusedFileLauncherWindowController: NSWindowController {
    private let model = FocusedFileLauncherModel()
    private var hasPresented = false

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Focused File Launcher"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 660, height: 440)
        window.setAccessibilityLabel("RayPlacement Focused File Launcher")
        self.init(window: window)
        window.contentView = NSHostingView(rootView: LimaTypographyRoot(content: FocusedFileLauncherView(model: model)))
    }

    func present() {
        if !hasPresented {
            window?.center()
            hasPresented = true
        }
        if let window { WorkspaceWindowCoordinator.shared.present(window) }
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private final class FocusedFileLauncherModel: ObservableObject {
    @Published var selectedURL: URL?
    @Published var applications: [ApplicationRecord] = []
    @Published var selectedApplicationURL: URL?
    @Published var appSearch = ""
    @Published var status = "Choose an item, then choose its destination."
    @Published var isLoadingApplications = true

    private let applicationIndex = ApplicationIndex()

    init() {
        applicationIndex.scan { [weak self] applications in
            self?.applications = applications
            self?.isLoadingApplications = false
        }
    }

    var selectedApplication: ApplicationRecord? {
        applications.first { $0.url == selectedApplicationURL }
    }

    var filteredApplications: [ApplicationRecord] {
        let query = appSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return applications }
        return applications.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.url.path.localizedCaseInsensitiveContains(query)
        }
    }

    func chooseInFinder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a file or folder"
        panel.message = "RayPlacement will open this item in the app you choose."
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if let selectedURL { panel.directoryURL = selectedURL.deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedURL = url
        status = "Selected \(url.lastPathComponent)."
    }

    func revealInFinder() {
        guard let selectedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([selectedURL])
    }

    func openWithSelectedApplication() {
        guard let selectedURL else { status = "Choose a file or folder in Finder first."; return }
        guard let applicationURL = selectedApplicationURL else { status = "Choose an application first."; return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([selectedURL], withApplicationAt: applicationURL, configuration: configuration) { [weak self] _, error in
            DispatchQueue.main.async {
                if let error { self?.status = "Could not open the item: \(error.localizedDescription)" }
                else { self?.status = "Opened \(selectedURL.lastPathComponent) with \(self?.selectedApplication?.name ?? "the selected app")." }
            }
        }
    }

    func openWithDefaultApplication() {
        guard let selectedURL else { status = "Choose a file or folder in Finder first."; return }
        if NSWorkspace.shared.open(selectedURL) {
            status = "Opened \(selectedURL.lastPathComponent) with its default app."
        } else {
            status = "macOS could not open \(selectedURL.lastPathComponent)."
        }
    }
}

private struct FocusedFileLauncherView: View {
    @ObservedObject var model: FocusedFileLauncherModel
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        ZStack {
            LiquidGlassBackdrop(material: .underWindowBackground, blendingMode: .behindWindow)
            VStack(spacing: 9) {
                header
                workspace
                statusBar
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .tint(settings.accentTheme.primary)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "folder.badge.gearshape")
                .limaFont(.system(size: 14, weight: .bold))
                .foregroundStyle(settings.accentTheme.gradient)
                .frame(width: 31, height: 31)
                .background(.ultraThinMaterial, in: PrismaticPanelShape(cut: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text("Focused File Launcher").limaFont(.system(size: 14, weight: .semibold, design: .rounded))
                Text("Finder → destination app").limaFont(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Choose in Finder", systemImage: "folder") { model.chooseInFinder() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 11)
        .frame(height: 48)
        .liquidGlass(cornerRadius: 12, depth: .raised, accentOpacity: 0.022)
    }

    private var workspace: some View {
        GeometryReader { proxy in
            let selectionWidth = min(max(proxy.size.width * 0.37, 290), 440)
            HStack(spacing: 10) {
                selectionPane
                    .frame(width: selectionWidth)
                    .frame(maxHeight: .infinity)
                applicationPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var selectionPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Selected item").limaFont(.caption.weight(.semibold)).foregroundStyle(settings.accentTheme.tertiary)
            if let url = model.selectedURL {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: fileSymbol(url))
                            .limaFont(.system(size: 20, weight: .semibold))
                            .foregroundStyle(settings.accentTheme.gradient)
                            .frame(width: 46, height: 46)
                            .background(.ultraThinMaterial, in: PrismaticPanelShape(cut: 8))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(url.lastPathComponent).limaFont(.system(size: 13, weight: .semibold)).lineLimit(2)
                            Text(url.path).limaFont(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                        }
                    }
                    HStack(spacing: 7) {
                        Button("Reveal", action: model.revealInFinder).buttonStyle(.bordered).controlSize(.small)
                        Button("Default app", action: model.openWithDefaultApplication).buttonStyle(.bordered).controlSize(.small)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .liquidGlass(cornerRadius: 10, depth: .raised, accentOpacity: 0.018)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "folder").limaFont(.system(size: 28, weight: .medium)).foregroundStyle(.secondary)
                    Text("Nothing selected").limaFont(.system(size: 12, weight: .semibold))
                    Text("Choose any file or folder.").limaFont(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Choose in Finder", action: model.chooseInFinder).buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 58)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .liquidGlass(cornerRadius: 12, depth: .recessed, accentOpacity: 0.012)
    }

    private var applicationPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Open with").limaFont(.caption.weight(.semibold)).foregroundStyle(settings.accentTheme.tertiary)
                Spacer()
                Text(model.selectedApplication?.name ?? "Pick an app")
                    .limaFont(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            TextField("Filter installed apps", text: $model.appSearch).textFieldStyle(.plain)
                .padding(.horizontal, 9).frame(height: 28)
                .background(Color.white.opacity(0.06), in: PrismaticPanelShape(cut: 5))
            Group {
                if model.isLoadingApplications {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading installed apps…").limaFont(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.filteredApplications.isEmpty {
                    VStack(spacing: 7) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        Text("No matching apps").limaFont(.caption.weight(.medium))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $model.selectedApplicationURL) {
                        ForEach(model.filteredApplications) { app in
                            HStack(spacing: 8) {
                                appIcon(app.url)
                                Text(app.name).limaFont(.system(size: 11.5, weight: .medium)).lineLimit(1)
                            }
                            .tag(app.url)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.black.opacity(0.14), in: PrismaticPanelShape(cut: 7))
            HStack(spacing: 7) {
                Button("Open selected", action: model.openWithSelectedApplication)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedURL == nil || model.selectedApplicationURL == nil)
                Spacer()
                Text("Default app stays available").limaFont(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(11)
        .liquidGlass(cornerRadius: 12, depth: .raised, accentOpacity: 0.014)
    }

    private var statusBar: some View {
        HStack(spacing: 7) {
            Circle().fill(settings.accentTheme.tertiary).frame(width: 5, height: 5)
            Text(model.status).limaFont(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Color.black.opacity(0.16), in: PrismaticPanelShape(cut: 6))
    }

    private func fileSymbol(_ url: URL) -> String {
        var directory = ObjCBool(false)
        FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
        return directory.boolValue ? "folder.fill" : "doc.fill"
    }

    private func appIcon(_ url: URL) -> some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: 20, height: 20)
    }
}
