import AppKit
import RayPlacementCore
import SwiftUI

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

@MainActor
private final class NotesPresentationModel: ObservableObject {
    @Published fileprivate(set) var mode: NotesWindowMode
    @Published var sidebarVisible = true

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
    let dictation: NoteDictationService

    private static let windowModeKey = "notesWindowMode"
    private static let dockWidthKey = "notesDockWidth"
    private static let workspaceFrameKey = "notesWorkspaceFrame"

    private let presentation: NotesPresentationModel
    private var window: NSWindow?
    private var dictationHUD: DictationHUDController!
    private var workspaceFrame: NSRect?
    private var modeBeforeFullScreen: NotesWindowMode = .workspace
    private var sidebarBeforeFullScreen = true
    private var isApplyingFrame = false

    override init() {
        let store = NotesStore()
        self.store = store
        self.dictation = NoteDictationService { [weak store] transcript, destinationNoteID in
            store?.appendDictation(transcript, to: destinationNoteID)
        }
        let savedMode = UserDefaults.standard.string(forKey: Self.windowModeKey)
            .flatMap(NotesWindowMode.init(rawValue:))
        self.presentation = NotesPresentationModel(
            mode: savedMode == .dockedLeft || savedMode == .dockedRight ? savedMode! : .workspace
        )
        super.init()
        self.dictationHUD = DictationHUDController(dictation: dictation)
    }

    func present() {
        let window = ensureWindow()
        applyPresentationMode(presentation.mode, to: window, animated: false)
        WorkspaceWindowCoordinator.shared.present(window, joinWorkspace: !presentation.mode.isDocked)
        NSApp.activate(ignoringOtherApps: true)
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
        store.selectMostRecentNote()
        let preferredMode: NotesWindowMode = presentation.mode == .dockedLeft ? .dockedLeft : .dockedRight
        let window = ensureWindow()
        applyPresentationMode(preferredMode, to: window, animated: true)
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
        store.selectMostRecentNote()
        if let window { WorkspaceWindowCoordinator.shared.popOut(window) }
        dock(edge)
        NSApp.activate(ignoringOtherApps: true)
    }

    func presentMostRecentAndToggleDictation() {
        store.selectMostRecentNote()
        present()
        guard dictation.phase == .idle || dictation.phase == .recording else { return }
        dictation.performPrimaryAction(
            destinationNoteID: store.selectedNoteID,
            destinationNoteTitle: store.selectedNote?.displayTitle
        )
    }

    func shutdown() {
        dictation.cancel()
        store.flush()
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
        window.title = "Lima Notes"
        window.setAccessibilityLabel("Lima Notes")
        window.titleVisibility = NSWindow.TitleVisibility.hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.tabbingMode = NSWindow.TabbingMode.preferred
        window.isReleasedWhenClosed = false
        window.hasShadow = true
        window.delegate = self
        window.contentView = NSHostingView(rootView: LimaTypographyRoot(content: NotesView(
            store: store,
            dictation: dictation,
            presentation: presentation,
            dockLeft: { [weak self] in self?.dock(.left) },
            dockRight: { [weak self] in self?.dock(.right) },
            restoreWorkspace: { [weak self] in self?.restoreWorkspace() },
            toggleFullScreen: { [weak self] in self?.toggleFullScreen() }
        )))
        return window
    }

    private func dock(_ edge: NotesDockEdge) {
        let window = ensureWindow()
        if presentation.mode == .workspace {
            rememberWorkspaceFrame(window.frame)
        }
        if store.selectedNote == nil { store.selectMostRecentNote() }
        applyPresentationMode(edge == .left ? .dockedLeft : .dockedRight, to: window, animated: true)
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
        window.minSize = NSSize(width: 720, height: 500)
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
            window.minSize = NSSize(width: 720, height: 500)
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
    @ObservedObject var dictation: NoteDictationService
    @ObservedObject var presentation: NotesPresentationModel
    @ObservedObject private var settings = SettingsStore.shared
    let dockLeft: () -> Void
    let dockRight: () -> Void
    let restoreWorkspace: () -> Void
    let toggleFullScreen: () -> Void

    @State private var searchQuery = ""
    @State private var confirmDelete = false
    @State private var showSpeakerNames = false
    @State private var showAppearance = false
    @State private var speakerOneName = ""
    @State private var speakerTwoName = ""

    private var filteredNotes: [MarkdownNote] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return store.notes }
        return store.notes.filter { note in
            note.displayTitle.lowercased().contains(query)
                || note.content.prefix(20_000).lowercased().contains(query)
        }
    }

    private var pinnedNotes: [MarkdownNote] { filteredNotes.filter(\.isPinned) }
    private var favoriteNotes: [MarkdownNote] { filteredNotes.filter { !$0.isPinned && $0.isFavorite } }
    private var regularNotes: [MarkdownNote] { filteredNotes.filter { !$0.isPinned && !$0.isFavorite } }

    var body: some View {
        ZStack {
            LiquidGlassBackdrop(material: .underWindowBackground, blendingMode: .behindWindow)
            LinearGradient(
                colors: notesThemeColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(0.42)
            .ignoresSafeArea()
            VStack(spacing: 10) {
                windowChrome
                    .liquidGlass(cornerRadius: 17, depth: .floating, accentOpacity: 0.024)
                if presentation.mode.isDocked {
                    quickNoteWorkspace
                        .liquidGlass(cornerRadius: 18, depth: .raised, accentOpacity: 0.014)
                } else if presentation.sidebarVisible && presentation.mode != .fullScreen {
                    HStack(spacing: 10) {
                        sidebar
                            .frame(width: 246)
                            .liquidGlass(cornerRadius: 19, depth: .floating, accentOpacity: 0.020)
                        editor
                            .frame(minWidth: 470, maxWidth: .infinity, maxHeight: .infinity)
                            .liquidGlass(cornerRadius: 19, depth: .raised, accentOpacity: 0.012)
                    }
                } else {
                    editor
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .liquidGlass(cornerRadius: 19, depth: .raised, accentOpacity: 0.012)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .padding(.top, presentation.mode == .fullScreen ? 10 : 7)
        }
        .frame(
            minWidth: presentation.mode.isDocked ? NotesWindowLayout.minimumDockWidth : 720,
            minHeight: 500
        )
        .tint(settings.accentTheme.primary)
        .preferredColorScheme(.dark)
        .alert("Delete this note?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Note", role: .destructive) { store.deleteSelectedNote() }
        } message: {
            Text("This permanently removes the selected local note.")
        }
        .sheet(isPresented: $showSpeakerNames) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Name transcript speakers").limaFont(.title3.bold())
                Text("Names apply to this note and to new dictation segments appended here.")
                    .limaFont(.caption).foregroundStyle(.secondary)
                Form {
                    TextField("Speaker 1", text: $speakerOneName)
                    TextField("Speaker 2", text: $speakerTwoName)
                }
                .formStyle(.grouped)
                HStack {
                    Spacer()
                    Button("Cancel") { showSpeakerNames = false }
                    Button("Apply") {
                        store.renameSpeakers([1: speakerOneName, 2: speakerTwoName])
                        showSpeakerNames = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(22)
            .frame(width: 430)
            .preferredColorScheme(.dark)
        }
        .animation(.interactiveSpring(response: 0.34, dampingFraction: 0.86), value: presentation.sidebarVisible)
        .animation(.interactiveSpring(response: 0.34, dampingFraction: 0.86), value: presentation.mode)
        .animation(.easeInOut(duration: 0.24), value: settings.notesVisualTheme)
    }

    private var windowChrome: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    PrismaticPanelShape(cut: 7)
                        .fill(LinearGradient(
                            colors: [settings.accentTheme.primary, settings.accentTheme.secondary],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                    Image(systemName: presentation.mode.isDocked ? "note.text" : "note.text.badge.plus")
                        .limaFont(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 28, height: 28)
                Text(presentation.mode.isDocked ? "Quick Note" : "Notes")
                    .limaFont(.system(size: 14, weight: .semibold))
            }

            Spacer(minLength: 8)

            NotesChromeButton(symbol: "slider.horizontal.3", label: "Customize Notes") {
                showAppearance.toggle()
            }
            .popover(isPresented: $showAppearance, arrowEdge: .bottom) {
                NotesAppearancePanel(settings: settings)
            }

            if presentation.mode == .workspace {
                NotesChromeButton(
                    symbol: presentation.sidebarVisible ? "sidebar.left" : "rectangle.righthalf.inset.filled",
                    label: presentation.sidebarVisible ? "Hide Notes Sidebar" : "Show Notes Sidebar",
                    action: { presentation.sidebarVisible.toggle() }
                )
            }

            if presentation.mode.isDocked {
                NotesChromeButton(symbol: "macwindow", label: "Return to Workspace", action: restoreWorkspace)
                    .keyboardShortcut("0", modifiers: [.command, .option])
                NotesChromeButton(
                    symbol: presentation.mode == .dockedLeft
                        ? "rectangle.righthalf.inset.filled"
                        : "rectangle.lefthalf.inset.filled",
                    label: presentation.mode == .dockedLeft ? "Move Quick Note Right" : "Move Quick Note Left",
                    action: presentation.mode == .dockedLeft ? dockRight : dockLeft
                )
            } else if presentation.mode != .fullScreen {
                NotesChromeButton(symbol: "rectangle.lefthalf.inset.filled", label: "Dock Quick Note Left", action: dockLeft)
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                NotesChromeButton(symbol: "rectangle.righthalf.inset.filled", label: "Dock Quick Note Right", action: dockRight)
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            }

            NotesChromeButton(
                symbol: presentation.mode == .fullScreen
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right",
                label: presentation.mode == .fullScreen ? "Exit Full Screen" : "Enter Full Screen",
                action: toggleFullScreen
            )
            .keyboardShortcut("f", modifiers: [.command, .control])
        }
        .padding(.leading, presentation.mode == .fullScreen ? 18 : 78)
        .padding(.trailing, 10)
        .frame(height: 44)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search notes", text: $searchQuery)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 9)
                .frame(height: 30)
                .liquidGlass(cornerRadius: 10, depth: .recessed, accentOpacity: 0)

                Button {
                    store.createNote()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("New Note (Command-N)")
                .keyboardShortcut("n", modifiers: .command)

            }
            .padding(10)

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
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 7)
            }

            GlassHairline()
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .limaFont(.caption2)
                    .foregroundStyle(Color.accentColor)
                Text("Local")
                Spacer()
                Text("\(store.notes.count) \(store.notes.count == 1 ? "note" : "notes")")
            }
            .limaFont(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 34)
        }
        .background(Color.clear)
    }

    private var quickNoteWorkspace: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(store.notes) { note in
                        Button {
                            store.selectedNoteID = note.id
                        } label: {
                            if note.id == store.selectedNoteID {
                                Label(note.displayTitle, systemImage: "checkmark")
                            } else {
                                Text(note.displayTitle)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "note.text")
                            .foregroundStyle(Color.accentColor)
                        Text(store.selectedNote?.displayTitle ?? "Choose a note")
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .limaFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.borderlessButton)

                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find", text: $searchQuery)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 8)
                .frame(width: 116, height: 28)
                .background(PrismaticPanelShape(cut: 5).fill(Color.primary.opacity(0.055)))

                NotesChromeButton(symbol: "plus", label: "New Quick Note") { store.createNote() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            .padding(.horizontal, 10)
            .frame(height: 44)

            if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(filteredNotes.prefix(10)) { note in
                            Button {
                                store.selectedNoteID = note.id
                                searchQuery = ""
                            } label: {
                                Text(note.displayTitle)
                                    .limaFont(.caption)
                                    .lineLimit(1)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(PrismaticPanelShape(cut: 4).fill(Color.accentColor.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 7)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            Divider().opacity(0.6)
            editor
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let note = store.selectedNote {
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
                    Circle().fill(Color.accentColor.opacity(0.12))
                    Image(systemName: "note.text.badge.plus")
                        .limaFont(.system(size: 28, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 66, height: 66)
                Text("Start a quick thought").limaFont(.title3.bold())
                Text("Notes save locally as you type.")
                    .limaFont(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Create Note") { store.createNote() }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func editorHeader(_ note: MarkdownNote) -> some View {
        HStack(spacing: 10) {
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
                Button("Name Transcript Speakers…") {
                    speakerOneName = note.speakerNames[1] ?? ""
                    speakerTwoName = note.speakerNames[2] ?? ""
                    showSpeakerNames = true
                }
                Divider()
                Button("Delete Note…", role: .destructive) { confirmDelete = true }
                    .keyboardShortcut(.delete, modifiers: .command)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28)
                    .background(.ultraThinMaterial, in: PrismaticPanelShape(cut: 6))
                    .overlay(PrismaticPanelShape(cut: 6).stroke(Color.white.opacity(0.24), lineWidth: 0.6))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 30)
            .help("More Note Actions")
        }
        .padding(.horizontal, presentation.mode.isDocked ? 12 : 18)
        .frame(minHeight: presentation.mode.isDocked ? 52 : 62)
        .background(Color.clear)
    }

    @ViewBuilder
    private func editorCanvas(_ note: MarkdownNote) -> some View {
        let markdownEditor = InlineMarkdownEditor(
            text: Binding(
                get: { store.selectedNote?.content ?? "" },
                set: store.updateContent
            ),
            compact: presentation.mode.isDocked,
            fontStyle: settings.notesFontStyle,
            fontSize: settings.notesFontSize,
            lineSpacing: settings.notesLineSpacing
        )
        .accessibilityLabel("Inline formatted Markdown editor")

        if presentation.mode == .fullScreen || settings.notesContentWidth != .fluid {
            HStack(spacing: 0) {
                Spacer(minLength: presentation.mode.isDocked ? 0 : 20)
                markdownEditor
                    .frame(maxWidth: settings.notesContentWidth.maximum)
                    .background(noteCanvasColor.opacity(0.42))
                    .liquidGlass(cornerRadius: 12, depth: .recessed, accentOpacity: 0.008)
                Spacer(minLength: presentation.mode.isDocked ? 0 : 20)
            }
            .background(Color.clear)
        } else {
            markdownEditor
                .background(Color(nsColor: .textBackgroundColor).opacity(0.18))
        }
    }

    private func noteToolbar(_ note: MarkdownNote) -> some View {
        VStack(spacing: 0) {
            if let status = activeStatus {
                HStack(spacing: 7) {
                    if dictation.phase == .transcribing || dictation.phase == .requestingPermission {
                        ProgressView().controlSize(.small)
                    } else {
                        Circle()
                            .fill((store.lastError ?? dictation.lastError) == nil ? Color.accentColor : Color.orange)
                            .frame(width: 6, height: 6)
                    }
                    Text(status).lineLimit(1)
                    Spacer()
                    if dictation.recoveryAudioURL != nil, dictation.phase == .idle {
                        Button("Retry") { dictation.retryFailedRecording() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                        if let recoveryURL = dictation.recoveryAudioURL {
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([recoveryURL])
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.mini)
                            .help("Show preserved recording in Finder")
                        }
                    }
                }
                .limaFont(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 7)
            }

            HStack(spacing: 9) {
                HStack(spacing: 1) {
                    Menu {
                        Button("Heading 1") { MarkdownEditorActions.heading(1) }
                        Button("Heading 2") { MarkdownEditorActions.heading(2) }
                        Button("Heading 3") { MarkdownEditorActions.heading(3) }
                        Divider()
                        Button("Quote") { MarkdownEditorActions.insert("> Quote") }
                        Button("Divider") { MarkdownEditorActions.insert("---") }
                        Button("Table") { MarkdownEditorActions.table() }
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
                    MarkdownInsertButton(symbol: "list.bullet", help: "Insert list item") { MarkdownEditorActions.insert("- List item") }
                    MarkdownInsertButton(symbol: "checklist", help: "Insert task") { MarkdownEditorActions.insert("- [ ] Task") }
                    MarkdownInsertButton(symbol: "chevron.left.forwardslash.chevron.right", help: "Insert formatted code block") {
                        MarkdownEditorActions.insert("```\ncode\n```")
                    }
                    MarkdownInsertButton(symbol: "link", help: "Link (Command-K)", action: MarkdownEditorActions.link)
                }
                .padding(3)
                .liquidGlass(cornerRadius: 10, depth: .recessed, accentOpacity: 0)

                Spacer(minLength: 5)

                dictationControl(compact: presentation.mode.isDocked)
            }
            .padding(.horizontal, presentation.mode.isDocked ? 9 : 12)
            .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func dictationControl(compact: Bool) -> some View {
        Button {
            if store.selectedNoteID == nil { store.createNote() }
            dictation.performPrimaryAction(
                destinationNoteID: store.selectedNoteID,
                destinationNoteTitle: store.selectedNote?.displayTitle
            )
        } label: {
            if compact {
                Image(systemName: dictation.phase == .recording ? "stop.fill" : "mic.fill")
                    .frame(width: 30, height: 26)
            } else {
                Label(dictation.actionTitle, systemImage: dictation.phase == .recording ? "stop.circle.fill" : "mic.fill")
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(dictation.phase == .recording ? .red : .accentColor)
        .disabled(
            dictation.phase == .requestingPermission
                || dictation.phase == .transcribing
        )
        .help("Record into this note; Stop finishes any remaining transcription")
    }

    private var activeStatus: String? {
        if let error = store.lastError ?? dictation.lastError { return error }
        if dictation.phase != .idle { return dictation.statusText }
        return nil
    }

    private func noteSelectionButton(_ note: MarkdownNote) -> some View {
        Button {
            store.selectedNoteID = note.id
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

    private func relativeTimestamp(_ date: Date) -> String {
        let elapsed = max(0, Date().timeIntervalSince(date))
        if elapsed < 60 { return "now" }
        if elapsed < 3_600 { return "\(Int(elapsed / 60))m ago" }
        if elapsed < 86_400 { return "\(Int(elapsed / 3_600))h ago" }
        if elapsed < 604_800 { return "\(Int(elapsed / 86_400))d ago" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private var notesThemeColors: [Color] {
        switch settings.notesVisualTheme {
        case .prism: return [settings.accentTheme.primary.opacity(0.26), Color.cyan.opacity(0.08), Color.black.opacity(0.08)]
        case .graphite: return [Color(white: 0.18), Color(white: 0.07), Color.black.opacity(0.28)]
        case .midnight: return [Color(red: 0.05, green: 0.09, blue: 0.20), Color(red: 0.09, green: 0.05, blue: 0.18), .black.opacity(0.32)]
        case .aurora: return [Color.teal.opacity(0.20), Color.indigo.opacity(0.23), Color.purple.opacity(0.12)]
        case .ink: return [Color(red: 0.17, green: 0.13, blue: 0.10), Color(red: 0.08, green: 0.07, blue: 0.07), Color.orange.opacity(0.06)]
        }
    }

    private var noteCanvasColor: Color {
        switch settings.notesVisualTheme {
        case .prism: return Color(red: 0.08, green: 0.09, blue: 0.13)
        case .graphite: return Color(white: 0.08)
        case .midnight: return Color(red: 0.035, green: 0.05, blue: 0.10)
        case .aurora: return Color(red: 0.035, green: 0.08, blue: 0.09)
        case .ink: return Color(red: 0.09, green: 0.075, blue: 0.065)
        }
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
                                .overlay(Circle().stroke(.white.opacity(settings.notesVisualTheme == theme ? 0.9 : 0.18), lineWidth: settings.notesVisualTheme == theme ? 2 : 0.7))
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
        .background(.ultraThinMaterial)
        .preferredColorScheme(.dark)
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
        .buttonStyle(LiquidGlassIconButtonStyle(size: 27))
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
                            .foregroundStyle(Color.accentColor)
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
                Text(relativeTimestamp(note.modifiedAt))
                    .limaFont(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background {
            if selected {
                ZStack {
                    PrismaticPanelShape(cut: 6).fill(.ultraThinMaterial)
                    PrismaticPanelShape(cut: 6).fill(Color.accentColor.opacity(0.09))
                }
            }
        }
        .overlay {
            if selected {
                PrismaticPanelShape(cut: 6)
                    .strokeBorder(Color.white.opacity(0.38), lineWidth: 0.7)
            }
        }
        .shadow(color: selected ? Color.accentColor.opacity(0.10) : .clear, radius: 8, y: 3)
        .contentShape(PrismaticPanelShape(cut: 6))
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
