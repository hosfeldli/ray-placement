import AppKit
import SwiftUI

@MainActor
final class ActionToastController {
    enum Style: Equatable {
        case working
        case success
        case error

        var symbol: String {
            switch self {
            case .working: return "clock.arrow.circlepath"
            case .success: return "checkmark.circle.fill"
            case .error: return "exclamationmark.triangle.fill"
            }
        }

        var color: Color {
            switch self {
            case .working: return .cyan
            case .success: return .green
            case .error: return .orange
            }
        }
    }

    private let panel: NSPanel
    private var dismissWorkItem: DispatchWorkItem?
    private var workingStartedAt: Date?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle]
        panel.setAccessibilityLabel("RayPlacement action status")
    }

    func show(_ message: String, style: Style = .success, duration: TimeInterval = 1.4) {
        show(message, style: style, duration: duration, compact: false)
    }

    func showStealth(_ message: String, style: Style = .working, duration: TimeInterval = 3_600) {
        show(message, style: style, duration: duration, compact: true)
    }

    private func show(_ message: String, style: Style, duration: TimeInterval, compact: Bool) {
        dismissWorkItem?.cancel()
        if style == .working {
            if workingStartedAt == nil { workingStartedAt = Date() }
        } else {
            workingStartedAt = nil
        }
        let width: CGFloat = compact ? 190 : 360
        let height: CGFloat = compact ? 34 : 44
        panel.setContentSize(NSSize(width: width, height: height))
        panel.contentView = NSHostingView(rootView: LimaTypographyRoot(content: ActionToastView(message: message, style: style, startedAt: workingStartedAt, compact: compact)))
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let visibleFrame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: visibleFrame.midX - panel.frame.width / 2,
                y: visibleFrame.minY + 30
            ))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        let workItem = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }

    func dismiss() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        workingStartedAt = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        })
    }
}

private struct ActionToastView: View {
    let message: String
    let style: ActionToastController.Style
    let startedAt: Date?
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 7 : 9) {
            if style == .working {
                ProgressView().controlSize(compact ? .mini : .small)
            } else {
                Image(systemName: style.symbol)
                    .limaFont(.system(size: 14, weight: .semibold))
                    .foregroundStyle(style.color)
            }
            Text(message)
                .limaFont(.system(size: compact ? 11.5 : 12.5, weight: .semibold))
                .lineLimit(2)
            Spacer(minLength: 0)
            if !compact, let startedAt, style == .working {
                Text(startedAt, style: .timer)
                    .limaFont(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, compact ? 10 : LimaDesign.toolbarPadding)
        .frame(width: compact ? 190 : 360, height: compact ? 34 : LimaDesign.toolbarHeight)
        .background(.ultraThinMaterial, in: PrismaticPanelShape(cut: LimaDesign.compactCorner))
        .background(LimaDesign.recessedFill, in: PrismaticPanelShape(cut: LimaDesign.compactCorner))
        .overlay(
            PrismaticPanelShape(cut: LimaDesign.compactCorner)
                .stroke(style.color.opacity(0.34), lineWidth: 0.7)
        )
        .shadow(color: style.color.opacity(0.07), radius: 8, y: 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }
}
