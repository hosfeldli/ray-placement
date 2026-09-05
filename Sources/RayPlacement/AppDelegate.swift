import AppKit
import CoreServices
import Foundation
import RayPlacementCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotKeys = HotKeyManager()
    private let accessoryMouse = AccessoryMouseBindingManager()
    private let updateService = UpdateService()
    private lazy var updateProgressWindow = UpdateProgressWindowController(service: updateService)
    private var launcher: LauncherController!
    private var statusItem: NSStatusItem?
    private var observers: [NSObjectProtocol] = []
    private var registeredActivationShortcut: ShortcutSpec?
    private var registeredNotesShortcut: ShortcutSpec?
    private var registeredQuickNoteShortcut: ShortcutSpec?
    private var registeredDictationShortcut: ShortcutSpec?
    private var registeredNotesDockLeftShortcut: ShortcutSpec?
    private var registeredNotesDockRightShortcut: ShortcutSpec?
    private var registeredTerminalShortcut: ShortcutSpec?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.arguments.contains("--unregister-login-item-and-quit") {
            if SMAppService.mainApp.status != .notRegistered {
                try? SMAppService.mainApp.unregister()
            }
            NSApp.terminate(nil)
            return
        }
        try? ApplicationPaths.prepare()
        let launchPath = Bundle.main.bundleURL.path
        if launchPath.hasPrefix("/Volumes/") || launchPath.contains("/AppTranslocation/") {
            let alert = NSAlert()
            alert.messageText = "Move Lima to Applications"
            alert.informativeText = "Drag Lima into Applications in Finder, then open that installed copy. Running from the download or disk image prevents reliable updates and Dock shortcuts."
            alert.addButton(withTitle: "Open Applications")
            alert.addButton(withTitle: "Quit")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
            }
            NSApp.terminate(nil)
            return
        }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.setActivationPolicy(SettingsStore.shared.showInDock ? .regular : .accessory)
        launcher = LauncherController(updateService: updateService)
        launcher.onExtensionsChanged = { [weak self] in self?.registerExtensionHotkeys() }

        configureMainMenu()
        configureStatusItem()
        registerActivationHotkey()
        registerActionHotkeys()
        configureAccessoryMouseBindings()
        registerExtensionHotkeys()
        installObservers()
        let isShowingUpdateResult = configureUpdates()

        let launchEvent = NSAppleEventManager.shared().currentAppleEvent
        let launchedAsLoginItem = launchEvent?
            .paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem))?
            .booleanValue ?? false
        if !launchedAsLoginItem, !isShowingUpdateResult {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.launcher.show()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidBecomeActive(_ notification: Notification) {
        SettingsStore.shared.refreshLaunchAtLogin()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // ASWebAuthenticationSession normally consumes its callback directly.
        // Keep the app-level URL event handled so a future/manual callback does
        // not reopen a blank document or get routed to another command.
        guard urls.contains(where: { $0.scheme?.lowercased() == "rayplacement" }) else { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if updateService.isInstalling || updateService.completionResult != nil {
            updateProgressWindow.present()
        } else {
            launcher.show()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        launcher?.shutdown()
        UsageMonitor.shared.flush()
        hotKeys.unregisterAll()
        accessoryMouse.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    @objc func toggleLauncher() { launcher.toggle() }
    @objc func showSettings() { launcher.showSettings() }
    @objc func showNotes() { launcher.showNotes() }
    @objc func showQuickNote() { launcher.showQuickNote() }
    @objc func toggleNoteDictation() { launcher.showNotesAndToggleDictation() }
    @objc func showTerminal() { launcher.showDeveloperTerminal() }
    @objc func checkForUpdates() { updateService.checkForUpdates(manual: true) }
    @objc func reloadExtensions() { launcher.viewModel.reloadExtensions() }
    @objc func quit() { NSApp.terminate(nil) }

    private func registerActivationHotkey() {
        guard SettingsStore.shared.activationHotkeyEnabled else {
            hotKeys.unregister(identifier: "activation")
            registeredActivationShortcut = nil
            return
        }
        guard let shortcut = ShortcutSpec(string: SettingsStore.shared.activationShortcut) else {
            SettingsStore.shared.lastError = "The activation shortcut is invalid."
            if let registeredActivationShortcut {
                SettingsStore.shared.restoreActivationShortcut(registeredActivationShortcut.storageString)
            }
            return
        }
        do {
            try hotKeys.registerFromApplication(identifier: "activation", shortcut: shortcut) { [weak self] application in
                self?.launcher.toggle(from: application)
            }
            registeredActivationShortcut = shortcut
            SettingsStore.shared.lastError = nil
        } catch {
            SettingsStore.shared.lastError = error.localizedDescription
            if let registeredActivationShortcut {
                SettingsStore.shared.restoreActivationShortcut(registeredActivationShortcut.storageString)
            }
        }
    }

    private func registerActionHotkeys() {
        registerActionHotkey(
            identifier: "builtin.notes",
            displayName: "Notes",
            enabled: SettingsStore.shared.notesHotkeyEnabled,
            rawShortcut: SettingsStore.shared.notesShortcut,
            previous: &registeredNotesShortcut,
            restore: SettingsStore.shared.restoreNotesShortcut
        ) { [weak self] in
            self?.launcher.showNotes()
        }
        registerActionHotkey(
            identifier: "builtin.dictation",
            displayName: "Dictation",
            enabled: SettingsStore.shared.dictationHotkeyEnabled,
            rawShortcut: SettingsStore.shared.dictationShortcut,
            previous: &registeredDictationShortcut,
            restore: SettingsStore.shared.restoreDictationShortcut
        ) { [weak self] in
            self?.launcher.showNotesAndToggleDictation()
        }
        registerActionHotkey(
            identifier: "builtin.quick-note",
            displayName: "Quick Note",
            enabled: SettingsStore.shared.quickNoteHotkeyEnabled,
            rawShortcut: SettingsStore.shared.quickNoteShortcut,
            previous: &registeredQuickNoteShortcut,
            restore: SettingsStore.shared.restoreQuickNoteShortcut
        ) { [weak self] in
            self?.launcher.showQuickNote()
        }
        registerActionHotkey(
            identifier: "builtin.notes-dock-left",
            displayName: "Dock Notes Left",
            enabled: SettingsStore.shared.notesDockLeftHotkeyEnabled,
            rawShortcut: SettingsStore.shared.notesDockLeftShortcut,
            previous: &registeredNotesDockLeftShortcut,
            restore: SettingsStore.shared.restoreNotesDockLeftShortcut
        ) { [weak self] in
            self?.launcher.dockNotesLeft()
        }
        registerActionHotkey(
            identifier: "builtin.notes-dock-right",
            displayName: "Dock Notes Right",
            enabled: SettingsStore.shared.notesDockRightHotkeyEnabled,
            rawShortcut: SettingsStore.shared.notesDockRightShortcut,
            previous: &registeredNotesDockRightShortcut,
            restore: SettingsStore.shared.restoreNotesDockRightShortcut
        ) { [weak self] in
            self?.launcher.dockNotesRight()
        }
        registerActionHotkey(
            identifier: "builtin.terminal",
            displayName: "Developer Terminal",
            enabled: SettingsStore.shared.developerTerminalEnabled && SettingsStore.shared.terminalHotkeyEnabled,
            rawShortcut: SettingsStore.shared.terminalShortcut,
            previous: &registeredTerminalShortcut,
            restore: SettingsStore.shared.restoreTerminalShortcut
        ) { [weak self] in self?.launcher.showDeveloperTerminal() }
    }

    private func configureAccessoryMouseBindings() {
        accessoryMouse.start(bindings: SettingsStore.shared.accessoryMouseBindings) { [weak self] action, application in
            self?.performAccessoryMouseAction(action, sourceApplication: application)
        }
    }

    private func performAccessoryMouseAction(_ action: AccessoryMouseAction, sourceApplication: NSRunningApplication?) {
        switch action {
        case .none: break
        case .previousDesktop: postShortcut(keyCode: 123, flags: .maskControl)
        case .nextDesktop: postShortcut(keyCode: 124, flags: .maskControl)
        case .missionControl: postShortcut(keyCode: 126, flags: .maskControl)
        case .applicationWindows: postShortcut(keyCode: 125, flags: .maskControl)
        case .previousWindow: postShortcut(keyCode: 50, flags: .maskCommand)
        case .back: postShortcut(keyCode: 33, flags: .maskCommand)
        case .forward: postShortcut(keyCode: 30, flags: .maskCommand)
        case .launcher: launcher.toggle(from: sourceApplication)
        case .notes: launcher.showNotes()
        case .quickNote: launcher.showQuickNote()
        case .dictation: launcher.showNotesAndToggleDictation()
        case .terminal: launcher.showDeveloperTerminal()
        }
    }

    private func postShortcut(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard WindowManager.trusted(prompt: true),
              let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func registerActionHotkey(
        identifier: String,
        displayName: String,
        enabled: Bool,
        rawShortcut: String,
        previous: inout ShortcutSpec?,
        restore: (String) -> Void,
        handler: @escaping () -> Void
    ) {
        guard enabled else {
            hotKeys.unregister(identifier: identifier)
            previous = nil
            return
        }
        guard let shortcut = ShortcutSpec(string: rawShortcut) else {
            SettingsStore.shared.lastError = "The \(displayName) shortcut is invalid."
            if let previous { restore(previous.storageString) }
            return
        }
        do {
            try hotKeys.register(identifier: identifier, shortcut: shortcut, handler: handler)
            previous = shortcut
            SettingsStore.shared.lastError = nil
        } catch {
            SettingsStore.shared.lastError = error.localizedDescription
            if let previous { restore(previous.storageString) }
        }
    }

    private func registerExtensionHotkeys() {
        hotKeys.unregisterAll(prefix: "extension.")
        var issues: [ExtensionIssue] = []
        for loaded in launcher.viewModel.extensionCommands {
            guard SettingsStore.shared.isHotkeyEnabled(loaded) else { continue }
            guard let raw = SettingsStore.shared.effectiveShortcut(for: loaded) else { continue }
            guard let shortcut = ShortcutSpec(string: raw) else {
                issues.append(ExtensionIssue(
                    file: loaded.extensionName,
                    message: "\(loaded.command.title) has an invalid hotkey: \(raw)"
                ))
                continue
            }
            let identifier = "extension.\(loaded.extensionID).\(loaded.command.id)"
            do {
                try hotKeys.registerFromApplication(identifier: identifier, shortcut: shortcut) { [weak self] application in
                    self?.launcher.executeExtensionFromHotkey(loaded, sourceApplication: application)
                }
            } catch {
                issues.append(ExtensionIssue(
                    file: loaded.extensionName,
                    message: "\(loaded.command.title): \(error.localizedDescription)"
                ))
            }
        }
        launcher.viewModel.setExtensionHotkeyIssues(issues)
    }

    private func installObservers() {
        observers.append(NotificationCenter.default.addObserver(
            forName: .rayPlacementShortcutChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.registerActivationHotkey() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .rayPlacementActionShortcutsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.registerActionHotkeys()
                self?.launcher.refreshDeveloperTerminalAvailability()
                self?.accessoryMouse.update(bindings: SettingsStore.shared.accessoryMouseBindings)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .rayPlacementExtensionsReloadRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.launcher.viewModel.reloadExtensions() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .rayPlacementExtensionShortcutsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.registerExtensionHotkeys() }
        })
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: "Lima")
            button.target = self
            button.action = #selector(toggleLauncher)
        }

        let menu = NSMenu()
        let show = NSMenuItem(title: "Show Lima", action: #selector(toggleLauncher), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let notes = NSMenuItem(title: "Notes…", action: #selector(showNotes), keyEquivalent: "n")
        notes.keyEquivalentModifierMask = [.command, .shift]
        notes.target = self
        menu.addItem(notes)
        let quickNote = NSMenuItem(title: "Quick Note Sidebar", action: #selector(showQuickNote), keyEquivalent: "n")
        quickNote.keyEquivalentModifierMask = [.command, .option]
        quickNote.target = self
        menu.addItem(quickNote)
        let dictate = NSMenuItem(title: "Start or Stop Dictation Conversation", action: #selector(toggleNoteDictation), keyEquivalent: "")
        dictate.target = self
        menu.addItem(dictate)
        let reload = NSMenuItem(title: "Reload Extensions", action: #selector(reloadExtensions), keyEquivalent: "")
        reload.target = self
        menu.addItem(reload)
        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Lima", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Lima")
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        let notes = NSMenuItem(title: "Notes…", action: #selector(showNotes), keyEquivalent: "n")
        notes.keyEquivalentModifierMask = [.command, .shift]
        notes.target = self
        appMenu.addItem(notes)
        let quickNote = NSMenuItem(title: "Quick Note Sidebar", action: #selector(showQuickNote), keyEquivalent: "n")
        quickNote.keyEquivalentModifierMask = [.command, .option]
        quickNote.target = self
        appMenu.addItem(quickNote)
        let dictate = NSMenuItem(title: "Start or Stop Dictation Conversation", action: #selector(toggleNoteDictation), keyEquivalent: "")
        dictate.target = self
        appMenu.addItem(dictate)
        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        appMenu.addItem(updates)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Lima", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
    }

    private func configureUpdates() -> Bool {
        updateService.onReleaseAvailable = { [weak self] release in
            self?.presentUpdateConfirmation(release)
        }
        updateService.onInstallStarted = { [weak self] in
            self?.updateProgressWindow.present()
        }
        if let result = updateService.consumePreviousUpdateResult() {
            updateService.showCompletion(succeeded: result.succeeded, message: result.message)
            DispatchQueue.main.async { [weak self] in
                self?.updateProgressWindow.present()
            }
            return true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.updateService.checkForUpdates(manual: false)
        }
        return false
    }

    private func presentUpdateConfirmation(_ release: UpdateService.Release) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Lima \(release.versionText) is available"
        let notes = release.body?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(1_200) ?? ""
        alert.informativeText = "Installed: \(updateService.currentVersion)\n\n\(notes)\n\nThe update kit will be verified locally and installed only after you confirm."
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "View on GitHub")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            updateService.install(release)
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(release.htmlURL)
        default:
            break
        }
    }
}
