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
    static let primaryDestinations: [LimaWorkspaceModule] = [.home, .notes, .ai, .dictation, .extensions, .clipboard]

    var title: String {
        switch self {
        case .home: "Home"
        case .notes: "Notes"
        case .ai: "AI"
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
        case .dictation: "4"
        case .extensions: "5"
        case .clipboard: "6"
        case .terminal: "7"
        case .formatter: "8"
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
    @State private var hovered: String?
    @ObservedObject private var typography = AppTypography.shared

    private var labeled: Bool { sizeClass == .expanded }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                LimaWayfinderMark()
                if labeled {
                    Text("LIMA").font(.system(size: 10, weight: .bold)).tracking(1.8)
                        .foregroundStyle(LimaTheme.textSecondary)
                }
            }
            .frame(height: 38)
            .frame(maxWidth: .infinity, alignment: labeled ? .leading : .center)
            .padding(.horizontal, labeled ? 9 : 0)
            .padding(.bottom, 8)

            ForEach(LimaWorkspaceModule.primaryDestinations, id: \.self) { module in
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
                Text("⌥⌘ 1–6").font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(LimaTheme.textTertiary)
                    .help("Switch workspaces; ⌥⌘0 returns to the previous one")
                    .padding(.bottom, 6)
            }

            Button(action: openSettings) {
                railLabel("Settings", symbol: "gearshape", selected: false, hovered: hovered == "settings")
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityLabel("Open Settings")
            .onHover { hovered = $0 ? "settings" : nil }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 8)
        .frame(width: labeled ? max(sizeClass.moduleRailWidth, 48 + 80 * typography.scale) : sizeClass.moduleRailWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(LimaTheme.navigationBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace navigation")
    }

    private func railLabel(_ title: String, symbol: String, selected: Bool, hovered: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: selected ? .semibold : .medium))
                .frame(width: 24)
            if labeled {
                VStack(alignment: .leading, spacing: 1) {
                    if symbol == "arrow.uturn.backward", previous != nil {
                        Text("RETURN TO").font(.system(size: 8, weight: .semibold)).tracking(0.6)
                            .foregroundStyle(LimaTheme.textTertiary)
                    }
                    Text(title).limaFont(.system(size: 11.5, weight: selected ? .semibold : .medium))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(selected ? LimaTheme.accentInk : LimaTheme.textSecondary)
        .padding(.horizontal, labeled ? 8 : 0)
        .frame(maxWidth: .infinity)
        .frame(minHeight: max(36, 28 * typography.scale))
        .limaSelection(selected, hovered: hovered, radius: LimaRadius.control)
        .contentShape(RoundedRectangle(cornerRadius: LimaRadius.control))
    }
}
