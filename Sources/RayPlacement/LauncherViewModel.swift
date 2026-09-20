import AppKit
import Combine
import Foundation
import RayPlacementCore
import RayPlacementWriting

@MainActor
protocol LauncherViewModelDelegate: AnyObject {
    func launcherViewModel(_ viewModel: LauncherViewModel, perform action: LauncherAction, item: LauncherItem)
    func launcherViewModelDidReloadExtensions(_ viewModel: LauncherViewModel)
    func launcherViewModelDidRequestHide(_ viewModel: LauncherViewModel)
}

@MainActor
final class LauncherViewModel: ObservableObject {
    // Keep the grid geometry in one place so keyboard navigation matches the
    // rendered columns at every launcher density.
    static let emojiGridColumnCount = 12
    private static let emojiPageSize = 120
    @Published var query = "" {
        didSet {
            if oldValue != query {
                selectedIndex = 0
                if mode == .files {
                    SurfaceStateCache.shared.set(.string(query), for: "files", key: "query")
                }
                refreshResults()
            }
        }
    }
    @Published private(set) var mode: LauncherMode = .root
    @Published private(set) var results: [LauncherItem] = []
    @Published private(set) var universalResults: [LimaSearchResult] = []
    /// The emoji picker owns its own lightweight data path. Keeping the raw
    /// catalog out of `results` avoids creating thousands of command models.
    @Published private(set) var emojiMatches: [EmojiEntry] = []
    @Published var selectedIndex = 0
    /// Only keyboard/page navigation increments this value. Pointer hover may
    /// update the highlighted row, but must never recenter the scroll view.
    @Published private(set) var navigationGeneration = 0
    @Published private(set) var isSearching = false
    @Published private(set) var extensionIssues: [ExtensionIssue] = []
    @Published private(set) var focusGeneration = 0
    @Published var timezoneSourceID: String = UserDefaults.standard.string(forKey: "timezoneSourceID") ?? TimeZone.current.identifier {
        didSet { UserDefaults.standard.set(timezoneSourceID, forKey: "timezoneSourceID") }
    }
    @Published var timezoneDestinationID: String = UserDefaults.standard.string(forKey: "timezoneDestinationID") ?? "UTC" {
        didSet { UserDefaults.standard.set(timezoneDestinationID, forKey: "timezoneDestinationID") }
    }
    @Published private(set) var timezoneDidCopy = false
    @Published private(set) var contextualSelectionText: String?
    @Published private(set) var actionPanelItem: LauncherItem?

    weak var delegate: LauncherViewModelDelegate?

    let clipboard: ClipboardHistoryService
    private let applicationIndex = ApplicationIndex()
    private let fileSearch = FileSearchService()
    private let extensionLoader = ExtensionLoader()
    private let usage = UsageStore()
    private let aliasStore = CommandAliasStore()
    private let searchIndex = LauncherSearchIndex()
    private var applications: [ApplicationRecord] = []
    @Published private(set) var extensionCommands: [LoadedExtensionCommand] = []
    private var fileResults: [URL] = []
    private var manifestExtensionIssues: [ExtensionIssue] = []
    private var hotkeyExtensionIssues: [ExtensionIssue] = []
    private var searchWorkItem: DispatchWorkItem?
    private var universalSearchTask: Task<Void, Never>?
    private var universalSearchGeneration = 0
    private var clipboardSearchWorkItem: DispatchWorkItem?
    private var clipboardSearchGeneration = 0
    private var clipboardObserver: AnyCancellable?
    private var catalogObservers: [AnyCancellable] = []

    init(clipboard: ClipboardHistoryService) {
        self.clipboard = clipboard
        clipboardObserver = clipboard.$entries.sink { [weak self] _ in
            self?.refreshResults()
        }
        catalogObservers = [
            NotesStore.shared.objectWillChange.sink { [weak self] _ in self?.refreshResults() },
            ContextShelfStore.shared.objectWillChange.sink { [weak self] _ in self?.refreshResults() },
            WorkflowStore.shared.objectWillChange.sink { [weak self] _ in self?.refreshResults() },
            LimaMacroStore.shared.objectWillChange.sink { [weak self] _ in self?.refreshResults() },
            ExtensionOutputStore.shared.objectWillChange.sink { [weak self] _ in self?.refreshResults() }
        ]
        reloadExtensions(notify: false)
        applicationIndex.scan { [weak self] records in
            self?.applications = records
            self?.refreshResults()
        }
        refreshResults()
    }

    var placeholder: String {
        switch mode {
        case .root: return "Search commands and applications…"
        case .files: return "Search files with Spotlight…"
        case .picker(.timezone): return "Enter a time like 9:30 AM, 14:00, or now"
        case .picker(.applications): return "Search running applications…"
        case .picker(.displays): return "Choose a display…"
        case .picker(.emoji): return "Search emojis…"
        case .clipboard: return "Search clipboard history…"
        case .history: return "Search command history…"
        case .terminal: return "Interactive terminal"
        case .contextShelf: return "Context Shelf"
        case .writingReview: return "Writing review"
        case .extensionSurface(let session): return session.title
        case .surface(let session): return session.surface.title
        case .output: return "Command output"
        }
    }

    var isEmojiPicker: Bool {
        if case .picker(.emoji) = mode { return true }
        return false
    }

    var isTimezonePicker: Bool {
        if case .picker(.timezone) = mode { return true }
        return false
    }

    var selectedItem: LauncherItem? {
        if isEmojiPicker {
            guard emojiMatches.indices.contains(selectedIndex) else { return nil }
            return emojiItem(for: emojiMatches[selectedIndex])
        }
        guard results.indices.contains(selectedIndex) else { return nil }
        return results[selectedIndex]
    }

    var selectedItemIsActionable: Bool {
        if isEmojiPicker { return !emojiMatches.isEmpty }
        guard let selectedItem else { return false }
        return isActionable(selectedItem)
    }

    var hasActionableResults: Bool {
        if isEmojiPicker { return !emojiMatches.isEmpty }
        return results.contains(where: isActionable)
    }

    /// A bounded range for the emoji grid. Rendering a single 3,900-cell
    /// collection still makes SwiftUI lay out and expose a huge accessibility
    /// tree, even when the cells themselves are lazy.
    var emojiVisibleRange: Range<Int> {
        let lower = emojiPageIndex * Self.emojiPageSize
        let upper = min(lower + Self.emojiPageSize, emojiMatches.count)
        return lower..<upper
    }

    var emojiPageIndex: Int {
        guard !emojiMatches.isEmpty else { return 0 }
        return min(selectedIndex / Self.emojiPageSize, emojiPageCount - 1)
    }

    var emojiPageCount: Int {
        guard !emojiMatches.isEmpty else { return 0 }
        return Int(ceil(Double(emojiMatches.count) / Double(Self.emojiPageSize)))
    }

    var emojiPageLabel: String {
        guard emojiPageCount > 1 else { return "" }
        return "\(emojiPageIndex + 1) / \(emojiPageCount)"
    }

    static let timezoneOptions: [TimezoneOption] = [
        TimezoneOption(id: TimeZone.current.identifier, title: "Local Time"),
        TimezoneOption(id: "UTC", title: "UTC"),
        TimezoneOption(id: "America/New_York", title: "New York"),
        TimezoneOption(id: "America/Chicago", title: "Chicago"),
        TimezoneOption(id: "America/Denver", title: "Denver"),
        TimezoneOption(id: "America/Los_Angeles", title: "Los Angeles"),
        TimezoneOption(id: "America/Toronto", title: "Toronto"),
        TimezoneOption(id: "America/Sao_Paulo", title: "São Paulo"),
        TimezoneOption(id: "Europe/London", title: "London"),
        TimezoneOption(id: "Europe/Paris", title: "Paris"),
        TimezoneOption(id: "Europe/Berlin", title: "Berlin"),
        TimezoneOption(id: "Africa/Johannesburg", title: "Johannesburg"),
        TimezoneOption(id: "Asia/Dubai", title: "Dubai"),
        TimezoneOption(id: "Asia/Kolkata", title: "India"),
        TimezoneOption(id: "Asia/Singapore", title: "Singapore"),
        TimezoneOption(id: "Asia/Shanghai", title: "Shanghai"),
        TimezoneOption(id: "Asia/Tokyo", title: "Tokyo"),
        TimezoneOption(id: "Australia/Sydney", title: "Sydney"),
        TimezoneOption(id: "Pacific/Auckland", title: "Auckland")
    ].reduce(into: [TimezoneOption]()) { result, option in
        if !result.contains(where: { $0.id == option.id }) { result.append(option) }
    }

    var timezoneConversion: TimezoneConversion? {
        TimezoneConverter.convert(query, from: timezoneSourceID, to: timezoneDestinationID)
    }

    func swapTimezones() {
        (timezoneSourceID, timezoneDestinationID) = (timezoneDestinationID, timezoneSourceID)
    }

    func copyTimezoneResult() {
        guard let conversion = timezoneConversion else { return }
        clipboard.copy("\(conversion.destinationTime) \(conversion.destinationZone) — \(conversion.destinationDate)")
        timezoneDidCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.timezoneDidCopy = false
        }
    }

    func isActionable(_ item: LauncherItem) -> Bool {
        if case .noOp = item.action { return false }
        return true
    }

    func setContextualSelection(_ text: String?) {
        let clean = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        contextualSelectionText = clean?.isEmpty == false ? clean : nil
        if mode == .root { refreshResults() }
    }

    func resetContextualSelection() {
        contextualSelectionText = nil
        if mode == .root { refreshResults() }
    }

    func refreshForSettings() {
        refreshResults()
    }

    func aliases(for commandID: String) -> [String] { aliasStore.aliases(for: commandID) }
    func setAliases(_ aliases: [String], for commandID: String) { aliasStore.set(aliases, for: commandID); refreshResults() }
    func resetLearnedRanking() { usage.reset(); refreshResults() }
    func forgetLearnedRanking(_ commandID: String) { usage.forget(commandID); refreshResults() }
    func lastLearnedCommands(limit: Int = 10) -> [String] { usage.recentIdentifiers(limit: limit) }

    var commandDescriptors: [ManagedCommandDescriptor] {
        var descriptors = builtInItems().map { ManagedCommandDescriptor(id: $0.id, title: $0.title, subtitle: $0.subtitle) }
        descriptors += extensionCommands.map {
            ManagedCommandDescriptor(
                id: "extension.\($0.extensionID).\($0.command.id)",
                title: $0.command.title,
                subtitle: $0.command.subtitle ?? $0.extensionName
            )
        }
        return descriptors.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func resetForPresentation() {
        searchWorkItem?.cancel()
        universalSearchTask?.cancel()
        clipboardSearchWorkItem?.cancel()
        fileSearch.cancel()
        // The terminal is a persistent workspace inside the launcher. Reopen
        // the launcher to the same terminal surface instead of resetting the
        // shell to the root command list.
        switch reopeningPolicy {
        case .resume:
            break
        case .resumeIfPinned:
            if !isPinnedSurface { resetToRoot() }
        case .root:
            resetToRoot()
        }
        focusGeneration += 1
    }

    var reopeningPolicy: LauncherSurfaceReopeningPolicy {
        switch mode {
        case .terminal: return .resume
        case .contextShelf: return .resumeIfPinned
        case .surface(let session): return session.surface.reopeningPolicy
        default: return .root
        }
    }

    private var isPinnedSurface: Bool {
        mode.isPinnedSurface
    }

    func recordSurfaceInteraction(at date: Date = Date()) {
        switch mode {
        case .surface(var session):
            session.lastInteractionAt = date
            mode = .surface(session)
        case .extensionSurface(var session):
            // Extension sessions use the same timeout semantics as generalized
            // surfaces. Reassign the value-type session so the timestamp is
            // retained by the mode rather than lost in a no-op branch.
            session.lastInteractionAt = date
            mode = .extensionSurface(session)
        default:
            break
        }
    }

    private func resetToRoot() {
        mode = .root
        query = ""
        selectedIndex = 0
        refreshResults()
    }

    func focusSearch() {
        focusGeneration += 1
    }

    /// Updates the value-type session stored in `mode` without losing the
    /// active surface identity. Pinning is intentionally session-scoped and is
    /// not written to UserDefaults.
    func setSurfacePinned(_ pinned: Bool) {
        switch mode {
        case .surface(var session):
            session.isPinned = pinned
            mode = .surface(session)
        case .extensionSurface(var session):
            session.isPinned = pinned
            // Preserve the complete session, especially lastInteractionAt.
            mode = .extensionSurface(session)
        default:
            break
        }
    }

    var selectedFileURL: URL? {
        guard mode == .files, let item = selectedItem else { return nil }
        switch item.action {
        case .openFile(let url), .fileAction(let url, _), .revealFile(let url): return url
        default: return nil
        }
    }

    func enter(_ newMode: LauncherMode) {
        searchWorkItem?.cancel()
        universalSearchTask?.cancel()
        clipboardSearchWorkItem?.cancel()
        fileSearch.cancel()
        mode = newMode
        query = ""
        selectedIndex = 0
        if newMode == .files,
           let restoredQuery = SurfaceStateCache.shared.string(for: "files", key: "query"),
           !restoredQuery.isEmpty {
            query = restoredQuery
        } else {
            refreshResults()
        }
    }

    func enter(_ newMode: LauncherMode, query initialQuery: String) {
        enter(newMode)
        guard !initialQuery.isEmpty else { return }
        query = initialQuery
    }

    func showOutput(
        title: String,
        text: String,
        state: LauncherOutputState = .success
    ) {
        mode = .output(title: title, text: text, state: state)
        query = ""
        results = []
    }

    func showWritingReview(_ review: WritingReview) {
        mode = .writingReview(review)
        query = ""
        results = []
    }

    func copyWritingResult(_ review: WritingReview) {
        executeWritingResult(review, paste: false)
    }

    func pasteWritingResult(_ review: WritingReview) {
        executeWritingResult(review, paste: true)
    }

    func approveExtension(_ issue: ExtensionIssue) {
        guard let extensionID = issue.extensionID,
              let manifestHash = issue.manifestHash,
              let capabilities = issue.capabilities else { return }
        ExtensionApprovalStore.approve(extensionID: extensionID, manifestHash: manifestHash, capabilities: capabilities)
        reloadExtensions()
    }

    func revokeExtension(_ extensionID: String) {
        ExtensionApprovalStore.revoke(extensionID: extensionID)
        reloadExtensions()
    }

    func reloadExtensions(notify: Bool = true) {
        let loaded = extensionLoader.load()
        extensionCommands = loaded.commands
        manifestExtensionIssues = loaded.issues
        updateExtensionIssues()
        refreshResults()
        if notify { delegate?.launcherViewModelDidReloadExtensions(self) }
    }

    @discardableResult
    func repairBundledExtensions() -> String {
        let report = extensionLoader.repairBundledExtensions()
        let loaded = extensionLoader.load()
        extensionCommands = loaded.commands
        manifestExtensionIssues = loaded.issues
        updateExtensionIssues()
        refreshResults()
        delegate?.launcherViewModelDidReloadExtensions(self)
        return report.summary
    }

    func setExtensionHotkeyIssues(_ issues: [ExtensionIssue]) {
        hotkeyExtensionIssues = issues
        updateExtensionIssues()
    }

    func moveSelection(by delta: Int) {
        if isEmojiPicker {
            moveEmojiSelection(by: delta)
            return
        }
        guard !results.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + results.count) % results.count
        navigationGeneration += 1
    }

    /// Moves through the emoji catalog using the same row width as the grid.
    /// The catalog is circular, so every keyboard movement always leaves a
    /// valid selection instead of getting stranded at a page boundary.
    func moveEmojiSelection(by delta: Int) {
        guard !emojiMatches.isEmpty else { return }
        selectedIndex = wrappedEmojiIndex(selectedIndex + delta)
        navigationGeneration += 1
    }

    func moveEmojiSelection(rowDelta: Int, columnDelta: Int) {
        guard !emojiMatches.isEmpty else { return }
        let columnCount = Self.emojiGridColumnCount
        let row = selectedIndex / columnCount
        let column = selectedIndex % columnCount
        let target = ((row + rowDelta) * columnCount) + column + columnDelta
        selectedIndex = wrappedEmojiIndex(target)
        navigationGeneration += 1
    }

    func selectFirstEmoji() {
        guard !emojiMatches.isEmpty else { return }
        selectedIndex = 0
        navigationGeneration += 1
    }

    func selectLastEmoji() {
        guard !emojiMatches.isEmpty else { return }
        selectedIndex = emojiMatches.count - 1
        navigationGeneration += 1
    }

    private func wrappedEmojiIndex(_ index: Int) -> Int {
        let count = emojiMatches.count
        return ((index % count) + count) % count
    }

    func select(_ index: Int) {
        if isEmojiPicker {
            guard emojiMatches.indices.contains(index) else { return }
            selectedIndex = index
            return
        }
        guard results.indices.contains(index) else { return }
        selectedIndex = index
    }

    func openActionPanel(for item: LauncherItem? = nil) {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        guard let item = item ?? selectedItem, isActionable(item) else { return }
        actionPanelItem = item
        LauncherPerformanceDiagnostics.shared.mark("action-panel-open", startedAt: startedAt, budget: 50)
    }

    func closeActionPanel() { actionPanelItem = nil }

    func actionPanelActions(for item: LauncherItem) -> [LauncherItemAction] {
        switch item.action {
        case .fileAction(let url, _):
            return [
                LauncherItemAction(id: "open", title: "Open", symbol: "arrow.up.forward.app", shortcut: nil, role: .primary, action: .fileAction(url, .open)),
                LauncherItemAction(id: "quick-look", title: "Quick Look", symbol: "eye", shortcut: nil, role: .secondary, action: .fileAction(url, .quickLook)),
                LauncherItemAction(id: "reveal", title: "Reveal in Finder", symbol: "finder", shortcut: nil, role: .secondary, action: .fileAction(url, .reveal)),
                LauncherItemAction(id: "copy-path", title: "Copy Path", symbol: "doc.on.doc", shortcut: nil, role: .secondary, action: .fileAction(url, .copyPath)),
                LauncherItemAction(id: "terminal", title: "Open Terminal Here", symbol: "terminal", shortcut: nil, role: .secondary, action: .fileAction(url, .openTerminalHere)),
                LauncherItemAction(id: "shelf", title: "Add to Shelf", symbol: "tray.and.arrow.down", shortcut: nil, role: .secondary, action: .fileAction(url, .addToShelf)),
                LauncherItemAction(id: "note", title: "Append to Note", symbol: "note.text.badge.plus", shortcut: nil, role: .secondary, action: .fileAction(url, .sendToNote))
            ]
        case .launchApplication(let url):
            let name = item.title
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL == url || $0.localizedName == name }) else {
                return [LauncherItemAction(id: "open", title: "Open", symbol: "arrow.up.forward.app", shortcut: nil, role: .primary, action: item.action)]
            }
            return [
                LauncherItemAction(id: "open", title: "Open", symbol: "arrow.up.forward.app", shortcut: nil, role: .primary, action: item.action),
                LauncherItemAction(id: "hide", title: "Hide", symbol: "eye.slash", shortcut: nil, role: .secondary, action: .applicationOperation(operation: "hide", processIdentifier: app.processIdentifier, name: name)),
                LauncherItemAction(id: "quit", title: "Quit", symbol: "xmark.circle", shortcut: nil, role: .destructive, action: .applicationOperation(operation: "quit", processIdentifier: app.processIdentifier, name: name)),
                LauncherItemAction(id: "force-quit", title: "Force Quit", symbol: "exclamationmark.octagon", shortcut: nil, role: .destructive, action: .applicationOperation(operation: "forceQuit", processIdentifier: app.processIdentifier, name: name))
            ]
        default:
            var actions = [LauncherItemAction(id: "run", title: "Run", symbol: "play.fill", shortcut: "↩", role: .primary, action: item.action)]
            if let context = contextValue(for: item) {
                actions.append(LauncherItemAction(id: "use-with", title: "Use With…", symbol: "arrow.triangle.branch", shortcut: nil, role: .secondary, action: .useWith(context)))
                actions.append(contentsOf: LimaCompatibilityRegistry.shared.actions(for: context).map {
                    LauncherItemAction(id: "use-with.\($0.id)", title: $0.title, symbol: $0.symbol, shortcut: nil, role: .secondary, action: $0.action)
                })
            }
            actions.append(LauncherItemAction(id: "shelf", title: "Add to Shelf", symbol: "tray.and.arrow.down", shortcut: nil, role: .secondary, action: .system(.addSelectionToShelf)))
            let favoriteTitle = CommandManager.shared.isFavorite(item.id) ? "Unpin from Top" : "Pin to Top"
            actions.append(LauncherItemAction(id: "favorite", title: favoriteTitle, symbol: CommandManager.shared.isFavorite(item.id) ? "pin.slash" : "pin", shortcut: nil, role: .secondary, action: .toggleFavorite(item.id)))
            actions.append(LauncherItemAction(id: "forget", title: "Forget Ranking", symbol: "clock.badge.xmark", shortcut: nil, role: .destructive, action: .forgetRanking(item.id)))
            return actions
        }
    }

    private func contextValue(for item: LauncherItem) -> LimaContextValue? {
        switch item.action {
        case .copyText(let value), .saveSelectionToQuickNote(let value), .pasteText(let value), .replaceSelectedText(let value):
            return LimaContextValue(kind: .text, title: item.title, value: value)
        case .openFile(let url), .revealFile(let url), .fileAction(let url, _):
            return LimaContextValue(kind: .file, title: item.title, value: url.path)
        case .openURL(let url):
            return LimaContextValue(kind: .url, title: item.title, value: url.absoluteString)
        case .universalSearch(let result):
            let kind: LimaContextKind = result.kind == .note ? .note : .text
            return LimaContextValue(kind: kind, title: result.title, value: result.subtitle)
        case .note(let id):
            guard let note = NotesStore.shared.notes.first(where: { $0.id == id }) else { return nil }
            return LimaContextValue(kind: .note, title: note.title, value: note.content)
        case .shelfItem(let id):
            guard let shelf = ContextShelfStore.shared.items.first(where: { $0.id == id }) else { return nil }
            return LimaContextValue(kind: .shelfItem, title: shelf.title, value: shelf.textValue ?? shelf.preview)
        case .clipboardEntry(let id):
            guard let entry = clipboard.entries.first(where: { $0.id == id }) else { return nil }
            return LimaContextValue(kind: .clipboard, title: "Clipboard", value: entry.text)
        case .extensionOutput(let id):
            guard let output = ExtensionOutputStore.shared.outputs.first(where: { $0.id == id }) else { return nil }
            return LimaContextValue(kind: .text, title: output.title, value: output.value)
        default: return nil
        }
    }

    func executeAction(_ action: LauncherItemAction) {
        guard let item = actionPanelItem ?? selectedItem else { return }
        closeActionPanel()
        usage.record(item.id, sourceApplication: NSWorkspace.shared.frontmostApplication?.localizedName)
        delegate?.launcherViewModel(self, perform: action.action, item: item)
    }

    func repeatLastAction() {
        guard let identifier = usage.lastIdentifier() else { return }
        let items = builtInItems() + extensionItems() + applicationItems() + macroItems() + specializedItems()
        guard let item = items.first(where: { $0.id == identifier }) else { return }
        execute(item: item)
    }

    private func execute(item: LauncherItem) {
        usage.record(item.id, sourceApplication: NSWorkspace.shared.frontmostApplication?.localizedName)
        delegate?.launcherViewModel(self, perform: item.action, item: item)
    }

    func executeSelected() {
        if isEmojiPicker {
            guard emojiMatches.indices.contains(selectedIndex) else { return }
            let item = emojiItem(for: emojiMatches[selectedIndex])
            execute(item: item)
            return
        }
        guard let item = selectedItem, isActionable(item) else { return }
        execute(item: item)
    }

    func executeEmoji(at index: Int) {
        guard isEmojiPicker, emojiMatches.indices.contains(index) else { return }
        selectedIndex = index
        executeSelected()
    }

    func moveEmojiPage(by delta: Int) {
        guard emojiPageCount > 1 else { return }
        let targetPage = min(max(emojiPageIndex + delta, 0), emojiPageCount - 1)
        guard targetPage != emojiPageIndex else { return }
        let positionOnPage = selectedIndex % Self.emojiPageSize
        selectedIndex = min(targetPage * Self.emojiPageSize + positionOnPage, emojiMatches.count - 1)
        navigationGeneration += 1
    }

    func executeVisibleItem(at index: Int) {
        guard results.indices.contains(index) else { return }
        selectedIndex = index
        executeSelected()
    }

    func handleEscape() {
        if !query.isEmpty {
            query = ""
        } else if mode != .root {
            enter(.root)
        } else {
            delegate?.launcherViewModelDidRequestHide(self)
        }
    }

    func goBackIfPossible() -> Bool {
        guard query.isEmpty, mode != .root else { return false }
        enter(.root)
        return true
    }

    private func refreshResults() {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        defer { LauncherPerformanceDiagnostics.shared.mark("local-search-refresh", startedAt: startedAt, budget: 30) }
        switch mode {
        case .root:
            refreshRootResults()

        case .files:
            refreshFileResults()
        case .picker(let picker):
            isSearching = false
            switch picker {
            case .timezone:
                results = []
            case .applications:
                results = runningApplicationItems()
            case .displays:
                results = displayItems()
            case .emoji:
                refreshEmojiMatches()
                results = []
            }
        case .clipboard:
            refreshClipboardResults()
        case .history:
            isSearching = false
            results = historyItems()
        case .terminal:
            isSearching = false
            results = []
        case .contextShelf:
            isSearching = false
            results = []
        case .extensionSurface, .surface:
            isSearching = false
            results = []
        case .writingReview:
            isSearching = false
            results = []
        case .output:
            isSearching = false
            results = []
        }
        if isEmojiPicker {
            selectedIndex = emojiMatches.isEmpty ? 0 : min(selectedIndex, emojiMatches.count - 1)
        } else if results.isEmpty {
            selectedIndex = 0
        } else {
            selectedIndex = min(selectedIndex, results.count - 1)
        }
    }

    private func refreshRootResults() {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        universalSearchGeneration += 1
        let generation = universalSearchGeneration
        universalSearchTask?.cancel()
        universalResults = []
        results = rootResults()
        guard !cleanQuery.isEmpty else {
            isSearching = false
            return
        }
        isSearching = true
        universalSearchTask = Task { [weak self] in
            let found = await UniversalSearchCoordinator.shared.search(cleanQuery)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      self.mode == .root,
                      self.universalSearchGeneration == generation,
                      self.query.trimmingCharacters(in: .whitespacesAndNewlines) == cleanQuery else { return }
                self.universalResults = found
                self.results = self.rootResults()
                self.isSearching = false
            }
        }
    }

    private func universalItem(_ result: LimaSearchResult) -> LauncherItem {
        let icon: LauncherIcon
        switch result.kind {
        case .note: icon = .system("note.text")
        case .dictation: icon = .system("waveform")
        case .terminal: icon = .system("terminal.fill")
        case .command: icon = .system("arrow.trianglehead.2.clockwise.rotate.90")
        default: icon = .system("magnifyingglass")
        }
        return LauncherItem(
            id: result.id,
            title: result.title,
            subtitle: result.subtitle,
            icon: icon,
            keywords: result.keywords,
            action: .universalSearch(result),
            accessory: "Open"
        )
    }

    private func rootSearchItems(_ items: [LauncherItem], query: String) -> [LauncherItem] {
        let ranked = items.compactMap { item -> (LauncherItem, Double)? in
            let titleScore = FuzzyMatcher.score(item.title, query: query)
            let allScore = FuzzyMatcher.score(item.searchableText, query: query)
            let score = max(titleScore ?? -.infinity, allScore ?? -.infinity)
            guard score.isFinite else { return nil }
            let normalizedTitle = item.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let normalizedQuery = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let intentBonus: Double = normalizedTitle == normalizedQuery ? 100 : (normalizedTitle.hasPrefix(normalizedQuery) ? 24 : 0)
            let favoriteRank = CommandManager.shared.favoriteRank(item.id)
            let favoriteBonus = favoriteRank == Int.max ? 0 : max(0, 500 - Double(favoriteRank * 20))
            return (item, score + intentBonus + usage.score(for: item.id) + favoriteBonus)
        }.sorted { first, second in
            if first.1 == second.1 { return first.0.title.localizedStandardCompare(second.0.title) == .orderedAscending }
            return first.1 > second.1
        }.map { $0.0 }
        let localIDs = Set(ranked.map { $0.id })
        let universal: [LauncherItem] = universalResults.filter { !localIDs.contains($0.id) }.map { universalItem($0) }
        return Array((ranked + universal).prefix(24))
    }

    private func rootResults() -> [LauncherItem] {
        var items = builtInItems() + extensionItems() + applicationItems() + macroItems() + specializedItems()
        if let selection = contextualSelectionText {
            items.insert(contentsOf: contextualItems(for: selection), at: 0)
        }
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchIndex.rebuild(items: items)

        // Deliberately undocumented developer gate. The configuration item is
        // not part of the normal catalog or searchable text.
        if cleanQuery == "🤖" {
            return [LauncherItem(
                id: "developer.grammar-settings",
                title: "Grammar Engine",
                subtitle: "Configure an enhanced proofreading provider",
                icon: .system("lock.shield.fill"),
                keywords: [],
                action: .system(.openDeveloperGrammarSettings),
                accessory: "Developer"
            )]
        }

        if !cleanQuery.isEmpty, let result = calculatorResult(for: cleanQuery) {
            items.insert(result, at: 0)
        }
        if !cleanQuery.isEmpty {
            items.append(contentsOf: directInvocationItems(for: cleanQuery))
        }

        guard !cleanQuery.isEmpty else {
            let priority = [
                "builtin.quick-note", "builtin.notes", "builtin.search-files", "builtin.terminal",
                "extension.local.system-controls.force-quit-application", "builtin.clipboard",
                "extension.local.window-management.left-half", "extension.local.window-management.right-half",
                "extension.local.window-management.maximize", "builtin.command-history", "builtin.extensions-folder",
                "builtin.settings", "builtin.reload-extensions"
            ]
            let defaults = priority.compactMap { id in items.first { $0.id == id } }
            let recent: [LauncherItem] = usage.recentIdentifiers(limit: 8).compactMap { identifier in
                guard let item = items.first(where: { $0.id == identifier }) else { return nil }
                var recentItem = item
                recentItem.accessory = "Recent"
                return recentItem
            }
            let favorites = items
                .filter { CommandManager.shared.isFavorite($0.id) }
                .sorted { CommandManager.shared.favoriteRank($0.id) < CommandManager.shared.favoriteRank($1.id) }
                .map { item -> LauncherItem in
                    var favorite = item
                    favorite.accessory = "Favorite"
                    return favorite
                }
            let contextual = contextualSelectionText == nil ? [] : items.filter { $0.id.hasPrefix("context.") }.prefix(4).map { $0 }
            let ordered = Array(contextual) + Array(favorites.prefix(4)) + Array(recent.prefix(4)) + defaults.filter { defaultItem in
                !contextual.contains(where: { $0.id == defaultItem.id })
                    && !recent.contains(where: { $0.id == defaultItem.id })
                    && !favorites.contains(where: { $0.id == defaultItem.id })
            }
            var unique = [LauncherItem]()
            var identifiers = Set<String>()
            for item in ordered where identifiers.insert(item.id).inserted { unique.append(item) }
            return Array(unique.prefix(11))
        }

        let ranked = items.compactMap { item -> (LauncherItem, Double)? in
            guard let baseScore = searchScore(for: item, query: cleanQuery) else { return nil }
            let provenance = aliasProvenance(for: item, query: cleanQuery)
            var rankedItem = item
            rankedItem.aliasKind = provenance.kind
            let favoriteRank = CommandManager.shared.favoriteRank(item.id)
            let favoriteBonus = favoriteRank == Int.max ? 0 : max(0, 500 - Double(favoriteRank * 20))
            return (rankedItem, baseScore + provenance.bonus + usage.score(for: item.id) + favoriteBonus)
        }
        .sorted { first, second in
            if first.1 == second.1 { return first.0.title.localizedStandardCompare(second.0.title) == .orderedAscending }
            return first.1 > second.1
        }
        .prefix(12)
        .map(\.0)
        if ranked.isEmpty && universalResults.isEmpty {
            return [placeholderItem(id: "root.empty", title: "No results", subtitle: "Try another app or command name", icon: "magnifyingglass")]
        }
        let local = ranked
        let localIDs = Set(local.map(\.id))
        let universal = universalResults.filter { !localIDs.contains($0.id) }.map(universalItem)
        return Array((local + universal).prefix(24))
    }

    private func normalizedSearchTokens(_ value: String) -> [String] {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split { character in
                !(character.isLetter || character.isNumber)
            }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func aliasProvenance(for item: LauncherItem, query: String) -> (kind: LimaAliasKind, bonus: Double) {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if title == normalizedQuery { return (.exactTitle, 100_000) }
        if aliasStore.aliases(for: item.id).contains(where: { $0.lowercased() == normalizedQuery }) {
            return (.userAlias, 1_200)
        }
        if item.id.hasPrefix("extension."),
           let loaded = extensionCommands.first(where: { "extension.\($0.extensionID).\($0.command.id)" == item.id }),
           loaded.command.aliases?.contains(where: { $0.lowercased() == normalizedQuery }) == true {
            return (.extensionAlias, 900)
        }
        if (item.id.hasPrefix("builtin.") || item.id.hasPrefix("context.")),
           item.keywords.contains(where: { $0.lowercased() == normalizedQuery }) {
            return (.builtInAlias, 600)
        }
        return (.exactTitle, 0)
    }

    private func searchScore(for item: LauncherItem, query: String) -> Double? {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return 0 }
        let fields = [item.title, item.subtitle] + item.keywords
        let wholeText = item.searchableText
        let titleScore = FuzzyMatcher.score(item.title, query: clean)
        let wholeScore = FuzzyMatcher.score(wholeText, query: clean)
        let tokens = normalizedSearchTokens(clean)
        let tokenScores = tokens.map { token in
            fields.compactMap { FuzzyMatcher.score($0, query: token) }.max() ?? -.infinity
        }
        guard tokenScores.allSatisfy(\.isFinite) else {
            return max(titleScore ?? -.infinity, wholeScore ?? -.infinity).isFinite
                ? max(titleScore ?? -.infinity, wholeScore ?? -.infinity)
                : nil
        }
        let normalizedTitle = item.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let normalizedQuery = clean.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let titleIntent: Double
        if normalizedTitle == normalizedQuery { titleIntent = 100_000 }
        else if normalizedTitle.hasPrefix(normalizedQuery) { titleIntent = 24 }
        else { titleIntent = 0 }
        let tokenScore = 14_000 + tokenScores.reduce(0, +) + titleIntent
        return max(titleScore ?? -.infinity, wholeScore ?? -.infinity, tokenScore)
    }

    /// Converts a typed command plus trailing words into the same public action
    /// the manifest declares. This is deliberately bounded: only picker query
    /// arguments and application-picker targets are accepted, never arbitrary
    /// shell fragments or a scripting language.
    private func directInvocationItems(for query: String) -> [LauncherItem] {
        let queryTokens = normalizedSearchTokens(query)
        guard queryTokens.count >= 2 else { return [] }
        var items: [LauncherItem] = []
        var seen = Set<String>()

        let command = queryTokens[0]
        let argument = query.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst(command.count).trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = command.lowercased()
        if let length = Int(argument), (lowered == "password" || lowered == "pass" || lowered == "pw" || lowered == "pwdgen"), (8...20).contains(length) {
            items.append(LauncherItem(id: "direct.password.\(length)", title: "Generate \(length)-character Password", subtitle: "Password Generator", icon: .system("key.fill"), keywords: ["password", "pass", "pw"], action: .builtinInvocation(.password(length: length)), accessory: "Direct"))
        } else if !argument.isEmpty && ["timezone", "time", "tz"].contains(lowered) {
            items.append(LauncherItem(id: "direct.timezone.\(argument)", title: "Show Time in \(argument)", subtitle: "Timezone Converter", icon: .system("clock"), keywords: ["timezone", "time"], action: .builtinInvocation(.timezone(query: String(argument))), accessory: "Direct"))
        } else if !argument.isEmpty && ["note", "quicknote", "qn"].contains(lowered) {
            items.append(LauncherItem(id: "direct.note.\(argument)", title: "Open Note: \(argument)", subtitle: "Quick Note", icon: .system("note.text"), keywords: ["note", "quick note"], action: .builtinInvocation(.note(title: String(argument))), accessory: "Direct"))
        } else if !argument.isEmpty && ["terminal", "term", "shell"].contains(lowered) {
            items.append(LauncherItem(id: "direct.terminal.\(argument)", title: "Open Terminal at \(argument)", subtitle: "Terminal", icon: .system("terminal.fill"), keywords: ["terminal", "shell"], action: .builtinInvocation(.terminal(path: String(argument))), accessory: "Direct"))
        } else if !argument.isEmpty && ["format", "formatter"].contains(lowered) {
            items.append(LauncherItem(id: "direct.format.\(argument)", title: "Format as \(argument.uppercased())", subtitle: "Formatter", icon: .system("curlybraces"), keywords: ["format", argument], action: .builtinInvocation(.format(kind: String(argument))), accessory: "Direct"))
        }

        for loaded in extensionCommands where SettingsStore.shared.isCommandEnabled(loaded) {
            let commandWords = normalizedSearchTokens(
                ([loaded.command.title, loaded.command.subtitle ?? ""] + (loaded.command.keywords ?? []) + (loaded.command.aliases ?? [])).joined(separator: " ")
            )
            let unmatched = queryTokens.filter { token in
                !commandWords.contains { word in
                    word == token || word.hasPrefix(token) || token.hasPrefix(word)
                }
            }
            guard !unmatched.isEmpty, unmatched.count < queryTokens.count else { continue }
            let argumentText = unmatched.joined(separator: " ")
            let operation = loaded.command.action.operation ?? ""
            let actionType = loaded.command.action.type
            let supportsQuery: Bool
            switch actionType {
            case .picker:
                supportsQuery = ["emoji", "timezone", "application", "file"].contains(operation)
            case .application:
                supportsQuery = loaded.command.action.target == "picker"
            default:
                supportsQuery = false
            }
            guard supportsQuery else { continue }

            var action = loaded.command.action
            var parameters = action.parameters ?? [:]
            parameters["query"] = argumentText
            if actionType == .application {
                parameters["applicationQuery"] = argumentText
            }
            action.parameters = parameters
            var invoked = loaded
            invoked.command.action = action

            let baseID = "extension.\(loaded.extensionID).\(loaded.command.id)"
            let suffix = argumentText.replacingOccurrences(of: " ", with: "-")
            let appName: String? = actionType == .application
                ? matchingRunningApplication(named: argumentText)?.localizedName
                : nil
            let title: String
            let subtitle: String
            let icon: LauncherIcon
            if let appName {
                title = "\(loaded.command.title) → \(appName)"
                subtitle = "Open the application picker with \(appName) selected"
                icon = matchingRunningApplication(named: argumentText)?.bundleURL.map(LauncherIcon.application) ?? .system(loaded.command.icon ?? "puzzlepiece.extension.fill")
            } else {
                title = "\(loaded.command.title) · \(argumentText)"
                subtitle = loaded.command.subtitle ?? loaded.extensionName
                icon = .system(loaded.command.icon ?? "puzzlepiece.extension.fill")
            }
            let identifier = "\(baseID).argument.\(suffix)"
            guard seen.insert(identifier).inserted else { continue }
            items.append(LauncherItem(
                id: identifier,
                title: title,
                subtitle: subtitle,
                icon: icon,
                keywords: (loaded.command.keywords ?? []) + [argumentText],
                action: .extensionCommand(invoked),
                shortcut: nil,
                accessory: "Direct"
            ))
        }
        return items
    }

    private func matchingRunningApplication(named query: String) -> NSRunningApplication? {
        let tokens = normalizedSearchTokens(query)
        guard !tokens.isEmpty else { return nil }
        return NSWorkspace.shared.runningApplications
            .filter { !$0.isTerminated && $0.activationPolicy == .regular && $0.localizedName != nil }
            .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
            .first { application in
                let searchable = normalizedSearchTokens([application.localizedName ?? "", application.bundleIdentifier ?? ""].joined(separator: " "))
                return tokens.allSatisfy { token in searchable.contains { $0 == token || $0.hasPrefix(token) || token.hasPrefix($0) } }
            }
    }

    private func refreshFileResults() {
        searchWorkItem?.cancel()
        let requestedMode = mode
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty else {
            isSearching = false
            fileResults = []
            results = [placeholderItem(
                id: "files.hint",
                title: "Type a file name",
                subtitle: "Results come from Spotlight",
                icon: "magnifyingglass"
            )]
            return
        }

        isSearching = true
        fileResults = []
        results = [placeholderItem(id: "files.searching", title: "Searching…", subtitle: cleanQuery, icon: "magnifyingglass")]
        let request = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.fileSearch.search(cleanQuery) { [weak self] urls in
                guard let self, self.mode == requestedMode,
                      self.query.trimmingCharacters(in: .whitespacesAndNewlines) == cleanQuery else { return }
                self.isSearching = false
                self.fileResults = urls
                self.results = urls.isEmpty
                    ? [self.placeholderItem(
                        id: "files.empty",
                        title: "No files found",
                        subtitle: "Try a broader name",
                        icon: "doc.text.magnifyingglass"
                    )]
                    : urls.map { self.fileItem($0) }
                self.selectedIndex = 0
            }
        }
        searchWorkItem = request
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: request)
    }

    private func refreshClipboardResults() {
        clipboardSearchWorkItem?.cancel()
        clipboardSearchGeneration += 1
        let generation = clipboardSearchGeneration
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = clipboard.entries

        guard !cleanQuery.isEmpty else {
            isSearching = false
            results = clipboardItems(snapshot, hadEntries: !snapshot.isEmpty)
            return
        }

        isSearching = true
        results = [placeholderItem(id: "clipboard.searching", title: "Searching…", subtitle: cleanQuery, icon: "magnifyingglass")]
        let request = DispatchWorkItem { [weak self] in
            let matching = snapshot.filter { FuzzyMatcher.score($0.text, query: cleanQuery) != nil }
            DispatchQueue.main.async {
                guard let self, self.mode == .clipboard,
                      self.clipboardSearchGeneration == generation,
                      self.query.trimmingCharacters(in: .whitespacesAndNewlines) == cleanQuery else { return }
                self.isSearching = false
                self.results = self.clipboardItems(matching, hadEntries: !snapshot.isEmpty)
                self.selectedIndex = 0
            }
        }
        clipboardSearchWorkItem = request
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.08, execute: request)
    }

    private func clipboardItems(_ matching: [ClipboardEntry], hadEntries: Bool) -> [LauncherItem] {
        guard !matching.isEmpty else {
            return [placeholderItem(
                id: "clipboard.empty",
                title: hadEntries ? "No matching clipboard items" : "Clipboard history is empty",
                subtitle: SettingsStore.shared.clipboardEnabled ? "Copied text stays on this Mac" : "Enable history in Settings",
                icon: "clipboard"
            )]
        }
        return matching.prefix(50).map { entry in
            let singleLine = entry.text.replacingOccurrences(of: "\n", with: " ")
            let title = String(singleLine.prefix(110))
            return LauncherItem(
                id: "clipboard.\(entry.id.uuidString)",
                title: title,
                subtitle: entry.capturedAt.formatted(date: .abbreviated, time: .shortened),
                icon: .system("clipboard.fill"),
                keywords: [],
                action: .copyText(entry.text),
                accessory: "Copy"
            )
        }
    }

    private func applicationItems() -> [LauncherItem] {
        applications.map { app in
            LauncherItem(
                id: "app.\(app.url.path)",
                title: app.name,
                subtitle: "Application",
                icon: .application(app.url),
                keywords: [app.bundleIdentifier ?? "", app.url.path],
                action: .launchApplication(app.url)
            )
        }
    }

    private var applicationPickerOperation = "forceQuit"

    func enterApplicationPicker(operation: String, query initialQuery: String = "") {
        applicationPickerOperation = operation
        enter(.picker(.applications(operation: operation)), query: initialQuery)
    }

    private var displayPickerOperation = "moveToDisplay"

    func enterDisplayPicker(operation: String = "moveToDisplay") {
        displayPickerOperation = operation
        enter(.picker(.displays(operation: operation)))
    }

    private func displayItems() -> [LauncherItem] {
        let screens = NSScreen.screens.enumerated().compactMap { index, screen -> (CGDirectDisplayID, NSScreen)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (CGDirectDisplayID(number.uint32Value), screen)
        }
        guard !screens.isEmpty else {
            return [placeholderItem(id: "display.empty", title: "No displays available", subtitle: "macOS did not expose any displays", icon: "display")]
        }
        return screens.map { displayID, screen in
            let name = screen.localizedName.isEmpty ? "Display \(displayID)" : screen.localizedName
            let primary = screen == NSScreen.main ? " · Main display" : ""
            let dimensions = "\(Int(screen.frame.width)) × \(Int(screen.frame.height))\(primary)"
            return LauncherItem(
                id: "display.\(displayID)",
                title: name,
                subtitle: dimensions,
                icon: .system(screen == NSScreen.main ? "display" : "display.2"),
                keywords: ["display", "monitor", String(displayID)],
                action: .displayOperation(operation: displayPickerOperation, displayIdentifier: displayID, name: name),
                accessory: screen == NSScreen.main ? "Main" : nil
            )
        }
    }

    private func runningApplicationItems() -> [LauncherItem] {
        let currentBundleIdentifier = Bundle.main.bundleIdentifier
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let allRunning = NSWorkspace.shared.runningApplications
            .filter {
                !$0.isTerminated
                    && $0.activationPolicy == .regular
                    && $0.bundleIdentifier != currentBundleIdentifier
                    && $0.localizedName != nil
            }
            .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
        let running = cleanQuery.isEmpty ? allRunning : allRunning.filter { application in
            let searchable = [application.localizedName ?? "", application.bundleIdentifier ?? ""]
                .joined(separator: " ")
            return FuzzyMatcher.score(searchable, query: cleanQuery) != nil
        }
        guard !running.isEmpty else {
            return [placeholderItem(
                id: "force-quit.empty",
                title: cleanQuery.isEmpty ? "No running applications" : "No matching applications",
                subtitle: cleanQuery.isEmpty ? "Only normal foreground apps are shown" : "Try another application name",
                icon: cleanQuery.isEmpty ? "checkmark.circle" : "magnifyingglass"
            )]
        }
        return running.map { application in
            let name = application.localizedName ?? "Application"
            return LauncherItem(
                id: "force-quit.\(application.processIdentifier)",
                title: name,
                subtitle: "Force quit immediately — unsaved work may be lost",
                icon: application.bundleURL.map(LauncherIcon.application) ?? .system("app.dashed"),
                keywords: [application.bundleIdentifier ?? "", "quit", "kill", "frozen"],
                action: .applicationOperation(operation: applicationPickerOperation, processIdentifier: application.processIdentifier, name: name),
                accessory: "Confirm"
            )
        }
    }

    private func refreshEmojiMatches() {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching: [EmojiEntry]
        if cleanQuery.isEmpty {
            matching = EmojiCatalog.entries
        } else {
            let exact = EmojiCatalog.search(cleanQuery)
            if !exact.isEmpty {
                matching = exact
            } else {
                matching = EmojiCatalog.entries.compactMap { entry -> (EmojiEntry, Double)? in
                    guard let fuzzy = FuzzyMatcher.score(entry.searchableText, query: cleanQuery) else { return nil }
                    return (entry, fuzzy)
                }
                .sorted { first, second in
                    if first.1 == second.1 { return first.0.name < second.0.name }
                    return first.1 > second.1
                }
                .prefix(120)
                .map(\.0)
            }
        }
        emojiMatches = matching
    }

    private func emojiItem(for entry: EmojiEntry) -> LauncherItem {
        LauncherItem(
            id: "emoji.\(entry.id)",
            title: entry.name,
            subtitle: entry.group,
            icon: .text(entry.emoji),
            keywords: entry.keywords,
            action: .pasteText(entry.emoji),
            accessory: "Paste"
        )
    }

    private func historyItems() -> [LauncherItem] {
        let items = builtInItems() + extensionItems() + applicationItems() + macroItems() + specializedItems()
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let recent = usage.recentIdentifiers(limit: 50).compactMap { identifier in
            items.first { $0.id == identifier }
        }
        let matching = cleanQuery.isEmpty ? recent : recent.filter {
            FuzzyMatcher.score($0.searchableText, query: cleanQuery) != nil
        }
        guard !matching.isEmpty else {
            return [placeholderItem(
                id: "history.empty",
                title: cleanQuery.isEmpty ? "No command history yet" : "No matching history",
                subtitle: cleanQuery.isEmpty ? "Run a command and it will appear here" : "Try another command name",
                icon: cleanQuery.isEmpty ? "clock" : "magnifyingglass"
            )]
        }
        return matching.enumerated().map { offset, item in
            var recentItem = item
            recentItem.accessory = offset == 0 ? "Most recent" : "Recent"
            return recentItem
        }
    }

    private func extensionItems() -> [LauncherItem] {
        extensionCommands.filter {
            SettingsStore.shared.isCommandEnabled($0) && CommandManager.shared.isEnabled("extension.\($0.extensionID).\($0.command.id)")
        }.map { loaded in
            LauncherItem(
                id: "extension.\(loaded.extensionID).\(loaded.command.id)",
                title: loaded.command.title,
                subtitle: loaded.command.subtitle ?? loaded.extensionName,
                icon: .system(loaded.command.icon ?? "puzzlepiece.extension.fill"),
                keywords: (loaded.command.keywords ?? []) + (loaded.command.aliases ?? []),
                action: .extensionCommand(loaded),
                shortcut: SettingsStore.shared.isHotkeyEnabled(loaded)
                    ? SettingsStore.shared.effectiveShortcut(for: loaded)
                        .flatMap { ShortcutSpec(string: $0)?.displayString }
                    : nil
            )
        }
    }

    private func contextualItems(for text: String) -> [LauncherItem] {
        let bullets = text.components(separatedBy: .newlines)
            .map { line in
                let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return clean.hasPrefix("- ") || clean.hasPrefix("* ") ? clean : "- \(clean)"
            }
            .joined(separator: "\n")
        return [
            LauncherItem(
                id: "context.check-writing",
                title: "Check Spelling & Grammar",
                subtitle: "Review the current selection locally",
                icon: .system("text.badge.checkmark"),
                keywords: ["selection", "spell", "grammar", "proofread"],
                action: .checkSelectedText,
                shortcut: "⌘1",
                accessory: "Review"
            ),
            LauncherItem(
                id: "context.copy-plain-text",
                title: "Copy as Plain Text",
                subtitle: "Copy the current selection without rich formatting",
                icon: .system("doc.plaintext"),
                keywords: ["selection", "plain", "text", "copy"],
                action: .copyText(text),
                shortcut: "⌘2",
                accessory: "Copy"
            ),
            LauncherItem(
                id: "context.quick-note",
                title: "Save Selection to Quick Note",
                subtitle: "Create a local note from the current selection",
                icon: .system("note.text.badge.plus"),
                keywords: ["selection", "note", "save", "capture"],
                action: .saveSelectionToQuickNote(text),
                shortcut: "⌘3",
                accessory: "Save"
            ),
            LauncherItem(
                id: "context.markdown-bullets",
                title: "Convert Selection to Markdown Bullets",
                subtitle: "Prefix each selected line with a Markdown bullet",
                icon: .system("list.bullet"),
                keywords: ["selection", "markdown", "format", "bullets", "list"],
                action: .replaceSelectedText(bullets),
                shortcut: "⌘4",
                accessory: "Replace"
            ),
        ]
    }

    private func specializedItems() -> [LauncherItem] {
        let notes = NotesStore.shared.notes.prefix(30).map { note in
            LauncherItem(id: "note.\(note.id.uuidString)", title: note.title, subtitle: note.content.prefix(80).description, icon: .system("note.text"), keywords: note.tags + ["note", "markdown"], action: .note(note.id), accessory: note.isFavorite ? "Favorite" : "Note", aliasKind: nil)
        }
        let shelf = ContextShelfStore.shared.items.prefix(30).map { item in
            LauncherItem(id: "shelf.\(item.id.uuidString)", title: item.title, subtitle: item.preview, icon: .system("tray.full"), keywords: ["shelf", item.kind.rawValue], action: .shelfItem(item.id), accessory: item.isPinned ? "Pinned" : "Shelf", aliasKind: nil)
        }
        let clips = clipboard.entries.prefix(30).map { entry in
            LauncherItem(id: "clipboard.\(entry.id.uuidString)", title: String(entry.text.prefix(70)), subtitle: "Clipboard entry", icon: .system("clipboard"), keywords: ["clipboard", "copy", "paste"], action: .clipboardEntry(entry.id), accessory: entry.pinned ? "Pinned" : "Clipboard", aliasKind: nil)
        }
        let workflows = WorkflowStore.shared.workflows.prefix(30).map { workflow in
            LauncherItem(id: "workflow.\(workflow.id.uuidString)", title: workflow.name, subtitle: "\(workflow.steps.count) steps", icon: .system("arrow.trianglehead.2.clockwise.rotate.90"), keywords: ["workflow", "automation"], action: .workflow(workflow.id), accessory: workflow.favorite ? "Favorite" : "Workflow", aliasKind: nil)
        }
        let outputs = ExtensionOutputStore.shared.outputs.prefix(30).map { output in
            LauncherItem(id: "output.\(output.id.uuidString)", title: output.title, subtitle: String(output.value.prefix(80)), icon: .system("text.quote"), keywords: ["output", output.descriptor.kind.rawValue], action: .extensionOutput(output.id), accessory: "Output", aliasKind: nil)
        }
        return notes + shelf + clips + workflows + outputs
    }

    private func macroItems() -> [LauncherItem] {
        LimaMacroStore.shared.chains.map { chain in
            LauncherItem(id: "macro.\(chain.id.uuidString)", title: chain.name, subtitle: "Run \(chain.steps.count) registered action\(chain.steps.count == 1 ? "" : "s")", icon: .system("bolt.horizontal.circle"), keywords: ["macro", "chain", "automation"], action: .macro(chain.id), accessory: "Macro")
        }
    }

    private func builtInItems() -> [LauncherItem] {
        let items: [LauncherItem] = [
            LauncherItem(id: "builtin.search-files", title: "Search Files", subtitle: "Find files with Spotlight", icon: .system("doc.text.magnifyingglass"), keywords: ["finder", "document", "open"], action: .enterMode(.files)),
            LauncherItem(id: "builtin.notes", title: "Lima Notes", subtitle: "Open the separate Markdown notes window", icon: .system("note.text"), keywords: ["notes", "markdown", "write"], action: .system(.openNotes), shortcut: SettingsStore.shared.notesHotkeyEnabled ? ShortcutSpec(string: SettingsStore.shared.notesShortcut)?.displayString : nil),
            LauncherItem(id: "builtin.ai-chat", title: "Open AI Chat", subtitle: "Start a private streaming OpenAI conversation", icon: .system("sparkles"), keywords: ["ai", "chat", "openai", "assistant", "conversation"], action: .system(.openAIChat)),
            LauncherItem(id: "builtin.quick-note", title: "Quick Note Sidebar", subtitle: "Pin the most recent note beside your current app", icon: .system("rectangle.righthalf.inset.filled"), keywords: ["notes", "dock", "side", "sidebar", "capture"], action: .system(.openQuickNote), shortcut: SettingsStore.shared.quickNoteHotkeyEnabled ? ShortcutSpec(string: SettingsStore.shared.quickNoteShortcut)?.displayString : nil),
            LauncherItem(id: "builtin.note-dictation", title: "Start or Stop Dictation Conversation", subtitle: "Record a separate dictation conversation", icon: .system("mic.fill"), keywords: ["notes", "meeting", "speech", "transcribe"], action: .system(.toggleNoteDictation), shortcut: SettingsStore.shared.dictationHotkeyEnabled ? ShortcutSpec(string: SettingsStore.shared.dictationShortcut)?.displayString : nil),
            // The terminal is an optional developer surface. Keeping it out of
            // the catalog entirely makes the setting apply to search as well as
            // the default command list.
            LauncherItem(id: "builtin.terminal", title: "Terminal", subtitle: "Run commands in a local zsh terminal", icon: .system("terminal.fill"), keywords: ["shell", "console", "command", "vim", "nano", "developer", "term", ">"], action: .system(.openTerminal)),
            LauncherItem(id: "builtin.context-shelf", title: "Context Shelf", subtitle: "Temporary working memory for text, files, and tool output", icon: .system("tray.full"), keywords: ["shelf", "context", "working", "memory", "capture", "stash", "save selection"], action: .system(.openContextShelf)),
            LauncherItem(id: "builtin.add-selection-to-shelf", title: "Add Selection to Shelf", subtitle: "Capture highlighted text without opening Lima", icon: .system("text.badge.plus"), keywords: ["add", "selection", "capture", "shelf", "highlight"], action: .system(.addSelectionToShelf)),
            LauncherItem(id: "builtin.workflows", title: "Workflows", subtitle: "Build and run multi-command workflows", icon: .system("arrow.trianglehead.2.clockwise.rotate.90"), keywords: ["workflow", "automation", "sequence"], action: .system(.openWorkflows)),
            LauncherItem(id: "builtin.permissions", title: "Permission Center", subtitle: "Review Accessibility, microphone, speech, automation, and login access", icon: .system("checkmark.shield"), keywords: ["permission", "privacy", "accessibility", "microphone", "automation"], action: .system(.openPermissionCenter)),
            LauncherItem(id: "builtin.diagnostics", title: "Export Diagnostics", subtitle: "Create a sanitized support bundle without private content", icon: .system("stethoscope"), keywords: ["diagnostics", "support", "debug", "report"], action: .system(.exportDiagnostics)),
            LauncherItem(id: "builtin.grammar-debugger", title: "Grammar Debugger", subtitle: "Inspect candidate cards, consensus, feedback, and seed analytics", icon: .system("ladybug"), keywords: ["grammar", "debug", "ensemble", "candidates", "analytics", "benchmark", "proofread", "fix writing", "correct"], action: .system(.openGrammarDebugger)),
            LauncherItem(id: "builtin.clipboard", title: "Clipboard History", subtitle: "Search text copied on this Mac", icon: .system("clipboard.fill"), keywords: ["copy", "paste", "history"], action: .enterMode(.clipboard)),
            LauncherItem(id: "builtin.command-history", title: "Command History", subtitle: "Re-run recently used commands and tools", icon: .system("clock.arrow.circlepath"), keywords: ["recent", "history", "last", "again", "commands"], action: .enterMode(.history)),
            LauncherItem(id: "builtin.extensions-folder", title: "Open Extensions Folder", subtitle: "Add commands without rebuilding", icon: .system("folder.badge.gearshape"), keywords: ["plugin", "custom", "script", "functionality"], action: .system(.openExtensionsFolder)),
            LauncherItem(id: "builtin.reload-extensions", title: "Reload Extensions", subtitle: "Pick up manifest changes", icon: .system("arrow.clockwise"), keywords: ["plugin", "refresh"], action: .system(.reloadExtensions)),
            LauncherItem(id: "builtin.settings", title: "Lima Settings", subtitle: "Hotkeys, performance, privacy, and extensions", icon: .system("gearshape.fill"), keywords: ["preferences", "hotkey", "shortcut", "performance", "accessibility"], action: .system(.openSettings), shortcut: "⌘,"),
            LauncherItem(id: "builtin.check-for-updates", title: "Check for Updates", subtitle: "Look for a verified Lima update", icon: .system("arrow.triangle.2.circlepath"), keywords: ["update", "upgrade", "release", "version", "software"], action: .system(.checkForUpdates)),
            LauncherItem(id: "builtin.quit", title: "Quit Lima", subtitle: "System", icon: .system("power"), keywords: ["exit"], action: .system(.quit), shortcut: "⌘Q")
        ]
        return items
    }

    private func calculatorResult(for query: String) -> LauncherItem? {
        let allowed = CharacterSet(charactersIn: "0123456789.,+-*/%^() πe")
        guard query.unicodeScalars.allSatisfy(allowed.contains),
              query.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains),
              let value = try? Calculator.evaluate(query) else { return nil }
        let formatted = Calculator.formatted(value)
        return LauncherItem(
            id: "calculator.\(query)",
            title: formatted,
            subtitle: "Calculator — press Return to copy",
            icon: .system("equal.circle.fill"),
            keywords: [query],
            action: .copyText(formatted),
            accessory: "Copy"
        )
    }

    private func fileItem(_ url: URL) -> LauncherItem {
        LauncherItem(
            id: "file.\(url.path)",
            title: url.lastPathComponent,
            subtitle: url.deletingLastPathComponent().path,
            icon: .file(url),
            keywords: [url.path],
            action: .fileAction(url, .open)
        )
    }

    private func placeholderItem(id: String, title: String, subtitle: String, icon: String) -> LauncherItem {
        LauncherItem(id: id, title: title, subtitle: subtitle, icon: .system(icon), keywords: [], action: .noOp)
    }

    private func updateExtensionIssues() {
        extensionIssues = manifestExtensionIssues + hotkeyExtensionIssues
    }

    private func executeWritingResult(_ review: WritingReview, paste: Bool) {
        let text = review.hasSuggestedChanges ? review.suggestedText : review.sourceText
        let item = LauncherItem(
            id: paste ? "writing.replace" : "writing.copy",
            title: paste ? "Replace Selected Text" : "Copy Reviewed Text",
            subtitle: "Writing Review",
            icon: .system(paste ? "text.badge.checkmark" : "doc.on.doc"),
            keywords: [],
            action: paste ? .replaceSelectedText(text) : .copyText(text)
        )
        delegate?.launcherViewModel(self, perform: item.action, item: item)
    }

}

private struct CommandUsageRecord: Codable {
    var totalInvocations: Int
    var lastUsedAt: Date
    var recentUses: [Date]
    var sourceApplicationCounts: [String: Int]
}

private final class UsageStore {
    private let recordsKey = "commandUsageRecords"
    private let historyKey = "commandHistory"
    private var records: [String: CommandUsageRecord]
    private var order: [String]

    init() {
        if let data = UserDefaults.standard.data(forKey: recordsKey),
           let decoded = try? JSONDecoder().decode([String: CommandUsageRecord].self, from: data) {
            records = decoded
        } else { records = [:] }
        order = UserDefaults.standard.stringArray(forKey: historyKey) ?? []
    }

    func record(_ identifier: String, sourceApplication: String? = nil) {
        let now = Date()
        var record = records[identifier] ?? CommandUsageRecord(totalInvocations: 0, lastUsedAt: now, recentUses: [], sourceApplicationCounts: [:])
        record.totalInvocations += 1
        record.lastUsedAt = now
        record.recentUses.insert(now, at: 0)
        record.recentUses = Array(record.recentUses.prefix(20))
        if let sourceApplication, !sourceApplication.isEmpty { record.sourceApplicationCounts[sourceApplication, default: 0] += 1 }
        records[identifier] = record
        order.removeAll { $0 == identifier }; order.insert(identifier, at: 0)
        if order.count > 100 { order = Array(order.prefix(100)) }
        if let data = try? JSONEncoder().encode(records) { UserDefaults.standard.set(data, forKey: recordsKey) }
        UserDefaults.standard.set(order, forKey: historyKey)
    }

    func recentIdentifiers(limit: Int) -> [String] { Array(order.prefix(max(0, limit))) }

    func lastIdentifier() -> String? { order.first }

    func forget(_ identifier: String) { records.removeValue(forKey: identifier); order.removeAll { $0 == identifier }; if let data = try? JSONEncoder().encode(records) { UserDefaults.standard.set(data, forKey: recordsKey) }; UserDefaults.standard.set(order, forKey: historyKey) }

    func reset() { records.removeAll(); order.removeAll(); UserDefaults.standard.removeObject(forKey: recordsKey); UserDefaults.standard.removeObject(forKey: historyKey) }

    func score(for identifier: String) -> Double {
        guard let record = records[identifier] else { return 0 }
        let ageDays = max(0, Date().timeIntervalSince(record.lastUsedAt)) / 86_400
        let recency = min(120, max(0, 120 - ageDays * 8))
        let frequency = min(100, log1p(Double(record.totalInvocations)) * 18)
        // Adaptive signals are intentionally bounded; fuzzy/title matching remains dominant.
        return recency + frequency
    }
}
