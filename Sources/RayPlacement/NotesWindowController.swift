import AppKit
import RayPlacementCore
import SwiftUI
import UniformTypeIdentifiers

private enum NotesWindowMode: String {
    case workspace
    case dockedLeft
    case dockedRight
    case fullScreen

    var isDocked: Bool { self == .dockedLeft || self == .dockedRight }

    var dockEdge: NotesDockEdge? {
        switch self {
        case .dockedLeft: return .left
        case .dockedRight: return .right
        case .workspace, .fullScreen: return nil
        }
    }

}

private enum NotesSection {
    case notes
    case dictation
}

@MainActor
private final class NotesPresentationModel: ObservableObject {
    @Published fileprivate(set) var mode: NotesWindowMode
    @Published var sidebarVisible = true
    @Published var section: NotesSection = .notes
    @Published var focusDictationEditor = false

    init(mode: NotesWindowMode) {
        self.mode = mode
    }

    func setMode(_ mode: NotesWindowMode) {
        self.mode = mode
    }
}

@MainActor
final class NotesWindowController: NSObject, NSWindowDelegate {
    let store: NotesStore
    let conversations: DictationConversationStore
    let dictation: NoteDictationService

    private static let windowModeKey = "notesWindowMode"
    private static let dockWidthKey = "notesDockWidth"
    private static let workspaceFrameKey = "notesWorkspaceFrame"
    private static let quickNoteTargetIDKey = "quickNoteTargetID"
    private static let quickNoteTargetModeKey = "quickNoteTargetMode"

    private let presentation: NotesPresentationModel
    private var window: NSWindow?
    private var dictationHUD: DictationHUDController!
    private var workspaceFrame: NSRect?
    private var modeBeforeFullScreen: NotesWindowMode = .workspace
    private var sidebarBeforeFullScreen = true
    private var isApplyingFrame = false

    override init() {
        let store = NotesStore.shared
        let conversations = DictationConversationStore.shared
        self.store = store
        self.conversations = conversations
        self.dictation = NoteDictationService(
            onTranscript: { [weak conversations] transcript in
                conversations?.append(transcript)
            },
            onSessionStarted: { [weak conversations] in
                conversations?.beginConversation()
            },
            onSessionRetryStarted: { [weak conversations] in
                conversations?.beginRetryConversation()
            },
            onSessionFinished: { [weak conversations] in
                conversations?.finishConversation()
            },
            onSessionFailed: { [weak conversations] in
                conversations?.failConversationForRetry()
            }
        )
        let savedMode = UserDefaults.standard.string(forKey: Self.windowModeKey)
            .flatMap(NotesWindowMode.init(rawValue:))
        self.presentation = NotesPresentationModel(
            mode: savedMode == .dockedLeft || savedMode == .dockedRight ? savedMode! : .workspace
        )
        super.init()
        self.dictationHUD = DictationHUDController(
            dictation: dictation,
            conversations: conversations,
            openConversation: { [weak self] id in
                self?.presentDictationConversation(id: id)
            }
        )
    }

    func present() {
        restoreWorkspaceSelection()
        let window = ensureWindow()
        applyPresentationMode(presentation.mode, to: window, animated: false)
        WorkspaceWindowCoordinator.shared.present(window, joinWorkspace: !presentation.mode.isDocked)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func restoreWorkspaceSelection() {
        let state = WorkspaceStateRegistry.shared.state
        if let id = state.selectedNoteID, store.notes.contains(where: { $0.id == id }) {
            store.selectedNoteID = id
        }
        if let id = state.selectedDictationID, conversations.conversations.contains(where: { $0.id == id }) {
            conversations.selectedConversationID = id
        }
        if state.notesSection == "dictation" { presentation.section = .dictation }
        else if state.notesSection == "notes" { presentation.section = .notes }
    }

    func toggleVisibility() {
        if let window, window.isVisible {
            store.flush()
            window.orderOut(nil)
        } else {
            present()
        }
    }

    func presentQuickNote() {
        selectQuickNoteTarget()
        let preferredMode: NotesWindowMode = presentation.mode == .dockedLeft ? .dockedLeft : .dockedRight
        let window = ensureWindow()
        applyPresentationMode(preferredMode, to: window, animated: true)
        markQuickNoteTarget()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func presentDockedLeft() {
        presentDocked(.left)
    }

    func presentDockedRight() {
        presentDocked(.right)
    }

    private func presentDocked(_ edge: NotesDockEdge) {
        selectQuickNoteTarget()
        if let window { WorkspaceWindowCoordinator.shared.popOut(window) }
        dock(edge)
        markQuickNoteTarget()
        NSApp.activate(ignoringOtherApps: true)
    }

    fileprivate var quickNoteTargetMode: QuickNoteTargetMode {
        get {
            UserDefaults.standard.string(forKey: Self.quickNoteTargetModeKey)
                .flatMap(QuickNoteTargetMode.init(rawValue:)) ?? .lastQuickNote
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.quickNoteTargetModeKey)
        }
    }

    func setQuickNoteTarget(_ id: UUID) {
        guard store.notes.contains(where: { $0.id == id }) else { return }
        UserDefaults.standard.set(id.uuidString, forKey: Self.quickNoteTargetIDKey)
        quickNoteTargetMode = .lastQuickNote
    }

    fileprivate func setQuickNoteTargetMode(_ mode: QuickNoteTargetMode) {
        quickNoteTargetMode = mode
    }

    private func selectQuickNoteTarget() {
        let savedTargetID = UserDefaults.standard.string(forKey: Self.quickNoteTargetIDKey)
            .flatMap(UUID.init(uuidString:))
        let targetID = QuickNoteTargetResolver.resolve(
            mode: quickNoteTargetMode,
            savedTargetID: savedTargetID,
            selectedNoteID: store.selectedNoteID,
            notes: store.notes
        )

        if let targetID {
            store.selectNote(targetID, recordHistory: false)
        } else {
            // Preserve the existing empty-state behavior, including creating a
            // blank note when Quick Note is opened before any note exists.
            store.selectMostRecentNote()
        }
    }

    private func markQuickNoteTarget() {
        guard presentation.mode.isDocked, let id = store.selectedNoteID else { return }
        UserDefaults.standard.set(id.uuidString, forKey: Self.quickNoteTargetIDKey)
    }

    func selectNote(_ id: UUID) {
        guard store.notes.contains(where: { $0.id == id }) else { return }
        store.selectNote(id)
        presentation.section = .notes
    }

    func selectDictation(_ id: UUID) {
        guard conversations.conversations.contains(where: { $0.id == id }) else { return }
        conversations.selectedConversationID = id
        presentation.section = .dictation
        WorkspaceStateRegistry.shared.update {
            $0.selectedDictationID = id
            $0.notesSection = "dictation"
        }
    }

    /// Presents the exact conversation associated with the active dictation
    /// session. This intentionally does not use the historically selected row.
    func presentDictationConversation(id: UUID) {
        guard conversations.conversations.contains(where: { $0.id == id }) else { return }
        selectDictation(id)
        let window = ensureWindow()
        applyPresentationMode(presentation.mode, to: window, animated: false)
        WorkspaceWindowCoordinator.shared.present(window, joinWorkspace: !presentation.mode.isDocked)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        presentation.focusDictationEditor = true
    }

    func presentMostRecentAndToggleDictation() {
        presentation.section = .dictation
        present()
        guard dictation.phase == .idle || dictation.phase == .recording else { return }
        dictation.performPrimaryAction()
    }

    func shutdown() {
        dictation.cancel()
        store.flush()
        conversations.flush()
    }

    func windowWillClose(_ notification: Notification) {
        store.flush()
    }

    func windowDidMove(_ notification: Notification) {
        guard !isApplyingFrame, presentation.mode == .workspace, let window else { return }
        rememberWorkspaceFrame(window.frame)
    }

    func windowDidResize(_ notification: Notification) {
        guard !isApplyingFrame, let window else { return }
        if presentation.mode == .workspace {
            rememberWorkspaceFrame(window.frame)
        } else if let edge = presentation.mode.dockEdge {
            UserDefaults.standard.set(window.frame.width, forKey: Self.dockWidthKey)
            applyDockFrame(edge: edge, to: window, animated: false)
        }
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard let window, let edge = presentation.mode.dockEdge else { return }
        applyDockFrame(edge: edge, to: window, animated: false)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        modeBeforeFullScreen = presentation.mode
        sidebarBeforeFullScreen = presentation.sidebarVisible
        presentation.setMode(.fullScreen)
        presentation.sidebarVisible = false
        window?.level = .normal
        window?.collectionBehavior = [.managed]
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        presentation.sidebarVisible = sidebarBeforeFullScreen
        guard let window else { return }
        let returnMode = modeBeforeFullScreen == .fullScreen ? .workspace : modeBeforeFullScreen
        applyPresentationMode(returnMode, to: window, animated: true)
    }

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let window = makeWindow()
        self.window = window
        return window
    }

    private func makeWindow() -> NSWindow {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let defaultFrame = NSRect(
            x: visibleFrame.midX - 520,
            y: visibleFrame.midY - 370,
            width: 1_040,
            height: 740
        )
        let savedFrame = UserDefaults.standard.string(forKey: Self.workspaceFrameKey)
            .map(NSRectFromString) ?? defaultFrame
        let initialFrame = appKitRect(NotesWindowLayout.clampedWorkspaceFrame(savedFrame, visibleFrame: visibleFrame))
        workspaceFrame = initialFrame

        let window = NSWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        LimaWindowChrome.configure(
            window,
            title: "Lima Notes",
            accessibilityLabel: "Lima Notes",
            movableByBackground: false
        )
        window.tabbingMode = NSWindow.TabbingMode.preferred
        window.isReleasedWhenClosed = false
        window.hasShadow = true
        window.delegate = self
        window.contentView = NSHostingView(rootView: LimaTypographyRoot(content: NotesView(
            store: store,
            conversations: conversations,
            dictation: dictation,
            presentation: presentation,
            dockLeft: { [weak self] in self?.dock(.left) },
            dockRight: { [weak self] in self?.dock(.right) },
            restoreWorkspace: { [weak self] in self?.restoreWorkspace() },
            toggleFullScreen: { [weak self] in self?.toggleFullScreen() },
            setQuickNoteTarget: { [weak self] id in self?.setQuickNoteTarget(id) },
            setQuickNoteTargetMode: { [weak self] mode in self?.setQuickNoteTargetMode(mode) },
            quickNoteTargetMode: { [weak self] in self?.quickNoteTargetMode ?? .lastQuickNote }
        )))
        return window
    }

    private func dock(_ edge: NotesDockEdge) {
        let window = ensureWindow()
        if presentation.mode == .workspace {
            rememberWorkspaceFrame(window.frame)
        }
        if store.selectedNote == nil { selectQuickNoteTarget() }
        applyPresentationMode(edge == .left ? .dockedLeft : .dockedRight, to: window, animated: true)
        markQuickNoteTarget()
        window.makeKeyAndOrderFront(nil)
    }

    private func restoreWorkspace() {
        guard let window else {
            presentation.setMode(.workspace)
            UserDefaults.standard.set(NotesWindowMode.workspace.rawValue, forKey: Self.windowModeKey)
            return
        }
        applyPresentationMode(.workspace, to: window, animated: true)
    }

    private func toggleFullScreen() {
        let window = ensureWindow()
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            return
        }

        if presentation.mode == .fullScreen {
            setWindowControls(hidden: false, on: window)
            presentation.sidebarVisible = sidebarBeforeFullScreen
            let returnMode = modeBeforeFullScreen == .fullScreen ? .workspace : modeBeforeFullScreen
            applyPresentationMode(returnMode, to: window, animated: true)
            return
        }

        modeBeforeFullScreen = presentation.mode
        sidebarBeforeFullScreen = presentation.sidebarVisible
        if presentation.mode == .workspace {
            rememberWorkspaceFrame(window.frame)
        }
        presentation.setMode(.fullScreen)
        presentation.sidebarVisible = false
        window.level = .normal
        window.collectionBehavior = [.managed]
        window.minSize = NSSize(width: 800, height: 500)
        window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        window.isMovable = false
        setWindowControls(hidden: true, on: window)
        let target = (window.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        setFrame(target, on: window, animated: true)
    }

    private func applyPresentationMode(_ mode: NotesWindowMode, to window: NSWindow, animated: Bool) {
        presentation.setMode(mode)
        if mode != .fullScreen {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.windowModeKey)
        }

        switch mode {
        case .workspace:
            setWindowControls(hidden: false, on: window)
            window.isMovable = true
            window.level = .normal
            window.collectionBehavior = [.managed]
            window.minSize = NSSize(width: 800, height: 500)
            window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            let target = workspaceFrame ?? initialWorkspaceFrame(for: window.screen)
            setFrame(target, on: window, animated: animated)
        case .dockedLeft, .dockedRight:
            setWindowControls(hidden: false, on: window)
            window.isMovable = true
            window.level = .floating
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.minSize = NSSize(width: NotesWindowLayout.minimumDockWidth, height: 480)
            window.maxSize = NSSize(width: NotesWindowLayout.maximumDockWidth, height: CGFloat.greatestFiniteMagnitude)
            if let edge = mode.dockEdge { applyDockFrame(edge: edge, to: window, animated: animated) }
        case .fullScreen:
            break
        }
    }

    private func setWindowControls(hidden: Bool, on window: NSWindow) {
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { buttonType in
            window.standardWindowButton(buttonType)?.isHidden = hidden
        }
    }

    private func applyDockFrame(edge: NotesDockEdge, to window: NSWindow, animated: Bool) {
        let visibleFrame = (window.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let savedWidth = UserDefaults.standard.double(forKey: Self.dockWidthKey)
        let preferredWidth = savedWidth > 0 ? savedWidth : 420
        let frame = appKitRect(NotesWindowLayout.dockedFrame(
            edge: edge,
            visibleFrame: visibleFrame,
            preferredWidth: preferredWidth
        ))
        setFrame(frame, on: window, animated: animated)
    }

    private func setFrame(_ frame: NSRect, on window: NSWindow, animated: Bool) {
        isApplyingFrame = true
        window.setFrame(frame, display: true, animate: animated)
        isApplyingFrame = false
    }

    private func rememberWorkspaceFrame(_ frame: NSRect) {
        workspaceFrame = frame
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.workspaceFrameKey)
    }

    private func initialWorkspaceFrame(for screen: NSScreen?) -> NSRect {
        let visibleFrame = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let savedFrame = UserDefaults.standard.string(forKey: Self.workspaceFrameKey)
            .map(NSRectFromString)
            ?? NSRect(x: visibleFrame.midX - 520, y: visibleFrame.midY - 370, width: 1_040, height: 740)
        let clamped = appKitRect(NotesWindowLayout.clampedWorkspaceFrame(savedFrame, visibleFrame: visibleFrame))
        workspaceFrame = clamped
        return clamped
    }

    private func appKitRect(_ rect: CGRect) -> NSRect {
        NSRect(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height)
    }
}

private struct NotesView: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var conversations: DictationConversationStore
    @ObservedObject var dictation: NoteDictationService
    @ObservedObject var presentation: NotesPresentationModel
    @ObservedObject private var settings = SettingsStore.shared
    let dockLeft: () -> Void
    let dockRight: () -> Void
    let restoreWorkspace: () -> Void
    let toggleFullScreen: () -> Void
    let setQuickNoteTarget: (UUID) -> Void
    let setQuickNoteTargetMode: (QuickNoteTargetMode) -> Void
    let quickNoteTargetMode: () -> QuickNoteTargetMode

    @State private var searchQuery = ""
    @State private var isSearchPresented = false
    @State private var isDockBrowserExpanded = false
    @State private var confirmDelete = false
    @State private var confirmDeleteDictation = false
    @State private var pendingDictationDeleteID: UUID?
    @State private var deleteActiveDictation = false
    @State private var showAppearance = false
    @State private var showTags = false
    @State private var showRevisions = false
    @State private var exportError: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var dictationEditorFocused: Bool

    private var filteredNotes: [MarkdownNote] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return store.notes }
        return store.notes.filter { note in
            note.displayTitle.lowercased().contains(query)
                || note.content.prefix(20_000).lowercased().contains(query)
                || note.tags.contains { $0.lowercased().contains(query) }
        }
    }

    private var pinnedNotes: [MarkdownNote] { filteredNotes.filter(\.isPinned) }
    private var favoriteNotes: [MarkdownNote] { filteredNotes.filter { !$0.isPinned && $0.isFavorite } }
    private var regularNotes: [MarkdownNote] { filteredNotes.filter { !$0.isPinned && !$0.isFavorite } }

    var body: some View {
        ZStack {
            LiquidGlassBackdrop(material: .underWindowBackground, blendingMode: .behindWindow)
            VStack(spacing: LimaDesign.panelGap) {
                if !presentation.mode.isDocked {
                    windowChrome
                        .limaNativeSurface(fill: LimaColors.raisedSurface, radius: LimaRadius.panel, border: LimaColors.border)
                }
                if presentation.mode.isDocked {
                    VStack(spacing: 0) {
                        if isDockBrowserExpanded {
                            noteBrowser(compact: true)
                                .frame(minHeight: 132, maxHeight: 224)
                        } else {
                            dockedNoteHeader
                                .frame(height: 46)
                        }
                        GlassHairline()
                        editor
                    }
                    .limaNativeSurface(fill: LimaColors.raisedSurface, radius: LimaRadius.panel, border: LimaColors.border)
                } else if presentation.sidebarVisible && presentation.mode != .fullScreen {
                    HStack(spacing: 10) {
                        sidebar
                            .frame(width: 246)
                            .limaNativeSurface(fill: LimaColors.sidebarBackground, radius: LimaRadius.panel, border: LimaColors.border)
                        editor
                            .frame(minWidth: 470, maxWidth: .infinity, maxHeight: .infinity)
                            .limaNativeSurface(fill: LimaColors.editorBackground, radius: LimaRadius.panel, border: LimaColors.border)
                    }
                } else {
                    editor
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .limaNativeSurface(fill: LimaColors.editorBackground, radius: LimaRadius.panel, border: LimaColors.border)
                }
            }
            .padding(.horizontal, presentation.mode.isDocked ? 6 : LimaDesign.windowPadding)
            .padding(.bottom, presentation.mode.isDocked ? 6 : LimaDesign.windowPadding)
            .padding(.top, presentation.mode == .fullScreen ? 10 : 7)
        }
        .frame(
            minWidth: presentation.mode.isDocked ? NotesWindowLayout.minimumDockWidth : 720,
            minHeight: 500
        )
        .tint(SettingsStore.shared.accentTheme.readablePrimary)
        .onChange(of: presentation.focusDictationEditor) { shouldFocus in
            guard shouldFocus else { return }
            DispatchQueue.main.async {
                dictationEditorFocused = true
                presentation.focusDictationEditor = false
            }
        }
        .alert("Delete this note?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Note", role: .destructive) { store.deleteSelectedNote() }
        } message: {
            Text("This permanently removes the selected local note.")
        }
        .alert("Notes operation failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "Unknown error")
        }
        .alert("Delete this dictation?", isPresented: $confirmDeleteDictation) {
            Button("Cancel", role: .cancel) {
                pendingDictationDeleteID = nil
                deleteActiveDictation = false
            }
            Button(deleteActiveDictation ? "Stop & Delete" : "Delete Conversation", role: .destructive) {
                if deleteActiveDictation { dictation.cancel() }
                if let identifier = pendingDictationDeleteID,
                   let conversation = conversations.conversations.first(where: { $0.id == identifier }) {
                    conversations.delete(conversation)
                }
                pendingDictationDeleteID = nil
                deleteActiveDictation = false
            }
        } message: {
            Text(deleteActiveDictation
                ? "Recording or transcription will stop, and this conversation will be permanently removed."
                : "This permanently removes the selected local dictation conversation.")
        }
        .sheet(isPresented: $showTags) {
            TagEditorSheet(tags: store.selectedNote?.tags ?? []) { tags in
                store.replaceTags(tags)
                showTags = false
            }
        }
        .sheet(isPresented: $showRevisions) {
            RevisionHistorySheet(revisions: store.selectedNote?.revisionHistory ?? []) { revision in
                store.restore(revision)
                showRevisions = false
            }
        }
        .limaAnimation(LimaDesign.spring(0.34), value: presentation.sidebarVisible)
        .limaAnimation(LimaDesign.spring(0.34), value: presentation.mode)
        .limaAnimation(.easeInOut(duration: 0.24), value: settings.notesVisualTheme)
    }

    private var windowChrome: some View {
        HStack(spacing: presentation.mode.isDocked ? 6 : 10) {
            LimaToolbarTitle(
                symbol: presentation.mode.isDocked ? "note.text" : "note.text.badge.plus",
                title: presentation.mode.isDocked ? "Quick Note" : "Notes",
                subtitle: presentation.section == .dictation ? "Separate conversations" : "Local Markdown workspace"
            )
            .frame(maxWidth: presentation.mode.isDocked ? 150 : 270, alignment: .leading)
            .layoutPriority(1)

            Spacer(minLength: presentation.mode.isDocked ? 4 : 8)

            if presentation.mode.isDocked {
                Menu {
                    Button {
                        presentation.section = .notes
                    } label: {
                        Label("Notes", systemImage: "note.text")
                    }
                    Button {
                        presentation.section = .dictation
                    } label: {
                        Label("Dictation", systemImage: "waveform")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: presentation.section == .notes ? "note.text" : "waveform")
                        Text(presentation.section == .notes ? "Notes" : "Dictation")
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .limaFont(.caption2)
                    }
                    .frame(minWidth: 92, maxWidth: 120, minHeight: 28)
                }
                .menuStyle(.borderlessButton)
                .limaNativeSurface(fill: LimaColors.recessedSurface, radius: LimaRadius.control, border: LimaColors.border)
                .help("Choose Quick Note section")

                Menu {
                    Button("Customize Notes") { showAppearance = true }
                    Divider()
                    Button("Return to Workspace", action: restoreWorkspace)
                    Button(
                        presentation.mode == .dockedLeft ? "Move Quick Note Right" : "Move Quick Note Left",
                        action: presentation.mode == .dockedLeft ? dockRight : dockLeft
                    )
                    Divider()
                    Button("Enter Full Screen", action: toggleFullScreen)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 30, height: 28)
                }
                .menuStyle(.borderlessButton)
                .limaNativeSurface(fill: LimaColors.recessedSurface, radius: LimaRadius.control, border: LimaColors.border)
                .help("Quick Note actions")
                .accessibilityLabel("Quick Note actions")
            } else {
                Picker("Notes section", selection: $presentation.section) {
                    Label("Notes", systemImage: "note.text").tag(NotesSection.notes)
                    Label("Dictation", systemImage: "waveform").tag(NotesSection.dictation)
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
                .controlSize(.small)

                NotesChromeButton(symbol: "slider.horizontal.3", label: "Customize Notes") {
                    showAppearance.toggle()
                }

                if presentation.mode == .workspace {
                    NotesChromeButton(
                        symbol: presentation.sidebarVisible ? "sidebar.left" : "rectangle.righthalf.inset.filled",
                        label: presentation.sidebarVisible ? "Hide Notes Sidebar" : "Show Notes Sidebar",
                        action: { presentation.sidebarVisible.toggle() }
                    )
                }

                if presentation.mode != .fullScreen {
                    NotesChromeButton(symbol: "rectangle.lefthalf.inset.filled", label: "Dock Quick Note Left", action: dockLeft)
                        .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    NotesChromeButton(symbol: "rectangle.righthalf.inset.filled", label: "Dock Quick Note Right", action: dockRight)
                        .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                }
            }

            if !presentation.mode.isDocked {
                NotesChromeButton(
                    symbol: presentation.mode == .fullScreen
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right",
                    label: presentation.mode == .fullScreen ? "Exit Full Screen" : "Enter Full Screen",
                    action: toggleFullScreen
                )
                .keyboardShortcut("f", modifiers: [.command, .control])
            }
        }
        .padding(.leading, presentation.mode == .fullScreen ? 18 : (presentation.mode.isDocked ? 10 : 78))
        .padding(.trailing, 10)
        .frame(height: LimaDesign.toolbarHeight)
        .popover(isPresented: $showAppearance, arrowEdge: .bottom) {
            NotesAppearancePanel(settings: settings)
        }
    }

    private var dockedNoteHeader: some View {
        HStack(spacing: 7) {
            Button {
                isDockBrowserExpanded = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "note.text")
                        .foregroundStyle(SettingsStore.shared.accentTheme.readablePrimary)
                    Text(store.selectedNote?.displayTitle ?? "Choose a note")
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .limaFont(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("Choose a note")
            .accessibilityLabel("Choose a note")

            NotesChromeButton(symbol: "magnifyingglass", label: "Find a note") {
                isDockBrowserExpanded = true
                isSearchPresented = true
            }
            Menu {
                Section("Quick Note target") {
                    ForEach(QuickNoteTargetMode.allCases) { mode in
                        Button {
                            setQuickNoteTargetMode(mode)
                        } label: {
                            Label(mode.title, systemImage: quickNoteTargetMode() == mode ? "checkmark" : "circle")
                        }
                    }
                }
                Divider()
                Button {
                    store.createNote()
                } label: {
                    Label("New Note", systemImage: "plus")
                }
                Button {
                    presentation.section = .notes
                } label: {
                    Label("Notes", systemImage: "note.text")
                }
                Button {
                    presentation.section = .dictation
                } label: {
                    Label("Dictation", systemImage: "waveform")
                }
                Divider()
                if let note = store.selectedNote {
                    Button(note.isPinned ? "Unpin Note" : "Pin Note", action: store.togglePin)
                    Button(note.isFavorite ? "Remove from Favorites" : "Add to Favorites", action: store.toggleFavorite)
                    Button("Set as Quick Note") { setQuickNoteTarget(note.id) }
                    Button("Edit Tags…") { showTags = true }
                    Button("Revision History…") { showRevisions = true }
                }
                Divider()
                Button("Customize Notes") { showAppearance = true }
                Button("Return to Workspace", action: restoreWorkspace)
                Button(
                    presentation.mode == .dockedLeft ? "Move Quick Note Right" : "Move Quick Note Left",
                    action: presentation.mode == .dockedLeft ? dockRight : dockLeft
                )
                Button("Enter Full Screen", action: toggleFullScreen)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 30, height: 28)
            }
            .menuStyle(.borderlessButton)
            .limaNativeSurface(fill: LimaColors.recessedSurface, radius: LimaRadius.control, border: LimaColors.border)
            .help("Quick Note actions")
            .accessibilityLabel("Quick Note actions")
        }
        .padding(.horizontal, 8)
    }

    private var sidebar: some View {
        noteBrowser(compact: false)
            .limaNativeSurface(fill: LimaColors.sidebarBackground, radius: LimaRadius.panel, border: LimaColors.border)
    }

    private func noteBrowser(compact: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if compact && !isSearchPresented {
                    HStack(spacing: 5) {
                        Image(systemName: "note.text")
                            .foregroundStyle(SettingsStore.shared.accentTheme.readablePrimary)
                        Text(store.selectedNote?.displayTitle ?? "Choose a note")
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search notes", text: $searchQuery)
                            .textFieldStyle(.plain)
                        if compact {
                            Button {
                                searchQuery = ""
                                isSearchPresented = false
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Close note search")
                        }
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .limaNativeSurface(fill: LimaColors.recessedSurface, radius: LimaRadius.control, border: LimaColors.border)
                    .frame(maxWidth: .infinity)
                }

                if compact && isDockBrowserExpanded {
                    NotesChromeButton(symbol: "chevron.up", label: "Collapse note browser") {
                        searchQuery = ""
                        isSearchPresented = false
                        isDockBrowserExpanded = false
                    }
                }

                if compact {
                    NotesChromeButton(
                        symbol: isSearchPresented ? "xmark" : "magnifyingglass",
                        label: isSearchPresented ? "Close note search" : "Find a note",
                        action: {
                            if isSearchPresented {
                                searchQuery = ""
                            }
                            isSearchPresented.toggle()
                        }
                    )
                }

                Menu {
                    Section("New Note") {
                        ForEach(MarkdownNoteTemplate.allCases) { template in
                            Button {
                                store.createNote(template: template)
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(template.title)
                                        Text(template.detail)
                                            .limaFont(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: template == .blank ? "square.and.pencil" : "doc.text.fill")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: compact ? "plus" : "square.and.pencil")
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .limaButton(prominent: true)
                .controlSize(.small)
                .help("New Note or Template (Command-N)")
                .keyboardShortcut("n", modifiers: .command)
            }
            .padding(compact ? 8 : 10)

            GlassHairline()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    if !pinnedNotes.isEmpty {
                        sidebarSectionLabel("Pinned")
                            .padding(.horizontal, 8)
                            .padding(.top, 3)
                        ForEach(pinnedNotes) { note in
                            noteSelectionButton(note)
                        }
                    }

                    if !favoriteNotes.isEmpty {
                        sidebarSectionLabel("Favorites")
                            .padding(.horizontal, 8)
                            .padding(.top, 3)
                        ForEach(favoriteNotes) { note in
                            noteSelectionButton(note)
                        }
                    }

                    if !regularNotes.isEmpty {
                        sidebarSectionLabel(searchQuery.isEmpty ? "Recent" : "Results")
                            .padding(.horizontal, 8)
                            .padding(.top, 3)
                        ForEach(regularNotes) { note in
                            noteSelectionButton(note)
                        }
                    }

                    if filteredNotes.isEmpty {
                        Text(searchQuery.isEmpty ? "No notes yet" : "No matching notes")
                            .limaFont(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 7)
            }

            if !compact {
                GlassHairline()
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .limaFont(.caption2)
                        .foregroundStyle(SettingsStore.shared.accentTheme.readablePrimary)
                    Text("Local")
                    Spacer()
                    Text("\(store.notes.count) \(store.notes.count == 1 ? "note" : "notes")")
                }
                .limaFont(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .frame(height: LimaDesign.statusHeight)
            }
        }
        .background(Color.clear)
    }

    @ViewBuilder
    private var editor: some View {
        if presentation.section == .dictation {
            dictationSection
        } else if let note = store.selectedNote {
            VStack(spacing: 0) {
                editorHeader(note)
                GlassHairline()
                editorCanvas(note)
                GlassHairline()
                noteToolbar(note)
            }
        } else {
            VStack(spacing: 14) {
                ZStack {
                    Circle().fill(SettingsStore.shared.accentTheme.primary.opacity(0.12))
                    Image(systemName: "note.text.badge.plus")
                        .limaFont(.system(size: 28, weight: .medium))
                        .foregroundStyle(SettingsStore.shared.accentTheme.readablePrimary)
                }
                .frame(width: 66, height: 66)
                Text("Start a quick thought").limaFont(.title3.bold())
                Text("Notes save locally as you type.")
                    .limaFont(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Create Note") { store.createNote() }
                    .limaButton(prominent: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var dictationSection: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                dictationSidebarHeader

                Text("Dictation is saved here as its own conversation. Notes stay untouched.")
                    .limaFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ScrollView {
                    LazyVStack(spacing: 5) {
                        if conversations.conversations.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                Image(systemName: "waveform.and.mic")
                                    .foregroundStyle(SettingsStore.shared.accentTheme.readablePrimary)
                                Text("No conversations yet")
                                    .limaFont(.caption.weight(.semibold))
                                Text("Start dictation to create a private conversation.")
                                    .limaFont(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                        } else {
                            ForEach(conversations.conversations) { conversation in
                                Button { conversations.selectedConversationID = conversation.id } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 5) {
                                            Text(conversation.title)
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                                .layoutPriority(1)
                                            Spacer(minLength: 2)
                                            Image(systemName: conversation.isComplete ? "checkmark.circle.fill" : "circle.dotted")
                                                .foregroundStyle(conversation.isComplete ? Color.green : Color.orange)
                                                .accessibilityHidden(true)
                                        }
                                        Text(conversation.preview.isEmpty ? "No transcript yet" : conversation.preview)
                                            .limaFont(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                            .truncationMode(.tail)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 8)
                                    .limaSelection(conversation.id == conversations.selectedConversationID, radius: LimaRadius.control)
                                }
                                .buttonStyle(.plain)
                                .help("Open \(conversation.title)")
                                .accessibilityLabel("\(conversation.title), \(conversation.preview.isEmpty ? "No transcript yet" : conversation.preview)")
                                .accessibilityHint("Select this dictation conversation")
                            }
                        }
                    }
                }
                .frame(minHeight: 90, maxHeight: .infinity)
            }
            .frame(width: presentation.mode.isDocked ? 180 : 280)
            .padding(10)

            VStack(alignment: .leading, spacing: 10) {
                if let conversation = conversations.selectedConversation {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(conversation.title)
                                .limaFont(.title3.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .help(conversation.title)
                            Text(dictationConversationStatus(for: conversation))
                                .limaFont(.caption)
                                .foregroundStyle(dictationStatusColor(for: conversation))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .layoutPriority(1)

                        Spacer(minLength: 4)

                        if dictation.phase == .recording || dictation.phase == .paused {
                            HStack(spacing: 4) {
                                Button { dictation.pauseOrResume() } label: {
                                    Image(systemName: dictation.phase == .recording ? "pause.fill" : "play.fill")
                                        .frame(width: 27, height: 27)
                                }
                                .buttonStyle(.borderless)
                                .help(dictation.phase == .recording ? "Pause recording" : "Resume recording")
                                .accessibilityLabel(dictation.phase == .recording ? "Pause recording" : "Resume recording")

                                Button { dictation.performPrimaryAction() } label: {
                                    Image(systemName: "stop.fill")
                                        .frame(width: 27, height: 27)
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.red)
                                .help("Stop recording and transcribe")
                                .accessibilityLabel("Stop recording and transcribe")
                            }
                        } else if dictation.phase == .completed || dictation.phase == .failed || dictation.phase == .idle {
                            if dictation.recoveryAudioURL != nil, dictation.phase == .idle {
                                Button("Retry") { dictation.retryFailedRecording() }
                                    .limaButton(prominent: true)
                                    .controlSize(.mini)
                                    .help("Retry transcription of the saved recording")
                            }
                        }

                        Button(role: .destructive) {
                            requestDeleteConversation(conversation)
                        } label: {
                            Image(systemName: "trash")
                                .frame(width: 27, height: 27)
                        }
                        .buttonStyle(.borderless)
                        .help(dictationIsBusy ? "Stop and delete conversation" : "Delete conversation")
                        .accessibilityLabel(dictationIsBusy ? "Stop and delete conversation" : "Delete conversation")
                    }

                    HStack(spacing: 7) {
                        Image(systemName: dictationStateSymbol(for: conversation))
                            .foregroundStyle(dictationStatusColor(for: conversation))
                            .accessibilityHidden(true)
                        Text(dictationEditorState(for: conversation))
                            .limaFont(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if dictation.phase == .recording || dictation.phase == .paused {
                            Text(Self.clockLabel(dictation.recordingElapsed))
                                .limaFont(.caption2.monospacedDigit())
                                .foregroundStyle(.primary)
                            Text("·")
                            Text(dictation.inputSignalText)
                                .limaFont(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(dictationAccessibilityStatus(for: conversation))

                    ZStack(alignment: .topLeading) {
                        TextEditor(text: Binding(
                            get: { conversations.selectedConversation?.transcript ?? "" },
                            set: { conversations.updateTranscript($0, for: conversation.id) }
                        ))
                        .limaFont(.system(size: presentation.mode.isDocked ? 13 : 15))
                        .scrollContentBackground(.hidden)
                        .padding(7)
                        .background(LimaColors.editorBackground, in: RoundedRectangle(cornerRadius: LimaRadius.panel, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: LimaRadius.panel, style: .continuous).stroke(LimaColors.border, lineWidth: LimaDesign.borderWidth))
                        .focused($dictationEditorFocused)
                        .accessibilityLabel("Editable dictation transcript")
                        .accessibilityHint("Correct the transcript directly. Changes are saved locally.")

                        if conversation.transcript.isEmpty {
                            Text(dictation.phase == .recording ? "Live transcript will appear here…" : "Transcript will appear here. You can edit it after recording.")
                                .limaFont(.system(size: presentation.mode.isDocked ? 13 : 15))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 15)
                                .padding(.vertical, 14)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(minHeight: 170, maxHeight: .infinity)

                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: dictationStatusSymbol(for: conversation))
                            .foregroundStyle(dictationStatusColor(for: conversation))
                            .accessibilityHidden(true)
                        Text(dictationStatusMessage(for: conversation))
                            .limaFont(.caption)
                            .foregroundStyle(dictationStatusColor(for: conversation))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 2)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(dictationStatusMessage(for: conversation))
                } else {
                    VStack(alignment: .leading, spacing: 9) {
                        Image(systemName: "waveform.and.mic")
                            .font(.system(size: 25, weight: .semibold))
                            .foregroundStyle(SettingsStore.shared.accentTheme.readablePrimary)
                        Text("Start a dictation conversation")
                            .limaFont(.title3.bold())
                        Text("Your transcript will appear in this tab and will never be appended to a Markdown note.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Start Dictation") { dictation.performPrimaryAction() }
                            .limaButton(prominent: true)
                            .help("Start a new dictation conversation")
                    }
                    .frame(maxWidth: 420, alignment: .leading)
                    Spacer()
                }
            }
            .padding(presentation.mode.isDocked ? 10 : 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var dictationSidebarHeader: some View {
        if presentation.mode.isDocked {
            VStack(alignment: .leading, spacing: 7) {
                Label("Conversations", systemImage: "waveform")
                    .limaFont(.headline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help("Dictation conversations")
                Button { exportSelectedTranscript() } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                .disabled(conversations.selectedConversation == nil)
                .help("Export transcript")
                HStack(spacing: 5) {
                    Spacer(minLength: 0)
                    dictationPauseButton
                    dictationPrimaryButton
                }
            }
        } else {
            HStack(spacing: 7) {
                Label("Conversations", systemImage: "waveform")
                    .limaFont(.headline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                    .help("Dictation conversations")
                Spacer(minLength: 2)
                Button { exportSelectedTranscript() } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                .disabled(conversations.selectedConversation == nil)
                .help("Export transcript")
                dictationPauseButton
                dictationPrimaryButton
            }
        }
    }

    @ViewBuilder
    private var dictationPauseButton: some View {
        if dictation.phase == .recording || dictation.phase == .paused {
            Button { dictation.pauseOrResume() } label: {
                Image(systemName: dictation.phase == .recording ? "pause.fill" : "play.fill")
                    .frame(width: 27, height: 26)
            }
            .buttonStyle(.borderless)
            .background(LimaColors.warning.opacity(0.14), in: RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous).stroke(LimaColors.warning.opacity(0.42), lineWidth: LimaDesign.borderWidth))
            .help(dictation.phase == .recording ? "Pause recording" : "Resume recording")
            .accessibilityLabel(dictation.phase == .recording ? "Pause recording" : "Resume recording")
        }
    }

    private var dictationPrimaryButton: some View {
        Button { dictation.performPrimaryAction() } label: {
            Image(systemName: dictationPrimarySymbol)
                .frame(width: 27, height: 26)
        }
        .buttonStyle(.borderless)
        .background(dictationPrimaryColor.opacity(0.16), in: RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous).stroke(dictationPrimaryColor.opacity(0.48), lineWidth: LimaDesign.borderWidth))
        .help(dictationPrimaryLabel)
        .accessibilityLabel(dictationPrimaryLabel)
    }

    private var dictationIsBusy: Bool {
        switch dictation.phase {
        case .requestingPermission, .recording, .paused, .stopping, .transcribing:
            return true
        case .idle, .completed, .failed:
            return false
        }
    }

    private var dictationPrimaryLabel: String {
        switch dictation.phase {
        case .idle: return "Start dictation"
        case .requestingPermission: return "Waiting for permission"
        case .recording, .paused: return "Stop recording and transcribe"
        case .stopping: return "Finishing recording"
        case .transcribing: return "Transcribing"
        case .completed, .failed: return "Record another dictation"
        }
    }

    private var dictationPrimarySymbol: String {
        switch dictation.phase {
        case .idle, .completed, .failed: return "mic.fill"
        case .recording, .paused: return "stop.fill"
        case .requestingPermission, .stopping, .transcribing: return "hourglass"
        }
    }

    private var dictationPrimaryColor: Color {
        switch dictation.phase {
        case .recording, .paused: return .red
        case .failed: return .orange
        default: return SettingsStore.shared.accentTheme.readablePrimary
        }
    }

    private func requestDeleteConversation(_ conversation: DictationConversation) {
        pendingDictationDeleteID = conversation.id
        deleteActiveDictation = dictationIsBusy
        confirmDeleteDictation = true
    }

    private func dictationConversationStatus(for conversation: DictationConversation) -> String {
        switch dictation.phase {
        case .requestingPermission: return "Waiting for permission"
        case .recording: return "Recording locally · \(Self.clockLabel(dictation.recordingElapsed))"
        case .paused: return "Recording paused · \(Self.clockLabel(dictation.recordingElapsed))"
        case .stopping: return "Finishing recording…"
        case .transcribing: return "Transcribing…"
        case .completed: return dictation.lastError == nil ? "Conversation complete" : "Completed with a warning"
        case .failed: return "Transcription failed"
        case .idle: return conversation.isComplete ? "Conversation complete" : "Ready to continue"
        }
    }

    private func dictationEditorState(for conversation: DictationConversation) -> String {
        switch dictation.phase {
        case .recording: return "Live transcript"
        case .paused: return "Live transcript paused"
        case .requestingPermission, .stopping, .transcribing: return "Processing transcript"
        case .failed: return "Transcript needs attention"
        case .completed: return "Final transcript"
        case .idle: return conversation.transcript.isEmpty ? "No transcript yet" : "Final transcript"
        }
    }

    private func dictationStateSymbol(for conversation: DictationConversation) -> String {
        switch dictation.phase {
        case .recording: return "waveform"
        case .paused: return "pause.circle.fill"
        case .requestingPermission, .stopping, .transcribing: return "ellipsis.circle"
        case .failed: return "exclamationmark.triangle.fill"
        case .completed: return "checkmark.circle.fill"
        case .idle: return conversation.isComplete ? "checkmark.circle.fill" : "circle.dotted"
        }
    }

    private func dictationStatusSymbol(for conversation: DictationConversation) -> String {
        switch dictation.phase {
        case .failed: return "exclamationmark.triangle.fill"
        case .completed: return "checkmark.circle.fill"
        case .idle where conversation.isComplete: return "checkmark.circle.fill"
        case .recording: return "waveform"
        case .paused: return "pause.circle.fill"
        default: return "info.circle"
        }
    }

    private func dictationStatusColor(for conversation: DictationConversation) -> Color {
        switch dictation.phase {
        case .recording, .paused: return .orange
        case .failed: return .orange
        case .completed: return .green
        case .idle where conversation.isComplete: return .green
        default: return .secondary
        }
    }

    private func dictationStatusMessage(for conversation: DictationConversation) -> String {
        if let error = dictation.lastError, dictation.phase == .failed || dictation.phase == .idle {
            return error
        }
        switch dictation.phase {
        case .requestingPermission: return "Approve the requested permission to begin recording."
        case .recording: return "Recording is active. Pause to hold input or stop to finish and transcribe."
        case .paused: return "Recording is paused. Resume to continue or stop to transcribe the saved audio."
        case .stopping: return "Finishing the recording…"
        case .transcribing: return dictation.transcriptionProgress ?? "Transcribing…"
        case .completed: return dictation.lastError ?? "Transcript ready. You can edit the text or record another conversation."
        case .failed: return dictation.lastError ?? "Transcription failed. Retry the saved recording or record another conversation."
        case .idle: return conversation.transcript.isEmpty ? "No transcript yet. Start dictation to capture a conversation." : "Transcript ready. You can edit the text or record another conversation."
        }
    }

    private func dictationAccessibilityStatus(for conversation: DictationConversation) -> String {
        var value = dictationConversationStatus(for: conversation)
        if dictation.phase == .recording || dictation.phase == .paused {
            value += ", \(Self.clockLabel(dictation.recordingElapsed)) elapsed, \(dictation.inputSignalText)"
        }
        return value
    }

    private static func clockLabel(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func editorHeader(_ note: MarkdownNote) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                Button(action: navigateBack) {
                    Image(systemName: "chevron.left")
                        .frame(width: 25, height: 25)
                }
                .buttonStyle(LimaToolbarIconButtonStyle(size: 25))
                .disabled(!store.canNavigateBack)
                .help("Previous Note (Command-[)")
                .accessibilityLabel("Previous Note")
                .keyboardShortcut("[", modifiers: .command)

                Button(action: navigateForward) {
                    Image(systemName: "chevron.right")
                        .frame(width: 25, height: 25)
                }
                .buttonStyle(LimaToolbarIconButtonStyle(size: 25))
                .disabled(!store.canNavigateForward)
                .help("Next Note (Command-])")
                .accessibilityLabel("Next Note")
                .keyboardShortcut("]", modifiers: .command)
            }
            .opacity(presentation.mode.isDocked ? 0.92 : 1)

            VStack(alignment: .leading, spacing: 3) {
                TextField(
                    "Untitled Note",
                    text: Binding(
                        get: { store.selectedNote?.title ?? "" },
                        set: store.updateTitle
                    )
                )
                .textFieldStyle(.plain)
                .limaFont(.system(size: presentation.mode.isDocked ? 17 : 21, weight: .semibold))

                if settings.notesShowMetadata {
                    HStack(spacing: 5) {
                        Text("\(wordCount(note.content)) words")
                        if !presentation.mode.isDocked {
                            Text("·")
                            Text("edited \(relativeTimestamp(note.modifiedAt))")
                        }
                    }
                    .limaFont(.caption2)
                    .foregroundStyle(.secondary)
                }
                if !note.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(note.tags.prefix(4), id: \.self) { tag in
                            Text("#\(tag)")
                                .limaFont(.system(size: 9, weight: .medium))
                                .foregroundStyle(SettingsStore.shared.accentTheme.readablePrimary)
                        }
                    }
                } else if settings.notesShowMetadata {
                    Button {
                        showTags = true
                    } label: {
                        Label("Add tag", systemImage: "tag")
                            .limaFont(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(SettingsStore.shared.accentTheme.readablePrimary)
                    .help("Add a tag to this note")
                    .accessibilityLabel("Add tag to note")
                }
            }

            Spacer(minLength: 6)

            NotesChromeButton(
                symbol: note.isPinned ? "pin.fill" : "pin",
                label: note.isPinned ? "Unpin Note" : "Pin Note",
                action: store.togglePin
            )

            NotesChromeButton(
                symbol: note.isFavorite ? "star.fill" : "star",
                label: note.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                action: store.toggleFavorite
            )

            Menu {
                Button(note.isPinned ? "Unpin Note" : "Pin Note", action: store.togglePin)
                Button(note.isFavorite ? "Remove from Favorites" : "Add to Favorites", action: store.toggleFavorite)
                Divider()
                Button("Duplicate Note") { store.duplicateSelectedNote() }
                Button("Set as Quick Note") { setQuickNoteTarget(note.id) }
                Button("Edit Tags…") { showTags = true }
                Button("Revision History…") { showRevisions = true }
                Divider()
                Button("Delete Note…", role: .destructive) { confirmDelete = true }
                    .keyboardShortcut(.delete, modifiers: .command)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28)
                    .background(LimaColors.raisedSurface, in: RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous).stroke(LimaColors.border, lineWidth: LimaDesign.borderWidth))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 30)
            .help("More Note Actions")
        }
        .padding(.horizontal, presentation.mode.isDocked ? 8 : 18)
        .frame(minHeight: presentation.mode.isDocked ? 46 : 62)
        .background(Color.clear)
    }

    @ViewBuilder
    private func editorCanvas(_ note: MarkdownNote) -> some View {
        let compact = presentation.mode.isDocked
        let markdownEditor = InlineMarkdownEditor(
            text: Binding(
                get: { store.selectedNote?.content ?? "" },
                set: store.updateContent
            ),
            compact: compact,
            scrollOffset: Binding(
                get: { store.noteScrollOffset(for: note.id, compact: compact) ?? 0 },
                set: { store.setNoteScrollOffset($0, for: note.id, compact: compact) }
            ),
            fontStyle: settings.notesFontStyle,
            fontSize: settings.notesFontSize,
            lineSpacing: settings.notesLineSpacing,
            theme: settings.notesVisualTheme,
            inlineGrammarCheckingEnabled: settings.inlineGrammarCheckingEnabled
        )
        .accessibilityLabel("Inline formatted Markdown editor")

        if presentation.mode == .fullScreen || settings.notesContentWidth != .fluid {
            HStack(spacing: 0) {
                Spacer(minLength: presentation.mode.isDocked ? 0 : 20)
                markdownEditor
                    .id(note.id)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing)))
                    .frame(maxWidth: settings.notesContentWidth.maximum)
                    .background(LimaColors.editorBackground, in: RoundedRectangle(cornerRadius: LimaRadius.panel, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: LimaRadius.panel, style: .continuous).stroke(LimaColors.border, lineWidth: LimaDesign.borderWidth))
                Spacer(minLength: presentation.mode.isDocked ? 0 : 20)
            }
            .background(Color.clear)
        } else {
            markdownEditor
                .id(note.id)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing)))
                .background(LimaColors.editorBackground)
        }
    }

    private func noteToolbar(_ note: MarkdownNote) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Menu {
                    Button("Import Markdown…", action: importMarkdown)
                    Button("Export All Markdown…", action: exportMarkdown)
                } label: {
                    Image(systemName: "folder")
                        .frame(width: 25, height: 24)
                }
                .menuStyle(.borderlessButton)
                .help("Import or export Markdown notes")
                HStack(spacing: 1) {
                    Menu {
                        Button("Heading 1") { MarkdownEditorActions.heading(1) }
                        Button("Heading 2") { MarkdownEditorActions.heading(2) }
                        Button("Heading 3") { MarkdownEditorActions.heading(3) }
                        Divider()
                        Button("Quote") { MarkdownEditorActions.insert("> Quote") }
                        Button("Divider") { MarkdownEditorActions.insert("---") }
                        Button("Table") { MarkdownEditorActions.table() }
                        Button("Image…") { MarkdownEditorActions.image() }
                        Button("Chart") { MarkdownEditorActions.chart() }
                    } label: {
                        Image(systemName: "textformat")
                            .limaFont(.system(size: 11, weight: .semibold))
                            .frame(width: 25, height: 24)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 28)
                    .help("Headings, quote, divider, or table")
                    .accessibilityLabel("Insert formatted block")

                    MarkdownInsertButton(symbol: "bold", help: "Bold (Command-B)", action: MarkdownEditorActions.bold)
                    MarkdownInsertButton(symbol: "italic", help: "Italic (Command-I)", action: MarkdownEditorActions.italic)
                    MarkdownInsertButton(symbol: "list.bullet", help: "Apply bullets to selected lines", action: MarkdownEditorActions.bullets)
                    MarkdownInsertButton(symbol: "checklist", help: "Apply checkboxes to selected lines", action: MarkdownEditorActions.checklist)
                    MarkdownInsertButton(symbol: "photo", help: "Add an image from Finder", action: MarkdownEditorActions.image)
                    MarkdownInsertButton(symbol: "chart.bar.xaxis", help: "Insert a native chart", action: MarkdownEditorActions.chart)
                    MarkdownInsertButton(symbol: "chevron.left.forwardslash.chevron.right", help: "Insert formatted code block") {
                        MarkdownEditorActions.insert("```\ncode\n```")
                    }
                    MarkdownInsertButton(symbol: "link", help: "Link (Command-K)", action: MarkdownEditorActions.link)
                }
                .padding(3)
                .limaNativeSurface(fill: LimaColors.recessedSurface, radius: LimaRadius.control, border: LimaColors.border)

                Spacer(minLength: 5)

                if !store.referencedNotes().isEmpty || !store.backlinks().isEmpty {
                    Menu {
                        if !store.referencedNotes().isEmpty {
                            Section("References") {
                                ForEach(store.referencedNotes()) { linked in
                                    Button(linked.displayTitle) { selectNote(linked.id) }
                                }
                            }
                        }
                        if !store.backlinks().isEmpty {
                            Section("Backlinks") {
                                ForEach(store.backlinks()) { linked in
                                    Button(linked.displayTitle) { selectNote(linked.id) }
                                }
                            }
                        }
                    } label: {
                        Label("Links", systemImage: "link")
                            .limaFont(.caption2.weight(.semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .help("References and backlinks")
                }

                let tasks = taskProgress(note.content)
                if tasks.total > 0 {
                    Label("Tasks \(tasks.complete) of \(tasks.total)", systemImage: tasks.complete == tasks.total ? "checkmark.circle.fill" : "circle.dashed")
                        .limaFont(.caption2.weight(.semibold))
                        .foregroundStyle(tasks.complete == tasks.total ? Color.green : Color.secondary)
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(LimaColors.recessedSurface, in: RoundedRectangle(cornerRadius: LimaRadius.small, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: LimaRadius.small, style: .continuous).stroke(LimaColors.border, lineWidth: LimaDesign.borderWidth))
                        .help("Completed tasks")
                }

            }
            .padding(.horizontal, presentation.mode.isDocked ? 9 : 12)
            .padding(.vertical, 8)
        }
        .background(LimaColors.recessedSurface)
    }

    private func importMarkdown() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.text, UTType(filenameExtension: "md")].compactMap { $0 }
        guard panel.runModal() == .OK else { return }
        do { try store.importMarkdown(panel.urls) }
        catch { exportError = error.localizedDescription }
    }

    private func exportMarkdown() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Lima Notes"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.exportMarkdown(to: url) }
        catch { exportError = error.localizedDescription }
    }

    private func exportSelectedTranscript() {
        guard let conversation = conversations.selectedConversation else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(conversation.title).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try conversations.exportTranscript(conversation, to: url) }
        catch { exportError = error.localizedDescription }
    }

    private func selectNote(_ identifier: UUID) {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.12) : LimaDesign.spring(0.28)) {
            store.selectNote(identifier)
            if presentation.mode.isDocked {
                setQuickNoteTarget(identifier)
            }
            if presentation.mode.isDocked {
                searchQuery = ""
                isSearchPresented = false
                isDockBrowserExpanded = false
            }
        }
    }

    private func navigateBack() {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.12) : LimaDesign.spring(0.28)) {
            _ = store.navigateBack()
        }
    }

    private func navigateForward() {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.12) : LimaDesign.spring(0.28)) {
            _ = store.navigateForward()
        }
    }

    private func noteSelectionButton(_ note: MarkdownNote) -> some View {
        Button {
            selectNote(note.id)
        } label: {
            NoteListRow(note: note, selected: store.selectedNoteID == note.id)
        }
            .buttonStyle(.plain)
            .accessibilityLabel("\(note.displayTitle), \(note.preview)")
    }

    private func sidebarSectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .limaFont(.system(size: 9, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }

    private func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    private func taskProgress(_ text: String) -> (complete: Int, total: Int) {
        let lines = text.components(separatedBy: .newlines)
        let taskLines = lines.filter { $0.range(of: #"^\s*- \[[ xX]\]\s+"#, options: .regularExpression) != nil }
        let complete = taskLines.filter { $0.range(of: #"^\s*- \[[xX]\]\s+"#, options: .regularExpression) != nil }.count
        return (complete, taskLines.count)
    }

    private func relativeTimestamp(_ date: Date) -> String {
        let elapsed = max(0, Date().timeIntervalSince(date))
        if elapsed < 60 { return "now" }
        if elapsed < 3_600 { return "\(Int(elapsed / 60))m ago" }
        if elapsed < 86_400 { return "\(Int(elapsed / 3_600))h ago" }
        if elapsed < 604_800 { return "\(Int(elapsed / 86_400))d ago" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

private struct NotesAppearancePanel: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Note appearance", systemImage: "paintpalette.fill")
                    .limaFont(.headline)
                Spacer()
                Button("Reset") {
                    settings.notesVisualTheme = .prism
                    settings.notesFontStyle = .system
                    settings.notesFontSize = 15.5
                    settings.notesLineSpacing = 3.5
                    settings.notesContentWidth = .wide
                    settings.notesShowMetadata = true
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("COLOR").notesAppearanceLabel()
                HStack(spacing: 7) {
                    ForEach(NotesVisualTheme.allCases) { theme in
                        Button {
                            settings.notesVisualTheme = theme
                        } label: {
                            Circle()
                                .fill(theme.gradient)
                                .frame(width: 24, height: 24)
                                .overlay(Circle().stroke(.white.opacity(settings.notesVisualTheme == theme ? 0.9 : 0.18), lineWidth: settings.notesVisualTheme == theme ? LimaDesign.focusWidth : LimaDesign.borderWidth))
                        }
                        .buttonStyle(.plain)
                        .help(theme.title)
                        .accessibilityLabel("Use \(theme.title) notes theme")
                    }
                }
            }

            Picker("Typeface", selection: $settings.notesFontStyle) {
                ForEach(NotesFontStyle.allCases) { style in Text(style.title).tag(style) }
            }
            .pickerStyle(.segmented)

            Picker("Page width", selection: $settings.notesContentWidth) {
                ForEach(NotesContentWidth.allCases) { width in Text(width.title).tag(width) }
            }
            .pickerStyle(.segmented)

            NotesAppearanceSlider(title: "Text", value: $settings.notesFontSize, range: 13...24, valueLabel: "\(Int(settings.notesFontSize)) pt")
            NotesAppearanceSlider(title: "Leading", value: $settings.notesLineSpacing, range: 1...12, valueLabel: String(format: "%.1f", settings.notesLineSpacing))

            Toggle("Show word count and edit time", isOn: $settings.notesShowMetadata)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(16)
        .frame(width: 330)
        .limaNativeSurface(fill: LimaColors.raisedSurface, radius: LimaRadius.panel, border: LimaColors.border, shadow: true)
    }
}

private struct NotesAppearanceSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let valueLabel: String

    var body: some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 52, alignment: .leading)
            Slider(value: $value, in: range)
            Text(valueLabel).monospacedDigit().foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
        }
        .limaFont(.caption)
    }
}

private extension Text {
    func notesAppearanceLabel() -> some View {
        limaFont(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(.secondary)
    }
}

private extension NotesVisualTheme {
    var gradient: LinearGradient {
        let colors: [Color]
        switch self {
        case .prism: colors = [.purple, .cyan]
        case .graphite: colors = [Color(white: 0.48), Color(white: 0.12)]
        case .midnight: colors = [.blue, .indigo]
        case .aurora: colors = [.teal, .purple]
        case .ink: colors = [.orange, Color(red: 0.20, green: 0.12, blue: 0.09)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

private struct TagEditorSheet: View {
    let initialTags: [String]
    let onSave: ([String]) -> Void
    @State private var text: String

    init(tags: [String], onSave: @escaping ([String]) -> Void) {
        initialTags = tags
        self.onSave = onSave
        _text = State(initialValue: tags.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Tags").limaFont(.title3.bold())
            Text("Separate tags with commas. Tags are stored locally.").foregroundStyle(.secondary)
            TextField("project, follow-up, personal", text: $text)
                .limaInputSurface()
            HStack {
                Spacer()
                Button("Save") {
                    onSave(text.split(separator: ",").map(String.init))
                }
                .limaButton(prominent: true)
            }
        }
        .padding(22)
        .frame(width: 420)
    }
}

private struct RevisionHistorySheet: View {
    let revisions: [NoteRevision]
    let onRestore: (NoteRevision) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pendingRestore: NoteRevision?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Revision History").limaFont(.title3.bold())
                    Text("\(revisions.count) saved \(revisions.count == 1 ? "version" : "versions")")
                        .limaFont(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(SettingsStore.shared.accentTheme.readablePrimary)
            }
            if revisions.isEmpty {
                Text("Revisions appear after a note has been edited.").foregroundStyle(.secondary)
            } else {
                List(revisions.reversed()) { revision in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(revision.title.isEmpty ? "Untitled Note" : revision.title)
                                .lineLimit(1)
                            Text(revisionPreview(revision.content))
                                .limaFont(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            HStack(spacing: 6) {
                                Text(revision.timestamp.formatted(date: .abbreviated, time: .shortened))
                                Text("·")
                                Text("\(wordCount(revision.content)) words")
                            }
                            .limaFont(.caption2)
                            .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 8)
                        Button("Restore") { pendingRestore = revision }
                    }
                    .padding(.vertical, 3)
                }
            }
            HStack { Spacer(); Button("Close") { dismiss() } }
        }
        .padding(18)
        .frame(width: 560, height: 410)
        .alert("Restore this revision?", isPresented: Binding(
            get: { pendingRestore != nil },
            set: { if !$0 { pendingRestore = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingRestore = nil }
            Button("Restore") {
                if let pendingRestore { onRestore(pendingRestore) }
                pendingRestore = nil
                dismiss()
            }
        } message: {
            Text("Your current note will be saved as a new revision before this version is restored.")
        }
    }

    private func revisionPreview(_ content: String) -> String {
        let clean = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Empty note"
        return String(clean.prefix(120))
    }

    private func wordCount(_ content: String) -> Int {
        content.split(whereSeparator: { $0.isWhitespace }).count
    }
}

private struct NotesChromeButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .limaFont(.system(size: 12, weight: .semibold))
                .frame(width: 27, height: 27)
        }
        .buttonStyle(LimaToolbarIconButtonStyle(size: 27))
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct NoteListRow: View {
    let note: MarkdownNote
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(note.displayTitle)
                        .limaFont(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if note.isPinned {
                        Image(systemName: "pin.fill")
                            .limaFont(.system(size: 8))
                            .foregroundStyle(SettingsStore.shared.accentTheme.readablePrimary)
                            .accessibilityHidden(true)
                    }
                    if note.isFavorite {
                        Image(systemName: "star.fill")
                            .limaFont(.system(size: 8))
                            .foregroundStyle(Color.yellow)
                            .accessibilityHidden(true)
                    }
                }
                Text(note.preview)
                    .limaFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(relativeTimestamp(note.modifiedAt))
                    if !note.tags.isEmpty {
                        Text("·")
                        Text("\(note.tags.count) \(note.tags.count == 1 ? "tag" : "tags")")
                    }
                }
                .limaFont(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .limaSelection(selected, radius: LimaRadius.control)
        .contentShape(RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous))
    }

    private func relativeTimestamp(_ date: Date) -> String {
        let elapsed = max(0, Date().timeIntervalSince(date))
        if elapsed < 60 { return "now" }
        if elapsed < 3_600 { return "\(Int(elapsed / 60))m ago" }
        if elapsed < 86_400 { return "\(Int(elapsed / 3_600))h ago" }
        if elapsed < 604_800 { return "\(Int(elapsed / 86_400))d ago" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

private struct MarkdownInsertButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .limaFont(.system(size: 11, weight: .semibold))
                .frame(width: 25, height: 24)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(help)
        .accessibilityLabel(help)
    }
}
