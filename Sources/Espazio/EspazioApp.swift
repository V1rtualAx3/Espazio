import AppKit

/// Agent application (LSUIElement): no Dock icon, a menu bar item and the notch windows.
@main
@MainActor
enum EspazioMain {
    static func main() {
        // A peer that vanishes (codex app-server, browser on the OAuth loopback) must surface as
        // EPIPE, never kill the app.
        signal(SIGPIPE, SIG_IGN)
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = AppCoordinator()
        self.coordinator = coordinator
        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
