import AppKit
import RayPlacementWriting
import SwiftUI

/// A focused, local-only proofreading workspace. All mutations remain reviewable
/// in the editor; this surface never requires an AI provider or account.
@MainActor
struct GrammarWorkspaceView: View {
    private let characterLimit = 50_000
    @State private var sourceText = ""
    @State private var review: WritingReview?
    @State private var acceptedIssueIDs = Set<String>()
    @State private var isChecking = false
    @State private var statusMessage: String?
    @State private var checker = RuleBasedWritingChecker()

    private var correctedText: String {
        guard let review else { return sourceText }
        return review.applying(acceptedIssueIDs).suggestedText
    }

    private var canCheck: Bool {
        !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && sourceText.count <= characterLimit
            && !isChecking
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 9) {
                    Label(isChecking ? (statusMessage ?? "Checking locally…") : "Local proofreader",
                          systemImage: isChecking ? "ellipsis.circle" : "lock.shield")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LimaTheme.textSecondary)
                    Spacer(minLength: 8)
                    Text("\(sourceText.count.formatted()) / \(characterLimit.formatted())")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(sourceText.count > characterLimit ? Color.red : LimaTheme.textTertiary)
                    Button {
                        runCheck()
                    } label: {
                        if isChecking {
                            ProgressView().controlSize(.small)
                                .frame(width: 112, height: 24)
                        } else {
                            Label("Check writing", systemImage: "wand.and.stars")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LimaTheme.accentInk)
                    .controlSize(.small)
                    .disabled(!canCheck)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .help("Check locally with Harper · ⌘↩")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                GlassHairline()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let review {
                            if proxy.size.width >= 760 {
                                HStack(alignment: .top, spacing: 12) {
                                    textPanel(title: "ORIGINAL TEXT", text: review.sourceText,
                                              symbol: "text.alignleft", tint: LimaTheme.textSecondary)
                                    textPanel(title: "IMPROVED VERSION", text: correctedText,
                                              symbol: "checkmark.circle", tint: LimaTheme.accentInk)
                                }
                            } else {
                                VStack(spacing: 12) {
                                    textPanel(title: "ORIGINAL TEXT", text: review.sourceText,
                                              symbol: "text.alignleft", tint: LimaTheme.textSecondary)
                                    textPanel(title: "IMPROVED VERSION", text: correctedText,
                                              symbol: "checkmark.circle", tint: LimaTheme.accentInk)
                                }
                            }
                            reviewChanges(review)
                        } else {
                            if proxy.size.width >= 760 {
                                HStack(alignment: .top, spacing: 12) {
                                    sourceEditor
                                    localStatusCard
                                        .frame(width: 224)
                                }
                            } else {
                                VStack(spacing: 12) {
                                    sourceEditor
                                    localStatusCard
                                }
                            }
                        }
                        if let statusMessage, !isChecking {
                            Label(statusMessage, systemImage: review == nil ? "info.circle" : "checkmark.circle")
                                .font(.caption)
                                .foregroundStyle(LimaTheme.textSecondary)
                                .padding(.horizontal, 2)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .background(LimaTheme.surfacePrimary)
        }
        .onChange(of: sourceText) { _ in
            guard !isChecking else { return }
            review = nil
            acceptedIssueIDs.removeAll()
            statusMessage = nil
        }
        .onDisappear { checker.cancel() }
        .accessibilityIdentifier("lima-grammar-workspace")
    }

    private var sourceEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Write or paste text", systemImage: "text.alignleft")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(LimaTheme.textSecondary)
                Spacer()
                if !sourceText.isEmpty {
                    Button("Clear") { sourceText = "" }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 13)
            .frame(height: 38)
            Rectangle().fill(LimaTheme.borderSubtle).frame(height: LimaDesign.hairlineWidth)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $sourceText)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .accessibilityLabel("Text to proofread")
                if sourceText.isEmpty {
                    Text("Paste or write a passage to check spelling and grammar…")
                        .font(.system(size: 13))
                        .foregroundStyle(LimaTheme.textTertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 15)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 300)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(LimaTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: LimaRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: LimaRadius.card, style: .continuous)
            .stroke(LimaTheme.borderSubtle, lineWidth: LimaDesign.hairlineWidth))
    }

    private var localStatusCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("Private by design", systemImage: "lock.shield.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LimaTheme.textPrimary)
            Text("Harper checks spelling and grammar on this Mac. Your text is not sent to a service.")
                .font(.system(size: 11))
                .foregroundStyle(LimaTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Label("No account or API key", systemImage: "checkmark.circle")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(LimaTheme.textSecondary)
            Label("Up to 50,000 characters", systemImage: "text.alignleft")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(LimaTheme.textSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(LimaTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: LimaRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: LimaRadius.card, style: .continuous)
            .stroke(LimaTheme.borderSubtle, lineWidth: LimaDesign.hairlineWidth))
    }

    private func textPanel(title: String, text: String, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(LimaTheme.textSecondary)
                Spacer()
                Text("\(text.count.formatted()) chars")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(LimaTheme.textTertiary)
            }
            .padding(.horizontal, 13)
            .frame(height: 36)
            Rectangle().fill(LimaTheme.borderSubtle).frame(height: LimaDesign.hairlineWidth)
            ScrollView {
                Text(text.isEmpty ? "No accepted changes yet." : text)
                    .font(.system(size: 12.5))
                    .lineSpacing(3)
                    .foregroundStyle(text.isEmpty ? LimaTheme.textTertiary : LimaTheme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(13)
            }
            .frame(minHeight: 220)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(LimaTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: LimaRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: LimaRadius.card, style: .continuous)
            .stroke(LimaTheme.borderSubtle, lineWidth: LimaDesign.hairlineWidth))
    }

    private func reviewChanges(_ review: WritingReview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(review.issues.isEmpty ? "Writing check" : "Review changes")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LimaTheme.textPrimary)
                    Text(review.issues.isEmpty
                         ? "No spelling or grammar changes were suggested."
                         : "\(review.issues.count) local suggestion\(review.issues.count == 1 ? "" : "s") · choose what to keep")
                        .font(.caption)
                        .foregroundStyle(LimaTheme.textSecondary)
                }
                Spacer()
                if !review.issues.isEmpty {
                    Button("Reject all") { acceptedIssueIDs.removeAll() }
                        .buttonStyle(.borderless)
                    Button("Accept all") {
                        acceptedIssueIDs = Set(review.issues.filter { !$0.suggestions.isEmpty }.map(\.id))
                    }
                    .buttonStyle(.borderless)
                }
            }
            if !review.issues.isEmpty {
                VStack(spacing: 0) {
                    ForEach(review.issues) { issue in
                        issueRow(issue)
                        if issue.id != review.issues.last?.id {
                            Rectangle().fill(LimaTheme.borderSubtle).frame(height: LimaDesign.hairlineWidth)
                        }
                    }
                }
                .background(LimaTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: LimaRadius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: LimaRadius.card, style: .continuous)
                    .stroke(LimaTheme.borderSubtle, lineWidth: LimaDesign.hairlineWidth))
            }
            HStack(spacing: 8) {
                Button { copyCorrectedText() } label: {
                    Label("Copy improved", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(correctedText == sourceText)
                Button { applyCorrectedText() } label: {
                    Label("Use improved text", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.borderedProminent)
                .tint(LimaTheme.accentInk)
                .controlSize(.small)
                .disabled(correctedText == sourceText)
                Spacer()
                Button("Check again") { runCheck() }
                    .buttonStyle(.borderless)
                    .disabled(!canCheck)
            }
        }
    }

    private func issueRow(_ issue: WritingIssue) -> some View {
        let isAccepted = acceptedIssueIDs.contains(issue.id)
        let suggestion = issue.suggestions.first ?? "No safe suggestion"
        return HStack(spacing: 9) {
            Circle()
                .fill(issue.kind == .spelling ? Color.orange : LimaTheme.accentInk)
                .frame(width: 7, height: 7)
            Text(issue.original)
                .strikethrough()
                .foregroundStyle(LimaTheme.textSecondary)
                .lineLimit(1)
            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(LimaTheme.textTertiary)
            Text(suggestion)
                .foregroundStyle(issue.suggestions.isEmpty ? LimaTheme.textTertiary : LimaTheme.textPrimary)
                .lineLimit(1)
            Text(issue.kind.rawValue)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(LimaTheme.textSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(LimaTheme.surfaceSecondary, in: Capsule())
            Spacer(minLength: 4)
            Button(isAccepted ? "Undo" : "Accept") {
                if isAccepted { acceptedIssueIDs.remove(issue.id) }
                else if !issue.suggestions.isEmpty { acceptedIssueIDs.insert(issue.id) }
            }
            .buttonStyle(.borderless)
            .disabled(issue.suggestions.isEmpty)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
    }

    private func runCheck() {
        guard sourceText.count <= characterLimit else {
            statusMessage = "Shorten the text to 50,000 characters or fewer."
            return
        }
        guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "Enter text to check."
            return
        }
        isChecking = true
        review = nil
        acceptedIssueIDs.removeAll()
        statusMessage = "Checking locally…"
        checker.checkLocal(sourceText, progress: { message in
            statusMessage = message
        }) { result in
            isChecking = false
            switch result {
            case .success(let result):
                review = result
                acceptedIssueIDs.removeAll()
                statusMessage = result.issues.isEmpty ? "No changes suggested." : "Review each local suggestion before applying it."
            case .failure(let error):
                statusMessage = error.localizedDescription
            }
        }
    }

    private func copyCorrectedText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(correctedText, forType: .string)
        statusMessage = "Copied improved text."
    }

    private func applyCorrectedText() {
        sourceText = correctedText
        review = nil
        acceptedIssueIDs.removeAll()
        statusMessage = "Applied accepted changes to the editor."
    }
}
