import AppKit
import SwiftUI

/// Presentation only: search ranking, grants, and command execution stay in the launcher model.
enum LauncherSearchDesign {
    static func railWidth(for width: CGFloat) -> CGFloat { width >= 880 ? 164 : 52 }
    static func showsInspector(at width: CGFloat) -> Bool { width >= 900 }
    static let inspectorWidth: CGFloat = 278

    static func title(for item: LauncherItem) -> String {
        item.id == "builtin.notes" ? "Open Notes" : item.title
    }

    static func tint(for item: LauncherItem) -> AppAccentTheme {
        let id = item.id
        if id.contains("dictation") { return .violet }
        if id.contains("note") { return .orange }
        if id.contains("clipboard") { return .mint }
        if id.contains("password") { return .rose }
        if id.contains("ai-chat") { return .violet }
        if id.contains("extension") { return .cyan }
        if id.contains("file") { return .blue }
        return .blue
    }

    static func primaryTitle(for item: LauncherItem) -> String {
        switch item.action {
        case .launchApplication, .openFile, .fileAction, .revealFile, .openURL,
             .note, .shelfItem, .extensionOutput, .universalSearch: return "Open"
        case .copyText, .clipboardEntry: return "Copy"
        case .pasteText: return "Paste"
        case .replaceSelectedText: return "Replace"
        case .saveSelectionToQuickNote: return "Save"
        case .checkSelectedText, .applicationOperation: return "Review"
        case .enterMode: return "Open"
        case .system(let action):
            switch action {
            case .openNotes, .openAIChat, .openQuickNote, .openSettings, .openContextShelf: return "Open"
            default: return "Run"
            }
        default: return "Run"
        }
    }
}

@MainActor
struct LauncherSearchWorkspace: View {
    @ObservedObject var model: LauncherViewModel
    let openWorkspace: (LimaWorkspaceModule) -> Void
    let openSettings: () -> Void
    let createNote: () -> Void
    let dismiss: () -> Void
    @FocusState private var searchFocused: Bool
    @State private var hoveredID: String?
    @State private var showingDetails = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var idle: Bool { model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var selection: LauncherItem? {
        guard let item = model.selectedItem, model.isActionable(item) else { return nil }
        return item
    }

    var body: some View {
        GeometryReader { geometry in
            let expanded = geometry.size.width >= 880
            let hasInspector = LauncherSearchDesign.showsInspector(at: geometry.size.width)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    navigation(expanded: expanded)
                        .frame(width: LauncherSearchDesign.railWidth(for: geometry.size.width))
                    Rectangle().fill(LimaTheme.borderSubtle).frame(width: 0.5)
                    VStack(spacing: 18) {
                        searchField
                        HStack(alignment: .top, spacing: 18) {
                            results
                            if hasInspector {
                                Rectangle().fill(LimaTheme.borderSubtle).frame(width: 0.5)
                                ScrollView {
                                    if let item = selection { inspector(item) }
                                    else { emptyInspector }
                                }
                                .frame(width: LauncherSearchDesign.inspectorWidth)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .padding(expanded ? 20 : 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LimaTheme.surfacePrimary.opacity(0.88))
                }
                footer(wide: expanded, hasInspector: hasInspector)
            }
            .background(LimaTheme.windowBackground.opacity(0.9))
        }
        .onAppear { searchFocused = true }
        .onChange(of: model.focusGeneration) { _ in searchFocused = true }
        .sheet(isPresented: $showingDetails) {
            VStack(spacing: 0) {
                HStack {
                    Text("Selected result").limaFont(.headline)
                    Spacer()
                    Button("Done") { showingDetails = false }.keyboardShortcut(.cancelAction)
                }.padding(16)
                ScrollView {
                    if let item = selection { inspector(item) }
                    else { emptyInspector }
                }.padding(16)
            }.frame(width: 340, height: 580)
        }
        .background {
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden().accessibilityHidden(true)
        }
        .accessibilityIdentifier("lima-search-workspace")
    }

    private var searchField: some View {
        HStack(spacing: 13) {
            Menu {
                Button("Everything") { model.query = UniversalSearchCoordinator.parse(model.query).query }
                ForEach(["app", "command", "file", "note", "dictation", "workflow", "clipboard"], id: \.self) { scope in
                    Button(scope.capitalized) {
                        model.query = scope + ": " + UniversalSearchCoordinator.parse(model.query).query
                        searchFocused = true
                    }
                }
                Divider()
                Button("Files…") { model.enter(.files) }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 23, weight: .regular))
                    .foregroundStyle(LimaTheme.textSecondary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Narrow search: apps, commands, files, notes, dictation, workflows, or clipboard")
            .accessibilityLabel("Search scope")
            ZStack(alignment: .leading) {
                if model.query.isEmpty {
                    Text("Search or run a command")
                        .foregroundStyle(LimaTheme.textSecondary)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TextField("", text: $model.query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { model.executeSelected() }
                    .accessibilityLabel("Search commands, apps, and local content")
            }
            .limaFont(.system(size: 19))
            if model.isSearching { ProgressView().controlSize(.small) }
            if !model.query.isEmpty {
                Button { model.query = ""; searchFocused = true } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(LimaTheme.textSecondary)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            } else {
                keycap("⌘ F")
            }
        }
        .padding(.horizontal, 17)
        .frame(height: 58)
        .background(LimaTheme.fieldBackground, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(
            searchFocused ? LimaTheme.fieldFocusedBorder.opacity(0.65) : LimaTheme.borderStrong,
            lineWidth: LimaDesign.hairlineWidth))
    }

    private func navigation(expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                LimaWayfinderMark()
                if expanded {
                    Text("Lima").limaFont(.system(size: 21, weight: .semibold))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, expanded ? 12 : 3)
            .padding(.top, 22)
            .padding(.bottom, 14)
            ScrollView {
                VStack(spacing: 7) {
                    navButton("Search", symbol: "magnifyingglass", selected: true, expanded: expanded) {
                        model.query = ""; searchFocused = true
                    }
                    ForEach([LimaWorkspaceModule.notes, .ai, .context, .grammar, .dictation, .extensions, .clipboard], id: \.self) { module in
                        navButton(module.title, symbol: module.symbol, expanded: expanded) { openWorkspace(module) }
                    }
                }
            }
            Spacer(minLength: 0)
            navButton("Settings", symbol: "gearshape", expanded: expanded, action: openSettings)
                .padding(.bottom, 12)
        }
        .padding(.horizontal, expanded ? 10 : 5)
        .background(LimaTheme.surfaceSecondary.opacity(0.7))
    }

    private func navButton(_ title: String, symbol: String, selected: Bool = false,
                           expanded: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbol).font(.system(size: 20, weight: .regular)).frame(width: 24)
                if expanded { Text(title).limaFont(.callout.weight(selected ? .semibold : .medium)); Spacer(minLength: 0) }
            }
            .foregroundStyle(selected ? LimaTheme.accentInk : LimaTheme.textSecondary)
            .padding(.horizontal, expanded ? 10 : 4)
            .frame(maxWidth: .infinity, minHeight: 43)
            .background(selected ? LimaTheme.surfaceSelected : .clear, in: RoundedRectangle(cornerRadius: 11))
            .overlay(alignment: .leading) {
                if selected { Capsule().fill(LimaTheme.accentInk).frame(width: 3, height: 23) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var results: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    if let context = model.contextualSelectionText {
                        Label("For your selection", systemImage: "text.cursor").limaFont(.callout.weight(.semibold))
                        Text(String(context.prefix(140))).limaFont(.caption)
                            .foregroundStyle(LimaTheme.textSecondary).lineLimit(2).padding(.bottom, 8)
                    }
                    Text(idle ? "Suggested for you" : "Search results")
                        .limaFont(.callout.weight(.medium))
                        .foregroundStyle(LimaTheme.textSecondary)
                        .padding(.horizontal, 10).padding(.bottom, 5)
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                        if idle, index == 6 {
                            Divider().padding(.vertical, 12)
                            Text("More from your workspace").limaFont(.callout.weight(.medium))
                                .foregroundStyle(LimaTheme.textSecondary).padding(.horizontal, 10)
                        }
                        resultRow(item, index: index).id(item.id)
                    }
                }
                .padding(.bottom, 12)
            }
            .onChange(of: model.navigationGeneration) { _ in
                guard let item = model.selectedItem else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                    scroll.scrollTo(item.id, anchor: .center)
                }
            }
            .onChange(of: model.query) { _ in
                if let first = model.results.first { scroll.scrollTo(first.id, anchor: .top) }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultRow(_ item: LauncherItem, index: Int) -> some View {
        let selected = model.selectedIndex == index && model.isActionable(item)
        return HStack(spacing: 0) {
            Button { model.select(index) } label: {
                HStack(spacing: 12) {
                    SearchResultIcon(item: item, size: 39)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LauncherSearchDesign.title(for: item))
                            .limaFont(.system(size: 14, weight: .semibold))
                            .foregroundStyle(LimaTheme.textPrimary).lineLimit(2)
                        Text(item.subtitle).limaFont(.caption)
                            .foregroundStyle(LimaTheme.textSecondary).lineLimit(2)
                    }
                    Spacer(minLength: 3)
                    if item.accessory == "Recent" || item.accessory == "Favorite" {
                        Image(systemName: item.accessory == "Recent" ? "clock" : "pin")
                            .font(.system(size: 11)).foregroundStyle(LimaTheme.textTertiary)
                    }
                }
                .padding(.leading, 12).padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!model.isActionable(item))
            .accessibilityLabel(LauncherSearchDesign.title(for: item))
            .accessibilityHint("Select to preview; Return runs the selected result")
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            if model.isActionable(item) {
                Button { model.select(index); model.executeSelected() } label: {
                    keycap(selected ? "↩" : (index < 9 ? "⌘ \(index + 1)" : "↗"))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .help(LauncherSearchDesign.primaryTitle(for: item) + " " + item.title)
                .accessibilityLabel(LauncherSearchDesign.primaryTitle(for: item) + " " + item.title)
            }
        }
        .background(selected ? LimaTheme.surfaceSelected : (hoveredID == item.id ? LimaTheme.surfaceSecondary : .clear),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? LimaTheme.borderStrong : .clear, lineWidth: 0.5))
        .onHover { hoveredID = $0 ? item.id : (hoveredID == item.id ? nil : hoveredID) }
    }

    private func inspector(_ item: LauncherItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(LauncherSearchDesign.tint(for: item).primary.opacity(0.1))
                    .frame(width: 144, height: 112).rotationEffect(.degrees(-11))
                RoundedRectangle(cornerRadius: 21)
                    .fill(LauncherSearchDesign.tint(for: item).primary.opacity(0.12))
                    .frame(width: 126, height: 109).rotationEffect(.degrees(9))
                if item.id == "builtin.notes" || item.id == "builtin.quick-note" {
                    SearchNoteIllustration()
                } else {
                    SearchResultIcon(item: item, size: 86)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 138)
            .accessibilityHidden(true)
            Text(LauncherSearchDesign.title(for: item)).limaFont(.system(size: 23, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(item.subtitle).limaFont(.body).foregroundStyle(LimaTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button { model.executeSelected(); showingDetails = false } label: {
                HStack {
                    Text(LauncherSearchDesign.primaryTitle(for: item))
                    Spacer()
                    Image(systemName: "arrow.turn.down.left")
                }.limaFont(.callout.weight(.semibold)).padding(11)
                    .frame(maxWidth: .infinity)
                    .background(LimaTheme.surfaceSelected, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain).foregroundStyle(LimaTheme.accentInk)
            Divider()
            Text("Quick actions").limaFont(.callout.weight(.medium)).foregroundStyle(LimaTheme.textSecondary)
            if item.id == "builtin.notes" || item.id == "builtin.quick-note" {
                detailButton("Create new note", symbol: "plus") { createNote(); showingDetails = false }
                detailButton("Search local notes", symbol: "magnifyingglass") {
                    showingDetails = false; model.query = "note:"; searchFocused = true
                }
            }
            ForEach(model.actionPanelActions(for: item).filter { $0.role == .secondary && $0.id != "shelf" }.prefix(3)) { action in
                detailButton(action.title, symbol: action.symbol) {
                    model.executeAction(action); showingDetails = false
                }
            }
            detailButton("All actions", symbol: "ellipsis.circle") {
                showingDetails = false
                model.openActionPanel(for: item)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LimaTheme.surfaceRaised.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(LimaTheme.borderSubtle, lineWidth: 0.5))
    }

    private var emptyInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 32)).foregroundStyle(LimaTheme.accentInk)
            Text("Find your next action").limaFont(.headline)
            Text("Search commands, applications, notes, and local content. Select a result to see its actions.")
                .limaFont(.callout).foregroundStyle(LimaTheme.textSecondary)
            detailButton("Clear search", symbol: "arrow.counterclockwise") { model.query = ""; searchFocused = true }
        }.padding(20)
    }

    private func detailButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .limaFont(.callout).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 7).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(LimaTheme.textPrimary)
    }

    private func footer(wide: Bool, hasInspector: Bool) -> some View {
        HStack(spacing: 14) {
            if wide {
                Image(systemName: "bolt.fill").font(.system(size: 23)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("A faster, calmer you.").limaFont(.caption.weight(.medium))
                    Text("Search. Command. Create.").limaFont(.caption2).foregroundStyle(LimaTheme.textSecondary)
                }
            }
            Spacer(minLength: 0)
            if wide { HStack(spacing: 5) { keycap("↑ ↓"); Text("Navigate") } }
            Button { model.enter(.history) } label: { Label("History", systemImage: "clock") }
                .buttonStyle(.plain).help("Open command history")
            if !hasInspector {
                Button { showingDetails = true } label: { Image(systemName: "sidebar.right") }
                    .buttonStyle(.plain).disabled(selection == nil)
                    .help("Preview selected result").accessibilityLabel("Preview selected result")
            }
            Button { model.openActionPanel() } label: {
                HStack(spacing: 5) { if wide { keycap("⌘ K") }; Text("Actions") }
            }.buttonStyle(.plain).disabled(selection == nil)
            Button(action: dismiss) {
                HStack(spacing: 5) { keycap("esc"); if wide { Text("Close") } }
            }.buttonStyle(.plain).accessibilityLabel("Close Search")
        }
        .limaFont(.caption).foregroundStyle(LimaTheme.textSecondary)
        .padding(.horizontal, wide ? 20 : 12)
        .frame(height: wide ? 58 : 44)
        .background(LimaTheme.surfaceSecondary.opacity(0.85))
        .overlay(alignment: .top) { Rectangle().fill(LimaTheme.borderSubtle).frame(height: 0.5) }
    }

    private func keycap(_ value: String) -> some View {
        Text(value).font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(LimaTheme.textSecondary)
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(LimaTheme.fieldBackground, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(LimaTheme.borderSubtle, lineWidth: 0.5))
            .fixedSize()
    }
}

/// Native vector artwork: no generated assets or external image dependency.
private struct SearchNoteIllustration: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13)
                .fill(Color(red: 0.64, green: 0.59, blue: 0.48))
                .frame(width: 93, height: 87).rotationEffect(.degrees(-12)).offset(x: -20, y: 9)
            RoundedRectangle(cornerRadius: 13)
                .fill(Color(red: 0.73, green: 0.73, blue: 0.75))
                .frame(width: 93, height: 94).rotationEffect(.degrees(10)).offset(x: 24, y: 5)
            VStack(alignment: .leading, spacing: 10) {
                ForEach([68.0, 58.0, 64.0, 38.0], id: \.self) { width in
                    Capsule().fill(Color(red: 0.62, green: 0.57, blue: 0.48).opacity(0.5))
                        .frame(width: width, height: 4)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(width: 108, height: 108)
            .background(LinearGradient(colors: [Color(red: 1, green: 0.98, blue: 0.92),
                                                Color(red: 0.84, green: 0.81, blue: 0.75)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(0.7), lineWidth: 1))
            .rotationEffect(.degrees(-3))
            .shadow(color: .black.opacity(0.12), radius: 7, y: 5)
        }
    }
}

private struct SearchResultIcon: View {
    let item: LauncherItem
    let size: CGFloat
    var body: some View {
        Group {
            switch item.icon {
            case .system(let symbol):
                LimaFeatureIcon(symbol: symbol, tint: LauncherSearchDesign.tint(for: item), size: size)
            case .application(let url), .file(let url):
                Image(nsImage: LauncherIconCache.shared.image(for: url)).resizable().scaledToFit()
            case .text(let text):
                Text(text).font(.system(size: size * 0.72))
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}
