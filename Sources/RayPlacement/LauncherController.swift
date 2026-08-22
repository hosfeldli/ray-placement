import AppKit
import ApplicationServices
import Foundation
import RayPlacementCore
import RayPlacementWriting
import SwiftUI

@MainActor
final class LauncherController: NSObject, NSWindowDelegate, LauncherViewModelDelegate {
    let clipboard: ClipboardHistoryService
    let viewModel: LauncherViewModel

    var onExtensionsChanged: (() -> Void)?

    private let panel: LauncherPanel
    private let extensionExecutor = ExtensionExecutor()
    private let writingRunner = WritingProviderRunner()
    private lazy var notesWindow = NotesWindowController()
    private var previousApplication: NSRunningApplication?
    private var localEventMonitor: Any?
    private lazy var settingsWindow = SettingsWindowController(
        settings: .shared,
        viewModel: viewModel,
        reloadExtensions: { [weak self] in self?.viewModel.reloadExtensions() }
    )

    override init() {
        let clipboard = ClipboardHistoryService()
        self.clipboard = clipboard
        self.viewModel = LauncherViewModel(clipboard: clipboard)
        self.panel = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: 740, height: 510))
        super.init()

        viewModel.delegate = self
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: LauncherView(viewModel: viewModel))
        installKeyboardMonitor()
    }

    deinit {
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
    }

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    func show() {
        rememberFrontmostApplication()
        viewModel.resetForPresentation()
        presentPanel()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func shutdown() {
        extensionExecutor.cancelAll()
        writingRunner.cancel()
        clipboard.flush()
        notesWindow.shutdown()
    }

    func showSettings() {
        hide()
        settingsWindow.present()
    }

    func showNotes() {
        hide()
        notesWindow.present()
    }

    func executeExtensionFromHotkey(_ command: LoadedExtensionCommand) {
        rememberFrontmostApplication()
        executeExtension(command)
    }

    func launcherViewModel(_ viewModel: LauncherViewModel, perform action: LauncherAction, item: LauncherItem) {
        switch action {
        case .launchApplication(let url):
            hide()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
                if let error { DispatchQueue.main.async { self?.presentError(title: item.title, error: error) } }
            }

        case .openFile(let url), .openURL(let url):
            hide()
            if !NSWorkspace.shared.open(url) {
                presentError(title: item.title, message: "macOS could not open \(url.isFileURL ? url.path : url.absoluteString).")
            }

        case .revealFile(let url):
            hide()
            NSWorkspace.shared.activateFileViewerSelecting([url])

        case .openInVSCode(let url):
            openInVSCode(url, title: item.title)

        case .copyText(let text):
            clipboard.copy(text)
            hide()

        case .pasteText(let text):
            clipboard.copy(text)
            pasteIntoPreviousApplication()

        case .replaceSelectedText(let text):
            replaceSelectedText(text)

        case .enterMode(let mode):
            viewModel.enter(mode)

        case .extensionCommand(let command):
            executeExtension(command)

        case .window(let layout):
            applyWindowLayout(layout)

        case .system(let systemAction):
            performSystemAction(systemAction)

        case .noOp:
            break
        }
    }

    func launcherViewModelDidReloadExtensions(_ viewModel: LauncherViewModel) {
        onExtensionsChanged?()
    }

    func launcherViewModelDidRequestHide(_ viewModel: LauncherViewModel) {
        hide()
    }

    func windowDidResignKey(_ notification: Notification) {
        if panel.isVisible { hide() }
    }

    private func presentPanel() {
        let targetScreen = screenUnderPointer() ?? NSScreen.main ?? NSScreen.screens.first
        if let visibleFrame = targetScreen?.visibleFrame {
            let size = panel.frame.size
            let x = visibleFrame.midX - size.width / 2
            let topInset = max(64, visibleFrame.height * 0.12)
            let y = max(visibleFrame.minY + 24, visibleFrame.maxY - size.height - topInset)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    private func rememberFrontmostApplication() {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApplication = frontmost
        }
    }

    private func screenUnderPointer() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
    }

    private func installKeyboardMonitor() {
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""

            if flags.contains(.command) {
                if characters == "," {
                    self.showSettings()
                    return nil
                }
                if characters == "q" {
                    NSApp.terminate(nil)
                    return nil
                }
                if let digit = Int(characters), (1...9).contains(digit) {
                    self.viewModel.executeVisibleItem(at: digit - 1)
                    return nil
                }
            }

            let controlOnly = flags.contains(.control) && !flags.contains(.command) && !flags.contains(.option)
            if event.keyCode == 125 || (controlOnly && characters == "n") {
                self.viewModel.moveSelection(by: 1)
                return nil
            }
            if event.keyCode == 126 || (controlOnly && characters == "p") {
                self.viewModel.moveSelection(by: -1)
                return nil
            }
            if event.keyCode == 36 || event.keyCode == 76 {
                self.viewModel.executeSelected()
                return nil
            }
            if event.keyCode == 53 {
                if case .output(_, let text, _) = self.viewModel.mode, text == "Running…" {
                    self.extensionExecutor.cancelAll()
                }
                if case .output(_, let text, _) = self.viewModel.mode, text.hasPrefix("Checking locally with") {
                    self.writingRunner.cancel()
                }
                self.viewModel.handleEscape()
                return nil
            }
            if event.keyCode == 51, self.viewModel.goBackIfPossible() {
                return nil
            }
            return event
        }
    }

    private func executeExtension(_ command: LoadedExtensionCommand) {
        let isShell = command.command.action.type == .shell
        if isShell {
            viewModel.showOutput(title: command.command.title, text: "Running…")
            if !panel.isVisible { presentPanel() }
        } else {
            hide()
        }

        extensionExecutor.execute(command, clipboard: clipboard) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let output):
                if output == "__PASTE__" {
                    self.pasteIntoPreviousApplication()
                } else if output == "__CHECK_WRITING__" {
                    self.performWritingCheck()
                } else if output == "__OPEN_IN_VSCODE__" {
                    self.viewModel.enter(.vscodePicker)
                    if !self.panel.isVisible { self.presentPanel() }
                } else if let output {
                    self.viewModel.showOutput(title: command.command.title, text: output)
                    if !self.panel.isVisible { self.presentPanel() }
                } else if isShell {
                    self.viewModel.showOutput(title: command.command.title, text: "Command completed.")
                }
            case .failure(let error):
                self.presentError(title: command.command.title, error: error)
            }
        }
    }

    private func performWritingCheck() {
        guard let previousApplication else {
            presentError(title: "Check Spelling & Grammar", message: "Select text in another app, then open RayPlacement and run this command.")
            return
        }
        guard WindowManager.trusted(prompt: true) else {
            presentError(title: "Check Spelling & Grammar", error: SelectedTextService.SelectionError.accessibilityRequired)
            return
        }

        hide()
        previousApplication.activate(options: [.activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            guard let self else { return }
            do {
                let selectedText = try SelectedTextService.selectedText(in: previousApplication.processIdentifier)
                self.showWritingReview(for: selectedText)
            } catch {
                self.presentError(title: "Check Spelling & Grammar", error: error)
            }
        }
    }

    private func showWritingReview(for text: String?) {
        let provider = SettingsStore.shared.writingProvider
        viewModel.showOutput(title: "Check Spelling & Grammar", text: "Checking locally with \(provider.title)…")
        if !panel.isVisible { presentPanel() }
        writingRunner.check(text ?? "", provider: provider) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let review):
                self.viewModel.showWritingReview(review)
                if !self.panel.isVisible { self.presentPanel() }
            case .failure(let error):
                self.presentError(title: "Check Spelling & Grammar", error: error)
            }
        }
    }

    private func pasteIntoPreviousApplication() {
        hide()
        guard WindowManager.trusted(prompt: true) else {
            presentError(title: "Paste", message: "Enable RayPlacement in System Settings → Privacy & Security → Accessibility to paste automatically.")
            return
        }
        previousApplication?.activate(options: [.activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard let source = CGEventSource(stateID: .hidSystemState),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return }
            down.flags = .maskCommand
            up.flags = .maskCommand
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    private func replaceSelectedText(_ text: String) {
        hide()
        guard let previousApplication else {
            presentError(title: "Replace Selected Text", message: "The app containing the original selection is no longer available.")
            return
        }
        guard WindowManager.trusted(prompt: true) else {
            presentError(title: "Replace Selected Text", error: SelectedTextService.SelectionError.accessibilityRequired)
            return
        }
        previousApplication.activate(options: [.activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            do {
                try SelectedTextService.replaceSelectedText(text, in: previousApplication.processIdentifier)
            } catch {
                self?.presentError(title: "Replace Selected Text", error: error)
            }
        }
    }

    private func openInVSCode(_ url: URL, title: String) {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") else {
            presentError(title: title, message: "Visual Studio Code is not installed or could not be found.")
            return
        }
        hide()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: applicationURL,
            configuration: configuration
        ) { [weak self] _, error in
            if let error {
                DispatchQueue.main.async { self?.presentError(title: title, error: error) }
            }
        }
    }

    private func applyWindowLayout(_ layout: WindowLayout) {
        let target = previousApplication
        hide()
        target?.activate(options: [.activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            guard let self else { return }
            switch WindowManager.apply(layout, to: target?.processIdentifier) {
            case .success: break
            case .failure(let error): self.presentError(title: layout.title, error: error)
            }
        }
    }

    private func performSystemAction(_ action: SystemAction) {
        switch action {
        case .lockScreen:
            hide()
            guard WindowManager.trusted(prompt: true) else {
                presentError(title: "Lock Screen", message: "Enable RayPlacement in System Settings → Privacy & Security → Accessibility, then try again.")
                return
            }
            postSystemShortcut(keyCode: 12, flags: [.maskCommand, .maskControl])

        case .sleep:
            hide()
            runSystemExecutable("/usr/bin/pmset", arguments: ["sleepnow"], title: "Sleep")

        case .startScreenSaver:
            hide()
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"))

        case .openExtensionsFolder:
            try? ApplicationPaths.prepare()
            hide()
            NSWorkspace.shared.open(ApplicationPaths.extensions)

        case .reloadExtensions:
            viewModel.reloadExtensions()

        case .clearClipboardHistory:
            clipboard.clear()

        case .openNotes:
            showNotes()

        case .openSettings:
            showSettings()

        case .quit:
            NSApp.terminate(nil)
        }
    }

    private func postSystemShortcut(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func runSystemExecutable(_ path: String, arguments: [String], title: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        task.terminationHandler = { [weak self] process in
            guard process.terminationStatus != 0 else { return }
            DispatchQueue.main.async {
                self?.presentError(title: title, message: "The system command exited with status \(process.terminationStatus).")
            }
        }
        do { try task.run() }
        catch { presentError(title: title, error: error) }
    }

    private func presentError(title: String, error: Error) {
        presentError(title: title, message: error.localizedDescription)
    }

    private func presentError(title: String, message: String) {
        viewModel.showOutput(title: title, text: message, isError: true)
        if !panel.isVisible { presentPanel() }
    }
}
