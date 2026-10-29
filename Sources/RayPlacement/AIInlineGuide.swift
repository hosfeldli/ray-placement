import SwiftUI

/// A discoverable, keyboard-accessible explanation for controls whose hover
/// help is too brief to describe the complete workflow.
struct AIInlineGuide: View {
    let title: String
    let steps: [String]
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(LimaTheme.textSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Help: " + title)
        .help("How " + title.lowercased() + " works")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .limaFont(.headline)
                    .foregroundStyle(LimaTheme.textPrimary)
                ForEach(steps.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 8) {
                        Text(String(index + 1) + ".")
                            .limaFont(.caption.weight(.semibold))
                            .foregroundStyle(SettingsStore.shared.accentTheme.readablePrimary)
                        Text(steps[index])
                            .limaFont(.caption)
                            .foregroundStyle(LimaTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16)
            .frame(width: 310, alignment: .leading)
        }
    }
}

struct AIProviderSetupChecklist: View {
    let provider: AIProvider
    private var steps: [String] { AIProviderSetupInstructions.steps(for: provider) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(steps.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 8) {
                    Text(String(index + 1) + ".")
                        .limaFont(.caption.weight(.semibold))
                        .foregroundStyle(SettingsStore.shared.accentTheme.readablePrimary)
                    Text(steps[index])
                        .limaFont(.caption)
                        .foregroundStyle(LimaTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

enum AIProviderSetupInstructions {
    static func steps(for provider: AIProvider) -> [String] {
        switch provider {
        case .codexCLI:
            return [
                "Install the official OpenAI Codex CLI so the codex command is available in your Terminal.",
                "Run codex login in Terminal and complete the CLI sign-in there. Lima does not collect that credential.",
                "Return to Lima, choose CLI default or a model, then select Test Connection."
            ]
        case .claudeCLI:
            return [
                "Install the official Anthropic Claude Code CLI so the claude command is available in your Terminal.",
                "Run claude in Terminal and complete its interactive sign-in there. Lima does not collect that credential.",
                "Return to Lima, choose CLI default or a model, then select Test Connection."
            ]
        case .openAICompatible:
            return [
                "Enter your server's base URL and model ID in AI Settings. An API key is optional if the server does not require one.",
                "If the server requires a key, paste it into the secure field and save it to Keychain.",
                "Select Test Connection before sending a request."
            ]
        default:
            return [
                "Create an API key in your " + provider.title + " account.",
                "Paste the key into Lima's secure field and save it to macOS Keychain.",
                "Select a model and choose Test Connection before sending a request."
            ]
        }
    }
}
