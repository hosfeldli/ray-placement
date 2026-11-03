import AppKit
import SwiftUI
import RayPlacementCore

struct ExtensionLibraryView: View {
    @ObservedObject var viewModel: LauncherViewModel
    @ObservedObject var catalog: ExtensionStoreModel
    let reloadExtensions: () -> Void
    var localOnly = false
    @ObservedObject private var library = ExtensionLibraryStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var commands = CommandManager.shared
    @ObservedObject private var packages = ExtensionPackageManager.shared
    @State private var area = Area.library
    @State private var query = ""
    @State private var filter = Filter.all
    @State private var selectedID: String?
    @State private var detail = Detail.overview
    @State private var removal: ExtensionLibraryEntry?
    @State private var editor: ExtensionLibraryEntry?
    @State private var checkResult: ExtensionInspection?

    init(viewModel: LauncherViewModel, catalog: ExtensionStoreModel, reloadExtensions: @escaping () -> Void,
         localOnly: Bool = false, library: ExtensionLibraryStore? = nil, selectedID: String? = nil, showDiagnostics: Bool = false) {
        self.viewModel = viewModel; self.catalog = catalog; self.reloadExtensions = reloadExtensions; self.localOnly = localOnly
        _library = ObservedObject(wrappedValue: library ?? .shared)
        _selectedID = State(initialValue: selectedID)
        _detail = State(initialValue: showDiagnostics ? .diagnostics : .overview)
    }
    private typealias Area = ExtensionLibraryArea
    private enum Filter: String, CaseIterable, Identifiable {
        case all = "All", attention = "Needs attention", active = "Enabled", disabled = "Disabled", local = "Development", builtIn = "Built-in"
        var id: String { rawValue }
    }
    private enum Detail: String, CaseIterable, Identifiable {
        case overview = "Overview", commands = "Commands & Shortcuts", diagnostics = "Diagnostics"
        var id: String { rawValue }
    }
    private var visible: [ExtensionLibraryEntry] {
        library.entries.filter { entry in
            let matches = query.split(whereSeparator: \.isWhitespace).allSatisfy { entry.searchableText.localizedCaseInsensitiveContains(String($0)) }
            guard matches else { return false }
            switch filter {
            case .all: return true
            case .attention: return [.review, .invalid].contains(library.status(entry))
            case .active: return library.status(entry) == .ready
            case .disabled: return library.status(entry) == .disabled
            case .local: return entry.development
            case .builtIn: return entry.bundled
            }
        }
    }
    private var selected: ExtensionLibraryEntry? { visible.first(where: { $0.id == selectedID }) ?? visible.first }
    var body: some View {
        VStack(spacing: 0) {
            header
            if let message = library.message {
                HStack { Text(message).font(.caption).textSelection(.enabled); Spacer(); Button { library.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss status") }
                    .padding(10).background(LimaTheme.accentInk.opacity(0.07))
            }
            Group {
                switch area {
                case .library: libraryContent
                case .discover: discover
                case .build: ExtensionBuilderView(reload: reload, created: { url in selectedID = url.appendingPathComponent("manifest.json").path; area = .library; library.refresh() })
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(LimaTheme.surfacePrimary)
        .onAppear { library.refresh(); applyRequestedArea() }
        .onChange(of: library.requestedArea) { _ in applyRequestedArea() }
        .onReceive(viewModel.$extensionCommands.dropFirst()) { _ in library.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: ExtensionDevelopmentFolders.changed)) { _ in library.refresh() }
        .onChange(of: catalog.installingID) { id in if id == nil { reload() } }
        .onChange(of: area) { value in if value == .discover && catalog.entries.isEmpty { catalog.load() } }
        .sheet(item: $editor) { entry in ExtensionManifestEditor(entry: entry, saved: reload) }
        .sheet(item: $checkResult) { result in inspectionSheet(result) }
        .alert("Remove extension?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })) {
            Button("Cancel", role: .cancel) { removal = nil }
            Button(removal?.development == true ? "Unlink Folder" : "Remove", role: .destructive) {
                if let removal { perform { try library.remove(removal); reload() } }; removal = nil
            }
        } message: { Text(removal?.development == true ? "Your source files stay in their current folder." : "Commands and AI contributions will be unloaded. Your shortcut preferences are preserved.") }
    }
    private func applyRequestedArea() {
        if let requested = library.requestedArea, !localOnly || requested != .discover {
            area = requested; library.requestedArea = nil
        }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Extensions").font(.title2.weight(.semibold))
                    Text("Add capabilities. Keep control of what runs.").font(.caption).foregroundStyle(LimaTheme.textSecondary)
                }
                Spacer()
                Menu {
                    Button("Install a Folder…") { chooseFolder(link: false) }
                    Button("Link a Development Folder…") { chooseFolder(link: true) }
                    Button("Check a Folder…") { checkFolder() }
                    Divider()
                    Button("Open Installed Folder") { NSWorkspace.shared.open(ApplicationPaths.extensions) }
                } label: { Label("Add", systemImage: "plus") }
                .menuStyle(.borderlessButton).fixedSize()
                Button(action: reload) { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Reload extensions").accessibilityLabel("Reload extensions")
            }
            HStack {
                Picker("Extension area", selection: $area) {
                    ForEach(Area.allCases.filter { !localOnly || $0 != .discover }) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 360)
                Spacer()
                if library.isLoading { ProgressView().controlSize(.small) }
            }
        }.padding(16)
    }
    private var libraryContent: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find an extension or command", text: $query).textFieldStyle(.plain)
                Picker("Filter extensions", selection: $filter) { ForEach(Filter.allCases) { Text($0.rawValue).tag($0) } }
                    .labelsHidden().frame(maxWidth: 170)
            }.padding(10).background(LimaTheme.surfaceSecondary).padding(.horizontal, 12).padding(.bottom, 10)
            if visible.isEmpty {
                empty("No extensions here", detail: library.entries.isEmpty ? "Install a folder, explore Discover, or build your first command." : "Try a different search or filter.", symbol: "puzzlepiece.extension")
            } else {
                GeometryReader { geometry in
                    if geometry.size.width < 620 {
                        VStack(spacing: 0) {
                            Picker("Extension", selection: Binding(get: { selected?.id ?? "" }, set: { selectedID = $0 })) {
                                ForEach(visible) { Text($0.name).tag($0.id) }
                            }.padding(10)
                            if let selected { inspector(selected) }
                        }
                    } else {
                        HSplitView {
                            ScrollView { LazyVStack(spacing: 4) { ForEach(visible) { entry in packageRow(entry) } }.padding(8) }
                                .frame(minWidth: 195, idealWidth: 230, maxWidth: 290)
                            if let selected { inspector(selected).frame(minWidth: 300) }
                        }
                    }
                }
            }
        }
    }
    private func packageRow(_ entry: ExtensionLibraryEntry) -> some View {
        let status = library.status(entry)
        return Button { selectedID = entry.id; detail = .overview } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: entry.development ? "hammer" : "puzzlepiece.extension.fill")
                    .frame(width: 28, height: 30).foregroundStyle(LimaTheme.accentInk)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name).font(.callout.weight(.semibold)).lineLimit(2)
                    Text(entry.source).font(.caption2).foregroundStyle(.secondary)
                    Label(status.rawValue, systemImage: status.symbol).font(.caption2).foregroundStyle(tint(status))
                }
                Spacer(minLength: 0)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected?.id == entry.id ? LimaTheme.surfaceSelected : LimaTheme.surfaceSecondary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).accessibilityLabel(entry.name + ", " + status.rawValue)
    }
    private func inspector(_ entry: ExtensionLibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                        Text([entry.source, entry.manifest?.version ?? "Unversioned"].joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if library.status(entry) == .ready || library.status(entry) == .disabled {
                        Toggle("Enabled", isOn: Binding(get: { library.status(entry) == .ready }, set: { library.setEnabled($0, entry: entry); reloadExtensions() }))
                            .toggleStyle(.switch).controlSize(.small).fixedSize()
                    }
                }
                Picker("Extension details", selection: $detail) { ForEach(Detail.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu).labelsHidden()
            }.padding(16)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    switch detail {
                    case .overview: overview(entry)
                    case .commands: commandRows(entry)
                    case .diagnostics: diagnostics(entry.inspection)
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button("Open Folder") { NSWorkspace.shared.open(entry.inspection.directory) }
                Button("Edit Manifest") { editor = entry }.disabled(entry.bundled)
                Spacer()
                if library.status(entry) == .removed, let id = entry.packageID {
                    Button("Restore") { packages.restoreBundled(id: id); reload() }
                } else { Button(entry.development ? "Unlink…" : "Remove…") { removal = entry } }
            }.controlSize(.small).padding(12)
        }
    }
    @ViewBuilder private func overview(_ entry: ExtensionLibraryEntry) -> some View {
        Text(entry.manifest?.description ?? "Check Diagnostics to repair this extension.").font(.callout).foregroundStyle(.secondary)
        let state = library.status(entry)
        Label(state.rawValue, systemImage: state.symbol).font(.headline).foregroundStyle(tint(state))
        if state == .review {
            Text("Review the capabilities below, then enable this version. A manifest change requires another review.").font(.callout)
            Button("Approve & Enable") { perform { try library.approve(entry); reload() } }.buttonStyle(.borderedProminent)
        } else if state == .invalid {
            Button("Show Diagnostics") { detail = .diagnostics }.buttonStyle(.borderedProminent)
        }
        if let manifest = entry.manifest {
            Text("\(manifest.commands.count) commands · \(manifest.contributions.tools.count) AI tools · \(manifest.contributions.skills.count) skills · \(manifest.contributions.agents.count) agents")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("Capabilities").font(.headline)
                if manifest.capabilities.isEmpty { Text("No host capabilities requested.").font(.caption).foregroundStyle(.secondary) }
                ForEach(manifest.capabilities.sorted { $0.rawValue < $1.rawValue }, id: \.rawValue) { capability in
                    Label(capability.rawValue, systemImage: "checkmark.shield").font(.callout)
                }
                if manifest.capabilities.contains(.shell) { Text("Scripts run as your macOS account. These declarations are not an OS sandbox.").font(.caption).foregroundStyle(.secondary) }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(LimaTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10))
            if !manifest.contributions.tools.isEmpty || !manifest.contributions.skills.isEmpty || !manifest.contributions.agents.isEmpty {
                DisclosureGroup("AI contributions") {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(manifest.contributions.tools) { tool in
                            VStack(alignment: .leading) { Text(tool.title).font(.callout.weight(.medium)); Text(tool.execution == .metadataOnly ? "Documentation only · not executable by AI" : ExtensionToolHostAdapterRegistry.adapter(for: tool.hostAdapterID) == nil ? "Host adapter unavailable in this Lima version" : "Read-only host adapter · choose in AI Tool Access after enabling").font(.caption).foregroundStyle(.secondary) }
                        }
                        ForEach(manifest.contributions.skills) { Text("Skill · " + $0.name).font(.callout) }
                        ForEach(manifest.contributions.agents) { Text("Agent · " + $0.name).font(.callout) }
                    }.padding(.top, 8)
                }
            }
            Text(manifest.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
    @ViewBuilder private func commandRows(_ entry: ExtensionLibraryEntry) -> some View {
        let loaded = viewModel.extensionCommands.filter { $0.extensionID == entry.packageID }
        if loaded.isEmpty {
            Text(entry.manifest?.commands.isEmpty == true ? "This package contributes AI capabilities instead of launcher commands." : "Enable this extension after fixing any errors and reviewing its capabilities.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(entry.manifest?.commands ?? []) { Text($0.title).font(.callout) }
        } else {
            ForEach(loaded, id: \.launcherIdentifier) { command in
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Toggle(command.command.title, isOn: Binding(get: { commands.isEnabled(command.launcherIdentifier) }, set: { commands.setEnabled($0, for: command.launcherIdentifier) }))
                            .toggleStyle(.checkbox)
                        Spacer()
                        Button("Run") { viewModel.findCommandInSearch(command.command.title); viewModel.executeCommand(id: command.launcherIdentifier) }
                            .disabled(library.status(entry) != .ready || !commands.isEnabled(command.launcherIdentifier))
                    }
                    if let subtitle = command.command.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Label("Shortcut", systemImage: "keyboard").font(.caption)
                        Spacer()
                        ShortcutRecorder(shortcut: Binding(get: { settings.effectiveShortcut(for: command) ?? "" }, set: { value in
                            let conflicts = commands.shortcutRegistry.owners(of: value).filter { $0.id != command.launcherIdentifier }
                            guard conflicts.isEmpty else { library.message = "Already assigned to \(conflicts.map(\.title).joined(separator: ", ")). Choose another shortcut."; return }
                            settings.setShortcut(value, for: command)
                        }), label: "Record shortcut").frame(width: 140, height: 28)
                    }
                }.padding(12).background(LimaTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
    @ViewBuilder private func diagnostics(_ inspection: ExtensionInspection) -> some View {
        if inspection.diagnostics.isEmpty { Label("All package checks passed", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
        ForEach(inspection.diagnostics) { issue in
            VStack(alignment: .leading, spacing: 5) {
                Label(issue.path.isEmpty ? "Manifest" : issue.path, systemImage: issue.severity == .error ? "exclamationmark.triangle" : "info.circle").font(.headline)
                Text(issue.message).font(.callout).textSelection(.enabled)
                Text(issue.fix).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(LimaTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10))
        }
        Text(inspection.directory.path).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
    }
    private var discover: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                HStack { Text("Discover extensions").font(.headline); Spacer(); Button("Refresh") { catalog.load() }.disabled(catalog.isLoading) }
                TextField("Search extensions", text: $query).textFieldStyle(.roundedBorder)
                Text(catalog.status).font(.caption).foregroundStyle(.secondary)
                ForEach(catalog.entries.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 5) { Text(entry.name).font(.headline); Text(entry.summary).font(.callout).foregroundStyle(.secondary); Text("\(entry.author) · \(entry.version)").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button(installLabel(entry)) { catalog.install(entry) }.disabled(catalog.installingID != nil || !canInstall(entry))
                    }.padding(14).background(LimaTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12))
                }
                if catalog.entries.isEmpty && !catalog.isLoading { Text("You can also add a local extension folder or create one in Build.").font(.callout).foregroundStyle(.secondary) }
            }.padding(16)
        }
    }
    private func canInstall(_ entry: ExtensionStoreEntry) -> Bool {
        guard let installed = library.entries.first(where: { $0.packageID == entry.id }) else { return true }
        guard !installed.bundled, !installed.development, let raw = installed.manifest?.version,
              let current = SemanticVersion(raw), let remote = SemanticVersion(entry.version) else { return false }
        return remote > current
    }
    private func installLabel(_ entry: ExtensionStoreEntry) -> String {
        guard library.entries.contains(where: { $0.packageID == entry.id }) else { return "Install" }
        return canInstall(entry) ? "Update" : "Installed"
    }
    private func inspectionSheet(_ result: ExtensionInspection) -> some View {
        VStack(alignment: .leading, spacing: 12) { Text("Package check").font(.title2); ScrollView { diagnostics(result) }; Button("Done") { checkResult = nil } }
            .padding(20).frame(width: 580, height: 460)
    }
    private func tint(_ status: ExtensionLibraryStatus) -> Color { switch status { case .ready: .green; case .disabled, .removed: .secondary; case .review: .orange; case .invalid: .red } }
    private func empty(_ title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 10) { Image(systemName: symbol).font(.largeTitle); Text(title).font(.headline); Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center); Button("Build an Extension") { area = .build } }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func reload() { reloadExtensions(); library.refresh() }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { library.message = error.localizedDescription } }
    private func chooseFolder(link: Bool) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = link ? "Link Development Folder" : "Install Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in do { try await library.addFolder(url, link: link); reload() } catch { library.message = error.localizedDescription } }
    }
    private func checkFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in checkResult = await Task.detached { ExtensionDeveloperKit.inspect(url) }.value }
    }
}

extension ExtensionInspection: Identifiable {
    public var id: String { directory.path }
}
