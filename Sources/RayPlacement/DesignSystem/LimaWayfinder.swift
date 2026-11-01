import RayPlacementCore
import SwiftUI

/// Navigation remembers destinations, never editor content or credentials.
struct LimaWorkspaceNavigation: Equatable {
    private(set) var current: LimaWorkspaceModule = .ai
    private(set) var previous: LimaWorkspaceModule?

    mutating func select(_ module: LimaWorkspaceModule) {
        let destination: LimaWorkspaceModule = [.home, .workflows].contains(module) ? .ai : module
        guard destination != current else { return }
        previous = current
        current = destination
    }
}

extension LimaWorkspaceModule {
    static let workspaceDestinations: [LimaWorkspaceModule] = [.ai, .notes, .dictation]
    static let toolDestinations: [LimaWorkspaceModule] = []
    static let userFacingModules = allCases.filter { $0 != .context && $0 != .home }
    static let primaryDestinations: [LimaWorkspaceModule] = workspaceDestinations + toolDestinations
    static let hiddenDestinations: [LimaWorkspaceModule] = [.home, .browser, .terminal, .context, .extensions, .clipboard, .grammar, .formatter]

    var primaryDestination: LimaWorkspaceModule {
        [.notes, .dictation].contains(self) ? self : .ai
    }

    var title: String {
        switch self {
        case .home: "Home"
        case .notes: "Notes"
        case .ai: "Assistant"
        case .browser: "Browser"
        case .context: "Context Shelf"
        case .grammar: "Writing Tools"
        case .dictation: "Recordings"
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

/// Small, stable navigation. Feature state stays in its owning store.
struct WorkspaceRecentDestination: Identifiable {
    let id: UUID
    let title: String
    let open: () -> Void
}

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
    var aiSidecarVisible = false
    var toggleAISidecar: (() -> Void)? = nil
    var openSearch: (() -> Void)? = nil
    var openCaptures: (() -> Void)? = nil
    var forceIconOnly = false
    var recentItems: [WorkspaceRecentDestination] = []
    @ObservedObject private var layout = WorkspaceLayoutStore.shared

    private var labeled: Bool { !forceIconOnly && layout.configuration.railPresentation != .icons && (sizeClass == .expanded || layout.configuration.railPresentation == .iconsAndLabels) }
    private var destination: LimaWorkspaceModule {
        current.primaryDestination
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                LimaWayfinderMark()
                if labeled {
                    Text("Lima").limaFont(.system(size: 20, weight: .semibold))
                    Spacer(minLength: 0)
                    if let selectWorkspaceProfile, !workspaceProfiles.isEmpty {
                        Menu {
                            ForEach(workspaceProfiles) { profile in
                                Button(profile.name) { selectWorkspaceProfile(profile) }
                            }
                            if let createWorkspaceProfile {
                                Divider()
                                Button("New Workspace", action: createWorkspaceProfile)
                            }
                        } label: { Image(systemName: "chevron.down") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden)
                        .help("Switch workspace")
                    }
                }
            }
            .frame(height: 50).padding(.horizontal, 8)
            if let openSearch {
                row("Search", symbol: "magnifyingglass", action: openSearch)
                    .padding(.bottom, 12)
                    .keyboardShortcut("k", modifiers: .command)
            }
            ForEach(LimaWorkspaceModule.workspaceDestinations, id: \.self) { module in
                row(module.title, symbol: module.symbol, selected: destination == module) { select(module) }
                    .accessibilityIdentifier(LimaQAIdentifiers.Workspace.module(module))
                    .keyboardShortcut(KeyEquivalent(Character(layout.configuration.shortcutKey(for: module).lowercased())), modifiers: [.command, .option])
            }
            if labeled, !recentItems.isEmpty {
                Text("RECENT").limaFont(.system(size: 10, weight: .semibold))
                    .tracking(0.7).foregroundStyle(LimaTheme.textTertiary)
                    .padding(.top, 24).padding(.horizontal, 10).padding(.bottom, 4)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(recentItems.prefix(8)) { item in
                            Button(action: item.open) {
                                Text(item.title.isEmpty ? "Untitled" : item.title)
                                    .limaFont(.system(size: 12)).lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10).padding(.vertical, 8)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).foregroundStyle(LimaTheme.textSecondary)
                        }
                    }
                }
            }
            Spacer(minLength: 16)
            if isDocked { row("Open in Window", symbol: "arrow.up.left.and.arrow.down.right", action: openInWindow) }
            Menu {
                Button("Settings…", action: openSettings)
                Button("Extensions…") { SettingsStore.shared.requestedSettingsSection = .commands; openSettings() }
                Button("Permissions…") { SettingsStore.shared.requestedSettingsSection = .capabilities; openSettings() }
                Button("Appearance…") { SettingsStore.shared.requestedSettingsSection = .appearance; openSettings() }
                if let openCaptures { Divider(); Button("Capture history", action: openCaptures) }
            } label: { label("Settings", symbol: "gearshape", selected: false) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .accessibilityLabel("Settings and extensions")
        }
        .padding(.horizontal, labeled ? 12 : 6).padding(.vertical, 8)
        .frame(width: labeled ? 200 : 60)
        .frame(maxHeight: .infinity)
        .background(LimaTheme.surfaceSecondary)
        .accessibilityIdentifier(LimaQAIdentifiers.Workspace.sidebar)
        .background {
            Button("") { select(.ai) }
                .keyboardShortcut(KeyEquivalent(Character(layout.configuration.shortcutKey(for: .home).lowercased())), modifiers: [.command, .option])
                .hidden().accessibilityHidden(true)
            ForEach(LimaWorkspaceModule.userFacingModules.filter { !LimaWorkspaceModule.workspaceDestinations.contains($0) }, id: \.self) { module in
                Button("") { select(module) }
                    .keyboardShortcut(KeyEquivalent(Character(layout.configuration.shortcutKey(for: module).lowercased())), modifiers: [.command, .option])
                    .hidden().accessibilityHidden(true)
            }
        }
    }

    private func row(_ title: String, symbol: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { label(title, symbol: symbol, selected: selected) }
            .buttonStyle(.plain).help(title).accessibilityLabel(title)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func label(_ title: String, symbol: String, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium)).frame(width: 24)
            if labeled { Text(title).limaFont(.system(size: 13, weight: selected ? .semibold : .regular)); Spacer(minLength: 0) }
        }
        .padding(.horizontal, 8).frame(height: 38)
        .frame(maxWidth: .infinity, alignment: labeled ? .leading : .center)
        .foregroundStyle(selected ? LimaTheme.accentInk : LimaTheme.textSecondary)
        .background(selected ? LimaTheme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
}
