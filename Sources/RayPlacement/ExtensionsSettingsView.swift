import SwiftUI
import RayPlacementCore

@MainActor
struct ExtensionsSettingsView: View {
    @ObservedObject var viewModel: LauncherViewModel
    @ObservedObject var storeModel: ExtensionStoreModel
    let reloadExtensions: () -> Void
    /// Workspace mode exposes only installed and local-development packages.
    /// The Settings window can still opt into the catalog explicitly.
    let localOnly: Bool

    init(
        viewModel: LauncherViewModel,
        storeModel: ExtensionStoreModel,
        reloadExtensions: @escaping () -> Void,
        localOnly: Bool = false
    ) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        _storeModel = ObservedObject(wrappedValue: storeModel)
        self.reloadExtensions = reloadExtensions
        self.localOnly = localOnly
    }

    @State private var tab: ExtensionTab = .installed
    @State private var query = ""
    @State private var installedFilter: ExtensionWorkspaceFilter = .all
    @ObservedObject private var commandManager = CommandManager.shared
    @State private var category = "All"
    @State private var selectedID: String?
    @State private var confirmUninstallID: String?
    @State private var status: String?
    @State private var detailTab: DetailTab = .commands
    @State private var cachedContributions: [String: ExtensionLoader.ContributionCatalogEntry] = [:]
    @State private var cachedManifests: [ExtensionManifest] = []

    private enum DetailTab: String, CaseIterable, Identifiable { case commands = "Commands", contributions = "Tools, Skills & Agents", preferences = "Preferences", permissions = "Permissions"; var id: String { rawValue } }

    private enum ExtensionTab: String, CaseIterable, Identifiable {
        case installed = "Installed"
        case available = "Store"
        case updates = "Updates"
        case developer = "Developer"
        var id: String { rawValue }
    }

    private var visibleTabs: [ExtensionTab] {
        localOnly ? [.installed, .developer] : ExtensionTab.allCases
    }

    private struct InstalledPackage: Identifiable {
        let id: String
        let name: String
        let version: String
        let source: String
        let enabled: Bool
        let commandCount: Int
        let commands: [LoadedExtensionCommand]
        let bundled: Bool
        let manifest: ExtensionManifest?
        let tools: [ExtensionToolDefinition]
        let skills: [ExtensionSkillDefinition]
        let agents: [ExtensionAgentDefinition]
        let lifecycleState: ExtensionPackageState
    }

    private func refreshPackageMetadata() {
        let contributions = ExtensionLoader().contributionCatalog()
        var manifests: [ExtensionManifest] = []
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: ApplicationPaths.extensions,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            let decoder = JSONDecoder()
            for item in contents {
                let manifestURL: URL
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory)
                if isDirectory.boolValue {
                    manifestURL = item.appendingPathComponent("manifest.json")
                } else if item.pathExtension.lowercased() == "json" {
                    manifestURL = item
                } else {
                    continue
                }
                guard let data = try? Data(contentsOf: manifestURL),
                      let manifest = try? decoder.decode(ExtensionManifest.self, from: data) else { continue }
                manifests.append(manifest)
            }
        }
        cachedContributions = Dictionary(uniqueKeysWithValues: contributions.map { ($0.extensionID, $0) })
        cachedManifests = manifests
    }

    private func reloadInstalled() {
        reloadExtensions()
        refreshPackageMetadata()
    }

    private var installed: [InstalledPackage] {
        var packages: [String: InstalledPackage] = [:]
        let contributionsByID = cachedContributions

        // Start with loaded commands so command settings remain available.
        for (id, commands) in Dictionary(grouping: viewModel.extensionCommands, by: \.extensionID) {
            guard let first = commands.first else { continue }
            let bundled = first.bundled || first.trust == .bundled || first.trust == .builtIn
            packages[id] = InstalledPackage(
                id: id,
                name: first.extensionName,
                version: first.version ?? "Unknown",
                source: bundled ? "Built-in" : (first.trust == .unsigned ? "Local" : "Installed"),
                enabled: commands.contains { CommandManager.shared.isEnabled($0.settingsIdentifier) },
                commandCount: commands.count,
                commands: commands.sorted { $0.command.title.localizedStandardCompare($1.command.title) == .orderedAscending },
                bundled: bundled,
                manifest: nil,
                tools: contributionsByID[id]?.tools ?? [],
                skills: contributionsByID[id]?.skills ?? [],
                agents: contributionsByID[id]?.agents ?? [],
                lifecycleState: ExtensionPackageManager.shared.record(for: id)?.state ?? .installed
            )
        }

        // Also discover valid package manifests with zero commands. This keeps
        // package lifecycle management independent from launcher registration.
        for manifest in cachedManifests where packages[manifest.id] == nil {
            let bundled = manifest.bundled || manifest.provenance == .bundled || manifest.trust == .bundled || manifest.trust == .builtIn
            packages[manifest.id] = InstalledPackage(
                id: manifest.id,
                name: manifest.name,
                version: manifest.version ?? "Unknown",
                source: bundled ? "Built-in" : (manifest.provenance == .unsigned ? "Local" : "Installed"),
                enabled: !bundled || SettingsStore.shared.extensionEnabledOverrides[manifest.id] ?? true,
                commandCount: manifest.commands.count,
                commands: [],
                bundled: bundled,
                manifest: manifest,
                tools: manifest.contributions.tools,
                skills: manifest.contributions.skills,
                agents: manifest.contributions.agents,
                lifecycleState: ExtensionPackageManager.shared.record(for: manifest.id)?.state ?? (ExtensionPackageManager.shared.isLogicallyRemoved(manifest.id) ? .logicallyRemoved : .installed)
            )
        }

        return packages.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var filteredInstalled: [InstalledPackage] {
        installed.filter { package in
            ExtensionWorkspaceFilter.matches(query: query, name: package.name, id: package.id,
                commandTitles: package.commands.map { $0.command.title })
                && installedFilter.includes(enabled: package.enabled, bundled: package.bundled)
        }
    }

    private var available: [ExtensionStoreEntry] {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return storeModel.entries.filter { entry in
            let matchesQuery = cleanQuery.isEmpty || [entry.name, entry.summary, entry.author, entry.category, entry.id]
                .joined(separator: " ")
                .localizedCaseInsensitiveContains(cleanQuery)
            let matchesCategory = category == "All" || entry.category == category
            return matchesQuery && matchesCategory
        }
    }

    private var categories: [String] {
        ["All"] + Array(Set(storeModel.entries.map(\.category))).sorted()
    }

    private var updates: [(entry: ExtensionStoreEntry, installed: InstalledPackage)] {
        let installedByID = Dictionary(uniqueKeysWithValues: installed.map { ($0.id, $0) })
        return storeModel.entries.compactMap { entry in
            guard let package = installedByID[entry.id],
                  let current = SemanticVersion(package.version),
                  let latest = SemanticVersion(entry.version),
                  current < latest else { return nil }
            return (entry, package)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if localOnly {
                localWorkspaceHeader
            }

            HStack {
                Picker("Extension area", selection: $tab) {
                    ForEach(visibleTabs) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Spacer()
                if !localOnly, !updates.isEmpty {
                    Text("\(updates.count) update\(updates.count == 1 ? "" : "s")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
            .padding(12)

            HStack(spacing: 10) {
                LimaWorkspaceSearchField(placeholder: "Search extensions and commands…", text: $query)
                Button {
                    reloadInstalled()
                    if !localOnly { storeModel.load() }
                } label: { Image(systemName: "arrow.clockwise").frame(width: 28, height: 28) }
                .buttonStyle(.bordered)
                .help(localOnly ? "Reload installed extensions" : "Refresh extensions and catalog")
                .accessibilityLabel("Reload extensions")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            Group {
                switch tab {
                case .installed: installedView
                case .available: availableView
                case .updates: updatesView
                case .developer: developerView
                }
            }
        }
        .onAppear {
            if !localOnly { storeModel.load() }
            reloadInstalled()
            if selectedID == nil { selectedID = filteredInstalled.first?.id }
        }
        .onChange(of: storeModel.installingID) { installingID in
            if installingID == nil { refreshPackageMetadata() }
        }
        .onChange(of: query) { _ in reconcileSelection() }
        .onChange(of: installedFilter) { _ in reconcileSelection() }
        .onChange(of: filteredInstalled.map(\.id)) { _ in reconcileSelection() }
        .alert("Uninstall Extension?", isPresented: Binding(get: { confirmUninstallID != nil }, set: { if !$0 { confirmUninstallID = nil } })) {
            Button("Cancel", role: .cancel) { confirmUninstallID = nil }
            Button("Uninstall", role: .destructive) {
                if let id = confirmUninstallID { uninstall(id: id) }
                confirmUninstallID = nil
            }
        } message: {
            Text("The extension code will be removed. Lima will preserve its settings and shortcuts when possible.")
        }
    }

    private func reconcileSelection() {
        if !filteredInstalled.contains(where: { $0.id == selectedID }) {
            selectedID = filteredInstalled.first?.id
        }
    }

    private var localWorkspaceHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 11) {
                localWorkspaceTitle.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 8)
                localWorkspaceActions
            }
            VStack(alignment: .leading, spacing: 12) {
                localWorkspaceTitle
                localWorkspaceActions
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(LimaTheme.surfacePrimary)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LimaTheme.borderSubtle).frame(height: LimaDesign.hairlineWidth)
        }
    }

    private var localWorkspaceTitle: some View {
        LimaWorkspaceHeading(title: "Extensions", subtitle: "Manage the tools already available on this Mac.",
                             symbol: "puzzlepiece.extension.fill", tint: .cyan)
    }

    private var localWorkspaceActions: some View {
        HStack(spacing: 11) {
            Text("\(installed.count.formatted()) local")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(LimaTheme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(LimaTheme.surfaceSecondary, in: Capsule())
            Button("Open Folder") {
                NSWorkspace.shared.open(ApplicationPaths.extensions)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Open Lima’s local Extensions folder")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var installedView: some View {
        GeometryReader { proxy in
            let packages = filteredInstalled
            let catalogByID = Dictionary(uniqueKeysWithValues: storeModel.entries.map { ($0.id, $0) })
            let updatesByID = Dictionary(uniqueKeysWithValues: updates.map { ($0.installed.id, $0.entry) })
            let split = proxy.size.width >= 860
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(ExtensionWorkspaceFilter.allCases) { filter in
                                    Button { installedFilter = filter } label: {
                                        Text(filter.rawValue).limaFont(.caption.weight(.medium))
                                            .padding(.horizontal, 12).padding(.vertical, 7)
                                            .foregroundStyle(installedFilter == filter ? LimaTheme.accentInk : LimaTheme.textSecondary)
                                            .background(installedFilter == filter ? LimaTheme.surfaceSelected : LimaTheme.surfaceRaised, in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityAddTraits(installedFilter == filter ? .isSelected : [])
                                }
                            }
                        }
                        Text("\(packages.count) matching extensions").limaFont(.callout.weight(.semibold))
                            .padding(.vertical, 6)
                        if packages.isEmpty {
                            emptyState("No matching extensions",
                                       detail: installed.isEmpty ? "Add a local package to the Extensions folder, then reload." : "Try a different search or filter.",
                                       symbol: "puzzlepiece.extension")
                        }
                        ForEach(packages) { package in
                            installedCard(package, inlineDetail: !split,
                                          catalogEntry: catalogByID[package.id], updateEntry: updatesByID[package.id])
                        }
                        if let status { statusLine(status) }
                    }
                    .padding(16)
                }
                if split, let package = packages.first(where: { $0.id == selectedID }) {
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            LimaWorkspaceHeading(title: package.name, subtitle: package.source + " · v" + package.version,
                                                 symbol: "puzzlepiece.extension.fill", tint: .cyan)
                            extensionDetail(package)
                        }.padding(16)
                    }
                    .frame(width: 344)
                    .background(LimaTheme.surfaceSecondary)
                }
            }
        }
    }

    private func installedCard(_ package: InstalledPackage, inlineDetail: Bool,
                               catalogEntry: ExtensionStoreEntry?, updateEntry: ExtensionStoreEntry?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    installedSummary(package, catalogEntry: catalogEntry).fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 8)
                    installedActions(package, catalogEntry: catalogEntry, updateEntry: updateEntry)
                }
                VStack(alignment: .leading, spacing: 12) {
                    installedSummary(package, catalogEntry: catalogEntry)
                    HStack {
                        Spacer(minLength: 0)
                        installedActions(package, catalogEntry: catalogEntry, updateEntry: updateEntry)
                    }
                }
            }
            .padding(14)

            if inlineDetail, selectedID == package.id {
                Divider()
                extensionDetail(package)
            }
        }
        .background(selectedID == package.id ? LimaTheme.surfaceSelected : LimaTheme.surfaceRaised,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(selectedID == package.id ? LimaTheme.accentInk : LimaTheme.borderSubtle, lineWidth: 0.75))
    }

    private func installedSummary(_ package: InstalledPackage, catalogEntry: ExtensionStoreEntry?) -> some View {
        Button {
            selectedID = package.id
            detailTab = .commands
        } label: {
            HStack(spacing: 10) {
                LimaFeatureIcon(symbol: "puzzlepiece.extension.fill", tint: package.bundled ? .blue : .cyan)
                VStack(alignment: .leading, spacing: 5) {
                    Text(package.name).limaFont(.system(size: 15, weight: .semibold))
                    Text("\(package.source) · v\(package.version) · \(package.commandCount) commands")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(package.lifecycleState.rawValue) · \(package.commands.isEmpty ? "Contributions package" : (package.enabled ? "Commands enabled" : "Commands disabled"))")
                        .font(.caption)
                        .foregroundStyle(LimaTheme.textSecondary)
                    if !localOnly, let catalogEntry {
                        Text("Available v\(catalogEntry.version)")
                            .font(.caption2)
                            .foregroundStyle(LimaTheme.textTertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Configure " + package.name)
    }

    private func installedActions(_ package: InstalledPackage,
                                  catalogEntry: ExtensionStoreEntry?, updateEntry: ExtensionStoreEntry?) -> some View {
        HStack(spacing: 8) {
                Button("Configure") { selectedID = package.id }
                    .buttonStyle(.bordered)
                    .help("Inspect commands, preferences, and permissions")
                if !localOnly, let updateEntry {
                    Button("Update") { storeModel.install(updateEntry) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(storeModel.installingID != nil)
                }
                Menu {
                    if !package.commands.isEmpty {
                        Button(package.enabled ? "Disable Commands" : "Enable Commands") { toggle(package) }
                    }
                    Button("Configure Commands") { detailTab = .commands; selectedID = package.id }
                    Button("View Permissions") { detailTab = .permissions; selectedID = package.id }
                    Divider()
                    if package.bundled {
                        if ExtensionPackageManager.shared.isLogicallyRemoved(package.id) { Button("Restore Extension") { restoreBundled(package) } }
                        else { Button("Unload Extension", role: .destructive) { removeBundled(package) } }
                    } else {
                        if !localOnly, let catalogEntry {
                            Button("Reinstall") { storeModel.install(catalogEntry) }
                                .disabled(storeModel.installingID != nil)
                        }
                        Button("Uninstall", role: .destructive) { confirmUninstallID = package.id }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Actions for " + package.name)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func extensionDetail(_ package: InstalledPackage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Detail", selection: $detailTab) { ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu)
                Spacer()
                Button("Close") { selectedID = nil }.buttonStyle(.borderless)
            }
            if detailTab == .commands, package.commands.isEmpty {
                Text("No launcher commands. Check Tools, Skills & Agents for other contributions.")
                    .limaFont(.callout).foregroundStyle(LimaTheme.textSecondary)
            }
            if detailTab == .commands { ForEach(package.commands, id: \.settingsIdentifier) { command in
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(get: { CommandManager.shared.isEnabled(command.settingsIdentifier) }, set: { CommandManager.shared.setEnabled($0, for: command.settingsIdentifier) }))
                        .labelsHidden().toggleStyle(.checkbox)
                        .accessibilityLabel("Enable " + command.command.title)
                    Button { CommandManager.shared.toggleFavorite(command.settingsIdentifier) } label: {
                        Image(systemName: CommandManager.shared.isFavorite(command.settingsIdentifier) ? "star.fill" : "star")
                            .foregroundStyle(CommandManager.shared.isFavorite(command.settingsIdentifier) ? .yellow : .secondary)
                    }.buttonStyle(.borderless)
                        .accessibilityLabel("Favorite " + command.command.title)
                    Text(command.command.title).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Text(command.effectiveShortcutLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(LimaTheme.textSecondary)
                }
            }
            }
            if detailTab == .contributions { extensionContributions(package) }
            if detailTab == .preferences { extensionPreferences(package) }
            if detailTab == .permissions { extensionPermissions(package) }
            HStack {
                Button("Open Extensions Folder") { NSWorkspace.shared.open(ApplicationPaths.extensions) }
                Button("Reload") { reloadInstalled() }
            }
        }
        .padding(11)
    }

    private func extensionContributions(_ package: InstalledPackage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                Text("Tools").font(.headline)
                if package.tools.isEmpty {
                    Text("No tools declared.").font(.caption).foregroundStyle(LimaTheme.textSecondary)
                }
                ForEach(package.tools) { tool in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tool.title).font(.callout.weight(.medium))
                        Text(tool.description).font(.caption).foregroundStyle(LimaTheme.textSecondary)
                        Text("\(tool.isReadOnly ? "Read-only" : "Write-capable") · \(tool.execution.rawValue) · Adapter: \(tool.hostAdapterID ?? "None")")
                            .font(.caption2).foregroundStyle(LimaTheme.textTertiary)
                        if !tool.capabilities.isEmpty {
                            Text("Capabilities: \(tool.capabilities.map(\.rawValue).sorted().joined(separator: ", "))")
                                .font(.caption2).foregroundStyle(LimaTheme.textSecondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
            Group {
                Text("Skills").font(.headline)
                if package.skills.isEmpty {
                    Text("No skills declared.").font(.caption).foregroundStyle(LimaTheme.textSecondary)
                }
                ForEach(package.skills) { skill in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(skill.name).font(.callout.weight(.medium))
                        Text(skill.instructions).font(.caption).foregroundStyle(LimaTheme.textSecondary).textSelection(.enabled)
                        if !skill.preferredToolIDs.isEmpty {
                            Text("Preferred tools: \(skill.preferredToolIDs.joined(separator: ", "))")
                                .font(.caption2).foregroundStyle(LimaTheme.textTertiary)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
            Group {
                Text("Agents").font(.headline)
                if package.agents.isEmpty {
                    Text("No agents declared.").font(.caption).foregroundStyle(LimaTheme.textSecondary)
                }
                ForEach(package.agents) { agent in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(agent.name).font(.callout.weight(.medium))
                        Text(agent.instructions).font(.caption).foregroundStyle(LimaTheme.textSecondary).textSelection(.enabled)
                        let model = [agent.modelProviderID, agent.modelID].compactMap { $0 }.joined(separator: " · ")
                        if !model.isEmpty { Text("Model: \(model)").font(.caption2).foregroundStyle(LimaTheme.textTertiary) }
                        if !agent.skillIDs.isEmpty { Text("Skills: \(agent.skillIDs.joined(separator: ", "))").font(.caption2).foregroundStyle(LimaTheme.textTertiary) }
                        if !agent.toolIDs.isEmpty { Text("Tools: \(agent.toolIDs.joined(separator: ", "))").font(.caption2).foregroundStyle(LimaTheme.textTertiary) }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private func extensionPreferences(_ package: InstalledPackage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preferences").font(.headline)
            Text("Package preferences are stored by extension identifier and remain available after removal.").font(.caption).foregroundStyle(LimaTheme.textSecondary)
            Text("Settings key: extension.\(package.id)").font(.caption.monospaced()).foregroundStyle(LimaTheme.textSecondary)
            if !package.commands.isEmpty {
                Toggle("Enable commands", isOn: Binding(get: { package.enabled }, set: { _ in toggle(package) }))
            }
        }
    }

    private func extensionPermissions(_ package: InstalledPackage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Permissions").font(.headline)
            let commandCapabilities = package.commands.reduce(into: Set<ExtensionManifest.Capability>()) { $0.formUnion($1.capabilities) }
            let toolCapabilities = package.tools.reduce(into: Set<ExtensionManifest.Capability>()) { $0.formUnion($1.capabilities) }
            let capabilities = commandCapabilities.union(toolCapabilities).union(package.manifest?.capabilities ?? [])
            if capabilities.isEmpty { Text("No special capabilities requested.").font(.caption).foregroundStyle(LimaTheme.textSecondary) }
            ForEach(Array(capabilities).sorted { $0.rawValue < $1.rawValue }, id: \.rawValue) { capability in Label(capability.rawValue, systemImage: "checkmark.shield") .font(.caption) }
            Text(package.bundled ? "Bundled extensions are trusted by Lima." : "User extensions require approval when their manifest or capabilities change.").font(.caption).foregroundStyle(LimaTheme.textSecondary)
        }
    }

    private var availableView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !categories.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(categories, id: \.self) { value in
                            Button(value) { category = value }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(category == value ? SettingsStore.shared.accentTheme.readablePrimary : .secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    if available.isEmpty {
                        emptyState("No matching extensions", detail: storeModel.isLoading ? "Refreshing catalog…" : "Try another search or category.", symbol: "magnifyingglass")
                    } else {
                        ForEach(available) { entry in
                            availableCard(entry)
                        }
                    }
                    if let status { statusLine(status) }
                }
                .padding(12)
            }
        }
    }

    private func availableCard(_ entry: ExtensionStoreEntry) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: entry.icon)
                .font(.system(size: 18))
                .foregroundStyle(SettingsStore.shared.accentTheme.readablePrimary)
                .frame(width: 36, height: 36)
                .background(SettingsStore.shared.accentTheme.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.name).font(.callout.weight(.semibold))
                    Text("v\(entry.version)").font(.caption.monospacedDigit()).foregroundStyle(LimaTheme.textSecondary)
                }
                Text(entry.summary).font(.caption).foregroundStyle(LimaTheme.textSecondary)
                Text("\(entry.category) · \(entry.author)").font(.caption2).foregroundStyle(LimaTheme.textTertiary)
            }
            Spacer()
            Button(storeModel.isInstalled(entry) ? "Installed" : (storeModel.installingID == entry.id ? "Installing…" : "Install")) {
                storeModel.install(entry)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(storeModel.isInstalled(entry) || storeModel.installingID != nil)
        }
        .padding(11)
        .background(LimaTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(LimaTheme.borderSubtle, lineWidth: 1))
    }

    private var developerView: some View {
        Form {
            Section("Developer extensions") {
                Text("Install and inspect local extension packages. Developer tools are intentionally separate from the Store.")
                    .font(.caption).foregroundStyle(LimaTheme.textSecondary)
                Button("Open Extensions Folder") { NSWorkspace.shared.open(ApplicationPaths.extensions) }
                Button("Reload Installed Extensions") { reloadInstalled() }
            }
            Section("Package provenance") {
                ForEach(filteredInstalled) { package in
                    HStack {
                        Image(systemName: package.bundled ? "shippingbox.fill" : "person.crop.circle")
                        VStack(alignment: .leading) {
                            Text(package.name).font(.callout.weight(.medium))
                            Text("\(package.source) · \(package.id)").font(.caption).foregroundStyle(LimaTheme.textSecondary)
                        }
                        Spacer()
                        Text(package.bundled ? "Bundled" : "Local / installed").font(.caption).foregroundStyle(LimaTheme.textSecondary)
                    }
                }
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden).controlSize(.small)
    }

    private var updatesView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if updates.isEmpty {
                    emptyState("Everything is up to date", detail: "Refresh Available to check the catalog again.", symbol: "checkmark.circle")
                } else {
                    HStack {
                        Text("UPDATES AVAILABLE").font(.caption.weight(.bold)).tracking(1.1).foregroundStyle(LimaTheme.textSecondary)
                        Spacer()
                        Button("Update All") { updateAll() }.buttonStyle(.borderedProminent).controlSize(.small)
                    }
                    ForEach(updates, id: \.entry.id) { update in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(update.entry.name).font(.callout.weight(.semibold))
                                Text("\(update.installed.version) → \(update.entry.version)").font(.caption.monospacedDigit()).foregroundStyle(LimaTheme.textSecondary)
                            }
                            Spacer()
                            Button("Update") { storeModel.install(update.entry) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                        .padding(11)
                        .background(LimaTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                }
            }
            .padding(12)
        }
    }

    private func toggle(_ package: InstalledPackage) {
        for command in package.commands {
            CommandManager.shared.setEnabled(!package.enabled, for: command.settingsIdentifier)
        }
        reloadInstalled()
    }

    private func removeBundled(_ package: InstalledPackage) {
        ExtensionPackageManager.shared.logicallyRemoveBundled(id: package.id)
        reloadInstalled()
        status = "Unloaded \(package.id). The bundled package can be restored later."
    }

    private func restoreBundled(_ package: InstalledPackage) {
        ExtensionPackageManager.shared.restoreBundled(id: package.id)
        reloadInstalled()
        status = "Restored \(package.id)."
    }

    private func uninstall(id: String) {
        let url = ApplicationPaths.extensions.appendingPathComponent(id, isDirectory: true)
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            ExtensionApprovalStore.revoke(extensionID: id)
            reloadInstalled()
            status = "Removed \(id). Settings and shortcuts were preserved."
        } catch {
            status = "Could not remove \(id): \(error.localizedDescription)"
        }
    }

    private func updateAll() {
        storeModel.installAll(updates.map(\.entry))
    }

    @ViewBuilder
    private func emptyState(_ title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(LimaTheme.textSecondary)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(LimaTheme.textSecondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
    }

    private func statusLine(_ value: String) -> some View {
        Text(value).font(.caption).foregroundStyle(LimaTheme.textSecondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension LoadedExtensionCommand {
    @MainActor var effectiveShortcutLabel: String {
        SettingsStore.shared.effectiveShortcut(for: self).flatMap { ShortcutSpec(string: $0)?.displayString } ?? "—"
    }
    var settingsIdentifier: String { "\(extensionID).\(command.id)" }
}
