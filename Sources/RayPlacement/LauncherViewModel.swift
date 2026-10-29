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

/// Session-local history for transient launcher surfaces. The mode itself is
/// retained so returning from a picker does not fabricate a new surface state.
private struct LauncherNavigationFrame {
    let mode: LauncherMode
    let query: String
    let selectedResultID: String?
    let selectedIndex: Int
    let scrollAnchorID: String?
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
                closeAudioOutputPicker()
                let phase = LauncherSearchPhase(query: query)
                if searchPhase != phase { searchPhase = phase }
                closeActionPanel()
                if mode == .root { keyboardNavigationQuery = nil }
                if mode == .root {
                    if let item = selectedItem, item.id != "root.empty" {
                        preferredRootSelectionID = item.id
                    }
                } else {
                    selectedIndex = 0
                }
                if mode == .files {
                    SurfaceStateCache.shared.set(.string(query), for: "files", key: "query")
                }
                if mode == .root && !searchPresented {
                    // A command query may be prepared before the panel appears.
                    // Keep its phase, but defer catalog work until presentation.
                    results = []
                    isSearching = false
                } else {
                    refreshResults()
                }
            }
        }
    }
    @Published private(set) var mode: LauncherMode = .root
    @Published private(set) var searchPhase: LauncherSearchPhase = .idle
    @Published private(set) var isAudioOutputPickerPresented = false
    let audioOutputPicker = AudioOutputPickerModel()
    @Published private(set) var results: [LauncherItem] = []
    @Published private(set) var universalResults: [LimaSearchResult] = []
    /// The emoji picker owns its own lightweight data path. Keeping the raw
    /// catalog out of `results` avoids creating thousands of command models.
    @Published private(set) var emojiMatches: [EmojiEntry] = []
    @Published var selectedIndex = 0
    /// Only keyboard/page navigation increments this value. Pointer hover may
    /// update the highlighted row, but must never recenter the scroll view.
    @Published private(set) var navigationGeneration = 0
    @Published private(set) var scrollRestorationAnchorID: String?
    @Published private(set) var isSearching = false
    @Published private(set) var extensionIssues: [ExtensionIssue] = []
    @Published private(set) var focusGeneration = 0
    @Published var timezoneSourceID: String = LimaTestEnvironment.userDefaults.string(forKey: "timezoneSourceID") ?? TimeZone.current.identifier {
        didSet { LimaTestEnvironment.userDefaults.set(timezoneSourceID, forKey: "timezoneSourceID") }
    }
    @Published var timezoneDestinationID: String = LimaTestEnvironment.userDefaults.string(forKey: "timezoneDestinationID") ?? "UTC" {
        didSet { LimaTestEnvironment.userDefaults.set(timezoneDestinationID, forKey: "timezoneDestinationID") }
    }
    @Published private(set) var timezoneDidCopy = false
    @Published private(set) var contextualSelectionText: String?
    private(set) var sourceApplicationID: String?
    private(set) var sourceApplicationName: String?
    @Published private(set) var actionPanelItem: LauncherItem?
    @Published private(set) var actionPanelSelectedIndex = 0
    @Published private(set) var aliasEditorItem: LauncherItem?
    @Published var aliasEditorDraft = "" { didSet { aliasEditorError = nil } }
    @Published private(set) var aliasEditorError: String?

    weak var delegate: LauncherViewModelDelegate?

    let clipboard: ClipboardHistoryService
    private let applicationIndex = ApplicationIndex()
    private let fileSearch = FileSearchService()
    private let extensionLoader = ExtensionLoader()
    private let usage = UsageStore()
    private let aliasStore = CommandAliasStore()
    private let searchEngine = LauncherSearchEngine()
    /// Each source owns its own command models and normalized documents. A note
    /// edit updates only Notes documents; applications and commands stay cached.
    private enum CatalogSource: CaseIterable {
        case builtins, extensions, applications, macros, notes, shelf, clipboard, outputs
    }
    private var catalogItemsBySource: [CatalogSource: [LauncherItem]] = [:]
    private var catalogInputsBySource: [CatalogSource: [LauncherSearchDocumentInput]] = [:]
    private var catalogDocumentBuildCounts: [CatalogSource: Int] = [:]
    private var rootCatalog: [LauncherItem]?
    private var rootCatalogByID: [String: LauncherItem] = [:]
    private var searchCatalog: SearchCatalogSnapshot?
    private var searchCatalogRevision: UInt64 = 0
    private var localSearchHits: [LauncherSearchHit] = []
    private var rootLocalSearchPending = false
    private var localSearchTask: Task<Void, Never>?
    private var catalogRefreshScheduled = false
    /// Standalone models are presented by default; the live controller updates this
    /// as the panel opens and closes so hidden store changes do not rank a query.
    private var searchPresented = true
    private var applications: [ApplicationRecord] = []
    @Published private(set) var extensionCommands: [LoadedExtensionCommand] = []
    private var fileResults: [URL] = []
    private var rootFileResults: [URL] = []
    private var rootFileSearchPending = false
    private var rootUniversalSearchPending = false
    private var manifestExtensionIssues: [ExtensionIssue] = []
    private var hotkeyExtensionIssues: [ExtensionIssue] = []
    private var searchWorkItem: DispatchWorkItem?
    private var universalSearchTask: Task<Void, Never>?
    private var universalSearchGeneration = 0
    private var lastScheduledRootQuery = ""
    /// Old results remain visible but inert until a response for the latest
    /// query arrives. This prevents a placeholder flash and stale execution.
    private var renderedRootQuery = ""
    private var preferredRootSelectionID: String?
    private var navigationFrames: [LauncherNavigationFrame] = []
    private var keyboardNavigationQuery: String?
    private var visibleSearchScrollAnchorID: String?
    private var clipboardSearchWorkItem: DispatchWorkItem?
    private var clipboardSearchGeneration = 0
    private var clipboardObserver: AnyCancellable?
    private var catalogObservers: [AnyCancellable] = []

    init(clipboard: ClipboardHistoryService, scanApplications: Bool = true) {
        self.clipboard = clipboard
        clipboardObserver = clipboard.$entries.sink { [weak self] _ in
            self?.rootCatalogDidChange(.clipboard)
        }
        catalogObservers = [
            // Observe only searchable collections; selection, editor focus, and
            // other store UI changes must not invalidate the command catalog.
            NotesStore.shared.$notes.sink { [weak self] _ in self?.rootCatalogDidChange(.notes) },
            ContextShelfStore.shared.$items.sink { [weak self] _ in self?.rootCatalogDidChange(.shelf) },
            LimaMacroStore.shared.$chains.sink { [weak self] _ in self?.rootCatalogDidChange(.macros) },
            ExtensionOutputStore.shared.$outputs.sink { [weak self] _ in self?.rootCatalogDidChange(.outputs) },
            CommandManager.shared.$favoriteIDs.sink { [weak self] _ in self?.rootCatalogDidChange() },
            CommandManager.shared.$profiles.sink { [weak self] _ in self?.rootCatalogDidChange() },
            CommandManager.shared.$activeProfileID.sink { [weak self] _ in self?.rootCatalogDidChange() },
            // Only preferences that affect command availability, shortcut labels,
            // or the Clipboard entry can change this catalog.
            SettingsStore.shared.$extensionEnabledOverrides.sink { [weak self] _ in self?.rootCatalogDidChange(.extensions) },
            SettingsStore.shared.$extensionPackEnabledOverrides.sink { [weak self] _ in self?.rootCatalogDidChange(.extensions) },
            SettingsStore.shared.$extensionHotkeyEnabledOverrides.sink { [weak self] _ in self?.rootCatalogDidChange(.extensions) },
            SettingsStore.shared.$extensionShortcutOverrides.sink { [weak self] _ in self?.rootCatalogDidChange(.extensions) },
            SettingsStore.shared.$clipboardEnabled.sink { [weak self] _ in self?.rootCatalogDidChange(.clipboard) },
            SettingsStore.shared.$notesShortcut.sink { [weak self] _ in self?.rootCatalogDidChange(.builtins) },
            SettingsStore.shared.$notesHotkeyEnabled.sink { [weak self] _ in self?.rootCatalogDidChange(.builtins) },
            SettingsStore.shared.$quickNoteShortcut.sink { [weak self] _ in self?.rootCatalogDidChange(.builtins) },
            SettingsStore.shared.$quickNoteHotkeyEnabled.sink { [weak self] _ in self?.rootCatalogDidChange(.builtins) },
            SettingsStore.shared.$dictationShortcut.sink { [weak self] _ in self?.rootCatalogDidChange(.builtins) },
            SettingsStore.shared.$dictationHotkeyEnabled.sink { [weak self] _ in self?.rootCatalogDidChange(.builtins) }
        ]
        reloadExtensions(notify: false)
        if scanApplications {
            applicationIndex.scan { [weak self] records in
                self?.applications = records
                self?.rootCatalogDidChange(.applications)
            }
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
        if mode == .root, searchPhase == .active,
           renderedRootQuery != query.trimmingCharacters(in: .whitespacesAndNewlines) {
            return false
        }
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

    /// Only app identity participates in local ranking. Selection and window
    /// content follow their separate explicit-context paths.
    func setSourceApplication(id: String?, name: String?) {
        guard sourceApplicationID != id || sourceApplicationName != name else { return }
        sourceApplicationID = id
        sourceApplicationName = name
        invalidateSearchDocuments()
        if mode == .root && searchPresented { refreshResults() }
    }

    func refreshForSettings() {
        invalidateRootCatalog()
        if searchPresented { refreshResults() }
    }

    func setSearchPresented(_ presented: Bool) {
        guard searchPresented != presented else { return }
        searchPresented = presented
        if presented {
            if mode == .root, searchPhase == .active { refreshRootResults() }
        } else {
            closeAudioOutputPicker()
            navigationFrames.removeAll()
            keyboardNavigationQuery = nil
            visibleSearchScrollAnchorID = nil
            scrollRestorationAnchorID = nil
            searchWorkItem?.cancel()
            localSearchTask?.cancel()
            universalSearchTask?.cancel()
            fileSearch.cancel()
            universalSearchGeneration += 1
            localSearchHits = []
            rootLocalSearchPending = false
            rootFileSearchPending = false
            rootUniversalSearchPending = false
            isSearching = false
            if mode == .root {
                universalResults = []
                rootFileResults = []
                results = []
                selectedIndex = 0
                renderedRootQuery = ""
                preferredRootSelectionID = nil
            }
        }
    }

    func openAudioOutputPicker() {
        guard mode == .root else { return }
        isAudioOutputPickerPresented = true
        audioOutputPicker.start()
    }

    func closeAudioOutputPicker() {
        guard isAudioOutputPickerPresented else { return }
        isAudioOutputPickerPresented = false
        audioOutputPicker.stop()
    }

    private func rootCatalogDidChange(_ source: CatalogSource? = nil) {
        invalidateRootCatalog(source)
        guard searchPresented, mode == .root, searchPhase == .active,
              !catalogRefreshScheduled else { return }
        // Published values arrive after willChange. Coalesce source events and
        // rebuild only the changed sections after stores commit their values.
        catalogRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.catalogRefreshScheduled = false
            guard self.searchPresented, self.mode == .root,
                  self.searchPhase == .active else { return }
            self.refreshResults()
        }
    }

    private func invalidateRootCatalog(_ source: CatalogSource? = nil) {
        rootCatalog = nil
        rootCatalogByID = [:]
        searchCatalog = nil
        if let source {
            catalogItemsBySource.removeValue(forKey: source)
            catalogInputsBySource.removeValue(forKey: source)
        } else {
            catalogItemsBySource.removeAll()
            catalogInputsBySource.removeAll()
        }
    }

    private func catalogItems(for source: CatalogSource) -> [LauncherItem] {
        if let cached = catalogItemsBySource[source] { return cached }
        let items: [LauncherItem]
        switch source {
        case .builtins: items = builtInItems()
        case .extensions: items = extensionItems()
        case .applications: items = applicationItems()
        case .macros: items = macroItems()
        case .notes: items = noteItems()
        case .shelf: items = shelfItems()
        case .clipboard: items = clipboardItems()
        case .outputs: items = outputItems()
        }
        catalogItemsBySource[source] = items
        return items
    }

    private func rootCatalogItems() -> [LauncherItem] {
        if let rootCatalog { return rootCatalog }
        let items = CatalogSource.allCases.flatMap(catalogItems(for:))
        rootCatalog = items
        rootCatalogByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return items
    }

    private func localSearchCatalog() -> SearchCatalogSnapshot {
        if let searchCatalog { return searchCatalog }
        _ = rootCatalogItems()
        let inputs = CatalogSource.allCases.flatMap { source -> [LauncherSearchDocumentInput] in
            if let cached = catalogInputsBySource[source] { return cached }
            let clipboardText: [String: String] = source == .clipboard
                ? Dictionary(clipboard.entries.prefix(500).map {
                    ("clipboard.\($0.id)", String($0.text.prefix(8_000)))
                }, uniquingKeysWith: { first, _ in first }) : [:]
            let extensionAliases: [String: [String]] = source == .extensions
                ? Dictionary(extensionCommands.map {
                    ("extension.\($0.extensionID).\($0.command.id)", $0.command.aliases ?? [])
                }, uniquingKeysWith: { first, _ in first }) : [:]
            let built = catalogItems(for: source).map { item -> LauncherSearchDocumentInput in
                let favoriteRank = CommandManager.shared.favoriteRank(item.id)
                let favoriteBonus = favoriteRank == Int.max ? 0 : max(0, 500 - Double(favoriteRank * 20))
                return LauncherSearchDocumentInput(
                    item: item, searchText: clipboardText[item.id],
                    userAliases: aliasStore.isEnabled(for: item.id) ? aliasStore.aliases(for: item.id) : [],
                    extensionAliases: extensionAliases[item.id] ?? [],
                    rankingBonus: usage.score(for: item.id, sourceApplicationID: sourceApplicationID,
                                              sourceApplicationName: sourceApplicationName) + favoriteBonus
                )
            }
            catalogInputsBySource[source] = built
            catalogDocumentBuildCounts[source, default: 0] += 1
            return built
        }
        searchCatalogRevision &+= 1
        let snapshot = SearchCatalogSnapshot(revision: searchCatalogRevision, inputs: inputs)
        searchCatalog = snapshot
        return snapshot
    }

    /// Test synchronization point for the debounced local actor search. Tests
    /// should assert a settled result rather than the first-keypress placeholder.
    func waitForLocalSearchForTesting() async {
        await localSearchTask?.value
    }

    #if DEBUG
    func searchDocumentBuildCountForTesting(_ source: String) -> Int {
        guard let source = CatalogSource.allCases.first(where: { String(describing: $0) == source }) else { return 0 }
        return catalogDocumentBuildCounts[source, default: 0]
    }
    #endif

    func aliases(for commandID: String) -> [String] { aliasStore.aliases(for: commandID) }

    func openAliasEditor(for item: LauncherItem) {
        guard mode == .root, commandDescriptors.contains(where: { $0.id == item.id }) else { return }
        closeActionPanel()
        aliasEditorDraft = ""
        aliasEditorError = nil
        aliasEditorItem = item
    }

    func closeAliasEditor() {
        aliasEditorItem = nil
        aliasEditorDraft = ""
        aliasEditorError = nil
    }

    @discardableResult
    func saveAliasDraft() -> Bool {
        guard let item = aliasEditorItem else { return false }
        let alias = aliasEditorDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty, alias.count <= 64,
              !alias.contains(","), !alias.contains("\n") else {
            aliasEditorError = "Enter one alias of up to 64 characters without commas."
            return false
        }
        if let error = setAliases(aliases(for: item.id) + [alias], for: item.id) {
            aliasEditorError = error
            return false
        }
        closeAliasEditor()
        return true
    }

    func aliasesEnabled(for commandID: String) -> Bool { aliasStore.isEnabled(for: commandID) }

    func aliasConflict(_ aliases: [String], for commandID: String) -> String? {
        let normalized = CommandAliasStore.normalize(aliases)
        for alias in normalized {
            if let titleOwner = commandDescriptors.first(where: {
                $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == alias
            }) {
                return "“\(alias)” matches the exact title of \(titleOwner.title)."
            }
            if let extensionOwner = extensionCommands.first(where: {
                $0.command.aliases?.contains(where: {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == alias
                }) == true
            }) {
                return "“\(alias)” is provided by \(extensionOwner.command.title)."
            }
        }
        if let conflict = aliasStore.conflict(for: normalized, excluding: commandID) {
            let owner = commandDescriptors.first(where: { $0.id == conflict.commandID })?.title ?? conflict.commandID
            return "“\(conflict.alias)” is already assigned to \(owner)."
        }
        return nil
    }

    private func invalidateSearchDocuments() {
        searchCatalog = nil
        catalogInputsBySource.removeAll()
    }

    @discardableResult
    func setAliases(_ aliases: [String], for commandID: String) -> String? {
        if let conflict = aliasConflict(aliases, for: commandID) { return conflict }
        if let conflict = aliasStore.set(aliases, for: commandID) {
            return "“\(conflict.alias)” is already assigned to another command."
        }
        invalidateSearchDocuments()
        refreshResults()
        return nil
    }

    func setAliasesEnabled(_ enabled: Bool, for commandID: String) {
        objectWillChange.send()
        aliasStore.setEnabled(enabled, for: commandID)
        invalidateSearchDocuments()
        refreshResults()
    }
    func resetLearnedRanking() { usage.reset(); invalidateSearchDocuments(); refreshResults() }
    func forgetLearnedRanking(_ commandID: String) { usage.forget(commandID); invalidateSearchDocuments(); refreshResults() }
    func lastLearnedCommands(limit: Int = 10) -> [String] { usage.recentIdentifiers(limit: limit) }
    var learnedSourceApplications: [SearchLearningApplication] { usage.knownSourceApplications }
    func isSourceApplicationExcluded(_ id: String) -> Bool { usage.isExcluded(id) }
    func setSourceApplicationExcluded(_ excluded: Bool, id: String) {
        objectWillChange.send()
        usage.setExcluded(excluded, id: id)
        invalidateSearchDocuments()
        if mode == .root && searchPresented { refreshResults() }
    }

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
        navigationFrames.removeAll()
        keyboardNavigationQuery = nil
        visibleSearchScrollAnchorID = nil
        scrollRestorationAnchorID = nil
        closeAliasEditor()
        searchWorkItem?.cancel()
        localSearchTask?.cancel()
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
        navigationFrames.removeAll()
        preferredRootSelectionID = nil
        visibleSearchScrollAnchorID = nil
        scrollRestorationAnchorID = nil
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
        guard (mode == .files || mode == .root), let item = selectedItem else { return nil }
        switch item.action {
        case .openFile(let url), .fileAction(let url, _), .revealFile(let url): return url
        default: return nil
        }
    }

    func enter(_ newMode: LauncherMode) {
        if newMode == .root {
            navigationFrames.removeAll()
        } else if newMode != mode {
            navigationFrames.append(currentNavigationFrame())
        }
        transition(to: newMode, restoring: nil)
    }

    /// Pop exactly one launcher surface. At the root, the caller decides
    /// whether Escape dismisses the panel; it never cancels background work.
    @discardableResult
    func navigateBack() -> Bool {
        if aliasEditorItem != nil {
            closeAliasEditor()
            return true
        }
        if actionPanelItem != nil {
            closeActionPanel()
            return true
        }
        if let frame = navigationFrames.popLast() {
            transition(to: frame.mode, restoring: frame)
            return true
        }
        guard mode != .root else { return false }
        transition(to: .root, restoring: nil)
        return true
    }

    func recordSearchScrollAnchor(_ id: String?) {
        guard mode == .root, scrollRestorationAnchorID == nil else { return }
        visibleSearchScrollAnchorID = id
    }

    func consumeSearchScrollRestorationAnchor(_ id: String) {
        guard scrollRestorationAnchorID == id else { return }
        scrollRestorationAnchorID = nil
        visibleSearchScrollAnchorID = id
    }

    private func currentNavigationFrame() -> LauncherNavigationFrame {
        LauncherNavigationFrame(
            mode: mode, query: query,
            selectedResultID: selectedItem?.id,
            selectedIndex: selectedIndex,
            scrollAnchorID: mode == .root ? visibleSearchScrollAnchorID : nil
        )
    }

    private func transition(to newMode: LauncherMode, restoring frame: LauncherNavigationFrame?) {
        searchWorkItem?.cancel()
        localSearchTask?.cancel()
        rootLocalSearchPending = false
        localSearchHits = []
        universalSearchTask?.cancel()
        clipboardSearchWorkItem?.cancel()
        fileSearch.cancel()
        rootFileSearchPending = false
        rootUniversalSearchPending = false
        rootFileResults = []
        mode = newMode
        results = []
        selectedIndex = frame?.selectedIndex ?? 0
        preferredRootSelectionID = newMode == .root ? frame?.selectedResultID : nil
        visibleSearchScrollAnchorID = newMode == .root ? frame?.scrollAnchorID : nil
        scrollRestorationAnchorID = newMode == .root ? frame?.scrollAnchorID : nil
        let nextQuery: String
        if let frame {
            nextQuery = frame.query
        } else if newMode == .files {
            nextQuery = SurfaceStateCache.shared.string(for: "files", key: "query") ?? ""
        } else {
            nextQuery = ""
        }
        if query != nextQuery {
            query = nextQuery
        } else {
            refreshResults()
        }
        if newMode != .root, let id = frame?.selectedResultID,
           let index = results.firstIndex(where: { $0.id == id }) {
            selectedIndex = index
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
        enter(.output(title: title, text: text, state: state))
    }

    func showWritingReview(_ review: WritingReview) {
        enter(.writingReview(review))
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
        rootCatalogDidChange(.extensions)
        if notify { delegate?.launcherViewModelDidReloadExtensions(self) }
    }

    @discardableResult
    func repairBundledExtensions() -> String {
        let report = extensionLoader.repairBundledExtensions()
        let loaded = extensionLoader.load()
        extensionCommands = loaded.commands
        manifestExtensionIssues = loaded.issues
        updateExtensionIssues()
        rootCatalogDidChange(.extensions)
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
        if mode == .root {
            preferredRootSelectionID = selectedItem?.id
            if renderedRootQuery == query.trimmingCharacters(in: .whitespacesAndNewlines) {
                keyboardNavigationQuery = renderedRootQuery
            }
        }
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
        if mode == .root { preferredRootSelectionID = selectedItem?.id }
    }

    func openActionPanel(for item: LauncherItem? = nil) {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        guard let item = item ?? selectedItem, isActionable(item) else { return }
        actionPanelSelectedIndex = 0
        actionPanelItem = item
        LauncherPerformanceDiagnostics.shared.mark("action-panel-open", startedAt: startedAt, budget: 50)
    }

    func closeActionPanel() {
        actionPanelItem = nil
        actionPanelSelectedIndex = 0
    }

    func moveActionPanelSelection(by delta: Int) {
        guard let item = actionPanelItem else { return }
        let count = actionPanelActions(for: item).count
        guard count > 0 else { return }
        actionPanelSelectedIndex = min(max(actionPanelSelectedIndex + delta, 0), count - 1)
    }

    func executeSelectedPanelAction() {
        guard let item = actionPanelItem else { return }
        let actions = actionPanelActions(for: item)
        guard actions.indices.contains(actionPanelSelectedIndex) else { return }
        executeAction(actions[actionPanelSelectedIndex])
    }

    func actionPanelActions(for item: LauncherItem) -> [LauncherItemAction] {
        var capabilities = LimaActionRegistry.Capabilities()
        capabilities.isFavorite = CommandManager.shared.isFavorite(item.id)

        switch item.action {
        case .fileAction(let url, _), .openFile(let url), .revealFile(let url):
            capabilities.objectExists = FileManager.default.fileExists(atPath: url.path)
            capabilities.canOpenInCode = capabilities.objectExists &&
                ["com.microsoft.VSCode", "com.visualstudio.code.oss"].contains {
                    NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
                }
            capabilities.canAttachFileToAI = capabilities.objectExists &&
                AIRequestPolicy.shared.isEnabled &&
                AIFileAttachmentPolicy.canAttach(AIContextCapture.attachment(for: url))
        case .launchApplication(let url):
            capabilities.objectExists = FileManager.default.fileExists(atPath: url.path)
            capabilities.runningApplicationPID = NSWorkspace.shared.runningApplications.first {
                $0.bundleURL == url || $0.localizedName == item.title
            }?.processIdentifier
        default:
            capabilities.canEditAlias = commandDescriptors.contains { $0.id == item.id }
            if let context = contextValue(for: item) {
                capabilities.contextActions = LimaCompatibilityRegistry.shared.actions(for: context).map {
                    LauncherItemAction(id: "use-with.\($0.id)", title: $0.title,
                                       symbol: $0.symbol, shortcut: nil,
                                       role: .secondary, action: $0.action)
                }
            }
        }
        return LimaActionRegistry.actions(for: item, capabilities: capabilities)
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
            if result.kind == .dictation,
               let id = UUID(uuidString: String(result.id.dropFirst("dictation:".count))),
               let conversation = DictationConversationStore.shared.conversations.first(where: { $0.id == id }) {
                return LimaContextValue(id: id, kind: .text, title: result.title, value: conversation.transcript)
            }
            return nil
        case .note(let id):
            guard let note = NotesStore.shared.notes.first(where: { $0.id == id }) else { return nil }
            return LimaContextValue(id: note.id, kind: .note, title: note.title, value: note.content)
        case .shelfItem(let id):
            guard let shelf = ContextShelfStore.shared.items.first(where: { $0.id == id }) else { return nil }
            // Mail references need a scoped resolver and disclosure review; the
            // generic Use With path must not turn their preview into AI context.
            if shelf.isMailReference || shelf.isMessageReference || shelf.isBrowserReference { return nil }
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
        if case .editAlias(let id) = action.action {
            guard id == item.id else { return }
            openAliasEditor(for: item)
            return
        }
        recordUsage(for: item)
        delegate?.launcherViewModel(self, perform: action.action, item: item)
    }

    func repeatLastAction() {
        guard let identifier = usage.lastIdentifier() else { return }
        let items = rootCatalogItems()
        guard let item = items.first(where: { $0.id == identifier }) else { return }
        execute(item: item)
    }

    private func execute(item: LauncherItem) {
        recordUsage(for: item)
        delegate?.launcherViewModel(self, perform: item.action, item: item)
    }

    private func recordUsage(for item: LauncherItem) {
        if item.id.hasPrefix("emoji."), case .pasteText(let emoji) = item.action {
            EmojiUsageStore.shared.record(emoji)
        } else {
            usage.record(item.id, sourceApplicationID: sourceApplicationID,
                         sourceApplicationName: sourceApplicationName)
            invalidateSearchDocuments()
        }
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
        if !navigateBack() {
            delegate?.launcherViewModelDidRequestHide(self)
        }
    }

    func goBackIfPossible() -> Bool {
        guard query.isEmpty, mode != .root else { return false }
        return navigateBack()
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
        // Non-query triggers (selection, aliases, learned ranking) can arrive
        // after the panel closes. Never rebuild or rank a hidden root search.
        guard searchPresented else {
            lastScheduledRootQuery = ""
            results = []
            renderedRootQuery = ""
            preferredRootSelectionID = nil
            isSearching = false
            return
        }
        let keepPreviousResults = results.contains { $0.id != "root.empty" }
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = UniversalSearchCoordinator.parse(cleanQuery)
        universalSearchGeneration += 1
        let generation = universalSearchGeneration
        localSearchTask?.cancel()
        universalSearchTask?.cancel()
        searchWorkItem?.cancel()
        fileSearch.cancel()
        localSearchHits = []
        universalResults = []
        rootFileResults = []
        rootLocalSearchPending = false
        rootFileSearchPending = false
        rootUniversalSearchPending = false
        guard !parsed.query.isEmpty else {
            lastScheduledRootQuery = ""
            results = []
            renderedRootQuery = ""
            preferredRootSelectionID = nil
            selectedIndex = 0
            isSearching = false
            return
        }
        // Show the first query after an empty composer without a fixed delay;
        // only subsequent keystrokes need coalescing.
        let debounceMilliseconds = lastScheduledRootQuery.isEmpty ? 0 : 35
        lastScheduledRootQuery = parsed.query
        let shouldSearchFiles = (parsed.prefix == nil || parsed.prefix == "file") && parsed.query.count >= 2
        rootLocalSearchPending = true
        rootUniversalSearchPending = true
        rootFileSearchPending = shouldSearchFiles
        isSearching = true
        if !keepPreviousResults {
            results = rootResults()
            renderedRootQuery = cleanQuery
            selectedIndex = 0
        }
        localSearchTask = Task { [weak self] in
            // Yield one turn for first-keypress focus; debounce rapid edits.
            if debounceMilliseconds == 0 { await Task.yield() }
            else { try? await Task.sleep(for: .milliseconds(debounceMilliseconds)) }
            guard !Task.isCancelled, let self else { return }
            let catalog = self.localSearchCatalog()
            let response = await self.searchEngine.search(
                LauncherSearchRequest(rawQuery: cleanQuery, generation: generation),
                catalog: catalog
            )
            guard !Task.isCancelled, self.searchPresented, self.mode == .root,
                  response.generation == self.universalSearchGeneration,
                  self.query.trimmingCharacters(in: .whitespacesAndNewlines) == cleanQuery else { return }
            self.localSearchHits = response.hits
            self.rootLocalSearchPending = false
            self.isSearching = self.rootUniversalSearchPending || self.rootFileSearchPending
            self.publishRootResults(for: cleanQuery)
        }
        if shouldSearchFiles {
            let request = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.fileSearch.search(parsed.query) { [weak self] urls in
                    guard let self, self.mode == .root,
                          self.universalSearchGeneration == generation,
                          self.query.trimmingCharacters(in: .whitespacesAndNewlines) == cleanQuery else { return }
                    self.rootFileResults = Array(urls.prefix(12))
                    self.rootFileSearchPending = false
                    self.isSearching = self.rootLocalSearchPending || self.rootUniversalSearchPending
                    self.publishRootResults(for: cleanQuery)
                }
            }
            searchWorkItem = request
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: request)
        }
        let searchStartedAt = Date()
        universalSearchTask = Task { [weak self] in
            // Start the first query promptly; coalesce later keystrokes before
            // capturing provider snapshots or ranking workspace documents.
            if debounceMilliseconds == 0 { await Task.yield() }
            else { try? await Task.sleep(for: .milliseconds(debounceMilliseconds)) }
            guard !Task.isCancelled else { return }
            let found = await UniversalSearchCoordinator.shared.search(cleanQuery)
            let wasCancelled = Task.isCancelled
            await MainActor.run {
                PerformanceMonitor.shared.record(
                    .universalSearchQueryToResults,
                    startedAt: searchStartedAt,
                    duration: max(0, Date().timeIntervalSince(searchStartedAt)),
                    succeeded: !wasCancelled,
                )
            }
            guard !wasCancelled else { return }
            await MainActor.run {
                guard let self,
                      self.mode == .root,
                      self.universalSearchGeneration == generation,
                      self.query.trimmingCharacters(in: .whitespacesAndNewlines) == cleanQuery else { return }
                self.universalResults = found
                self.rootUniversalSearchPending = false
                self.isSearching = self.rootLocalSearchPending || self.rootFileSearchPending
                self.publishRootResults(for: cleanQuery)
            }
        }
    }

    private func publishRootResults(for query: String) {
        let fresh = rootResults()
        let stillRanking = rootLocalSearchPending || rootFileSearchPending || rootUniversalSearchPending
        if fresh.count == 1, fresh[0].id == "root.empty", stillRanking,
           results.contains(where: { $0.id != "root.empty" }) {
            // Do not replace useful prior rows with an interim placeholder.
            return
        }
        let selectedID = preferredRootSelectionID ?? selectedItem?.id
        let previousIndex = selectedIndex
        results = SearchSelectionCoordinator.orderedResults(
            current: results,
            incoming: fresh,
            preserveCurrentOrder: keyboardNavigationQuery == query && renderedRootQuery == query
        )
        renderedRootQuery = query
        selectedIndex = SearchSelectionCoordinator.selectedIndex(
            in: results, preferredID: selectedID, previousIndex: previousIndex,
            isActionable: isActionable
        )
        if !rootLocalSearchPending && !rootFileSearchPending && !rootUniversalSearchPending {
            preferredRootSelectionID = nil
        }
    }

    private func universalItem(_ result: LimaSearchResult) -> LauncherItem {
        let icon: LauncherIcon
        switch result.kind {
        case .note: icon = .system("note.text")
        case .dictation: icon = .system("waveform")
        case .aiConversation: icon = .system("bubble.left.and.bubble.right")
        case .terminal: icon = .system("terminal.fill")
        case .command: icon = .system("arrow.trianglehead.2.clockwise.rotate.90")
        case .workspace: icon = .system("square.stack.3d.up")
        case .context: icon = .system("tray.full")
        case .clipboard: icon = .system("clipboard")
        case .screenshot: icon = .system("photo.on.rectangle")
        case .messages: icon = .system(MessagesSearchResultID.isReply(result.id)
                                                ? "square.and.pencil" : "message")
        default: icon = .system("magnifyingglass")
        }
        return LauncherItem(
            id: result.id.replacingOccurrences(of: ":", with: "."),
            title: result.title,
            subtitle: result.subtitle,
            icon: icon,
            keywords: result.keywords,
            action: result.kind == .note && UUID(uuidString: String(result.id.dropFirst("note:".count))) != nil
                ? .note(UUID(uuidString: String(result.id.dropFirst("note:".count)))!) : .universalSearch(result),
            accessory: result.kind == .screenshot ? "Copy Image" :
                (MessagesSearchResultID.isReply(result.id) ? "Review Reply" : "Open")
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
            return (item, score + intentBonus + usage.score(for: item.id, sourceApplicationID: sourceApplicationID,
                                                    sourceApplicationName: sourceApplicationName) + favoriteBonus)
        }.sorted { first, second in
            if first.1 == second.1 { return first.0.title.localizedStandardCompare(second.0.title) == .orderedAscending }
            return first.1 > second.1
        }.map { $0.0 }
        let localIDs = Set(ranked.map { $0.id })
        let universal: [LauncherItem] = universalResults.filter { !localIDs.contains($0.id) }.map { universalItem($0) }
        return Array((ranked + universal).prefix(24))
    }

    private func rootResults() -> [LauncherItem] {
        // The idle launcher has no result rows or hidden keyboard targets.
        guard !UniversalSearchCoordinator.parse(query).query.isEmpty else { return [] }
        let parsed = UniversalSearchCoordinator.parse(query)
        let cleanQuery = parsed.query
        // Deliberately undocumented developer gate; never part of the catalog.
        if cleanQuery == "🤖" {
            return [LauncherItem(
                id: "developer.grammar-settings", title: "Grammar Engine",
                subtitle: "Configure an enhanced proofreading provider",
                icon: .system("lock.shield.fill"), keywords: [],
                action: .system(.openDeveloperGrammarSettings), accessory: "Developer"
            )]
        }

        // Only a small set of per-query actions is assembled on MainActor.
        // The full command/app/Clipboard catalog has already been ranked by
        // LauncherSearchEngine and arrives here as bounded identifier hits.
        var dynamic: [LauncherItem] = []
        if parsed.prefix == nil {
            if let selection = contextualSelectionText {
                dynamic += contextualItems(for: selection)
            }
            if let calculator = calculatorResult(for: cleanQuery) {
                dynamic.append(calculator)
            }
            if let conversion = measurementConversionResult(for: cleanQuery) {
                dynamic.append(conversion)
            }
            dynamic += directInvocationItems(for: cleanQuery)
        }
        dynamic += rootFileResults.map(fileItem)
        let localIDs = Set(localSearchHits.map(\.id))
        dynamic += universalResults.map(universalItem).filter { !localIDs.contains($0.id) }
        let providerScores = Dictionary(universalResults.map {
            ($0.id.replacingOccurrences(of: ":", with: "."), 14_000 + $0.score)
        }, uniquingKeysWith: max)

        let localRanked: [(LauncherItem, Double)] = localSearchHits.compactMap { hit in
            guard var item = rootCatalogByID[hit.id] else { return nil }
            item.aliasKind = hit.aliasKind
            return (item, hit.score)
        }
        let dynamicRanked: [(LauncherItem, Double)] = dynamic.compactMap { item in
            // Provider matches may come from full note/transcript content,
            // not the visible preview. Keep that score when local text misses.
            guard let baseScore = searchScore(for: item, query: cleanQuery)
                ?? providerScores[item.id] else { return nil }
            let provenance = aliasProvenance(for: item, query: cleanQuery)
            var rankedItem = item
            rankedItem.aliasKind = provenance.kind
            let favoriteRank = CommandManager.shared.favoriteRank(item.id)
            let favoriteBonus = favoriteRank == Int.max ? 0 : max(0, 500 - Double(favoriteRank * 20))
            return (rankedItem, baseScore + provenance.bonus + usage.score(for: item.id, sourceApplicationID: sourceApplicationID,
                                                               sourceApplicationName: sourceApplicationName) + favoriteBonus)
        }
        let ranked = (localRanked + dynamicRanked).sorted { first, second in
            if first.1 == second.1 {
                return first.0.title.localizedStandardCompare(second.0.title) == .orderedAscending
            }
            return first.1 > second.1
        }
        if ranked.isEmpty {
            let subtitle = isSearching ? "Searching Spotlight and your workspace…" : "Try another app, file, or command name"
            return [placeholderItem(id: "root.empty", title: isSearching ? "Searching…" : "No results",
                                    subtitle: subtitle, icon: "magnifyingglass")]
        }
        return Array(ranked.prefix(24).map(\.0))
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
        if aliasStore.isEnabled(for: item.id),
           aliasStore.aliases(for: item.id).contains(where: { $0.lowercased() == normalizedQuery }) {
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
            let entriesByEmoji = Dictionary(uniqueKeysWithValues: EmojiCatalog.entries.map { ($0.emoji, $0) })
            let recent = EmojiUsageStore.shared.recentEmojis(limit: 80).compactMap { entriesByEmoji[$0] }
            let recentIDs = Set(recent.map(\.id))
            matching = recent + EmojiCatalog.entries.filter { !recentIDs.contains($0.id) }
        } else {
            let exact = EmojiCatalog.search(cleanQuery) { EmojiUsageStore.shared.score(for: $0.emoji) }
            if !exact.isEmpty {
                matching = exact
            } else {
                matching = EmojiCatalog.entries.compactMap { entry -> (EmojiEntry, Double)? in
                    guard let fuzzy = FuzzyMatcher.score(entry.searchableText, query: cleanQuery) else { return nil }
                    let usageTieBreak = min(0.9, EmojiUsageStore.shared.score(for: entry.emoji) / 250)
                    return (entry, fuzzy + usageTieBreak)
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
        let items = rootCatalogItems()
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

    private func noteItems() -> [LauncherItem] {
        NotesStore.shared.notes.prefix(30).map { note in
            LauncherItem(id: "note.\(note.id.uuidString)", title: note.title, subtitle: note.content.prefix(80).description, icon: .system("note.text"), keywords: note.tags + ["note", "markdown"], action: .note(note.id), accessory: note.isFavorite ? "Favorite" : "Note", aliasKind: nil)
        }
    }

    private func shelfItems() -> [LauncherItem] {
        ContextShelfStore.shared.items.prefix(30).map { item in
            LauncherItem(id: "shelf.\(item.id.uuidString)", title: item.title, subtitle: item.preview, icon: .system("tray.full"), keywords: ["shelf", item.kind.rawValue], action: .shelfItem(item.id), accessory: item.isPinned ? "Pinned" : "Shelf", aliasKind: nil)
        }
    }

    private func clipboardItems() -> [LauncherItem] {
        clipboard.entries.prefix(500).map { entry in
            LauncherItem(id: "clipboard.\(entry.id.uuidString)", title: String(entry.text.prefix(70)), subtitle: "Clipboard entry", icon: .system("clipboard"), keywords: ["clipboard", "copy", "paste"], action: .clipboardEntry(entry.id), accessory: entry.pinned ? "Pinned" : "Clipboard", aliasKind: nil)
        }
    }

    private func outputItems() -> [LauncherItem] {
        ExtensionOutputStore.shared.outputs.prefix(30).map { output in
            LauncherItem(id: "output.\(output.id.uuidString)", title: output.title, subtitle: String(output.value.prefix(80)), icon: .system("text.quote"), keywords: ["output", output.descriptor.kind.rawValue], action: .extensionOutput(output.id), accessory: "Output", aliasKind: nil)
        }
    }

    private func macroItems() -> [LauncherItem] {
        LimaMacroStore.shared.chains.map { chain in
            LauncherItem(id: "macro.\(chain.id.uuidString)", title: chain.name, subtitle: "Run \(chain.steps.count) registered action\(chain.steps.count == 1 ? "" : "s")", icon: .system("bolt.horizontal.circle"), keywords: ["macro", "chain", "automation"], action: .macro(chain.id), accessory: "Macro")
        }
    }

    private func builtInItems() -> [LauncherItem] {
        let items: [LauncherItem] = [
            LauncherItem(id: "builtin.search-files", title: "Search Files", subtitle: "Find files with Spotlight", icon: .system("doc.text.magnifyingglass"), keywords: ["finder", "document", "open"], action: .enterMode(.files)),
            LauncherItem(id: "builtin.notes", title: "Lima Notes", subtitle: "Open Notes in the unified Workspace", icon: .system("note.text"), keywords: ["notes", "markdown", "write"], action: .system(.openNotes), shortcut: SettingsStore.shared.notesHotkeyEnabled ? ShortcutSpec(string: SettingsStore.shared.notesShortcut)?.displayString : nil),
            LauncherItem(id: "builtin.create-note", title: "New Note", subtitle: "Create and open a local note", icon: .system("square.and.pencil"), keywords: ["notes", "create", "capture", "write"], action: .system(.createNote)),
            LauncherItem(id: "builtin.ai-chat", title: "Open AI Chat", subtitle: "Start a private, provider-configurable conversation", icon: .system("sparkles"), keywords: ["ai", "chat", "openai", "assistant", "conversation"], action: .system(.openAIChat)),
            LauncherItem(id: "builtin.quick-note", title: "Quick Note Sidebar", subtitle: "Pin the most recent note beside your current app", icon: .system("rectangle.righthalf.inset.filled"), keywords: ["notes", "dock", "side", "sidebar", "capture"], action: .system(.openQuickNote), shortcut: SettingsStore.shared.quickNoteHotkeyEnabled ? ShortcutSpec(string: SettingsStore.shared.quickNoteShortcut)?.displayString : nil),
            LauncherItem(id: "builtin.note-dictation", title: "Start or Stop Dictation", subtitle: "Capture live speech into a dictation conversation", icon: .system("mic.fill"), keywords: ["notes", "meeting", "speech", "transcribe"], action: .system(.toggleNoteDictation), shortcut: SettingsStore.shared.dictationHotkeyEnabled ? ShortcutSpec(string: SettingsStore.shared.dictationShortcut)?.displayString : nil),
            LauncherItem(id: "builtin.capture-clipboard-note", title: "Capture Clipboard to Note", subtitle: "Create and open a local note from current clipboard text", icon: .system("clipboard.fill"), keywords: ["capture", "notes", "paste", "save"], action: .system(.captureClipboardToNote)),
            LauncherItem(id: "builtin.capture-selection-note", title: "Capture Selection to Note", subtitle: "Create and open a local note from selected text in another app", icon: .system("text.badge.plus"), keywords: ["capture", "notes", "highlight", "selected text"], action: .system(.captureSelectionToNote)),
            LauncherItem(id: "builtin.capture-dictation-note", title: "Dictate into Current Note", subtitle: "Start or stop speech capture in the visible note", icon: .system("mic.badge.plus"), keywords: ["capture", "notes", "speech", "transcribe"], action: .system(.dictateIntoNote)),
            LauncherItem(id: "builtin.transcripts", title: "Open Transcripts", subtitle: "Review your local dictation history", icon: .system("waveform"), keywords: ["dictation", "speech", "history"], action: .system(.openTranscripts)),
            LauncherItem(id: "builtin.grammar", title: "Open Grammar", subtitle: "Review local writing tools", icon: .system("textformat.abc"), keywords: ["writing", "proofread", "spelling"], action: .system(.openGrammarWorkspace)),
            LauncherItem(id: "builtin.formatter", title: "Open Formatter", subtitle: "Format structured text in Workspace", icon: .system("curlybraces"), keywords: ["json", "text", "format"], action: .system(.openFormatter)),
            // The terminal is an optional developer surface. Keeping it out of
            // the catalog entirely makes the setting apply to search as well as
            // the default command list.
            LauncherItem(id: "builtin.terminal", title: "Terminal", subtitle: "Run commands in a local zsh terminal", icon: .system("terminal.fill"), keywords: ["shell", "console", "command", "vim", "nano", "developer", "term", ">"], action: .system(.openTerminal)),
            LauncherItem(id: "builtin.context-shelf", title: "Context Shelf", subtitle: "Temporary working memory for text, files, and tool output", icon: .system("tray.full"), keywords: ["shelf", "context", "working", "memory", "capture", "stash", "save selection"], action: .system(.openContextShelf)),
            LauncherItem(id: "builtin.screenshot-studio", title: "Screenshot Studio", subtitle: "Choose a window or display to capture, or browse history", icon: .system("camera.viewfinder"), keywords: ["screenshot", "capture screen", "capture window", "screen recording", "image history"], action: .system(.openScreenshotStudio)),
            LauncherItem(id: "builtin.quick-capture-region", title: "Quick Capture Region", subtitle: "Select a region and copy its image to the clipboard", icon: .system("rectangle.dashed"), keywords: ["screenshot", "region", "capture", "clipboard", "image"], action: .system(.quickCaptureRegion)),
            LauncherItem(id: "builtin.text-reader-region", title: "Text Reader Region", subtitle: "Select a region and copy locally recognized text", icon: .system("text.viewfinder"), keywords: ["ocr", "region", "text", "reader", "clipboard"], action: .system(.textReaderRegion)),
            LauncherItem(id: "builtin.audio-output", title: "Switch Audio Output", subtitle: "Choose speakers, headphones, or another system output", icon: .system("speaker.wave.2"), keywords: ["audio", "audio output", "sound", "speaker", "speakers", "headphones", "airpods", "output device"], action: .system(.openAudioOutput)),
            LauncherItem(id: "builtin.network-quality", title: "Internet Speed Test", subtitle: "Open network diagnostics; run a test only when you choose", icon: .system("speedometer"), keywords: ["speed", "internet", "network", "bandwidth", "latency", "connection"], action: .system(.openNetworkQuality)),
            LauncherItem(id: "builtin.add-selection-to-shelf", title: "Add Selection to Shelf", subtitle: "Capture highlighted text without opening Lima", icon: .system("text.badge.plus"), keywords: ["add", "selection", "capture", "shelf", "highlight"], action: .system(.addSelectionToShelf)),
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
        let allowed = CharacterSet(charactersIn: "0123456789.,+-*/%^() πesqrtSQRT")
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

    private func measurementConversionResult(for query: String) -> LauncherItem? {
        guard let result = SearchMeasurementConversion.convert(query) else { return nil }
        return LauncherItem(
            id: "conversion.\(query)",
            title: result.formatted,
            subtitle: "Conversion — press Return to copy",
            icon: .system("ruler"),
            keywords: [query],
            action: .copyText(result.formatted),
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

struct SearchLearningApplication: Identifiable, Equatable {
    let id: String
    let name: String
}

/// Local, bounded Search learning. A source app is metadata only: no window
/// title, selection, document contents, or provider input is recorded here.
final class UsageStore {
    private let recordsKey = "commandUsageRecords"
    private let historyKey = "commandHistory"
    private let applicationNamesKey = "commandUsageApplicationNames"
    private let excludedApplicationsKey = "commandUsageExcludedApplications"
    private let defaults: UserDefaults
    private var records: [String: CommandUsageRecord]
    private var order: [String]
    private var applicationNames: [String: String]
    private var excludedApplications: Set<String>

    init(defaults: UserDefaults = LimaTestEnvironment.userDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: recordsKey),
           let decoded = try? JSONDecoder().decode([String: CommandUsageRecord].self, from: data) {
            records = decoded
        } else { records = [:] }
        order = defaults.stringArray(forKey: historyKey) ?? []
        applicationNames = defaults.dictionary(forKey: applicationNamesKey) as? [String: String] ?? [:]
        excludedApplications = Set(defaults.stringArray(forKey: excludedApplicationsKey) ?? [])
    }

    var knownSourceApplications: [SearchLearningApplication] {
        let recorded = Set(records.values.flatMap { $0.sourceApplicationCounts.keys })
        let ids = Set(applicationNames.keys).union(recorded).union(excludedApplications)
        return ids.map { SearchLearningApplication(id: $0, name: applicationNames[$0] ?? $0) }
            .sorted {
                let comparison = $0.name.localizedStandardCompare($1.name)
                return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
            }
    }

    func isExcluded(_ id: String) -> Bool { excludedApplications.contains(id) }

    func setExcluded(_ excluded: Bool, id: String) {
        guard !id.isEmpty else { return }
        if excluded { excludedApplications.insert(id) } else { excludedApplications.remove(id) }
        defaults.set(excludedApplications.sorted(), forKey: excludedApplicationsKey)
    }

    private func sourceKey(id: String?, name: String?) -> String? {
        if let id, !id.isEmpty { return id }
        if let name, !name.isEmpty { return name }
        return nil
    }

    private func excludesSource(id: String?, name: String?) -> Bool {
        (id.map(excludedApplications.contains) == true) ||
        (name.map(excludedApplications.contains) == true)
    }

    func record(_ identifier: String, sourceApplicationID: String? = nil, sourceApplicationName: String? = nil) {
        guard !excludesSource(id: sourceApplicationID, name: sourceApplicationName) else { return }
        let now = Date()
        var record = records[identifier] ?? CommandUsageRecord(totalInvocations: 0, lastUsedAt: now, recentUses: [], sourceApplicationCounts: [:])
        record.totalInvocations += 1
        record.lastUsedAt = now
        record.recentUses.insert(now, at: 0)
        record.recentUses = Array(record.recentUses.prefix(20))
        if let source = sourceKey(id: sourceApplicationID, name: sourceApplicationName) {
            if record.sourceApplicationCounts[source] != nil || record.sourceApplicationCounts.count < 64 {
                record.sourceApplicationCounts[source, default: 0] += 1
            }
            if applicationNames[source] != nil || applicationNames.count < 128 {
                applicationNames[source] = sourceApplicationName ?? source
                defaults.set(applicationNames, forKey: applicationNamesKey)
            }
        }
        records[identifier] = record
        order.removeAll { $0 == identifier }; order.insert(identifier, at: 0)
        if order.count > 100 { order = Array(order.prefix(100)) }
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: recordsKey) }
        defaults.set(order, forKey: historyKey)
    }

    func recentIdentifiers(limit: Int) -> [String] { Array(order.prefix(max(0, limit))) }

    func lastIdentifier() -> String? { order.first }

    func forget(_ identifier: String) {
        records.removeValue(forKey: identifier)
        order.removeAll { $0 == identifier }
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: recordsKey) }
        defaults.set(order, forKey: historyKey)
    }

    /// Reset learned behavior without silently removing user-owned exclusions.
    func reset() {
        records.removeAll()
        order.removeAll()
        applicationNames.removeAll()
        defaults.removeObject(forKey: recordsKey)
        defaults.removeObject(forKey: historyKey)
        defaults.removeObject(forKey: applicationNamesKey)
    }

    func score(for identifier: String, sourceApplicationID: String? = nil, sourceApplicationName: String? = nil) -> Double {
        guard let record = records[identifier] else { return 0 }
        let ageDays = max(0, Date().timeIntervalSince(record.lastUsedAt)) / 86_400
        let recency = min(120, max(0, 120 - ageDays * 8))
        let frequency = min(100, log1p(Double(record.totalInvocations)) * 18)
        // Context is a bounded tie-breaker; exact titles and explicit aliases
        // keep their separate deterministic priority in LauncherSearchEngine.
        guard !excludesSource(id: sourceApplicationID, name: sourceApplicationName),
              let source = sourceKey(id: sourceApplicationID, name: sourceApplicationName) else {
            return recency + frequency
        }
        let contextualUses = record.sourceApplicationCounts[source]
            ?? (sourceApplicationName.flatMap { record.sourceApplicationCounts[$0] } ?? 0)
        let context = min(80, log1p(Double(contextualUses)) * 24)
        return recency + frequency + context
    }
}
