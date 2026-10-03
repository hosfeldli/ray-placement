import SwiftUI
import RayPlacementCore

enum CommandCenterFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case builtIn = "Built-in"
    case extensions = "Extensions"
    case tools = "Tools"
    case skills = "Skills"
    case agents = "Agents"
    case disabled = "Disabled"
    case conflicts = "Conflicts"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .builtIn: "shippingbox"
        case .extensions: "puzzlepiece.extension"
        case .tools: "wrench.and.screwdriver"
        case .skills: "sparkles"
        case .agents: "person.crop.square"
        case .disabled: "pause.circle"
        case .conflicts: "exclamationmark.triangle"
        }
    }
}

enum CommandCenterEntryKind: String {
    case command
    case extensionCommand
    case extensionPackage
    case tool
    case skill
    case agent
}

struct CommandCenterEntry: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let kind: CommandCenterEntryKind
    let source: String
    let isEnabled: Bool
    let isFavorite: Bool
    let shortcut: String
    let isConflict: Bool
    let capabilities: [String]
    let presentation: String?
    let version: String?
    let detail: String
    let risk: String?
    let availableToAI: Bool?
    let schema: String?
    let provider: String?
    let model: String?
    let skills: [String]
    let tools: [String]
    let reasoning: String?

    var searchableText: String {
        ([title, subtitle, source, kind.rawValue, detail, risk ?? "", provider ?? "", model ?? ""]
            + capabilities + skills + tools)
            .joined(separator: " ")
    }
}

enum CommandCenterCatalog {
    static func shortcutAssignmentID(for commandID: String) -> String {
        switch commandID {
        case "builtin.note-dictation": return "builtin.dictation"
        case "builtin.add-selection-to-shelf": return "builtin.context-shelf.capture-selection"
        default: return commandID
        }
    }

    static func nativeToolEntries(
        definitions: [LimaAIToolDefinition],
        enabledIDs: Set<String>,
        actionToolIDs: Set<String> = []
    ) -> [CommandCenterEntry] {
        definitions.filter { $0.extensionBinding == nil }.map { tool in
            let eligible = tool.risk == .read || actionToolIDs.contains(tool.id)
            let schema = (try? JSONSerialization.data(withJSONObject: tool.parameters, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return CommandCenterEntry(
                id: tool.id, title: tool.displayName, subtitle: tool.userSummary,
                kind: .tool, source: "Built-in",
                isEnabled: eligible && enabledIDs.contains(tool.id),
                isFavorite: false, shortcut: "", isConflict: false,
                capabilities: [], presentation: nil, version: nil,
                detail: tool.description, risk: eligible ? tool.risk.title : "Not eligible",
                availableToAI: eligible, schema: schema, provider: nil, model: nil,
                skills: [], tools: [], reasoning: nil
            )
        }
    }

    static func visibleEntries(
        _ entries: [CommandCenterEntry],
        filter: CommandCenterFilter,
        query: String
    ) -> [CommandCenterEntry] {
        let terms = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        return entries.filter { entry in
            let matchesFilter: Bool
            switch filter {
            case .all:
                matchesFilter = true
            case .builtIn:
                matchesFilter = entry.source == "Built-in"
            case .extensions:
                matchesFilter = entry.kind == .extensionPackage
                    || entry.kind == .extensionCommand
                    || (entry.kind == .tool || entry.kind == .skill || entry.kind == .agent) && entry.source != "Built-in"
            case .tools:
                matchesFilter = entry.kind == .tool
            case .skills:
                matchesFilter = entry.kind == .skill
            case .agents:
                matchesFilter = entry.kind == .agent
            case .disabled:
                matchesFilter = !entry.isEnabled
            case .conflicts:
                matchesFilter = entry.isConflict
            }
            return matchesFilter && terms.allSatisfy {
                entry.searchableText.localizedCaseInsensitiveContains($0)
            }
        }
        .sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
}

@MainActor
struct CommandCenterView: View {
    @ObservedObject var viewModel: LauncherViewModel
    @ObservedObject var settings: SettingsStore
    @ObservedObject var commandManager: CommandManager
    @ObservedObject var extensionStoreModel: ExtensionStoreModel
    let reloadExtensions: () -> Void
    let makeShortcutBinding: (String) -> Binding<String>

    @ObservedObject private var nativeToolStore = LimaAIToolStore.shared
    @State private var shortcutLookup = ""
    @State private var selectedArea: Area = .catalog
    @State private var selectedFilter: CommandCenterFilter = .all
    @State private var query = ""
    @State private var selectedID: String?

    private enum Area: String, CaseIterable, Identifiable {
        case catalog = "Commands"
        case extensions = "Extensions"
        var id: String { rawValue }
    }

    private var entries: [CommandCenterEntry] {
        let extensionCommands = viewModel.extensionCommands
        let byCommandID = Dictionary(
            uniqueKeysWithValues: extensionCommands.map {
                ("extension.\($0.extensionID).\($0.command.id)", $0)
            }
        )
        let conflictIDs = Set(commandManager.shortcutRegistry.conflicts.flatMap { $0.map(\.id) })
        let commandEntries = viewModel.commandDescriptors.map { descriptor -> CommandCenterEntry in
            let loaded = byCommandID[descriptor.id]
            let source = loaded?.provenanceLabel ?? "Built-in"
            let shortcut = loaded.flatMap { settings.effectiveShortcut(for: $0) } ?? builtinShortcut(for: descriptor.id)
            return CommandCenterEntry(
                id: descriptor.id,
                title: descriptor.title,
                subtitle: descriptor.subtitle,
                kind: loaded == nil ? .command : .extensionCommand,
                source: source,
                isEnabled: commandManager.isEnabled(descriptor.id),
                isFavorite: commandManager.isFavorite(descriptor.id),
                shortcut: shortcut,
                isConflict: conflictIDs.contains(CommandCenterCatalog.shortcutAssignmentID(for: descriptor.id)),
                capabilities: loaded.map { $0.capabilities.map(\.rawValue).sorted() } ?? [],
                presentation: loaded?.effectivePresentation.rawValue,
                version: loaded?.version,
                detail: loaded.map { "Extension \($0.extensionName) · \($0.extensionID)" } ?? "Built-in Lima command",
                risk: nil,
                availableToAI: nil,
                schema: nil,
                provider: nil,
                model: nil,
                skills: [],
                tools: [],
                reasoning: nil
            )
        }

        let contributionCatalog = ExtensionLoader().contributionCatalog()
        let approvedToolIDs = Set(
            ExtensionToolHostAdapterRegistry.approvedBindings().map {
                "extension:\($0.extensionID):\($0.tool.id)"
            }
        )
        let contributionEntries = contributionCatalog.flatMap { package -> [CommandCenterEntry] in
            let packageCommands = extensionCommands.filter { $0.extensionID == package.extensionID }
            let enabled = packageCommands.isEmpty || packageCommands.contains {
                commandManager.isEnabled("extension.\($0.extensionID).\($0.command.id)")
            }
            let source = packageCommands.first?.provenanceLabel ?? "Approved extension"
            let packageEntry = CommandCenterEntry(
                id: "package.\(package.extensionID)",
                title: package.extensionName,
                subtitle: "\(package.tools.count) tools · \(package.skills.count) skills · \(package.agents.count) agents",
                kind: .extensionPackage,
                source: source,
                isEnabled: enabled,
                isFavorite: false,
                shortcut: "",
                isConflict: false,
                capabilities: package.capabilities.map(\.rawValue).sorted(),
                presentation: nil,
                version: packageCommands.first?.version,
                detail: "Extension ID: \(package.extensionID)",
                risk: nil,
                availableToAI: nil,
                schema: nil,
                provider: nil,
                model: nil,
                skills: [],
                tools: [],
                reasoning: nil
            )
            let tools = package.tools.map { tool in
                let schema = (try? JSONEncoder().encode(tool.inputSchema))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                return CommandCenterEntry(
                    id: "extension:\(package.extensionID):\(tool.id)",
                    title: tool.title,
                    subtitle: tool.description,
                    kind: .tool,
                    source: package.extensionName,
                    isEnabled: approvedToolIDs.contains("extension:\(package.extensionID):\(tool.id)")
                        && nativeToolStore.enabledToolIDs.contains("extension:\(package.extensionID):\(tool.id)"),
                    isFavorite: false,
                    shortcut: "",
                    isConflict: false,
                    capabilities: tool.capabilities.map(\.rawValue).sorted(),
                    presentation: nil,
                    version: nil,
                    detail: "Adapter: \(tool.hostAdapterID ?? "None")",
                    risk: tool.isReadOnly ? "Read-only" : "Write-capable",
                    availableToAI: approvedToolIDs.contains("extension:\(package.extensionID):\(tool.id)"),
                    schema: schema,
                    provider: nil,
                    model: nil,
                    skills: [],
                    tools: [],
                    reasoning: nil
                )
            }
            return [packageEntry] + tools
        }

        let skillEntries = AIChatConfigurationCatalog.skills.map { skill in
            CommandCenterEntry(
                id: skill.id,
                title: skill.name,
                subtitle: skill.preferredToolIDs.isEmpty ? "AI context configuration" : "Preferred tools: \(skill.preferredToolIDs.joined(separator: ", "))",
                kind: .skill,
                source: skill.id.hasPrefix("extension:") ? "Extension" : "Built-in",
                isEnabled: true,
                isFavorite: false,
                shortcut: "",
                isConflict: false,
                capabilities: [],
                presentation: nil,
                version: nil,
                detail: skill.instructions,
                risk: nil,
                availableToAI: true,
                schema: nil,
                provider: skill.recommendedProviderID,
                model: skill.recommendedModelID,
                skills: [],
                tools: skill.preferredToolIDs,
                reasoning: nil
            )
        }
        let agentEntries = AIChatConfigurationCatalog.agents.map { agent in
            CommandCenterEntry(
                id: agent.id,
                title: agent.name,
                subtitle: [agent.providerID, agent.modelID].compactMap { $0 }.joined(separator: " · ").ifEmpty("AI agent configuration"),
                kind: .agent,
                source: agent.id.hasPrefix("extension:") ? "Extension" : "Built-in",
                isEnabled: true,
                isFavorite: false,
                shortcut: "",
                isConflict: false,
                capabilities: [],
                presentation: nil,
                version: nil,
                detail: agent.instructions,
                risk: nil,
                availableToAI: true,
                schema: nil,
                provider: agent.providerID,
                model: agent.modelID,
                skills: agent.skillIDs,
                tools: agent.toolIDs,
                reasoning: agent.reasoningEffort?.rawValue
            )
        }

        var packagesByID: [String: CommandCenterEntry] = [:]
        for group in Dictionary(grouping: extensionCommands, by: \.extensionID).values {
            guard let first = group.first else { continue }
            let commands = group.map { $0.command.title }.sorted()
            packagesByID[first.extensionID] = CommandCenterEntry(
                id: "package.\(first.extensionID)",
                title: first.extensionName,
                subtitle: "\(commands.count) command\(commands.count == 1 ? "" : "s")",
                kind: .extensionPackage,
                source: first.provenanceLabel,
                isEnabled: group.contains { commandManager.isEnabled("extension.\($0.extensionID).\($0.command.id)") },
                isFavorite: false,
                shortcut: "",
                isConflict: false,
                capabilities: Array(Set(group.flatMap { $0.capabilities.map(\.rawValue) })).sorted(),
                presentation: nil,
                version: first.version,
                detail: commands.joined(separator: "\n"),
                risk: nil,
                availableToAI: nil,
                schema: nil,
                provider: nil,
                model: nil,
                skills: [],
                tools: [],
                reasoning: nil
            )
        }
        let packageEntries = packagesByID.values.filter { existing in
            !contributionEntries.contains(where: { $0.id == existing.id })
        }

        let availableToolDefinitions = LimaAIToolRegistry.availableDefinitions
        let policyEnabledActionToolIDs = Set(availableToolDefinitions
            .filter { $0.actionCategory != nil }
            .map(\.id))
        let nativeTools = CommandCenterCatalog.nativeToolEntries(
            definitions: availableToolDefinitions,
            enabledIDs: nativeToolStore.enabledToolIDs,
            actionToolIDs: policyEnabledActionToolIDs
        )
        return commandEntries + contributionEntries + packageEntries + nativeTools + skillEntries + agentEntries
    }

    private var visibleEntries: [CommandCenterEntry] {
        CommandCenterCatalog.visibleEntries(entries, filter: selectedFilter, query: query)
    }

    private var selectedEntry: CommandCenterEntry? {
        if let selectedID, let found = visibleEntries.first(where: { $0.id == selectedID }) { return found }
        return visibleEntries.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Command Center area", selection: $selectedArea) {
                    ForEach(Area.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
                Spacer()
                if selectedArea == .extensions && extensionStoreModel.entries.count > 0 {
                    Text("\(extensionStoreModel.entries.count) store items")
                        .font(.caption)
                        .foregroundStyle(LimaTheme.textSecondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider()
            if selectedArea == .extensions {
                ExtensionsSettingsView(
                    viewModel: viewModel,
                    storeModel: extensionStoreModel,
                    reloadExtensions: reloadExtensions
                )
            } else {
                catalogContent
            }
        }
        .onAppear { commandManager.validateShortcuts(viewModel.extensionCommands) }
        .onChange(of: selectedFilter) { _ in keepSelectionVisible() }
        .onChange(of: query) { _ in keepSelectionVisible() }
        .onChange(of: viewModel.extensionCommands.count) { _ in
            commandManager.validateShortcuts(viewModel.extensionCommands)
        }
    }

    private var catalogContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(LimaTheme.textSecondary)
                TextField("Search commands, tools, skills, and agents", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(LimaTheme.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 31)
            .background(LimaTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .padding(10)

            DisclosureGroup("Look up a shortcut") {
                HStack {
                    ShortcutRecorder(shortcut: $shortcutLookup, label: "Press shortcut…")
                        .frame(width: 150, height: 28)
                    let owners = commandManager.shortcutRegistry.owners(of: shortcutLookup)
                    Text(owners.isEmpty ? "No assignment" : owners.map(\.title).joined(separator: ", "))
                        .font(.caption).foregroundStyle(LimaTheme.textSecondary)
                    Spacer(minLength: 0)
                }
                .padding(.top, 5)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)

            HStack(spacing: 0) {
                filterSidebar
                    .frame(width: 126)
                Divider()
                itemList
                    .frame(minWidth: 150, idealWidth: 190, maxWidth: 220)
                Divider()
                inspector
                    .frame(minWidth: 210, maxWidth: .infinity)
            }
        }
    }

    private var filterSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(CommandCenterFilter.allCases) { filter in
                    Button {
                        selectedFilter = filter
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: filter.symbol)
                                .frame(width: 16)
                            Text(filter.rawValue)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text("\(CommandCenterCatalog.visibleEntries(entries, filter: filter, query: "").count)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(LimaTheme.textTertiary)
                        }
                        .font(.system(size: 11.5, weight: selectedFilter == filter ? .semibold : .regular))
                        .foregroundStyle(selectedFilter == filter ? settings.accentTheme.readablePrimary : LimaTheme.textPrimary)
                        .padding(.horizontal, 8)
                        .frame(height: 29)
                        .background(selectedFilter == filter ? settings.accentTheme.primary.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(7)
        }
    }

    private var itemList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                if visibleEntries.isEmpty {
                    emptyState("No matching items", symbol: "magnifyingglass", detail: "Try another filter or search.")
                        .padding(.top, 24)
                } else {
                    ForEach(visibleEntries) { entry in
                        Button {
                            selectedID = entry.id
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: symbol(for: entry.kind))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(entry.isConflict ? .orange : settings.accentTheme.readablePrimary)
                                    .frame(width: 15, height: 17)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title)
                                        .font(.system(size: 11.5, weight: selectedEntry?.id == entry.id ? .semibold : .medium))
                                        .lineLimit(1)
                                    Text(entry.subtitle)
                                        .font(.system(size: 10))
                                        .foregroundStyle(LimaTheme.textSecondary)
                                        .lineLimit(2)
                                }
                                Spacer(minLength: 0)
                                if !entry.isEnabled {
                                    Image(systemName: "pause.fill")
                                        .font(.system(size: 8))
                                        .foregroundStyle(LimaTheme.textTertiary)
                                }
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(selectedEntry?.id == entry.id ? settings.accentTheme.primary.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(6)
        }
        .onChange(of: selectedEntry?.id) { value in selectedID = value }
    }

    private var inspector: some View {
        Group {
            if let entry = selectedEntry {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title)
                                .font(.headline)
                                .textSelection(.enabled)
                            Text(entry.kind.label + " · " + entry.source)
                                .font(.caption)
                                .foregroundStyle(LimaTheme.textSecondary)
                        }
                        Divider()
                        inspectorContent(entry)
                    }
                    .padding(12)
                }
            } else {
                emptyState("Select an item", symbol: "sidebar.right", detail: "Choose a command or contribution to inspect it.")
            }
        }
        .background(LimaTheme.surfaceSecondary.opacity(0.4))
    }

    @ViewBuilder
    private func inspectorContent(_ entry: CommandCenterEntry) -> some View {
        switch entry.kind {
        case .command, .extensionCommand:
            Toggle("Enabled", isOn: Binding(
                get: { commandManager.isEnabled(entry.id) },
                set: { commandManager.setEnabled($0, for: entry.id) }
            ))
            Toggle("Favorite", isOn: Binding(
                get: { commandManager.isFavorite(entry.id) },
                set: { _ in commandManager.toggleFavorite(entry.id) }
            ))
            if canEditShortcut(for: entry) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Shortcut").font(.caption.weight(.semibold))
                    ShortcutRecorder(
                        shortcut: makeShortcutBinding(CommandCenterCatalog.shortcutAssignmentID(for: entry.id)),
                        label: "Record shortcut"
                    )
                    .frame(maxWidth: .infinity, minHeight: 28)
                }
            } else {
                LabeledContent("Shortcut", value: entry.shortcut.isEmpty ? "—" : entry.shortcut)
            }
            if let presentation = entry.presentation {
                LabeledContent("Presentation", value: presentation.capitalized)
            }
            if !entry.capabilities.isEmpty {
                detailSection("Capabilities", values: entry.capabilities)
            } else {
                LabeledContent("Capabilities", value: "None")
            }
            if let version = entry.version { LabeledContent("Version", value: version) }
            if !entry.detail.isEmpty { Text(entry.detail).font(.caption).foregroundStyle(LimaTheme.textSecondary).textSelection(.enabled) }
        case .extensionPackage:
            if let version = entry.version { LabeledContent("Version", value: version) }
            LabeledContent("Source", value: entry.source)
            LabeledContent("Enabled", value: entry.isEnabled ? "Yes" : "No")
            if !entry.capabilities.isEmpty { detailSection("Capabilities", values: entry.capabilities) }
            if !entry.detail.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Commands").font(.caption.weight(.semibold))
                    Text(entry.detail).font(.caption).foregroundStyle(LimaTheme.textSecondary)
                }
            }
            Button("Manage extensions") { selectedArea = .extensions }
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .tool:
            LabeledContent("Risk", value: entry.risk ?? "Unknown")
            if let tool = LimaAIToolRegistry.definition(for: entry.id),
               tool.risk == .read || (tool.actionCategory != nil && AIComputerActionPolicy.shared.allows(tool)) {
                Toggle("Enabled for AI", isOn: Binding(
                    get: { nativeToolStore.isEnabled(tool) },
                    set: { enabled in
                        // Recheck eligibility at interaction time; never revive a revoked extension.
                        guard let current = LimaAIToolRegistry.definition(for: entry.id),
                              current.risk == .read || (current.actionCategory != nil && AIComputerActionPolicy.shared.allows(current)) else { return }
                        nativeToolStore.setEnabled(current, enabled: enabled)
                    }
                ))
                Text("Applies to future AI requests. Browser actions still require site grants and their selected approval policy.")
                    .font(.caption).foregroundStyle(LimaTheme.textSecondary)
            } else {
                LabeledContent("Enabled for AI", value: "Not eligible")
            }
            if !entry.capabilities.isEmpty { detailSection("Required capabilities", values: entry.capabilities) }
            LabeledContent("Source", value: entry.source)
            if let schema = entry.schema {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Input schema").font(.caption.weight(.semibold))
                    Text(schema.prefix(4_000)).font(.system(size: 9, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text(entry.detail).font(.caption).foregroundStyle(LimaTheme.textSecondary)
        case .skill:
            if !entry.tools.isEmpty { detailSection("Preferred tools", values: entry.tools) }
            if let provider = entry.provider { LabeledContent("Recommended provider", value: provider) }
            if let model = entry.model { LabeledContent("Recommended model", value: model) }
            detailSection("Instructions", values: [entry.detail])
        case .agent:
            if let provider = entry.provider { LabeledContent("Provider", value: provider) }
            if let model = entry.model { LabeledContent("Model", value: model) }
            if let reasoning = entry.reasoning { LabeledContent("Reasoning", value: reasoning) }
            if !entry.skills.isEmpty { detailSection("Skills", values: entry.skills) }
            if !entry.tools.isEmpty { detailSection("Allowed tools", values: entry.tools) }
            detailSection("Instructions", values: [entry.detail])
        }
    }

    private func detailSection(_ title: String, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold))
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Text(value)
                    .font(title == "Instructions" ? .caption : .caption2)
                    .foregroundStyle(LimaTheme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func builtinShortcut(for id: String) -> String {
        let value: String
        switch CommandCenterCatalog.shortcutAssignmentID(for: id) {
        case "builtin.notes": value = settings.notesShortcut
        case "builtin.quick-note": value = settings.quickNoteShortcut
        case "builtin.dictation": value = settings.dictationShortcut
        case "builtin.terminal": value = settings.terminalShortcut
        case "builtin.context-shelf.capture-selection": value = settings.contextShelfCaptureShortcut
        default: return ""
        }
        return ShortcutSpec(string: value)?.displayString ?? value
    }

    private func canEditShortcut(for entry: CommandCenterEntry) -> Bool {
        if entry.kind == .extensionCommand { return true }
        return [
            "builtin.notes",
            "builtin.quick-note",
            "builtin.note-dictation",
            "builtin.terminal",
            "builtin.add-selection-to-shelf"
        ].contains(entry.id)
    }

    private func keepSelectionVisible() {
        if !visibleEntries.contains(where: { $0.id == selectedID }) {
            selectedID = visibleEntries.first?.id
        }
    }

    private func emptyState(_ title: String, symbol: String, detail: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(LimaTheme.textTertiary)
            Text(title).font(.callout.weight(.medium))
            Text(detail).font(.caption).foregroundStyle(LimaTheme.textSecondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
    }

    private func symbol(for kind: CommandCenterEntryKind) -> String {
        switch kind {
        case .command: "command"
        case .extensionCommand: "puzzlepiece.extension"
        case .extensionPackage: "shippingbox"
        case .tool: "wrench.and.screwdriver"
        case .skill: "sparkles"
        case .agent: "person.crop.square"
        }
    }
}

private extension CommandCenterEntryKind {
    var label: String {
        switch self {
        case .command: "Command"
        case .extensionCommand: "Extension command"
        case .extensionPackage: "Extension"
        case .tool: "Tool"
        case .skill: "Skill"
        case .agent: "Agent"
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
