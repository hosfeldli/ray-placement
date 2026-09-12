import AppKit
import RayPlacementWriting
import SwiftUI

struct LauncherView: View {
    @ObservedObject var viewModel: LauncherViewModel
    @ObservedObject var terminalModel: DeveloperTerminalModel
    @ObservedObject var passwordGeneratorModel: PasswordGeneratorModel
    @ObservedObject var inlineExtensionSurfaceModel: InlineExtensionSurfaceModel
    @ObservedObject var formatterModel: FormatterWorkspaceModel
    @ObservedObject var extensionStoreModel: ExtensionStoreModel
    @ObservedObject var workflowModel: WorkflowEditorModel
    @ObservedObject var surfaceSessionController: LauncherSurfaceSessionController
    let onSurfaceInteraction: () -> Void
    let onPinSurface: (Bool) -> Void
    let onOpenSurfaceWorkspace: () -> Void
    let onPerformSurfacePrimaryAction: () -> Void
    @ObservedObject private var settings = SettingsStore.shared
    @FocusState private var searchFocused: Bool
    @FocusState private var timezoneFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredEmojiID: String?
    @State private var hoveredResultID: String?
    @State private var acceptedWritingIssueIDs: Set<String> = []
    @State private var rejectedWritingIssueIDs: Set<String> = []

    init(
        viewModel: LauncherViewModel,
        terminalModel: DeveloperTerminalModel,
        passwordGeneratorModel: PasswordGeneratorModel,
        inlineExtensionSurfaceModel: InlineExtensionSurfaceModel,
        formatterModel: FormatterWorkspaceModel,
        extensionStoreModel: ExtensionStoreModel,
        workflowModel: WorkflowEditorModel,
        surfaceSessionController: LauncherSurfaceSessionController,
        onSurfaceInteraction: @escaping () -> Void = {},
        onPinSurface: @escaping (Bool) -> Void = { _ in },
        onOpenSurfaceWorkspace: @escaping () -> Void = {},
        onPerformSurfacePrimaryAction: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.terminalModel = terminalModel
        self.passwordGeneratorModel = passwordGeneratorModel
        self.inlineExtensionSurfaceModel = inlineExtensionSurfaceModel
        self.formatterModel = formatterModel
        self.extensionStoreModel = extensionStoreModel
        self.workflowModel = workflowModel
        self.surfaceSessionController = surfaceSessionController
        self.onSurfaceInteraction = onSurfaceInteraction
        self.onPinSurface = onPinSurface
        self.onOpenSurfaceWorkspace = onOpenSurfaceWorkspace
        self.onPerformSurfacePrimaryAction = onPerformSurfacePrimaryAction
    }

    var body: some View {
        ZStack {
            LiquidGlassBackdrop(material: .hudWindow, blendingMode: .behindWindow, identityLayer: true)
            VStack(spacing: 5) {
                searchHeader
                content
                    .id(viewModel.mode.visualIdentity)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.975)).combined(with: .offset(y: 5)))
                footer
            }
        }
        .frame(
            width: LauncherPanelLayout.size(
                for: viewModel.mode,
                density: settings.interfaceDensity,
                resultCount: viewModel.results.count,
                query: viewModel.query
            ).width,
            height: LauncherPanelLayout.size(
                for: viewModel.mode,
                density: settings.interfaceDensity,
                resultCount: viewModel.results.count,
                query: viewModel.query
            ).height
        )
        // The shell is intentionally one continuous shape. The shadow is
        // applied after the clip so it remains outside the perimeter and does
        // not become a fuzzy second border.
        .background(
            LimaColors.windowBackground.opacity(0.90),
            in: RoundedRectangle(cornerRadius: LimaRadius.launcherWindow, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: LimaRadius.launcherWindow, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LimaRadius.launcherWindow, style: .continuous)
                .strokeBorder(LimaColors.border.opacity(0.92), lineWidth: LimaDesign.focusWidth)
        }
        .shadow(color: .black.opacity(0.14), radius: 12, y: 5)
        .tint(settings.accentTheme.readablePrimary)
        .limaAnimation(LimaDesign.spring(0.30), value: viewModel.mode.visualIdentity)
        .onAppear {
            if viewModel.mode == .terminal {
                terminalModel.startIfNeeded()
            } else {
                focusSearch()
            }
        }
        .onChange(of: viewModel.focusGeneration) { _ in
            if viewModel.mode != .terminal { focusSearch() }
        }
        .onChange(of: viewModel.mode.visualIdentity) { _ in
            if case .writingReview(let review) = viewModel.mode {
                acceptedWritingIssueIDs = Set(review.issues.map(\.id))
                rejectedWritingIssueIDs = []
            }
        }
        .onChange(of: viewModel.mode.visualIdentity) { _ in
            if viewModel.mode == .terminal {
                searchFocused = false
                timezoneFocused = false
                terminalModel.startIfNeeded()
            } else {
                focusSearch()
            }
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 10) {
            if viewModel.mode != .root {
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
                .help("Back to search")
            }

            if let title = viewModel.mode.title, viewModel.mode != .root {
                Text(title)
                    .limaFont(.system(size: 14, weight: .bold))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.right")
                    .limaFont(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }

            if viewModel.isTimezonePicker {
                Spacer()
                StatusCapsule(text: "OFFLINE", color: LimaLauncherPalette.cyan)
            } else if isDedicatedSurfaceMode {
                Spacer(minLength: 0)
            } else if isOutputMode {
                Text(outputHeaderText)
                    .limaFont(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if viewModel.mode != .terminal {
                TextField(viewModel.placeholder, text: $viewModel.query)
                    .textFieldStyle(.plain)
                    .limaFont(.system(size: 17, weight: .medium))
                    .focused($searchFocused)
                    .accessibilityLabel(viewModel.placeholder)
            } else {
                Spacer(minLength: 0)
            }

            if viewModel.mode != .terminal, viewModel.isSearching {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 20)
            } else if viewModel.mode != .terminal, !viewModel.query.isEmpty {
                Text("esc")
                    .limaFont(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: LimaRadius.compactControl, style: .continuous))
            }

            if isSurfaceMenuVisible {
                surfaceActionMenu
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 46)
        .liquidGlass(cornerRadius: LimaRadius.searchField, depth: .raised, accentOpacity: 0.024)
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    private var isDedicatedSurfaceMode: Bool {
        switch viewModel.mode {
        case .surface, .extensionSurface, .output, .writingReview:
            return true
        default:
            return false
        }
    }

    private var isSurfaceMenuVisible: Bool {
        guard viewModel.mode != .root, viewModel.mode != .terminal else { return false }
        return isDedicatedSurfaceMode || isPinEligible
    }

    private var isPinEligible: Bool {
        switch viewModel.mode {
        case .surface, .extensionSurface:
            return true
        default:
            return false
        }
    }

    private var surfaceCanPopOut: Bool {
        switch viewModel.mode {
        case .surface(let session): return session.surface.canPopOut
        case .extensionSurface(let session): return session.canPopOut
        default: return false
        }
    }

    private var surfaceActionMenu: some View {
        Menu {
            Button("Back to Search") {
                onSurfaceInteraction()
                viewModel.enter(.root)
            }
            if isPinEligible {
                Button(surfaceSessionController.isPinned ? "Unpin Surface" : "Keep Open") {
                    onSurfaceInteraction()
                    onPinSurface(!surfaceSessionController.isPinned)
                }
            }
            if surfaceCanPopOut {
                Divider()
                Button("Open Full Workspace") {
                    onSurfaceInteraction()
                    onOpenSurfaceWorkspace()
                }
            }
            if let action = surfacePrimaryActionTitle {
                Divider()
                Button(action) {
                    onSurfaceInteraction()
                    performSurfacePrimaryAction()
                }
            }
            if surfaceSupportsCopy {
                Button("Copy Result") {
                    onSurfaceInteraction()
                    copySurfaceResult()
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .limaFont(.system(size: 13, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 29, height: 29)
        }
        .menuStyle(.borderlessButton)
        .help("Surface actions")
        .accessibilityLabel("Surface actions")
    }

    private var surfacePrimaryActionTitle: String? {
        switch viewModel.mode {
        case .surface(let session):
            switch session.surface.id {
            case "formatter": return "Format"
            case "workflows": return "Run Workflow"
            default: return nil
            }
        case .extensionSurface(let session):
            if session.kind == .form { return "Run" }
            if session.kind == .generator { return "Regenerate" }
            return nil
        default:
            return nil
        }
    }

    private var surfaceSupportsCopy: Bool {
        switch viewModel.mode {
        case .surface(let session): return session.surface.id == "formatter"
        case .extensionSurface: return true
        case .output: return true
        default: return false
        }
    }

    private func performSurfacePrimaryAction() {
        onPerformSurfacePrimaryAction()
    }

    private func copySurfaceResult() {
        switch viewModel.mode {
        case .surface(let session) where session.surface.id == "formatter":
            formatterModel.copyOutput()
        case .extensionSurface(let session) where session.kind == .generator:
            passwordGeneratorModel.copy()
        case .extensionSurface(let session) where session.kind == .form:
            inlineExtensionSurfaceModel.copyOutput()
        case .output(_, let text, _):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        default: break
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.mode {
        case .picker(.timezone):
            timezoneConverterView
        case .writingReview(let review):
            writingReviewView(review)
        case .output(let title, let text, let state):
            outputView(title: title, text: text, state: state)
        case .surface(let session):
            inlineSurface(session)
        case .extensionSurface(let session):
            if session.kind == .generator && (session.id == "password-generator" || session.id.hasSuffix(".password-generator")) {
                PasswordGeneratorSurface(model: passwordGeneratorModel)
            } else if session.kind == .form, let form = inlineExtensionSurfaceModel.form {
                ExtensionFormView(model: form, showsHeader: false)
            } else {
                InlineExtensionSurfacePlaceholder(session: session)
            }
        case .terminal:
            DeveloperTerminalView(model: terminalModel)
        case .contextShelf:
            ContextShelfView(store: .shared)
        case .picker(.emoji):
            emojiGrid
        case .picker(.applications):
            resultList
        default:
            resultList
        }
    }

    @ViewBuilder
    private func inlineSurface(_ session: LauncherSurfaceSession) -> some View {
        switch session.id {
        case "formatter":
            FormatterWorkspaceView(model: formatterModel)
                .padding(10)
                .onChange(of: formatterModel.source) { _ in onSurfaceInteraction() }
                .onChange(of: formatterModel.kind) { _ in onSurfaceInteraction() }
                .onChange(of: formatterModel.style) { _ in onSurfaceInteraction() }
                .onChange(of: formatterModel.segmentEnding) { _ in onSurfaceInteraction() }
                .onChange(of: formatterModel.searchQuery) { _ in onSurfaceInteraction() }
        case "permissions":
            PermissionCenterView(center: .shared)
                .padding(.horizontal, 10)
                .onSurfaceInteraction(onSurfaceInteraction)
        case "extension-store":
            ExtensionStoreView(model: extensionStoreModel)
                .onChange(of: extensionStoreModel.query) { _ in onSurfaceInteraction() }
                .onSurfaceInteraction(onSurfaceInteraction)
        case "workflows":
            WorkflowEditorView(model: workflowModel)
                .onChange(of: workflowModel.selectedID) { _ in onSurfaceInteraction() }
                .onChange(of: workflowModel.commandFilter) { _ in onSurfaceInteraction() }
                .onSurfaceInteraction(onSurfaceInteraction)
        case "extension-development":
            ExtensionDevelopmentView()
                .onSurfaceInteraction(onSurfaceInteraction)
        default:
            InlineLauncherSurfacePlaceholder(session: session)
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
                        columns: Array(
                            repeating: GridItem(.flexible(minimum: 42, maximum: 64), spacing: 5),
                            count: LauncherViewModel.emojiGridColumnCount
                        ),
                        spacing: 5
                    ) {
                        ForEach(viewModel.emojiVisibleRange, id: \.self) { index in
                            let entry = viewModel.emojiMatches[index]
                            let isSelected = index == viewModel.selectedIndex
                            let isHovered = entry.id == hoveredEmojiID
                            Button {
                                viewModel.executeEmoji(at: index)
                            } label: {
                                EmojiGridTile(
                                    emoji: entry.emoji,
                                    selected: isSelected,
                                    hovered: isHovered
                                )
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .contentShape(Rectangle())
                            .onHover { hovering in
                                if hovering {
                                    hoveredEmojiID = entry.id
                                } else if hoveredEmojiID == entry.id {
                                    hoveredEmojiID = nil
                                }
                            }
                            .accessibilityLabel(entry.name)
                            .accessibilityValue(isSelected ? "Selected" : "")
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                            .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                }
                .onChange(of: viewModel.navigationGeneration) { _ in
                    let newIndex = viewModel.selectedIndex
                    guard viewModel.emojiMatches.indices.contains(newIndex) else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                        proxy.scrollTo(viewModel.emojiMatches[newIndex].id, anchor: .center)
                    }
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
                    Text("Try another name or clear the search")
                        .limaFont(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
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
                    if viewModel.mode == .root,
                       viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       viewModel.contextualSelectionText == nil {
                        idleLauncherHeader
                    } else if viewModel.mode == .root, viewModel.contextualSelectionText != nil {
                        contextualSelectionHeader
                    }

                    LazyVStack(spacing: 3) {
                        ForEach(Array(viewModel.results.enumerated()), id: \.element.id) { index, item in
                        if viewModel.isActionable(item) {
                            Button {
                                onSurfaceInteraction()
                                viewModel.select(index)
                                viewModel.executeSelected()
                            } label: {
                                ResultRow(
                                    item: item,
                                    selected: index == viewModel.selectedIndex,
                                    actionLabel: actionLabel(for: item),
                                    hovered: hoveredResultID == item.id
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(accessibilityLabel(for: item)))
                            .accessibilityHint(Text("Press to \(actionLabel(for: item).lowercased())"))
                            .accessibilityValue(Text(index == viewModel.selectedIndex ? "Selected" : ""))
                            .accessibilityAddTraits(index == viewModel.selectedIndex ? .isSelected : [])
                            .id(item.id)
                            .onHover { hovering in
                                hoveredResultID = hovering ? item.id : (hoveredResultID == item.id ? nil : hoveredResultID)
                            }
                        } else {
                            ResultRow(item: item, selected: false, actionLabel: nil, hovered: hoveredResultID == item.id)
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
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                    proxy.scrollTo(viewModel.results[newIndex].id, anchor: .center)
                }
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var idleLauncherHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Ready when you are")
                .limaFont(LimaTypography.sectionTitle)
                .foregroundStyle(LimaColors.primaryText)
            Text("Recent and favorite actions")
                .limaFont(LimaTypography.body)
                .foregroundStyle(LimaColors.secondaryText)
        }
        .padding(.horizontal, 11)
        .padding(.top, 8)
        .padding(.bottom, 1)
        .accessibilityElement(children: .combine)
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
                    .foregroundStyle(SettingsStore.shared.accentTheme.readableTertiary)
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
                    TaskOrbitView(color: isWritingOutput(title) ? LimaLauncherPalette.violet : LimaLauncherPalette.cyan)
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(title).limaFont(.system(size: 16, weight: .bold))
                            StatusCapsule(text: isWritingOutput(title) ? "LOCAL RULES" : "RUNNING", color: isWritingOutput(title) ? LimaLauncherPalette.violet : LimaLauncherPalette.cyan)
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
                        .foregroundStyle(settings.accentTheme.onGradient)
                        .frame(width: 38, height: 38)
                        .background(LimaLauncherPalette.heroGradient, in: Circle())
                        .shadow(color: LimaLauncherPalette.indigo.opacity(0.28), radius: 9, y: 4)
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
                .limaButton(prominent: true)
                .tint(LimaLauncherPalette.readableIndigo)
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
                    .foregroundStyle(isSource ? LimaLauncherPalette.readableIndigo : LimaLauncherPalette.readableCyan)
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
        let effectiveReview = review.applying(acceptedWritingIssueIDs, rejecting: rejectedWritingIssueIDs)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill((review.issues.isEmpty ? Color.green : LimaLauncherPalette.violet).opacity(0.14))
                    Image(systemName: review.issues.isEmpty ? "checkmark" : "wand.and.stars")
                        .limaFont(.system(size: 16, weight: .bold))
                        .foregroundStyle(review.issues.isEmpty ? Color.green : LimaLauncherPalette.readableViolet)
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(review.issues.isEmpty ? "Your writing is ready" : "Correction ready")
                        .limaFont(.system(size: 16, weight: .bold))
                    Text("\(review.sourceText.count) selected characters · \(activeWritingModelTitle)")
                        .limaFont(.caption)
                        .foregroundStyle(.secondary)
                    if let status = review.status {
                        Text(status)
                            .limaFont(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                Button("Copy \(effectiveReview.hasSuggestedChanges ? "Suggested" : "Text")") {
                    viewModel.copyWritingResult(effectiveReview)
                }
                .limaButton()
                .accessibilityHint("Copies the reviewed text")
                Button("Replace \(effectiveReview.hasSuggestedChanges ? "Selection" : "Selected Text")") {
                    viewModel.pasteWritingResult(effectiveReview)
                }
                .limaButton(prominent: true)
                .tint(LimaLauncherPalette.readableIndigo)
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
                            title: effectiveReview.hasSuggestedChanges ? "CORRECTED TEXT" : "CHECKED TEXT",
                            text: effectiveReview.hasSuggestedChanges ? effectiveReview.suggestedText : effectiveReview.sourceText,
                            color: effectiveReview.hasSuggestedChanges ? LimaLauncherPalette.violet : .green,
                            symbol: effectiveReview.hasSuggestedChanges ? "wand.and.stars" : "checkmark.circle.fill"
                        )
                    }

                    if !review.issues.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("REVIEW EACH CHANGE")
                                .limaFont(.system(size: 9, weight: .bold))
                                .tracking(1.0)
                                .foregroundStyle(.secondary)
                            ForEach(review.issues) { issue in
                                WritingIssueDecisionRow(
                                    issue: issue,
                                    accepted: acceptedWritingIssueIDs.contains(issue.id) && !rejectedWritingIssueIDs.contains(issue.id),
                                    onAccept: {
                                        acceptedWritingIssueIDs.insert(issue.id)
                                        rejectedWritingIssueIDs.remove(issue.id)
                                    },
                                    onReject: {
                                        acceptedWritingIssueIDs.remove(issue.id)
                                        rejectedWritingIssueIDs.insert(issue.id)
                                    }
                                )
                            }
                        }
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
        SettingsStore.shared.grammarEngineMode == .externalAPI ? "External API" : "Python + Harper"
    }

    @ViewBuilder
    private var footer: some View {
        if viewModel.mode == .terminal {
            HStack {
                Spacer()
                KeyHint(keys: "esc", label: "Back to search")
            }
            .padding(.horizontal, 13)
            .frame(height: 27)
            .padding(.bottom, 5)
        } else if viewModel.mode == .root {
            HStack(spacing: 12) {
                LimaStatusLine(
                    "\(viewModel.results.count) available",
                    symbol: "circle.grid.2x2.fill",
                    tint: SettingsStore.shared.accentTheme.tertiary,
                    compact: true
                )
                .frame(maxWidth: 160)
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
                    } else if case .extensionSurface(let session) = viewModel.mode {
                        KeyHint(keys: "⌘R", label: session.kind == .form ? "Run again" : "Regenerate")
                        KeyHint(keys: "⌘C", label: "Copy")
                        KeyHint(keys: "↩", label: session.kind == .form ? "Run" : "Copy")
                    } else if case .surface(let session) = viewModel.mode {
                        if session.surface.id == "formatter" || session.surface.id == "workflows" {
                            KeyHint(keys: "⌘R", label: session.surface.id == "formatter" ? "Format" : "Run")
                        }
                        if session.surface.id == "formatter" { KeyHint(keys: "⌘C", label: "Copy") }
                        if session.surface.canPopOut { KeyHint(keys: "⌘O", label: "Open in Window") }
                        KeyHint(keys: "↩", label: session.surface.id == "formatter" ? "Format" : session.surface.id == "workflows" ? "Run" : "Open")
                    }
                    if viewModel.selectedItemIsActionable, !isOutputMode {
                        KeyHint(keys: "↩", label: primaryActionLabel)
                    }
                    if let remaining = surfaceSessionController.secondsRemaining,
                       remaining < 5,
                       !surfaceSessionController.isPinned {
                        KeyHint(keys: "", label: "Search in \(max(1, Int(ceil(remaining))))s")
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
        case .output, .writingReview, .extensionSurface: return true
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
        case .running: return settings.accentTheme.primary
        case .success: return .green
        case .error: return .orange
        }
    }

    private var primaryActionLabel: String {
        guard let action = viewModel.selectedItem?.action else { return "Run" }
        switch action {
        case .launchApplication, .openFile, .fileAction(_, .open), .openURL: return "Open"
        case .copyText: return "Copy"
        case .pasteText: return "Paste"
        case .replaceSelectedText: return "Replace"
        case .saveSelectionToQuickNote: return "Save"
        case .checkSelectedText: return "Review"
        case .applicationOperation: return "Review"
        case .enterMode: return "Enter"
        default: return "Run"
        }
    }

    private func actionLabel(for item: LauncherItem) -> String {
        switch item.action {
        case .launchApplication, .openFile, .fileAction(_, .open), .openURL: return "Open"
        case .copyText: return "Copy"
        case .pasteText: return "Paste"
        case .replaceSelectedText: return "Replace"
        case .saveSelectionToQuickNote: return "Save"
        case .checkSelectedText: return "Review"
        case .applicationOperation: return "Review"
        case .enterMode: return "Enter"
        default: return "Run"
        }
    }

    private func accessibilityLabel(for item: LauncherItem) -> String {
        item.subtitle.isEmpty ? item.title : "\(item.title), \(item.subtitle)"
    }

    private func focusSearch() {
        guard !isOutputMode, viewModel.mode != .terminal else { return }
        DispatchQueue.main.async {
            if viewModel.isTimezonePicker {
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
            .background(configuration.isPressed ? LimaColors.hoverFill : LimaColors.recessedSurface, in: RoundedRectangle(cornerRadius: LimaRadius.small, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LimaRadius.small, style: .continuous).stroke(LimaColors.border, lineWidth: LimaDesign.borderWidth))
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
    }
}

private struct WritingIssueRow: View {
    let issue: WritingIssue

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: issue.kind == .spelling ? "character.cursor.ibeam" : "text.badge.checkmark")
                .foregroundStyle(issue.kind == .spelling ? Color.orange : SettingsStore.shared.accentTheme.readablePrimary)
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

private struct WritingIssueDecisionRow: View {
    let issue: WritingIssue
    let accepted: Bool
    let onAccept: () -> Void
    let onReject: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: accepted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(accepted ? .green : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(issue.original).limaFont(.system(size: 12.5, weight: .semibold))
                    Text("→")
                    Text(issue.suggestions.first ?? "No replacement")
                        .limaFont(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(accepted ? .green : .secondary)
                }
                Text(issue.message).limaFont(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Keep") { onAccept() }
                .buttonStyle(.borderless)
                .foregroundStyle(accepted ? .green : .secondary)
            Button("Reject") { onReject() }
                .buttonStyle(.borderless)
                .foregroundStyle(!accepted ? .orange : .secondary)
        }
        .padding(9)
        .background(LimaColors.recessedSurface, in: RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous).stroke(LimaColors.border, lineWidth: LimaDesign.borderWidth))
    }
}

private struct ResultRow: View {
    @ObservedObject private var settings = SettingsStore.shared
    let item: LauncherItem
    let selected: Bool
    let actionLabel: String?
    let hovered: Bool

    var body: some View {
        HStack(spacing: 10) {
            LauncherIconView(icon: item.icon, selected: selected)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .limaFont(.system(size: 13.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(LimaColors.primaryText)
                    .lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .limaFont(.system(size: 11.25))
                        .foregroundStyle(LimaColors.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 10)
            if let accessory = item.accessory {
                Text(accessory)
                    .limaFont(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(LimaColors.secondaryText)
            }
            if let shortcut = item.shortcut { LimaShortcutBadge(text: shortcut) }
            if selected, let actionLabel {
                HStack(spacing: 4) {
                    Text("↩")
                    Text(actionLabel)
                }
                .limaFont(.system(size: 10.25, weight: .bold, design: .rounded))
                .foregroundStyle(settings.accentTheme.onPrimary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(settings.accentTheme.primary, in: RoundedRectangle(cornerRadius: LimaRadius.small, style: .continuous))
            }
        }
        .padding(.horizontal, 11)
        .frame(height: settings.interfaceDensity.resultRowHeight)
        .limaSelection(selected, hovered: hovered, radius: LimaRadius.control)
        .animation(nil, value: selected)
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
                    .foregroundStyle(selected ? SettingsStore.shared.accentTheme.readablePrimary : Color.secondary)
                    .padding(7.5)
                    .background(selected ? LimaColors.selectedFill : LimaColors.recessedSurface, in: RoundedRectangle(cornerRadius: LimaRadius.small, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: LimaRadius.small, style: .continuous)
                            .stroke(selected ? LimaColors.focusedBorder : LimaColors.border, lineWidth: LimaDesign.borderWidth)
                    }
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
    let hovered: Bool

    var body: some View {
        Text(emoji)
            .limaFont(.system(size: 30))
            .minimumScaleFactor(0.72)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
            .background(selected ? LimaColors.selectedFill : (hovered ? LimaColors.hoverFill : .clear), in: RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous)
                        .strokeBorder(LimaColors.accent, lineWidth: LimaDesign.focusWidth)
                }
            }
            .animation(LimaMotion.quick, value: selected)
            .animation(LimaMotion.quick, value: hovered)
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
                .background(LimaColors.recessedSurface, in: RoundedRectangle(cornerRadius: LimaRadius.small, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: LimaRadius.small, style: .continuous).stroke(LimaColors.border, lineWidth: LimaDesign.borderWidth))
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
            .overlay(PrismaticPanelShape(cut: 5).stroke(color.opacity(0.24), lineWidth: LimaDesign.borderWidth))
    }
}

private struct TaskOrbitView: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false
    @State private var pulsing = false

    private var motionAllowed: Bool {
        !reduceMotion && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(pulsing ? 0.08 : 0.16))
                .scaleEffect(pulsing ? 1.14 : 0.88)
            Circle()
                .trim(from: 0.08, to: 0.72)
                .stroke(
                    AngularGradient(colors: [color.opacity(0.05), color, LimaLauncherPalette.cyan], center: .center),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .padding(5)
            Image(systemName: "sparkles")
                .limaFont(.system(size: 11, weight: .bold))
                .foregroundStyle(color)
        }
        .onAppear {
            guard motionAllowed else { return }
            withAnimation(.linear(duration: 1.35).repeatForever(autoreverses: false)) { spinning = true }
            withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) { pulsing = true }
        }
        .onChange(of: reduceMotion) { isReduced in
            if isReduced {
                spinning = false
                pulsing = false
            } else if motionAllowed {
                withAnimation(.linear(duration: 1.35).repeatForever(autoreverses: false)) { spinning = true }
                withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) { pulsing = true }
            }
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
                            .fill(index <= activeStep ? LimaLauncherPalette.indigo : Color.primary.opacity(0.09))
                            .frame(width: 14, height: 14)
                        if index < activeStep {
                            Image(systemName: "checkmark")
                                .limaFont(.system(size: 7, weight: .bold))
                                .foregroundStyle(LimaColors.primaryText)
                        } else {
                            Circle()
                                .fill(index == activeStep ? LimaColors.primaryText : Color.secondary.opacity(0.45))
                                .frame(width: 4, height: 4)
                        }
                    }
                    Text(label)
                        .limaFont(.system(size: 10, weight: index == activeStep ? .semibold : .medium))
                        .foregroundStyle(index <= activeStep ? Color.primary : .secondary)
                }
                if index < labels.count - 1 {
                    Rectangle()
                        .fill(index < activeStep ? LimaLauncherPalette.indigo.opacity(0.6) : Color.primary.opacity(0.08))
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
private enum LimaLauncherPalette {
    static var indigo: Color { SettingsStore.shared.accentTheme.primary }
    static var violet: Color { SettingsStore.shared.accentTheme.secondary }
    static var cyan: Color { SettingsStore.shared.accentTheme.tertiary }
    static var readableIndigo: Color { SettingsStore.shared.accentTheme.readablePrimary }
    static var readableViolet: Color { SettingsStore.shared.accentTheme.readableSecondary }
    static var readableCyan: Color { SettingsStore.shared.accentTheme.readableTertiary }
    static var heroGradient: LinearGradient { SettingsStore.shared.accentTheme.gradient }
    static let cardBackground = Color(nsColor: .controlBackgroundColor).opacity(0.78)
    static let selectionBackground = indigo.opacity(0.13)
}

private extension View {
    func onSurfaceInteraction(_ action: @escaping () -> Void) -> some View {
        simultaneousGesture(TapGesture().onEnded { action() })
            .simultaneousGesture(
                DragGesture(minimumDistance: 2).onEnded { _ in action() }
            )
    }
}

private struct InlineLauncherSurfacePlaceholder: View {
    let session: LauncherSurfaceSession

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.inset.filled")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(SettingsStore.shared.accentTheme.readablePrimary)
            Text(session.surface.title).limaFont(.headline.weight(.semibold))
            Text("This tool is running inside Lima's central launcher.")
                .limaFont(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: max(180, session.surface.preferredSize.height - 130))
        .padding(20)
    }
}

private struct InlineExtensionSurfacePlaceholder: View {
    let session: ExtensionSurfaceSession

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(SettingsStore.shared.accentTheme.readablePrimary)
            Text(session.title)
                .limaFont(.headline.weight(.semibold))
            Text("This inline extension surface is ready for its form or output specification.")
                .limaFont(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: max(180, session.preferredHeight - 130))
        .padding(20)
    }

    private var symbol: String {
        switch session.kind {
        case .form: return "rectangle.and.pencil.and.ellipsis"
        case .generator: return "sparkles"
        case .picker: return "line.3.horizontal.decrease.circle"
        case .textTool: return "text.cursor"
        case .liveOutput: return "terminal"
        }
    }
}

private extension LauncherMode {
    var visualIdentity: String {
        switch self {
        case .root: return "root"
        case .files: return "files"
        case .picker(.timezone): return "picker-timezone"
        case .picker(.applications): return "picker-applications"
        case .picker(.displays): return "picker-displays"
        case .picker(.emoji): return "picker-emoji"
        case .clipboard: return "clipboard"
        case .history: return "history"
        case .terminal: return "terminal"
        case .contextShelf: return "context-shelf"
        case .writingReview: return "writing-review"
        case .extensionSurface(let session): return "extension-\(session.id)"
        case .surface(let session): return "surface-\(session.id)"
        case .output: return "output"
        }
    }
}
