import AppKit

@main
enum RayPlacementMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let applicationDelegate = AppDelegate()
        application.delegate = applicationDelegate
        withExtendedLifetime(applicationDelegate) {
            application.run()
        }
    }
}
