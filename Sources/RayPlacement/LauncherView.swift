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

            TextField(viewModel.placeholder, text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .regular))
                .focused($searchFocused)
                .disabled(isOutputMode)
                .accessibilityLabel(viewModel.placeholder)

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
        case .output(let title, let text, let isError):
            outputView(title: title, text: text, isError: isError)
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
                                ResultRow(item: item, selected: index == viewModel.selectedIndex)
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
                            ResultRow(item: item, selected: false)
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

    private func outputView(title: String, text: String, isError: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                let isRunning = text == "Running…"
                Image(systemName: isRunning ? "clock.fill" : (isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"))
                    .foregroundStyle(isRunning ? Color.accentColor : (isError ? Color.orange : Color.green))
                Text(title).font(.headline)
            }
            ScrollView {
                Text(text.isEmpty ? "Command completed." : text)
                    .font(.system(size: 13, design: .monospaced))
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
            }

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
                KeyHint(keys: "esc", label: "Back")
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
        }
        .padding(.horizontal, 11)
        .frame(height: 51)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.23) : Color.clear)
        )
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
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .scaledToFit()
            case .text(let text):
                Text(text).font(.system(size: 23))
            }
        }
        .frame(width: 32, height: 32)
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
