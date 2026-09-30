import AppKit

@main
@MainActor
final class AerialPlayerApp: NSObject, NSApplicationDelegate {
    private let controller = WallpaperController()
    private var statusBar: StatusBarController?

    static func main() {
        let application = NSApplication.shared
        let delegate = AerialPlayerApp()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController(controller: controller)
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
        statusBar?.remove()
    }
}
