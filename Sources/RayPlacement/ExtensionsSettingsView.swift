import SwiftUI
import RayPlacementCore

@MainActor
struct ExtensionsSettingsView: View {
    @ObservedObject var viewModel: LauncherViewModel
    @ObservedObject var storeModel: ExtensionStoreModel
    let reloadExtensions: () -> Void

    @State private var tab: ExtensionTab = .installed
    @State private var query = ""
    @State private var category = "All"
    @State private var selectedID: String?
    @State private var confirmUninstallID: String?
    @State private var status: String?
    @State private var detailTab: DetailTab = .commands

    private enum DetailTab: String, CaseIterable, Identifiable { case commands = "Commands", preferences = "Preferences", permissions = "Permissions"; var id: String { rawValue } }

    private enum ExtensionTab: String, CaseIterable, Identifiable {
        case installed = "Installed"
        case available = "Store"
        case updates = "Updates"
        case developer = "Developer"
        var id: String { rawValue }
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
        let lifecycleState: ExtensionPackageState
    }

    private var installed: [InstalledPackage] {
        var packages: [String: InstalledPackage] = [:]

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
                lifecycleState: ExtensionPackageManager.shared.record(for: id)?.state ?? .installed
            )
        }

        // Also discover valid package manifests with zero commands. This keeps
        // package lifecycle management independent from launcher registration.
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
                      let manifest = try? decoder.decode(ExtensionManifest.self, from: data),
                      packages[manifest.id] == nil else { continue }
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
                    lifecycleState: ExtensionPackageManager.shared.record(for: manifest.id)?.state ?? (ExtensionPackageManager.shared.isLogicallyRemoved(manifest.id) ? .logicallyRemoved : .installed)
                )
            }
        }

        return packages.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
        storeModel.entries.compactMap { entry in
            guard let package = installed.first(where: { $0.id == entry.id }),
                  let current = SemanticVersion(package.version),
                  let latest = SemanticVersion(entry.version),
                  current < latest else { return nil }
            return (entry, package)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Extension area", selection: $tab) {
                    ForEach(ExtensionTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Spacer()
                if !updates.isEmpty {
                    Text("\(updates.count) update\(updates.count == 1 ? "" : "s")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
            .padding(12)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(LimaTheme.textSecondary)
                TextField("Search Extensions…", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(LimaTheme.textTertiary)
                }
                Button { reloadExtensions(); storeModel.load() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Reload installed extensions and refresh the catalog")
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(LimaTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

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
            storeModel.load()
            reloadExtensions()
        }
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

    private var installedView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if installed.isEmpty {
                    emptyState("No extensions installed", detail: "Install a package from Available or add a local extension folder.", symbol: "puzzlepiece.extension")
                } else {
                    ForEach(installed) { package in
                        installedCard(package)
                    }
                }
                if let status { statusLine(status) }
            }
            .padding(12)
        }
    }

    private func installedCard(_ package: InstalledPackage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(SettingsStore.shared.accentTheme.readableSecondary)
                    .frame(width: 34, height: 34)
                    .background(SettingsStore.shared.accentTheme.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(package.name).font(.callout.weight(.semibold))
                    Text("\(package.source) · \(package.lifecycleState.rawValue) · v\(package.version) · \(package.commandCount) command\(package.commandCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(LimaTheme.textSecondary)
                }
                Spacer()
                Text(package.enabled ? "Enabled" : "Disabled")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(package.enabled ? .green : .secondary)
                Menu {
                    Button(package.enabled ? "Disable" : "Enable") { toggle(package) }
                    Button("Configure Commands") { selectedID = package.id }
                    Button("View Details") { selectedID = package.id }
                    Divider()
                    if package.bundled {
                        if ExtensionPackageManager.shared.isLogicallyRemoved(package.id) { Button("Restore Extension") { restoreBundled(package) } }
                        else { Button("Unload Extension", role: .destructive) { removeBundled(package) } }
                    } else {
                        Button("Uninstall", role: .destructive) { confirmUninstallID = package.id }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
            }
            .padding(11)

            if selectedID == package.id {
                Divider()
                extensionDetail(package)
            }
        }
        .background(LimaTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(LimaTheme.borderSubtle, lineWidth: 1))
    }

    private func extensionDetail(_ package: InstalledPackage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Extension detail", selection: $detailTab) { ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                Spacer()
                Button("Close") { selectedID = nil }.buttonStyle(.borderless)
            }
            if detailTab == .commands { ForEach(package.commands, id: \.settingsIdentifier) { command in
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(get: { CommandManager.shared.isEnabled(command.settingsIdentifier) }, set: { CommandManager.shared.setEnabled($0, for: command.settingsIdentifier) }))
                        .labelsHidden().toggleStyle(.checkbox)
                    Button { CommandManager.shared.toggleFavorite(command.settingsIdentifier) } label: {
                        Image(systemName: CommandManager.shared.isFavorite(command.settingsIdentifier) ? "star.fill" : "star")
                            .foregroundStyle(CommandManager.shared.isFavorite(command.settingsIdentifier) ? .yellow : .secondary)
                    }.buttonStyle(.borderless)
                    Text(command.command.title).lineLimit(1)
                    Spacer()
                    Text(command.effectiveShortcutLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(LimaTheme.textSecondary)
                }
            }
            }
            if detailTab == .preferences { extensionPreferences(package) }
            if detailTab == .permissions { extensionPermissions(package) }
            HStack {
                Button("Open Extensions Folder") { NSWorkspace.shared.open(ApplicationPaths.extensions) }
                Button("Reload") { reloadExtensions() }
            }
        }
        .padding(11)
    }

    private func extensionPreferences(_ package: InstalledPackage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preferences").font(.headline)
            Text("Package preferences are stored by extension identifier and remain available after removal.").font(.caption).foregroundStyle(LimaTheme.textSecondary)
            Text("Settings key: extension.\(package.id)").font(.caption.monospaced()).foregroundStyle(LimaTheme.textSecondary)
            Toggle("Enabled", isOn: Binding(get: { package.enabled }, set: { _ in toggle(package) }))
        }
    }

    private func extensionPermissions(_ package: InstalledPackage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Permissions").font(.headline)
            let capabilities = package.commands.compactMap { Array($0.capabilities) }.reduce(into: Set<ExtensionManifest.Capability>()) { $0.formUnion($1) }
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
                Button("Reload Installed Extensions") { reloadExtensions() }
            }
            Section("Package provenance") {
                ForEach(installed) { package in
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
        reloadExtensions()
    }

    private func removeBundled(_ package: InstalledPackage) {
        ExtensionPackageManager.shared.logicallyRemoveBundled(id: package.id)
        reloadExtensions()
        status = "Unloaded \(package.id). The bundled package can be restored later."
    }

    private func restoreBundled(_ package: InstalledPackage) {
        ExtensionPackageManager.shared.restoreBundled(id: package.id)
        reloadExtensions()
        status = "Restored \(package.id)."
    }

    private func uninstall(id: String) {
        let url = ApplicationPaths.extensions.appendingPathComponent(id, isDirectory: true)
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            ExtensionApprovalStore.revoke(extensionID: id)
            reloadExtensions()
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
