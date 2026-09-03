import AppKit
import RayPlacementWriting
import SwiftUI

struct LauncherView: View {
    @ObservedObject var viewModel: LauncherViewModel
    @ObservedObject private var settings = SettingsStore.shared
    @FocusState private var searchFocused: Bool
    @FocusState private var timezoneFocused: Bool

    var body: some View {
        ZStack {
            LiquidGlassBackdrop(material: .hudWindow, blendingMode: .behindWindow)
            VStack(spacing: 5) {
                searchHeader
                content
                    .id(viewModel.mode.visualIdentity)
                    .transition(.opacity.combined(with: .scale(scale: 0.975)).combined(with: .offset(y: 5)))
                footer
            }
        }
        .frame(width: settings.interfaceDensity.launcherWidth, height: settings.interfaceDensity.launcherHeight)
        .clipShape(PrismaticPanelShape(cut: 18))
        .overlay(
            PrismaticPanelShape(cut: 18)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.82), RayColors.cyan.opacity(0.54), RayColors.indigo.opacity(0.34), Color.black.opacity(0.28)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.0
                )
        )
        .overlay(
            PrismaticPanelShape(cut: 18)
                .strokeBorder(Color.black.opacity(0.56), lineWidth: 0.7)
                .padding(1.35)
        )
        .overlay(alignment: .topTrailing) {
            LinearGradient(
                colors: [.clear, RayColors.cyan.opacity(0.44), Color.white.opacity(0.36)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 118, height: 1)
            .padding(.trailing, 31)
            .padding(.top, 0.7)
        }
        .shadow(color: RayColors.indigo.opacity(0.18), radius: 38, y: 16)
        .shadow(color: .black.opacity(0.48), radius: 30, y: 16)
        .tint(settings.accentTheme.primary)
        .preferredColorScheme(.dark)
        .animation(.interactiveSpring(response: 0.30, dampingFraction: 0.86), value: viewModel.mode.visualIdentity)
        .onAppear { focusSearch() }
        .onChange(of: viewModel.focusGeneration) { _ in focusSearch() }
        .onChange(of: viewModel.mode.visualIdentity) { _ in focusSearch() }
    }

    private var searchHeader: some View {
        HStack(spacing: 10) {
            if viewModel.mode == .root {
                HStack(spacing: 7) {
                    ZStack {
                        PrismaticPanelShape(cut: 7).fill(RayColors.heroGradient)
                        Image(systemName: "sparkle.magnifyingglass")
                            .limaFont(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 27, height: 27)
                    Text("LIMA")
                        .limaFont(.system(size: 11, weight: .black, design: .rounded))
                        .tracking(1.6)
                        .foregroundStyle(.primary)
                }
                .overlay(PrismaticPanelShape(cut: 7).stroke(Color.white.opacity(0.48), lineWidth: 0.7))
                .shadow(color: RayColors.indigo.opacity(0.30), radius: 12, y: 5)
                .accessibilityHidden(true)
            } else {
                Button {
                    viewModel.enter(.root)
                } label: {
                    Image(systemName: "chevron.left")
                        .limaFont(.system(size: 14, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 29, height: 29)
                }
                .buttonStyle(LiquidGlassIconButtonStyle(size: 29))
                .accessibilityLabel("Back")
                .help("Back")
            }

            if let title = viewModel.mode.title, viewModel.mode != .root {
                Text(title)
                    .limaFont(.system(size: 14, weight: .bold))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.right")
                    .limaFont(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }

            if viewModel.mode == .timezoneConverter {
                Spacer()
                StatusCapsule(text: "OFFLINE", color: RayColors.cyan)
            } else if isOutputMode {
                Text(outputHeaderText)
                    .limaFont(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                TextField(viewModel.placeholder, text: $viewModel.query)
                    .textFieldStyle(.plain)
                    .limaFont(.system(size: 17, weight: .medium))
                    .focused($searchFocused)
                    .accessibilityLabel(viewModel.placeholder)
            }

            if viewModel.isSearching {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 20)
            } else if !viewModel.query.isEmpty {
                Text("esc")
                    .limaFont(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.08), in: PrismaticPanelShape(cut: 4))
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 46)
        .liquidGlass(cornerRadius: 13, depth: .raised, accentOpacity: 0.032)
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.mode {
        case .timezoneConverter:
            timezoneConverterView
        case .writingReview(let review):
            writingReviewView(review)
        case .output(let title, let text, let state):
            outputView(title: title, text: text, state: state)
        case .emojiPicker:
            emojiGrid
        default:
            resultList
        }
    }

    private var emojiGrid: some View {
        VStack(spacing: 6) {
            if viewModel.emojiPageCount > 1 {
                HStack(spacing: 5) {
                    Spacer()
                    Button { viewModel.moveEmojiPage(by: -1) } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(EmojiPageButtonStyle(disabled: viewModel.emojiPageIndex == 0))
                    .disabled(viewModel.emojiPageIndex == 0)
                    .accessibilityLabel("Previous emoji page")
                    Text(viewModel.emojiPageLabel)
                        .limaFont(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 36)
                    Button { viewModel.moveEmojiPage(by: 1) } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(EmojiPageButtonStyle(disabled: viewModel.emojiPageIndex + 1 >= viewModel.emojiPageCount))
                    .disabled(viewModel.emojiPageIndex + 1 >= viewModel.emojiPageCount)
                    .accessibilityLabel("Next emoji page")
                }
                .padding(.horizontal, 13)
                .frame(height: 22)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 40, maximum: 46), spacing: 5)],
                        spacing: 5
                    ) {
                        ForEach(viewModel.emojiVisibleRange, id: \.self) { index in
                            let entry = viewModel.emojiMatches[index]
                            Button {
                                viewModel.executeEmoji(at: index)
                            } label: {
                                EmojiGridTile(
                                    emoji: entry.emoji,
                                    selected: index == viewModel.selectedIndex
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(entry.name)
                            .accessibilityValue(index == viewModel.selectedIndex ? "Selected" : "")
                            .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                }
                .onChange(of: viewModel.navigationGeneration) { _ in
                    let newIndex = viewModel.selectedIndex
                    guard viewModel.emojiVisibleRange.contains(newIndex),
                          viewModel.emojiMatches.indices.contains(newIndex) else { return }
                    proxy.scrollTo(viewModel.emojiMatches[newIndex].id, anchor: .center)
                }
                .scrollIndicators(.hidden)
            }
        }
        .overlay {
            if viewModel.emojiMatches.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .limaFont(.system(size: 22, weight: .medium))
                    Text("No matching emoji")
                        .limaFont(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if viewModel.mode == .root, viewModel.contextualSelectionText != nil {
                        contextualSelectionHeader
                    }

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
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 2)
            }
            .onChange(of: viewModel.navigationGeneration) { _ in
                let newIndex = viewModel.selectedIndex
                guard viewModel.results.indices.contains(newIndex) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(viewModel.results[newIndex].id, anchor: .center)
                }
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var contextualSelectionHeader: some View {
        let text = viewModel.contextualSelectionText ?? ""
        let preview = text.replacingOccurrences(of: "\n", with: " ")
        let clippedPreview = String(preview.prefix(132))
        let lineCount = max(1, text.components(separatedBy: .newlines).count)

        return HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(SettingsStore.shared.accentTheme.gradient.opacity(0.22))
                Image(systemName: "text.cursor")
                    .limaFont(.system(size: 13, weight: .bold))
                    .foregroundStyle(SettingsStore.shared.accentTheme.tertiary)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text("For Your Selection")
                    .limaFont(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text(clippedPreview.isEmpty ? "Selected text" : clippedPreview + (preview.count > clippedPreview.count ? "…" : ""))
                    .limaFont(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(text.count.formatted()) chars")
                Text("\(lineCount) \(lineCount == 1 ? "line" : "lines")")
            }
            .limaFont(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11)
        .frame(minHeight: 52)
        .liquidGlass(cornerRadius: 11, depth: .recessed, accentOpacity: 0.018)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Actions for selected text, \(text.count) characters")
    }

    private func outputView(title: String, text: String, state: LauncherOutputState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .running = state {
                HStack(spacing: 12) {
                    TaskOrbitView(color: isWritingOutput(title) ? RayColors.violet : RayColors.cyan)
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(title).limaFont(.system(size: 16, weight: .bold))
                            StatusCapsule(text: isWritingOutput(title) ? "LOCAL RULES" : "RUNNING", color: isWritingOutput(title) ? RayColors.violet : RayColors.cyan)
                        }
                        Text(text.isEmpty ? "Working…" : text)
                            .limaFont(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(13)
                .liquidGlass(cornerRadius: 16, depth: .raised, accentOpacity: 0.030)
                ActivityTimeline(activeStep: activityStep(for: text), isWriting: isWritingOutput(title))
            } else {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(outputStateColor(state).opacity(0.14))
                        Image(systemName: state == .error ? "exclamationmark.triangle.fill" : "checkmark")
                            .limaFont(.system(size: 17, weight: .bold))
                            .foregroundStyle(outputStateColor(state))
                    }
                    .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).limaFont(.system(size: 16, weight: .bold))
                        Text(state == .error ? "Lima needs your attention" : "Finished successfully")
                            .limaFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusCapsule(text: outputStateLabel(state), color: outputStateColor(state))
                }
                ScrollView {
                    Text(text.isEmpty ? "Command completed." : text)
                        .limaFont(.system(size: 13.5, design: .rounded))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(16)
                }
                .liquidGlass(cornerRadius: 14, depth: .recessed, accentOpacity: 0.010)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var timezoneConverterView: some View {
        VStack(spacing: 14) {
            HStack(spacing: 0) {
                timezoneCard(
                    title: "FROM",
                    selection: $viewModel.timezoneSourceID,
                    time: viewModel.timezoneConversion?.sourceTime,
                    date: viewModel.timezoneConversion?.sourceDate,
                    isSource: true
                )

                Button { viewModel.swapTimezones() } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .limaFont(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(RayColors.heroGradient, in: Circle())
                        .shadow(color: RayColors.indigo.opacity(0.28), radius: 9, y: 4)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, -3)
                .zIndex(2)
                .accessibilityLabel("Swap timezones")

                timezoneCard(
                    title: "TO",
                    selection: $viewModel.timezoneDestinationID,
                    time: viewModel.timezoneConversion?.destinationTime,
                    date: viewModel.timezoneConversion?.destinationDate,
                    isSource: false
                )
            }

            HStack {
                Spacer()
                Button {
                    viewModel.copyTimezoneResult()
                } label: {
                    Label(viewModel.timezoneDidCopy ? "Copied" : "Copy result", systemImage: viewModel.timezoneDidCopy ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .tint(RayColors.indigo)
                .disabled(viewModel.timezoneConversion == nil)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func timezoneCard(
        title: String,
        selection: Binding<String>,
        time: String?,
        date: String?,
        isSource: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text(title)
                    .limaFont(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(isSource ? RayColors.indigo : RayColors.cyan)
                Spacer()
                Picker("", selection: selection) {
                    ForEach(LauncherViewModel.timezoneOptions) { option in
                        Text("\(option.title) · \(option.city)").tag(option.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 165)
            }

            if isSource {
                TextField("9:30 AM", text: $viewModel.query)
                    .textFieldStyle(.plain)
                    .limaFont(.system(size: 29, weight: .semibold, design: .rounded))
                    .focused($timezoneFocused)
                    .accessibilityLabel("Time to convert")
                Text(time == nil && !viewModel.query.isEmpty ? "Enter a valid time" : (date ?? "Type a time above"))
                    .limaFont(.caption.weight(.medium))
                    .foregroundStyle(time == nil && !viewModel.query.isEmpty ? Color.orange : .secondary)
            } else {
                Text(time ?? "—")
                    .limaFont(.system(size: 29, weight: .semibold, design: .rounded))
                Text(date.map { "\($0) · \(viewModel.timezoneConversion?.destinationZone ?? "")" } ?? "Converted time appears here")
                    .limaFont(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 174, alignment: .topLeading)
        .liquidGlass(cornerRadius: 15, depth: .raised, accentOpacity: isSource ? 0.025 : 0.016)
    }

    private func writingReviewView(_ review: WritingReview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill((review.issues.isEmpty ? Color.green : RayColors.violet).opacity(0.14))
                    Image(systemName: review.issues.isEmpty ? "checkmark" : "wand.and.stars")
                        .limaFont(.system(size: 16, weight: .bold))
                        .foregroundStyle(review.issues.isEmpty ? Color.green : RayColors.violet)
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(review.issues.isEmpty ? "Your writing is ready" : "Correction ready")
                        .limaFont(.system(size: 16, weight: .bold))
                    Text("\(review.sourceText.count) selected characters · \(activeWritingModelTitle)")
                        .limaFont(.caption)
                        .foregroundStyle(.secondary)
                }
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
                .tint(RayColors.indigo)
                .accessibilityHint("Revalidates and replaces the exact original selection")
                .keyboardShortcut(.return, modifiers: [])
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        writingComparisonPanel(
                            title: "ORIGINAL SELECTION",
                            text: review.sourceText,
                            color: .secondary,
                            symbol: "text.quote"
                        )
                        writingComparisonPanel(
                            title: review.hasSuggestedChanges ? "CORRECTED TEXT" : "CHECKED TEXT",
                            text: review.hasSuggestedChanges ? review.suggestedText : review.sourceText,
                            color: review.hasSuggestedChanges ? RayColors.violet : .green,
                            symbol: review.hasSuggestedChanges ? "wand.and.stars" : "checkmark.circle.fill"
                        )
                    }

                    if let issue = review.issues.first {
                        WritingIssueRow(issue: issue)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func writingComparisonPanel(
        title: String,
        text: String,
        color: Color,
        symbol: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: symbol)
                .limaFont(.system(size: 10.5, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(color)
            Text(text)
                .limaFont(.system(size: 13.5))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .liquidGlass(cornerRadius: 14, depth: .raised, accentOpacity: 0.020)
    }

    private var activeWritingModelTitle: String {
        "Python + Harper"
    }

    @ViewBuilder
    private var footer: some View {
        if viewModel.mode == .root {
            HStack(spacing: 12) {
                Text("\(viewModel.results.count) available")
                    .limaFont(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                KeyHint(keys: "↑↓", label: "Navigate")
                if viewModel.mode == .root {
                    KeyHint(keys: "⌘K", label: "History")
                }
                KeyHint(keys: "↩", label: primaryActionLabel)
                KeyHint(keys: "esc", label: "Close")
            }
            .padding(.horizontal, 13)
            .frame(height: 27)
            .padding(.bottom, 5)
        } else {
            HStack {
                Spacer()
                HStack(spacing: 8) {
                    KeyHint(keys: "esc", label: outputCanCancel ? "Cancel" : "Back")
                    if case .writingReview = viewModel.mode {
                        KeyHint(keys: "⌘C", label: "Copy")
                        KeyHint(keys: "↩", label: "Replace")
                    }
                    if viewModel.selectedItemIsActionable, !isOutputMode {
                        KeyHint(keys: "↩", label: primaryActionLabel)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 25)
            }
            .padding(.horizontal, 9)
            .padding(.bottom, 7)
        }
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
            return "Ready to replace"
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
        case .launchApplication, .openFile, .openURL: return "Open"
        case .copyText: return "Copy"
        case .pasteText: return "Paste"
        case .replaceSelectedText: return "Replace"
        case .saveSelectionToQuickNote: return "Save"
        case .checkSelectedText: return "Review"
        case .forceQuitApplication: return "Review"
        case .enterMode: return "Enter"
        default: return "Run"
        }
    }

    private func actionLabel(for item: LauncherItem) -> String {
        switch item.action {
        case .launchApplication, .openFile, .openURL: return "Open"
        case .copyText: return "Copy"
        case .pasteText: return "Paste"
        case .replaceSelectedText: return "Replace"
        case .saveSelectionToQuickNote: return "Save"
        case .checkSelectedText: return "Review"
        case .forceQuitApplication: return "Review"
        case .enterMode: return "Enter"
        default: return "Run"
        }
    }

    private func accessibilityLabel(for item: LauncherItem) -> String {
        item.subtitle.isEmpty ? item.title : "\(item.title), \(item.subtitle)"
    }

    private func focusSearch() {
        guard !isOutputMode else { return }
        DispatchQueue.main.async {
            if viewModel.mode == .timezoneConverter {
                timezoneFocused = true
            } else {
                searchFocused = true
            }
        }
    }

    private func isWritingOutput(_ title: String) -> Bool {
        let clean = title.lowercased()
        return clean.contains("writing") || clean.contains("grammar")
    }

    private func activityStep(for message: String) -> Int {
        let clean = message.lowercased()
        if clean.contains("review") || clean.contains("format") || clean.contains("final") { return 2 }
        if clean.contains("correct") || clean.contains("check") || clean.contains("analy") { return 1 }
        return 0
    }
}

private struct EmojiPageButtonStyle: ButtonStyle {
    let disabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .limaFont(.system(size: 9, weight: .bold))
            .foregroundStyle(disabled ? Color.secondary.opacity(0.38) : Color.primary.opacity(0.85))
            .frame(width: 20, height: 20)
            .background(Color.white.opacity(configuration.isPressed ? 0.12 : 0.055), in: PrismaticPanelShape(cut: 4))
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
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
                        .limaFont(.system(size: 13, weight: .semibold))
                    Text(issue.kind.rawValue)
                        .limaFont(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.07), in: PrismaticPanelShape(cut: 4))
                }
                Text(issue.message)
                    .limaFont(.system(size: 12))
                    .foregroundStyle(.secondary)
                if !issue.suggestions.isEmpty {
                    Text("Suggestions: \(issue.suggestions.joined(separator: ", "))")
                        .limaFont(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .liquidGlass(cornerRadius: 12, depth: .recessed, accentOpacity: 0.010)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(issue.kind.rawValue): \(issue.original). \(issue.message)")
    }
}

private struct ResultRow: View {
    @ObservedObject private var settings = SettingsStore.shared
    let item: LauncherItem
    let selected: Bool
    let actionLabel: String?

    var body: some View {
        HStack(spacing: 10) {
            LauncherIconView(icon: item.icon, selected: selected)
                .frame(width: 27, height: 27)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .limaFont(.system(size: 13.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(Color.white.opacity(selected ? 1 : 0.92))
                    .lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .limaFont(.system(size: 11.25, weight: .regular))
                        .foregroundStyle(Color.white.opacity(selected ? 0.68 : 0.56))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 10)
            if let accessory = item.accessory {
                Text(accessory)
                    .limaFont(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .limaFont(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: PrismaticPanelShape(cut: 4))
                    .overlay(PrismaticPanelShape(cut: 4).stroke(Color.white.opacity(0.20), lineWidth: 0.6))
            }
            if selected, let actionLabel {
                HStack(spacing: 4) {
                    Text("↩")
                    Text(actionLabel)
                }
                .limaFont(.system(size: 10.25, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(SettingsStore.shared.accentTheme.gradient, in: PrismaticPanelShape(cut: 5))
                .overlay(PrismaticPanelShape(cut: 5).stroke(Color.white.opacity(0.35), lineWidth: 0.6))
                .shadow(color: SettingsStore.shared.accentTheme.primary.opacity(0.24), radius: 7, y: 3)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: settings.interfaceDensity.resultRowHeight)
        .background {
            if selected {
                ZStack {
                    PrismaticPanelShape(cut: 7).fill(.ultraThinMaterial)
                    PrismaticPanelShape(cut: 7)
                        .fill(SettingsStore.shared.accentTheme.gradient.opacity(0.09))
                }
            }
        }
        .overlay {
            if selected {
                PrismaticPanelShape(cut: 7)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.66), SettingsStore.shared.accentTheme.primary.opacity(0.36), Color.white.opacity(0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.85
                    )
            }
        }
        .shadow(color: selected ? SettingsStore.shared.accentTheme.primary.opacity(0.10) : .clear, radius: 11, y: 5)
        .opacity(selected ? 1 : 0.97)
        .scaleEffect(selected ? 1 : 0.998)
        .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.84), value: selected)
    }
}

private struct LauncherIconView: View {
    let icon: LauncherIcon
    let selected: Bool

    var body: some View {
        Group {
            switch icon {
            case .system(let name):
                Image(systemName: name)
                    .resizable()
                    .scaledToFit()
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(selected ? SettingsStore.shared.accentTheme.primary : Color.secondary)
                    .padding(7.5)
                    .background(.ultraThinMaterial, in: PrismaticPanelShape(cut: 5))
                    .overlay(
                        PrismaticPanelShape(cut: 5)
                            .stroke(Color.white.opacity(selected ? 0.34 : 0.14), lineWidth: 0.65)
                    )
            case .application(let url), .file(let url):
                Image(nsImage: LauncherIconCache.shared.image(for: url))
                    .resizable()
                    .scaledToFit()
            case .text(let text):
                Text(text).limaFont(.system(size: 23))
            }
        }
        .frame(width: 30, height: 30)
    }
}

private struct EmojiGridTile: View {
    let emoji: String
    let selected: Bool

    var body: some View {
        Text(emoji)
            .limaFont(.system(size: 27))
            .minimumScaleFactor(0.72)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .contentShape(PrismaticPanelShape(cut: 5))
            .background {
                PrismaticPanelShape(cut: 5)
                    .fill(selected ? AnyShapeStyle(SettingsStore.shared.accentTheme.gradient.opacity(0.18)) : AnyShapeStyle(Color.white.opacity(0.035)))
            }
            .overlay {
                PrismaticPanelShape(cut: 5)
                    .strokeBorder(
                        selected ? SettingsStore.shared.accentTheme.tertiary.opacity(0.78) : Color.white.opacity(0.10),
                        lineWidth: selected ? 1.1 : 0.6
                    )
            }
            .shadow(color: selected ? SettingsStore.shared.accentTheme.primary.opacity(0.18) : .clear, radius: 5, y: 2)
            .scaleEffect(selected ? 1.02 : 1)
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
                .limaFont(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.085), in: PrismaticPanelShape(cut: 4))
            Text(label).limaFont(.system(size: 10.5)).foregroundStyle(.secondary)
        }
    }
}

private struct StatusCapsule: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .limaFont(.system(size: 9.5, weight: .bold, design: .rounded))
            .tracking(0.6)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.11), in: PrismaticPanelShape(cut: 5))
            .overlay(PrismaticPanelShape(cut: 5).stroke(color.opacity(0.24), lineWidth: 0.8))
    }
}

private struct TaskOrbitView: View {
    let color: Color
    @State private var spinning = false
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(pulsing ? 0.08 : 0.16))
                .scaleEffect(pulsing ? 1.14 : 0.88)
            Circle()
                .trim(from: 0.08, to: 0.72)
                .stroke(
                    AngularGradient(colors: [color.opacity(0.05), color, RayColors.cyan], center: .center),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .padding(5)
            Image(systemName: "sparkles")
                .limaFont(.system(size: 11, weight: .bold))
                .foregroundStyle(color)
        }
        .onAppear {
            withAnimation(.linear(duration: 1.35).repeatForever(autoreverses: false)) { spinning = true }
            withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) { pulsing = true }
        }
        .accessibilityHidden(true)
    }
}

private struct ActivityTimeline: View {
    let activeStep: Int
    let isWriting: Bool

    private var labels: [String] {
        isWriting ? ["Capture", "Local correction", "Review"] : ["Prepare", "Run", "Finish"]
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                HStack(spacing: 7) {
                    ZStack {
                        Circle()
                            .fill(index <= activeStep ? RayColors.indigo : Color.primary.opacity(0.09))
                            .frame(width: 14, height: 14)
                        if index < activeStep {
                            Image(systemName: "checkmark")
                                .limaFont(.system(size: 7, weight: .bold))
                                .foregroundStyle(.white)
                        } else {
                            Circle()
                                .fill(index == activeStep ? Color.white : Color.secondary.opacity(0.45))
                                .frame(width: 4, height: 4)
                        }
                    }
                    Text(label)
                        .limaFont(.system(size: 10, weight: index == activeStep ? .semibold : .medium))
                        .foregroundStyle(index <= activeStep ? Color.primary : .secondary)
                }
                if index < labels.count - 1 {
                    Rectangle()
                        .fill(index < activeStep ? RayColors.indigo.opacity(0.6) : Color.primary.opacity(0.08))
                        .frame(height: 1)
                }
            }
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Current step: \(labels[activeStep])")
    }
}

@MainActor
private enum RayColors {
    static var indigo: Color { SettingsStore.shared.accentTheme.primary }
    static var violet: Color { SettingsStore.shared.accentTheme.secondary }
    static var cyan: Color { SettingsStore.shared.accentTheme.tertiary }
    static var heroGradient: LinearGradient { SettingsStore.shared.accentTheme.gradient }
    static let cardBackground = Color(nsColor: .controlBackgroundColor).opacity(0.78)
    static let selectionBackground = indigo.opacity(0.13)
}

private extension LauncherMode {
    var visualIdentity: String {
        switch self {
        case .root: return "root"
        case .files: return "files"
        case .timezoneConverter: return "timezone"
        case .forceQuitPicker: return "force-quit"
        case .emojiPicker: return "emoji"
        case .clipboard: return "clipboard"
        case .history: return "history"
        case .writingReview: return "writing-review"
        case .output: return "output"
        }
    }
}
