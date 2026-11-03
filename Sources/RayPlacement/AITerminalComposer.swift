import SwiftUI

/// A real instruction composer for the same agent, separate from PTY input.
/// Shell output and command input remain in the terminal process itself.
struct AITerminalComposer: View {
    @ObservedObject var model: AIChatViewModel
    let openChat: (() -> Void)?
    @State private var request = ""
    @State private var notice: String?

    private var waiting: Bool { model.pendingQuestion != nil || model.pendingApproval != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if waiting {
                HStack {
                    Label("Lima needs your input to continue", systemImage: "hand.raised")
                    Spacer()
                    if let openChat { Button("Review in Chat", action: openChat) }
                }.font(.caption).foregroundStyle(.orange)
            }
            HStack(spacing: 9) {
                Image(systemName: "sparkles").foregroundStyle(LimaTheme.accentInk)
                TextField(model.canEndTask ? "Lima is working…" : "Ask Lima to build, edit, run or investigate…", text: $request)
                    .textFieldStyle(.plain).onSubmit(submit)
                    .disabled(model.canEndTask)
                    .accessibilityLabel("Instruction for Lima")
                if model.canEndTask {
                    ProgressView().controlSize(.small)
                } else {
                    Button(action: submit) { Image(systemName: "arrow.up.circle.fill").font(.title3) }
                        .buttonStyle(.plain).disabled(request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Send terminal instruction")
                }
            }
            if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            Text("AI instructions · real shell below · shared chat, tools and task progress")
                .font(.caption2).foregroundStyle(LimaTheme.textTertiary)
        }.padding(12).background(LimaTheme.surfaceSecondary)
    }

    private func submit() {
        guard !model.canEndTask, !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            notice = "Finish or clear your unsent Chat draft before sending another instruction."
            return
        }
        model.draft = request; model.send()
        if model.draft.isEmpty { request = ""; notice = nil }
        else { notice = model.streamError ?? "Open Chat to finish setting up the provider." }
    }
}
