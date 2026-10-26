import RayPlacementCore
import SwiftUI

/// Navigation remembers destinations, never editor content or credentials.
struct LimaWorkspaceNavigation: Equatable {
    private(set) var current: LimaWorkspaceModule = .home
    private(set) var previous: LimaWorkspaceModule?

    mutating func select(_ module: LimaWorkspaceModule) {
        let destination: LimaWorkspaceModule = module == .workflows ? .home : module
        guard destination != current else { return }
        previous = current
        current = destination
    }
}

extension LimaWorkspaceModule {
    static let workspaceDestinations: [LimaWorkspaceModule] = [.home, .ai, .browser, .terminal, .notes]
    static let toolDestinations: [LimaWorkspaceModule] = [.clipboard, .extensions, .grammar]
    static let primaryDestinations: [LimaWorkspaceModule] = workspaceDestinations + toolDestinations
    static let hiddenDestinations: [LimaWorkspaceModule] = [.context, .dictation, .formatter]

    var title: String {
        switch self {
        case .home: "Home"
        case .notes: "Notes"
        case .ai: "AI Chat"
        case .browser: "Browser"
        case .context: "Context Shelf"
        case .grammar: "Writing Tools"
        case .dictation: "Dictation"
        case .workflows: "Workflows"
        case .extensions: "Extensions"
        case .clipboard: "Clipboard"
        case .terminal: "Terminal"
        case .formatter: "Formatter"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .notes: "note.text"
        case .ai: "sparkles"
        case .browser: "globe"
        case .context: "square.stack.3d.up"
        case .grammar: "textformat.abc"
        case .dictation: "waveform"
        case .workflows: "arrow.triangle.branch"
        case .extensions: "puzzlepiece.extension"
        case .clipboard: "doc.on.clipboard"
        case .terminal: "terminal"
        case .formatter: "wand.and.stars"
        }
    }

    /// Explicit assignments keep the workspace sequence stable if enum order changes.
    var shortcutNumber: String {
        switch self {
        case .home: "1"
        case .notes: "2"
        case .ai: "3"
        case .browser: "B"
        case .context: "4"
        case .grammar: "5"
        case .dictation: "6"
        case .workflows: "7"
        case .extensions: "8"
        case .clipboard: "9"
        case .terminal: "T"
        case .formatter: "F"
        }
    }

    /// Preserve Context’s mnemonic for established keyboard users while the
    /// numbered shortcut remains the consistent primary sequence.
    var shortcutAlias: String? {
        self == .context ? "C" : nil
    }
}

/// A compact gradient waypoint mark drawn in SwiftUI, with no image asset dependency.
struct LimaWayfinderMark: View {
    var body: some View {
        LimaWayfinderMarkShape()
            .fill(LinearGradient(
                colors: [Color(red: 0.28, green: 0.70, blue: 0.98), Color(red: 0.34, green: 0.48, blue: 0.99), Color(red: 0.56, green: 0.34, blue: 0.91)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
    }
}

private struct LimaWayfinderMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        return Path { path in
            path.move(to: point(0.48, 0.04))
            path.addQuadCurve(to: point(0.65, 0.13), control: point(0.57, 0.00))
            path.addLine(to: point(0.95, 0.75))
            path.addQuadCurve(to: point(0.78, 0.97), control: point(0.98, 0.94))
            path.addLine(to: point(0.20, 0.97))
            path.addQuadCurve(to: point(0.04, 0.76), control: point(0.02, 0.96))
            path.addLine(to: point(0.32, 0.20))
            path.addQuadCurve(to: point(0.48, 0.04), control: point(0.39, 0.06))
            path.closeSubpath()
        }
    }
}

/// Shared by production and the UI Lab; it never constructs workspace services.
struct LimaWayfinderRail: View {
    let current: LimaWorkspaceModule
    let previous: LimaWorkspaceModule?
    let sizeClass: LimaWorkspaceSizeClass
    let select: (LimaWorkspaceModule) -> Void
    let openSettings: () -> Void
    let isDocked: Bool
    let openInWindow: () -> Void
    var workspaceProfiles: [WorkspaceProfile] = []
    var activeWorkspaceProfileID: UUID? = nil
    var selectWorkspaceProfile: ((WorkspaceProfile) -> Void)? = nil
    var createWorkspaceProfile: (() -> Void)? = nil
    var aiSidecarVisible: Bool = false
    var toggleAISidecar: (() -> Void)? = nil
    var openSearch: (() -> Void)? = nil
    var openCaptures: (() -> Void)? = nil
    var forceIconOnly: Bool = false
    @State private var toolsExpanded = true
    @ObservedObject private var layout = WorkspaceLayoutStore.shared
    private let settings = SettingsStore.shared
    @State private var hovered: String?
    @ObservedObject private var typography = AppTypography.shared

    private var labeled: Bool {
        if forceIconOnly { return false }
        switch layout.configuration.railPresentation {
        case .adaptive: return sizeClass == .expanded
        case .icons: return false
        case .iconsAndLabels: return true
        }
    }

    private var configuredWidth: CGFloat {
        let base = labeled ? max(sizeClass.moduleRailWidth, 208 * typography.scale) : max(sizeClass.moduleRailWidth, 60)
        switch layout.configuration.railWidth {
        case .compact: return labeled ? max(200, base - 8) : 58
        case .standard: return base
        case .wide: return base + (labeled ? 24 : 4)
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 9) {
                LimaWayfinderMark()
                if labeled {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Lima").limaFont(.system(size: 21, weight: .semibold))
                            .foregroundStyle(LimaTheme.textPrimary)
                        Text("Search. Create. Do.").limaFont(.caption)
                            .foregroundStyle(LimaTheme.textTertiary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(height: 70)
            .frame(maxWidth: .infinity, alignment: labeled ? .leading : .center)
            .padding(.horizontal, labeled ? 9 : 0)
            .padding(.bottom, 6)

            if let openSearch {
                Button(action: openSearch) {
                    railLabel("Search anything", symbol: "magnifyingglass", selected: false,
                              hovered: hovered == "search", shortcut: "⌘K")
                }
                .buttonStyle(.plain)
                .help("Search anything")
                .accessibilityLabel("Search anything")
                .onHover { hovered = $0 ? "search" : nil }
            }

            if let selectWorkspaceProfile, !workspaceProfiles.isEmpty {
                Menu {
                    ForEach(workspaceProfiles) { profile in
                        Button {
                            selectWorkspaceProfile(profile)
                        } label: {
                            if profile.id == activeWorkspaceProfileID {
                                Label(profile.name, systemImage: "checkmark")
                            } else {
                                Text(profile.name)
                            }
                        }
                    }
                    if let createWorkspaceProfile {
                        Divider()
                        Button("New Workspace", systemImage: "plus", action: createWorkspaceProfile)
                    }
                } label: {
                    railLabel(
                        workspaceProfiles.first(where: { $0.id == activeWorkspaceProfileID })?.name ?? "Workspaces",
                        symbol: "square.stack.3d.up",
                        selected: false,
                        hovered: hovered == "profiles"
                    )
                }
                .menuStyle(.borderlessButton)
                .help("Switch or create a named workspace")
                .accessibilityLabel("Switch Workspace")
                .onHover { hovered = $0 ? "profiles" : nil }
                Divider().padding(.horizontal, 8)
            }

            ScrollView(.vertical) {
                VStack(spacing: 8) {
                    ForEach(layout.configuration.sections) { section in
                        railGroup(section)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Spacer(minLength: 12)

            if isDocked {
                Button(action: openInWindow) {
                    railLabel("Open in Window", symbol: "arrow.up.left.and.arrow.down.right", selected: false, hovered: hovered == "window")
                }
                .buttonStyle(.plain)
                .help("Open the same workspace in a resizable window")
                .accessibilityLabel("Open in Window")
                .onHover { hovered = $0 ? "window" : nil }
            }

            Button(action: openSettings) {
                railLabel("Settings", symbol: "gearshape", selected: false, hovered: hovered == "settings")
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityLabel("Open Settings")
            .onHover { hovered = $0 ? "settings" : nil }
        }
        .padding(.horizontal, labeled ? 10 : 4)
        .padding(.vertical, 14)
        .frame(width: configuredWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .limaGlassContainer(region: .sidebar, cornerRadius: 22)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace navigation")
        .accessibilityIdentifier(LimaQAIdentifiers.Workspace.sidebar)
        .contextMenu {
            Button("Customize Workspace…") {
                settings.requestedSettingsSection = .workspace
                openSettings()
            }
        }
        .background {
            // Keep established shortcuts without showing layout controls as destinations.
            if let previous {
                Button("") { select(previous) }
                    .keyboardShortcut("0", modifiers: [.command, .option])
                    .hidden()
                    .accessibilityHidden(true)
            }
            if current != .ai, let toggleAISidecar {
                Button("", action: toggleAISidecar)
                    .keyboardShortcut("\\", modifiers: [.command])
                    .hidden()
                    .accessibilityHidden(true)
            }
            ForEach(layout.configuration.hiddenModules, id: \.self) { module in
                Button("") { select(module) }
                    .keyboardShortcut(KeyEquivalent(Character(layout.configuration.shortcutKey(for: module).lowercased())), modifiers: [.command, .option])
                    .hidden()
                    .accessibilityHidden(true)
            }
            if !toolsExpanded {
                ForEach(layout.configuration.toolModules, id: \.self) { module in
                    Button("") { select(module) }
                        .keyboardShortcut(KeyEquivalent(Character(layout.configuration.shortcutKey(for: module).lowercased())), modifiers: [.command, .option])
                        .hidden()
                        .accessibilityHidden(true)
                }
            }
        }
    }

    @ViewBuilder
    private func railGroup(_ section: WorkspaceSectionConfiguration) -> some View {
        let isTools = section.id == WorkspaceSectionConfiguration.toolsID
        if isTools {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { toolsExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 24, height: 24)
                    if labeled {
                        Text(section.name.uppercased())
                            .font(.system(size: 12, weight: .semibold))
                        Spacer(minLength: 0)
                        Image(systemName: toolsExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                }
                .foregroundStyle(LimaTheme.textSecondary)
                .padding(.horizontal, labeled ? 8 : 0)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
            }
            .buttonStyle(.plain)
            .help(toolsExpanded ? "Collapse Tools" : "Expand Tools")
            .accessibilityLabel("Tools")
            .accessibilityValue(toolsExpanded ? "Expanded" : "Collapsed")
        } else if labeled && layout.configuration.showsSectionNames {
            Text(section.name.uppercased())
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(LimaTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 11)
                .padding(.top, 8)
                .padding(.bottom, 1)
        }

        if !isTools || toolsExpanded {
            if isTools, let openCaptures {
                Button(action: openCaptures) {
                    railLabel("Captures", symbol: "viewfinder", selected: false,
                              hovered: hovered == "captures")
                }
                .buttonStyle(.plain)
                .help("Open Screenshot Studio and history")
                .accessibilityLabel("Captures")
                .onHover { hovered = $0 ? "captures" : nil }
            }
            ForEach(section.modules, id: \.self) { module in
            Button { select(module) } label: {
                railLabel(module.title, symbol: module.symbol, selected: module == current, hovered: hovered == module.rawValue,
                          shortcut: "⌥⌘\(layout.configuration.shortcutKey(for: module))")
            }
            .buttonStyle(.plain)
            .keyboardShortcut(KeyEquivalent(Character(layout.configuration.shortcutKey(for: module).lowercased())), modifiers: [.command, .option])
            .background {
                if let alias = layout.configuration.shortcutAlias(for: module) {
                    Button("") { select(module) }
                        .keyboardShortcut(KeyEquivalent(Character(alias.lowercased())), modifiers: [.command, .option])
                        .hidden()
                        .accessibilityHidden(true)
                }
            }
            .help("\(module.title) · ⌥⌘\(layout.configuration.shortcutKey(for: module))\(layout.configuration.shortcutAlias(for: module).map { " · ⌥⌘\($0)" } ?? "")")
            .accessibilityLabel(module.title)
            .accessibilityIdentifier(LimaQAIdentifiers.Workspace.module(module))
            .accessibilityValue(module == current ? "Current workspace" : "")
            .accessibilityAddTraits(module == current ? [.isSelected] : [])
            .onHover { hovered = $0 ? module.rawValue : nil }
            }
        }
    }

    private func railLabel(_ title: String, symbol: String, selected: Bool, hovered: Bool, shortcut: String? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 18, weight: selected ? .semibold : .medium))
                .frame(width: 24, height: 24)
            if labeled {
                VStack(alignment: .leading, spacing: 1) {
                    if symbol == "arrow.uturn.backward", previous != nil {
                        Text("RETURN TO").font(.system(size: 8, weight: .semibold)).tracking(0.6)
                            .foregroundStyle(LimaTheme.textTertiary)
                    }
                    Text(title).limaFont(.system(size: 14, weight: selected ? .semibold : .medium))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if layout.configuration.showsKeyboardShortcuts, let shortcut {
                    Text(shortcut).font(.system(size: 9, weight: .medium))
                        .foregroundStyle(LimaTheme.textTertiary)
                }
            }
        }
        .foregroundStyle(selected ? LimaTheme.accentInk : LimaTheme.textSecondary)
        .padding(.horizontal, labeled ? 8 : 0)
        .frame(maxWidth: .infinity)
        .frame(minHeight: max(labeled ? 40 : 40, 32 * typography.scale))
        .limaSelection(selected, hovered: hovered, radius: LimaRadius.control)
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [settings.accentTheme.primary.opacity(0.72),
                                                LimaTheme.borderStrong.opacity(0.32)],
                                       startPoint: .leading, endPoint: .trailing),
                        lineWidth: 0.9
                    )
                    .allowsHitTesting(false)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: LimaRadius.control))
    }
}
