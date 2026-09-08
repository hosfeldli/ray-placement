import AppKit
import SwiftUI

@main
enum RayPlacementMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        #if DEBUG
        if let previewMode = uiPreviewMode() {
            runUIPreview(application, mode: previewMode)
            return
        }
        if CommandLine.arguments.contains("--terminal-preview") {
            // Isolated UI smoke test: no global hotkeys, dictation, credential
            // access, or update checks. Preview preferences use its own bundle.
            application.setActivationPolicy(.regular)
            let menu = NSMenu()
            let appItem = NSMenuItem()
            let appMenu = NSMenu()
            appMenu.addItem(withTitle: "Quit Preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            appItem.submenu = appMenu
            menu.addItem(appItem)
            let windowItem = NSMenuItem()
            let windowMenu = NSMenu(title: "Window")
            windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
            windowItem.submenu = windowMenu
            menu.addItem(windowItem)
            application.mainMenu = menu
            application.windowsMenu = windowMenu
            let inspector = NSWindow(contentRect: NSRect(x: 90, y: 100, width: 500, height: 420),
                                     styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            LimaWindowChrome.configure(
                inspector,
                title: "Typography Preview",
                accessibilityLabel: "Typography Preview"
            )
            inspector.contentView = NSHostingView(rootView: LimaTypographyRoot(content: TypographyPreview()))
            inspector.makeKeyAndOrderFront(nil)
            if CommandLine.arguments.contains("--typography-first") { inspector.makeKeyAndOrderFront(nil) }
            withExtendedLifetime(inspector) { application.run() }
            return
        }
        #endif
        let applicationDelegate = AppDelegate()
        application.delegate = applicationDelegate
        withExtendedLifetime(applicationDelegate) {
            application.run()
        }
    }
}


#if DEBUG
private extension RayPlacementMain {
    static func uiPreviewMode() -> LimaUIPreviewMode? {
        guard let index = CommandLine.arguments.firstIndex(of: "--ui-preview"),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return LimaUIPreviewMode(rawValue: CommandLine.arguments[index + 1])
    }

    @MainActor
    static func runUIPreview(_ application: NSApplication, mode: LimaUIPreviewMode) {
        application.setActivationPolicy(.regular)
        configurePreviewMenu(application)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: mode.size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        LimaWindowChrome.configure(
            window,
            title: mode.title,
            accessibilityLabel: mode.title,
            minSize: mode.size
        )
        window.contentView = NSHostingView(rootView: LimaTypographyRoot(content: LimaUIPreviewGallery(mode: mode)))
        window.center()
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        withExtendedLifetime(window) { application.run() }
    }

    static func configurePreviewMenu(_ application: NSApplication) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close Preview", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        application.mainMenu = menu
        application.windowsMenu = windowMenu
    }
}
#endif

#if DEBUG
private struct TypographyPreview: View {
    @State private var text = "# Preview note\n\n**Bold**, *italic*, and `code` stay editable.\n\n| Item | State |\n| --- | --- |\n| Session | Preserved |"
    var body: some View {
        VStack {
            InterfaceTextSizeControl().padding()
            InlineMarkdownEditor(text: $text, compact: true)
        }
    }
}
#endif
