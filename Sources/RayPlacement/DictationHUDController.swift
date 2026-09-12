import AppKit
import Combine
import SwiftUI

@MainActor
private final class ActivityHUDState: ObservableObject {
    /// Presentation state is interaction state, not visibility state. Whether
    /// the recording pill exists is derived exclusively from dictation.phase.
    @Published var expandedMusic = false
    /// Set only while the preferred player width cannot clear the launcher.
    /// This keeps the visual state synchronized with the collision fallback.
    @Published var collisionMini = false
    private var collapseTask: Task<Void, Never>?

    func scheduleCollapse(after timeout: TimeInterval) {
        collapseTask?.cancel()
        collapseTask = nil
        guard expandedMusic, timeout > 0 else { return }
        collapseTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(timeout))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.expandedMusic = false
            self.collapseTask = nil
        }
    }

    func cancelCollapse() {
        collapseTask?.cancel()
        collapseTask = nil
    }

    deinit {
        collapseTask?.cancel()
    }
}

@MainActor
final class ActivityHUDController {
    private let panel: ActivityHUDPanel
    private let hudState = ActivityHUDState()
    private let music = MusicNowPlayingService()
    private let focus = ShelfFocusCoordinator()
    private let settings = SettingsStore.shared
    private var stateObserver: AnyCancellable?
    private var settingsObserver: AnyCancellable?
    private var expansionObserver: AnyCancellable?
    private var collisionObserver: AnyCancellable?

    init(
        dictation: NoteDictationService,
        conversations: DictationConversationStore,
        openConversation: @escaping (UUID) -> Void
    ) {
        panel = ActivityHUDPanel(contentRect: NSRect(x: 0, y: 0, width: 250, height: 56))
        panel.onMiddleClick = { [weak self] in
            self?.music.perform(.playPause)
            self?.hudState.scheduleCollapse(after: self?.settings.musicExpandedTimeout ?? 0)
            self?.focus.restoreSoon()
        }
        panel.onVolumeScroll = { [weak self] delta in
            self?.music.adjustOutputVolume(by: delta)
            self?.hudState.scheduleCollapse(after: self?.settings.musicExpandedTimeout ?? 0)
        }
        panel.contentView = ShelfHostingView(rootView: LimaTypographyRoot(content: ActivityHUDView(
            dictation: dictation,
            conversations: conversations,
            music: music,
            focus: focus,
            hudState: hudState,
            settings: settings,
            openDictation: { [weak self] in
                guard let id = conversations.currentConversationID else { return }
                openConversation(id)
                self?.focus.restoreSoon()
            }
        )))

        stateObserver = Publishers.CombineLatest3(
            dictation.$phase,
            music.$nowPlaying,
            settings.$musicShowWhenPaused
        )
        .sink { [weak self] _, _, _ in self?.updateLayout(dictation: dictation) }
        settingsObserver = settings.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.updateLayout(dictation: dictation) }
        }
        expansionObserver = hudState.$expandedMusic.sink { [weak self] _ in
            Task { @MainActor in self?.updateLayout(dictation: dictation) }
        }
        collisionObserver = hudState.$collisionMini.sink { [weak self] _ in
            Task { @MainActor in self?.updateLayout(dictation: dictation) }
        }
    }

    private func updateLayout(dictation: NoteDictationService) {
        let dictationVisible = shouldShowRecordingHUD(for: dictation.phase)
        let musicVisible = shouldShowMusicHUD(music.nowPlaying)
        guard dictationVisible || musicVisible else {
            panel.orderOut(nil)
            return
        }

        let requestedMusicWidth = requestedMusicPresentation(dictationVisible: dictationVisible).hudWidth
        let preferredWidth = dictationVisible && musicVisible
            ? 210 + 8 + requestedMusicWidth
            : (dictationVisible ? 210 : requestedMusicWidth)
        let miniMusicWidth = MusicHUDPresentation.mini.hudWidth
        let miniWidth = dictationVisible && musicVisible
            ? 210 + 8 + miniMusicWidth
            : (dictationVisible ? 210 : miniMusicWidth)

        if !hudState.collisionMini,
           miniWidth < preferredWidth,
           !canPlace(width: preferredWidth),
           canPlace(width: miniWidth) {
            hudState.collisionMini = true
            show(width: miniWidth)
            return
        }
        if hudState.collisionMini, canPlace(width: preferredWidth) {
            hudState.collisionMini = false
            show(width: preferredWidth)
            return
        }
        show(width: hudState.collisionMini ? miniWidth : preferredWidth)
    }

    /// The recording pill is intentionally phase-authoritative. Stopping and
    /// transcription are not recording states, so the pill disappears before
    /// the asynchronous transcription work completes.
    private func shouldShowRecordingHUD(for phase: NoteDictationService.Phase) -> Bool {
        phase == .recording || phase == .paused
    }

    private func shouldShowMusicHUD(_ snapshot: MediaNowPlayingSnapshot?) -> Bool {
        guard let snapshot else { return false }
        return snapshot.isPlaying || settings.musicShowWhenPaused
    }

    private func requestedMusicPresentation(dictationVisible: Bool) -> MusicHUDPresentation {
        if hudState.expandedMusic && settings.musicExpandOnClick { return .expanded }
        if dictationVisible { return .mini }
        return settings.musicHUDPresentation
    }

    private func effectiveMusicPresentation(dictationVisible: Bool) -> MusicHUDPresentation {
        if hudState.collisionMini { return .mini }
        return requestedMusicPresentation(dictationVisible: dictationVisible)
    }

    private func show(width: CGFloat) {
        guard let screen = preferredScreen(),
              let visibleFrame = Optional(screen.visibleFrame) else {
            panel.setContentSize(NSSize(width: width, height: 56))
            panel.orderFrontRegardless()
            return
        }

        let clampedWidth = min(width, max(1, visibleFrame.width - 16))
        guard let origin = nonOverlappingOrigin(for: clampedWidth, visibleFrame: visibleFrame) else {
            // There is no visible non-overlapping frame on this display. Hide
            // explicitly rather than retaining a stale frame that may now
            // overlap the launcher. A later layout pass retries placement.
            panel.orderOut(nil)
            return
        }
        panel.setContentSize(NSSize(width: clampedWidth, height: 56))
        panel.setFrameOrigin(origin)
        // The shelf is informational and must not activate Lima or steal the
        // key window while its metadata is refreshed.
        panel.orderFrontRegardless()
    }

    private func canPlace(width: CGFloat) -> Bool {
        guard let screen = preferredScreen(),
              let visibleFrame = Optional(screen.visibleFrame) else { return true }
        let clampedWidth = min(width, max(1, visibleFrame.width - 16))
        return nonOverlappingOrigin(for: clampedWidth, visibleFrame: visibleFrame) != nil
    }

    private func preferredScreen() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        if let pointerScreen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) {
            return pointerScreen
        }
        if let launcherScreen = NSApp.windows
            .first(where: { $0 is LauncherPanel && $0.isVisible })?.screen {
            return launcherScreen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func blockers(in visibleFrame: NSRect) -> [NSWindow] {
        NSApp.windows.filter { window in
            window !== panel
                && window.isVisible
                && window is LauncherPanel
                && window.frame.intersects(visibleFrame)
        }
    }

    /// Prefer the dock position, then horizontal/vertical displacement, and
    /// finally scan the visible frame for a valid placement. Every candidate
    /// is checked against every launcher blocker.
    private func nonOverlappingOrigin(for width: CGFloat, visibleFrame: NSRect) -> NSPoint? {
        let height: CGFloat = 56
        guard width <= visibleFrame.width - 16,
              height <= visibleFrame.height - 16 else { return nil }
        let preferredX: CGFloat
        switch settings.hudDockPosition {
        case .bottomCenter: preferredX = visibleFrame.midX - width / 2
        case .bottomLeft: preferredX = visibleFrame.minX + 18
        case .bottomRight: preferredX = visibleFrame.maxX - width - 18
        }
        let safeX = max(visibleFrame.minX + 8, min(preferredX, visibleFrame.maxX - width - 8))
        let desired = NSRect(x: safeX, y: visibleFrame.minY + 18, width: width, height: height)
        let blockers = blockers(in: visibleFrame)

        func fits(_ origin: NSPoint) -> Bool {
            let frame = NSRect(origin: origin, size: desired.size)
            return frame.minX >= visibleFrame.minX + 8
                && frame.maxX <= visibleFrame.maxX - 8
                && frame.minY >= visibleFrame.minY + 8
                && frame.maxY <= visibleFrame.maxY - 8
                && !blockers.contains(where: { frame.intersects($0.frame) })
        }

        if blockers.contains(where: { desired.intersects($0.frame) }) {
            let horizontalCandidates = blockers.flatMap { blocker in
                [
                    NSPoint(x: blocker.frame.minX - width - 10, y: desired.minY),
                    NSPoint(x: blocker.frame.maxX + 10, y: desired.minY)
                ]
            }
            if let candidate = horizontalCandidates.first(where: fits) { return candidate }

            let verticalCandidates = blockers.flatMap { blocker in
                [
                    NSPoint(x: desired.minX, y: blocker.frame.maxY + 10),
                    NSPoint(x: desired.minX, y: blocker.frame.minY - height - 10)
                ]
            }
            if let candidate = verticalCandidates.first(where: fits) { return candidate }
        }
        if fits(desired.origin) { return desired.origin }

        // A launcher can be wider than either side candidate while still
        // leaving a small visible pocket. Search that pocket rather than
        // returning an overlapping bottom frame.
        let maxX = visibleFrame.maxX - width - 8
        let maxY = visibleFrame.maxY - height - 8
        var y = visibleFrame.minY + 8
        while y <= maxY {
            var x = visibleFrame.minX + 8
            while x <= maxX {
                if fits(NSPoint(x: x, y: y)) { return NSPoint(x: x, y: y) }
                x += 16
            }
            y += 16
        }
        return nil
    }

}

/// Compatibility name retained for existing Notes-window callers while the
/// implementation is now an activity shelf for both music and dictation.
typealias DictationHUDController = ActivityHUDController

private final class ShelfHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class ActivityHUDPanel: NSPanel {
    var onMiddleClick: (() -> Void)?
    var onVolumeScroll: ((Double) -> Void)?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask = [.borderless],
        backing: NSWindow.BackingStoreType = .buffered,
        defer flag: Bool = false
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        becomesKeyOnlyIfNeeded = false
        level = .statusBar
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle, .canJoinAllApplications]
        setAccessibilityLabel("Lima activity shelf")
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .otherMouseDown && event.buttonNumber == 2 {
            onMiddleClick?()
            return
        }
        if event.type == .scrollWheel,
           event.locationInWindow.x >= frame.width - 112 {
            let delta = event.scrollingDeltaY == 0 ? event.scrollingDeltaX : event.scrollingDeltaY
            if delta != 0 {
                onVolumeScroll?(delta)
                return
            }
        }
        super.sendEvent(event)
    }
}

private struct MusicSignalRibbon: View {
    let progress: Double
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            let clampedProgress = min(1, max(0, progress))
            let barWidth = max(1, (proxy.size.width - 34) / 24)
            HStack(alignment: .center, spacing: 1.4) {
                ForEach(0..<24, id: \.self) { index in
                    let filled = Double(index) / 24 < clampedProgress
                    Capsule()
                        .fill(filled ? accent.opacity(0.92) : LimaColors.tertiaryText.opacity(0.35))
                        .frame(width: barWidth, height: 5)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 15)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private extension MusicHUDPresentation {
    var hudWidth: CGFloat {
        switch self {
        case .mini: return 250
        case .compact: return 360
        case .expanded: return 520
        }
    }
}

private struct ActivityHUDView: View {
    @ObservedObject var dictation: NoteDictationService
    @ObservedObject var conversations: DictationConversationStore
    @ObservedObject var music: MusicNowPlayingService
    let focus: ShelfFocusCoordinator
    @ObservedObject var hudState: ActivityHUDState
    @ObservedObject var settings: SettingsStore
    let openDictation: () -> Void
    @State private var volumePopoverVisible = false

    var body: some View {
        let dictationVisible = dictation.phase == .recording || dictation.phase == .paused
        let musicVisible = music.nowPlaying.map { $0.isPlaying || settings.musicShowWhenPaused } ?? false
        let presentation = effectivePresentation(dictationVisible: dictationVisible)

        return HStack(spacing: 8) {
            if dictationVisible { dictationPill.frame(width: 210) }
            if musicVisible, let track = music.nowPlaying {
                musicPill(track, presentation: presentation)
                    .frame(width: presentation.hudWidth)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .limaAnimation(LimaDesign.spring(0.24), value: dictation.phase)
        .limaAnimation(LimaDesign.spring(0.24), value: music.nowPlaying)
        .onDisappear { hudState.cancelCollapse() }
    }

    private func effectivePresentation(dictationVisible: Bool) -> MusicHUDPresentation {
        if hudState.collisionMini { return .mini }
        if hudState.expandedMusic && settings.musicExpandOnClick { return .expanded }
        if dictationVisible { return .mini }
        return settings.musicHUDPresentation
    }

    private var dictationPill: some View {
        HStack(spacing: 8) {
            Button(action: openDictation) {
                HStack(spacing: 8) {
                    activityIndicator.frame(width: 30, height: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(primaryText)
                            .limaFont(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                        Text(secondaryText)
                            .limaFont(.system(size: 9.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(DictationOpenButtonStyle())
            .help("Open this dictation conversation in Lima Notes")
            .accessibilityLabel("Open current dictation conversation in Lima Notes")

            Button {
                // Notes and the HUD both call the same service action. The
                // phase changes to stopping immediately, which removes this
                // pill without any HUD-specific dismissal flag.
                dictation.performPrimaryAction()
                focus.restoreSoon()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 24, height: 24)
                    .foregroundStyle(LimaColors.danger)
                    .background(LimaColors.dangerSoft, in: RoundedRectangle(cornerRadius: LimaRadius.compactControl, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: LimaRadius.compactControl, style: .continuous)
                            .strokeBorder(LimaColors.danger.opacity(0.26), lineWidth: LimaDesign.borderWidth)
                    }
            }
            .buttonStyle(.plain)
            .help("Stop recording and finish transcription")
            .accessibilityLabel("Stop dictation")
        }
        .padding(.horizontal, 8)
        .frame(height: 56)
        .limaNativeSurface(fill: LimaColors.raisedSurface, radius: LimaRadius.searchField, border: LimaColors.danger.opacity(0.30), shadow: true)
        .overlay(alignment: .bottom) {
            AudioAccentRail(level: dictation.audioLevel, accent: .red, active: dictation.phase == .recording)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
    }

    private struct DictationOpenButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .padding(.vertical, 3)
                .background(configuration.isPressed ? LimaColors.hoverFill : .clear, in: RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous))
                .opacity(configuration.isPressed ? 0.82 : 1)
        }
    }

    @ViewBuilder
    private func musicPill(_ track: MediaNowPlayingSnapshot, presentation: MusicHUDPresentation) -> some View {
        switch presentation {
        case .mini: miniMusicPill(track)
        case .compact: compactMusicPill(track)
        case .expanded: expandedMusicPill(track)
        }
    }

    private func miniMusicPill(_ track: MediaNowPlayingSnapshot) -> some View {
        HStack(spacing: 7) {
            if settings.musicShowArtwork {
                artworkButton(for: track, size: 38)
            }
            Button { toggleExpandedOrOpenSource() } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).limaFont(.system(size: 11.5, weight: .semibold, design: .rounded)).lineLimit(1)
                    Text(track.artist.isEmpty ? track.source.title : track.artist)
                        .limaFont(.system(size: 8.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help(settings.musicExpandOnClick ? "Expand player" : "Open \(track.source.title)")
            if settings.musicShowPlaybackControls { transportControls(track, compact: true) }
        }
        .padding(.horizontal, 8)
        .frame(height: 56)
        .limaNativeSurface(fill: LimaColors.raisedSurface, radius: LimaRadius.searchField, border: track.source.accent.opacity(0.26), shadow: true)
        .overlay(alignment: .bottom) {
            if settings.musicShowProgress {
                MusicSignalRibbon(progress: track.duration > 0 ? track.position / track.duration : 0, accent: track.source.accent)
                    .padding(.horizontal, 8)
                    .frame(height: 6)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(track.source.title), \(track.isPlaying ? "playing" : "paused"): \(track.title) by \(track.artist)")
    }

    private func compactMusicPill(_ track: MediaNowPlayingSnapshot) -> some View {
        HStack(spacing: 8) {
            if settings.musicShowArtwork { artworkButton(for: track, size: 40) }
            Button { toggleExpandedOrOpenSource() } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).limaFont(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
                    Text([track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · "))
                        .limaFont(.system(size: 8.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if settings.musicShowProgress {
                        HStack(spacing: 4) {
                            Text(timeLabel(track.position)).limaFont(.system(size: 7.5, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                            MusicSignalRibbon(progress: track.duration > 0 ? track.position / track.duration : 0, accent: track.source.accent)
                            Text(timeLabel(track.duration)).limaFont(.system(size: 7.5, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            if settings.musicShowPlaybackControls { transportControls(track, compact: false) }
            volumeButton
        }
        .padding(.horizontal, 8)
        .frame(height: 56)
        .limaNativeSurface(fill: LimaColors.raisedSurface, radius: LimaRadius.searchField, border: track.source.accent.opacity(0.26), shadow: true)
        .overlay(alignment: .bottom) {
            AudioAccentRail(level: track.isPlaying ? music.outputAudioLevel : 0, accent: track.source.accent, active: track.isPlaying)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(track.source.title), \(track.isPlaying ? "playing" : "paused"): \(track.title) by \(track.artist)")
    }

    private func expandedMusicPill(_ track: MediaNowPlayingSnapshot) -> some View {
        HStack(spacing: 9) {
            artworkButton(for: track, size: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).limaFont(.system(size: 12.5, weight: .bold, design: .rounded)).lineLimit(1)
                Text(track.artist).limaFont(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(.secondary).lineLimit(1)
                Text(track.album.isEmpty ? track.source.title : track.album)
                    .limaFont(.system(size: 8, weight: .medium, design: .rounded)).foregroundStyle(.tertiary).lineLimit(1)
                if settings.musicShowProgress {
                    HStack(spacing: 4) {
                        Text(timeLabel(track.position)).limaFont(.system(size: 7.5, design: .monospaced)).foregroundStyle(.secondary)
                        MusicSignalRibbon(progress: track.duration > 0 ? track.position / track.duration : 0, accent: track.source.accent)
                        Text(timeLabel(track.duration)).limaFont(.system(size: 7.5, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if settings.musicShowPlaybackControls { transportControls(track, compact: false) }
            VStack(spacing: 3) {
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                Slider(value: Binding(get: { music.outputVolume }, set: {
                    music.setOutputVolume($0)
                    scheduleCollapse()
                }), in: 0...1)
                    .controlSize(.mini)
                    .frame(width: 62)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 56)
        .limaNativeSurface(fill: LimaColors.raisedSurface, radius: LimaRadius.searchField, border: track.source.accent.opacity(0.30), shadow: true)
        .onAppear { hudState.scheduleCollapse(after: settings.musicExpandedTimeout) }
    }

    private var volumeButton: some View {
        Button {
            volumePopoverVisible.toggle()
            scheduleCollapse()
        } label: {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $volumePopoverVisible, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Output volume").font(.caption.weight(.semibold))
                Slider(value: Binding(get: { music.outputVolume }, set: {
                    music.setOutputVolume($0)
                    scheduleCollapse()
                }), in: 0...1)
                    .frame(width: 150)
            }
            .padding(12)
        }
        .help("Adjust output volume")
        .accessibilityLabel("Output volume")
    }

    private func artworkButton(for track: MediaNowPlayingSnapshot, size: CGFloat) -> some View {
        Button {
            music.openSource()
            scheduleCollapse()
            focus.restoreSoon()
        } label: {
            ZStack(alignment: .bottomTrailing) {
                musicArtwork(for: track, accent: track.source.accent)
                Image(systemName: track.source.symbol)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(LimaColors.primaryText)
                    .padding(4)
                    .background(LimaColors.recessedSurface.opacity(0.92), in: Circle())
                    .padding(2)
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Open \(track.source.title)")
        .accessibilityLabel("Open \(track.source.title): \(track.title)")
    }

    private func transportControls(_ track: MediaNowPlayingSnapshot, compact: Bool) -> some View {
        HStack(spacing: compact ? 0 : 1) {
            mediaButton("backward.fill", label: "Previous track") { runMediaAction(.previous) }
            Button { runMediaAction(.playPause) } label: {
                Image(systemName: track.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: compact ? 8 : 9, weight: .bold))
                    .frame(width: compact ? 24 : 27, height: compact ? 24 : 25)
                    .foregroundStyle(LimaColors.primaryText)
                    .background(track.source.accent, in: Circle())
            }
            .buttonStyle(.plain)
            mediaButton("forward.fill", label: "Next track") { runMediaAction(.next) }
        }
        .opacity(music.isPerformingTransport ? 0.55 : 1)
        .disabled(music.isPerformingTransport)
    }

    private func mediaButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 8.5, weight: .bold)).frame(width: 23, height: 24)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func toggleExpandedOrOpenSource() {
        guard settings.musicExpandOnClick else {
            music.openSource()
            focus.restoreSoon()
            return
        }
        hudState.expandedMusic = true
        hudState.scheduleCollapse(after: settings.musicExpandedTimeout)
    }

    private func scheduleCollapse() {
        hudState.scheduleCollapse(after: settings.musicExpandedTimeout)
    }

    private func runMediaAction(_ action: MusicNowPlayingService.TransportAction) {
        music.perform(action)
        focus.restoreSoon()
        if hudState.expandedMusic { scheduleCollapse() }
    }

    @ViewBuilder
    private func musicArtwork(for track: MediaNowPlayingSnapshot, accent: Color) -> some View {
        if settings.musicShowArtwork, let artwork = music.artwork {
            Image(nsImage: artwork).resizable().scaledToFill()
        } else {
            ZStack {
                LinearGradient(colors: [accent.opacity(0.34), settings.accentTheme.primary.opacity(0.16)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: track.source.symbol).limaFont(.system(size: 13, weight: .bold)).foregroundStyle(accent)
            }
        }
    }

    private func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        return "\(Int(seconds) / 60):\(String(format: "%02d", Int(seconds) % 60))"
    }

    @ViewBuilder
    private var activityIndicator: some View {
        switch dictation.phase {
        case .recording: SpeechLevelView(level: dictation.audioLevel)
        case .paused: Image(systemName: "pause.fill")
        default: EmptyView()
        }
    }

    private var primaryText: String {
        dictation.phase == .paused ? "Recording paused" : "Recording"
    }

    private var secondaryText: String {
        dictation.phase == .paused
            ? Self.clock(dictation.recordingElapsed)
            : "\(Self.clock(dictation.recordingElapsed)) · \(dictation.inputSignalText)"
    }

    private var accessibilityText: String {
        "\(primaryText) · \(Self.clock(dictation.recordingElapsed)) elapsed"
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

@MainActor
private final class ShelfFocusCoordinator {
    private weak var previousApplication: NSRunningApplication?
    private var observer: NSObjectProtocol?

    init() {
        remember(NSWorkspace.shared.frontmostApplication)
        observer = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in self?.remember(app) }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func remember(_ application: NSRunningApplication?) {
        guard let application,
              application.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        previousApplication = application
    }

    func restoreSoon() {
        let application = previousApplication
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            application?.activate(options: [.activateIgnoringOtherApps])
        }
    }
}

private struct AudioAccentRail: View {
    let level: Double?
    let accent: Color
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !active || reduceMotion)) { context in
            GeometryReader { geometry in
                let time = context.date.timeIntervalSinceReferenceDate
                let pulse = level ?? (0.52 + sin(time * 3.2) * 0.18)
                let amount = min(1, max(0.08, pulse))
                let width = max(28, geometry.size.width * (0.12 + amount * 0.38))
                let travel = max(0, geometry.size.width - width - 12)
                // Microphone energy changes the rail's span and intensity; it
                // stays anchored instead of pretending activity by sweeping.
                let position = level == nil
                    ? travel * (0.5 + sin(time * 1.25) * 0.5)
                    : travel * 0.5
                Capsule()
                    .fill(accent.opacity(0.72 + amount * 0.28))
                    .frame(width: width, height: 2)
                    .offset(x: 6 + position)
                    .opacity(0.42 + amount * 0.58)
                    .limaAnimation(.linear(duration: 0.08), value: amount)
            }
        }
        .frame(height: 3)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct SpeechLevelView: View {
    let level: Double
    private let multipliers: [Double] = [0.58, 1.0, 0.72]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(Array(multipliers.enumerated()), id: \.offset) { _, multiplier in
                Capsule()
                    .fill(LimaColors.danger)
                    .frame(width: 3, height: 4 + 15 * max(0.08, level) * multiplier)
            }
        }
        .frame(width: 28, height: 24)
        .background(LimaColors.dangerSoft, in: RoundedRectangle(cornerRadius: LimaRadius.small, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LimaRadius.small, style: .continuous)
                .strokeBorder(LimaColors.danger.opacity(0.24), lineWidth: LimaDesign.borderWidth)
        }
        .limaAnimation(.linear(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }
}
