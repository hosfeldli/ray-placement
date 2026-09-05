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

private enum NotesSection {
    case notes
    case dictation
}

@MainActor
private final class NotesPresentationModel: ObservableObject {
    @Published fileprivate(set) var mode: NotesWindowMode
    @Published var sidebarVisible = true
    @Published var section: NotesSection = .notes

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

    private let presentation: NotesPresentationModel
    private var window: NSWindow?
    private var dictationHUD: DictationHUDController!
    private var workspaceFrame: NSRect?
    private var modeBeforeFullScreen: NotesWindowMode = .workspace
    private var sidebarBeforeFullScreen = true
    private var isApplyingFrame = false

    override init() {
        let store = NotesStore()
        let conversations = DictationConversationStore()
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

    @State private var searchQuery = ""
    @State private var confirmDelete = false
    @State private var confirmDeleteDictation = false
    @State private var pendingDictationDeleteID: UUID?
    @State private var deleteActiveDictation = false
    @State private var showAppearance = false
    @State private var showTags = false
    @State private var showRevisions = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            LinearGradient(
                colors: notesThemeColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(0.42)
            .ignoresSafeArea()
            VStack(spacing: LimaDesign.panelGap) {
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
            .padding(.horizontal, presentation.mode.isDocked ? 6 : LimaDesign.windowPadding)
            .padding(.bottom, presentation.mode.isDocked ? 6 : LimaDesign.windowPadding)
            .padding(.top, presentation.mode == .fullScreen ? 10 : 7)
        }
        .frame(
            minWidth: presentation.mode.isDocked ? NotesWindowLayout.minimumDockWidth : 720,
            minHeight: 500
        )
        .tint(SettingsStore.shared.accentTheme.primary)
        .preferredColorScheme(.dark)
        .alert("Delete this note?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Note", role: .destructive) { store.deleteSelectedNote() }
        } message: {
            Text("This permanently removes the selected local note.")
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
        HStack(spacing: 10) {
            LimaToolbarTitle(
                symbol: presentation.mode.isDocked ? "note.text" : "note.text.badge.plus",
                title: presentation.mode.isDocked ? "Quick Note" : "Notes",
                subtitle: presentation.section == .dictation ? "Separate conversations" : "Local Markdown workspace"
            )
            .frame(maxWidth: presentation.mode.isDocked ? 150 : 270, alignment: .leading)
            .layoutPriority(1)

            Spacer(minLength: 8)

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
        .frame(height: LimaDesign.toolbarHeight)
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
                    Image(systemName: "square.and.pencil")
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .limaButton(prominent: true)
                .controlSize(.small)
                .help("New Note or Template (Command-N)")
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
                    .foregroundStyle(SettingsStore.shared.accentTheme.primary)
                Text("Local")
                Spacer()
                Text("\(store.notes.count) \(store.notes.count == 1 ? "note" : "notes")")
            }
            .limaFont(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: LimaDesign.statusHeight)
        }
        .background(Color.clear)
    }

    private var quickNoteWorkspace: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Menu {
                    ForEach(store.notes) { note in
                        Button { store.selectedNoteID = note.id } label: {
                            if note.id == store.selectedNoteID {
                                Label(note.displayTitle, systemImage: "checkmark")
                            } else {
                                Text(note.displayTitle)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "note.text")
                            .foregroundStyle(SettingsStore.shared.accentTheme.primary)
                        Text(store.selectedNote?.displayTitle ?? "Choose a note")
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .limaFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.borderlessButton)

                NotesChromeButton(symbol: "magnifyingglass", label: "Find a note") {
                    searchQuery = searchQuery.isEmpty ? " " : ""
                }
                NotesChromeButton(symbol: "plus", label: "New Quick Note") { store.createNote() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            .padding(.horizontal, 8)
            .frame(height: 38)

            if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find a note", text: $searchQuery)
                        .textFieldStyle(.plain)
                    Button { searchQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(LimaDesign.controlFill, in: PrismaticPanelShape(cut: 5))
                .overlay(PrismaticPanelShape(cut: 5).stroke(LimaDesign.controlBorder, lineWidth: LimaDesign.borderWidth))
                .padding(.horizontal, 8)

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
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(SettingsStore.shared.accentTheme.primary.opacity(0.10), in: PrismaticPanelShape(cut: 4))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 5)
                }
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }

            Divider().opacity(0.6)
            editor
        }
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
                        .foregroundStyle(SettingsStore.shared.accentTheme.primary)
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
                                    .foregroundStyle(SettingsStore.shared.accentTheme.primary)
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
                                    .background(
                                        conversation.id == conversations.selectedConversationID
                                            ? SettingsStore.shared.accentTheme.primary.opacity(0.22)
                                            : Color.white.opacity(0.035),
                                        in: PrismaticPanelShape(cut: 7)
                                    )
                                    .overlay(
                                        PrismaticPanelShape(cut: 7)
                                            .stroke(
                                                conversation.id == conversations.selectedConversationID
                                                    ? SettingsStore.shared.accentTheme.primary.opacity(0.72)
                                                    : Color.white.opacity(0.08),
                                                lineWidth: conversation.id == conversations.selectedConversationID ? 1.0 : 0.6
                                            )
                                    )
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
                        .background(LimaDesign.editorFill, in: PrismaticPanelShape(cut: 9))
                        .overlay(PrismaticPanelShape(cut: 9).stroke(LimaDesign.controlBorder, lineWidth: LimaDesign.borderWidth))
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
                            .foregroundStyle(SettingsStore.shared.accentTheme.primary)
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
            .background(Color.orange.opacity(0.16), in: PrismaticPanelShape(cut: 6))
            .overlay(PrismaticPanelShape(cut: 6).stroke(Color.orange.opacity(0.42), lineWidth: 0.7))
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
        .background(dictationPrimaryColor.opacity(0.18), in: PrismaticPanelShape(cut: 6))
        .overlay(PrismaticPanelShape(cut: 6).stroke(dictationPrimaryColor.opacity(0.48), lineWidth: 0.7))
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
        default: return SettingsStore.shared.accentTheme.primary
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
                if !note.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(note.tags.prefix(4), id: \.self) { tag in
                            Text("#\(tag)")
                                .limaFont(.system(size: 9, weight: .medium))
                                .foregroundStyle(SettingsStore.shared.accentTheme.primary)
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
                    .foregroundStyle(SettingsStore.shared.accentTheme.primary)
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
                Button("Edit Tags…") { showTags = true }
                Button("Revision History…") { showRevisions = true }
                Divider()
                Button("Delete Note…", role: .destructive) { confirmDelete = true }
                    .keyboardShortcut(.delete, modifiers: .command)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28)
                    .background(.ultraThinMaterial, in: PrismaticPanelShape(cut: 6))
                    .overlay(PrismaticPanelShape(cut: 6).stroke(LimaDesign.controlBorder, lineWidth: LimaDesign.borderWidth))
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
        let markdownEditor = InlineMarkdownEditor(
            text: Binding(
                get: { store.selectedNote?.content ?? "" },
                set: store.updateContent
            ),
            compact: presentation.mode.isDocked,
            fontStyle: settings.notesFontStyle,
            fontSize: settings.notesFontSize,
            lineSpacing: settings.notesLineSpacing,
            theme: settings.notesVisualTheme
        )
        .accessibilityLabel("Inline formatted Markdown editor")

        if presentation.mode == .fullScreen || settings.notesContentWidth != .fluid {
            HStack(spacing: 0) {
                Spacer(minLength: presentation.mode.isDocked ? 0 : 20)
                markdownEditor
                    .frame(maxWidth: settings.notesContentWidth.maximum)
                    .background(
                        LinearGradient(
                            colors: [noteCanvasColor.opacity(0.96), notesThemeColors[0].opacity(0.34), noteCanvasColor.opacity(0.88)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .liquidGlass(cornerRadius: 12, depth: .recessed, accentOpacity: 0.008)
                Spacer(minLength: presentation.mode.isDocked ? 0 : 20)
            }
            .background(Color.clear)
        } else {
            markdownEditor
                .background(LimaDesign.editorFill)
        }
    }

    private func noteToolbar(_ note: MarkdownNote) -> some View {
        VStack(spacing: 0) {
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
                .liquidGlass(cornerRadius: 10, depth: .recessed, accentOpacity: 0)

                Spacer(minLength: 5)

                if !store.referencedNotes().isEmpty || !store.backlinks().isEmpty {
                    Menu {
                        if !store.referencedNotes().isEmpty {
                            Section("References") {
                                ForEach(store.referencedNotes()) { linked in
                                    Button(linked.displayTitle) { store.selectedNoteID = linked.id }
                                }
                            }
                        }
                        if !store.backlinks().isEmpty {
                            Section("Backlinks") {
                                ForEach(store.backlinks()) { linked in
                                    Button(linked.displayTitle) { store.selectedNoteID = linked.id }
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
                        .background(LimaDesign.controlFill, in: PrismaticPanelShape(cut: 5))
                        .overlay(PrismaticPanelShape(cut: 5).stroke(LimaDesign.controlBorder, lineWidth: LimaDesign.borderWidth))
                        .help("Completed tasks")
                }

            }
            .padding(.horizontal, presentation.mode.isDocked ? 9 : 12)
            .padding(.vertical, 8)
        }
        .background(LimaDesign.recessedFill)
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

    private var notesThemeColors: [Color] {
        switch settings.notesVisualTheme {
        case .prism: return [SettingsStore.shared.accentTheme.primary.opacity(0.26), Color.cyan.opacity(0.08), Color.black.opacity(0.08)]
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
        .preferredColorScheme(.dark)
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
                    .foregroundStyle(SettingsStore.shared.accentTheme.primary)
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
        .preferredColorScheme(.dark)
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
                            .foregroundStyle(SettingsStore.shared.accentTheme.primary)
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
        .background {
            if selected {
                ZStack {
                    PrismaticPanelShape(cut: 6).fill(.ultraThinMaterial)
                    PrismaticPanelShape(cut: 6).fill(SettingsStore.shared.accentTheme.primary.opacity(0.09))
                }
            }
        }
        .overlay {
            if selected {
                PrismaticPanelShape(cut: 6)
                    .strokeBorder(Color.white.opacity(0.38), lineWidth: 0.7)
            }
        }
        .shadow(color: selected ? SettingsStore.shared.accentTheme.primary.opacity(0.07) : .clear, radius: 6, y: 2)
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
