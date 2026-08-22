import AppKit
import ApplicationServices
import RayPlacementCore
import RayPlacementWriting
import SwiftUI

private extension LoadedExtensionCommand {
    var settingsIdentifier: String { "\(extensionID).\(command.id)" }
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var viewModel: LauncherViewModel
    @State private var confirmClipboardClear = false
    @State private var accessibilityTrusted = AXIsProcessTrusted()
    let reloadExtensions: () -> Void

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            clipboardTab
                .tabItem { Label("Clipboard", systemImage: "clipboard") }
            writingTab
                .tabItem { Label("Writing", systemImage: "text.badge.checkmark") }
            performanceTab
                .tabItem { Label("Performance", systemImage: "gauge.medium") }
            extensionsTab
                .tabItem { Label("Extensions", systemImage: "puzzlepiece.extension") }
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(20)
        .frame(width: 720, height: 560)
    }

    private var performanceTab: some View {
        Form {
            Section("Writing models") {
                performancePicker("Writing", selection: $settings.writingPerformance)
                LabeledContent(
                    "Qwen compute limit",
                    value: "\(settings.writingPerformance.threadLimit) CPU thread\(settings.writingPerformance.threadLimit == 1 ? "" : "s"), \(Int(settings.writingPerformance.writingTimeout))s timeout"
                )
                Text("Models load only when a writing check is requested and exit afterward. Qwen remains CPU-only so it cannot compete with the desktop for GPU resources.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Qwen still uses about 2 GB of memory while a check is running because the model itself must be loaded. Choose Harper for the lightest checks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Note dictation") {
                performancePicker("Dictation", selection: $settings.dictationPerformance)
                LabeledContent(
                    "Work limit",
                    value: "Record \(Int(settings.dictationPerformance.dictationMaximumDuration / 60)) min; \(Int(settings.dictationPerformance.dictationTranscriptionTimeout))s per segment"
                )
                Text("Dictation never listens in the background. After Stop, long meetings are processed sequentially in small on-device segments so memory stays bounded. High allows a full 60-minute meeting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("AI-capable extensions") {
                performancePicker("Extensions", selection: $settings.extensionPerformance)
                LabeledContent(
                    "Process budget",
                    value: "\(settings.extensionPerformance.threadLimit) cooperative thread\(settings.extensionPerformance.threadLimit == 1 ? "" : "s"), \(Int(settings.extensionPerformance.extensionTimeout))s timeout"
                )
                Text("RayPlacement enforces process priority and timeouts and supplies common AI thread-limit environment variables. Third-party executables can ignore cooperative thread variables, so only install extensions you trust.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func performancePicker(_ title: String, selection: Binding<PerformanceScale>) -> some View {
        Picker(title, selection: selection) {
            ForEach(PerformanceScale.allCases) { scale in
                Text(scale.title).tag(scale)
            }
        }
        .pickerStyle(.segmented)
    }

    private var writingTab: some View {
        Form {
            Section("Grammar and spelling engine") {
                Picker("Writing provider", selection: $settings.writingProvider) {
                    ForEach(WritingProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(settings.writingProvider.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Label("All providers are bundled and run entirely on this Mac.", systemImage: "checkmark.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            Section("Provider notes") {
                LabeledContent("Harper", value: "Fast, explainable, rule-based checks")
                LabeledContent("T5-small CoEdit INT8", value: "Local sentence rewriting; best for short passages")
                LabeledContent("Qwen3 1.7B Q8 (Deep)", value: "On demand; controlled by Settings → Performance")
                Text("The INT8 option uses the Apache-licensed TonyRaju ONNX conversion of Unbabel/gec-t5_small. It is listed by its published CoEdit name, but it is not an official checkpoint from the CoEdIT paper authors.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("The Deep option uses the official Apache-2.0 Qwen3 1.7B Q8 model through the bundled llama.cpp runtime. It never runs in the background, does not require Ollama, and never sends checked text over the network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var generalTab: some View {
        Form {
            Section("Launcher") {
                LabeledContent("Activation shortcut") {
                    ShortcutRecorder(shortcut: $settings.activationShortcut)
                        .frame(width: 145, height: 28)
                }
                Text("Click the shortcut, then press any modifier and key. The default is ⌥Space.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Start RayPlacement when I log in", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))
                if let error = settings.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Accessibility") {
                Label(
                    accessibilityTrusted ? "Accessibility access is working" : "Accessibility access is not available",
                    systemImage: accessibilityTrusted ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
                )
                .foregroundStyle(accessibilityTrusted ? .green : .orange)

                Text("Writing checks, replacing selected text, window commands, and automatic paste use this permission. The launcher and its global shortcuts do not.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Request Access") { requestAccessibilityAccess() }
                    Button("Open Accessibility Settings") { openAccessibilitySettings() }
                    Button("Reveal This App") {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    }
                }

                Text(Bundle.main.bundleURL.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }

            Section("Keyboard") {
                LabeledContent("Navigate", value: "↑ / ↓ or Control-P / Control-N")
                LabeledContent("Run", value: "Return")
                LabeledContent("Back or close", value: "Escape")
                LabeledContent("Settings", value: "⌘,")
                LabeledContent("Visible result", value: "⌘1 … ⌘9")
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityTrusted = AXIsProcessTrusted()
        }
    }

    private func requestAccessibilityAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        accessibilityTrusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    private var clipboardTab: some View {
        Form {
            Section("Local clipboard history") {
                Toggle("Remember copied text", isOn: $settings.clipboardEnabled)
                Stepper("Keep up to \(settings.clipboardLimit) items", value: $settings.clipboardLimit, in: 10...500, step: 10)
                Text("Off by default. When enabled, RayPlacement checks the macOS clipboard and stores text only in ~/Library/Application Support/RayPlacement. Nothing is sent over the network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if #available(macOS 15.4, *) {
                    Text("macOS clipboard permission: \(pasteboardAccessDescription())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Clear Clipboard History", role: .destructive) {
                    confirmClipboardClear = true
                }
            }
        }
        .formStyle(.grouped)
        .alert("Clear Clipboard History?", isPresented: $confirmClipboardClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear History", role: .destructive) { viewModel.clipboard.clear() }
        } message: {
            Text("This permanently removes every item RayPlacement has saved from the clipboard.")
        }
    }

    private var extensionsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text(ApplicationPaths.extensions.path)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack {
                        Button("Open Extensions Folder") { NSWorkspace.shared.open(ApplicationPaths.extensions) }
                        Button("Reload") { reloadExtensions() }
                        Spacer()
                        Text("\(viewModel.extensionCommands.count) commands")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(4)
            } label: {
                Label("Add functionality", systemImage: "folder.badge.plus")
            }

            Text("Drop in a JSON manifest for URL, file, copy, paste, writing, or executable-script commands. Record or clear a global shortcut for any loaded command below.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !viewModel.extensionIssues.isEmpty {
                GroupBox("Extension issues") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(viewModel.extensionIssues) { issue in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(issue.file).font(.caption.weight(.semibold))
                                    Text(issue.message).font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(4)
                    }
                    .frame(maxHeight: 95)
                }
            }

            if viewModel.extensionCommands.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("No extension commands loaded").font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(viewModel.extensionCommands, id: \LoadedExtensionCommand.settingsIdentifier) { loaded in
                            ExtensionShortcutRow(settings: settings, loaded: loaded)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(12)
    }

    private var aboutTab: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 56, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
            Text("RayPlacement").font(.title.bold())
            Text("A fast, local-only macOS command launcher")
                .foregroundStyle(.secondary)
            Text("Local-only writing tools. No cloud AI. No analytics.")
                .font(.callout.weight(.medium))
            Text("Version 1.4.0")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @available(macOS 15.4, *)
    private func pasteboardAccessDescription() -> String {
        switch NSPasteboard.general.accessBehavior.rawValue {
        case 0: return "Ask when first needed"
        case 1: return "Ask before access"
        case 2: return "Always allow"
        case 3: return "Always deny"
        default: return "Managed by macOS"
        }
    }
}

private struct ExtensionShortcutRow: View {
    @ObservedObject var settings: SettingsStore
    let loaded: LoadedExtensionCommand

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: loaded.command.icon ?? "puzzlepiece.extension.fill")
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(loaded.command.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(loaded.extensionName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            ShortcutRecorder(
                shortcut: Binding(
                    get: { settings.effectiveShortcut(for: loaded) ?? "" },
                    set: { settings.setShortcut($0, for: loaded) }
                ),
                label: "\(loaded.command.title) shortcut"
            )
            .frame(width: 145, height: 28)

            Button("Clear") { settings.setShortcut(nil, for: loaded) }
                .disabled(settings.effectiveShortcut(for: loaded) == nil)
            if settings.hasShortcutOverride(for: loaded) {
                Button("Use Default") { settings.resetShortcut(for: loaded) }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: String
    var label = "Activation shortcut"

    func makeCoordinator() -> Coordinator { Coordinator(shortcut: $shortcut) }

    func makeNSView(context: Context) -> ShortcutCaptureView {
        let view = ShortcutCaptureView()
        view.onChange = { context.coordinator.shortcut.wrappedValue = $0 }
        view.shortcut = shortcut
        view.accessibilityLabelText = label
        return view
    }

    func updateNSView(_ nsView: ShortcutCaptureView, context: Context) {
        nsView.shortcut = shortcut
        nsView.accessibilityLabelText = label
    }

    final class Coordinator {
        var shortcut: Binding<String>
        init(shortcut: Binding<String>) { self.shortcut = shortcut }
    }
}

private final class ShortcutCaptureView: NSView {
    var shortcut = "" {
        didSet {
            needsDisplay = true
            updateAccessibilityValue()
        }
    }
    var onChange: ((String) -> Void)?
    var accessibilityLabelText = "Activation shortcut" {
        didSet { setAccessibilityLabel(accessibilityLabelText) }
    }
    private var recording = false {
        didSet {
            needsDisplay = true
            updateAccessibilityValue()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAccessibility()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAccessibility()
    }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 145, height: 28) }

    override func accessibilityPerformPress() -> Bool {
        recording = true
        window?.makeFirstResponder(self)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        recording = true
        window?.makeFirstResponder(self)
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            recording = false
            window?.makeFirstResponder(nil)
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers = Set<ShortcutSpec.Modifier>()
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        guard !modifiers.isEmpty, let key = Self.keyName(for: event) else {
            NSSound.beep()
            return
        }
        // Persist the physical virtual key code so custom shortcuts keep working
        // on non-US keyboard layouts. The suffix preserves a friendly label.
        let physicalKey = "kc\(event.keyCode):\(key)"
        let value = ShortcutSpec(modifiers: modifiers, key: physicalKey).storageString
        shortcut = value
        onChange?(value)
        recording = false
        window?.makeFirstResponder(nil)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.18) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = 1
        path.stroke()

        let value = recording
            ? "Press shortcut…"
            : (shortcut.isEmpty ? "No shortcut" : (ShortcutSpec(string: shortcut)?.displayString ?? shortcut))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        let string = NSAttributedString(string: value, attributes: attributes)
        let size = string.size()
        string.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    private func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityLabelText)
        setAccessibilityHelp("Press to record a new global shortcut.")
        updateAccessibilityValue()
    }

    private func updateAccessibilityValue() {
        let value = recording
            ? "Recording. Press a modifier and key."
            : (shortcut.isEmpty ? "No shortcut" : (ShortcutSpec(string: shortcut)?.displayString ?? shortcut))
        setAccessibilityValue(value)
    }

    private static func keyName(for event: NSEvent) -> String? {
        let special: [UInt16: String] = [
            36: "return", 48: "tab", 49: "space", 51: "delete", 53: "escape",
            123: "left", 124: "right", 125: "down", 126: "up",
            122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6",
            98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12"
        ]
        if let value = special[event.keyCode] { return value }
        guard let characters = event.charactersIgnoringModifiers?.lowercased(), characters.count == 1 else { return nil }
        return characters
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    private let settingsStore: SettingsStore

    init(settings: SettingsStore, viewModel: LauncherViewModel, reloadExtensions: @escaping () -> Void) {
        self.settingsStore = settings
        let view = SettingsView(settings: settings, viewModel: viewModel, reloadExtensions: reloadExtensions)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "RayPlacement Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        settingsStore.refreshLaunchAtLogin()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
