import SwiftUI

/// Changes only presentation. The conversation, Browser tabs and Terminal
/// sessions keep their existing owners and keep running while switching.
struct WorkspaceToolSwitcher: View {
    let current: LimaWorkspaceModule
    let conversationID: UUID?
    let select: (LimaWorkspaceModule) -> Void
    @Binding var conversationVisible: Bool
    @ObservedObject private var terminal = AIWorkspaceTerminalCoordinator.shared
    @Environment(\.limaWorkspaceSizeClass) private var sizeClass
    @Environment(\.limaAssistantSplitAvailable) private var canSplit
    private let destinations: [LimaWorkspaceModule] = [.ai, .browser, .terminal]

    private var runningCount: Int {
        terminal.sessions(for: conversationID).filter { $0.state == .running }.count
    }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(destinations, id: \.self) { module in
                Button { select(module) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: module.symbol)
                        Text(module == .ai ? "Chat" : module.title)
                        if module == .terminal && runningCount > 0 {
                            Text("\(runningCount)")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .padding(.horizontal, 4).padding(.vertical, 2)
                                .background(LimaTheme.accentInk.opacity(0.15), in: Capsule())
                        }
                    }
                    .limaFont(.system(size: 11, weight: .medium))
                    .foregroundStyle(current == module ? LimaTheme.accentInk : LimaTheme.textSecondary)
                    .padding(.horizontal, sizeClass == .compact ? 8 : 11)
                    .frame(height: 29)
                    .background(current == module ? LimaTheme.surfaceSelected : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(current == module ? .isSelected : [])
                .accessibilityLabel("Show " + (module == .ai ? "Conversation" : module.title))
                .help("Switch to \(module.title) · keeps your task running")
            }
            Spacer(minLength: 0)
            if current != .ai && canSplit {
                Button { conversationVisible.toggle() } label: {
                    Image(systemName: conversationVisible ? "sidebar.left" : "bubble.left")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help(conversationVisible ? "Hide conversation" : "Show conversation beside this tool")
                .accessibilityLabel("Toggle conversation")
                .keyboardShortcut("\\", modifiers: .command)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(LimaTheme.surfaceSecondary.opacity(0.8))
        .accessibilityIdentifier("workspace.tool-switcher")
    }
}
