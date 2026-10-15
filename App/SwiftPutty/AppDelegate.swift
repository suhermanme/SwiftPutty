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

    /// Quitting ends every session at once. PuTTY has no Quit (each
    /// window asks for itself, "Warn before closing window"), so ask once
    /// for all the windows that would have asked (D-034).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let count = model.connectedSessionsWithCloseWarning
        guard count > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "SwiftPutty Exit Confirmation"
        alert.informativeText = count == 1
            ? "Are you sure you want to close this session?"
            : "Are you sure you want to close these \(count) sessions?"
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopCore()
    }
}
