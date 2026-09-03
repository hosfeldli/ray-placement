import AppKit
import Combine
import SwiftUI

@MainActor
final class DictationHUDController {
    private let panel: DictationHUDPanel
    private let music = MusicNowPlayingService()
    private let focus = ShelfFocusCoordinator()
    private var stateObserver: AnyCancellable?

    init(dictation: NoteDictationService) {
        panel = DictationHUDPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 56))
        panel.contentView = NSHostingView(rootView: LimaTypographyRoot(content: TopShelfView(
            dictation: dictation,
            music: music,
            focus: focus
        )))

        stateObserver = Publishers.CombineLatest(dictation.$phase, music.$nowPlaying)
            .sink { [weak self] phase, nowPlaying in
                guard let self else { return }
                let dictationVisible = phase != .idle
                let musicVisible = nowPlaying != nil
                guard dictationVisible || musicVisible else {
                    self.hide()
                    return
                }
                let width: CGFloat = dictationVisible && musicVisible ? 702 : (dictationVisible ? 320 : 374)
                self.show(width: width)
            }
    }

    private func show(width: CGFloat) {
        panel.setContentSize(NSSize(width: width, height: 56))
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let visibleFrame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: visibleFrame.midX - width / 2,
                y: visibleFrame.maxY - panel.frame.height - 12
            ))
        }
        panel.orderFrontRegardless()
    }

    private func hide() {
        panel.orderOut(nil)
    }
}

private final class DictationHUDPanel: NSPanel {
    // SwiftUI buttons inside a non-activating panel still require a key-capable
    // responder chain to complete their press gesture. The panel remains
    // non-activating at the app level, so this does not switch applications.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask = [.borderless],
        backing: NSWindow.BackingStoreType = .buffered,
        defer flag: Bool = false
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // Remains non-activating, but accepts deliberate clicks on compact
        // transport and dictation controls without taking keyboard focus.
        ignoresMouseEvents = false
        becomesKeyOnlyIfNeeded = true
        level = .statusBar
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle, .canJoinAllApplications]
        setAccessibilityLabel("RayPlacement activity shelf")
    }
}

private struct TopShelfView: View {
    @ObservedObject var dictation: NoteDictationService
    @ObservedObject var music: MusicNowPlayingService
    let focus: ShelfFocusCoordinator

    var body: some View {
        HStack(spacing: 8) {
            if dictation.phase != .idle {
                dictationPill.frame(width: 320)
            }
            if let track = music.nowPlaying {
                musicPill(track).frame(width: 374)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.84), value: dictation.phase)
        .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.84), value: music.nowPlaying)
    }

    private var dictationPill: some View {
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
            Button {
                dictation.performPrimaryAction(destinationNoteID: nil)
                focus.restoreSoon()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(Color.red.opacity(0.16), in: PrismaticPanelShape(cut: 5))
            }
            .buttonStyle(.plain)
            .help("Stop recording and finish transcription")
            .accessibilityLabel("Stop dictation")
        }
        .padding(.horizontal, 10)
        .frame(height: 56)
        .prismaticShelf(accent: .red)
        .overlay(alignment: .bottom) {
            AudioAccentRail(level: dictation.audioLevel, accent: .red, active: dictation.phase == .recording)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
    }

    private func musicPill(_ track: MediaNowPlayingSnapshot) -> some View {
        let accent = track.source.accent
        return HStack(spacing: 8) {
            musicArtwork(for: track, accent: accent)
            .frame(width: 38, height: 38)
            .clipShape(PrismaticPanelShape(cut: 7))
            .overlay(PrismaticPanelShape(cut: 7).stroke(accent.opacity(0.48), lineWidth: 0.8))

            Button {
                music.openSource()
                focus.restoreSoon()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Image(systemName: track.source.symbol)
                            .limaFont(.system(size: 8, weight: .bold))
                            .foregroundStyle(accent)
                        Text(track.source.title.uppercased())
                            .limaFont(.system(size: 8, weight: .bold, design: .rounded))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                        if track.isPlaying {
                            MusicActivityIndicator(level: music.outputAudioLevel, color: accent)
                        } else {
                            Text("PAUSED")
                                .limaFont(.system(size: 7.5, weight: .bold, design: .rounded))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text(track.title)
                        .limaFont(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Text(music.transportMessage ?? music.controlAvailabilityMessage ?? mediaSubtitle(track))
                        .limaFont(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle((music.transportMessage == nil && music.controlAvailabilityMessage == nil) ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(track.source.title)")
            .accessibilityLabel("Open \(track.source.title): \(track.title)")

            HStack(spacing: 2) {
                mediaButton("backward.fill", label: "Previous track") { runMediaAction(.previous) }
                Button {
                    runMediaAction(.playPause)
                } label: {
                    Image(systemName: track.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 10.5, weight: .bold))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(.white)
                        .background(accent.gradient, in: PrismaticPanelShape(cut: 6))
                        .overlay(PrismaticPanelShape(cut: 6).stroke(Color.white.opacity(0.34), lineWidth: 0.6))
                        .shadow(color: accent.opacity(0.28), radius: 6, y: 2)
                }
                .buttonStyle(.plain)
                .help(track.isPlaying ? "Pause \(track.title)" : "Play \(track.title)")
                .accessibilityLabel(track.isPlaying ? "Pause \(track.title)" : "Play \(track.title)")
                mediaButton("forward.fill", label: "Next track") { runMediaAction(.next) }
            }
            .opacity(music.isPerformingTransport ? 0.55 : 1)
            .disabled(music.isPerformingTransport)
        }
        .padding(.horizontal, 10)
        .frame(height: 56)
        .prismaticShelf(accent: accent)
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
                .frame(width: 25, height: 25)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.white.opacity(0.055), in: PrismaticPanelShape(cut: 5))
        .help(label)
        .accessibilityLabel(label)
    }

    private func runMediaAction(_ action: MusicNowPlayingService.TransportAction) {
        music.perform(action)
        focus.restoreSoon()
    }

    private func mediaSubtitle(_ track: MediaNowPlayingSnapshot) -> String {
        let detail = track.artist.isEmpty ? track.album : track.artist
        return detail.isEmpty ? track.source.title : "\(track.source.title) · \(detail)"
    }

    @ViewBuilder
    private var activityIndicator: some View {
        switch dictation.phase {
        case .recording: SpeechLevelView(level: dictation.audioLevel)
        case .requestingPermission, .transcribing: ProgressView().controlSize(.small)
        case .idle: Image(systemName: "mic")
        }
    }

    private var primaryText: String {
        switch dictation.phase {
        case .requestingPermission: return "Waiting for dictation permission"
        case .recording: return "Recording · \(dictation.destinationNoteTitle)"
        case .transcribing: return "Transcribing to \(dictation.destinationNoteTitle)"
        case .idle: return "Dictation stopped"
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
        case .transcribing:
            return dictation.transcriptionProgress ?? "Processing locally…"
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
            return "Recording to \(dictation.destinationNoteTitle), \(Self.clock(dictation.recordingElapsed)) elapsed"
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

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !active)) { context in
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
                    .fill(LinearGradient(colors: [.clear, accent.opacity(0.95), .white.opacity(0.78), accent.opacity(0.75), .clear], startPoint: .leading, endPoint: .trailing))
                    .frame(width: width, height: 2)
                    .offset(x: 6 + position)
                    .opacity(0.42 + amount * 0.58)
                    .shadow(color: accent.opacity(0.35 + amount * 0.55), radius: 2 + amount * 5)
                    .animation(.linear(duration: 0.08), value: amount)
            }
        }
        .frame(height: 3)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private extension View {
    func prismaticShelf(accent: Color) -> some View {
        background(.ultraThinMaterial, in: PrismaticPanelShape(cut: 8))
            .background(Color.black.opacity(0.30), in: PrismaticPanelShape(cut: 8))
            .overlay(
                PrismaticPanelShape(cut: 8)
                    .fill(
                        LinearGradient(
                            colors: [.clear, Color.white.opacity(0.09), accent.opacity(0.10), .clear],
                            startPoint: .bottomLeading,
                            endPoint: .topTrailing
                        )
                    )
                    .blendMode(.screen)
            )
            .overlay(
                PrismaticPanelShape(cut: 8)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.36), accent.opacity(0.44), Color.white.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
            )
            .shadow(color: accent.opacity(0.16), radius: 10, y: 5)
    }
}

private struct MusicActivityIndicator: View {
    let level: Double
    let color: Color

    var body: some View {
        HStack(alignment: .center, spacing: 1.5) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(color)
                    .frame(width: 2, height: barHeight(for: index))
            }
        }
        .frame(width: 13, height: 10, alignment: .center)
        .accessibilityHidden(true)
    }

    private func barHeight(for index: Int) -> CGFloat {
        let multiplier: Double = index.isMultiple(of: 2) ? 1 : 1.65
        return CGFloat(3 + 7 * max(0.25, level) * multiplier)
    }
}

private struct SpeechLevelView: View {
    let level: Double
    private let multipliers: [Double] = [0.58, 1.0, 0.72]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(Array(multipliers.enumerated()), id: \.offset) { _, multiplier in
                Capsule()
                    .fill(Color.red)
                    .frame(width: 3, height: 4 + 15 * max(0.08, level) * multiplier)
            }
        }
        .frame(width: 28, height: 24)
        .background(Color.red.opacity(0.10), in: PrismaticPanelShape(cut: 5))
        .animation(.linear(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }
}
