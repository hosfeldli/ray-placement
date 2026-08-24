import AppKit
import Combine
import SwiftUI

@MainActor
final class DictationHUDController {
    private let panel: DictationHUDPanel
    private var phaseObserver: AnyCancellable?

    init(
        dictation: NoteDictationService,
        openNotes: @escaping () -> Void
    ) {
        panel = DictationHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 68)
        )
        panel.contentView = NSHostingView(rootView: DictationHUDView(
            dictation: dictation,
            openNotes: openNotes,
            stop: { dictation.performPrimaryAction(destinationNoteID: nil) },
            cancel: dictation.cancel
        ))

        phaseObserver = dictation.$phase
            .removeDuplicates()
            .sink { [weak self] phase in
                guard let self else { return }
                switch phase {
                case .idle:
                    self.hide()
                case .requestingPermission, .recording, .transcribing:
                    self.show()
                }
            }
    }

    func show() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let visibleFrame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: visibleFrame.midX - panel.frame.width / 2,
                y: visibleFrame.minY + 18
            ))
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

private final class DictationHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
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
        level = .statusBar
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle, .canJoinAllApplications]
        setAccessibilityLabel("RayPlacement dictation status")
    }
}

private struct DictationHUDView: View {
    @ObservedObject var dictation: NoteDictationService
    let openNotes: () -> Void
    let stop: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            activityIndicator
                .frame(width: 44, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(primaryText)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(secondaryText)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: openNotes) {
                Image(systemName: "note.text")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .help("Open the destination note")
            .accessibilityLabel("Open destination note")

            if dictation.phase == .recording {
                Button("Stop", systemImage: "stop.fill", action: stop)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }

            Button(action: cancel) {
                Image(systemName: "xmark")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Cancel dictation")
        }
        .padding(.horizontal, 13)
        .frame(width: 440, height: 68)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var activityIndicator: some View {
        switch dictation.phase {
        case .recording:
            SpeechLevelView(level: dictation.audioLevel)
        case .requestingPermission, .transcribing:
            ProgressView()
                .controlSize(.small)
        case .idle:
            Image(systemName: "mic")
        }
    }

    private var primaryText: String {
        switch dictation.phase {
        case .requestingPermission:
            return "Waiting for dictation permission"
        case .recording:
            return "Recording to \(dictation.destinationNoteTitle)"
        case .transcribing:
            return "Transcribing to \(dictation.destinationNoteTitle)"
        case .idle:
            return "Dictation stopped"
        }
    }

    private var secondaryText: String {
        switch dictation.phase {
        case .requestingPermission:
            return "Approve Microphone and Speech Recognition if prompted"
        case .recording:
            return "\(Self.clock(dictation.recordingElapsed)) · \(dictation.inputSignalText)"
        case .transcribing:
            return dictation.transcriptionProgress ?? "Processing the recording on this Mac…"
        case .idle:
            return ""
        }
    }

    private var accessibilityText: String {
        switch dictation.phase {
        case .recording:
            return "Recording to \(dictation.destinationNoteTitle), \(Self.clock(dictation.recordingElapsed)) elapsed"
        default:
            return primaryText
        }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct SpeechLevelView: View {
    let level: Double
    private let multipliers: [Double] = [0.48, 0.78, 1.0, 0.72, 0.54]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(multipliers.enumerated()), id: \.offset) { _, multiplier in
                Capsule()
                    .fill(Color.red)
                    .frame(width: 3, height: 5 + 20 * max(0.08, level) * multiplier)
            }
        }
        .frame(width: 40, height: 30)
        .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .animation(.linear(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }
}
