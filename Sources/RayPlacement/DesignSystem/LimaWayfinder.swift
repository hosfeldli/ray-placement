import RayPlacementCore
import SwiftUI

/// Navigation remembers destinations, never editor content or credentials.
struct LimaWorkspaceNavigation: Equatable {
    private(set) var current: LimaWorkspaceModule = .home
    private(set) var previous: LimaWorkspaceModule?

    mutating func select(_ module: LimaWorkspaceModule) {
        guard module != current else { return }
        previous = current
        current = module
    }
}

extension LimaWorkspaceModule {
    static let workspaceDestinations: [LimaWorkspaceModule] = [.home, .notes, .ai, .context, .grammar, .dictation]
    static let toolDestinations: [LimaWorkspaceModule] = [.extensions, .clipboard, .terminal, .formatter]
    static let primaryDestinations: [LimaWorkspaceModule] = workspaceDestinations + toolDestinations

    var title: String {
        switch self {
        case .home: "Home"
        case .notes: "Notes"
        case .ai: "AI"
        case .context: "Context"
        case .grammar: "Grammar"
        case .dictation: "Dictation"
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
        case .context: "tray.full"
        case .grammar: "textformat.abc"
        case .dictation: "waveform"
        case .extensions: "puzzlepiece.extension"
        case .clipboard: "clipboard"
        case .terminal: "terminal"
        case .formatter: "wand.and.stars"
        }
    }

    /// Explicit assignments keep muscle memory stable if enum order changes.
    var shortcutNumber: String {
        switch self {
        case .home: "1"
        case .notes: "2"
        case .ai: "3"
        case .context: "C"
        case .grammar: "4"
        case .dictation: "5"
        case .extensions: "6"
        case .clipboard: "7"
        case .terminal: "8"
        case .formatter: "9"
        }
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
    @State private var hovered: String?
    @ObservedObject private var typography = AppTypography.shared

    private var labeled: Bool { sizeClass == .expanded }

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
            .padding(.bottom, 16)

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
                    railGroup("WORKSPACE", destinations: LimaWorkspaceModule.workspaceDestinations)
                    railGroup("TOOLS", destinations: LimaWorkspaceModule.toolDestinations)
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider().padding(.horizontal, 8).padding(.vertical, 6)

            Button {
                if let previous { select(previous) }
            } label: {
                railLabel(labeled ? (previous?.title ?? "Return") : "Return", symbol: "arrow.uturn.backward",
                          selected: false, hovered: hovered == "return")
            }
            .buttonStyle(.plain)
            .keyboardShortcut("0", modifiers: [.command, .option])
            .disabled(previous == nil)
            .opacity(previous == nil ? 0.45 : 1)
            .help(previous.map { "Return to \($0.title) · ⌥⌘0" } ?? "Switch workspaces to enable Return")
            .accessibilityLabel(previous.map { "Return to \($0.title)" } ?? "Return to previous workspace")
            .onHover { hovered = $0 ? "return" : nil }

            Spacer(minLength: 12)

            if labeled {
                Text("⌥⌘ 1–9 · C").font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(LimaTheme.textTertiary)
                    .help("Switch workspaces; ⌥⌘0 returns to the previous one")
                    .padding(.bottom, 6)
            }

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
        .frame(width: labeled ? max(sizeClass.moduleRailWidth, 48 + 114 * typography.scale) : sizeClass.moduleRailWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(LimaTheme.navigationBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace navigation")
    }

    @ViewBuilder
    private func railGroup(_ title: String, destinations: [LimaWorkspaceModule]) -> some View {
        if labeled {
            Text(title)
                .font(.system(size: 8.5, weight: .bold))
                .tracking(0.9)
                .foregroundStyle(LimaTheme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 11)
                .padding(.top, title == "TOOLS" ? 8 : 2)
                .padding(.bottom, 1)
        }

        ForEach(destinations, id: \.self) { module in
            Button { select(module) } label: {
                railLabel(module.title, symbol: module.symbol, selected: module == current, hovered: hovered == module.rawValue)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(KeyEquivalent(Character(module.shortcutNumber)), modifiers: [.command, .option])
            .help("\(module.title) · ⌥⌘\(module.shortcutNumber)")
            .accessibilityLabel(module.title)
            .accessibilityValue(module == current ? "Current workspace" : "")
            .accessibilityAddTraits(module == current ? [.isSelected] : [])
            .onHover { hovered = $0 ? module.rawValue : nil }
        }
    }

    private func railLabel(_ title: String, symbol: String, selected: Bool, hovered: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .resizable()
                .scaledToFit()
                .font(.system(size: 19, weight: selected ? .semibold : .regular))
                .frame(width: 22, height: 22)
                .frame(width: 24)
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
            }
        }
        .foregroundStyle(selected ? LimaTheme.accentInk : LimaTheme.textSecondary)
        .padding(.horizontal, labeled ? 8 : 0)
        .frame(maxWidth: .infinity)
        .frame(minHeight: max(labeled ? 43 : 36, 32 * typography.scale))
        .limaSelection(selected, hovered: hovered, radius: LimaRadius.control)
        .contentShape(RoundedRectangle(cornerRadius: LimaRadius.control))
    }
}
