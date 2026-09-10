import AppKit
import Combine
import SwiftUI

@MainActor
private final class DictationHUDState: ObservableObject {
    @Published var dismissedConversationID: UUID?
    @Published var dismissedSessionGeneration: UInt64?
}

@MainActor
final class DictationHUDController {
    private let panel: DictationHUDPanel
    private let shelfState = DictationHUDState()
    private let music = MusicNowPlayingService()
    private let focus = ShelfFocusCoordinator()
    private let conversations: DictationConversationStore
    private var stateObserver: AnyCancellable?
    private var dismissedConversationID: UUID?
    private var dismissedSessionGeneration: UInt64?

    init(
        dictation: NoteDictationService,
        conversations: DictationConversationStore,
        openConversation: @escaping (UUID) -> Void
    ) {
        self.conversations = conversations
        panel = DictationHUDPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 56))
        panel.contentView = ShelfHostingView(rootView: LimaTypographyRoot(content: TopShelfView(
            dictation: dictation,
            conversations: conversations,
            music: music,
            focus: focus,
            hudState: shelfState,
            openDictation: { [weak self] in
                guard let self, let id = self.conversations.currentConversationID else { return }
                let generation = self.conversations.currentSessionGeneration
                self.dismissedConversationID = id
                self.dismissedSessionGeneration = generation
                self.shelfState.dismissedConversationID = id
                self.shelfState.dismissedSessionGeneration = generation
                self.hideDictationIfNeeded(
                    phase: dictation.phase,
                    conversationID: id,
                    sessionGeneration: generation,
                    nowPlaying: self.music.nowPlaying
                )
                openConversation(id)
            }
        )))

        stateObserver = Publishers.CombineLatest4(
            dictation.$phase,
            conversations.$currentConversationID,
            conversations.$currentSessionGeneration,
            music.$nowPlaying
        )
            .sink { [weak self] phase, conversationID, sessionGeneration, nowPlaying in
                guard let self else { return }
                if sessionGeneration != self.dismissedSessionGeneration {
                    // A new recording, including a retry of the same
                    // conversation, gets a fresh HUD. Later phase updates in
                    // the same generation cannot undo a deliberate dismissal.
                    if sessionGeneration > 0 {
                        self.dismissedConversationID = nil
                        self.dismissedSessionGeneration = nil
                        self.shelfState.dismissedConversationID = nil
                        self.shelfState.dismissedSessionGeneration = nil
                    }
                }
                self.hideDictationIfNeeded(
                    phase: phase,
                    conversationID: conversationID,
                    sessionGeneration: sessionGeneration,
                    nowPlaying: nowPlaying
                )
            }
    }

    private func hideDictationIfNeeded(
        phase: NoteDictationService.Phase,
        conversationID: UUID?,
        sessionGeneration: UInt64,
        nowPlaying: MediaNowPlayingSnapshot?
    ) {
        let dictationVisible = phase != .idle
            && conversationID != nil
            && sessionGeneration != dismissedSessionGeneration
        let musicVisible = nowPlaying != nil
        guard dictationVisible || musicVisible else {
            hide()
            return
        }
        let width: CGFloat = dictationVisible && musicVisible ? 702 : (dictationVisible ? 320 : 374)
        show(width: width)
    }

    private func show(width: CGFloat) {
        panel.setContentSize(NSSize(width: width, height: 56))
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let visibleFrame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: visibleFrame.midX - width / 2,
                y: visibleFrame.minY + 18
            ))
        }
        // The shelf is informational and must never interrupt the application
        // that owns keyboard focus. `orderFrontRegardless()` raises the panel
        // without making it key or activating Lima.
        panel.orderFrontRegardless()
    }

    private func hide() {
        panel.orderOut(nil)
    }
}

private final class ShelfHostingView<Content: View>: NSHostingView<Content> {
    // Allow controls to receive the first click without requiring the shelf to
    // become the key window. Passive shelf updates never change focus.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class DictationHUDPanel: NSPanel {
    // This shelf must never become the key window. In particular, showing
    // music metadata while the user is typing elsewhere must not steal input.
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
        // Keep the shelf above other windows without activating Lima or
        // changing the active application's key window.
        // The shelf can receive deliberate clicks, but it cannot become key.
        // This prevents state updates from redirecting keyboard input while
        // retaining the music and dictation controls.
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
        .accessibilityHidden(true)
    }
}

private struct TopShelfView: View {
    @ObservedObject var dictation: NoteDictationService
    @ObservedObject var conversations: DictationConversationStore
    @ObservedObject var music: MusicNowPlayingService
    let focus: ShelfFocusCoordinator
    @ObservedObject var hudState: DictationHUDState
    let openDictation: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if dictation.phase != .idle,
               let conversationID = conversations.currentConversationID,
               conversationID != hudState.dismissedConversationID,
               conversations.currentSessionGeneration != hudState.dismissedSessionGeneration {
                dictationPill.frame(width: 320)
            }
            if let track = music.nowPlaying {
                musicPill(track).frame(width: 374)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .limaAnimation(LimaDesign.spring(0.24), value: dictation.phase)
        .limaAnimation(LimaDesign.spring(0.24), value: music.nowPlaying)
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
                        Text(streamingText)
                            .limaFont(.system(size: 9.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .contentTransition(.interpolate)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(DictationOpenButtonStyle())
            .help("Open this dictation conversation in Lima Notes")
            .accessibilityLabel("Open current dictation conversation in Lima Notes")

            Button {
                // This is deliberately a sibling control, not a nested button,
                // so stopping can never bubble into the Notes action.
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
        .padding(.horizontal, LimaDesign.toolbarPadding)
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

    private func musicPill(_ track: MediaNowPlayingSnapshot) -> some View {
        let accent = track.source.accent
        let statusMessage = music.controlAvailabilityMessage
        let metadata = [track.artist, track.album]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        let detail = statusMessage ?? (metadata.isEmpty ? track.source.title : metadata)

        return HStack(spacing: 8) {
            Button {
                music.openSource()
                focus.restoreSoon()
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    musicArtwork(for: track, accent: accent)
                    Image(systemName: track.source.symbol)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(LimaColors.primaryText)
                        .padding(4)
                        .background(LimaColors.recessedSurface.opacity(0.92), in: Circle())
                        .padding(3)
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(accent.opacity(0.42), lineWidth: LimaDesign.borderWidth)
                        .allowsHitTesting(false)
                }
            }
            .buttonStyle(.plain)
            .help("Open \(track.source.title)")
            .accessibilityLabel("Open \(track.source.title): \(track.title)")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(track.title)
                        .limaFont(.system(size: 12, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Image(systemName: track.isPlaying ? "waveform" : "pause.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(track.isPlaying ? accent : .secondary)
                }
                Text(detail)
                    .limaFont(.system(size: 8.5, weight: .medium, design: .rounded))
                    .foregroundStyle(statusMessage == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    Text(timeLabel(track.position))
                        .limaFont(.system(size: 7.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(LimaColors.secondaryText)
                    MusicSignalRibbon(
                        progress: track.duration > 0 ? track.position / track.duration : 0,
                        accent: accent
                    )
                    Text(timeLabel(track.duration))
                        .limaFont(.system(size: 7.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(LimaColors.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 3) {
                HStack(spacing: 1) {
                    mediaButton("backward.fill", label: "Previous track") { runMediaAction(.previous) }
                    Button { runMediaAction(.playPause) } label: {
                        Image(systemName: track.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 27, height: 25)
                            .foregroundStyle(LimaColors.primaryText)
                            .background(accent, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help(track.isPlaying ? "Pause \(track.title)" : "Play \(track.title)")
                    .accessibilityLabel(track.isPlaying ? "Pause \(track.title)" : "Play \(track.title)")
                    mediaButton("forward.fill", label: "Next track") { runMediaAction(.next) }
                }
                HStack(spacing: 3) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(get: { music.outputVolume }, set: { music.setOutputVolume($0) }), in: 0...1)
                        .controlSize(.mini)
                        .frame(width: 60)
                        .help("Output volume")
                }
            }
            .frame(width: 88)
            .padding(.vertical, 3)
            .background(LimaColors.recessedSurface.opacity(0.92), in: Capsule())
            .overlay(Capsule().stroke(LimaColors.border, lineWidth: LimaDesign.borderWidth))
            .opacity(music.isPerformingTransport ? 0.55 : 1)
            .disabled(music.isPerformingTransport)
        }
        .padding(.horizontal, 8)
        .frame(height: 56)
        .limaNativeSurface(fill: LimaColors.raisedSurface, radius: LimaRadius.searchField, border: accent.opacity(0.26), shadow: true)
        .overlay(alignment: .bottom) {
            AudioAccentRail(
                level: track.isPlaying ? music.outputAudioLevel : 0,
                accent: accent,
                active: track.isPlaying
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(track.source.title), \(track.isPlaying ? "playing" : "paused"): \(track.title) by \(track.artist)")
    }

    @ViewBuilder
    private func musicArtwork(for track: MediaNowPlayingSnapshot, accent: Color) -> some View {
        if let artwork = music.artwork {
            Image(nsImage: artwork)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(
                    colors: [accent.opacity(0.34), SettingsStore.shared.accentTheme.primary.opacity(0.16)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: track.source.symbol)
                    .limaFont(.system(size: 13, weight: .bold))
                    .foregroundStyle(accent)
            }
        }
    }

    private func mediaButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .bold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(label)
        .accessibilityLabel(label)
    }

    private func runMediaAction(_ action: MusicNowPlayingService.TransportAction) {
        music.perform(action)
        focus.restoreSoon()
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
        case .requestingPermission, .stopping, .transcribing: ProgressView().controlSize(.small)
        case .completed: Image(systemName: "checkmark.circle.fill")
        case .failed: Image(systemName: "exclamationmark.triangle.fill")
        case .idle: Image(systemName: "mic")
        }
    }

    private var primaryText: String {
        switch dictation.phase {
        case .requestingPermission: return "Waiting for dictation permission"
        case .recording: return "Recording · Dictation conversation"
        case .paused: return "Recording paused"
        case .stopping: return "Finishing recording"
        case .transcribing: return "Transcribing conversation"
        case .completed: return "Dictation completed"
        case .failed: return "Dictation failed"
        case .idle: return "Dictation ready"
        }
    }

    private var secondaryText: String {
        switch dictation.phase {
        case .requestingPermission:
            return SettingsStore.shared.dictationEngine == .localWhisper
                ? "Approve Microphone access if prompted"
                : "Approve Microphone and Speech Recognition if prompted"
        case .recording:
            let live = dictation.semiLiveSegmentCount == 0 ? "live · listening" : "live · \(dictation.semiLiveSegmentCount) added"
            return "\(Self.clock(dictation.recordingElapsed)) · \(live) · \(dictation.inputSignalText)"
        case .paused:
            return "\(Self.clock(dictation.recordingElapsed)) · paused"
        case .stopping:
            return "Finishing recording…"
        case .transcribing:
            return dictation.transcriptionProgress ?? "Transcribing…"
        case .completed:
            return "Transcript ready to edit"
        case .failed:
            return "Retry the saved recording or record again"
        case .idle:
            return ""
        }
    }

    private var streamingText: String {
        if dictation.phase == .recording,
           !dictation.livePreviewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "“\(dictation.livePreviewText)”"
        }
        return secondaryText
    }

    private var accessibilityText: String {
        if dictation.phase == .recording {
            return "Recording conversation · \(Self.clock(dictation.recordingElapsed)) elapsed"
        }
        return primaryText
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
