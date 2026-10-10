import SwiftUI

enum WorkspaceRailSection: String, Codable, CaseIterable, Identifiable {
    case workspace, tools, hidden
    var id: String { rawValue }
    var title: String {
        switch self {
        case .workspace: "Workspace"
        case .tools: "Tools"
        case .hidden: "Hidden"
        }
    }
}

enum WorkspaceRailPresentation: String, Codable, CaseIterable, Identifiable {
    case adaptive, icons, iconsAndLabels
    var id: String { rawValue }
    var title: String {
        switch self {
        case .adaptive: "Adaptive"
        case .icons: "Icons"
        case .iconsAndLabels: "Icons + Labels"
        }
    }
}

enum WorkspaceRailWidth: String, Codable, CaseIterable, Identifiable {
    case compact, standard, wide
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum HomeWorkspaceSection: String, Codable, CaseIterable, Identifiable {
    case continueWork = "continue"
    case recent
    case quickActions
    case pinned
    case activeTasks

    var id: String { rawValue }
    var title: String {
        switch self {
        case .continueWork: "Continue"
        case .recent: "Recent"
        case .quickActions: "Quick Actions"
        case .pinned: "Pinned Notes"
        case .activeTasks: "Active Tasks"
        }
    }
}

/// Home preferences belong to a Workspace layout, not a separate widget system.
struct HomeWorkspaceConfiguration: Codable, Equatable {
    var sectionOrder: [HomeWorkspaceSection]
    var hiddenSections: [HomeWorkspaceSection]
    var showsRecentNotes: Bool
    var showsRecentAI: Bool

    init(
        sectionOrder: [HomeWorkspaceSection] = HomeWorkspaceSection.allCases,
        hiddenSections: [HomeWorkspaceSection] = [.activeTasks],
        showsRecentNotes: Bool = true,
        showsRecentAI: Bool = true
    ) {
        var seen = Set<HomeWorkspaceSection>()
        self.sectionOrder = sectionOrder.filter { seen.insert($0).inserted }
        self.sectionOrder.append(contentsOf: HomeWorkspaceSection.allCases.filter { seen.insert($0).inserted })
        seen.removeAll()
        self.hiddenSections = hiddenSections.filter { seen.insert($0).inserted }
        self.showsRecentNotes = showsRecentNotes
        self.showsRecentAI = showsRecentAI
    }

    static let defaultConfiguration = HomeWorkspaceConfiguration()
    var normalized: HomeWorkspaceConfiguration {
        HomeWorkspaceConfiguration(
            sectionOrder: sectionOrder,
            hiddenSections: hiddenSections,
            showsRecentNotes: showsRecentNotes,
            showsRecentAI: showsRecentAI
        )
    }
    func isVisible(_ section: HomeWorkspaceSection) -> Bool { !hiddenSections.contains(section) }
    mutating func setVisible(_ visible: Bool, for section: HomeWorkspaceSection) {
        hiddenSections.removeAll { $0 == section }
        if !visible { hiddenSections.append(section) }
    }
    mutating func move(_ section: HomeWorkspaceSection, by offset: Int) {
        guard let index = sectionOrder.firstIndex(of: section) else { return }
        let destination = min(max(index + offset, 0), sectionOrder.count - 1)
        guard destination != index else { return }
        sectionOrder.insert(sectionOrder.remove(at: index), at: destination)
    }
}

struct WorkspaceSectionConfiguration: Codable, Equatable, Identifiable {
    static let workspaceID = UUID(uuidString: "4B8DA4B7-EDCE-4873-926B-F56696634A3B")!
    static let toolsID = UUID(uuidString: "20BD2EE5-F89D-4F34-9362-7FCA379F11D5")!
    var id: UUID
    var name: String
    var modules: [LimaWorkspaceModule]

    init(id: UUID = UUID(), name: String, modules: [LimaWorkspaceModule] = []) {
        self.id = id
        self.name = name
        self.modules = modules
    }
}

/// Ordered sections own rail placement. Unplaced modules remain available in Search.
struct WorkspaceConfiguration: Codable, Equatable {
    var sections: [WorkspaceSectionConfiguration]
    var startupModule: LimaWorkspaceModule
    var railPresentation: WorkspaceRailPresentation
    var railWidth: WorkspaceRailWidth
    var showsSectionNames: Bool
    var showsKeyboardShortcuts: Bool
    /// Overrides for the legacy ⌥⌘ shortcuts; absent keys keep their stable defaults.
    var shortcutOverrides: [String: String]
    var home: HomeWorkspaceConfiguration

    init(
        workspaceModules: [LimaWorkspaceModule],
        toolModules: [LimaWorkspaceModule],
        startupModule: LimaWorkspaceModule = .home,
        railPresentation: WorkspaceRailPresentation = .adaptive,
        railWidth: WorkspaceRailWidth = .standard,
        showsSectionNames: Bool = true,
        showsKeyboardShortcuts: Bool = false,
        shortcutOverrides: [String: String] = [:],
        home: HomeWorkspaceConfiguration = .defaultConfiguration
    ) {
        self.init(
            sections: [
                WorkspaceSectionConfiguration(id: WorkspaceSectionConfiguration.workspaceID, name: "Workspace", modules: workspaceModules),
                WorkspaceSectionConfiguration(id: WorkspaceSectionConfiguration.toolsID, name: "Tools", modules: toolModules)
            ],
            startupModule: startupModule,
            railPresentation: railPresentation,
            railWidth: railWidth,
            showsSectionNames: showsSectionNames,
            showsKeyboardShortcuts: showsKeyboardShortcuts,
            shortcutOverrides: shortcutOverrides,
            home: home
        )
    }

    init(
        sections: [WorkspaceSectionConfiguration],
        startupModule: LimaWorkspaceModule = .home,
        railPresentation: WorkspaceRailPresentation = .adaptive,
        railWidth: WorkspaceRailWidth = .standard,
        showsSectionNames: Bool = true,
        showsKeyboardShortcuts: Bool = false,
        shortcutOverrides: [String: String] = [:],
        home: HomeWorkspaceConfiguration = .defaultConfiguration
    ) {
        self.sections = Self.normalizedSections(sections)
        self.startupModule = startupModule
        self.railPresentation = railPresentation
        self.railWidth = railWidth
        self.showsSectionNames = showsSectionNames
        self.showsKeyboardShortcuts = showsKeyboardShortcuts
        self.shortcutOverrides = Self.normalizedShortcutOverrides(shortcutOverrides)
        self.home = home.normalized
        if !visibleModules.contains(startupModule) {
            self.startupModule = visibleModules.first ?? .home
        }
    }

    static let defaultConfiguration = WorkspaceConfiguration(
        workspaceModules: LimaWorkspaceModule.workspaceDestinations,
        toolModules: LimaWorkspaceModule.toolDestinations
    )

    var workspaceModules: [LimaWorkspaceModule] {
        sections.first(where: { $0.id == WorkspaceSectionConfiguration.workspaceID })?.modules ?? []
    }
    var toolModules: [LimaWorkspaceModule] {
        sections.first(where: { $0.id == WorkspaceSectionConfiguration.toolsID })?.modules ?? []
    }
    var visibleModules: [LimaWorkspaceModule] { sections.flatMap(\.modules) }
    var hiddenModules: [LimaWorkspaceModule] {
        let visible = Set(visibleModules)
        return LimaWorkspaceModule.allCases.filter { !visible.contains($0) }
    }
    var normalized: WorkspaceConfiguration {
        WorkspaceConfiguration(
            sections: sections, startupModule: startupModule,
            railPresentation: railPresentation, railWidth: railWidth,
            showsSectionNames: showsSectionNames, showsKeyboardShortcuts: showsKeyboardShortcuts,
            shortcutOverrides: shortcutOverrides, home: home
        )
    }

    static let allowedShortcutKeys = (1...9).map(String.init) + "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map { String($0) }

    func shortcutKey(for module: LimaWorkspaceModule) -> String {
        shortcutOverrides[module.rawValue] ?? module.shortcutNumber
    }
    func shortcutAlias(for module: LimaWorkspaceModule) -> String? {
        guard let alias = module.shortcutAlias,
              shortcutKey(for: module) != alias,
              !LimaWorkspaceModule.allCases.contains(where: { $0 != module && shortcutKey(for: $0) == alias })
        else { return nil }
        return alias
    }
    mutating func setShortcutKey(_ key: String, for module: LimaWorkspaceModule) {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard Self.allowedShortcutKeys.contains(clean) else { return }
        let previous = shortcutKey(for: module)
        if let owner = LimaWorkspaceModule.allCases.first(where: { $0 != module && shortcutKey(for: $0) == clean }) {
            shortcutOverrides[owner.rawValue] = previous
        }
        shortcutOverrides[module.rawValue] = clean
        shortcutOverrides = Self.normalizedShortcutOverrides(shortcutOverrides)
    }
    private static func normalizedShortcutOverrides(_ overrides: [String: String]) -> [String: String] {
        var resolved = Dictionary(uniqueKeysWithValues: LimaWorkspaceModule.allCases.map { ($0.rawValue, $0.shortcutNumber) })
        for module in LimaWorkspaceModule.allCases {
            guard let raw = overrides[module.rawValue] else { continue }
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard allowedShortcutKeys.contains(key), let old = resolved[module.rawValue], key != old else { continue }
            if let owner = resolved.first(where: { $0.key != module.rawValue && $0.value == key })?.key {
                resolved[owner] = old
            }
            resolved[module.rawValue] = key
        }
        return resolved.filter { key, value in
            LimaWorkspaceModule(rawValue: key)?.shortcutNumber != value
        }
    }

    func modules(in section: WorkspaceRailSection) -> [LimaWorkspaceModule] {
        switch section {
        case .workspace: workspaceModules
        case .tools: toolModules
        case .hidden: hiddenModules
        }
    }
    func section(for module: LimaWorkspaceModule) -> WorkspaceRailSection {
        if workspaceModules.contains(module) { return .workspace }
        if toolModules.contains(module) { return .tools }
        return .hidden
    }
    func sectionID(for module: LimaWorkspaceModule) -> UUID? {
        sections.first(where: { $0.modules.contains(module) })?.id
    }

    mutating func setSection(_ section: WorkspaceRailSection, for module: LimaWorkspaceModule) {
        switch section {
        case .workspace: moveModule(module, to: WorkspaceSectionConfiguration.workspaceID)
        case .tools: moveModule(module, to: WorkspaceSectionConfiguration.toolsID)
        case .hidden: hideModule(module)
        }
    }
    mutating func move(_ module: LimaWorkspaceModule, in section: WorkspaceRailSection, by offset: Int) {
        switch section {
        case .workspace: moveModule(module, in: WorkspaceSectionConfiguration.workspaceID, by: offset)
        case .tools: moveModule(module, in: WorkspaceSectionConfiguration.toolsID, by: offset)
        case .hidden: break
        }
    }
    mutating func moveModule(_ module: LimaWorkspaceModule, to sectionID: UUID) {
        guard let destination = sections.firstIndex(where: { $0.id == sectionID }) else { return }
        for index in sections.indices { sections[index].modules.removeAll { $0 == module } }
        sections[destination].modules.append(module)
        ensureVisibleStartup()
    }
    mutating func moveModule(_ module: LimaWorkspaceModule, in sectionID: UUID, by offset: Int) {
        guard let sectionIndex = sections.firstIndex(where: { $0.id == sectionID }),
              let index = sections[sectionIndex].modules.firstIndex(of: module) else { return }
        let destination = min(max(index + offset, 0), sections[sectionIndex].modules.count - 1)
        guard destination != index else { return }
        sections[sectionIndex].modules.remove(at: index)
        sections[sectionIndex].modules.insert(module, at: destination)
    }
    mutating func moveModule(_ module: LimaWorkspaceModule, before target: LimaWorkspaceModule) {
        guard module != target, let sectionID = sectionID(for: target),
              let destination = sections.firstIndex(where: { $0.id == sectionID }) else { return }
        for index in sections.indices { sections[index].modules.removeAll { $0 == module } }
        guard let targetIndex = sections[destination].modules.firstIndex(of: target) else { return }
        sections[destination].modules.insert(module, at: targetIndex)
        ensureVisibleStartup()
    }
    mutating func hideModule(_ module: LimaWorkspaceModule) {
        for index in sections.indices { sections[index].modules.removeAll { $0 == module } }
        ensureVisibleStartup()
    }
    mutating func showModule(_ module: LimaWorkspaceModule) {
        guard sectionID(for: module) == nil, let first = sections.first?.id else { return }
        moveModule(module, to: first)
    }
    @discardableResult
    mutating func addSection(named name: String) -> UUID? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let section = WorkspaceSectionConfiguration(name: clean)
        sections.append(section)
        return section.id
    }
    mutating func renameSection(_ id: UUID, to name: String) {
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return }
        sections[index].name = name
    }
    mutating func moveSection(_ id: UUID, by offset: Int) {
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return }
        let destination = min(max(index + offset, 0), sections.count - 1)
        guard index != destination else { return }
        sections.insert(sections.remove(at: index), at: destination)
    }
    mutating func moveSection(_ id: UUID, before targetID: UUID) {
        guard id != targetID, let source = sections.firstIndex(where: { $0.id == id }) else { return }
        let section = sections.remove(at: source)
        guard let destination = sections.firstIndex(where: { $0.id == targetID }) else {
            sections.insert(section, at: source)
            return
        }
        sections.insert(section, at: destination)
    }
    mutating func deleteSection(_ id: UUID) {
        guard id != WorkspaceSectionConfiguration.workspaceID,
              id != WorkspaceSectionConfiguration.toolsID,
              let index = sections.firstIndex(where: { $0.id == id }) else { return }
        let modules = sections.remove(at: index).modules
        if !sections.isEmpty { sections[0].modules.append(contentsOf: modules) }
    }

    private mutating func ensureVisibleStartup() {
        if !visibleModules.contains(startupModule) {
            startupModule = visibleModules.first ?? .home
        }
    }
    private static func normalizedSections(_ sections: [WorkspaceSectionConfiguration]) -> [WorkspaceSectionConfiguration] {
        var seenIDs = Set<UUID>()
        var seenModules = Set<LimaWorkspaceModule>()
        var result: [WorkspaceSectionConfiguration] = []
        for section in sections where seenIDs.insert(section.id).inserted {
            let name = section.name.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(WorkspaceSectionConfiguration(
                id: section.id, name: name.isEmpty ? "Section" : name,
                modules: section.modules.filter { seenModules.insert($0).inserted }
            ))
        }
        if result.isEmpty {
            result.append(WorkspaceSectionConfiguration(id: WorkspaceSectionConfiguration.workspaceID, name: "Workspace"))
        }
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case sections, startupModule, railPresentation, railWidth, showsSectionNames, showsKeyboardShortcuts, shortcutOverrides, home
        case workspaceModules, toolModules
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(sections, forKey: .sections)
        try values.encode(startupModule, forKey: .startupModule)
        try values.encode(railPresentation, forKey: .railPresentation)
        try values.encode(railWidth, forKey: .railWidth)
        try values.encode(showsSectionNames, forKey: .showsSectionNames)
        try values.encode(showsKeyboardShortcuts, forKey: .showsKeyboardShortcuts)
        try values.encode(shortcutOverrides, forKey: .shortcutOverrides)
        try values.encode(home, forKey: .home)
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let sections: [WorkspaceSectionConfiguration]
        if let saved = try values.decodeIfPresent([WorkspaceSectionConfiguration].self, forKey: .sections) {
            sections = saved
        } else {
            sections = [
                WorkspaceSectionConfiguration(
                    id: WorkspaceSectionConfiguration.workspaceID, name: "Workspace",
                    modules: try values.decodeIfPresent([LimaWorkspaceModule].self, forKey: .workspaceModules) ?? LimaWorkspaceModule.workspaceDestinations
                ),
                WorkspaceSectionConfiguration(
                    id: WorkspaceSectionConfiguration.toolsID, name: "Tools",
                    modules: try values.decodeIfPresent([LimaWorkspaceModule].self, forKey: .toolModules) ?? LimaWorkspaceModule.toolDestinations
                )
            ]
        }
        self.init(
            sections: sections,
            startupModule: try values.decodeIfPresent(LimaWorkspaceModule.self, forKey: .startupModule) ?? .home,
            railPresentation: try values.decodeIfPresent(WorkspaceRailPresentation.self, forKey: .railPresentation) ?? .adaptive,
            railWidth: try values.decodeIfPresent(WorkspaceRailWidth.self, forKey: .railWidth) ?? .standard,
            showsSectionNames: try values.decodeIfPresent(Bool.self, forKey: .showsSectionNames) ?? true,
            showsKeyboardShortcuts: try values.decodeIfPresent(Bool.self, forKey: .showsKeyboardShortcuts) ?? false,
            shortcutOverrides: try values.decodeIfPresent([String: String].self, forKey: .shortcutOverrides) ?? [:],
            home: try values.decodeIfPresent(HomeWorkspaceConfiguration.self, forKey: .home) ?? .defaultConfiguration
        )
    }
}

struct WorkspaceConfigurationEditor: View {
    @ObservedObject var settings: SettingsStore
    @State private var newSectionName = ""
    private var configuration: WorkspaceConfiguration { settings.workspaceConfiguration }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Arrange modules in any section. Hidden modules remain available in Search and commands.")
                .font(.caption).foregroundStyle(LimaTheme.textSecondary)
            ForEach(Array(configuration.sections.enumerated()), id: \.element.id) { index, section in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(LimaTheme.textTertiary)
                            .draggable("section:\(section.id.uuidString)")
                        TextField("Section name", text: Binding(
                            get: { settings.workspaceConfiguration.sections.first(where: { $0.id == section.id })?.name ?? section.name },
                            set: { value in update { $0.renameSection(section.id, to: value) } }
                        ))
                        .font(.system(size: 11, weight: .bold))
                        .textFieldStyle(.plain)
                        Spacer()
                        orderButton("arrow.up", disabled: index == 0) { update { $0.moveSection(section.id, by: -1) } }
                        orderButton("arrow.down", disabled: index == configuration.sections.count - 1) { update { $0.moveSection(section.id, by: 1) } }
                        if section.id != WorkspaceSectionConfiguration.workspaceID &&
                            section.id != WorkspaceSectionConfiguration.toolsID {
                            Button("Remove", systemImage: "minus.circle") { update { $0.deleteSection(section.id) } }
                                .labelStyle(.iconOnly)
                                .help("Remove section and move its modules to the first section")
                        }
                    }
                    .dropDestination(for: String.self) { items, _ in
                        drop(items, on: section.id)
                    }
                    if section.modules.isEmpty {
                        Text("No modules").font(.caption).foregroundStyle(LimaTheme.textTertiary)
                    }
                    ForEach(Array(section.modules.enumerated()), id: \.element) { moduleIndex, module in
                        HStack(spacing: 8) {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(LimaTheme.textTertiary)
                                .draggable("module:\(module.rawValue)")
                            Label(module.title, systemImage: module.symbol)
                            Spacer(minLength: 8)
                            shortcutMenu(for: module)
                            orderButton("arrow.up", disabled: moduleIndex == 0) {
                                update { $0.moveModule(module, in: section.id, by: -1) }
                            }
                            orderButton("arrow.down", disabled: moduleIndex == section.modules.count - 1) {
                                update { $0.moveModule(module, in: section.id, by: 1) }
                            }
                            Menu {
                                ForEach(configuration.sections.filter { $0.id != section.id }) { destination in
                                    Button(destination.name) { update { $0.moveModule(module, to: destination.id) } }
                                }
                                Divider()
                                Button("Hide") { update { $0.hideModule(module) } }
                            } label: { Image(systemName: "ellipsis.circle") }
                                .menuStyle(.borderlessButton)
                                .accessibilityLabel("Move \(module.title)")
                        }
                        .dropDestination(for: String.self) { items, _ in
                            guard let value = items.first, value.hasPrefix("module:"),
                                  let dragged = LimaWorkspaceModule(rawValue: String(value.dropFirst(7))) else { return false }
                            update { $0.moveModule(dragged, before: module) }
                            return true
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            HStack {
                TextField("New section", text: $newSectionName)
                Button("Add Section") {
                    update { _ = $0.addSection(named: newSectionName) }
                    newSectionName = ""
                }
                .disabled(newSectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !configuration.hiddenModules.isEmpty {
                Text("HIDDEN").font(.system(size: 10, weight: .bold)).foregroundStyle(LimaTheme.textTertiary)
                ForEach(configuration.hiddenModules, id: \.self) { module in
                    HStack {
                        Label(module.title, systemImage: module.symbol)
                            .draggable("module:\(module.rawValue)")
                        Spacer()
                        shortcutMenu(for: module)
                        Menu("Show in…") {
                            ForEach(configuration.sections) { section in
                                Button(section.name) { update { $0.moveModule(module, to: section.id) } }
                            }
                        }
                    }
                }
            }
            Divider()
            Picker("Rail presentation", selection: Binding(
                get: { settings.workspaceConfiguration.railPresentation },
                set: { value in update { $0.railPresentation = value } }
            )) {
                ForEach(WorkspaceRailPresentation.allCases) { Text($0.title).tag($0) }
            }
            Picker("Rail width", selection: Binding(
                get: { settings.workspaceConfiguration.railWidth },
                set: { value in update { $0.railWidth = value } }
            )) {
                ForEach(WorkspaceRailWidth.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Show section names", isOn: Binding(
                get: { settings.workspaceConfiguration.showsSectionNames },
                set: { value in update { $0.showsSectionNames = value } }
            ))
            Toggle("Show keyboard shortcuts", isOn: Binding(
                get: { settings.workspaceConfiguration.showsKeyboardShortcuts },
                set: { value in update { $0.showsKeyboardShortcuts = value } }
            ))
            Picker("Startup module", selection: Binding(
                get: { settings.workspaceConfiguration.startupModule },
                set: { value in update { $0.startupModule = value } }
            )) {
                ForEach(configuration.visibleModules, id: \.self) { module in Text(module.title).tag(module) }
            }
            Button("Restore Default Layout") { settings.workspaceConfiguration = .defaultConfiguration }
        }
        .padding(.vertical, 4)
    }

    private func drop(_ items: [String], on sectionID: UUID) -> Bool {
        guard let value = items.first else { return false }
        if value.hasPrefix("module:"),
           let module = LimaWorkspaceModule(rawValue: String(value.dropFirst(7))) {
            update { $0.moveModule(module, to: sectionID) }
            return true
        }
        if value.hasPrefix("section:"),
           let sourceID = UUID(uuidString: String(value.dropFirst(8))) {
            update { $0.moveSection(sourceID, before: sectionID) }
            return true
        }
        return false
    }

    private func shortcutMenu(for module: LimaWorkspaceModule) -> some View {
        Menu {
            ForEach(WorkspaceConfiguration.allowedShortcutKeys, id: \.self) { key in
                Button {
                    update { $0.setShortcutKey(key, for: module) }
                } label: {
                    if key == configuration.shortcutKey(for: module) {
                        Label("⌥⌘\(key)", systemImage: "checkmark")
                    } else {
                        Text("⌥⌘\(key)")
                    }
                }
            }
        } label: {
            Text("⌥⌘\(configuration.shortcutKey(for: module))")
                .font(.caption.monospaced())
        }
        .menuStyle(.borderlessButton)
        .help("Change \(module.title) shortcut; selecting an assigned key swaps shortcuts")
        .accessibilityLabel("\(module.title) shortcut")
    }

    private func orderButton(_ symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .disabled(disabled)
    }
    private func update(_ change: (inout WorkspaceConfiguration) -> Void) {
        var next = settings.workspaceConfiguration
        change(&next)
        settings.workspaceConfiguration = next.normalized
    }
}

struct HomeWorkspaceConfigurationEditor: View {
    @ObservedObject var settings: SettingsStore
    private var configuration: HomeWorkspaceConfiguration { settings.workspaceConfiguration.home }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose which Home sections appear and drag their order with the arrow controls.")
                .font(.caption).foregroundStyle(LimaTheme.textSecondary)
            ForEach(Array(configuration.sectionOrder.enumerated()), id: \.element) { index, section in
                HStack {
                    Toggle(section.title, isOn: Binding(
                        get: { settings.workspaceConfiguration.home.isVisible(section) },
                        set: { visible in update { $0.setVisible(visible, for: section) } }
                    ))
                    Spacer()
                    Button("Move up", systemImage: "arrow.up") { update { $0.move(section, by: -1) } }
                        .labelStyle(.iconOnly)
                        .disabled(index == 0)
                    Button("Move down", systemImage: "arrow.down") { update { $0.move(section, by: 1) } }
                        .labelStyle(.iconOnly)
                        .disabled(index == configuration.sectionOrder.count - 1)
                }
            }
            Toggle("Show Recent Notes", isOn: Binding(
                get: { settings.workspaceConfiguration.home.showsRecentNotes },
                set: { value in update { $0.showsRecentNotes = value } }
            ))
            Toggle("Show Recent AI", isOn: Binding(
                get: { settings.workspaceConfiguration.home.showsRecentAI },
                set: { value in update { $0.showsRecentAI = value } }
            ))
            Button("Restore Home Defaults") {
                var next = settings.workspaceConfiguration
                next.home = .defaultConfiguration
                settings.workspaceConfiguration = next
            }
        }
        .padding(.vertical, 4)
    }

    private func update(_ change: (inout HomeWorkspaceConfiguration) -> Void) {
        var next = settings.workspaceConfiguration
        change(&next.home)
        settings.workspaceConfiguration = next.normalized
    }
}
