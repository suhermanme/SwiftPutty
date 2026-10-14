import AppKit
import PuTTYBridge

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationWillFinishLaunching(_ notification: Notification) {
        model.startCore()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // As in PuTTY: closing the last window ends the application.
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopCore()
    }
}
