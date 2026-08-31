import AppKit
import SwiftUI

@main
enum RayPlacementMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        #if DEBUG
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
            let terminal = DeveloperTerminalWindowController()
            let inspector = NSWindow(contentRect: NSRect(x: 90, y: 100, width: 500, height: 420),
                                     styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            inspector.title = "Typography Preview"
            inspector.contentView = NSHostingView(rootView: LimaTypographyRoot(content: TypographyPreview()))
            inspector.makeKeyAndOrderFront(nil)
            terminal.present()
            if CommandLine.arguments.contains("--typography-first") { inspector.makeKeyAndOrderFront(nil) }
            withExtendedLifetime((terminal, inspector)) { application.run() }
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
private struct TypographyPreview: View {
    @State private var text = "# Preview note\n\n**Bold**, *italic*, and `code` stay editable.\n\n| Item | State |\n| --- | --- |\n| Session | Preserved |"
    var body: some View {
        VStack {
            InterfaceTextSizeControl().padding()
            InlineMarkdownEditor(text: $text, compact: true)
        }.preferredColorScheme(.dark)
    }
}
#endif
