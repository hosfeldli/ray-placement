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
            case .working: return .accentColor
            case .success: return .green
            case .error: return .orange
            }
        }
    }

    private let panel: NSPanel
    private var dismissWorkItem: DispatchWorkItem?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 330, height: 62),
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
        dismissWorkItem?.cancel()
        panel.contentView = NSHostingView(rootView: ActionToastView(message: message, style: style))
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let visibleFrame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: visibleFrame.midX - panel.frame.width / 2,
                y: visibleFrame.maxY - panel.frame.height - 42
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

    var body: some View {
        HStack(spacing: 11) {
            if style == .working {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: style.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(style.color)
            }
            Text(message)
                .font(.system(size: 13.5, weight: .semibold))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 17)
        .frame(width: 330, height: 62)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }
}
