import AppKit
import ApplicationServices
import Combine
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
    private lazy var extensionFormWindow = ExtensionFormWindowController()
    private let writingChecker = RuleBasedWritingChecker()
    // The activity shelf also hosts lightweight Apple Music controls, so it is
    // available from launch rather than only after Notes has been opened once.
    private let notesWindow = NotesWindowController()
    private let terminalModel: DeveloperTerminalModel
    private lazy var focusedFileLauncherWindow = FocusedFileLauncherWindowController()
    private lazy var passwordGeneratorWindow = PasswordGeneratorWindowController()
    private lazy var extensionDevelopmentWindow = ExtensionDevelopmentWindowController()
    private lazy var formatterWindow = FormatterWindowController()
    private lazy var workflowWindow = WorkflowWindowController { [weak self] workflow in
        self?.executeWorkflow(workflow)
    }
    private var previousApplication: NSRunningApplication?
    private var lastExternalApplication: NSRunningApplication?
    private var selectedTextContext: SelectedTextService.SelectionContext?
    private var keyboardSelectionContext: KeyboardSelectionService.Capture?
    private var focusedTextContext: SelectedTextService.SelectionContext?
    private var writingTaskID: UUID?
    private var localEventMonitor: Any?
    private var applicationActivationObserver: NSObjectProtocol?
    private var modeSubscription: AnyCancellable?
    private let updateService: UpdateService
    private lazy var developerGrammarSettingsWindow = DeveloperGrammarSettingsWindowController(settings: .shared)
    private lazy var permissionWindow: NSWindowController = {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 430), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        LimaWindowChrome.configure(window, title: "Lima Permission Center", accessibilityLabel: "Lima Permission Center")
        window.contentView = NSHostingView(rootView: LimaTypographyRoot(content: PermissionCenterView(center: .shared)))
        return NSWindowController(window: window)
    }()
    private lazy var settingsWindow = SettingsWindowController(
        settings: .shared,
        viewModel: viewModel,
        updateService: updateService,
        reloadExtensions: { [weak self] in self?.viewModel.reloadExtensions() }
    )

    init(updateService: UpdateService) {
        let clipboard = ClipboardHistoryService.shared
        self.clipboard = clipboard
        self.viewModel = LauncherViewModel(clipboard: clipboard)
        self.terminalModel = DeveloperTerminalModel()
        self.panel = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 452))
        self.updateService = updateService
        super.init()

        viewModel.delegate = self
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: LimaTypographyRoot(content: LauncherView(viewModel: viewModel, terminalModel: terminalModel)))
        modeSubscription = viewModel.$mode
            .removeDuplicates()
            .sink { [weak self] mode in
                self?.resizePanel(for: mode, animated: true)
            }
        resizePanel(for: viewModel.mode, animated: false)
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
        viewModel.setContextualSelection(selectedTextContext?.text)
        viewModel.resetForPresentation()
        presentPanel()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func shutdown() {
        extensionExecutor.cancelAll()
        writingChecker.cancel()
        toast.dismiss()
        clipboard.flush()
        notesWindow.shutdown()
        terminalModel.shutdown()
        formatterWindow.shutdown()
        workflowWindow.shutdown()
    }

    func showSettings() {
        hide()
        settingsWindow.present()
    }

    func showDeveloperGrammarSettings() {
        hide()
        developerGrammarSettingsWindow.present()
    }

    func showNotes() {
        hide()
        notesWindow.toggleVisibility()
    }

    func showQuickNote() {
        hide()
        notesWindow.presentQuickNote()
    }

    func dockNotesLeft() {
        hide()
        notesWindow.presentDockedLeft()
    }

    func dockNotesRight() {
        hide()
        notesWindow.presentDockedRight()
    }

    func showNotesAndToggleDictation() {
        hide()
        notesWindow.presentMostRecentAndToggleDictation()
    }

    func showDeveloperTerminal() {
        viewModel.enter(.terminal)
        presentPanel()
        DispatchQueue.main.async { [weak self] in
            self?.terminalModel.startIfNeeded()
            self?.terminalModel.focus()
        }
    }
    func showFocusedFileLauncher() { hide(); focusedFileLauncherWindow.present() }

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

        case .copyText(let text):
            clipboard.copy(text)
            hide()
            toast.show("Copied to the clipboard")

        case .pasteText(let text):
            pasteTextIntoPreviousApplication(
                text,
                successMessage: item.id.hasPrefix("emoji.") ? "Pasted \(text)" : "Pasted text"
            )

        case .replaceSelectedText(let text):
            replaceSelectedText(text)

        case .saveSelectionToQuickNote(let text):
            hide()
            notesWindow.store.createQuickNote(with: text)
            notesWindow.presentQuickNote()

        case .checkSelectedText:
            performWritingCheck()

        case .applicationOperation(let operation, let processIdentifier, let name):
            dispatchApplicationSelection(operation: operation, processIdentifier: processIdentifier, name: name)

        case .displayOperation(let operation, let displayIdentifier, let name):
            dispatchDisplaySelection(operation: operation, displayIdentifier: displayIdentifier, name: name)

        case .enterMode(let mode):
            viewModel.enter(mode)

        case .extensionCommand(let command):
            executeExtension(command)

        case .universalSearch(let result):
            routeUniversalSearchResult(result)

        case .workflow(let id):
            guard let workflow = WorkflowStore.shared.workflows.first(where: { $0.id == id }) else {
                presentError(title: "Workflow", message: "That workflow no longer exists.")
                return
            }
            executeWorkflow(workflow)

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

    private func resizePanel(for mode: LauncherMode, animated: Bool) {
        let targetScreen = screenUnderPointer() ?? NSScreen.main ?? NSScreen.screens.first
        let desiredSize = LauncherPanelLayout.size(for: mode, density: SettingsStore.shared.interfaceDensity)
        let size: NSSize
        if let visibleFrame = targetScreen?.visibleFrame {
            size = NSSize(
                width: min(desiredSize.width, max(320, visibleFrame.width - 80)),
                height: min(desiredSize.height, max(240, visibleFrame.height - 100))
            )
        } else {
            size = desiredSize
        }

        var frame = panel.frame
        let center = NSPoint(x: frame.midX, y: frame.midY)
        frame.size = size
        frame.origin = NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)

        guard animated, panel.isVisible else {
            panel.setFrame(frame, display: panel.isVisible)
            return
        }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.01 : 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
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
            context.duration = reduceMotion ? 0.01 : 0.22
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

            // In terminal mode the PTY receives every ordinary keystroke.
            // Escape is the only launcher-level action, allowing the user to
            // leave the terminal without adding a second command surface.
            if viewModel.mode == .terminal {
                if event.keyCode == 53 {
                    viewModel.enter(.root)
                    return nil
                }
                return event
            }

            if flags.contains(.command) {
                if characters == "," {
                    self.showSettings()
                    return nil
                }
                if characters == "q" {
                    NSApp.terminate(nil)
                    return nil
                }
                if characters == "k", self.viewModel.mode == .root {
                    self.viewModel.enter(.history)
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
            if self.viewModel.isEmojiPicker {
                switch event.keyCode {
                case 123: // Left arrow
                    self.viewModel.moveEmojiSelection(rowDelta: 0, columnDelta: -1)
                    return nil
                case 124: // Right arrow
                    self.viewModel.moveEmojiSelection(rowDelta: 0, columnDelta: 1)
                    return nil
                case 125: // Down arrow
                    self.viewModel.moveEmojiSelection(rowDelta: 1, columnDelta: 0)
                    return nil
                case 126: // Up arrow
                    self.viewModel.moveEmojiSelection(rowDelta: -1, columnDelta: 0)
                    return nil
                case 116: // Page Up
                    self.viewModel.moveEmojiPage(by: -1)
                    return nil
                case 121: // Page Down
                    self.viewModel.moveEmojiPage(by: 1)
                    return nil
                case 115: // Home
                    self.viewModel.selectFirstEmoji()
                    return nil
                case 119: // End
                    self.viewModel.selectLastEmoji()
                    return nil
                case 49: // Space executes without inserting a search space
                    self.viewModel.executeSelected()
                    return nil
                default:
                    break
                }
            }
            if event.keyCode == 125 || (controlOnly && characters == "n") {
                self.viewModel.moveSelection(by: self.viewModel.isEmojiPicker ? LauncherViewModel.emojiGridColumnCount : 1)
                return nil
            }
            if event.keyCode == 126 || (controlOnly && characters == "p") {
                self.viewModel.moveSelection(by: self.viewModel.isEmojiPicker ? -LauncherViewModel.emojiGridColumnCount : -1)
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
                    self.writingChecker.cancel()
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
        if command.command.action.type == .form {
            hide()
            extensionFormWindow.present(command: command) { [weak self] values, completion in
                self?.extensionExecutor.executeForm(command, values: values, completion: completion)
            }
            return
        }

        let isShell = command.command.action.type == .shell
        let runsInBackground = isShell && command.command.runInBackground == true
        if runsInBackground {
            hide()
            toast.show("\(command.command.title) is running", style: .working, duration: 3_600)
        } else if isShell {
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
            case .success(.completed(let output)):
                if let output, !output.isEmpty {
                    if runsInBackground {
                        self.toast.show("\(command.command.title) completed", style: .success)
                    } else {
                        self.viewModel.showOutput(title: command.command.title, text: output, state: .success)
                        if !self.panel.isVisible { self.presentPanel() }
                    }
                } else if isShell {
                    if runsInBackground {
                        self.toast.show("\(command.command.title) completed", style: .success)
                    } else {
                        self.viewModel.showOutput(title: command.command.title, text: "Command completed.", state: .success)
                        if !self.panel.isVisible { self.presentPanel() }
                    }
                }

            case .success(.native(let action)):
                self.dispatchNativeAction(action)

            case .success(.nativeChain(let actions)):
                self.dispatchNativeChain(actions)

            case .failure(let error):
                if runsInBackground {
                    self.toast.show("\(command.command.title) failed · \(error.localizedDescription)", style: .error, duration: 5)
                } else {
                    self.presentError(title: command.command.title, error: error)
                }
            }
        }
    }

    /// Dispatches the stable, capability-oriented native API exposed to
    /// extension manifests. Bundled commands use this same path as user
    /// extensions; only the host implementation knows about native windows.
    private func dispatchNativeAction(_ action: ExtensionAction, completion: @escaping () -> Void = {}) {
        switch action.type {
        case .clipboard:
            switch action.operation ?? "copy" {
            case "paste":
                pasteTextIntoPreviousApplication(action.value, successMessage: "Pasted text", completion: completion)
                return
            case "pastePlainText":
                pasteIntoPreviousApplication(completion: completion)
                return
            case "copy":
                clipboard.copy(action.value)
                toast.show("Copied to the clipboard")
            default:
                presentError(title: "Clipboard", message: "Unsupported clipboard operation: \(action.operation ?? "")")
            }
            completion()

        case .picker:
            let operation = action.operation ?? ""
            let query = action.parameters?["query"] ?? action.arguments?.first
            switch operation {
            case "emoji":
                viewModel.enter(.picker(.emoji), query: query ?? "")
                presentPanel()
            case "application":
                viewModel.enterApplicationPicker(
                    operation: action.parameters?["applicationOperation"] ?? "forceQuit",
                    query: action.parameters?["query"] ?? action.parameters?["applicationQuery"] ?? ""
                )
                presentPanel()
            case "display":
                viewModel.enterDisplayPicker(operation: action.parameters?["windowOperation"] ?? "moveToDisplay")
                presentPanel()
            case "file":
                focusedFileLauncherWindow.present()
            case "timezone":
                viewModel.enter(.picker(.timezone), query: query ?? "")
                presentPanel()
            case "password":
                passwordGeneratorWindow.present()
            default:
                presentError(title: "Picker", message: "Unsupported picker operation: \(operation)")
            }
            completion()

        case .workspace:
            switch action.operation ?? "" {
            case "writingReview":
                performWritingCheck()
            case "focusedFileLauncher":
                focusedFileLauncherWindow.present()
            case "formatter":
                formatterWindow.present()
            case "extensionDevelopment":
                extensionDevelopmentWindow.present()
            case "repairExtensions":
                toast.show(viewModel.repairBundledExtensions())
            case "uninstall":
                presentUninstaller()
            default:
                presentError(title: "Workspace", message: "Unsupported workspace operation: \(action.operation ?? "")")
            }
            completion()

        case .window:
            let operation = action.operation ?? action.value
            let target = previousApplication ?? lastExternalApplication
            target?.activate(options: [.activateIgnoringOtherApps])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
                guard let self else { return }
                switch WindowManager.apply(operation, to: target?.processIdentifier) {
                case .success:
                    self.toast.show("Applied \(WindowLayout(rawValue: operation)?.title ?? operation)")
                case .failure(let error):
                    self.presentError(title: "Window Management", error: error)
                }
                completion()
            }

        case .application:
            dispatchApplicationAction(action, completion: completion)

        case .system:
            dispatchSystemAction(action, completion: completion)

        case .form, .shell, .url, .file:
            // These action types are completed by ExtensionExecutor and should
            // never arrive here. Keep the fallback explicit for safety.
            completion()
        }
    }

    private func dispatchNativeChain(
        _ actions: [ExtensionAction],
        index: Int = 0,
        completion: @escaping () -> Void = {}
    ) {
        guard !actions.isEmpty else { completion(); return }
        guard actions.count <= ExtensionAction.maximumNativeChainLength else {
            presentError(title: "Extension Chain", message: "Action chains may contain at most eight actions.")
            completion()
            return
        }
        guard actions.indices.contains(index) else { completion(); return }
        dispatchNativeAction(actions[index]) { [weak self] in
            guard let self else { completion(); return }
            guard index + 1 < actions.count else { completion(); return }
            self.dispatchNativeChain(actions, index: index + 1, completion: completion)
        }
    }

    private func dispatchDisplaySelection(
        operation: String,
        displayIdentifier: CGDirectDisplayID,
        name: String,
        completion: @escaping () -> Void = {}
    ) {
        let target = previousApplication ?? lastExternalApplication
        target?.activate(options: [.activateIgnoringOtherApps])
        hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            guard let self else { completion(); return }
            switch WindowManager.apply(operation, to: target?.processIdentifier, displayIdentifier: displayIdentifier) {
            case .success:
                self.toast.show("Moved window to \(name)")
            case .failure(let error):
                self.presentError(title: "Display", error: error)
            }
            completion()
        }
    }

    private func dispatchApplicationAction(_ action: ExtensionAction, completion: @escaping () -> Void) {
        let operation = action.operation ?? ""
        let target = action.target ?? "frontmost"
        if operation == "forceQuitAll" || operation == "quitAll" {
            if operation == "forceQuitAll" {
                confirmForceQuitAllApplications(completion: completion)
            } else {
                quitAllApplications(completion: completion)
            }
            return
        }
        if target == "picker" {
            viewModel.enterApplicationPicker(
                operation: operation,
                query: action.parameters?["query"] ?? action.parameters?["applicationQuery"] ?? ""
            )
            presentPanel()
            completion()
            return
        }

        let application: NSRunningApplication?
        if let bundleIdentifier = action.parameters?["bundleIdentifier"], !bundleIdentifier.isEmpty {
            application = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleIdentifier }
        } else if target == "frontmost" || target == "previous" {
            application = previousApplication ?? lastExternalApplication
        } else {
            application = previousApplication ?? lastExternalApplication
        }
        guard let application else {
            presentError(title: operation.capitalized, message: "No target application is available.")
            completion()
            return
        }
        dispatchApplicationSelection(
            operation: operation,
            processIdentifier: application.processIdentifier,
            name: application.localizedName ?? "Application",
            completion: completion
        )
    }

    private func dispatchApplicationSelection(
        operation: String,
        processIdentifier: Int32,
        name: String,
        completion: @escaping () -> Void = {}
    ) {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier), !application.isTerminated else {
            presentError(title: operation.capitalized, message: "\(name) is no longer running.")
            completion()
            return
        }
        switch operation {
        case "forceQuit":
            confirmForceQuit(processIdentifier: processIdentifier, name: name, completion: completion)
        case "restart":
            restartApplication(application, name: name, completion: completion)
        case "quit":
            hide()
            if application.terminate() {
                toast.show("Quit \(name)")
            } else {
                presentError(title: "Quit Application", message: "macOS did not allow \(name) to quit.")
            }
            completion()
        case "activate":
            application.activate(options: [.activateIgnoringOtherApps])
            completion()
        case "hide":
            _ = application.hide()
            completion()
        case "unhide":
            _ = application.unhide()
            application.activate(options: [.activateIgnoringOtherApps])
            completion()
        default:
            presentError(title: "Application", message: "Unsupported application operation: \(operation)")
            completion()
        }
    }

    private func restartApplication(
        _ application: NSRunningApplication,
        name: String,
        completion: @escaping () -> Void = {}
    ) {
        guard let bundleURL = application.bundleURL else {
            presentError(title: "Restart Application", message: "The application bundle for \(name) is unavailable.")
            completion()
            return
        }
        hide()
        guard application.terminate() else {
            presentError(title: "Restart Application", message: "macOS did not allow \(name) to quit gracefully.")
            completion()
            return
        }
        toast.show("Restarting \(name)…", style: .working, duration: 8)
        waitForTermination(application, bundleURL: bundleURL, name: name, attemptsRemaining: 20, completion: completion)
    }

    private func waitForTermination(
        _ application: NSRunningApplication,
        bundleURL: URL,
        name: String,
        attemptsRemaining: Int,
        completion: @escaping () -> Void
    ) {
        if application.isTerminated {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { [weak self] _, error in
                guard let self else { return }
                if let error {
                    self.presentError(title: "Restart Application", error: error)
                } else {
                    self.toast.show("Restarted \(name)")
                }
                completion()
            }
            return
        }
        guard attemptsRemaining > 0 else {
            if application.forceTerminate() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.waitForTermination(application, bundleURL: bundleURL, name: name, attemptsRemaining: 3, completion: completion)
                }
            } else {
                presentError(title: "Restart Application", message: "\(name) did not terminate.")
                completion()
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.waitForTermination(application, bundleURL: bundleURL, name: name, attemptsRemaining: attemptsRemaining - 1, completion: completion)
        }
    }

    private func dispatchSystemAction(_ action: ExtensionAction, completion: @escaping () -> Void) {
        let operation = action.operation ?? action.value
        let destructive = action.confirmation == true || ["logout", "restart", "shutdown"].contains(operation)
        if destructive && !confirmSystemOperation(operation) {
            completion()
            return
        }
        hide()
        switch operation {
        case "lock":
            postSystemShortcut(keyCode: 12, flags: [.maskCommand, .maskControl])
            completion()
        case "sleep":
            runSystemExecutable("/usr/bin/pmset", arguments: ["sleepnow"], title: "Sleep", completion: completion)
        case "screenSaver":
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"))
            completion()
        case "logout":
            runSystemAppleScript("tell application \"System Events\" to log out", title: "Log Out", completion: completion)
        case "restart":
            runSystemExecutable("/sbin/shutdown", arguments: ["-r", "now"], title: "Restart Mac", completion: completion)
        case "shutdown":
            runSystemExecutable("/sbin/shutdown", arguments: ["-h", "now"], title: "Shut Down", completion: completion)
        default:
            presentError(title: "System", message: "Unsupported system operation: \(operation)")
            completion()
        }
    }

    private func confirmSystemOperation(_ operation: String) -> Bool {
        let title: String
        let detail: String
        switch operation {
        case "logout":
            title = "Log Out of This Mac?"
            detail = "Open applications may be closed and unsaved work could be lost."
        case "restart":
            title = "Restart This Mac?"
            detail = "Open applications may be closed and unsaved work could be lost."
        case "shutdown":
            title = "Shut Down This Mac?"
            detail = "Open applications may be closed and unsaved work could be lost."
        default:
            title = "Perform System Action?"
            detail = "Continue with the requested system operation?"
        }
        return LimaConfirmationService.confirm(
            title: title,
            detail: detail,
            confirmTitle: operation == "shutdown" ? "Shut Down" : operation == "restart" ? "Restart" : "Log Out",
            deliberate: true
        )
    }

    private func quitAllApplications(completion: @escaping () -> Void = {}) {
        let currentBundleIdentifier = Bundle.main.bundleIdentifier
        let applications = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.activationPolicy == .regular && $0.bundleIdentifier != currentBundleIdentifier
        }
        guard !applications.isEmpty else {
            toast.show("No other applications are running")
            completion()
            return
        }
        let names = applications.compactMap(\.localizedName)
        let detail = "Ask \(applications.count) normal user application\(applications.count == 1 ? "" : "s") to quit gracefully?\n\n\(names.prefix(8).joined(separator: ", "))"
        guard LimaConfirmationService.confirm(
            title: "Quit All Applications?",
            detail: detail,
            confirmTitle: "Quit All",
            severity: .warning,
            deliberate: true
        ) else {
            completion()
            return
        }
        for application in applications { _ = application.terminate() }
        hide()
        toast.show("Asked \(applications.count) applications to quit")
        completion()
    }

    private func runSystemAppleScript(_ source: String, title: String, completion: @escaping () -> Void = {}) {
        guard let script = NSAppleScript(source: source) else {
            presentError(title: title, message: "The native system request could not be created.")
            completion()
            return
        }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        if let error {
            presentError(title: title, message: error[NSAppleScript.errorMessage] as? String ?? "macOS rejected the request.")
        }
        completion()
    }

    private func presentUninstaller() {
        guard LimaConfirmationService.confirm(
            title: "Move Lima to Trash?",
            detail: "Lima will close. Your notes, extensions, and settings stay on this Mac.",
            confirmTitle: "Move to Trash",
            severity: .warning,
            deliberate: true
        ),
              let script = Bundle.main.url(forResource: "Uninstall Lima", withExtension: "command") else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [script.path, "--confirmed"]
        try? process.run()
    }

    func runStealthGrammar() {
        guard SettingsStore.shared.stealthGrammarEnabled else { return }
        guard let previousApplication, !previousApplication.isTerminated else {
            toast.show("Select text first", style: .error, duration: 2.2)
            return
        }
        guard WindowManager.trusted(prompt: true) else {
            toast.show("Accessibility access is required", style: .error, duration: 2.8)
            return
        }
        hide()
        captureWritingSelectionWithKeyboard(from: previousApplication, stealth: true)
    }

    private func performWritingCheck() {
        guard let previousApplication else {
            presentError(title: "Check Spelling & Grammar", message: "Select text in another app, then open Lima and run this command.")
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

    private func captureWritingSelectionWithKeyboard(from application: NSRunningApplication, stealth: Bool = false) {
        let retainedAccessibilityContext = selectedTextContext.flatMap { context in
            context.processIdentifier == application.processIdentifier ? context : nil
        }
        if stealth {
            toast.showStealth("Editing…")
        } else {
            toast.show("Reading the highlight with Copy…", style: .working, duration: 3_600)
        }
        KeyboardSelectionService.capture(from: application, clipboardHistory: clipboard) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let capture):
                self.previousApplication = application
                self.lastExternalApplication = application
                // Preserve the stronger AX range when Copy and Accessibility
                // agree. Keyboard capture remains available as a fallback.
                self.selectedTextContext = retainedAccessibilityContext?.text == capture.text
                    ? retainedAccessibilityContext
                    : nil
                self.keyboardSelectionContext = capture
                if stealth {
                    self.runStealthCorrection(for: capture.text)
                } else {
                    self.showWritingReview(for: capture.text)
                }
            case .failure(let keyboardError):
                do {
                    let target = try self.resolveSelectedTextTarget(preferred: application)
                    self.previousApplication = target.application
                    self.lastExternalApplication = target.application
                    self.keyboardSelectionContext = nil
                    self.selectedTextContext = target.context
                    if stealth {
                        self.runStealthCorrection(for: target.context.text)
                    } else {
                        self.showWritingReview(for: target.context.text)
                    }
                } catch {
                    if stealth {
                        self.selectedTextContext = nil
                        self.keyboardSelectionContext = nil
                        self.focusedTextContext = nil
                        self.toast.showStealth("Couldn’t read selection", style: .error, duration: 2.4)
                    } else {
                        self.presentError(
                            title: "Check Spelling & Grammar",
                            message: "Lima could not read the current highlight by Copy or Accessibility. \(keyboardError.localizedDescription)"
                        )
                    }
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

    private func runStealthCorrection(for text: String) {
        let taskID = UUID()
        writingTaskID = taskID
        toast.showStealth("Editing…")
        writingChecker.checkStealth(text, progress: { [weak self] message in
            guard let self, self.writingTaskID == taskID else { return }
            self.toast.showStealth(message)
        }) { [weak self] result in
            guard let self, self.writingTaskID == taskID else { return }
            self.writingTaskID = nil
            switch result {
            case .success(let corrected) where corrected == text:
                self.selectedTextContext = nil
                self.keyboardSelectionContext = nil
                self.focusedTextContext = nil
                self.toast.showStealth("No changes needed", style: .success, duration: 1.6)
            case .success(let corrected):
                self.replaceStealthText(corrected)
            case .failure:
                self.selectedTextContext = nil
                self.keyboardSelectionContext = nil
                self.focusedTextContext = nil
                self.toast.showStealth("Couldn’t edit selection", style: .error, duration: 2.4)
            }
        }
    }

    private func replaceStealthText(_ text: String) {
        guard let application = previousApplication, !application.isTerminated else {
            clipboard.copy(text)
            toast.showStealth("Couldn’t replace selection · corrected text copied", style: .error, duration: 3.2)
            return
        }
        application.unhide()
        application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            guard let self else { return }
            if self.selectedTextContext == nil,
               self.keyboardSelectionContext?.processIdentifier == application.processIdentifier {
                self.pasteStealthReplacement(text, into: application)
                return
            }
            do {
                let context = try self.replacementContext(in: application)
                try SelectedTextService.replaceSelectedText(text, using: context)
                self.selectedTextContext = nil
                self.keyboardSelectionContext = nil
                self.focusedTextContext = nil
                self.toast.showStealth("Text corrected", style: .success, duration: 1.6)
            } catch SelectedTextService.SelectionError.replacementUnavailable {
                self.pasteStealthReplacement(text, into: application)
            } catch {
                self.clipboard.copy(text)
                self.toast.showStealth("Couldn’t replace selection · corrected text copied", style: .error, duration: 3.2)
            }
        }
    }

    private func pasteStealthReplacement(_ text: String, into application: NSRunningApplication) {
        KeyboardSelectionService.paste(text, into: application, clipboardHistory: clipboard) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.selectedTextContext = nil
                self.keyboardSelectionContext = nil
                self.focusedTextContext = nil
                self.toast.showStealth("Text corrected", style: .success, duration: 1.6)
            case .failure:
                self.clipboard.copy(text)
                self.toast.showStealth("Couldn’t replace selection · corrected text copied", style: .error, duration: 3.2)
            }
        }
    }

    private func showWritingReview(for text: String) {
        let taskID = UUID()
        writingTaskID = taskID
        hide()
        toast.show("Checking \(text.count) characters locally…", style: .working, duration: 3_600)
        writingChecker.check(text, progress: { [weak self] message in
            guard let self, self.writingTaskID == taskID else { return }
            self.toast.show(message, style: .working, duration: 3_600)
        }) { [weak self] result in
            guard let self else { return }
            guard self.writingTaskID == taskID else { return }
            self.writingTaskID = nil
            switch result {
            case .success(let review):
                self.toast.show("Correction verified · opening review", style: .success)
                self.viewModel.showWritingReview(review)
                if !self.panel.isVisible { self.presentPanel() }
            case .failure(let error):
                self.toast.dismiss()
                self.presentError(title: "Check Spelling & Grammar", error: error)
            }
        }
    }

    private func pasteIntoPreviousApplication(completion: @escaping () -> Void = {}) {
        hide()
        guard let text = NSPasteboard.general.string(forType: .string) else {
            presentError(title: "Paste", message: "The clipboard does not contain text to paste.")
            completion()
            return
        }
        guard let previousApplication else {
            presentError(title: "Paste", message: "The app that should receive the text is no longer available.")
            completion()
            return
        }
        guard WindowManager.trusted(prompt: true) else {
            presentError(title: "Paste", message: "Enable Lima in System Settings → Privacy & Security → Accessibility to paste automatically.")
            completion()
            return
        }
        previousApplication.unhide()
        previousApplication.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            guard let self else { completion(); return }
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
                completion()
            } catch SelectedTextService.SelectionError.selectionChanged {
                self.presentError(
                    title: "Paste",
                    message: "The original insertion point changed. Put the cursor back where you want the text and try again."
                )
                completion()
            } catch {
                self.postPasteShortcut(
                    into: previousApplication,
                    successMessage: "Pasted as plain text",
                    completion: completion
                )
            }
        }
    }

    private func pasteTextIntoPreviousApplication(
        _ text: String,
        successMessage: String,
        completion: @escaping () -> Void = {}
    ) {
        hide()
        guard let previousApplication, !previousApplication.isTerminated else {
            clipboard.copy(text)
            presentError(title: "Paste", message: "The source app is no longer available. The text was copied instead.")
            completion()
            return
        }
        guard WindowManager.trusted(prompt: true) else {
            clipboard.copy(text)
            presentError(title: "Paste", message: "Enable Lima in Accessibility to paste automatically. The text was copied instead.")
            completion()
            return
        }
        previousApplication.unhide()
        previousApplication.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            guard let self else { completion(); return }
            // Prefer the live Accessibility insertion range. This avoids a
            // clipboard/key-event race in native editors and is especially
            // important for multi-scalar emoji. Browser, Electron, Office,
            // terminal, and protected fields fall back to an atomic Cmd-V.
            do {
                let context: SelectedTextService.SelectionContext
                if let focused = self.focusedTextContext,
                   focused.processIdentifier == previousApplication.processIdentifier {
                    context = focused
                } else {
                    context = try SelectedTextService.editableContext(in: previousApplication.processIdentifier)
                }
                try SelectedTextService.replaceSelectedText(text, using: context)
                self.focusedTextContext = nil
                self.toast.show(successMessage)
                completion()
            } catch {
                self.pasteTextWithKeyboard(
                    text,
                    into: previousApplication,
                    successMessage: successMessage,
                    completion: completion
                )
            }
        }
    }

    private func pasteTextWithKeyboard(
        _ text: String,
        into application: NSRunningApplication,
        successMessage: String,
        completion: @escaping () -> Void = {}
    ) {
        KeyboardSelectionService.paste(text, into: application, clipboardHistory: clipboard) { [weak self] result in
            switch result {
            case .success:
                self?.toast.show(successMessage)
            case .failure(let error):
                self?.clipboard.copy(text)
                self?.presentError(title: "Paste", message: "Lima could not restore focus and paste. The text was copied instead. \(error.localizedDescription)")
            }
            completion()
        }
    }

    private func postPasteShortcut(
        into application: NSRunningApplication,
        successMessage: String?,
        completion: @escaping () -> Void = {}
    ) {
        KeyboardSelectionService.paste(into: application) { [weak self] result in
            switch result {
            case .success:
                if let successMessage { self?.toast.show(successMessage) }
            case .failure(let error):
                self?.presentError(
                    title: "Paste",
                    message: "Lima could not return keyboard focus and paste. The text remains on the clipboard. \(error.localizedDescription)"
                )
            }
            completion()
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
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
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { [weak self] in
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
        toast.show("Returning to the source selection…", style: .working, duration: 5)
        KeyboardSelectionService.paste(
            text,
            into: application,
            clipboardHistory: clipboard
        ) { [weak self] result in
            guard let self else { return }
            guard case .success = result else {
                let detail: String
                if case .failure(let error) = result { detail = error.localizedDescription } else { detail = "Unknown error." }
                self.clipboard.copy(text)
                self.presentError(
                    title: "Replace Selected Text",
                    message: "Lima could not return focus and send Command-V. The corrected text is on the clipboard. \(detail)"
                )
                return
            }
            self.selectedTextContext = nil
            self.keyboardSelectionContext = nil
            self.focusedTextContext = nil
            self.toast.show("Correction pasted into the highlight")
        }
    }

    private func pasteReplacement(
        _ text: String,
        using context: SelectedTextService.SelectionContext
    ) {
        do {
            let refreshed = (try? SelectedTextService.reconnectedContext(using: context)) ?? context
            try SelectedTextService.restoreSelection(using: refreshed)
            toast.show("Direct edit was unavailable · pasting into the restored highlight…", style: .working, duration: 8)
            guard let application = NSRunningApplication(processIdentifier: refreshed.processIdentifier) else {
                clipboard.copy(text)
                presentError(title: "Replace Selected Text", message: "The source app is no longer running. The correction is on the clipboard.")
                return
            }
            KeyboardSelectionService.paste(
                text,
                into: application,
                clipboardHistory: clipboard
            ) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.finishPastedReplacement(text, using: refreshed, attempt: 0)
                case .failure(let error):
                    self.clipboard.copy(text)
                    self.presentError(
                        title: "Replace Selected Text",
                        message: "Automatic paste was blocked. The correction is on the clipboard. \(error.localizedDescription)"
                    )
                }
            }
        } catch {
            presentError(title: "Replace Selected Text", error: error)
        }
    }

    private func finishPastedReplacement(
        _ text: String,
        using context: SelectedTextService.SelectionContext,
        attempt: Int
    ) {
        switch SelectedTextService.observeReplacement(text, using: context) {
        case .replaced, .changed, .unavailable:
            selectedTextContext = nil
            keyboardSelectionContext = nil
            focusedTextContext = nil
            toast.show("Replaced the exact highlighted text")
        case .originalStillPresent where attempt < 5:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
                self?.finishPastedReplacement(text, using: context, attempt: attempt + 1)
            }
        case .originalStillPresent:
            // Command-V was accepted, but some web editors keep stale AX text
            // for seconds. Avoid a false failure or a destructive second paste.
            selectedTextContext = nil
            keyboardSelectionContext = nil
            focusedTextContext = nil
            toast.show("Replacement sent to the highlighted text", style: .success, duration: 2.4)
        }
    }

    private func replacementContext(in application: NSRunningApplication) throws -> SelectedTextService.SelectionContext {
        if let captured = selectedTextContext,
           captured.processIdentifier == application.processIdentifier {
            return try SelectedTextService.reconnectedContext(using: captured)
        }
        return try SelectedTextService.selectionContext(in: application.processIdentifier)
    }

    private func confirmForceQuit(
        processIdentifier: Int32,
        name: String,
        completion: @escaping () -> Void = {}
    ) {
        guard LimaConfirmationService.confirm(
            title: "Force Quit \(name)?",
            detail: "The app will close immediately. Any unsaved work may be lost.",
            confirmTitle: "Force Quit",
            deliberate: true
        ) else {
            completion()
            return
        }
        guard let application = NSRunningApplication(processIdentifier: processIdentifier),
              !application.isTerminated else {
            presentError(title: "Force Quit", message: "\(name) is no longer running.")
            completion()
            return
        }
        if application.forceTerminate() {
            hide()
            toast.show("Force quit \(name)")
        } else {
            presentError(title: "Force Quit", message: "macOS did not allow \(name) to be force quit.")
        }
        completion()
    }

    private func confirmForceQuitAllApplications(completion: @escaping () -> Void = {}) {
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
            completion()
            return
        }

        let names = applications.compactMap(\.localizedName)
        let preview = names.prefix(8).joined(separator: ", ")
        let remaining = max(0, names.count - 8)
        let list = remaining == 0 ? preview : "\(preview), and \(remaining) more"

        NSApp.activate(ignoringOtherApps: true)
        guard LimaConfirmationService.confirm(
            title: "Force Quit All \(applications.count) Applications?",
            detail: "Lima will stay open. The following apps will close immediately and unsaved work may be lost:\n\n\(list)",
            confirmTitle: "Force Quit All",
            deliberate: true
        ) else {
            if !panel.isVisible { presentPanel() }
            completion()
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
        completion()
    }

    private func routeUniversalSearchResult(_ result: LimaSearchResult) {
        switch result.kind {
        case .note:
            guard let id = UUID(uuidString: String(result.id.dropFirst("note:".count))) else {
                presentError(title: result.title, message: "The note identifier is invalid.")
                return
            }
            notesWindow.selectNote(id)
            hide()
            notesWindow.present()

        case .dictation:
            guard let id = UUID(uuidString: String(result.id.dropFirst("dictation:".count))) else {
                presentError(title: result.title, message: "The dictation identifier is invalid.")
                return
            }
            notesWindow.selectDictation(id)
            hide()
            notesWindow.present()

        case .terminal:
            guard let id = UUID(uuidString: String(result.id.dropFirst("terminal:".count))) else {
                presentError(title: result.title, message: "The terminal session identifier is invalid.")
                return
            }
            TerminalSessionStore.shared.select(id)
            terminalModel.selectSession(id)
            viewModel.enter(.terminal)
            presentPanel()
            terminalModel.startIfNeeded()
            terminalModel.focus()

        case .command:
            if result.id.hasPrefix("workflow:"),
               let id = UUID(uuidString: String(result.id.dropFirst("workflow:".count))),
               let workflow = WorkflowStore.shared.workflows.first(where: { $0.id == id }) {
                executeWorkflow(workflow)
            } else {
                presentError(title: result.title, message: "This command cannot be opened from universal search.")
            }

        default:
            presentError(title: result.title, message: "This result type is not routable yet.")
        }
    }

    private func executeWorkflow(_ workflow: WorkflowDefinition) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Run \(workflow.name)?"
        alert.informativeText = "This workflow contains \(workflow.steps.count) step\(workflow.steps.count == 1 ? "" : "s"). Each step will be reported individually."
        alert.addButton(withTitle: "Run Workflow")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        hide()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let report = await WorkflowExecutor().execute(workflow, confirm: true) { [weak self] commandID in
                try await self?.executeWorkflowCommand(commandID)
            }
            let failed = report.steps.filter { !$0.succeeded }
            if failed.isEmpty {
                self.toast.show("Workflow completed")
            } else {
                self.presentError(
                    title: "Workflow completed with errors",
                    message: failed.map { "\($0.commandID): \($0.message ?? "Failed")" }.joined(separator: "\n")
                )
            }
        }
    }

    private func executeWorkflowCommand(_ commandID: String) async throws {
        guard let command = viewModel.extensionCommands.first(where: {
            "extension.\($0.extensionID).\($0.command.id)" == commandID || $0.command.id == commandID
        }) else {
            throw NSError(domain: "LimaWorkflow", code: 1, userInfo: [NSLocalizedDescriptionKey: "Command \(commandID) is unavailable."])
        }
        guard command.command.action.type != .form else {
            throw NSError(domain: "LimaWorkflow", code: 2, userInfo: [NSLocalizedDescriptionKey: "Form commands require interactive input and cannot run unattended."])
        }

        let result = try await extensionExecutor.executeAsync(command, clipboard: clipboard)
        switch result {
        case .completed:
            return
        case .native(let action):
            await withCheckedContinuation { continuation in
                dispatchNativeAction(action) { continuation.resume() }
            }
        case .nativeChain(let actions):
            await withCheckedContinuation { continuation in
                dispatchNativeChain(actions) { continuation.resume() }
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

        case .openTerminal:
            showDeveloperTerminal()

        case .openPermissionCenter:
            hide()
            PermissionCenter.shared.refresh()
            permissionWindow.showWindow(nil)
            permissionWindow.window?.center()
            NSApp.activate(ignoringOtherApps: true)

        case .exportDiagnostics:
            do {
                let url = try DiagnosticsService.shared.export()
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                presentError(title: "Diagnostics", message: error.localizedDescription)
            }

        case .openWorkflows:
            hide()
            workflowWindow.present()

        case .openSettings:
            showSettings()

        case .openDeveloperGrammarSettings:
            showDeveloperGrammarSettings()

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

    private func runSystemExecutable(
        _ path: String,
        arguments: [String],
        title: String,
        completion: @escaping () -> Void = {}
    ) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        task.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                if process.terminationStatus != 0 {
                    self?.presentError(title: title, message: "The system command exited with status \(process.terminationStatus).")
                }
                completion()
            }
        }
        do { try task.run() }
        catch {
            presentError(title: title, error: error)
            completion()
        }
    }

    private func presentError(title: String, error: Error) {
        presentError(title: title, message: error.localizedDescription)
    }

    private func presentError(title: String, message: String) {
        viewModel.showOutput(title: title, text: message, state: .error)
        if !panel.isVisible { presentPanel() }
    }
}
