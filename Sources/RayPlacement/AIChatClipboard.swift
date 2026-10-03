import AppKit
import SwiftUI

@MainActor
enum AIChatClipboard {
    /// Keep the exact response or code bytes, including indentation and trailing
    /// newlines. A failed pasteboard write must not be presented as a success.
    @discardableResult
    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
        guard !text.isEmpty else { return false }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }
        return pasteboard.string(forType: .string) == text
    }
}

struct AIChatCopyButton: View {
    enum Style: Equatable {
        case icon
        case labeled
    }

    let text: String
    let style: Style
    let accessibilityID: String
    @State private var outcome: Outcome = .ready

    private enum Outcome: Equatable {
        case ready
        case copied
        case failed

        var label: String {
            switch self {
            case .ready: return "Copy"
            case .copied: return "Copied"
            case .failed: return "Couldn't copy"
            }
        }

        var symbol: String {
            switch self {
            case .ready: return "doc.on.doc"
            case .copied: return "checkmark"
            case .failed: return "exclamationmark.triangle"
            }
        }
    }

    var body: some View {
        Button {
            outcome = AIChatClipboard.copy(text) ? .copied : .failed
        } label: {
            HStack(spacing: 5) {
                Image(systemName: outcome.symbol)
                if style == .labeled { Text(outcome.label) }
            }
            .limaFont(.caption2.weight(.medium))
            .frame(minWidth: 28, minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(outcome == .failed ? LimaColors.danger : LimaTheme.textSecondary)
        .disabled(text.isEmpty)
        .help(outcome.label)
        .accessibilityLabel(outcome.label)
        .accessibilityIdentifier(accessibilityID)
    }
}
