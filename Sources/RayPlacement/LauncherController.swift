import AppKit
import ApplicationServices
import Foundation
import QuartzCore
import RayPlacementCore
import RayPlacementWriting
import SwiftUI

@MainActor
final class LauncherController: NSObject, NSWindowDelegate, LauncherViewModelDelegate {
    let clipboard: ClipboardHistoryService
    let viewModel: LauncherViewModel

    var onExtensionsChanged: (() -> Void)?

    private let panel: LauncherPanel
    private let toast = ActionToastController()
    private let extensionExecutor = ExtensionExecutor()
    private let writingRunner = WritingProviderRunner()
    private lazy var notesWindow = NotesWindowController()
    private var previousApplication: NSRunningApplication?
    private var lastExternalApplication: NSRunningApplication?
    private var selectedTextContext: SelectedTextService.SelectionContext?
    private var keyboardSelectionContext: KeyboardSelectionService.Capture?
    private var focusedTextContext: SelectedTextService.SelectionContext?
    private var writingTaskID: UUID?
    private var localEventMonitor: Any?
    private var applicationActivationObserver: NSObjectProtocol?
    private let updateService: UpdateService
    private lazy var settingsWindow = SettingsWindowController(
        settings: .shared,
        viewModel: viewModel,
        updateService: updateService,
        reloadExtensions: { [weak self] in self?.viewModel.reloadExtensions() }
    )

    init(updateService: UpdateService) {
        let clipboard = ClipboardHistoryService()
        self.clipboard = clipboard
        self.viewModel = LauncherViewModel(clipboard: clipboard)
        self.panel = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: 690, height: 470))
        self.updateService = updateService
        super.init()

        viewModel.delegate = self
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: LauncherView(viewModel: viewModel))
        rememberExternalApplicationActivation()
        installKeyboardMonitor()
    }

    deinit {
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
        if let applicationActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(applicationActivationObserver)
        }
    }

    func toggle(from sourceApplication: NSRunningApplication? = nil) {
        panel.isVisible ? hide() : show(from: sourceApplication)
    }

    func show(from sourceApplication: NSRunningApplication? = nil) {
        rememberFrontmostApplication(preferred: sourceApplication)
        viewModel.resetForPresentation()
        presentPanel()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func shutdown() {
        extensionExecutor.cancelAll()
        writingRunner.cancel()
        toast.dismiss()
        clipboard.flush()
        notesWindow.shutdown()
    }

    func showSettings() {
        hide()
        settingsWindow.present()
    }

    func showNotes() {
        hide()
        notesWindow.toggleVisibility()
    }

    func showQuickNote() {
        hide()
        notesWindow.presentQuickNote()
    }

    func showNotesAndToggleDictation() {
        hide()
        notesWindow.presentMostRecentAndToggleDictation()
    }

    func executeExtensionFromHotkey(
        _ command: LoadedExtensionCommand,
        sourceApplication: NSRunningApplication? = nil
    ) {
        rememberFrontmostApplication(preferred: sourceApplication)
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
            toast.show("Copied to the clipboard")

        case .pasteText(let text):
            clipboard.copy(text)
            pasteIntoPreviousApplication()

        case .replaceSelectedText(let text):
            replaceSelectedText(text)

        case .forceQuitApplication(let processIdentifier, let name):
            confirmForceQuit(processIdentifier: processIdentifier, name: name)

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
        var finalOrigin = panel.frame.origin
        if let visibleFrame = targetScreen?.visibleFrame {
            let size = panel.frame.size
            let x = visibleFrame.midX - size.width / 2
            let topInset = max(64, visibleFrame.height * 0.12)
            let y = max(visibleFrame.minY + 24, visibleFrame.maxY - size.height - topInset)
            finalOrigin = NSPoint(x: x, y: y)
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = 0
        panel.setFrameOrigin(NSPoint(x: finalOrigin.x, y: finalOrigin.y + (reduceMotion ? 0 : 8)))
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.01 : 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(finalOrigin)
        }
    }

    private func rememberFrontmostApplication(preferred: NSRunningApplication? = nil) {
        let reportedFrontmost = preferred ?? NSWorkspace.shared.frontmostApplication
        let frontmost = reportedFrontmost?.bundleIdentifier == Bundle.main.bundleIdentifier
            ? lastExternalApplication
            : reportedFrontmost
        guard let frontmost,
              frontmost.bundleIdentifier != Bundle.main.bundleIdentifier,
              !frontmost.isTerminated else {
            previousApplication = nil
            selectedTextContext = nil
            keyboardSelectionContext = nil
            focusedTextContext = nil
            return
        }
        lastExternalApplication = frontmost
        previousApplication = frontmost
        focusedTextContext = try? SelectedTextService.editableContext(in: frontmost.processIdentifier)
        selectedTextContext = try? SelectedTextService.selectionContext(in: frontmost.processIdentifier)
        keyboardSelectionContext = nil
    }

    private func rememberExternalApplicationActivation() {
        if let application = NSWorkspace.shared.frontmostApplication,
           application.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastExternalApplication = application
        }
        applicationActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self,
                      let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      application.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
                self.lastExternalApplication = application
            }
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
                if characters == "c", case .writingReview(let review) = self.viewModel.mode {
                    self.viewModel.copyWritingResult(review)
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
                if case .writingReview(let review) = self.viewModel.mode {
                    self.viewModel.pasteWritingResult(review)
                    return nil
                }
                self.viewModel.executeSelected()
                return nil
            }
            if event.keyCode == 53 {
                if case .output(_, _, .running(let canCancel)) = self.viewModel.mode, canCancel {
                    self.extensionExecutor.cancelAll()
                    self.writingRunner.cancel()
                    self.writingTaskID = nil
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
            viewModel.showOutput(
                title: command.command.title,
                text: "Running extension with the configured performance budget…",
                state: .running(canCancel: true)
            )
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
                } else if output == "__CONVERT_TIMEZONES__" {
                    self.viewModel.enter(.timezoneConverter)
                    if !self.panel.isVisible { self.presentPanel() }
                } else if output == "__FORCE_QUIT_APPLICATIONS__" {
                    self.viewModel.enter(.forceQuitPicker)
                    if !self.panel.isVisible { self.presentPanel() }
                } else if output == "__FORCE_QUIT_ALL_APPLICATIONS__" {
                    self.confirmForceQuitAllApplications()
                } else if output == "__OPEN_FORMATTER_WORKSPACE__" {
                    self.notesWindow.presentFormatterWorkspace()
                } else if output == "__OPEN_EMOJI_PICKER__" {
                    self.viewModel.enter(.emojiPicker)
                    if !self.panel.isVisible { self.presentPanel() }
                } else if let output {
                    self.viewModel.showOutput(title: command.command.title, text: output, state: .success)
                    if !self.panel.isVisible { self.presentPanel() }
                } else if isShell {
                    self.viewModel.showOutput(title: command.command.title, text: "Command completed.", state: .success)
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
        // Copy is the broadest public selected-text API on macOS. It works in
        // browser, Electron, Office, and custom editors that omit AXSelectedText.
        captureWritingSelectionWithKeyboard(from: previousApplication)
    }

    private func captureWritingSelectionWithKeyboard(from application: NSRunningApplication) {
        toast.show("Reading the highlight with Copy…", style: .working, duration: 4)
        KeyboardSelectionService.capture(from: application, clipboardHistory: clipboard) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let capture):
                self.previousApplication = application
                self.lastExternalApplication = application
                self.selectedTextContext = nil
                self.keyboardSelectionContext = capture
                self.showWritingReview(for: capture.text)
            case .failure(let keyboardError):
                do {
                    let target = try self.resolveSelectedTextTarget(preferred: application)
                    self.previousApplication = target.application
                    self.lastExternalApplication = target.application
                    self.keyboardSelectionContext = nil
                    self.selectedTextContext = target.context
                    self.showWritingReview(for: target.context.text)
                } catch {
                    self.presentError(
                        title: "Check Spelling & Grammar",
                        message: "RayPlacement could not read the current highlight by Copy or Accessibility. \(keyboardError.localizedDescription)"
                    )
                }
            }
        }
    }

    private func resolveSelectedTextTarget(
        preferred application: NSRunningApplication
    ) throws -> (application: NSRunningApplication, context: SelectedTextService.SelectionContext) {
        do {
            return (
                application,
                try SelectedTextService.selectionContext(in: application.processIdentifier)
            )
        } catch {
            let preferredError = error
            let alternatives = NSWorkspace.shared.runningApplications
                .filter {
                    !$0.isTerminated
                        && $0.processIdentifier != application.processIdentifier
                        && $0.bundleIdentifier != Bundle.main.bundleIdentifier
                        && $0.activationPolicy == .regular
                }
                .prefix(16)
                .compactMap { candidate -> (NSRunningApplication, SelectedTextService.SelectionContext)? in
                    guard let context = try? SelectedTextService.selectionContext(in: candidate.processIdentifier) else {
                        return nil
                    }
                    return (candidate, context)
                }

            // A focus race can make macOS briefly report the wrong source app.
            // Recover only when there is one unambiguous nonempty selection;
            // never guess between selections retained by multiple editors.
            guard alternatives.count == 1, let target = alternatives.first else {
                throw preferredError
            }
            return (target.0, target.1)
        }
    }

    private func showWritingReview(for text: String) {
        let provider = WritingProvider.qwen3Deep
        let modelTitle = LocalModelCatalog.descriptor(SettingsStore.shared.selectedModel(for: .writing)).title
        let taskID = UUID()
        writingTaskID = taskID
        viewModel.showOutput(
            title: "Check Spelling & Grammar",
            text: "Captured \(text.count) highlighted characters. Starting \(modelTitle)…",
            state: .running(canCancel: true)
        )
        if !panel.isVisible { presentPanel() }
        writingRunner.check(text, provider: provider, progress: { [weak self] message in
            guard let self, self.writingTaskID == taskID else { return }
            self.viewModel.showOutput(
                title: "Check Spelling & Grammar",
                text: message,
                state: .running(canCancel: true)
            )
        }) { [weak self] result in
            guard let self else { return }
            guard self.writingTaskID == taskID else { return }
            self.writingTaskID = nil
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
        guard let text = NSPasteboard.general.string(forType: .string) else {
            presentError(title: "Paste", message: "The clipboard does not contain text to paste.")
            return
        }
        guard let previousApplication else {
            presentError(title: "Paste", message: "The app that should receive the text is no longer available.")
            return
        }
        guard WindowManager.trusted(prompt: true) else {
            presentError(title: "Paste", message: "Enable RayPlacement in System Settings → Privacy & Security → Accessibility to paste automatically.")
            return
        }
        previousApplication.unhide()
        previousApplication.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            guard let self else { return }
            do {
                let context: SelectedTextService.SelectionContext
                if let focusedTextContext = self.focusedTextContext,
                   focusedTextContext.processIdentifier == previousApplication.processIdentifier {
                    context = focusedTextContext
                } else {
                    context = try SelectedTextService.editableContext(in: previousApplication.processIdentifier)
                }
                try SelectedTextService.replaceSelectedText(text, using: context)
                self.focusedTextContext = nil
                self.toast.show("Pasted as plain text")
            } catch SelectedTextService.SelectionError.selectionChanged {
                self.presentError(
                    title: "Paste",
                    message: "The original insertion point changed. Put the cursor back where you want the text and try again."
                )
            } catch {
                self.postPasteShortcut(into: previousApplication, successMessage: "Pasted as plain text")
            }
        }
    }

    private func postPasteShortcut(
        into application: NSRunningApplication,
        successMessage: String?
    ) {
        KeyboardSelectionService.paste(into: application) { [weak self] result in
            switch result {
            case .success:
                if let successMessage { self?.toast.show(successMessage) }
            case .failure(let error):
                self?.presentError(
                    title: "Paste",
                    message: "RayPlacement could not return keyboard focus and paste. The text remains on the clipboard. \(error.localizedDescription)"
                )
            }
        }
    }

    private func replaceSelectedText(_ text: String) {
        hide()
        toast.show("Reconnecting to the original highlight…", style: .working, duration: 12)
        guard let previousApplication else {
            presentError(title: "Replace Selected Text", message: "The app containing the original selection is no longer available.")
            return
        }
        guard WindowManager.trusted(prompt: true) else {
            presentError(title: "Replace Selected Text", error: SelectedTextService.SelectionError.accessibilityRequired)
            return
        }
        previousApplication.unhide()
        previousApplication.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            guard let self else { return }
            if self.selectedTextContext == nil,
               self.keyboardSelectionContext?.processIdentifier == previousApplication.processIdentifier {
                self.pasteReplacementWithKeyboard(text, in: previousApplication)
                return
            }
            do {
                let context = try self.replacementContext(in: previousApplication)
                self.selectedTextContext = context
                self.toast.show("Selection found · replacing text…", style: .working, duration: 10)
                try SelectedTextService.replaceSelectedText(text, using: context)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                    self?.finishDirectReplacement(text, using: context, retryCount: 0)
                }
            } catch SelectedTextService.SelectionError.replacementUnavailable {
                self.pasteReplacementFallback(text, in: previousApplication)
            } catch {
                self.presentError(title: "Replace Selected Text", error: error)
            }
        }
    }

    private func finishDirectReplacement(
        _ text: String,
        using context: SelectedTextService.SelectionContext,
        retryCount: Int
    ) {
        switch SelectedTextService.observeReplacement(text, using: context) {
        case .replaced, .changed, .unavailable:
            selectedTextContext = nil
            focusedTextContext = nil
            toast.show("Replaced the exact highlighted text")
        case .originalStillPresent:
            if retryCount == 0 {
                toast.show("The editor delayed the change · retrying once…", style: .working, duration: 8)
                do {
                    let refreshed = try SelectedTextService.reconnectedContext(using: context)
                    selectedTextContext = refreshed
                    try SelectedTextService.replaceSelectedText(text, using: refreshed)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in
                        self?.finishDirectReplacement(text, using: refreshed, retryCount: 1)
                    }
                } catch {
                    pasteReplacement(text, using: context)
                }
            } else {
                pasteReplacement(text, using: context)
            }
        }
    }

    private func pasteReplacementFallback(_ text: String, in application: NSRunningApplication) {
        do {
            let context = try replacementContext(in: application)
            pasteReplacement(text, using: context)
        } catch {
            if keyboardSelectionContext?.processIdentifier == application.processIdentifier {
                pasteReplacementWithKeyboard(text, in: application)
            } else {
                presentError(title: "Replace Selected Text", error: error)
            }
        }
    }

    private func pasteReplacementWithKeyboard(_ text: String, in application: NSRunningApplication) {
        guard !application.isTerminated else {
            presentError(title: "Replace Selected Text", message: "The source app is no longer running.")
            return
        }
        clipboard.copy(text)
        toast.show("Returning to the source selection…", style: .working, duration: 5)
        KeyboardSelectionService.paste(into: application) { [weak self] result in
            guard let self else { return }
            guard case .success = result else {
                let detail: String
                if case .failure(let error) = result { detail = error.localizedDescription } else { detail = "Unknown error." }
                self.presentError(
                    title: "Replace Selected Text",
                    message: "RayPlacement could not return focus and send Command-V. The corrected text is on the clipboard. \(detail)"
                )
                return
            }
            self.selectedTextContext = nil
            self.keyboardSelectionContext = nil
            self.focusedTextContext = nil
            self.toast.show("Replaced the highlighted text")
        }
    }

    private func pasteReplacement(
        _ text: String,
        using context: SelectedTextService.SelectionContext
    ) {
        do {
            let refreshed = (try? SelectedTextService.reconnectedContext(using: context)) ?? context
            try SelectedTextService.restoreSelection(using: refreshed)
            toast.show("Direct edit was unavailable · using a verified paste…", style: .working, duration: 8)
            clipboard.copy(text)
            guard let application = NSRunningApplication(processIdentifier: refreshed.processIdentifier) else {
                presentError(title: "Replace Selected Text", message: "The source app is no longer running. The corrected text is on the clipboard.")
                return
            }
            postPasteShortcut(into: application, successMessage: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
                guard let self else { return }
                switch SelectedTextService.observeReplacement(text, using: refreshed) {
                case .replaced, .changed, .unavailable:
                    self.selectedTextContext = nil
                    self.focusedTextContext = nil
                    self.toast.show("Replaced the exact highlighted text")
                case .originalStillPresent:
                    self.presentError(
                        title: "Replace Selected Text",
                        message: "The editor did not accept the replacement. The corrected text is on the clipboard, so you can paste it manually with Command-V."
                    )
                }
            }
        } catch {
            presentError(title: "Replace Selected Text", error: error)
        }
    }

    private func replacementContext(in application: NSRunningApplication) throws -> SelectedTextService.SelectionContext {
        if let captured = selectedTextContext,
           captured.processIdentifier == application.processIdentifier {
            return try SelectedTextService.reconnectedContext(using: captured)
        }
        return try SelectedTextService.selectionContext(in: application.processIdentifier)
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

    private func confirmForceQuit(processIdentifier: Int32, name: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Force Quit \(name)?"
        alert.informativeText = "The app will close immediately. Any unsaved work may be lost."
        alert.addButton(withTitle: "Force Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let application = NSRunningApplication(processIdentifier: processIdentifier),
              !application.isTerminated else {
            presentError(title: "Force Quit", message: "\(name) is no longer running.")
            return
        }
        if application.forceTerminate() {
            hide()
            toast.show("Force quit \(name)")
        } else {
            presentError(title: "Force Quit", message: "macOS did not allow \(name) to be force quit.")
        }
    }

    private func confirmForceQuitAllApplications() {
        let currentBundleIdentifier = Bundle.main.bundleIdentifier
        let applications = NSWorkspace.shared.runningApplications
            .filter {
                !$0.isTerminated
                    && $0.activationPolicy == .regular
                    && $0.bundleIdentifier != currentBundleIdentifier
                    && $0.localizedName != nil
            }
            .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }

        guard !applications.isEmpty else {
            toast.show("No other applications are running")
            return
        }

        let names = applications.compactMap(\.localizedName)
        let preview = names.prefix(8).joined(separator: ", ")
        let remaining = max(0, names.count - 8)
        let list = remaining == 0 ? preview : "\(preview), and \(remaining) more"

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Force Quit All \(applications.count) Applications?"
        alert.informativeText = "RayPlacement will stay open. The following apps will close immediately and unsaved work may be lost:\n\n\(list)"
        alert.addButton(withTitle: "Force Quit All")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            if !panel.isVisible { presentPanel() }
            return
        }

        var closed = 0
        var failed: [String] = []
        for application in applications where application.bundleIdentifier != currentBundleIdentifier {
            if application.forceTerminate() {
                closed += 1
            } else {
                failed.append(application.localizedName ?? "Unknown application")
            }
        }
        hide()
        if failed.isEmpty {
            toast.show("Force quit \(closed) applications — RayPlacement stayed open")
        } else {
            presentError(
                title: "Force Quit All",
                message: "Closed \(closed) applications. macOS did not allow: \(failed.joined(separator: ", "))."
            )
        }
    }

    private func applyWindowLayout(_ layout: WindowLayout) {
        let target = previousApplication
        hide()
        target?.activate(options: [.activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            guard let self else { return }
            switch WindowManager.apply(layout, to: target?.processIdentifier) {
            case .success: self.toast.show("Applied \(layout.title)")
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

        case .openQuickNote:
            showQuickNote()

        case .toggleNoteDictation:
            showNotesAndToggleDictation()

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
        viewModel.showOutput(title: title, text: message, state: .error)
        if !panel.isVisible { presentPanel() }
    }
}
