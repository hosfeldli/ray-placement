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
    @Published var query = "" {
        didSet {
            if oldValue != query {
                selectedIndex = 0
                refreshResults()
            }
        }
    }
    @Published private(set) var mode: LauncherMode = .root
    @Published private(set) var results: [LauncherItem] = []
    @Published var selectedIndex = 0
    @Published private(set) var isSearching = false
    @Published private(set) var extensionIssues: [ExtensionIssue] = []
    @Published private(set) var focusGeneration = 0

    weak var delegate: LauncherViewModelDelegate?

    let clipboard: ClipboardHistoryService
    private let applicationIndex = ApplicationIndex()
    private let fileSearch = FileSearchService()
    private let extensionLoader = ExtensionLoader()
    private let usage = UsageStore()
    private var applications: [ApplicationRecord] = []
    @Published private(set) var extensionCommands: [LoadedExtensionCommand] = []
    private var fileResults: [URL] = []
    private var manifestExtensionIssues: [ExtensionIssue] = []
    private var hotkeyExtensionIssues: [ExtensionIssue] = []
    private var searchWorkItem: DispatchWorkItem?
    private var clipboardSearchWorkItem: DispatchWorkItem?
    private var clipboardSearchGeneration = 0
    private var clipboardObserver: AnyCancellable?

    init(clipboard: ClipboardHistoryService) {
        self.clipboard = clipboard
        clipboardObserver = clipboard.$entries.sink { [weak self] _ in
            guard let self, self.mode == .clipboard else { return }
            self.refreshResults()
        }
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
        case .vscodePicker: return "Search for a file or directory to open in VS Code…"
        case .clipboard: return "Search clipboard history…"
        case .writingReview: return "Writing review"
        case .output: return "Command output"
        }
    }

    var selectedItem: LauncherItem? {
        guard results.indices.contains(selectedIndex) else { return nil }
        return results[selectedIndex]
    }

    var selectedItemIsActionable: Bool {
        guard let selectedItem else { return false }
        return isActionable(selectedItem)
    }

    var hasActionableResults: Bool {
        results.contains(where: isActionable)
    }

    func isActionable(_ item: LauncherItem) -> Bool {
        if case .noOp = item.action { return false }
        return true
    }

    func resetForPresentation() {
        searchWorkItem?.cancel()
        clipboardSearchWorkItem?.cancel()
        fileSearch.cancel()
        mode = .root
        query = ""
        selectedIndex = 0
        focusGeneration += 1
        refreshResults()
    }

    func enter(_ newMode: LauncherMode) {
        searchWorkItem?.cancel()
        clipboardSearchWorkItem?.cancel()
        fileSearch.cancel()
        mode = newMode
        query = ""
        selectedIndex = 0
        refreshResults()
    }

    func showOutput(title: String, text: String, isError: Bool = false) {
        mode = .output(title: title, text: text, isError: isError)
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

    func reloadExtensions(notify: Bool = true) {
        let loaded = extensionLoader.load()
        extensionCommands = loaded.commands
        manifestExtensionIssues = loaded.issues
        updateExtensionIssues()
        refreshResults()
        if notify { delegate?.launcherViewModelDidReloadExtensions(self) }
    }

    func setExtensionHotkeyIssues(_ issues: [ExtensionIssue]) {
        hotkeyExtensionIssues = issues
        updateExtensionIssues()
    }

    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + results.count) % results.count
    }

    func select(_ index: Int) {
        guard results.indices.contains(index) else { return }
        selectedIndex = index
    }

    func executeSelected() {
        guard let item = selectedItem, isActionable(item) else { return }
        usage.record(item.id)
        delegate?.launcherViewModel(self, perform: item.action, item: item)
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
        switch mode {
        case .root:
            isSearching = false
            results = rootResults()
        case .files, .vscodePicker:
            refreshFileResults()
        case .clipboard:
            refreshClipboardResults()
        case .writingReview:
            isSearching = false
            results = []
        case .output:
            isSearching = false
            results = []
        }
        if results.isEmpty { selectedIndex = 0 }
        else { selectedIndex = min(selectedIndex, results.count - 1) }
    }

    private func rootResults() -> [LauncherItem] {
        var items = builtInItems() + extensionItems() + applicationItems()
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if !cleanQuery.isEmpty, let result = calculatorResult(for: cleanQuery) {
            items.insert(result, at: 0)
        }

        guard !cleanQuery.isEmpty else {
            let priority = [
                "builtin.search-files", "builtin.clipboard", "window.leftHalf", "window.rightHalf",
                "window.maximize", "builtin.extensions-folder", "builtin.settings", "builtin.reload-extensions"
            ]
            let defaults = priority.compactMap { id in items.first { $0.id == id } }
            let recent = items
                .filter { !priority.contains($0.id) && usage.score(for: $0.id) > 0 }
                .sorted { usage.score(for: $0.id) > usage.score(for: $1.id) }
            return Array((recent + defaults).prefix(11))
        }

        let ranked = items.compactMap { item -> (LauncherItem, Double)? in
            let titleScore = FuzzyMatcher.score(item.title, query: cleanQuery)
            let allScore = FuzzyMatcher.score(item.searchableText, query: cleanQuery)
            let score = max(titleScore ?? -.infinity, allScore ?? -.infinity)
            guard score.isFinite else { return nil }
            return (item, score + usage.score(for: item.id))
        }
        .sorted { first, second in
            if first.1 == second.1 { return first.0.title.localizedStandardCompare(second.0.title) == .orderedAscending }
            return first.1 > second.1
        }
        .prefix(12)
        .map(\.0)
        if ranked.isEmpty {
            return [placeholderItem(id: "root.empty", title: "No results", subtitle: "Try another app or command name", icon: "magnifyingglass")]
        }
        return ranked
    }

    private func refreshFileResults() {
        searchWorkItem?.cancel()
        let requestedMode = mode
        let opensInVSCode = requestedMode == .vscodePicker
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty else {
            isSearching = false
            fileResults = []
            results = [placeholderItem(
                id: opensInVSCode ? "vscode.hint" : "files.hint",
                title: opensInVSCode ? "Type a file or directory name" : "Type a file name",
                subtitle: opensInVSCode ? "Choose any Spotlight result to open it in VS Code" : "Results come from Spotlight",
                icon: opensInVSCode ? "chevron.left.forwardslash.chevron.right" : "magnifyingglass"
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
                        id: opensInVSCode ? "vscode.empty" : "files.empty",
                        title: opensInVSCode ? "No files or directories found" : "No files found",
                        subtitle: "Try a broader name",
                        icon: "doc.text.magnifyingglass"
                    )]
                    : urls.map { self.fileItem($0, opensInVSCode: opensInVSCode) }
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

    private func extensionItems() -> [LauncherItem] {
        extensionCommands.map { loaded in
            LauncherItem(
                id: "extension.\(loaded.extensionID).\(loaded.command.id)",
                title: loaded.command.title,
                subtitle: loaded.command.subtitle ?? loaded.extensionName,
                icon: .system(loaded.command.icon ?? "puzzlepiece.extension.fill"),
                keywords: loaded.command.keywords ?? [],
                action: .extensionCommand(loaded),
                shortcut: SettingsStore.shared.effectiveShortcut(for: loaded)
                    .flatMap { ShortcutSpec(string: $0)?.displayString }
            )
        }
    }

    private func builtInItems() -> [LauncherItem] {
        var items: [LauncherItem] = [
            LauncherItem(id: "builtin.search-files", title: "Search Files", subtitle: "Find files with Spotlight", icon: .system("doc.text.magnifyingglass"), keywords: ["finder", "document", "open"], action: .enterMode(.files)),
            LauncherItem(id: "builtin.clipboard", title: "Clipboard History", subtitle: "Search text copied on this Mac", icon: .system("clipboard.fill"), keywords: ["copy", "paste", "history"], action: .enterMode(.clipboard)),
            LauncherItem(id: "builtin.lock", title: "Lock Screen", subtitle: "Secure this Mac", icon: .system("lock.fill"), keywords: ["system", "security"], action: .system(.lockScreen)),
            LauncherItem(id: "builtin.screensaver", title: "Start Screen Saver", subtitle: "System", icon: .system("sparkles.tv"), keywords: ["display", "system"], action: .system(.startScreenSaver)),
            LauncherItem(id: "builtin.sleep", title: "Put Mac to Sleep", subtitle: "System", icon: .system("moon.zzz.fill"), keywords: ["system", "power"], action: .system(.sleep)),
            LauncherItem(id: "builtin.extensions-folder", title: "Open Extensions Folder", subtitle: "Add commands without rebuilding", icon: .system("folder.badge.gearshape"), keywords: ["plugin", "custom", "script", "functionality"], action: .system(.openExtensionsFolder)),
            LauncherItem(id: "builtin.reload-extensions", title: "Reload Extensions", subtitle: "Pick up manifest changes", icon: .system("arrow.clockwise"), keywords: ["plugin", "refresh"], action: .system(.reloadExtensions)),
            LauncherItem(id: "builtin.settings", title: "RayPlacement Settings", subtitle: "Hotkey, startup, clipboard, and extensions", icon: .system("gearshape.fill"), keywords: ["preferences", "hotkey", "shortcut"], action: .system(.openSettings), shortcut: "⌘,"),
            LauncherItem(id: "builtin.quit", title: "Quit RayPlacement", subtitle: "System", icon: .system("power"), keywords: ["exit"], action: .system(.quit), shortcut: "⌘Q")
        ]
        items.insert(contentsOf: WindowLayout.allCases.map { layout in
            LauncherItem(
                id: "window.\(layout.rawValue)",
                title: layout.title,
                subtitle: "Window Management",
                icon: .system(layout.symbol),
                keywords: ["window", "resize", "move"],
                action: .window(layout)
            )
        }, at: 2)
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

    private func fileItem(_ url: URL, opensInVSCode: Bool = false) -> LauncherItem {
        LauncherItem(
            id: "\(opensInVSCode ? "vscode" : "file").\(url.path)",
            title: url.lastPathComponent,
            subtitle: url.deletingLastPathComponent().path,
            icon: .file(url),
            keywords: [url.path],
            action: opensInVSCode ? .openInVSCode(url) : .openFile(url),
            accessory: opensInVSCode ? "Open in VS Code" : nil
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

private final class UsageStore {
    private let key = "commandUsage"
    private var values: [String: Double]

    init() {
        values = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
    }

    func record(_ identifier: String) {
        values[identifier] = Date().timeIntervalSince1970
        UserDefaults.standard.set(values, forKey: key)
    }

    func score(for identifier: String) -> Double {
        guard let timestamp = values[identifier] else { return 0 }
        let ageInDays = max(0, Date().timeIntervalSince1970 - timestamp) / 86_400
        return max(0, 800 - ageInDays * 15)
    }
}
