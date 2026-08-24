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
    let summarizer: NoteSummaryService
    let formatter: FormatterWorkspaceModel

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
        self.summarizer = NoteSummaryService()
        self.formatter = FormatterWorkspaceModel()
        let savedMode = UserDefaults.standard.string(forKey: Self.windowModeKey)
            .flatMap(NotesWindowMode.init(rawValue:))
        self.presentation = NotesPresentationModel(
            mode: savedMode == .dockedLeft || savedMode == .dockedRight ? savedMode! : .workspace
        )
        super.init()
        self.dictationHUD = DictationHUDController(dictation: dictation) { [weak self] in
            self?.present()
        }
    }

    func present() {
        let window = ensureWindow()
        applyPresentationMode(presentation.mode, to: window, animated: false)
        window.makeKeyAndOrderFront(nil)
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
        store.closeFormatterWorkspace()
        store.selectMostRecentNote()
        let preferredMode: NotesWindowMode = presentation.mode == .dockedLeft ? .dockedLeft : .dockedRight
        let window = ensureWindow()
        applyPresentationMode(preferredMode, to: window, animated: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func presentMostRecentAndToggleDictation() {
        store.closeFormatterWorkspace()
        store.selectMostRecentNote()
        present()
        guard dictation.phase == .idle || dictation.phase == .recording else { return }
        dictation.performPrimaryAction(
            destinationNoteID: store.selectedNoteID,
            destinationNoteTitle: store.selectedNote?.displayTitle
        )
    }

    func presentFormatterWorkspace() {
        store.openFormatterWorkspace()
        restoreWorkspace()
        present()
    }

    func shutdown() {
        dictation.cancel()
        summarizer.cancel()
        formatter.reset()
        store.flush()
    }

    func windowWillClose(_ notification: Notification) {
        summarizer.cancel()
        formatter.reset()
        store.closeFormatterWorkspace()
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
        window.title = "RayPlacement Notes"
        window.setAccessibilityLabel("RayPlacement Notes")
        window.titleVisibility = NSWindow.TitleVisibility.hidden
        window.titlebarAppearsTransparent = true
        window.tabbingMode = NSWindow.TabbingMode.disallowed
        window.isReleasedWhenClosed = false
        window.hasShadow = true
        window.delegate = self
        window.contentView = NSHostingView(rootView: NotesView(
            store: store,
            dictation: dictation,
            summarizer: summarizer,
            formatter: formatter,
            presentation: presentation,
            dockLeft: { [weak self] in self?.dock(.left) },
            dockRight: { [weak self] in self?.dock(.right) },
            restoreWorkspace: { [weak self] in self?.restoreWorkspace() },
            toggleFullScreen: { [weak self] in self?.toggleFullScreen() }
        ))
        return window
    }

    private func dock(_ edge: NotesDockEdge) {
        let window = ensureWindow()
        if presentation.mode == .workspace {
            rememberWorkspaceFrame(window.frame)
        }
        store.closeFormatterWorkspace()
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
    @ObservedObject var summarizer: NoteSummaryService
    @ObservedObject var formatter: FormatterWorkspaceModel
    @ObservedObject var presentation: NotesPresentationModel
    let dockLeft: () -> Void
    let dockRight: () -> Void
    let restoreWorkspace: () -> Void
    let toggleFullScreen: () -> Void

    @State private var searchQuery = ""
    @State private var confirmDelete = false

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
        VStack(spacing: 0) {
            windowChrome
            Divider().opacity(0.7)
            if presentation.mode.isDocked {
                quickNoteWorkspace
            } else if presentation.sidebarVisible && presentation.mode != .fullScreen {
                HSplitView {
                    sidebar.frame(minWidth: 210, idealWidth: 250, maxWidth: 280)
                    editor.frame(minWidth: 470, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                editor.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(
            minWidth: presentation.mode.isDocked ? NotesWindowLayout.minimumDockWidth : 720,
            minHeight: 500
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Delete this note?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Note", role: .destructive) { store.deleteSelectedNote() }
        } message: {
            Text("This permanently removes the selected local note.")
        }
        .sheet(isPresented: Binding(
            get: { summarizer.proposal != nil },
            set: { if !$0 { summarizer.dismissProposal() } }
        )) {
            if let proposal = summarizer.proposal {
                SummaryReviewView(
                    proposal: proposal,
                    insert: {
                        store.insertSummary(proposal.markdown, into: proposal.noteID)
                        summarizer.dismissProposal()
                    },
                    copy: summarizer.copyProposal,
                    close: summarizer.dismissProposal
                )
            }
        }
        .animation(.easeInOut(duration: 0.18), value: presentation.sidebarVisible)
        .animation(.easeInOut(duration: 0.18), value: presentation.mode)
    }

    private var windowChrome: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Color.accentColor, Color.purple.opacity(0.82)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                    Image(systemName: presentation.mode.isDocked ? "note.text" : "note.text.badge.plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 28, height: 28)
                Text(presentation.mode.isDocked ? "Quick Note" : "Notes")
                    .font(.system(size: 14, weight: .semibold))
            }

            Spacer(minLength: 8)

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
        .padding(.trailing, 14)
        .padding(.top, presentation.mode == .fullScreen ? 8 : 13)
        .padding(.bottom, 9)
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.095), Color.purple.opacity(0.035), Color.clear],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
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
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.055)))

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

                NotesChromeButton(symbol: "curlybraces.square", label: "Open Temporary Formatter") {
                    store.openFormatterWorkspace()
                }
            }
            .padding(10)

            Divider().opacity(0.6)

            List(selection: $store.selectedNoteID) {
                if store.formatterWorkspaceOpen && matchesFormatterSearch {
                    formatterRow
                        .tag(NotesStore.formatterWorkspaceID)
                        .listRowBackground(
                            store.isFormatterSelected ? Color.accentColor.opacity(0.14) : Color.clear
                        )
                }

                if !pinnedNotes.isEmpty {
                    Section {
                        ForEach(pinnedNotes) { note in noteRow(note) }
                    } header: {
                        sidebarSectionLabel("Pinned")
                    }
                }

                if !favoriteNotes.isEmpty {
                    Section {
                        ForEach(favoriteNotes) { note in noteRow(note) }
                    } header: {
                        sidebarSectionLabel("Favorites")
                    }
                }

                if !regularNotes.isEmpty {
                    Section {
                        ForEach(regularNotes) { note in noteRow(note) }
                    } header: {
                        sidebarSectionLabel(searchQuery.isEmpty ? "Recent" : "Results")
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider().opacity(0.6)
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                Text("Local")
                Spacer()
                Text("\(store.notes.count) \(store.notes.count == 1 ? "note" : "notes")")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 34)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.56))
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
                            .font(.caption2)
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
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.055)))

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
                                    .font(.caption)
                                    .lineLimit(1)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
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
        if store.isFormatterSelected {
            FormatterWorkspaceView(model: formatter)
        } else if let note = store.selectedNote {
            VStack(spacing: 0) {
                editorHeader(note)
                Divider().opacity(0.55)
                editorCanvas(note)
                Divider().opacity(0.55)
                noteToolbar(note)
            }
        } else {
            VStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.12))
                    Image(systemName: "note.text.badge.plus")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 66, height: 66)
                Text("Start a quick thought").font(.title3.bold())
                Text("Notes save locally as you type.")
                    .font(.subheadline)
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
                .font(.system(size: presentation.mode.isDocked ? 17 : 21, weight: .semibold))

                HStack(spacing: 5) {
                    Text("\(wordCount(note.content)) words")
                    if !presentation.mode.isDocked {
                        Text("·")
                        Text("edited \(relativeTimestamp(note.modifiedAt))")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
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
                Divider()
                Button("Delete Note…", role: .destructive) { confirmDelete = true }
                    .keyboardShortcut(.delete, modifiers: .command)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 30)
            .help("More Note Actions")
        }
        .padding(.horizontal, presentation.mode.isDocked ? 12 : 18)
        .frame(minHeight: presentation.mode.isDocked ? 52 : 62)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.28))
    }

    @ViewBuilder
    private func editorCanvas(_ note: MarkdownNote) -> some View {
        let markdownEditor = InlineMarkdownEditor(
            text: Binding(
                get: { store.selectedNote?.content ?? "" },
                set: store.updateContent
            ),
            compact: presentation.mode.isDocked
        )
        .accessibilityLabel("Inline formatted Markdown editor")

        if presentation.mode == .fullScreen {
            HStack(spacing: 0) {
                Spacer(minLength: 30)
                markdownEditor
                    .frame(maxWidth: 920)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.42))
                Spacer(minLength: 30)
            }
            .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
        } else {
            markdownEditor
                .background(Color(nsColor: .textBackgroundColor).opacity(0.25))
        }
    }

    private func noteToolbar(_ note: MarkdownNote) -> some View {
        VStack(spacing: 0) {
            if let status = activeStatus {
                HStack(spacing: 7) {
                    if summarizer.isSummarizing || dictation.phase == .transcribing || dictation.phase == .requestingPermission {
                        ProgressView().controlSize(.small)
                    } else {
                        Circle()
                            .fill((store.lastError ?? dictation.lastError ?? summarizer.lastError) == nil ? Color.accentColor : Color.orange)
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
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 7)
            }

            HStack(spacing: 9) {
                HStack(spacing: 1) {
                    MarkdownInsertButton(symbol: "bold", help: "Bold (Command-B)") { store.appendMarkdown("**bold text**") }
                    MarkdownInsertButton(symbol: "italic", help: "Italic (Command-I)") { store.appendMarkdown("*italic text*") }
                    MarkdownInsertButton(symbol: "list.bullet", help: "Insert list item") { store.appendMarkdown("- List item") }
                    MarkdownInsertButton(symbol: "checklist", help: "Insert task") { store.appendMarkdown("- [ ] Task") }
                    MarkdownInsertButton(symbol: "chevron.left.forwardslash.chevron.right", help: "Insert code block") {
                        store.appendMarkdown("```\ncode\n```")
                    }
                    MarkdownInsertButton(symbol: "link", help: "Link (Command-K)") { store.appendMarkdown("[link title](https://example.com)") }
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.055)))

                Spacer(minLength: 5)

                summaryControl(note, compact: presentation.mode.isDocked)
                dictationControl(compact: presentation.mode.isDocked)
            }
            .padding(.horizontal, presentation.mode.isDocked ? 9 : 12)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.48))
    }

    @ViewBuilder
    private func summaryControl(_ note: MarkdownNote, compact: Bool) -> some View {
        if summarizer.isSummarizing {
            Button(action: summarizer.cancel) {
                if compact {
                    Image(systemName: "xmark.circle.fill").frame(width: 28, height: 26)
                } else {
                    Label("Cancel Summary", systemImage: "xmark.circle.fill")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else {
            Button {
                summarizer.summarize(note)
            } label: {
                if compact {
                    Image(systemName: "sparkles").frame(width: 28, height: 26)
                } else {
                    Label("Summarize", systemImage: "sparkles")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(dictation.phase != .idle || note.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Summarize this note locally with the selected Qwen model")
        }
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
                || summarizer.isSummarizing
        )
        .help("Record into this note; Stop finishes any remaining transcription")
    }

    private var activeStatus: String? {
        if let error = store.lastError ?? dictation.lastError ?? summarizer.lastError { return error }
        if summarizer.isSummarizing { return summarizer.progressText ?? "Summarizing locally with Qwen…" }
        if dictation.phase != .idle { return dictation.statusText }
        return nil
    }

    private var matchesFormatterSearch: Bool {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return query.isEmpty || "formatter edi json xml temporary".contains(query)
    }

    private var formatterRow: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.13))
                Image(systemName: "curlybraces.square.fill").foregroundStyle(.orange)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Formatter Workspace").font(.subheadline.weight(.semibold))
                Text("EDI · JSON · XML").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text("TEMP")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.orange.opacity(0.12)))
        }
        .padding(.vertical, 5)
        .accessibilityLabel("Formatter Workspace, temporary EDI JSON and XML note")
    }

    private func noteRow(_ note: MarkdownNote) -> some View {
        NoteListRow(note: note, selected: store.selectedNoteID == note.id)
            .tag(note.id)
            .listRowBackground(
                store.selectedNoteID == note.id ? Color.accentColor.opacity(0.13) : Color.clear
            )
            .accessibilityLabel("\(note.displayTitle), \(note.preview)")
    }

    private func sidebarSectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .bold))
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
}

private struct NotesChromeButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct NoteListRow: View {
    let note: MarkdownNote
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(selected ? Color.accentColor : Color.clear)
                .frame(width: 3, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(note.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if note.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                    }
                    if note.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Color.yellow)
                            .accessibilityHidden(true)
                    }
                }
                Text(note.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(relativeTimestamp(note.modifiedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 5)
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
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 25, height: 24)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct SummaryReviewView: View {
    let proposal: NoteSummaryProposal
    let insert: () -> Void
    let copy: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LinearGradient(
                            colors: [Color.accentColor, Color.purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                    Image(systemName: "sparkles")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Local Summary").font(.title3.bold())
                    Text(proposal.noteTitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("QWEN · LOCAL")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(0.1)))
                NotesChromeButton(symbol: "xmark", label: "Close Summary", action: close)
            }
            .padding(16)
            .background(Color.accentColor.opacity(0.04))
            Divider()
            ScrollView {
                renderedSummary
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(24)
            }
            .textSelection(.enabled)
            Divider()
            HStack(spacing: 9) {
                Image(systemName: "lock.fill")
                Text("Generated on this Mac · review before inserting")
                Spacer()
                Button("Copy Markdown", action: copy)
                Button("Insert at Top", action: insert)
                    .buttonStyle(.borderedProminent)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(14)
        }
        .frame(width: 680, height: 520)
    }

    private var renderedSummary: Text {
        if let attributed = try? AttributedString(
            markdown: proposal.markdown,
            options: .init(interpretedSyntax: .full)
        ) {
            return Text(attributed)
        }
        return Text(proposal.markdown)
    }
}
