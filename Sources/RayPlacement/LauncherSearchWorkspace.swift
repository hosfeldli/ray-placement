import AppKit
import SwiftUI

/// Presentation only: search ranking, grants, and command execution stay in the launcher model.
enum LauncherSearchDesign {
    /// Search remains a launcher; result details are optional rather than a permanent third pane.
    static func canShowInspector(at width: CGFloat) -> Bool { width >= 960 }
    static let inspectorWidth: CGFloat = 250

    /// Keyboard navigation only scrolls when the selected row is outside the
    /// visible results viewport. A lazy row with no frame is off-screen.
    static func scrollAnchor(for rowFrame: CGRect?, viewportHeight: CGFloat) -> UnitPoint? {
        guard viewportHeight > 0, let rowFrame else { return .center }
        if rowFrame.minY < 0 { return .top }
        if rowFrame.maxY > viewportHeight { return .bottom }
        return nil
    }

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
            case .openNotes, .openAIChat, .openQuickNote, .openSettings, .openContextShelf, .openScreenshotStudio, .openAudioOutput: return "Open"
            default: return "Run"
            }
        default: return "Run"
        }
    }
}

private struct SearchResultFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct SearchResultsViewportHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

@MainActor
struct LauncherSearchWorkspace: View {
    @ObservedObject var model: LauncherViewModel
    let aiChatModel: AIChatViewModel
    let openWorkspace: (LimaWorkspaceModule) -> Void
    let openSettings: () -> Void
    let createNote: () -> Void
    let dismiss: () -> Void
    @FocusState private var searchFocused: Bool
    @State private var hoveredID: String?
    @State private var showingDetails = false
    @State private var showingInspector = false
    @State private var resultRowFrames: [String: CGRect] = [:]
    @State private var resultsViewportHeight: CGFloat = 0
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.limaTestReduceTransparency) private var testReduceTransparency

    private var opaque: Bool { reduceTransparency || (LimaTestEnvironment.isEnabled && testReduceTransparency) }
    private var idle: Bool { model.searchPhase == .idle }
    private var selection: LauncherItem? {
        guard let item = model.selectedItem, model.isActionable(item) else { return nil }
        return item
    }

    var body: some View {
        GeometryReader { geometry in
            let canShowInspector = LauncherSearchDesign.canShowInspector(at: geometry.size.width)
            let hasInspector = canShowInspector && showingInspector
            let wide = geometry.size.width >= 680
            VStack(spacing: 0) {
                LimaWindowDragRegion()
                    .frame(maxWidth: .infinity)
                    .frame(height: 12)
                VStack(spacing: idle ? 8 : 12) {
                    // This control stays in the same structural position while
                    // the controls and results around it change phase.
                    searchField(wide: wide)
                    if idle {
                        idleKeyboardHints
                    } else if model.isAudioOutputPickerPresented {
                        AudioOutputPickerView(model: model.audioOutputPicker,
                                              cancel: { model.closeAudioOutputPicker() },
                                              switched: { model.closeAudioOutputPicker() })
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        HStack(alignment: .top, spacing: 14) {
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
                }
                .padding(.horizontal, wide ? 16 : 12)
                .padding(.top, 0)
                .padding(.bottom, idle ? 1 : (wide ? 16 : 12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                if !idle && !model.isAudioOutputPickerPresented {
                    footer(wide: wide, canShowInspector: canShowInspector)
                }
            }
            .background(LimaTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: LimaRadius.launcherWindow, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LimaRadius.launcherWindow).strokeBorder(LimaTheme.borderSubtle, lineWidth: 0.5))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var idleKeyboardHints: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                keycap("↩")
                Text("Search or run")
            }
            Rectangle().fill(LimaTheme.borderSubtle).frame(width: 1, height: 13)
            HStack(spacing: 5) {
                keycap("esc")
                Text("Close")
            }
        }
        .limaFont(.caption)
        .foregroundStyle(LimaTheme.textSecondary)
        .padding(.horizontal, 12)
        .frame(height: 27)
        .background(LimaTheme.surfaceSecondary.opacity(opaque ? 1 : 0.9),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(LimaTheme.borderSubtle, lineWidth: 0.6))
        .accessibilityElement(children: .combine)
    }

    private func searchField(wide: Bool) -> some View {
        VStack(spacing: 7) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(idle ? LimaTheme.textPrimary : LimaTheme.accentInk)
                    .frame(width: 23)
                    .accessibilityHidden(true)
                ZStack(alignment: .leading) {
                    if model.query.isEmpty {
                        Text(wide ? "Search, ask, or run a command…" : "Search or ask Lima…")
                            .foregroundStyle(LimaTheme.textSecondary)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    TextField("", text: $model.query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onSubmit(submitSearch)
                        .accessibilityLabel("Search commands, apps, and local content")
                        .accessibilityIdentifier("lima-search-input")
                }
                .limaFont(.system(size: 17))
                if !idle && model.isSearching {
                    ProgressView().controlSize(.small)
                }
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                        searchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(LimaTheme.textSecondary)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
                }
            }
            .frame(height: 50)
            if idle {
                HStack(spacing: 8) {
                    quickActions(wide: wide)
                    Spacer(minLength: 4)

                }
                .frame(height: 39)
                .padding(.bottom, 6)
            }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 0)
        .background(LimaTheme.surfaceSecondary,
                    in: RoundedRectangle(cornerRadius: idle ? 20 : LimaRadius.searchField, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: idle ? 12 : LimaRadius.searchField)
            .strokeBorder(searchFocused ? LimaTheme.accentInk.opacity(0.35) : LimaTheme.borderSubtle, lineWidth: 0.7))
    }

    private func quickActions(wide: Bool) -> some View {
        HStack(spacing: 7) {
            quickAction("Assistant", symbol: "sparkles", compact: !wide) { openWorkspace(.ai) }
            quickAction("Notes", symbol: "note.text", compact: !wide) { openWorkspace(.notes) }
            quickAction("Recordings", symbol: "waveform", compact: !wide) { openWorkspace(.dictation) }
            Menu {
                ForEach(LimaWorkspaceModule.primaryDestinations, id: \.self) { module in
                    Button(module.title, systemImage: module.symbol) { openWorkspace(module) }
                }
                Divider()
                Button("Files", systemImage: "doc") { model.enter(.files) }
                Button("Clipboard", systemImage: "doc.on.clipboard") { model.enter(.clipboard) }
                Button("Writing tools", systemImage: "textformat.abc") { openWorkspace(.grammar) }
                Button("Formatter", systemImage: "curlybraces") { openWorkspace(.formatter) }
                Menu("Search in") {
                    Button("Everything") { model.query = UniversalSearchCoordinator.parse(model.query).query }
                    ForEach(["app", "command", "file", "note", "dictation", "chat", "workspace", "context", "clipboard"], id: \.self) { scope in
                        Button(scope.capitalized) {
                            model.query = scope + ": " + UniversalSearchCoordinator.parse(model.query).query
                            searchFocused = true
                        }
                    }
                }
                Divider()
                Button("Capture image", systemImage: "viewfinder") {
                    model.executeCommand(id: "builtin.quick-capture-region")
                }
                Button("Capture text", systemImage: "text.viewfinder") {
                    model.executeCommand(id: "builtin.text-reader-region")
                }
                Button("Capture history", systemImage: "photo.on.rectangle") {
                    model.executeCommand(id: "builtin.screenshot-studio")
                }
                Button("Settings", systemImage: "gearshape", action: openSettings)
            } label: {
                Group {
                    if wide { Label("More", systemImage: "ellipsis") }
                    else { Image(systemName: "square.stack.3d.up") }
                }
                .limaFont(.system(size: 12, weight: .medium))
                .padding(.horizontal, wide ? 9 : 0)
                .frame(width: wide ? nil : 35, height: 35)
                .background(LimaTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(LimaTheme.borderSubtle, lineWidth: 0.6))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .tint(LimaTheme.textSecondary)
            .accessibilityLabel("Workspace options and search scope")
        }
        .foregroundStyle(LimaTheme.textSecondary)
        .frame(height: 36)
    }

    private func submitSearch() {
        if idle { openWorkspace(.ai) }
        else { model.executeSelected() }
    }

    private func quickAction(_ title: String, symbol: String, compact: Bool, selected: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if compact { Image(systemName: symbol) }
                else { Label(title, systemImage: symbol) }
            }
            .limaFont(.system(size: 12, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? LimaTheme.accentInk : LimaTheme.textSecondary)
            .padding(.horizontal, compact ? 0 : 10)
            .frame(width: compact ? 32 : nil, height: 32)
            .background(selected ? LimaTheme.accentSoft : Color.clear,
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(
                selected ? settings.accentTheme.primary.opacity(0.75) : .clear,
                lineWidth: selected ? 0.9 : 0.5))
        }
        .buttonStyle(.plain)
        .help("Open \(title)")
        .accessibilityLabel("Open \(title)")
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
                    HStack {
                        Menu {
                            Button("Everything") { model.query = UniversalSearchCoordinator.parse(model.query).query }
                            ForEach(["app", "command", "file", "note", "dictation", "chat", "context", "clipboard"], id: \.self) { scope in
                                Button(scope.capitalized) { model.query = scope + ": " + UniversalSearchCoordinator.parse(model.query).query; searchFocused = true }
                            }
                        } label: { Label(UniversalSearchCoordinator.parse(model.query).prefix?.capitalized ?? "Results", systemImage: "line.3.horizontal.decrease") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .accessibilityLabel("Filter search results")
                            .limaFont(.callout.weight(.semibold))
                        Spacer()
                        if !model.results.isEmpty {
                            Text("\(model.results.count) found").limaFont(.caption)
                        }
                    }
                    .foregroundStyle(LimaTheme.textSecondary)
                    .padding(.horizontal, 10).padding(.bottom, 5)
                    if model.results.isEmpty && !model.isSearching {
                        Label("No matches. Try a different search or scope.", systemImage: "magnifyingglass")
                            .limaFont(.callout)
                            .foregroundStyle(LimaTheme.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 100)
                    }
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                        resultRow(item, index: index)
                            .background {
                                GeometryReader { row in
                                    Color.clear.preference(
                                        key: SearchResultFramePreferenceKey.self,
                                        value: [item.id: row.frame(in: .named("lima-search-results"))]
                                    )
                                }
                            }
                            .id(item.id)
                    }
                }
                .padding(.bottom, 12)
            }
            .coordinateSpace(name: "lima-search-results")
            .background {
                GeometryReader { viewport in
                    Color.clear.preference(key: SearchResultsViewportHeightPreferenceKey.self,
                                           value: viewport.size.height)
                }
            }
            .onPreferenceChange(SearchResultFramePreferenceKey.self) {
                resultRowFrames = $0
                recordVisibleResultAnchor()
            }
            .onPreferenceChange(SearchResultsViewportHeightPreferenceKey.self) {
                resultsViewportHeight = $0
                recordVisibleResultAnchor()
            }
            .onAppear { restoreSearchScrollIfNeeded(scroll) }
            .onChange(of: model.results.map { $0.id }) { _ in restoreSearchScrollIfNeeded(scroll) }
            .onChange(of: model.isSearching) { _ in restoreSearchScrollIfNeeded(scroll) }
            .onChange(of: model.navigationGeneration) { _ in
                guard let item = model.selectedItem, model.isActionable(item),
                      let anchor = LauncherSearchDesign.scrollAnchor(
                        for: resultRowFrames[item.id], viewportHeight: resultsViewportHeight
                      ) else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                    scroll.scrollTo(item.id, anchor: anchor)
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }

    private func recordVisibleResultAnchor() {
        guard resultsViewportHeight > 0 else { return }
        let top = resultRowFrames
            .filter { $0.value.maxY > 0 && $0.value.minY < resultsViewportHeight }
            .min { $0.value.minY < $1.value.minY }
        if let id = top?.key { model.recordSearchScrollAnchor(id) }
    }

    private func restoreSearchScrollIfNeeded(_ scroll: ScrollViewProxy) {
        guard !model.isSearching,
              let id = model.scrollRestorationAnchorID,
              model.results.contains(where: { $0.id == id }) else { return }
        DispatchQueue.main.async {
            guard model.scrollRestorationAnchorID == id else { return }
            scroll.scrollTo(id, anchor: .top)
            model.consumeSearchScrollRestorationAnchor(id)
        }
    }

    private func resultRow(_ item: LauncherItem, index: Int) -> some View {
        let selected = model.selectedIndex == index && model.isActionable(item)
        return HStack(spacing: 0) {
            Button { model.select(index) } label: {
                HStack(spacing: 12) {
                    SearchResultIcon(item: item, size: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LauncherSearchDesign.title(for: item))
                            .limaFont(.system(size: 14, weight: .semibold))
                            .foregroundStyle(LimaTheme.textPrimary).lineLimit(1)
                            .frame(height: 18, alignment: .leading)
                        Text(item.subtitle).limaFont(.caption)
                            .foregroundStyle(LimaTheme.textSecondary).lineLimit(1)
                            .frame(height: 16, alignment: .leading)
                    }
                    Spacer(minLength: 3)
                    if item.accessory == "Recent" || item.accessory == "Favorite" {
                        Image(systemName: item.accessory == "Recent" ? "clock" : "pin")
                            .font(.system(size: 11)).foregroundStyle(LimaTheme.textTertiary)
                    }
                }
                .padding(.leading, 12).padding(.vertical, 8)
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
        .frame(height: 56)
        .background(selected ? LimaTheme.surfaceSelected : (hoveredID == item.id ? LimaTheme.surfaceSecondary : .clear),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? LimaTheme.borderStrong : .clear, lineWidth: 0.5))
        .onHover { hoveredID = $0 ? item.id : (hoveredID == item.id ? nil : hoveredID) }
    }

    private func inspector(_ item: LauncherItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SearchResultIcon(item: item, size: 40).padding(.vertical, 8)
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

    private func footer(wide: Bool, canShowInspector: Bool) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                keycap("↑ ↓")
                if wide { Text("Navigate") }
            }
            HStack(spacing: 5) {
                keycap("↩")
                if wide { Text("Open") }
            }
            Spacer(minLength: 0)
            Button { model.enter(.history) } label: {
                if wide { Label("History", systemImage: "clock") }
                else { Image(systemName: "clock") }
            }
            .buttonStyle(.plain)
            .help("Open command history")

            Button {
                if canShowInspector { showingInspector.toggle() }
                else { showingDetails = true }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: showingInspector && canShowInspector ? "sidebar.right.fill" : "sidebar.right")
                    if wide { Text(showingInspector && canShowInspector ? "Hide details" : "Details") }
                }
            }
            .buttonStyle(.plain)
            .disabled(selection == nil)
            .help("Preview selected result")
            .accessibilityLabel("Preview selected result")

            Button { model.openActionPanel() } label: {
                HStack(spacing: 5) {
                    if wide { keycap("⌘ K") }
                    if wide { Text("Actions") } else { Image(systemName: "ellipsis.circle") }
                }
            }
            .buttonStyle(.plain)
            .disabled(selection == nil)
            .help("Open actions for the selected result")

            Button(action: dismiss) {
                HStack(spacing: 5) {
                    keycap("esc")
                    if wide { Text("Close") }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Search")
        }
        .limaFont(.caption)
        .foregroundStyle(LimaTheme.textSecondary)
        .padding(.horizontal, wide ? 16 : 12)
        .frame(height: wide ? 46 : 44)
        .background(LimaTheme.surfaceSecondary.opacity(
            reduceTransparency ? 1 : settings.glassStyle.baseOpacity * 0.8
        ))
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

private struct SearchResultIcon: View {
    let item: LauncherItem
    let size: CGFloat
    var body: some View {
        Group {
            switch item.icon {
            case .system(let symbol):
                Image(systemName: symbol).font(.system(size: size * 0.62)).foregroundStyle(LimaTheme.accentInk)
            case .application(let url), .file(let url):
                Image(nsImage: LauncherIconCache.shared.image(for: url)).resizable().scaledToFit()
            case .text(let text):
                Text(text).font(.system(size: size * 0.72))
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}
