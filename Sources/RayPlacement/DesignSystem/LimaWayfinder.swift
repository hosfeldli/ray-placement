import SwiftUI

/// Navigation remembers destinations, never editor content or credentials.
struct LimaWorkspaceNavigation: Equatable {
    private(set) var current: LimaWorkspaceModule = .notes
    private(set) var previous: LimaWorkspaceModule?

    mutating func select(_ module: LimaWorkspaceModule) {
        guard module != current else { return }
        previous = current
        current = module
    }
}

extension LimaWorkspaceModule {
    var title: String {
        switch self {
        case .notes: "Notes"
        case .ai: "AI"
        case .dictation: "Dictation"
        case .terminal: "Terminal"
        case .formatter: "Formatter"
        }
    }

    var symbol: String {
        switch self {
        case .notes: "note.text"
        case .ai: "sparkles"
        case .dictation: "waveform"
        case .terminal: "terminal"
        case .formatter: "wand.and.stars"
        }
    }

    /// Explicit assignments keep muscle memory stable if enum order changes.
    var shortcutNumber: String {
        switch self {
        case .notes: "1"
        case .ai: "2"
        case .dictation: "3"
        case .terminal: "4"
        case .formatter: "5"
        }
    }
}

/// A quiet, typographic identity. No bitmap, blur, animation, or new asset.
struct LimaWayfinderMark: View {
    var body: some View {
        Text("L")
            .font(.system(size: 16, weight: .black, design: .rounded))
            .foregroundStyle(LimaTheme.accentInk)
            .frame(width: 28, height: 28)
            .background(LimaTheme.accentSoft, in: PrismaticPanelShape(cut: 6))
            .overlay(alignment: .topTrailing) {
                Circle().fill(LimaTheme.accentInk).frame(width: 3, height: 3).padding(5)
            }
            .accessibilityHidden(true)
    }
}

/// Shared by production and the UI Lab; it never constructs workspace services.
struct LimaWayfinderRail: View {
    let current: LimaWorkspaceModule
    let previous: LimaWorkspaceModule?
    let sizeClass: LimaWorkspaceSizeClass
    let select: (LimaWorkspaceModule) -> Void
    let openShelf: () -> Void
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

            ForEach(LimaWorkspaceModule.allCases, id: \.self) { module in
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
                Text("⌥⌘ 1–5").font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(LimaTheme.textTertiary)
                    .help("Switch workspaces; ⌥⌘0 returns to the previous one")
                    .padding(.bottom, 6)
            }

            Button(action: openShelf) {
                railLabel("Shelf", symbol: "tray.full", selected: false, hovered: hovered == "shelf")
            }
            .buttonStyle(.plain)
            .help("Context Shelf · carry content between tools")
            .accessibilityLabel("Open Context Shelf")
            .onHover { hovered = $0 ? "shelf" : nil }

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
