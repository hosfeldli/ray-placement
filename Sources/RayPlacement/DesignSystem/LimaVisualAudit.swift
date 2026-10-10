#if DEBUG
import AppKit
import RayPlacementCore
import RayPlacementWriting
import SwiftUI

/// Offscreen renders only. No AppDelegate, screenshots of other apps, live AI,
/// microphone, terminal session, or global shortcut registration.
@MainActor
enum LimaVisualAudit {
    static func run(application: NSApplication, directory: URL) {
        guard LimaTestEnvironment.isEnabled else {
            fputs("Visual audit requires LIMA_TEST_MODE=1\n", stderr)
            exit(1)
        }
        application.setActivationPolicy(.prohibited)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch { fputs("Cannot create visual audit output\n", stderr); exit(1) }

        Task { @MainActor in
            var failures = 0
            for dark in [false, true] {
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
                application.appearance = appearance
                let modes: [LimaUIPreviewMode] = [
                    .launcherResults, .notes, .formatter, .settingsGeneral,
                    .extensions, .dictationRecording, .confirmation, .toast,
                    .aiConversation, .aiEmpty, .aiApproval, .aiFailure
                ]
                for mode in modes {
                    let view = LimaUIPreviewGallery(mode: mode)
                        .environment(\.colorScheme, dark ? .dark : .light)
                    if !(await render(view, size: mode.size, appearance: appearance,
                                      url: directory.appendingPathComponent("\(mode.rawValue)-\(dark ? "dark" : "light").png"))) {
                        failures += 1
                    }
                }
                for module: LimaWorkspaceModule in [.home, .notes, .ai, .extensions] {
                    for width: CGFloat in [420, 800, 1240] {
                        let view = LimaMockupWorkspaceFixtures.workspace(module, compact: width < 720)
                            .environment(\.colorScheme, dark ? .dark : .light)
                        if !(await render(view, size: NSSize(width: width, height: 780), appearance: appearance,
                                          url: directory.appendingPathComponent("production-\(module.rawValue)-\(Int(width))-\(dark ? "dark" : "light").png"))) {
                            failures += 1
                        }
                    }
                }
                for width: CGFloat in [420, 800, 1040] {
                    let search = LauncherSearchAuditFixtures.view()
                        .environment(\.colorScheme, dark ? .dark : .light)
                    if !(await render(search, size: NSSize(width: width, height: 700), appearance: appearance,
                                      url: directory.appendingPathComponent("production-search-\(Int(width))-\(dark ? "dark" : "light").png"))) {
                        failures += 1
                    }
                }
                for scenario in ["filtered", "empty", "selection", "actions"] {
                    let search = LauncherSearchAuditFixtures.view(scenario: scenario)
                        .environment(\.colorScheme, dark ? .dark : .light)
                    if !(await render(search, size: NSSize(width: 1040, height: 700), appearance: appearance,
                                      url: directory.appendingPathComponent("production-search-\(scenario)-\(dark ? "dark" : "light").png"))) {
                        failures += 1
                    }
                }
                let smallSearch = LauncherSearchAuditFixtures.view()
                    .environment(\.colorScheme, dark ? .dark : .light)
                if !(await render(smallSearch, size: NSSize(width: 640, height: 480), appearance: appearance,
                                  url: directory.appendingPathComponent("production-search-short-\(dark ? "dark" : "light").png"))) {
                    failures += 1
                }
                let preferences = LimaMockupWorkspaceFixtures.settings()
                    .environment(\.colorScheme, dark ? .dark : .light)
                if !(await render(preferences, size: NSSize(width: 1060, height: 780), appearance: appearance,
                                  url: directory.appendingPathComponent("production-settings-\(dark ? "dark" : "light").png"))) {
                    failures += 1
                }
                let original = "This are a local writing review. Keep every change reviewable."
                let issue = WritingIssue(kind: .grammar, range: NSRange(location: 5, length: 3),
                                         original: "are", message: "Use a singular verb with this subject.", suggestions: ["is"])
                let review = WritingReview(sourceText: original, suggestedText: original, issues: [issue])
                for width: CGFloat in [420, 1040] {
                    let grammarReview = GrammarWorkspaceView(visualReview: review)
                        .environment(\.colorScheme, dark ? .dark : .light)
                    if !(await render(grammarReview, size: NSSize(width: width, height: 780), appearance: appearance,
                                      url: directory.appendingPathComponent("grammar-review-\(Int(width))-\(dark ? "dark" : "light").png"))) {
                        failures += 1
                    }
                }
                for scenario: AIChatVisualScenario in [.streaming, .failure, .quota, .timeout, .markdown] {
                    let widths: [CGFloat] = [.failure, .quota, .timeout].contains(scenario)
                        ? [420, 600, 1040] : [420, 1040]
                    for width in widths {
                        let ai = AIChatVisualPreview(scenario: scenario)
                            .environment(\.colorScheme, dark ? .dark : .light)
                        if !(await render(ai, size: NSSize(width: width, height: 700), appearance: appearance,
                                          url: directory.appendingPathComponent("functional-\(scenario.rawValue)-\(Int(width))-\(dark ? "dark" : "light").png"))) {
                            failures += 1
                        }
                    }
                }
                let memoryStore = AIWorkspaceStore(fixtures: [], memories: [
                    AIMemory(title: "Writing preference", content: "Prefer concise updates and preserve technical terminology."),
                    AIMemory(title: "Release workflow", content: "Keep release assets immutable and validate before publication.")
                ])
                let memoryModel = AIChatViewModel(store: AIConversationStore(fixtures: []),
                    credentials: AIChatCredentialStore(configuration: .fixture),
                    nativeToolStore: LimaAIToolStore(fixtures: AIContextTools.ids),
                    transport: FixtureAITransport.standard, workspaceStore: memoryStore)
                let memory = AIMemoryInspector(model: memoryModel, store: memoryStore,
                    tools: memoryModel.nativeToolStore, initiallyExpanded: true)
                    .padding(14).environment(\.colorScheme, dark ? .dark : .light)
                if !(await render(memory, size: NSSize(width: 300, height: 560), appearance: appearance,
                                  url: directory.appendingPathComponent("functional-memory-\(dark ? "dark" : "light").png"))) {
                    failures += 1
                }
                let previewNotes = [
                    MarkdownNote(title: "Release checklist", content: "# Release checklist\n\n- [x] Run the test suite\n- [ ] Review the final build"),
                    MarkdownNote(title: "Workspace notes", content: "Keep project decisions close to the work."),
                    MarkdownNote(title: "Ideas for later", content: "A small, searchable place for the next thought.", isPinned: true)
                ]
                let previewConversations = AIConversationStore(fixtures: [
                    AIConversation(title: "Browser integration", messages: [
                        AIChatMessage(role: .user, text: "Review the navigation-only browser scope.")
                    ])
                ])
                let home = HomeWorkspaceView(
                    store: NotesStore(visualFixtures: previewNotes),
                    conversations: previewConversations,
                    open: { _ in },
                    openConversation: { _ in },
                    startNoteDictation: {},
                    openCommandSearch: { _ in }
                )
                    .environment(\.colorScheme, dark ? .dark : .light)
                if !(await render(home, size: NSSize(width: 1040, height: 700), appearance: appearance,
                                  url: directory.appendingPathComponent("workspace-home-\(dark ? "dark" : "light").png"))) {
                    failures += 1
                }
                let clipboard = ClipboardWorkspaceView(service: ClipboardHistoryService.shared, openSettings: {})
                    .environment(\.colorScheme, dark ? .dark : .light)
                if !(await render(clipboard, size: NSSize(width: 1040, height: 700), appearance: appearance,
                                  url: directory.appendingPathComponent("workspace-clipboard-\(dark ? "dark" : "light").png"))) {
                    failures += 1
                }
                for width: CGFloat in [420, 600, 1040] {
                    let grammar = GrammarWorkspaceView()
                        .environment(\.colorScheme, dark ? .dark : .light)
                    if !(await render(grammar, size: NSSize(width: width, height: 700), appearance: appearance,
                                      url: directory.appendingPathComponent("workspace-grammar-\(Int(width))-\(dark ? "dark" : "light").png"))) {
                        failures += 1
                    }
                }
                for width: CGFloat in [420, 600, 1040] {
                    let ai = WayfinderAuditAI()
                        .environment(\.colorScheme, dark ? .dark : .light)
                    if !(await render(ai, size: NSSize(width: width, height: 700), appearance: appearance,
                                      url: directory.appendingPathComponent("workspace-ai-\(Int(width))-\(dark ? "dark" : "light").png"))) {
                        failures += 1
                    }
                    let view = WayfinderAuditWorkspace()
                        .environment(\.colorScheme, dark ? .dark : .light)
                    if !(await render(view, size: NSSize(width: width, height: 640), appearance: appearance,
                                      url: directory.appendingPathComponent("wayfinder-\(Int(width))-\(dark ? "dark" : "light").png"))) {
                        failures += 1
                    }
                }
            }
            let accessible = WayfinderAuditWorkspace()
                .environment(\.colorScheme, .light)

            if !(await render(accessible, size: NSSize(width: 1040, height: 640),
                              appearance: NSAppearance(named: .accessibilityHighContrastAqua)!,
                              url: directory.appendingPathComponent("wayfinder-accessible.png"))) {
                failures += 1
            }
            print("Visual audit finished: \(failures) failed renders")
            exit(failures == 0 ? 0 : 1)
        }
        application.run()
    }

    private static func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance, url: URL) async -> Bool {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        let host = NSHostingView(rootView: LimaTypographyRoot(content: view))
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(180))
        host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        do { try png.write(to: url); return true } catch { return false }
    }
}

private struct WayfinderAuditWorkspace: View {
    @State private var navigation: LimaWorkspaceNavigation = {
        var value = LimaWorkspaceNavigation()
        value.select(.ai)
        value.select(.notes)
        return value
    }()
    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                LimaWayfinderRail(current: navigation.current, previous: navigation.previous,
                                  sizeClass: .classify(width: proxy.size.width),
                                  select: { navigation.select($0) }, openSettings: {},
                                  isDocked: false, openInWindow: {})
                Divider()
                VStack(alignment: .leading, spacing: 16) {
                    LimaToolbarTitle(symbol: navigation.current.symbol, title: navigation.current.title, subtitle: "Workspace")
                    Divider()
                    Text("A place to think. A shortcut to act.").limaFont(.title2.weight(.semibold))
                    Text("TEST DATA · Production navigation and shared components")
                        .limaFont(.caption).foregroundStyle(LimaTheme.textSecondary)
                    LimaSectionLabel("Working set", detail: "Pick up where you left off")
                    ForEach(["Release checklist", "Project notes", "Ideas for later"], id: \.self) { title in
                        LimaListRow(selected: title == "Release checklist") {
                            Image(systemName: "note.text")
                        } content: {
                            Text(title).limaFont(.body)
                        } trailing: {
                            Image(systemName: "chevron.right").foregroundStyle(LimaTheme.textSecondary)
                        }
                    }
                    Spacer()
                    LimaStatusLine("Ready", symbol: "checkmark.circle", tint: LimaTheme.accentInk,
                                   detail: "⌥⌘1–9 Switch · ⌥⌘0 Return")
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(LimaTheme.surfacePrimary)
            }
            .background(LimaTheme.windowBackground)
        }
    }
}

private struct WayfinderAuditAI: View {
    var body: some View {
        GeometryReader { proxy in
            let sizeClass = LimaWorkspaceSizeClass.classify(width: proxy.size.width)
            HStack(spacing: 0) {
                LimaWayfinderRail(current: .ai, previous: .notes, sizeClass: sizeClass,
                                  select: { _ in }, openSettings: {}, isDocked: true, openInWindow: {})
                Divider()
                AIChatVisualPreview(scenario: .conversation)
            }
            .environment(\.limaWorkspaceSizeClass, sizeClass)
        }
    }
}
#endif
