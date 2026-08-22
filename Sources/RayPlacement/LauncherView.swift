import AppKit
import RayPlacementWriting
import SwiftUI

struct LauncherView: View {
    @ObservedObject var viewModel: LauncherViewModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            Divider().opacity(0.65)
            content
            Divider().opacity(0.65)
            footer
        }
        .frame(width: 740, height: 510)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.32), radius: 28, y: 14)
        .onAppear { focusSearch() }
        .onChange(of: viewModel.focusGeneration) { _ in focusSearch() }
    }

    private var searchHeader: some View {
        HStack(spacing: 12) {
            if viewModel.mode == .root {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                    .accessibilityHidden(true)
            } else {
                Button {
                    viewModel.enter(.root)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                .help("Back")
            }

            if let title = viewModel.mode.title, viewModel.mode != .root {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }

            if isOutputMode {
                Text(outputHeaderText)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                TextField(viewModel.placeholder, text: $viewModel.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .regular))
                    .focused($searchFocused)
                    .accessibilityLabel(viewModel.placeholder)
            }

            if viewModel.isSearching {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 20)
            } else if !viewModel.query.isEmpty {
                Text("esc")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 66)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.mode {
        case .writingReview(let review):
            writingReviewView(review)
        case .output(let title, let text, let state):
            outputView(title: title, text: text, state: state)
        default:
            resultList
        }
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(Array(viewModel.results.enumerated()), id: \.element.id) { index, item in
                        if viewModel.isActionable(item) {
                            Button {
                                viewModel.select(index)
                                viewModel.executeSelected()
                            } label: {
                                ResultRow(
                                    item: item,
                                    selected: index == viewModel.selectedIndex,
                                    actionLabel: actionLabel(for: item)
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(accessibilityLabel(for: item)))
                            .accessibilityHint(Text("Press to \(actionLabel(for: item).lowercased())"))
                            .accessibilityValue(Text(index == viewModel.selectedIndex ? "Selected" : ""))
                            .accessibilityAddTraits(index == viewModel.selectedIndex ? .isSelected : [])
                            .id(item.id)
                            .onHover { hovering in
                                if hovering { viewModel.select(index) }
                            }
                        } else {
                            ResultRow(item: item, selected: false, actionLabel: nil)
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel(Text(accessibilityLabel(for: item)))
                                .id(item.id)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .onChange(of: viewModel.selectedIndex) { newIndex in
                guard viewModel.results.indices.contains(newIndex) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(viewModel.results[newIndex].id, anchor: .center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func outputView(title: String, text: String, state: LauncherOutputState) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if case .running = state {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: state == .error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(state == .error ? Color.orange : Color.green)
                }
                Text(title).font(.headline)
                Spacer()
                Text(outputStateLabel(state))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(outputStateColor(state))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(outputStateColor(state).opacity(0.12), in: Capsule())
            }
            ScrollView {
                Text(text.isEmpty ? "Command completed." : text)
                    .font(.system(size: 14, design: state == .running(canCancel: true) || state == .running(canCancel: false) ? .rounded : .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(14)
            }
            .background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func writingReviewView(_ review: WritingReview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: review.issues.isEmpty ? "checkmark.seal.fill" : "text.badge.checkmark")
                    .foregroundStyle(review.issues.isEmpty ? Color.green : Color.accentColor)
                Text(review.issues.isEmpty ? "No issues found" : "\(review.issues.count) writing \(review.issues.count == 1 ? "issue" : "issues")")
                    .font(.headline)
                Text("\(review.sourceText.count) selected characters")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy \(review.hasSuggestedChanges ? "Suggested" : "Text")") {
                    viewModel.copyWritingResult(review)
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Copies the reviewed text")
                Button("Replace \(review.hasSuggestedChanges ? "Selection" : "Selected Text")") {
                    viewModel.pasteWritingResult(review)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Replaces the original selection without using the clipboard")
                .keyboardShortcut(.return, modifiers: [])
            }

            Label(
                review.hasSuggestedChanges
                    ? "Review complete — press Return to replace the exact original selection"
                    : "Review complete — no replacement is needed",
                systemImage: review.hasSuggestedChanges ? "return" : "checkmark.circle"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(review.hasSuggestedChanges ? Color.accentColor : .green)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(review.hasSuggestedChanges ? "Suggested text" : "Checked text")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(review.hasSuggestedChanges ? review.suggestedText : review.sourceText)
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(13)
                    .background(Color.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))

                    ForEach(review.issues) { issue in
                        WritingIssueRow(issue: issue)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("RayPlacement")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if let title = viewModel.mode.title {
                Text("/").foregroundStyle(.tertiary)
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if viewModel.mode != .root {
                KeyHint(keys: "esc", label: outputCanCancel ? "Cancel" : "Back")
            }
            if case .writingReview = viewModel.mode {
                KeyHint(keys: "⌘C", label: "Copy")
                KeyHint(keys: "↩", label: "Replace")
            }
            if viewModel.selectedItemIsActionable, !isOutputMode {
                KeyHint(keys: "↩", label: primaryActionLabel)
            }
            if viewModel.hasActionableResults, !isOutputMode {
                KeyHint(keys: "↑↓", label: "Navigate")
            }
        }
        .padding(.horizontal, 17)
        .frame(height: 42)
    }

    private var isOutputMode: Bool {
        switch viewModel.mode {
        case .output, .writingReview: return true
        default: return false
        }
    }

    private var outputHeaderText: String {
        switch viewModel.mode {
        case .writingReview:
            return "Review complete — Return replaces the original highlight"
        case .output(_, let text, let state):
            if case .running = state { return text }
            return state == .error ? "Action needs attention" : "Action completed"
        default:
            return viewModel.placeholder
        }
    }

    private var outputCanCancel: Bool {
        guard case .output(_, _, .running(let canCancel)) = viewModel.mode else { return false }
        return canCancel
    }

    private func outputStateLabel(_ state: LauncherOutputState) -> String {
        switch state {
        case .running: return "WORKING"
        case .success: return "DONE"
        case .error: return "ERROR"
        }
    }

    private func outputStateColor(_ state: LauncherOutputState) -> Color {
        switch state {
        case .running: return .accentColor
        case .success: return .green
        case .error: return .orange
        }
    }

    private var primaryActionLabel: String {
        guard let action = viewModel.selectedItem?.action else { return "Run" }
        switch action {
        case .launchApplication, .openFile, .openURL, .openInVSCode: return "Open"
        case .copyText: return "Copy"
        case .pasteText: return "Paste"
        case .replaceSelectedText: return "Replace"
        case .enterMode: return "Enter"
        default: return "Run"
        }
    }

    private func actionLabel(for item: LauncherItem) -> String {
        switch item.action {
        case .launchApplication, .openFile, .openURL, .openInVSCode: return "Open"
        case .copyText: return "Copy"
        case .pasteText: return "Paste"
        case .replaceSelectedText: return "Replace"
        case .enterMode: return "Enter"
        default: return "Run"
        }
    }

    private func accessibilityLabel(for item: LauncherItem) -> String {
        item.subtitle.isEmpty ? item.title : "\(item.title), \(item.subtitle)"
    }

    private func focusSearch() {
        guard !isOutputMode else { return }
        DispatchQueue.main.async { searchFocused = true }
    }
}

private struct WritingIssueRow: View {
    let issue: WritingIssue

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: issue.kind == .spelling ? "character.cursor.ibeam" : "text.badge.checkmark")
                .foregroundStyle(issue.kind == .spelling ? Color.orange : Color.accentColor)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(issue.original)
                        .font(.system(size: 13, weight: .semibold))
                    Text(issue.kind.rawValue)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                }
                Text(issue.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if !issue.suggestions.isEmpty {
                    Text("Suggestions: \(issue.suggestions.joined(separator: ", "))")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(issue.kind.rawValue): \(issue.original). \(issue.message)")
    }
}

private struct ResultRow: View {
    let item: LauncherItem
    let selected: Bool
    let actionLabel: String?

    var body: some View {
        HStack(spacing: 13) {
            LauncherIconView(icon: item.icon)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 14.5, weight: .medium))
                    .lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 10)
            if let accessory = item.accessory {
                Text(accessory)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            }
            if selected, let actionLabel {
                HStack(spacing: 4) {
                    Text("↩")
                    Text(actionLabel)
                }
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 51)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(selected ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.1), value: selected)
    }
}

private struct LauncherIconView: View {
    let icon: LauncherIcon

    var body: some View {
        Group {
            switch icon {
            case .system(let name):
                Image(systemName: name)
                    .resizable()
                    .scaledToFit()
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
                    .padding(5)
            case .application(let url), .file(let url):
                Image(nsImage: LauncherIconCache.shared.image(for: url))
                    .resizable()
                    .scaledToFit()
            case .text(let text):
                Text(text).font(.system(size: 23))
            }
        }
        .frame(width: 32, height: 32)
    }
}

private final class LauncherIconCache {
    static let shared = LauncherIconCache()
    private let cache = NSCache<NSURL, NSImage>()

    func image(for url: URL) -> NSImage {
        let key = url as NSURL
        if let cached = cache.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(image, forKey: key)
        return image
    }
}

private struct KeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
    }
}

private struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
