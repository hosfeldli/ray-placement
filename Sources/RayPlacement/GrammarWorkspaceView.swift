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

    init() {}

    #if DEBUG
    init(visualReview: WritingReview) {
        precondition(LimaTestEnvironment.isEnabled)
        _sourceText = State(initialValue: visualReview.sourceText)
        _review = State(initialValue: visualReview)
        _acceptedIssueIDs = State(initialValue: Set(visualReview.issues.map(\.id)))
    }
    #endif

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
                grammarHeader(compact: proxy.size.width < 620)
                GlassHairline()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let review {
                            if proxy.size.width >= 760 {
                                HStack(alignment: .top, spacing: 12) {
                                    textPanel(title: "Original text", text: review.sourceText,
                                              symbol: "text.alignleft", tint: LimaTheme.textSecondary)
                                    textPanel(title: "Improved version", text: correctedText,
                                              symbol: "checkmark.circle", tint: LimaTheme.accentInk)
                                }
                            } else {
                                VStack(spacing: 12) {
                                    textPanel(title: "Original text", text: review.sourceText,
                                              symbol: "text.alignleft", tint: LimaTheme.textSecondary)
                                    textPanel(title: "Improved version", text: correctedText,
                                              symbol: "checkmark.circle", tint: LimaTheme.accentInk)
                                }
                            }
                            LimaWorkspaceCard { reviewChanges(review) }
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

    private func grammarHeader(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 11) {
                LimaWorkspaceHeading(title: "Grammar checker",
                    subtitle: isChecking ? (statusMessage ?? "Checking locally…") : "Review and improve your writing on this Mac.",
                    symbol: "textformat.abc", tint: .green)
                if !compact { localOnlyBadge }
            }
            if compact {
                HStack {
                    localOnlyBadge
                    Spacer()
                }
                grammarEditActions
                grammarCheckActions
            } else {
                HStack(spacing: 8) {
                    grammarEditActions
                    Spacer(minLength: 8)
                    grammarCheckActions
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
    }

    private var localOnlyBadge: some View {
        Label("LOCAL ONLY", systemImage: "lock.fill")
            .font(.system(size: 9, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(LimaTheme.accentInk)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(LimaTheme.accentSoft, in: Capsule())
            .overlay(Capsule().stroke(LimaTheme.borderSubtle, lineWidth: LimaDesign.hairlineWidth))
            .fixedSize()
    }

    private var grammarEditActions: some View {
        HStack(spacing: 8) {
            Button(action: pasteFromClipboard) {
                Label("Paste text", systemImage: "clipboard")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Paste plain text from the clipboard")
            .accessibilityLabel("Paste from Clipboard")

            if review != nil {
                Button("Edit original") { review = nil; acceptedIssueIDs.removeAll() }
                    .buttonStyle(.borderless)
            }
            if !sourceText.isEmpty {
                Button("Clear") { sourceText = "" }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Clear the text editor")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .disabled(isChecking)
    }

    private var grammarCheckActions: some View {
        HStack(spacing: 8) {
            Text("\(sourceText.count.formatted()) / \(characterLimit.formatted())")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(sourceText.count > characterLimit ? Color.red : LimaTheme.textTertiary)
            Spacer(minLength: 8)
            Button(action: runCheck) {
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
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func pasteFromClipboard() {
        guard let pasted = NSPasteboard.general.string(forType: .string),
              !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "The clipboard does not contain plain text."
            return
        }

        if pasted.count > characterLimit {
            sourceText = String(pasted.prefix(characterLimit))
            statusMessage = "Pasted the first \(characterLimit.formatted()) characters from the clipboard."
        } else {
            sourceText = pasted
            statusMessage = "Pasted text from the clipboard."
        }
    }

    private var sourceEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Write or paste text", systemImage: "text.alignleft")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(LimaTheme.textSecondary)
                Spacer()
                Label("Plain text", systemImage: "textformat")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(LimaTheme.textTertiary)
            }
            .padding(.horizontal, 13)
            .frame(height: 38)
            Rectangle().fill(LimaTheme.borderSubtle).frame(height: LimaDesign.hairlineWidth)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $sourceText)
                    .limaFont(.system(size: 15))
                    .lineSpacing(5)
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
                    .limaFont(.headline)
                    .foregroundStyle(LimaTheme.textPrimary)
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
                    .limaFont(.system(size: 15))
                    .lineSpacing(5)
                    .foregroundStyle(text.isEmpty ? LimaTheme.textTertiary : LimaTheme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(13)
            }
            .frame(minHeight: 260)
            HStack {
                Text("\(text.split(whereSeparator: { $0.isWhitespace }).count) words")
                    .limaFont(.caption).foregroundStyle(LimaTheme.textSecondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    statusMessage = "Copied " + title.lowercased() + "."
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                .buttonStyle(.bordered)
                .disabled(text.isEmpty)
            }.padding(13)
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
            reviewInsights(review)

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

    private func reviewInsights(_ review: WritingReview) -> some View {
        HStack(spacing: 0) {
            reviewInsight(value: review.issues.count.formatted(), label: "Suggestions", symbol: "sparkles")
            Divider().frame(height: 34)
            reviewInsight(value: acceptedIssueIDs.count.formatted(), label: "Accepted", symbol: "checkmark.circle")
            Divider().frame(height: 34)
            reviewInsight(value: correctedText.count.formatted(), label: "Characters", symbol: "text.alignleft")
        }
        .padding(.vertical, 9)
        .background(LimaTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: LimaRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: LimaRadius.card, style: .continuous)
            .stroke(LimaTheme.borderSubtle, lineWidth: LimaDesign.hairlineWidth))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(review.issues.count) suggestions, \(acceptedIssueIDs.count) accepted, \(correctedText.count) characters")
    }

    private func reviewInsight(value: String, label: String, symbol: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LimaTheme.accentInk)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(LimaTheme.textPrimary)
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(LimaTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func issueRow(_ issue: WritingIssue) -> some View {
        let isAccepted = acceptedIssueIDs.contains(issue.id)
        let suggestion = issue.suggestions.first ?? "No safe suggestion"
        return VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 9) {
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
          .limaFont(.callout)
          Text(issue.message).limaFont(.caption)
              .foregroundStyle(LimaTheme.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(minHeight: 54)
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
