import AppKit
import Combine
import SwiftUI

@MainActor
final class DictationHUDController {
    private let panel: DictationHUDPanel
    private let music = MusicNowPlayingService()
    private var stateObserver: AnyCancellable?

    init(dictation: NoteDictationService) {
        panel = DictationHUDPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 48))
        panel.contentView = NSHostingView(rootView: TopShelfView(
            dictation: dictation,
            music: music
        ))

        stateObserver = Publishers.CombineLatest(dictation.$phase, music.$nowPlaying)
            .sink { [weak self] phase, nowPlaying in
                guard let self else { return }
                let dictationVisible = phase != .idle
                let musicVisible = nowPlaying != nil
                guard dictationVisible || musicVisible else {
                    self.hide()
                    return
                }
                let width: CGFloat = dictationVisible && musicVisible ? 590 : (dictationVisible ? 312 : 270)
                self.show(width: width)
            }
    }

    private func show(width: CGFloat) {
        panel.setContentSize(NSSize(width: width, height: 48))
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
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel],
        backing: NSWindow.BackingStoreType = .buffered,
        defer flag: Bool = false
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // This is an informational overlay: it should never take focus or
        // intercept work in the app beneath it.
        ignoresMouseEvents = true
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

    var body: some View {
        HStack(spacing: 8) {
            if dictation.phase != .idle {
                dictationPill.frame(width: 312)
            }
            if let track = music.nowPlaying {
                musicPill(track).frame(width: 270)
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
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text(secondaryText)
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .prismaticShelf(accent: .red)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
    }

    private func musicPill(_ track: MediaNowPlayingSnapshot) -> some View {
        HStack(spacing: 8) {
            ZStack {
                PrismaticPanelShape(cut: 6)
                    .fill(SettingsStore.shared.accentTheme.gradient.opacity(0.24))
                Image(systemName: track.source.symbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(SettingsStore.shared.accentTheme.tertiary)
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text(mediaSubtitle(track))
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .prismaticShelf(accent: SettingsStore.shared.accentTheme.tertiary)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(track.source.title), now playing \(track.title) by \(track.artist)")
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
            let live = dictation.semiLiveSegmentCount == 0 ? "semi-live" : "\(dictation.semiLiveSegmentCount) added"
            return "\(Self.clock(dictation.recordingElapsed)) · \(live) · \(dictation.inputSignalText)"
        case .transcribing:
            return dictation.transcriptionProgress ?? "Processing locally…"
        case .idle:
            return ""
        }
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
