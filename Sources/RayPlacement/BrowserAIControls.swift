import SwiftUI

/// One shared control surface in Browser and Chat so the same settings have
/// the same meaning wherever a task is started.
struct BrowserAIControls: View {
    @ObservedObject var browser: BrowserWorkspaceModel
    @ObservedObject private var approval = BrowserTaskApprovalState.shared
    @State private var expanded = false

    var body: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: browser.aiControlMode == .off ? "hand.raised.slash" : "sparkles")
                Text(browser.aiControlMode == .off ? "AI off" : approval.displayMode.title)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(LimaTheme.accentSoft, in: Capsule())
            .foregroundStyle(browser.aiControlMode == .off ? LimaTheme.textSecondary : LimaTheme.accentInk)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("AI Browser controls: \(approval.displayMode.title), \(browser.aiControlMode.title)")
        .help("Browser access, independence, and navigation in one place")
        .popover(isPresented: $expanded, arrowEdge: .bottom) { panel }
    }

    var panel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("AI Browser", systemImage: "sparkles").font(.headline)
                Spacer()
                Text(approval.activeRunID == nil ? "Next task" : "Current task")
                    .font(.caption).foregroundStyle(LimaTheme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("How independently should Lima work?").font(.subheadline.weight(.semibold))
                ForEach(BrowserApprovalMode.allCases) { mode in
                    Button { approval.select(mode) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: approval.displayMode == mode ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(approval.displayMode == mode ? LimaTheme.accentInk : LimaTheme.textSecondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(mode.title).font(.callout.weight(.semibold))
                                Text(description(mode)).font(.caption).foregroundStyle(LimaTheme.textSecondary)
                            }
                            Spacer(minLength: 0)
                        }.padding(10).contentShape(Rectangle())
                            .background(approval.displayMode == mode ? LimaTheme.accentSoft : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain)
                }
            }
            Divider()
            Picker("Browser access", selection: $browser.aiControlMode) {
                ForEach(BrowserAIControlMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
            }
            Picker("Navigation", selection: $browser.navigationMode) {
                ForEach(BrowserNavigationMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            Text("Adaptive uses page controls and screenshots as needed. Independent allows routine actions across websites, including canvas input. Payments and protected information still need your involvement.")
                .font(.caption).foregroundStyle(LimaTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
            if let tab = browser.selectedTab, browser.aiControlMode != .off {
                Button(browser.pausedTabIDs.contains(tab.id) ? "Resume AI on this tab" : "Take control of this tab") {
                    if browser.pausedTabIDs.contains(tab.id) { try? browser.resumeAI(on: tab.id) }
                    else { browser.pauseAI(on: tab.id) }
                }.buttonStyle(.bordered).frame(maxWidth: .infinity)
            }
        }.padding(20).frame(width: 390)
            .foregroundStyle(LimaTheme.textPrimary)
            .background(LimaTheme.surfacePrimary)
    }

    private func description(_ mode: BrowserApprovalMode) -> String {
        switch mode {
        case .askForActions: return "Review each navigation and interaction."
        case .autoApproveNonpayment: return "Work on the websites approved for this task."
        case .independent: return "Follow links across sites and perform routine actions without repeated prompts."
        }
    }
}
