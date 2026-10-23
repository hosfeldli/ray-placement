import AppKit
import SwiftUI
import WebKit

private struct BrowserScreenshotMask: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var isValid: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite &&
            width > 0 && height > 0 && width <= 10_000 && height <= 10_000
    }

    func isNear(_ other: Self) -> Bool {
        abs(x - other.x) <= 2 && abs(y - other.y) <= 2 &&
            abs(width - other.width) <= 2 && abs(height - other.height) <= 2
    }
}

private struct BrowserScreenshotRedaction: Codable {
    let identity: BrowserPageIdentity
    let complete: Bool
    let rects: [BrowserScreenshotMask]
}

private final class BrowserFrameMessageHandler: NSObject, WKScriptMessageHandler {
    weak var tab: BrowserTab?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let frameID = body["frameID"] as? String,
              frameID != "main", frameID.count <= 100 else { return }
        let frameInfo = message.frameInfo
        Task { @MainActor [weak tab] in
            tab?.registerFrame(frameID, info: frameInfo)
        }
    }
}

enum BrowserTabPurpose: String, Sendable {
    case research
    case localServer
    case userBrowsing
}

struct BrowserTabContext: Equatable, Sendable {
    var projectID: UUID?
    var serverID: UUID?
    var purpose: BrowserTabPurpose
}

@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    let id = UUID()
    @Published private(set) var title = "New Tab"
    @Published private(set) var urlString = ""
    @Published private(set) var isLoading = false
    @Published private(set) var isSuspended = true
    @Published private(set) var webProcessAlive = true
    @Published var context: BrowserTabContext?
    private(set) var navigationRevision = 0
    private(set) var completedNavigationRevision = 0
    private(set) var failedNavigationRevision = 0
    private var navigationSequences: [ObjectIdentifier: Int] = [:]
    private(set) var isRestoring = false
    private(set) var restoreFailed = false
    var openPopup: ((WKWebViewConfiguration) -> WKWebView?)?
    private let configuration: WKWebViewConfiguration
    private var liveWebView: WKWebView?
    private var restoreURL: URL?
    private var requestedNavigationURL: URL?
    private let frameMessageHandler = BrowserFrameMessageHandler()
    private var frameInfoByID: [String: WKFrameInfo] = [:]
    private var frameOrder: [String] = []

    init(configuration: WKWebViewConfiguration) {
        self.configuration = configuration
        super.init()
        frameMessageHandler.tab = self
    }

    /// Only the selected tab and bounded in-flight tabs need a WebKit view.
    /// Reading a suspended tab creates a fresh document; old semantic targets
    /// are revoked by BrowserWorkspaceModel before this can happen.
    var webView: WKWebView {
        if let liveWebView { return liveWebView }
        // A popup configuration can inherit its opener's content controller.
        // Give every live view its own isolated handlers and document scripts.
        configuration.userContentController = WKUserContentController()
        configuration.userContentController.add(
            frameMessageHandler, contentWorld: .world(name: BrowserSemanticScript.world),
            name: BrowserSemanticScript.frameHandler
        )
        configuration.userContentController.addUserScript(
            WKUserScript(source: BrowserSemanticScript.install,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: false,
                         in: .world(name: BrowserSemanticScript.world))
        )
        // Detached background pages still need a viewport for visibility and
        // semantic geometry; the selected view is resized by SwiftUI.
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                             configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        liveWebView = view
        webProcessAlive = true
        isSuspended = false
        restoreFailed = false
        if let restoreURL, BrowserRuntime.safeDestination(restoreURL.absoluteString) != nil {
            isRestoring = true
            requestedNavigationURL = restoreURL
            view.load(URLRequest(url: restoreURL))
        }
        return view
    }

    var activeWebView: WKWebView? { liveWebView }
    var hasLiveWebView: Bool { liveWebView != nil }

    func requestNavigation(to url: URL) {
        restoreURL = url
        requestedNavigationURL = url
        urlString = url.absoluteString
    }

    func deferNavigation(to url: URL) {
        requestNavigation(to: url)
        title = url.host ?? "New Tab"
        isLoading = false
        isSuspended = true
        isRestoring = false
        restoreFailed = false
    }

    @discardableResult
    func suspend() -> Bool {
        guard let view = liveWebView else { return false }
        restoreURL = requestedNavigationURL ??
            view.url.flatMap { BrowserRuntime.safeDestination($0.absoluteString) } ??
            BrowserRuntime.safeDestination(urlString)
        requestedNavigationURL = nil
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.removeFromSuperview()
        liveWebView = nil
        navigationSequences.removeAll()
        isLoading = false
        isSuspended = true
        isRestoring = false
        restoreFailed = false
        frameInfoByID.removeAll()
        frameOrder.removeAll()
        return true
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationRevision &+= 1
        if let navigation { navigationSequences[ObjectIdentifier(navigation)] = navigationRevision }
        isLoading = true
        restoreFailed = false
        frameInfoByID.removeAll()
        frameOrder.removeAll()
        updateIdentity()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let navigation, let sequence = navigationSequences.removeValue(forKey: ObjectIdentifier(navigation)) {
            completedNavigationRevision = max(completedNavigationRevision, sequence)
        }
        isLoading = false
        isRestoring = false
        webProcessAlive = true
        requestedNavigationURL = nil
        updateIdentity()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webProcessAlive = false
        isLoading = false
        updateIdentity()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if let navigation, let sequence = navigationSequences.removeValue(forKey: ObjectIdentifier(navigation)) {
            failedNavigationRevision = max(failedNavigationRevision, sequence)
        }
        isLoading = false
        restoreFailed = isRestoring
        isRestoring = false
        requestedNavigationURL = nil
        updateIdentity()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if let navigation, let sequence = navigationSequences.removeValue(forKey: ObjectIdentifier(navigation)) {
            failedNavigationRevision = max(failedNavigationRevision, sequence)
        }
        isLoading = false
        restoreFailed = isRestoring
        isRestoring = false
        requestedNavigationURL = nil
        updateIdentity()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if url.scheme == "about" { return .allow }
        return BrowserRuntime.safeDestination(url.absoluteString) == nil ? .cancel : .allow
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        if let url = navigationAction.request.url,
           BrowserRuntime.safeDestination(url.absoluteString) == nil { return nil }
        return openPopup?(configuration)
    }

    func registerFrame(_ id: String, info: WKFrameInfo) {
        guard !info.isMainFrame else { return }
        if frameInfoByID[id] == nil { frameOrder.append(id) }
        frameInfoByID[id] = info
        if frameOrder.count > 32 {
            frameInfoByID.removeValue(forKey: frameOrder.removeFirst())
        }
    }

    var registeredFrames: [(String, WKFrameInfo)] {
        frameOrder.compactMap { id in frameInfoByID[id].map { (id, $0) } }
    }

    func frameInfo(for id: String) -> WKFrameInfo? { frameInfoByID[id] }

    func updateIdentity() {
        guard let liveWebView else { return }
        if let value = liveWebView.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty { title = String(decoding: value.utf8.prefix(512), as: UTF8.self) }
        if let value = liveWebView.url?.absoluteString, !value.isEmpty {
            urlString = value
            restoreURL = liveWebView.url
        }
    }
}

@MainActor
final class BrowserWorkspaceModel: ObservableObject {
    static let shared = BrowserWorkspaceModel(persistPreferences: true)

    /// Installed by the workspace window owner. Browser tools use this only for
    /// foreground AI actions; background research never steals the user's focus.
    var onAIForegroundTab: ((UUID) -> Bool)?

    func revealAIForegroundTab(_ id: UUID) -> Bool {
        guard selectedTabID == id else { return false }
        return onAIForegroundTab?(id) ?? false
    }

    @Published private(set) var tabs: [BrowserTab] = []
    @Published private(set) var selectedTabID: UUID?
    @Published var aiControlMode: BrowserAIControlMode {
        didSet {
            if persistPreferences {
                LimaTestEnvironment.userDefaults.set(aiControlMode.rawValue, forKey: "limaBrowserAIControlMode")
            }
            if aiControlMode != oldValue {
                automation = nil
                aiFocus = nil
                for tab in tabs { revokeBrowserState(for: tab.id) }
            }
        }
    }
    @Published var showAIPointer: Bool {
        didSet { if persistPreferences { LimaTestEnvironment.userDefaults.set(showAIPointer, forKey: "limaBrowserShowAIPointer") } }
    }
    @Published var highlightAITargets: Bool {
        didSet { if persistPreferences { LimaTestEnvironment.userDefaults.set(highlightAITargets, forKey: "limaBrowserHighlightAITargets") } }
    }
    @Published var showActionDescriptions: Bool {
        didSet { if persistPreferences { LimaTestEnvironment.userDefaults.set(showActionDescriptions, forKey: "limaBrowserShowActionDescriptions") } }
    }
    @Published private(set) var pausedTabIDs: Set<UUID> = []
    @Published private(set) var automation: BrowserAutomationState?
    @Published private(set) var aiFocus: BrowserAIFocusState?
    @Published private(set) var aiActivity: [BrowserAIActivity] = []
    private var lastAIPointerPositionByTabID: [UUID: CGPoint] = [:]
    private var visualHits: [UUID: BrowserVisualHit] = [:]
    private var needsFreshReadTabIDs: Set<UUID> = []
    private var userChangedTabIDs: Set<UUID> = []
    private var authorityRevisions: [UUID: UInt64] = [:]
    private var readRevisions: [UUID: UInt64] = [:]
    private var lastReadinessByTabID: [UUID: BrowserReadiness] = [:]
    private let maximumLiveWebViews = 6
    private var liveTabOrder: [UUID] = []
    private var activeOperationCounts: [UUID: Int] = [:]
    private struct PendingRevocation {
        let id: UUID
        let task: Task<Void, Never>
    }
    private var pendingRevocations: [UUID: PendingRevocation] = [:]
    private var userEventMonitor: Any?

    private let runtime: BrowserRuntime
    private let dataStore: WKWebsiteDataStore
    private let persistPreferences: Bool

    init(runtime: BrowserRuntime = .shared, dataStore: WKWebsiteDataStore? = nil,
         persistPreferences: Bool = false) {
        self.runtime = runtime
        self.dataStore = dataStore ?? .default()
        self.persistPreferences = persistPreferences
        let defaults = LimaTestEnvironment.userDefaults
        aiControlMode = BrowserAIControlMode(
            rawValue: defaults.string(forKey: "limaBrowserAIControlMode") ?? ""
        ) ?? .fullControl
        showAIPointer = defaults.object(forKey: "limaBrowserShowAIPointer") as? Bool ?? true
        highlightAITargets = defaults.object(forKey: "limaBrowserHighlightAITargets") as? Bool ?? true
        showActionDescriptions = defaults.object(forKey: "limaBrowserShowActionDescriptions") as? Bool ?? true
        userEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]
        ) { [weak self] event in
            self?.handleUserEvent(event)
            return event
        }
    }

    deinit {
        if let userEventMonitor { NSEvent.removeMonitor(userEventMonitor) }
    }

    func beginAIActivity(_ toolName: String, tabID: UUID?) -> UUID {
        let id = UUID()
        aiActivity.append(BrowserAIActivity(
            id: id, tabID: tabID, title: BrowserAIActivity.title(for: toolName),
            state: .working
        ))
        if aiActivity.count > 40 { aiActivity.removeFirst(aiActivity.count - 40) }
        return id
    }

    func finishAIActivity(_ id: UUID, result: LimaAIToolExecution) {
        guard let index = aiActivity.firstIndex(where: { $0.id == id }) else { return }
        aiActivity[index].tabID = result.browserTabID ?? aiActivity[index].tabID
        aiActivity[index].state = result.isError ? .failed : .completed
    }

    func activityState(for tabID: UUID) -> BrowserAIActivity.State? {
        aiActivity.last(where: { $0.tabID == tabID })?.state
    }

    private func handleUserEvent(_ event: NSEvent) {
        guard let tab = selectedTab,
              let webView = tab.activeWebView,
              webView.window === event.window else { return }
        let isPageEvent: Bool
        if event.type == .keyDown {
            isPageEvent = (webView.window?.firstResponder as? NSView)?.isDescendant(of: webView) == true
        } else {
            isPageEvent = webView.bounds.contains(webView.convert(event.locationInWindow, from: nil))
        }
        guard isPageEvent else { return }
        markPageChangedByUser(tab.id)
    }

    /// Human input invalidates stale semantic targets without permanently
    /// revoking the assistant's ability to reread the tab.
    func markPageChangedByUser(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        userChangedTabIDs.insert(id)
        automation = nil
        aiFocus = nil
        revokeBrowserState(for: id)
    }

    func pauseAI(on id: UUID) {
        guard tabs.contains(where: { $0.id == id }), !pausedTabIDs.contains(id) else { return }
        pausedTabIDs.insert(id)
        automation = nil
        aiFocus = nil
        revokeBrowserState(for: id)
    }

    func resumeAI(on id: UUID) throws {
        _ = try tab(id)
        pausedTabIDs.remove(id)
        needsFreshReadTabIDs.insert(id)
    }

    private func requireAIAccess(_ id: UUID) throws {
        guard !pausedTabIDs.contains(id) else { throw BrowserRuntimeError.userPaused }
    }

    private func requireFreshTarget(_ id: UUID) throws {
        try requireAIAccess(id)
        guard !needsFreshReadTabIDs.contains(id) else {
            throw userChangedTabIDs.contains(id) ? BrowserRuntimeError.pageChangedByUser : BrowserRuntimeError.missingSnapshot
        }
    }

    func isResultAccessible(on id: UUID) -> Bool {
        aiControlMode.canRead && !pausedTabIDs.contains(id) &&
            !needsFreshReadTabIDs.contains(id) && tabs.contains(where: { $0.id == id })
    }

    func isScreenshotCurrent(_ capture: BrowserScreenshotResult) -> Bool {
        isResultAccessible(on: capture.tabID) &&
            Date().timeIntervalSince(capture.capturedAt) >= 0 &&
            Date().timeIntervalSince(capture.capturedAt) <= 120 &&
            authorityRevisions[capture.tabID, default: 0] == capture.authorityRevision &&
            readRevisions[capture.tabID, default: 0] == capture.readRevision
    }

    var selectedTab: BrowserTab? { tabs.first { $0.id == selectedTabID } }
    var liveWebViewCount: Int { tabs.filter(\.hasLiveWebView).count }

    var authoritySnapshot: BrowserAuthoritySnapshot {
        let id = selectedTabID
        let selected = selectedTab
        return BrowserAuthoritySnapshot(
            available: true, controlMode: aiControlMode, tabCount: tabs.count,
            selectedTabID: id, explicitlyPaused: id.map { pausedTabIDs.contains($0) } ?? false,
            pageRevision: id.map { authorityRevisions[$0, default: 0] },
            needsFreshRead: id.map { needsFreshReadTabIDs.contains($0) } ?? false,
            liveWebViews: liveWebViewCount,
            lastReadiness: id.flatMap { lastReadinessByTabID[$0] },
            runtimeHealthy: selected?.webProcessAlive ?? true
        )
    }

    private func useLiveView(_ tab: BrowserTab) -> WKWebView {
        let view = tab.webView
        liveTabOrder.removeAll { $0 == tab.id }
        liveTabOrder.append(tab.id)
        trimLiveWebViews(protecting: tab.id)
        return view
    }

    private func beginOperation(on id: UUID) {
        activeOperationCounts[id, default: 0] += 1
    }

    private func endOperation(on id: UUID) {
        let remaining = (activeOperationCounts[id] ?? 1) - 1
        if remaining <= 0 { activeOperationCounts.removeValue(forKey: id) }
        else { activeOperationCounts[id] = remaining }
        trimLiveWebViews()
    }

    private func revokeBrowserState(for id: UUID) {
        authorityRevisions[id, default: 0] &+= 1
        needsFreshReadTabIDs.insert(id)
        lastReadinessByTabID.removeValue(forKey: id)
        visualHits = visualHits.filter { $0.value.tabID != id }
        if automation?.tabID == id, automation?.role == "visualReview" {
            automation = nil
            aiFocus = nil
        }
        let previous = pendingRevocations[id]?.task
        let runtime = self.runtime
        let task = Task {
            await previous?.value
            await runtime.remove(tabID: id)
            await AIToolOutputStore.shared.removeBrowserResults(for: id)
            await BrowserScreenshotStore.shared.remove(for: id)
        }
        pendingRevocations[id] = PendingRevocation(id: UUID(), task: task)
    }

    private func awaitRevocation(for id: UUID) async {
        while let pending = pendingRevocations[id] {
            await pending.task.value
            if pendingRevocations[id]?.id == pending.id {
                pendingRevocations.removeValue(forKey: id)
            }
        }
    }

    private func trimLiveWebViews(protecting protectedID: UUID? = nil) {
        while liveWebViewCount > maximumLiveWebViews {
            let candidates = liveTabOrder.filter { id in
                id != selectedTabID && id != protectedID &&
                    tabs.first(where: { $0.id == id })?.activeWebView?.window == nil &&
                    tabs.first(where: { $0.id == id })?.hasLiveWebView == true
            }
            // Prefer idle views, but do not exceed the cap if all background
            // views are busy. Revocation makes any evicted operation fail stale.
            guard let victimID = candidates.first(where: { activeOperationCounts[$0] == nil })
                    ?? candidates.first,
                  let victim = tabs.first(where: { $0.id == victimID }),
                  victim.suspend() else { break }
            liveTabOrder.removeAll { $0 == victimID }
            revokeBrowserState(for: victimID)
        }
    }

    func clearWebsiteData() async {
        await withCheckedContinuation { continuation in
            dataStore.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast
            ) {
                continuation.resume()
            }
        }
        await BrowserScreenshotStore.shared.clear()
        await AIToolOutputStore.shared.clearBrowserResults(includeOrphans: true)
        for tab in tabs {
            authorityRevisions[tab.id, default: 0] &+= 1
            needsFreshReadTabIDs.insert(tab.id)
            await runtime.remove(tabID: tab.id)
        }
    }

    @discardableResult
    func newTab(url: URL? = nil, foreground: Bool = true,
                context: BrowserTabContext? = nil,
                configuration: WKWebViewConfiguration? = nil) -> BrowserTab {
        let isPopupConfiguration = configuration != nil
        let configuration = configuration ?? WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let tab = BrowserTab(configuration: configuration)
        tab.context = context
        if let url { tab.deferNavigation(to: url) }
        tab.openPopup = { [weak self] configuration in
            guard let self else { return nil }
            let popup = self.newTab(foreground: true, configuration: configuration)
            return self.useLiveView(popup)
        }
        tabs.append(tab)
        let willSelect = foreground || selectedTabID == nil
        if willSelect { selectedTabID = tab.id }
        if (willSelect && url != nil) || isPopupConfiguration {
            // The lazy view consumes the requested URL once. Do not start a
            // second load, which could discard a newly opened page or popup.
            _ = useLiveView(tab)
        }
        trimLiveWebViews(protecting: tab.id)
        return tab
    }

    func tab(_ id: UUID) throws -> BrowserTab {
        guard let tab = tabs.first(where: { $0.id == id }) else { throw BrowserRuntimeError.missingTab }
        return tab
    }

    func tab(projectID: UUID, serverID: UUID) -> BrowserTab? {
        tabs.first { $0.context?.projectID == projectID && $0.context?.serverID == serverID &&
            $0.context?.purpose == .localServer }
    }

    @discardableResult
    func openServer(_ url: URL, projectID: UUID, serverID: UUID) throws -> BrowserTab {
        guard let safe = BrowserRuntime.safeDestination(url.absoluteString),
              safe.scheme?.lowercased() == "http",
              let host = safe.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1"].contains(host),
              safe.port != nil else { throw BrowserRuntimeError.invalidDestination }
        if let existing = tab(projectID: projectID, serverID: serverID) {
            try focus(existing.id)
            if existing.urlString == safe.absoluteString {
                try reload(existing.id)
            } else {
                try navigate(existing.id, to: safe)
            }
            return existing
        }
        return newTab(url: safe, foreground: true,
                      context: BrowserTabContext(projectID: projectID, serverID: serverID, purpose: .localServer))
    }

    func focus(_ id: UUID) throws {
        let tab = try tab(id)
        let wasSuspended = tab.isSuspended
        selectedTabID = id
        if tab.hasLiveWebView || !tab.urlString.isEmpty { _ = useLiveView(tab) }
        if wasSuspended { needsFreshReadTabIDs.insert(id) }
        trimLiveWebViews(protecting: id)
    }

    func close(_ id: UUID) async throws {
        let tab = try tab(id)
        tab.activeWebView?.stopLoading()
        tabs.removeAll { $0.id == id }
        liveTabOrder.removeAll { $0 == id }
        activeOperationCounts.removeValue(forKey: id)
        authorityRevisions.removeValue(forKey: id)
        readRevisions.removeValue(forKey: id)
        pausedTabIDs.remove(id)
        lastAIPointerPositionByTabID.removeValue(forKey: id)
        needsFreshReadTabIDs.remove(id)
        userChangedTabIDs.remove(id)
        await runtime.remove(tabID: id)
        await AIToolOutputStore.shared.removeBrowserResults(for: id)
        await BrowserScreenshotStore.shared.remove(for: id)
        if selectedTabID == id {
            selectedTabID = tabs.first?.id
            if let selectedTabID { try? focus(selectedTabID) }
        }
        trimLiveWebViews()
    }

    func navigate(_ id: UUID, to url: URL) throws {
        guard let safe = BrowserRuntime.safeDestination(url.absoluteString) else {
            throw BrowserRuntimeError.invalidDestination
        }
        let tab = try tab(id)
        revokeBrowserState(for: id)
        if let view = tab.activeWebView {
            tab.requestNavigation(to: safe)
            view.load(URLRequest(url: safe))
        } else {
            tab.deferNavigation(to: safe)
            _ = useLiveView(tab)
        }
    }

    func back(_ id: UUID) throws {
        let tab = try tab(id)
        guard let view = tab.activeWebView, view.canGoBack else {
            throw BrowserRuntimeError.unsupportedAction
        }
        revokeBrowserState(for: id)
        view.goBack()
    }
    func forward(_ id: UUID) throws {
        let tab = try tab(id)
        guard let view = tab.activeWebView, view.canGoForward else {
            throw BrowserRuntimeError.unsupportedAction
        }
        revokeBrowserState(for: id)
        view.goForward()
    }
    func reload(_ id: UUID) throws {
        let tab = try tab(id)
        revokeBrowserState(for: id)
        if let view = tab.activeWebView {
            view.reload()
        } else {
            _ = useLiveView(tab)
        }
    }

    func read(_ id: UUID) async throws -> BrowserPageSnapshot {
        guard aiControlMode.canRead else { throw BrowserRuntimeError.controlDisabled }
        try requireAIAccess(id)
        let tab = try tab(id)
        let authorityRevision = authorityRevisions[id, default: 0]
        readRevisions[id, default: 0] &+= 1
        visualHits = visualHits.filter { $0.value.tabID != id }
        if automation?.tabID == id, automation?.role == "visualReview" {
            automation = nil
            aiFocus = nil
        }
        let readRevision = readRevisions[id, default: 0]
        beginOperation(on: id)
        defer { endOperation(on: id) }
        let webView = useLiveView(tab)
        await awaitRevocation(for: id)
        let restoreDeadline = ProcessInfo.processInfo.systemUptime + 4
        while tab.isRestoring && ProcessInfo.processInfo.systemUptime < restoreDeadline {
            try Task.checkCancellation()
            try requireAIAccess(id)
            try await Task.sleep(for: .milliseconds(100))
        }
        guard !tab.isRestoring, !tab.restoreFailed else {
            throw BrowserRuntimeError.missingSnapshot
        }
        _ = try self.tab(id)
        try requireAIAccess(id)
        let world = WKContentWorld.world(name: BrowserSemanticScript.world)
        _ = try await webView.callAsyncJavaScript(
            BrowserSemanticScript.install, arguments: [:], in: nil, contentWorld: world
        )
        guard let json = try await webView.callAsyncJavaScript(
            BrowserSemanticScript.snapshot, arguments: [:], in: nil, contentWorld: world
        ) as? String,
              let data = json.data(using: .utf8) else {
            throw BrowserRuntimeError.missingSnapshot
        }
        let main = try JSONDecoder().decode(BrowserPageSnapshot.self, from: data)
        var children: [BrowserPageSnapshot] = []
        let registered = tab.registeredFrames
        for (frameID, frameInfo) in registered.prefix(12) {
            try Task.checkCancellation()
            guard aiControlMode.canRead else { throw BrowserRuntimeError.controlDisabled }
            try requireAIAccess(id)
            do {
                _ = try await webView.callAsyncJavaScript(
                    BrowserSemanticScript.install, arguments: [:], in: frameInfo, contentWorld: world
                )
                guard let raw = try await webView.callAsyncJavaScript(
                    BrowserSemanticScript.snapshot, arguments: [:], in: frameInfo, contentWorld: world
                ) as? String, let frameData = raw.data(using: .utf8) else { continue }
                let child = try JSONDecoder().decode(BrowserPageSnapshot.self, from: frameData)
                if child.frameID == frameID { children.append(child) }
            } catch {
                // A navigating or restricted frame is reported as partial, not empty.
                continue
            }
        }
        let expectedFrameCount = max(main.diagnostics.frameCount, tab.registeredFrames.count + 1)
        let frameOrigins = Dictionary(registered.map { id, info in
            let securityOrigin = info.securityOrigin
            let origin = securityOrigin.host.isEmpty ? "opaque" :
                "\(securityOrigin.protocol)://\(securityOrigin.host)" +
                (securityOrigin.port > 0 ? ":\(securityOrigin.port)" : "")
            return (id, origin)
        }, uniquingKeysWith: { _, newest in newest })
        var snapshot = BrowserPageSnapshot.aggregate(
            main, children: children, expectedFrameCount: expectedFrameCount,
            frameOrigins: frameOrigins
        )
        snapshot.tabID = id
        guard aiControlMode.canRead else { throw BrowserRuntimeError.controlDisabled }
        try requireAIAccess(id)
        guard authorityRevisions[id, default: 0] == authorityRevision,
              readRevisions[id, default: 0] == readRevision else {
            throw BrowserRuntimeError.staleTarget
        }
        _ = try self.tab(id)
        let frameIdentities = Dictionary(children.compactMap { child in
            child.frameID.map { ($0, child.identity) }
        }, uniquingKeysWith: { _, newest in newest })
        await runtime.replace(snapshot, frameIdentities: frameIdentities, for: id)
        guard aiControlMode.canRead, !pausedTabIDs.contains(id),
              authorityRevisions[id, default: 0] == authorityRevision,
              readRevisions[id, default: 0] == readRevision,
              tabs.contains(where: { $0.id == id }) else {
            throw BrowserRuntimeError.staleTarget
        }
        needsFreshReadTabIDs.remove(id)
        userChangedTabIDs.remove(id)
        lastReadinessByTabID[id] = snapshot.readiness
        tab.updateIdentity()
        return snapshot
    }

    private func screenshotRedaction(_ webView: WKWebView,
                                     expected: BrowserPageIdentity) async throws -> BrowserScreenshotRedaction {
        let raw = try await webView.callAsyncJavaScript(
            BrowserSemanticScript.screenshotRedaction, arguments: [:], in: nil,
            contentWorld: .world(name: BrowserSemanticScript.world)
        )
        guard let json = raw as? String, let data = json.data(using: .utf8),
              let result = try? JSONDecoder().decode(BrowserScreenshotRedaction.self, from: data),
              result.identity == expected, result.complete,
              result.rects.count <= 240, result.rects.allSatisfy(\.isValid) else {
            throw BrowserRuntimeError.screenshotProtected
        }
        return result
    }

    func screenshot(_ id: UUID) async throws -> BrowserScreenshotResult {
        guard aiControlMode.canRead else { throw BrowserRuntimeError.controlDisabled }
        let authorityRevision = authorityRevisions[id, default: 0]
        beginOperation(on: id)
        defer { endOperation(on: id) }
        let snapshot = try await wait(id, condition: .pageStable, timeoutMilliseconds: 5_000)
        // An incomplete traversal or protected child frame cannot justify a
        // pixel release: the parent may echo a child value outside its bounds.
        guard !snapshot.diagnostics.truncated,
              !snapshot.secureFields.contains(where: { $0.filled && $0.frameID != "main" }) else {
            throw BrowserRuntimeError.screenshotProtected
        }
        let tab = try tab(id)
        guard let webView = tab.activeWebView else { throw BrowserRuntimeError.missingSnapshot }
        let masksBefore = try await screenshotRedaction(webView, expected: snapshot.identity)
        let bounds = webView.bounds
        guard bounds.width >= 1, bounds.height >= 1 else { throw BrowserRuntimeError.unsupportedAction }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0,
                                    width: min(1280, bounds.width),
                                    height: min(900, bounds.height))
        let image = try await webView.takeSnapshot(configuration: configuration)
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw BrowserRuntimeError.unsupportedAction
        }
        // WebKit snapshots use backing pixels, often 2× the point-sized view.
        // Bound the encoded raster itself, not just the snapshot rectangle.
        let scale = min(1.0, 1280.0 / Double(source.width), 900.0 / Double(source.height))
        let width = max(1, Int((Double(source.width) * scale).rounded(.down)))
        let height = max(1, Int((Double(source.height) * scale).rounded(.down)))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw BrowserRuntimeError.unsupportedAction }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        try Task.checkCancellation()
        guard aiControlMode.canRead else { throw BrowserRuntimeError.controlDisabled }
        try requireAIAccess(id)
        _ = try self.tab(id)
        let after = try await read(id)
        guard after.identity.documentID == snapshot.identity.documentID,
              after.identity.routeGeneration == snapshot.identity.routeGeneration,
              after.identity.mutationRevision == snapshot.identity.mutationRevision,
              after.identity.userRevision == snapshot.identity.userRevision,
              after.frameContexts?.map({ "\($0.id)|\($0.url)|\($0.origin)" }) ==
                snapshot.frameContexts?.map({ "\($0.id)|\($0.url)|\($0.origin)" }),
              after.text == snapshot.text,
              after.secureFields == snapshot.secureFields,
              !after.diagnostics.truncated else {
            throw BrowserRuntimeError.screenshotProtected
        }
        let masksAfter = try await screenshotRedaction(webView, expected: after.identity)
        guard masksBefore.rects.count == masksAfter.rects.count,
              zip(masksBefore.rects, masksAfter.rects).allSatisfy({ $0.isNear($1) }) else {
            throw BrowserRuntimeError.screenshotProtected
        }
        let pointBounds = CGRect(origin: .zero, size: configuration.rect.size)
        let pixelX = CGFloat(width) / configuration.rect.width
        let pixelY = CGFloat(height) / configuration.rect.height
        context.setFillColor(NSColor.black.cgColor)
        for mask in masksBefore.rects {
            let expanded = CGRect(x: mask.x - 6, y: mask.y - 6,
                                  width: mask.width + 12, height: mask.height + 12)
            let clipped = expanded.intersection(pointBounds)
            guard !clipped.isNull, !clipped.isEmpty else { continue }
            context.fill(CGRect(x: clipped.minX * pixelX,
                                y: CGFloat(height) - clipped.maxY * pixelY,
                                width: clipped.width * pixelX,
                                height: clipped.height * pixelY))
        }
        guard let scaled = context.makeImage(),
              let jpeg = NSBitmapImageRep(cgImage: scaled).representation(
                using: .jpeg, properties: [.compressionFactor: 0.72]
              ) else { throw BrowserRuntimeError.unsupportedAction }
        let stored = try await BrowserScreenshotStore.shared.save(
            jpeg, for: id, width: width, height: height,
            pointWidth: Double(configuration.rect.width),
            pointHeight: Double(configuration.rect.height),
            authorityRevision: authorityRevision,
            readRevision: readRevisions[id, default: 0],
            redactionCount: masksBefore.rects.count
        )
        guard aiControlMode.canRead, !pausedTabIDs.contains(id),
              authorityRevisions[id, default: 0] == authorityRevision,
              tabs.contains(where: { $0.id == id }) else {
            await BrowserScreenshotStore.shared.remove(for: id)
            throw BrowserRuntimeError.controlDisabled
        }
        return stored
    }

    func visualHitForReview(_ id: UUID) async -> BrowserVisualHit? {
        guard aiControlMode.canInteract, let hit = visualHits[id],
              hit.semanticTargetID == nil,
              let capture = await BrowserScreenshotStore.shared.capture(id: hit.captureID),
              isScreenshotCurrent(capture),
              let page = await runtime.snapshot(for: hit.tabID),
              page.identity == hit.pageIdentity else { return nil }
        return hit
    }

    func hitTest(_ id: UUID, captureID: UUID, pixelX: Double,
                 pixelY: Double) async throws -> BrowserVisualHit {
        guard aiControlMode.canRead else { throw BrowserRuntimeError.controlDisabled }
        try requireFreshTarget(id)
        guard let capture = await BrowserScreenshotStore.shared.capture(id: captureID),
              capture.tabID == id, isScreenshotCurrent(capture),
              pixelX.isFinite, pixelY.isFinite,
              pixelX >= 0, pixelY >= 0,
              pixelX < Double(capture.pixelWidth),
              pixelY < Double(capture.pixelHeight) else {
            throw BrowserRuntimeError.staleTarget
        }
        guard let page = await runtime.snapshot(for: id),
              !page.diagnostics.truncated,
              !(page.links + page.controls).contains(where: \.sensitive) else {
            throw BrowserRuntimeError.screenshotProtected
        }
        let tab = try tab(id)
        guard let webView = tab.activeWebView else { throw BrowserRuntimeError.missingSnapshot }
        let pointX = pixelX * capture.pointWidth / Double(capture.pixelWidth)
        let pointY = pixelY * capture.pointHeight / Double(capture.pixelHeight)
        let hitID = UUID()
        let identity = page.identity
        let raw: Any?
        do {
            raw = try await webView.callAsyncJavaScript(
                BrowserSemanticScript.visualHitTest,
                arguments: [
                    "documentID": identity.documentID,
                    "routeGeneration": identity.routeGeneration,
                    "mutationRevision": identity.mutationRevision,
                    "userRevision": identity.userRevision,
                    "snapshotRevision": identity.snapshotRevision,
                    "hitID": hitID.uuidString,
                    "x": pointX, "y": pointY
                ],
                in: nil, contentWorld: .world(name: BrowserSemanticScript.world)
            )
        } catch {
            if let mapped = semanticActionError(error) { throw mapped }
            throw error
        }
        guard let json = raw as? String, let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(BrowserVisualHitPayload.self, from: data),
              payload.x.isFinite, payload.y.isFinite,
              payload.width > 0, payload.height > 0,
              payload.width.isFinite, payload.height.isFinite,
              isScreenshotCurrent(capture),
              aiControlMode.canRead, !pausedTabIDs.contains(id) else {
            throw BrowserRuntimeError.staleTarget
        }
        let hit = BrowserVisualHit(
            id: hitID, captureID: captureID, tabID: id,
            label: payload.label, role: payload.role,
            x: payload.x, y: payload.y, width: payload.width, height: payload.height,
            semanticTargetID: payload.semanticTargetID, pageIdentity: identity
        )
        visualHits[hitID] = hit
        if visualHits.count > 24, let first = visualHits.keys.first {
            visualHits.removeValue(forKey: first)
        }
        // Preview the exact screenshot hit in the native, noninteractive
        // overlay while the user considers the visual-click review.
        if hit.semanticTargetID == nil {
            let target = BrowserTarget(
                id: hit.id.uuidString, role: hit.role, label: hit.label,
                destination: nil, relationship: nil,
                x: hit.x, y: hit.y, width: hit.width, height: hit.height,
                frameID: "main", sensitive: false
            )
            let rawBounds = CGRect(x: hit.x, y: hit.y, width: hit.width, height: hit.height)
            let clipped = rawBounds.intersection(webView.bounds)
            let bounds = clipped.isNull || clipped.isEmpty ? nil : clipped
            var preview = BrowserAutomationState(
                id: UUID(), tabID: id, title: "Reviewing visual target “\(hit.label)”",
                role: "visualReview", target: target, overlayBounds: bounds,
                pointerStart: CGPoint(x: webView.bounds.midX, y: webView.bounds.midY)
            )
            preview.phase = .waiting
            automation = preview
            aiFocus = BrowserAIFocusState(
                id: preview.id, tabID: id, targetID: hit.id.uuidString,
                bounds: bounds, role: "visualReview", label: hit.label, intent: preview.title
            )
            let previewID = preview.id
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(120))
                if self?.automation?.id == previewID {
                    self?.automation = nil
                    self?.aiFocus = nil
                }
            }
        }
        return hit
    }

    func pointerClick(_ id: UUID, hitID: UUID,
                      commitApproved: Bool = false) async throws -> BrowserActionOutcome {
        guard aiControlMode.canInteract else { throw BrowserRuntimeError.controlDisabled }
        guard commitApproved else { throw BrowserRuntimeError.commitApprovalRequired }
        try requireFreshTarget(id)
        guard let hit = visualHits[hitID], hit.tabID == id,
              hit.semanticTargetID == nil,
              let capture = await BrowserScreenshotStore.shared.capture(id: hit.captureID),
              isScreenshotCurrent(capture),
              let before = await runtime.snapshot(for: id),
              before.identity == hit.pageIdentity else {
            throw BrowserRuntimeError.staleTarget
        }
        let target = BrowserTarget(
            id: hit.id.uuidString, role: hit.role, label: hit.label,
            destination: nil, relationship: nil,
            x: hit.x, y: hit.y, width: hit.width, height: hit.height,
            frameID: "main", sensitive: false
        )
        try await showAutomation(on: id, "Clicking visual target “\(hit.label)”",
                                 role: "visual", target: target)
        guard aiControlMode.canInteract, isScreenshotCurrent(capture),
              let current = await runtime.snapshot(for: id),
              current.identity == hit.pageIdentity else {
            throw BrowserRuntimeError.staleTarget
        }
        let tab = try tab(id)
        guard let webView = tab.activeWebView else { throw BrowserRuntimeError.staleTarget }
        try Task.checkCancellation()
        let raw: Any?
        do {
            raw = try await webView.callAsyncJavaScript(
                BrowserSemanticScript.visualPointerClick,
                arguments: [
                    "documentID": hit.pageIdentity.documentID,
                    "routeGeneration": hit.pageIdentity.routeGeneration,
                    "mutationRevision": hit.pageIdentity.mutationRevision,
                    "userRevision": hit.pageIdentity.userRevision,
                    "snapshotRevision": hit.pageIdentity.snapshotRevision,
                    "hitID": hitID.uuidString
                ],
                in: nil, contentWorld: .world(name: BrowserSemanticScript.world)
            )
        } catch {
            if let mapped = semanticActionError(error) { throw mapped }
            throw error
        }
        visualHits.removeValue(forKey: hitID)
        guard let json = raw as? String, let data = json.data(using: .utf8),
              let result = try? JSONDecoder().decode(BrowserScriptActionAcknowledgement.self, from: data),
              result.requested, result.performed, result.action == "pointerClick" else {
            throw BrowserRuntimeError.unsupportedAction
        }
        let effect = await verifyVisibleEffect(id, before: before)
        return BrowserActionOutcome(
            requested: true, performed: true,
            postActionVerified: effect.pageChanged,
            pageChanged: effect.pageChanged,
            routeChangeDetected: effect.routeChanged,
            detail: effect.pageChanged
                ? "The page visibly changed after the visual click; this does not prove a transaction completed."
                : "A pointer event was dispatched, but no visible result was verified. Read fresh page state."
        )
    }

    func find(_ id: UUID, query: String) async throws -> [BrowserSemanticMatch] {
        let snapshot = try await read(id)
        return Array(snapshot.find(query).prefix(60))
    }

    func activate(_ id: UUID, targetID: String,
                  disposition: BrowserNavigationDisposition,
                  commitApproved: Bool = false) async throws -> BrowserActivationOutcome {
        guard aiControlMode.canNavigate else { throw BrowserRuntimeError.controlDisabled }
        try requireFreshTarget(id)
        let target = try await runtime.resolveAny(tabID: id, targetID: targetID)
        if target.role == "link" {
            if target.destination != nil {
                return .navigated(try await openLink(id, targetID: targetID, disposition: disposition,
                                                     commitApproved: commitApproved))
            }
            guard target.relationship == "scripted" else { throw BrowserRuntimeError.invalidDestination }
        }
        guard disposition == .currentTab else { throw BrowserRuntimeError.noVerifiedDestination }
        guard target.availableActions?.contains("activate") != false else {
            throw BrowserRuntimeError.unsupportedAction
        }
        guard aiControlMode.canInteract else { throw BrowserRuntimeError.controlDisabled }
        return .interacted(try await interact(id, targetID: targetID, action: .click,
                                              commitApproved: commitApproved))
    }

    @discardableResult
    func openLink(_ id: UUID, targetID: String, disposition: BrowserNavigationDisposition,
                  commitApproved: Bool = false) async throws -> UUID {
        guard aiControlMode.canNavigate else { throw BrowserRuntimeError.controlDisabled }
        beginOperation(on: id)
        defer { endOperation(on: id) }
        try requireFreshTarget(id)
        let (identity, target) = try await runtime.resolve(tabID: id, targetID: targetID, link: true)
        guard let destination = BrowserRuntime.safeLinkDestination(target) else {
            throw BrowserRuntimeError.invalidDestination
        }
        guard let initialPage = await runtime.snapshot(for: id) else {
            throw BrowserRuntimeError.missingSnapshot
        }
        if BrowserCommitAuthorization.review(tabID: id, target: target, action: .click,
                                             page: initialPage) != nil && !commitApproved {
            throw BrowserRuntimeError.commitApprovalRequired
        }
        try await validateTarget(id, target: target, identity: identity)
        guard aiControlMode.canNavigate else { throw BrowserRuntimeError.controlDisabled }
        try requireFreshTarget(id)
        let dispositionDescription = disposition == .currentTab ? "" :
            (disposition == .newTab ? " in a new tab" : " in a background tab")
        try await showAutomation(on: id, "Opening “\(target.label)”\(dispositionDescription)",
                                 role: "link", target: target)
        // Geometry resolution suspends; a person can take over the tab while
        // the native pointer is prepared. Recheck both authority and target.
        guard aiControlMode.canNavigate else { throw BrowserRuntimeError.controlDisabled }
        try requireFreshTarget(id)
        try await validateTarget(id, target: target, identity: identity)
        if let currentPage = await runtime.snapshot(for: id),
           BrowserCommitAuthorization.review(tabID: id, target: target, action: .click,
                                             page: currentPage) != nil && !commitApproved {
            throw BrowserRuntimeError.commitApprovalRequired
        }
        try Task.checkCancellation()
        guard aiControlMode.canNavigate else { throw BrowserRuntimeError.controlDisabled }
        try requireFreshTarget(id)
        switch disposition {
        case .currentTab:
            try navigate(id, to: destination)
            return id
        case .newTab:
            let opened = newTab(url: destination, foreground: true).id
            markAutomationDestination(sourceTabID: id, destinationTabID: opened)
            return opened
        case .backgroundTab:
            let opened = newTab(url: destination, foreground: false).id
            markAutomationDestination(sourceTabID: id, destinationTabID: opened)
            return opened
        }
    }

    func commitReview(_ id: UUID, targetID: String,
                      action: BrowserInteractionAction) async throws -> BrowserCommitReview? {
        try requireFreshTarget(id)
        let target = try await runtime.resolveAny(tabID: id, targetID: targetID)
        guard let page = await runtime.snapshot(for: id) else { throw BrowserRuntimeError.missingSnapshot }
        return BrowserCommitAuthorization.review(tabID: id, target: target, action: action, page: page)
    }

    func interact(_ id: UUID, targetID: String, action: BrowserInteractionAction,
                  text: String? = nil, commitApproved: Bool = false) async throws -> BrowserActionOutcome {
        guard aiControlMode.canInteract else { throw BrowserRuntimeError.controlDisabled }
        let authorityRevision = authorityRevisions[id, default: 0]
        beginOperation(on: id)
        defer { endOperation(on: id) }
        try requireFreshTarget(id)
        let (identity, target) = try await runtime.resolve(tabID: id, targetID: targetID, link: false)
        if action == .type || action == .setValue {
            guard let text, text.utf8.count <= 4_000,
                  !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw BrowserRuntimeError.unsupportedAction
            }
        } else if action == .select {
            guard let text, !text.isEmpty, text.count <= 160 else {
                throw BrowserRuntimeError.unsupportedAction
            }
        } else if action == .toggle {
            guard text == "true" || text == "false" else {
                throw BrowserRuntimeError.unsupportedAction
            }
        } else if action == .pressKey {
            guard let text, BrowserInteractionAction.allowedKeys.contains(text) else {
                throw BrowserRuntimeError.unsupportedAction
            }
        }
        if target.state?.blockedByModal == true {
            throw BrowserRuntimeError.targetOccluded
        }
        guard let initialPage = await runtime.snapshot(for: id) else { throw BrowserRuntimeError.missingSnapshot }
        if BrowserCommitAuthorization.review(tabID: id, target: target, action: action,
                                             page: initialPage) != nil && !commitApproved {
            throw BrowserRuntimeError.commitApprovalRequired
        }
        let advertisedAction: String? = switch action {
        case .click: "activate"
        case .focus: "focus"
        case .type: "type"
        case .setValue: "set_value"
        case .clear: "clear"
        case .select: "select"
        case .toggle: "toggle"
        case .submit: "submit"
        case .pressKey: nil
        }
        if let advertisedAction, let available = target.availableActions,
           !available.contains(advertisedAction) {
            throw BrowserRuntimeError.unsupportedAction
        }
        guard aiControlMode.canInteract else { throw BrowserRuntimeError.controlDisabled }
        try requireFreshTarget(id)
        try await showAutomation(on: id, action.description(for: target.label), role: action.rawValue, target: target)
        guard aiControlMode.canInteract, authorityRevisions[id, default: 0] == authorityRevision else {
            throw BrowserRuntimeError.staleTarget
        }
        try requireFreshTarget(id)
        let before = await runtime.snapshot(for: id)
        if let before, BrowserCommitAuthorization.review(tabID: id, target: target,
                                                         action: action, page: before) != nil,
           !commitApproved {
            throw BrowserRuntimeError.commitApprovalRequired
        }
        if let dialog = before?.activeDialog, dialog.modal,
           target.frameID != dialog.frameID {
            throw BrowserRuntimeError.targetOccluded
        }
        guard aiControlMode.canInteract, authorityRevisions[id, default: 0] == authorityRevision else {
            throw BrowserRuntimeError.staleTarget
        }
        try requireFreshTarget(id)
        let tab = try tab(id)
        let frame = try targetFrame(target, in: tab)
        guard let webView = tab.activeWebView else { throw BrowserRuntimeError.staleTarget }
        try Task.checkCancellation()
        let result: Any?
        do {
            result = try await webView.callAsyncJavaScript(
                BrowserSemanticScript.action,
                arguments: [
                    "documentID": identity.documentID,
                    "routeGeneration": identity.routeGeneration,
                    "mutationRevision": identity.mutationRevision,
                    "userRevision": identity.userRevision,
                    "snapshotRevision": identity.snapshotRevision,
                    "targetID": targetID,
                    "action": action.rawValue,
                    "text": text ?? ""
                ],
                in: frame,
                contentWorld: .world(name: BrowserSemanticScript.world)
            )
        } catch {
            if let mapped = semanticActionError(error) { throw mapped }
            throw error
        }
        guard let json = result as? String, let data = json.data(using: .utf8),
              let acknowledgement = try? JSONDecoder().decode(BrowserScriptActionAcknowledgement.self, from: data),
              acknowledgement.requested, acknowledgement.performed,
              acknowledgement.action == action.rawValue else {
            throw BrowserRuntimeError.unsupportedAction
        }
        guard authorityRevisions[id, default: 0] == authorityRevision,
              tabs.contains(where: { $0.id == id }), !pausedTabIDs.contains(id) else {
            throw BrowserRuntimeError.staleTarget
        }
        let effect: (pageChanged: Bool, routeChanged: Bool)
        if (action == .click || action == .submit) && !acknowledgement.verified {
            effect = await verifyVisibleEffect(id, before: before)
        } else {
            effect = (false, false)
        }
        guard authorityRevisions[id, default: 0] == authorityRevision,
              tabs.contains(where: { $0.id == id }), !pausedTabIDs.contains(id) else {
            throw BrowserRuntimeError.staleTarget
        }
        let verified = aiControlMode.canInteract &&
            (acknowledgement.verified || effect.pageChanged) && action != .pressKey
        let detail: String
        if [.type, .setValue, .clear].contains(action) && verified {
            detail = "The requested value remains in the target after input events."
        } else if action == .select && verified {
            detail = "The requested native option remains selected after change events."
        } else if action == .toggle && verified {
            detail = "The target's checked state matches the requested state."
        } else if action == .focus && verified {
            detail = "The target became the active element."
        } else if effect.routeChanged && verified {
            detail = "The browser observed a route change after the action; this does not prove server acceptance."
        } else if effect.pageChanged && verified {
            detail = "The browser observed a visible semantic change after the action; this does not prove server acceptance."
        } else if action == .click && verified {
            detail = "The control's checked or ARIA state changed after the click."
        } else if action == .pressKey {
            detail = "The browser dispatched a synthetic key event; reread the page to verify any effect."
        } else {
            detail = "The browser dispatched the action; reread the page to verify its effect."
        }
        return BrowserActionOutcome(
            requested: true, performed: true, postActionVerified: verified,
            pageChanged: effect.pageChanged, routeChangeDetected: effect.routeChanged,
            detail: detail
        )
    }

    private func verifyVisibleEffect(_ id: UUID, before: BrowserPageSnapshot?) async ->
        (pageChanged: Bool, routeChanged: Bool) {
        guard let before else { return (false, false) }
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard !Task.isCancelled, aiControlMode.canInteract,
                  !pausedTabIDs.contains(id) else { return (false, false) }
            if let after = try? await read(id) {
                let routeChanged = after.identity.url != before.identity.url ||
                    after.identity.documentID != before.identity.documentID ||
                    after.identity.routeGeneration != before.identity.routeGeneration ||
                    after.frameContexts?.map(\.url) != before.frameContexts?.map(\.url)
                let stable = after.readiness == .readyWithContent || after.readiness == .readyEmpty
                let semanticChanged = stable && (
                    after.text != before.text || after.headings != before.headings ||
                    after.rows.map(\.text) != before.rows.map(\.text) ||
                    after.links.map(\.label) != before.links.map(\.label) ||
                    after.links.map(\.state) != before.links.map(\.state) ||
                    after.controls.map(\.label) != before.controls.map(\.label) ||
                    after.controls.map(\.state) != before.controls.map(\.state) ||
                    after.activeDialog != before.activeDialog
                )
                if routeChanged || semanticChanged { return (true, routeChanged) }
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return (false, false)
    }

    func scroll(_ id: UUID, direction: BrowserScrollDirection,
                fraction: Double = 0.8, frameID: String = "main") async throws -> BrowserScrollOutcome {
        guard aiControlMode.canNavigate, (0.5...1).contains(fraction) else {
            throw BrowserRuntimeError.controlDisabled
        }
        beginOperation(on: id)
        defer { endOperation(on: id) }
        guard !frameID.isEmpty, frameID.count <= 100 else { throw BrowserRuntimeError.staleTarget }
        let page = try await read(id)
        guard !page.diagnostics.truncated else { throw BrowserRuntimeError.privatePageIncomplete }
        guard aiControlMode.canNavigate else { throw BrowserRuntimeError.controlDisabled }
        try requireAIAccess(id)
        let identity = try await runtime.identity(tabID: id, frameID: frameID)
        let authorityRevision = authorityRevisions[id, default: 0]
        guard aiControlMode.canNavigate else { throw BrowserRuntimeError.controlDisabled }
        try requireAIAccess(id)
        let tab = try tab(id)
        let frame = frameID == "main" ? nil : tab.frameInfo(for: frameID)
        guard frameID == "main" || frame != nil else { throw BrowserRuntimeError.staleTarget }
        guard let webView = tab.activeWebView else { throw BrowserRuntimeError.staleTarget }
        guard let json = try await webView.callAsyncJavaScript(
            BrowserSemanticScript.scroll,
            arguments: [
                "documentID": identity.documentID,
                "routeGeneration": identity.routeGeneration,
                "mutationRevision": identity.mutationRevision,
                "userRevision": identity.userRevision,
                "snapshotRevision": identity.snapshotRevision,
                "direction": direction.rawValue,
                "fraction": fraction
            ],
            in: frame, contentWorld: .world(name: BrowserSemanticScript.world)
        ) as? String, let data = json.data(using: .utf8) else {
            throw BrowserRuntimeError.unsupportedAction
        }
        guard authorityRevisions[id, default: 0] == authorityRevision,
              tabs.contains(where: { $0.id == id }), !pausedTabIDs.contains(id) else {
            throw BrowserRuntimeError.staleTarget
        }
        var outcome = try JSONDecoder().decode(BrowserScrollOutcome.self, from: data)
        outcome.frameID = frameID
        if outcome.performed {
            let target = BrowserTarget(
                id: "scroll-region", role: "scroll", label: outcome.regionLabel,
                destination: nil, relationship: nil, x: outcome.x, y: outcome.y,
                width: outcome.width, height: outcome.height, frameID: frameID,
                sensitive: false
            )
            try await showAutomation(on: id, "Scrolling \(outcome.regionLabel)",
                                     role: "scroll", target: target)
        }
        return outcome
    }

    func scan(_ id: UUID, maximumPasses: Int = 10,
              frameID: String = "main") async throws -> BrowserScanResult {
        guard aiControlMode.canNavigate else { throw BrowserRuntimeError.controlDisabled }
        guard (1...20).contains(maximumPasses) else { throw BrowserRuntimeError.unsupportedAction }
        var collected = BrowserScanAccumulator()
        var captures = 0
        var noNewPasses = 0
        var reachedEnd = false
        for pass in 0..<maximumPasses {
            try Task.checkCancellation()
            let snapshot = try await scanStableSnapshot(id, accumulator: &collected)
            captures += 1
            let added = collected.add(snapshot)
            noNewPasses = added == 0 ? noNewPasses + 1 : 0
            if noNewPasses >= 3 || pass == maximumPasses - 1 { break }
            let outcome = try await scroll(id, direction: .down, frameID: frameID)
            if !outcome.performed {
                reachedEnd = true
                break
            }
            if outcome.endReached {
                let finalSnapshot = try await scanStableSnapshot(id, accumulator: &collected)
                captures += 1
                _ = collected.add(finalSnapshot)
                reachedEnd = true
                break
            }
        }
        var result = collected.result(tabID: id, captures: captures,
                                      reachedEnd: reachedEnd,
                                      stoppedForNoNewContent: noNewPasses >= 3)
        result.frameID = frameID
        return result
    }

    private func scanStableSnapshot(_ id: UUID,
                                    accumulator: inout BrowserScanAccumulator) async throws -> BrowserPageSnapshot {
        do {
            return try await wait(id, condition: .pageStable, timeoutMilliseconds: 5_000)
        } catch BrowserWaitError.timedOut {
            // Preserve a bounded partial scan instead of claiming that a busy
            // virtualized page reached semantic stability.
            accumulator.markTruncated()
            return try await read(id)
        }
    }

    func wait(_ id: UUID, condition: BrowserWaitCondition,
              timeoutMilliseconds: Int = 10_000) async throws -> BrowserPageSnapshot {
        guard (100...30_000).contains(timeoutMilliseconds) else { throw BrowserRuntimeError.unsupportedAction }
        let started = ProcessInfo.processInfo.systemUptime
        let initialURL = try tab(id).urlString
        let initialTabIDs = Set(tabs.map(\.id))
        while (ProcessInfo.processInfo.systemUptime - started) * 1_000 < Double(timeoutMilliseconds) {
            try Task.checkCancellation()
            guard aiControlMode.canRead else { throw BrowserRuntimeError.controlDisabled }
            try requireAIAccess(id)
            if case .newTab = condition {
                if let opened = tabs.first(where: { !initialTabIDs.contains($0.id) }),
                   let snapshot = try? await read(opened.id) {
                    return snapshot
                }
            } else if let snapshot = try? await read(id),
                      condition.matches(snapshot, initialURL: initialURL,
                                        isLoading: (try? tab(id).isLoading) ?? true) {
                return snapshot
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw BrowserWaitError.timedOut
    }

    /// Require a post-action WebKit completion and a stable semantic page before
    /// a navigation tool can claim that its destination loaded. A pre-action
    /// revision prevents an old, already-loaded page from satisfying the check.
    func waitForNavigation(_ id: UUID, after revision: Int,
                           timeoutMilliseconds: Int = 10_000) async throws -> BrowserPageSnapshot {
        guard (100...30_000).contains(timeoutMilliseconds) else { throw BrowserRuntimeError.unsupportedAction }
        let started = ProcessInfo.processInfo.systemUptime
        while (ProcessInfo.processInfo.systemUptime - started) * 1_000 < Double(timeoutMilliseconds) {
            try Task.checkCancellation()
            guard aiControlMode.canRead else { throw BrowserRuntimeError.controlDisabled }
            try requireAIAccess(id)
            let tab = try tab(id)
            if tab.failedNavigationRevision > revision &&
               tab.failedNavigationRevision >= tab.completedNavigationRevision {
                throw BrowserNavigationError.failed
            }
            if tab.completedNavigationRevision > revision {
                if !tab.isLoading, let snapshot = try? await read(id),
                   snapshot.readiness == .readyWithContent || snapshot.readiness == .readyEmpty {
                    return snapshot
                }
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw BrowserNavigationError.timedOut
    }

    private func targetFrame(_ target: BrowserTarget, in tab: BrowserTab) throws -> WKFrameInfo? {
        if target.frameID == "main" { return nil }
        guard let frame = tab.frameInfo(for: target.frameID) else { throw BrowserRuntimeError.staleTarget }
        return frame
    }

    private func semanticActionError(_ error: Error) -> BrowserRuntimeError? {
        let message = error.localizedDescription + " " + String(describing: error)
        if message.contains("target_occluded") { return .targetOccluded }
        if message.contains("stale_target") { return .staleTarget }
        if message.contains("target_not_interactable") { return .targetNotInteractable }
        if message.contains("sensitive_target") || message.contains("sensitive_form") {
            return .sensitiveTarget
        }
        if message.contains("option_missing_or_ambiguous") ||
           message.contains("not_text_input") ||
           message.contains("not_single_select") ||
           message.contains("not_toggle") ||
           message.contains("radio_cannot_uncheck") ||
           message.contains("unsupported_action") {
            return .unsupportedAction
        }
        return nil
    }

    private func validateTarget(_ id: UUID, target: BrowserTarget,
                                identity: BrowserPageIdentity) async throws {
        if target.state?.blockedByModal == true {
            throw BrowserRuntimeError.targetOccluded
        }
        if let dialog = await runtime.snapshot(for: id)?.activeDialog,
           dialog.modal, target.frameID != dialog.frameID {
            throw BrowserRuntimeError.targetOccluded
        }
        let tab = try tab(id)
        let frame = try targetFrame(target, in: tab)
        guard let webView = tab.activeWebView else { throw BrowserRuntimeError.staleTarget }
        do {
            _ = try await webView.callAsyncJavaScript(
                BrowserSemanticScript.action,
                arguments: [
                    "documentID": identity.documentID,
                    "routeGeneration": identity.routeGeneration,
                    "mutationRevision": identity.mutationRevision,
                    "userRevision": identity.userRevision,
                    "snapshotRevision": identity.snapshotRevision,
                    "targetID": target.id,
                    "action": "validate",
                    "text": ""
                ],
                in: frame,
                contentWorld: .world(name: BrowserSemanticScript.world)
            )
        } catch {
            if let mapped = semanticActionError(error) { throw mapped }
            throw error
        }
    }

    private func markAutomationDestination(sourceTabID: UUID, destinationTabID: UUID) {
        guard var state = automation, state.tabID == sourceTabID else { return }
        state.destinationTabID = destinationTabID
        automation = state
    }

    private func showAutomation(on tabID: UUID, _ title: String, role: String,
                                target: BrowserTarget) async throws {
        try Task.checkCancellation()
        guard let tab = try? tab(tabID), let webView = tab.activeWebView,
              !pausedTabIDs.contains(tabID) else { return }
        let frameGeometry: BrowserFrameGeometry?
        if target.frameID == "main" {
            frameGeometry = nil
        } else if let raw = try? await webView.callAsyncJavaScript(
            BrowserSemanticScript.frameGeometry,
            arguments: ["frameID": target.frameID], in: nil,
            contentWorld: .world(name: BrowserSemanticScript.world)
        ) as? String, let data = raw.data(using: .utf8) {
            frameGeometry = try? JSONDecoder().decode(BrowserFrameGeometry.self, from: data)
        } else {
            frameGeometry = nil
        }
        try Task.checkCancellation()
        guard !pausedTabIDs.contains(tabID), tabs.contains(where: { $0.id == tabID }) else { return }
        let bounds: CGRect?
        if target.frameID == "main" {
            let raw = CGRect(x: target.x, y: target.y, width: target.width, height: target.height)
            let clipped = raw.intersection(webView.bounds)
            bounds = clipped.isNull || clipped.isEmpty ? nil : clipped
        } else {
            bounds = frameGeometry?.visibleTargetBounds(target, viewport: webView.bounds)
        }
        let start = lastAIPointerPositionByTabID[tabID] ?? CGPoint(x: webView.bounds.midX, y: webView.bounds.midY)
        let state = BrowserAutomationState(
            id: UUID(), tabID: tabID, title: title, role: role,
            target: target, overlayBounds: bounds, pointerStart: start
        )
        aiFocus = BrowserAIFocusState(
            id: state.id, tabID: tabID, targetID: target.id,
            bounds: bounds, role: role, label: target.label, intent: title
        )
        automation = state
        if let bounds {
            lastAIPointerPositionByTabID[tabID] = CGPoint(x: bounds.minX + 25, y: bounds.maxY + 12)
            do {
                try await Task.sleep(for: .milliseconds(80))
                guard automation?.id == state.id, !pausedTabIDs.contains(tabID) else { return }
                automation?.phase = .moving
                try await Task.sleep(for: .milliseconds(220))
                guard automation?.id == state.id, !pausedTabIDs.contains(tabID) else { return }
                try Task.checkCancellation()
            } catch {
                if automation?.id == state.id {
                    automation = nil
                    aiFocus = nil
                }
                throw error
            }
            automation?.phase = .acting
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                if self?.automation?.id == state.id { self?.automation?.phase = .waiting }
            }
        } else {
            automation?.phase = .waiting
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if self?.automation?.id == state.id {
                self?.automation = nil
                if self?.aiFocus?.id == state.id { self?.aiFocus = nil }
            }
        }
    }
}

enum BrowserActivationOutcome: Sendable {
    case navigated(UUID)
    case interacted(BrowserActionOutcome)
}

enum BrowserNavigationDisposition: String, Codable, Sendable {
    case currentTab = "current_tab"
    case newTab = "new_tab"
    case backgroundTab = "background_tab"
}

enum BrowserScrollDirection: String, Codable, Sendable {
    case up
    case down
}

struct BrowserScrollOutcome: Codable, Sendable {
    var frameID: String? = nil
    let performed: Bool
    let before: Double
    let after: Double
    let endReached: Bool
    let regionLabel: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let availableRegions: Int
    let truncated: Bool
}

struct BrowserScannedLink: Codable, Hashable, Sendable {
    let text: String
    let url: String
    let relationship: String
}

struct BrowserScannedControl: Codable, Hashable, Sendable {
    let role: String
    let label: String
}

struct BrowserScannedRow: Codable, Hashable, Sendable {
    let stableKey: String
    let role: String
    let text: String
}

struct BrowserScanResult: Codable, Sendable {
    var frameID: String? = nil
    let tabID: UUID
    let captures: Int
    let reachedEnd: Bool
    let stoppedForNoNewContent: Bool
    let truncated: Bool
    let lines: [String]
    let rows: [BrowserScannedRow]
    let links: [BrowserScannedLink]
    let controls: [BrowserScannedControl]
}

struct BrowserScanAccumulator {
    private(set) var lines: [String] = []
    private(set) var rows: [BrowserScannedRow] = []
    private(set) var links: [BrowserScannedLink] = []
    private(set) var controls: [BrowserScannedControl] = []
    private var seenLines: Set<String> = []
    private var seenRows: Set<String> = []
    private var seenLinks: Set<BrowserScannedLink> = []
    private var seenControls: Set<BrowserScannedControl> = []
    private var lineCharacters = 0
    private(set) var truncated = false

    mutating func markTruncated() { truncated = true }

    mutating func add(_ snapshot: BrowserPageSnapshot) -> Int {
        let before = lines.count + rows.count + links.count + controls.count
        truncated = truncated || snapshot.diagnostics.truncated
        for rawLine in snapshot.text.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let line = String(trimmed.prefix(240))
            if trimmed.count > 240 { truncated = true }
            guard seenLines.insert(line).inserted else { continue }
            guard lines.count < 300, lineCharacters + line.count <= 25_000 else {
                truncated = true
                break
            }
            lines.append(line)
            lineCharacters += line.count
        }
        for item in snapshot.rows {
            guard seenRows.insert(item.stableKey).inserted else { continue }
            guard rows.count < 60 else { truncated = true; break }
            if item.text.count > 300 { truncated = true }
            rows.append(BrowserScannedRow(
                stableKey: item.stableKey, role: String(item.role.prefix(40)),
                text: String(item.text.prefix(300))
            ))
        }
        for target in snapshot.links where !target.sensitive {
            guard let raw = target.destination,
                  BrowserRuntime.safeDestination(raw) != nil else { continue }
            guard raw.count <= 512 else { truncated = true; continue }
            let link = BrowserScannedLink(
                text: String(target.label.prefix(160)), url: raw,
                relationship: target.relationship ?? "normal"
            )
            guard seenLinks.insert(link).inserted else { continue }
            guard links.count < 60 else { truncated = true; break }
            links.append(link)
        }
        for target in snapshot.controls where !target.sensitive {
            let control = BrowserScannedControl(
                role: String(target.role.prefix(80)),
                label: String(target.label.prefix(160))
            )
            guard seenControls.insert(control).inserted else { continue }
            guard controls.count < 60 else { truncated = true; break }
            controls.append(control)
        }
        return lines.count + rows.count + links.count + controls.count - before
    }

    func result(tabID: UUID, captures: Int, reachedEnd: Bool,
                stoppedForNoNewContent: Bool) -> BrowserScanResult {
        BrowserScanResult(
            tabID: tabID, captures: captures, reachedEnd: reachedEnd,
            stoppedForNoNewContent: stoppedForNoNewContent,
            truncated: truncated || !reachedEnd,
            lines: lines, rows: rows, links: links, controls: controls
        )
    }
}

enum BrowserInteractionAction: String {
    case click
    case focus
    case type
    case setValue
    case clear
    case select
    case toggle
    case pressKey
    case submit

    // Synthetic key events cannot safely trigger browser defaults such as form
    // submission or tab traversal. Keep this surface to non-submission keys.
    static let allowedKeys: Set<String> = [
        "Escape", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight",
        "Home", "End", "PageUp", "PageDown"
    ]

    func description(for target: String) -> String {
        switch self {
        case .click: "Clicking “\(target)”"
        case .focus: "Focusing “\(target)”"
        case .type: "Typing into “\(target)”"
        case .setValue: "Setting “\(target)”"
        case .clear: "Clearing “\(target)”"
        case .select: "Selecting an option in “\(target)”"
        case .toggle: "Toggling “\(target)”"
        case .pressKey: "Pressing key on “\(target)”"
        case .submit: "Submitting “\(target)”"
        }
    }
}

private struct BrowserScriptActionAcknowledgement: Decodable {
    let requested: Bool
    let performed: Bool
    let action: String
    let verified: Bool
}

struct BrowserActionOutcome: Codable, Sendable {
    let requested: Bool
    let performed: Bool
    let postActionVerified: Bool
    let pageChanged: Bool
    let routeChangeDetected: Bool
    let detail: String
}

struct BrowserFrameGeometry: Decodable {
    let x: Double
    let y: Double
    let scaleX: Double
    let scaleY: Double
    let clipX: Double
    let clipY: Double
    let clipWidth: Double
    let clipHeight: Double

    func visibleTargetBounds(_ target: BrowserTarget, viewport: CGRect) -> CGRect? {
        let values = [x, y, scaleX, scaleY, clipX, clipY, clipWidth, clipHeight,
                      target.x, target.y, target.width, target.height]
        guard values.allSatisfy(\.isFinite), scaleX > 0, scaleY > 0,
              clipWidth > 0, clipHeight > 0, target.width > 0, target.height > 0 else {
            return nil
        }
        let raw = CGRect(x: x + target.x * scaleX, y: y + target.y * scaleY,
                         width: target.width * scaleX, height: target.height * scaleY)
        let frameClip = CGRect(x: clipX, y: clipY, width: clipWidth, height: clipHeight)
        let visible = raw.intersection(frameClip).intersection(viewport)
        return visible.isNull || visible.isEmpty ? nil : visible
    }
}

struct BrowserAIActivity: Identifiable, Equatable {
    enum State: Equatable {
        case working
        case completed
        case failed
    }

    let id: UUID
    var tabID: UUID?
    let title: String
    var state: State

    static func title(for tool: String) -> String {
        switch tool {
        case "browser_read", "browser_result_read": return "Reading page"
        case "browser_find": return "Finding on page"
        case "browser_scan", "browser_scroll": return "Scanning page"
        case "browser_activate", "browser_open_link": return "Opening result"
        case "browser_new_tab": return "Opening tab"
        case "browser_close_tab": return "Closing tab"
        case "browser_focus_tab": return "Switching tab"
        case "browser_navigate", "browser_back", "browser_forward", "browser_reload": return "Navigating"
        case "browser_wait": return "Waiting for page"
        case "browser_type": return "Typing into page"
        case "browser_focus": return "Focusing control"
        case "browser_click", "browser_submit", "browser_press_key": return "Interacting with page"
        case "browser_screenshot": return "Inspecting page"
        default: return "Checking Browser"
        }
    }
}

struct BrowserAIFocusState: Identifiable {
    let id: UUID
    let tabID: UUID
    let targetID: String
    let bounds: CGRect?
    let role: String
    let label: String
    let intent: String
}

struct BrowserAutomationState: Identifiable {
    enum Phase: Equatable {
        case focusing
        case moving
        case acting
        case waiting
    }

    let id: UUID
    let tabID: UUID
    let title: String
    let role: String
    let target: BrowserTarget
    let overlayBounds: CGRect?
    let pointerStart: CGPoint
    var phase: Phase = .focusing
    var destinationTabID: UUID? = nil
}

enum BrowserWaitCondition {
    case pageStable
    case loadingFinished
    case newTab
    case urlChanged
    case textPresent(String)
    case textGone(String)
    case targetPresent(String)
    case targetGone(String)

    func matches(_ snapshot: BrowserPageSnapshot, initialURL: String,
                 isLoading: Bool = false) -> Bool {
        switch self {
        case .pageStable:
            return snapshot.readiness == .readyWithContent || snapshot.readiness == .readyEmpty
        case .loadingFinished:
            return !isLoading && snapshot.readiness != .loading
        case .newTab:
            return false // Evaluated against the tab collection by BrowserWorkspaceModel.
        case .urlChanged:
            return snapshot.identity.url != initialURL
        case .textPresent(let value):
            return snapshot.text.localizedStandardContains(value)
        case .textGone(let value):
            return (snapshot.readiness == .readyWithContent || snapshot.readiness == .readyEmpty) &&
                !snapshot.diagnostics.truncated &&
                !snapshot.text.localizedStandardContains(value)
        case .targetPresent(let value):
            return (snapshot.links + snapshot.controls).contains { $0.label.localizedStandardContains(value) }
        case .targetGone(let value):
            return (snapshot.readiness == .readyWithContent || snapshot.readiness == .readyEmpty) &&
                !snapshot.diagnostics.truncated &&
                !(snapshot.links + snapshot.controls).contains { $0.label.localizedStandardContains(value) }
        }
    }
}

enum BrowserWaitError: LocalizedError {
    case timedOut
    var errorDescription: String? { "The page did not reach the requested condition before the timeout." }
}

enum BrowserNavigationError: LocalizedError {
    case failed
    case timedOut

    var errorDescription: String? {
        switch self {
        case .failed: return "The Browser navigation failed before the destination loaded."
        case .timedOut: return "The Browser navigation did not reach a stable page before the timeout."
        }
    }
}

@MainActor
final class BrowserWebViewHost: NSView {
    private(set) weak var displayedWebView: WKWebView?
    private(set) var displayedTabID: UUID?

    override var isFlipped: Bool { true }

    func show(_ webView: WKWebView, tabID: UUID) {
        guard displayedWebView !== webView || displayedTabID != tabID || webView.superview !== self else { return }
        detach()
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        displayedWebView = webView
        displayedTabID = tabID
        assert(displayedWebView === webView && displayedTabID == tabID)
    }

    func detach() {
        // A tab may have been mounted in a new host before SwiftUI dismantles
        // the old one. Never remove a view now owned by that new host.
        if let displayedWebView, displayedWebView.superview === self {
            displayedWebView.removeFromSuperview()
        }
        displayedWebView = nil
        displayedTabID = nil
    }
}

private struct BrowserWebView: NSViewRepresentable {
    let tabID: UUID
    let webView: WKWebView

    func makeNSView(context: Context) -> BrowserWebViewHost {
        let host = BrowserWebViewHost()
        host.show(webView, tabID: tabID)
        return host
    }

    func updateNSView(_ host: BrowserWebViewHost, context: Context) {
        host.show(webView, tabID: tabID)
        assert(host.displayedWebView === webView && host.displayedTabID == tabID)
    }

    static func dismantleNSView(_ host: BrowserWebViewHost, coordinator: Void) {
        host.detach()
    }
}

struct BrowserWorkspaceView: View {
    @ObservedObject var model: BrowserWorkspaceModel = .shared
    @State private var showingAITimeline = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: LimaSpacing.sm) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: LimaSpacing.xs) {
                        ForEach(model.tabs) { tab in
                            BrowserTabButton(tab: tab, selected: tab.id == model.selectedTabID,
                                             aiOpened: model.automation?.destinationTabID == tab.id,
                                             aiState: model.activityState(for: tab.id),
                                             aiPaused: model.pausedTabIDs.contains(tab.id),
                                             focus: { try? model.focus(tab.id) },
                                             close: { Task { try? await model.close(tab.id) } })
                        }
                        Button { _ = model.newTab() } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 26, height: 26)
                                .background(LimaTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                        .help("New Tab")
                    }
                }
                Menu {
                    ForEach(BrowserAIControlMode.allCases, id: \.self) { mode in
                        Button(mode.title) { model.aiControlMode = mode }
                    }
                } label: {
                    Label(model.aiControlMode.title, systemImage: model.aiControlMode == .off ? "sparkles.slash" : "sparkles")
                        .limaFont(.caption.weight(.semibold))
                        .foregroundStyle(model.aiControlMode == .off ? LimaTheme.textSecondary : LimaTheme.accentInk)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(LimaTheme.accentSoft, in: Capsule())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Browser AI Control")
            }
            .padding(.horizontal, LimaSpacing.sm)
            .frame(height: 42)
            .background(LimaTheme.surfaceSecondary)
            GlassHairline()
            if let tab = model.selectedTab {
                BrowserTabContent(tab: tab, model: model)
                    .id(tab.id)
            } else {
                BrowserEmptyState(model: model)
            }
            if !model.aiActivity.isEmpty {
                GlassHairline()
                Button { showingAITimeline = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(LimaTheme.accentInk)
                        Text("AI · Browser")
                            .fontWeight(.semibold)
                        ForEach(Array(model.aiActivity.suffix(3))) { activity in
                            Image(systemName: activity.state == .working ? "circle.fill" :
                                  activity.state == .failed ? "exclamationmark.circle" : "checkmark")
                                .font(.system(size: 9))
                            Text(activity.title).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(LimaTheme.textSecondary)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingAITimeline, arrowEdge: .bottom) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("Browser AI activity").font(.headline)
                            ForEach(Array(model.aiActivity.reversed())) { activity in
                                HStack(spacing: 8) {
                                    Image(systemName: activity.state == .working ? "circle.fill" :
                                          activity.state == .failed ? "exclamationmark.circle" : "checkmark.circle")
                                        .foregroundStyle(activity.state == .failed ? LimaTheme.error : LimaTheme.accentInk)
                                    Text(activity.title)
                                    Spacer()
                                }
                                .font(.caption)
                            }
                        }
                        .padding(14)
                    }
                    .frame(width: 320, height: 300)
                }
            }
        }
    }
}

private struct BrowserEmptyState: View {
    @ObservedObject var model: BrowserWorkspaceModel
    @State private var address = ""

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "globe").font(.system(size: 28))
            Text("Browser").font(.headline)
            TextField("Search or enter an address…", text: $address)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420)
                .onSubmit {
                    guard let url = BrowserRuntime.addressDestination(address) else { return }
                    _ = model.newTab(url: url)
                }
                .accessibilityLabel("Browser address")
            Text("A page starts only when you navigate.").font(.caption)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct BrowserTabButton: View {
    @ObservedObject var tab: BrowserTab
    let selected: Bool
    let aiOpened: Bool
    let aiState: BrowserAIActivity.State?
    let aiPaused: Bool
    let focus: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Button(action: focus) {
                HStack(spacing: 5) {
                    if tab.isLoading { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "globe") }
                    Text(tab.title).lineLimit(1)
                    if aiOpened {
                        Image(systemName: "sparkles")
                            .foregroundStyle(LimaTheme.accentInk)
                            .accessibilityLabel("AI opened this tab")
                    }
                    if aiPaused {
                        Image(systemName: "pause.circle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityLabel("AI paused on this tab")
                    } else if let aiState {
                        Image(systemName: aiState == .working ? "circle.fill" :
                              aiState == .failed ? "exclamationmark.circle" : "checkmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(aiState == .failed ? LimaTheme.error : LimaTheme.accentInk)
                            .accessibilityLabel(aiState == .working ? "AI working on this tab" :
                                                aiState == .failed ? "AI action failed on this tab" :
                                                "AI completed work on this tab")
                    }
                }
                .frame(maxWidth: 150)
            }
            .buttonStyle(.plain)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 9)) }
                .buttonStyle(.plain)
                .accessibilityLabel("Close \(tab.title)")
        }
        .limaFont(.caption)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(selected ? LimaTheme.surfaceRaised : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(selected ? LimaTheme.accentInk.opacity(0.5) : LimaTheme.borderSubtle.opacity(0.4),
                          lineWidth: LimaDesign.hairlineWidth))
    }
}

private struct BrowserTabContent: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject var model: BrowserWorkspaceModel
    @State private var address = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { try? model.back(tab.id) } label: { Image(systemName: "chevron.left") }
                    .disabled(!(tab.activeWebView?.canGoBack ?? false))
                Button { try? model.forward(tab.id) } label: { Image(systemName: "chevron.right") }
                    .disabled(!(tab.activeWebView?.canGoForward ?? false))
                Button { try? model.reload(tab.id) } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(tab.urlString.isEmpty)
                HStack(spacing: 6) {
                    Image(systemName: tab.urlString.hasPrefix("https://") ? "lock.fill" : "globe")
                        .foregroundStyle(LimaTheme.textSecondary)
                        .accessibilityHidden(true)
                    TextField("HTTPS or localhost address", text: $address)
                        .textFieldStyle(.plain)
                        .onSubmit {
                            if let url = BrowserRuntime.addressDestination(address) {
                                try? model.navigate(tab.id, to: url)
                            }
                        }
                        .accessibilityLabel("Browser address")
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(LimaTheme.fieldBackground, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(LimaTheme.fieldBorder, lineWidth: LimaDesign.hairlineWidth))
                Button("Pause AI") { model.pauseAI(on: tab.id) }
                    .disabled(model.pausedTabIDs.contains(tab.id))
                    .accessibilityLabel("Pause AI for this tab")
                if tab.isLoading {
                    ProgressView().controlSize(.mini).accessibilityLabel("Page loading")
                } else if tab.navigationRevision > 0 &&
                          tab.failedNavigationRevision >= tab.navigationRevision &&
                          tab.failedNavigationRevision > tab.completedNavigationRevision {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(LimaTheme.error)
                        .accessibilityLabel("Page failed to load")
                } else if !tab.isSuspended && tab.navigationRevision > 0 &&
                          tab.completedNavigationRevision >= tab.navigationRevision {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(LimaTheme.textTertiary)
                        .accessibilityLabel("Page ready")
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(LimaTheme.surfacePrimary)
            .onAppear { address = tab.urlString }
            .onChange(of: tab.urlString) { address = $0 }
            GlassHairline()
            if model.pausedTabIDs.contains(tab.id) {
                HStack(spacing: 8) {
                    Image(systemName: "pause.circle.fill")
                    Text("AI paused for this tab")
                    Spacer()
                    Button("Resume AI") { try? model.resumeAI(on: tab.id) }
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Color.orange.opacity(0.12))
            }
            ZStack(alignment: .topLeading) {
                if let webView = tab.activeWebView {
                    BrowserWebView(tabID: tab.id, webView: webView)
                } else if tab.urlString.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "globe").font(.system(size: 28))
                        Text("Search or enter an address above")
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView("Resuming tab…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let action = model.automation, action.tabID == tab.id {
                    BrowserAutomationOverlay(
                        state: action,
                        focus: model.aiFocus,
                        showPointer: model.showAIPointer,
                        highlightTarget: model.highlightAITargets,
                        showDescription: model.showActionDescriptions
                    )
                    .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.showActionDescriptions,
               let action = model.automation,
               action.destinationTabID == tab.id {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles").foregroundStyle(.cyan)
                    Text(action.title).lineLimit(1)
                    Spacer(minLength: 0)
                    if tab.isSuspended { Text("Queued").foregroundStyle(.secondary) }
                    else if tab.isLoading { ProgressView().controlSize(.mini) }
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(.thinMaterial)
                .accessibilityLabel("AI: \(action.title)")
            }
        }
    }
}

private struct BrowserAutomationOverlay: View {
    let state: BrowserAutomationState
    let focus: BrowserAIFocusState?
    let showPointer: Bool
    let highlightTarget: Bool
    let showDescription: Bool

    var body: some View {
        GeometryReader { geometry in
            let target = state.target
            let bounds = state.overlayBounds
            let color: Color = state.role == "link" ? .cyan :
                state.role == "type" ? .pink : .purple
            if highlightTarget, let focus, focus.tabID == state.tabID,
               let focusBounds = focus.bounds {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(LinearGradient(colors: [.cyan, .purple, .pink],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing),
                                  lineWidth: 2)
                    .frame(width: max(1, focusBounds.width), height: max(1, focusBounds.height))
                    .position(x: focusBounds.midX, y: focusBounds.midY)
            }
            if showPointer, let bounds {
                let destination = CGPoint(x: bounds.minX + 25, y: bounds.maxY + 12)
                let cursor = state.phase == .focusing ? state.pointerStart : destination
                Text("↖ AI")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .padding(5)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(LinearGradient(colors: [.cyan, .purple, .pink],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing),
                                      lineWidth: 1))
                    .position(x: min(geometry.size.width - 25, max(25, cursor.x)),
                              y: min(geometry.size.height - 12, max(12, cursor.y)))
                    .animation(.easeInOut(duration: 0.22), value: state.phase)
                if state.phase == .acting {
                    Circle()
                        .strokeBorder(color.opacity(0.75), lineWidth: 2)
                        .frame(width: 30, height: 30)
                        .position(x: min(geometry.size.width - 15, max(15, destination.x)),
                                  y: min(geometry.size.height - 15, max(15, destination.y)))
                }
            }
            if showDescription {
                Label(bounds == nil && target.frameID != "main"
                      ? state.title + " · embedded frame" : state.title,
                      systemImage: "sparkles")
                    .font(.system(size: 11, weight: .medium))
                    .padding(7)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .position(x: bounds.map {
                        min(geometry.size.width - 100, max(105, $0.minX + 100))
                    } ?? geometry.size.width / 2,
                              y: bounds.map {
                        min(geometry.size.height - 15, max(20, $0.minY - 20))
                    } ?? 20)
            }
        }
        .accessibilityLabel("AI: \(state.title)")
    }
}

struct BrowserWorkspaceSettingsView: View {
    @ObservedObject private var browser = BrowserWorkspaceModel.shared
    @State private var showingClearConfirmation = false
    @State private var dataCleared = false

    var body: some View {
        Form {
            Section("AI Control") {
                Picker("Default", selection: $browser.aiControlMode) {
                    ForEach(BrowserAIControlMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Text("Page interactions invalidate stale AI targets. Use Pause AI on a tab to stop AI access until you resume it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("One mode governs reading, navigation, and interaction in Lima Browser tabs. Sensitive controls remain protected even with Full Control.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Visual Feedback") {
                Toggle("Show AI pointer", isOn: $browser.showAIPointer)
                Toggle("Highlight AI targets", isOn: $browser.highlightAITargets)
                Toggle("Show action descriptions", isOn: $browser.showActionDescriptions)
            }
            Section("Privacy") {
                LabeledContent("Sensitive fields", value: "Always protected")
                Button("Clear Browser Data", role: .destructive) {
                    showingClearConfirmation = true
                }
                if dataCleared {
                    Text("Browser website data was cleared.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier(LimaQAIdentifiers.Settings.browser)
        .confirmationDialog(
            "Clear Lima Browser website data?",
            isPresented: $showingClearConfirmation
        ) {
            Button("Clear Browser Data", role: .destructive) {
                Task {
                    await browser.clearWebsiteData()
                    dataCleared = true
                }
            }
        } message: {
            Text("This removes Lima Browser cookies, caches, and other website data. You may be signed out of websites.")
        }
    }
}
