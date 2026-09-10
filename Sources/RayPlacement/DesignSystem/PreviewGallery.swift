#if DEBUG
import AppKit
import SwiftUI

/// Deterministic, side-effect-free visual samples. These views intentionally do
/// not construct AppDelegate, SettingsStore, hot keys, update services,
/// Accessibility automation, credentials, or dictation services.
enum LimaUIPreviewMode: String, CaseIterable {
    case launcher
    case launcherResults = "launcher-results"
    case launcherIdleLight = "launcher-idle-light"
    case launcherResultsLight = "launcher-results-light"
    case launcherIdleDark = "launcher-idle-dark"
    case emoji
    case settings
    case extensions
    case notes
    case formatter
    case dictationRecording = "dictation-recording"
    case dictationTranscribing = "dictation-transcribing"
    case dictationCompleted = "dictation-completed"
    case settingsGeneral = "settings-general"
    case settingsWritingLocal = "settings-writing-local"
    case settingsWritingEnhanced = "settings-writing-enhanced"
    case settingsPrivacy = "settings-privacy"
    case confirmation
    case toast

    var title: String {
        switch self {
        case .launcher, .launcherIdleLight, .launcherIdleDark: return "Launcher Preview"
        case .launcherResults, .launcherResultsLight: return "Launcher Results Preview"
        case .emoji: return "Emoji Picker Preview"
        case .settings: return "Settings Preview"
        case .extensions: return "Extensions Preview"
        case .notes: return "Notes Preview"
        case .formatter: return "Formatter Preview"
        case .dictationRecording, .dictationTranscribing, .dictationCompleted: return "Dictation Preview"
        case .settingsGeneral, .settingsWritingLocal, .settingsWritingEnhanced, .settingsPrivacy: return "Settings Preview"
        case .confirmation: return "Confirmation Preview"
        case .toast: return "Toast Preview"
        }
    }

    var size: NSSize {
        switch self {
        case .launcherIdleLight, .launcherIdleDark: return NSSize(width: 704, height: 330)
        case .launcher, .launcherResults, .launcherResultsLight: return NSSize(width: 704, height: 466)
        case .emoji: return NSSize(width: 704, height: 520)
        case .settings: return NSSize(width: 820, height: 590)
        case .extensions: return NSSize(width: 820, height: 590)
        case .notes: return NSSize(width: 1_020, height: 700)
        case .formatter: return NSSize(width: 1_020, height: 690)
        case .dictationRecording, .dictationTranscribing, .dictationCompleted: return NSSize(width: 560, height: 360)
        case .settingsGeneral, .settingsWritingLocal, .settingsWritingEnhanced, .settingsPrivacy: return NSSize(width: 820, height: 590)
        case .confirmation: return NSSize(width: 520, height: 330)
        case .toast: return NSSize(width: 520, height: 300)
        }
    }
}

struct LimaUIPreviewGallery: View {
    let mode: LimaUIPreviewMode

    var body: some View {
        switch mode {
        case .launcher, .launcherIdleLight:
            PreviewLauncher(results: false)
        case .launcherResults, .launcherResultsLight:
            PreviewLauncher(results: true)
        case .launcherIdleDark:
            PreviewLauncher(results: false)
                .preferredColorScheme(.dark)
        case .emoji:
            PreviewEmojiPicker()
        case .settings:
            PreviewSettings()
        case .settingsGeneral:
            PreviewSettings(initialSelection: 0, variant: "general")
        case .settingsWritingLocal:
            PreviewSettings(initialSelection: 2, variant: "writing-local")
        case .settingsWritingEnhanced:
            PreviewSettings(initialSelection: 2, variant: "writing-enhanced")
        case .settingsPrivacy:
            PreviewSettings(initialSelection: 5, variant: "privacy")
        case .extensions:
            PreviewExtensions()
        case .notes:
            PreviewNotes()
        case .formatter:
            PreviewFormatter()
        case .dictationRecording:
            PreviewDictation(state: .recording)
        case .dictationTranscribing:
            PreviewDictation(state: .transcribing)
        case .dictationCompleted:
            PreviewDictation(state: .completed)
        case .confirmation:
            PreviewConfirmation()
        case .toast:
            PreviewToast()
        }
    }
}

private enum PreviewTheme {
    static let accent = LimaColors.accent
    static var onAccent: Color { AppAccentTheme.current.onPrimary }
    static var readableAccent: Color { AppAccentTheme.current.readablePrimary }
    static let red = LimaColors.danger
    static let orange = LimaColors.warning
    static let green = LimaColors.success

    static var background: some View {
        LimaColors.windowBackground.ignoresSafeArea()
    }
}

private struct PreviewWindowSurface<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            PreviewTheme.background
            content
        }
        .foregroundStyle(LimaColors.primaryText)
        .tint(PreviewTheme.readableAccent)
    }
}

private struct PreviewToolbar: View {
    let symbol: String
    let title: String
    let detail: String?

    var body: some View {
        HStack(spacing: LimaSpacing.sm) {
            Image(systemName: symbol)
                .foregroundStyle(PreviewTheme.readableAccent)
                .frame(width: 28, height: 28)
                .background(LimaColors.accentSoft, in: RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).limaFont(LimaTypography.windowTitle)
                if let detail {
                    Text(detail).limaFont(LimaTypography.caption).foregroundStyle(LimaColors.secondaryText)
                }
            }
            Spacer()
        }
        .padding(.horizontal, LimaSpacing.lg)
        .frame(height: 50)
        .background(LimaColors.raisedSurface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LimaColors.separator).frame(height: LimaDesign.hairlineWidth)
        }
    }
}

private struct PreviewLauncher: View {
    let results: Bool
    @State private var query: String

    init(results: Bool) {
        self.results = results
        _query = State(initialValue: results ? "window" : "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: results ? "rectangle.on.rectangle" : "sparkle.magnifyingglass")
                    .foregroundStyle(PreviewTheme.readableAccent)
                TextField("Search Lima…", text: $query)
                    .textFieldStyle(.plain)
                    .limaFont(.system(size: 17, weight: .medium))
                LimaShortcutBadge(text: "⌘ K")
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .background(LimaColors.editorBackground, in: RoundedRectangle(cornerRadius: LimaRadius.searchField, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LimaRadius.searchField, style: .continuous).stroke(LimaColors.focusedBorder.opacity(0.55), lineWidth: LimaDesign.focusWidth))
            .padding(10)

            if results {
                VStack(spacing: 3) {
                    PreviewLauncherRow(icon: "rectangle.on.rectangle", title: "Move Window Left", detail: "Move the focused window to the left half", shortcut: "⌥ ←", selected: true)
                    PreviewLauncherRow(icon: "arrow.up.left.and.arrow.down.right", title: "Maximize Window", detail: "Fill the current display", shortcut: "⌥ ↩", selected: false)
                    PreviewLauncherRow(icon: "arrow.right.to.line", title: "Move Window Right", detail: "Move the focused window to the right half", shortcut: "⌥ →", selected: false)
                    PreviewLauncherRow(icon: "terminal", title: "Terminal", detail: "Open a persistent shell workspace", shortcut: "⌘ T", selected: false)
                }
                .padding(.horizontal, 10)
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Ready when you are")
                        .limaFont(LimaTypography.sectionTitle)
                    Text("Recent and favorite actions")
                        .limaFont(LimaTypography.body)
                        .foregroundStyle(LimaColors.secondaryText)
                    HStack(spacing: 8) {
                        PreviewQuietChip(title: "Notes", symbol: "note.text")
                        PreviewQuietChip(title: "Terminal", symbol: "terminal")
                        PreviewQuietChip(title: "Clipboard", symbol: "clipboard")
                    }
                    Spacer()
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            HStack(spacing: 14) {
                PreviewKeyHint(keys: "↑↓", label: "Navigate")
                PreviewKeyHint(keys: "↩", label: "Open")
                PreviewKeyHint(keys: "esc", label: "Close")
                Spacer()
                Text(results ? "4 results" : "Ready")
                    .limaFont(LimaTypography.caption)
                    .foregroundStyle(LimaColors.tertiaryText)
            }
            .padding(.horizontal, 16)
            .frame(height: 34)
        }
        .frame(width: 704, height: results ? 466 : 330)
        .background(LimaColors.raisedSurface, in: RoundedRectangle(cornerRadius: LimaRadius.launcherWindow, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LimaRadius.launcherWindow, style: .continuous).stroke(LimaColors.border, lineWidth: LimaDesign.focusWidth))
            .shadow(color: .black.opacity(0.14), radius: 12, y: 5)
        .padding(14)
    }
}

private struct PreviewLauncherRow: View {
    let icon: String
    let title: String
    let detail: String
    let shortcut: String
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 28, height: 28)
                .foregroundStyle(selected ? PreviewTheme.readableAccent : LimaColors.secondaryText)
                .background(LimaColors.recessedSurface, in: RoundedRectangle(cornerRadius: LimaRadius.small, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).limaFont(LimaTypography.resultTitle)
                Text(detail).limaFont(LimaTypography.secondary).foregroundStyle(LimaColors.secondaryText)
            }
            Spacer()
            LimaShortcutBadge(text: shortcut)
            if selected {
                Text("↩ Open")
                    .limaFont(LimaTypography.shortcut)
                    .foregroundStyle(PreviewTheme.onAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(PreviewTheme.accent, in: RoundedRectangle(cornerRadius: LimaRadius.small, style: .continuous))
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 54)
        .limaSelection(selected, radius: LimaRadius.control)
    }
}

private struct PreviewQuietChip: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .limaFont(LimaTypography.caption)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(LimaColors.recessedSurface, in: RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous).stroke(LimaColors.border, lineWidth: LimaDesign.borderWidth))
    }
}

private struct PreviewEmojiPicker: View {
    @State private var query = ""
    private let emoji = ["😀", "😎", "🥳", "🤔", "😂", "❤️", "🔥", "✨", "🌱", "🍞", "🎵", "🚀", "✅", "⚠️", "📌", "🧠", "☕️", "🌤️", "🛠️", "📝", "🎯", "💡", "👋", "🙌"]

    var body: some View {
        PreviewWindowSurface {
            VStack(spacing: 0) {
                PreviewToolbar(symbol: "face.smiling", title: "Emoji", detail: "Search, navigate, and paste")
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(LimaColors.secondaryText)
                    TextField("Search emoji", text: $query)
                        .textFieldStyle(.plain)
                    LimaShortcutBadge(text: "⌘ ↩")
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(LimaColors.recessedSurface, in: RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous).stroke(LimaColors.border, lineWidth: LimaDesign.borderWidth))
                .padding(12)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 6), spacing: 5) {
                    ForEach(Array(emoji.enumerated()), id: \.offset) { index, value in
                        Text(value)
                            .limaFont(.system(size: 29))
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(index == 7 ? LimaColors.selectedFill : .clear, in: RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous))
                            .overlay {
                                if index == 7 {
                                    RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous)
                                        .stroke(LimaColors.focusedBorder, lineWidth: LimaDesign.focusWidth)
                                }
                            }
                    }
                }
                .padding(.horizontal, 18)
                Spacer()
                HStack {
                    Text("Recently used").limaFont(LimaTypography.caption).foregroundStyle(LimaColors.secondaryText)
                    Spacer()
                    PreviewKeyHint(keys: "↑↓", label: "Choose")
                    PreviewKeyHint(keys: "esc", label: "Close")
                }
                .padding(.horizontal, 16)
                .frame(height: 34)
            }
        }
    }
}

private struct PreviewSettings: View {
    @State private var selected: Int
    let variant: String?

    private static let sectionTitles = [
        "General", "Shortcuts & Input", "Writing & Dictation", "Clipboard",
        "Extensions", "Privacy & Permissions", "Advanced", "About"
    ]
    private static let sectionSymbols = [
        "gearshape.fill", "command", "wand.and.stars", "clipboard.fill",
        "puzzlepiece.extension.fill", "checkmark.shield.fill", "slider.horizontal.3", "info.circle.fill"
    ]

    init(initialSelection: Int = 0, variant: String? = nil) {
        _selected = State(initialValue: initialSelection)
        self.variant = variant
    }

    var body: some View {
        PreviewWindowSurface {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkle.magnifyingglass")
                            .foregroundStyle(PreviewTheme.readableAccent)
                        Text("Lima").limaFont(LimaTypography.sectionTitle)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 16)
                    ForEach(Array(Self.sectionTitles.enumerated()), id: \.offset) { index, title in
                        Button {
                            selected = index
                        } label: {
                            Label(title, systemImage: Self.sectionSymbols[index])
                                .limaFont(.system(size: 11.5, weight: selected == index ? .semibold : .medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .frame(height: 34)
                                .limaSelection(selected == index, radius: LimaRadius.control)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)
                    }
                    Spacer()
                }
                .frame(width: 204)
                .background(LimaColors.sidebarBackground)
                PreviewSettingsContent(selected: selected, variant: variant)
            }
            .limaNativeSurface(fill: LimaColors.raisedSurface, radius: LimaRadius.window, border: LimaColors.border)
            .padding(12)
        }
    }
}

private struct PreviewSettingsContent: View {
    let selected: Int
    let variant: String?

    private static let sectionTitles = [
        "General", "Shortcuts & Input", "Writing & Dictation", "Clipboard",
        "Extensions", "Privacy & Permissions", "Advanced", "About"
    ]
    private static let sectionSymbols = [
        "gearshape.fill", "command", "wand.and.stars", "clipboard.fill",
        "puzzlepiece.extension.fill", "checkmark.shield.fill", "slider.horizontal.3", "info.circle.fill"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PreviewToolbar(symbol: Self.sectionSymbols[selected], title: Self.sectionTitles[selected], detail: "Lima preferences")
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if variant == "writing-local" || variant == "writing-enhanced" {
                        PreviewSettingsSection(title: "Grammar Engine") {
                            PreviewSegmented(labels: ["Local", "External API"], selected: variant == "writing-enhanced" ? 1 : 0)
                            Text(variant == "writing-enhanced" ? "Use Local + your AI provider · text is sent for checking" : "Everything stays on this Mac")
                                .limaFont(LimaTypography.caption)
                                .foregroundStyle(LimaColors.secondaryText)
                            PreviewSettingLine(title: variant == "writing-enhanced" ? "Provider" : "Spelling + grammar", detail: variant == "writing-enhanced" ? "OpenAI · Connected" : "Python + Harper", symbol: "checkmark.shield.fill")
                            if variant == "writing-enhanced" {
                                PreviewSettingLine(title: "API key", detail: "Stored securely", symbol: "key.fill")
                            }
                        }
                        PreviewSettingsSection(title: "Stealth Grammar") {
                            PreviewSettingLine(title: "Shortcut", detail: "⌃ ⌥ G", symbol: "wand.and.stars")
                            PreviewSettingLine(title: "Preserved terms", detail: "Lima · EDI · TMS", symbol: "text.badge.checkmark")
                        }
                    } else if variant == "privacy" {
                        PreviewSettingsSection(title: "Permission status") {
                            PreviewSettingLine(title: "Accessibility", detail: "Allowed", symbol: "checkmark.shield.fill")
                            PreviewSettingLine(title: "Microphone", detail: "Allowed", symbol: "mic.fill")
                            PreviewSettingLine(title: "Speech Recognition", detail: "Allowed", symbol: "waveform")
                            PreviewSettingLine(title: "Correction Engine", detail: "External API · Connected", symbol: "lock.shield.fill")
                        }
                        PreviewSettingsSection(title: "Local storage") {
                            Text("Notes, dictation, and clipboard data stay in Lima’s private local storage. Remote grammar is opt-in and clearly identified.")
                                .limaFont(LimaTypography.body)
                                .foregroundStyle(LimaColors.secondaryText)
                        }
                    } else {
                        PreviewSettingsSection(title: "Appearance") {
                            PreviewSegmented(labels: ["System", "Light", "Dark"], selected: 0)
                            PreviewSegmented(labels: ["Compact", "Balanced", "Comfortable"], selected: 1)
                        }
                        PreviewSettingsSection(title: "Global hotkeys") {
                            PreviewSettingLine(title: "Launcher", detail: "⌘ Space", symbol: "command")
                            PreviewSettingLine(title: "Notes", detail: "⌥ N", symbol: "note.text")
                            PreviewSettingLine(title: "Dictation", detail: "⌃ ⌥ D", symbol: "mic.fill")
                        }
                        DisclosureGroup("Advanced performance and security") {
                            Text("Diagnostic, update, extension approval, and low-level performance options remain available without competing with daily preferences.")
                                .limaFont(LimaTypography.caption)
                                .foregroundStyle(LimaColors.secondaryText)
                                .padding(.top, 6)
                        }
                        .limaFont(LimaTypography.sectionTitle)
                    }
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct PreviewSettingsSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).limaFont(LimaTypography.sectionTitle)
            content
        }
    }
}

private struct PreviewSegmented: View {
    let labels: [String]
    let selected: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                Text(label)
                    .limaFont(LimaTypography.caption)
                    .frame(maxWidth: .infinity, minHeight: 29)
                    .background(index == selected ? LimaColors.selectedFill : .clear)
                    .overlay(alignment: .trailing) { Rectangle().fill(LimaColors.separator).frame(width: LimaDesign.hairlineWidth) }
            }
        }
        .background(LimaColors.recessedSurface, in: RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous).stroke(LimaColors.border, lineWidth: LimaDesign.borderWidth))
    }
}

private struct PreviewSettingLine: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(PreviewTheme.readableAccent).frame(width: 20)
            Text(title).limaFont(LimaTypography.body)
            Spacer()
            LimaShortcutBadge(text: detail)
        }
        .frame(minHeight: 34)
    }
}

private struct PreviewExtensions: View {
    var body: some View {
        PreviewWindowSurface {
            VStack(spacing: 0) {
                PreviewToolbar(symbol: "puzzlepiece.extension.fill", title: "Extensions", detail: "Built-in and user-installed capability packs")
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        PreviewExtensionPack(name: "Lima Essentials", detail: "Built-in by Lima · trusted", enabled: true, commands: [("Open Notes", "⌥ N"), ("Show Clipboard", "⌘ V"), ("Terminal", "⌥ T")])
                        PreviewExtensionPack(name: "Window Management", detail: "Built-in by Lima · trusted", enabled: true, commands: [("Move Left", "⌥ ←"), ("Move Right", "⌥ →"), ("Maximize", "⌥ ↩")])
                        PreviewExtensionPack(name: "Team Shortcuts", detail: "User extension · approval required", enabled: false, commands: [("Open Runbook", "⌘ ⇧ R"), ("Copy Incident ID", "⌘ ⇧ I")])
                    }
                    .padding(18)
                }
            }
        }
    }
}

private struct PreviewExtensionPack: View {
    let name: String
    let detail: String
    let enabled: Bool
    let commands: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(PreviewTheme.readableAccent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).limaFont(LimaTypography.sectionTitle)
                    Text(detail).limaFont(LimaTypography.caption).foregroundStyle(LimaColors.secondaryText)
                }
                Spacer()
                Toggle("Enabled", isOn: .constant(enabled))
                    .labelsHidden()
            }
            .padding(13)
            Divider()
            ForEach(Array(commands.enumerated()), id: \.offset) { _, command in
                HStack {
                    Image(systemName: "command.square").foregroundStyle(LimaColors.secondaryText)
                    Text(command.0).limaFont(LimaTypography.body)
                    Spacer()
                    LimaShortcutBadge(text: command.1)
                }
                .padding(.horizontal, 13)
                .frame(height: 38)
            }
        }
        .limaNativeSurface(fill: LimaColors.raisedSurface, radius: LimaRadius.panel, border: enabled ? LimaColors.border : LimaColors.warning.opacity(0.45))
    }
}

private struct PreviewNotes: View {
    var body: some View {
        PreviewWindowSurface {
            VStack(spacing: 0) {
                PreviewToolbar(symbol: "note.text", title: "Notes", detail: "Local Markdown workspace")
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "magnifyingglass").foregroundStyle(LimaColors.secondaryText)
                            Text("Search notes").limaFont(LimaTypography.caption).foregroundStyle(LimaColors.tertiaryText)
                        }
                        .padding(9)
                        .limaNativeSurface(fill: LimaColors.recessedSurface, radius: LimaRadius.control, border: LimaColors.border)
                        Text("PINNED").limaFont(.system(size: 9, weight: .bold)).foregroundStyle(LimaColors.tertiaryText).padding(.top, 9)
                        PreviewNoteRow(title: "Weekly plan", detail: "Today · 12:40 PM", selected: true)
                        Text("RECENT").limaFont(.system(size: 9, weight: .bold)).foregroundStyle(LimaColors.tertiaryText).padding(.top, 7)
                        PreviewNoteRow(title: "Garden notes", detail: "Yesterday", selected: false)
                        PreviewNoteRow(title: "Incident checklist", detail: "Monday", selected: false)
                        Spacer()
                        Text("3 notes · Local").limaFont(LimaTypography.caption).foregroundStyle(LimaColors.secondaryText)
                    }
                    .padding(12)
                    .frame(width: 250)
                    .background(LimaColors.sidebarBackground)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Weekly plan").limaFont(.system(size: 24, weight: .semibold))
                        Text("Updated today · 12:40 PM").limaFont(LimaTypography.caption).foregroundStyle(LimaColors.secondaryText)
                        Divider().padding(.vertical, 13)
                        Text("This is a calm document surface. The content owns the hierarchy, while metadata and formatting remain quiet.")
                            .limaFont(.system(size: 15))
                            .lineSpacing(4)
                        Text("\n- [x] Review extension packs\n- [ ] Test Light and Dark appearance\n- [ ] Verify dictation retry")
                            .limaFont(.system(size: 15, design: .monospaced))
                            .lineSpacing(4)
                        Spacer()
                        HStack {
                            Label("Tasks 1 of 3", systemImage: "circle.dashed")
                            Spacer()
                            Text("Bold   Italic   Link   Table").limaFont(LimaTypography.caption).foregroundStyle(LimaColors.secondaryText)
                        }
                        .padding(10)
                        .background(LimaColors.recessedSurface, in: RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous))
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(LimaColors.editorBackground)
                }
            }
        }
    }
}

private struct PreviewNoteRow: View {
    let title: String
    let detail: String
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).limaFont(LimaTypography.body)
            Text(detail).limaFont(LimaTypography.caption).foregroundStyle(LimaColors.tertiaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .limaSelection(selected, radius: LimaRadius.control)
    }
}

private struct PreviewFormatter: View {
    var body: some View {
        PreviewWindowSurface {
            VStack(spacing: 0) {
                PreviewToolbar(symbol: "wand.and.stars", title: "Document Formatter", detail: "Format, inspect, and copy local documents")
                HStack {
                    PreviewQuietChip(title: "JSON", symbol: "curlybraces")
                    PreviewQuietChip(title: "Pretty", symbol: "text.alignleft")
                    Spacer()
                    Button("Format") { }.limaButton(prominent: true)
                }
                .padding(12)
                HStack(spacing: 10) {
                    PreviewCodePane(title: "SOURCE", text: "{\"status\":\"ready\",\"items\":[1,2,3]}")
                    PreviewCodePane(title: "FORMATTED", text: "{\n  \"status\": \"ready\",\n  \"items\": [1, 2, 3]\n}")
                }
                .padding(.horizontal, 12)
                .frame(maxHeight: .infinity)
                PreviewStatus(title: "Valid JSON · ready to copy", symbol: "checkmark.seal.fill", tint: PreviewTheme.green)
                    .padding(12)
            }
        }
    }
}

private struct PreviewCodePane: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).limaFont(LimaTypography.caption).foregroundStyle(LimaColors.secondaryText).padding(10)
            Divider()
            Text(text)
                .limaFont(LimaTypography.technical)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(13)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LimaColors.editorBackground, in: RoundedRectangle(cornerRadius: LimaRadius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: LimaRadius.panel, style: .continuous).stroke(LimaColors.border, lineWidth: LimaDesign.borderWidth))
    }
}

private enum PreviewDictationState {
    case recording, transcribing, completed

    var title: String {
        switch self { case .recording: return "Recording"; case .transcribing: return "Transcribing"; case .completed: return "Completed" }
    }

    var detail: String {
        switch self { case .recording: return "Separate conversation · Recording"; case .transcribing: return "Separate conversation · Transcribing"; case .completed: return "Separate conversation · Completed" }
    }
}

private struct PreviewDictation: View {
    let state: PreviewDictationState

    var body: some View {
        PreviewWindowSurface {
            VStack(alignment: .leading, spacing: 18) {
                PreviewToolbar(
                    symbol: "waveform.and.mic",
                    title: "Dictation",
                    detail: state.detail
                )
                PreviewDictationHeader(state: state)
                PreviewDictationWaveform()
                HStack {
                    PreviewStatus(title: state.title, symbol: state == .completed ? "checkmark.circle.fill" : "waveform", tint: state == .completed ? PreviewTheme.green : PreviewTheme.red)
                    Spacer()
                    if state == .recording { Button("Pause") { }.limaButton() }
                    if state != .completed { Button("Stop & Transcribe") { }.limaButton(prominent: true) }
                }
                Text(state == .completed ? "Meeting notes about the extension review are saved in the selected conversation." : "Meeting notes about the extension review will appear here while recording continues.")
                    .limaFont(LimaTypography.body)
                    .foregroundStyle(LimaColors.secondaryText)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LimaColors.editorBackground, in: RoundedRectangle(cornerRadius: LimaRadius.panel, style: .continuous))
                Spacer()
            }
            .padding(18)
        }
    }
}

private struct PreviewDictationHeader: View {
    let state: PreviewDictationState

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(PreviewTheme.red.opacity(0.12))
                Image(systemName: "mic.fill").foregroundStyle(PreviewTheme.red)
            }
            .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.title).limaFont(.system(size: 18, weight: .semibold))
                Text(state == .recording ? "00:42 · Listening · Good input signal" : (state == .transcribing ? "00:42 · Preparing transcript" : "00:44 · Saved to Dictation"))
                    .limaFont(LimaTypography.caption)
                    .foregroundStyle(LimaColors.secondaryText)
            }
            Spacer()
            Circle().fill(PreviewTheme.red).frame(width: 8, height: 8)
        }
    }
}

private struct PreviewDictationWaveform: View {
    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(0..<26, id: \.self) { index in
                PreviewWaveformBar(index: index)
            }
        }
        .frame(height: 52)
        .padding(.horizontal, 12)
        .background(LimaColors.recessedSurface, in: RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous))
    }
}

private struct PreviewWaveformBar: View {
    let index: Int

    var body: some View {
        let barOpacity = index.isMultiple(of: 4) ? 0.92 : 0.45
        let barHeight = CGFloat(8 + (index * 7) % 23)
        return Capsule()
            .fill(PreviewTheme.red.opacity(barOpacity))
            .frame(maxWidth: .infinity)
            .frame(height: barHeight)
    }
}

private struct PreviewConfirmation: View {
    var body: some View {
        PreviewWindowSurface {
            VStack(alignment: .leading, spacing: 16) {
                PreviewToolbar(symbol: "exclamationmark.triangle.fill", title: "Force Quit Application", detail: "This action requires deliberate confirmation")
                VStack(alignment: .leading, spacing: 8) {
                    Text("Chrome").limaFont(.system(size: 19, weight: .semibold))
                    Text("The application will be terminated immediately. Unsaved work may be lost. Return is not assigned to the destructive action.")
                        .limaFont(LimaTypography.body)
                        .foregroundStyle(LimaColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                HStack {
                    Spacer()
                    Button("Cancel") { }.keyboardShortcut(.cancelAction)
                    Button("Force Quit") { }.limaButton(destructive: true)
                }
            }
            .padding(22)
            .limaNativeSurface(fill: LimaColors.raisedSurface, radius: LimaRadius.window, border: LimaColors.danger.opacity(0.35))
            .padding(16)
        }
    }
}

private struct PreviewToast: View {
    var body: some View {
        PreviewWindowSurface {
            VStack(alignment: .leading, spacing: 16) {
                PreviewToolbar(symbol: "checkmark.circle.fill", title: "Feedback", detail: "Compact, shared, non-focus-stealing status")
                Spacer()
                HStack(spacing: 9) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(PreviewTheme.green)
                    Text("Window moved left").limaFont(LimaTypography.body.weight(.semibold))
                    Spacer()
                    Text("now").limaFont(LimaTypography.caption).foregroundStyle(LimaColors.secondaryText)
                }
                .padding(.horizontal, 14)
                .frame(height: 42)
                .limaNativeSurface(fill: LimaColors.raisedSurface, radius: LimaRadius.control, border: PreviewTheme.green.opacity(0.30), shadow: true)
                Spacer()
                PreviewStatus(title: "Toast disappears automatically and never captures focus.", symbol: "info.circle", tint: PreviewTheme.accent)
            }
            .padding(18)
        }
    }
}

private struct PreviewStatus: View {
    let title: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: symbol)
            .limaFont(LimaTypography.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous))
    }
}

private struct PreviewKeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            LimaShortcutBadge(text: keys)
            Text(label).limaFont(LimaTypography.caption).foregroundStyle(LimaColors.secondaryText)
        }
    }
}
#endif
