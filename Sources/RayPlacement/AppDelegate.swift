import AppKit
import CoreServices
import Foundation
import RayPlacementCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotKeys = HotKeyManager()
    private var launcher: LauncherController!
    private var statusItem: NSStatusItem?
    private var observers: [NSObjectProtocol] = []
    private var registeredActivationShortcut: ShortcutSpec?

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? ApplicationPaths.prepare()
        NSApp.setActivationPolicy(SettingsStore.shared.showInDock ? .regular : .accessory)
        launcher = LauncherController()
        launcher.onExtensionsChanged = { [weak self] in self?.registerExtensionHotkeys() }

        configureMainMenu()
        configureStatusItem()
        registerActivationHotkey()
        installObservers()

        let launchEvent = NSAppleEventManager.shared().currentAppleEvent
        let launchedAsLoginItem = launchEvent?
            .paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem))?
            .booleanValue ?? false
        if !launchedAsLoginItem {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.launcher.show()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidBecomeActive(_ notification: Notification) {
        SettingsStore.shared.refreshLaunchAtLogin()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        launcher.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        launcher?.shutdown()
        hotKeys.unregisterAll()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    @objc func toggleLauncher() { launcher.toggle() }
    @objc func showSettings() { launcher.showSettings() }
    @objc func reloadExtensions() { launcher.viewModel.reloadExtensions() }
    @objc func quit() { NSApp.terminate(nil) }

    private func registerActivationHotkey() {
        hotKeys.unregisterAll(prefix: "extension.")
        defer { registerExtensionHotkeys() }
        guard let shortcut = ShortcutSpec(string: SettingsStore.shared.activationShortcut) else {
            SettingsStore.shared.lastError = "The activation shortcut is invalid."
            if let registeredActivationShortcut {
                SettingsStore.shared.restoreActivationShortcut(registeredActivationShortcut.storageString)
            }
            return
        }
        do {
            try hotKeys.register(identifier: "activation", shortcut: shortcut) { [weak self] in
                self?.launcher.toggle()
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

    private func registerExtensionHotkeys() {
        hotKeys.unregisterAll(prefix: "extension.")
        var issues: [ExtensionIssue] = []
        for loaded in launcher.viewModel.extensionCommands {
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
                try hotKeys.register(identifier: identifier, shortcut: shortcut) { [weak self] in
                    self?.launcher.executeExtensionFromHotkey(loaded)
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
            button.image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: "RayPlacement")
            button.target = self
            button.action = #selector(toggleLauncher)
        }

        let menu = NSMenu()
        let show = NSMenuItem(title: "Show RayPlacement", action: #selector(toggleLauncher), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let reload = NSMenuItem(title: "Reload Extensions", action: #selector(reloadExtensions), keyEquivalent: "")
        reload.target = self
        menu.addItem(reload)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit RayPlacement", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "RayPlacement")
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit RayPlacement", action: #selector(quit), keyEquivalent: "q")
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
}
