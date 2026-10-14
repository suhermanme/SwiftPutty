import SwiftUI
import TerminalUI

@main
struct SwiftPuttyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The launcher window. In PuTTY the configuration dialog is the
        // entry point and each session gets its own terminal window.
        Window("SwiftPutty", id: WindowID.launcher) {
            LauncherView(model: appDelegate.model)
        }
        .windowResizability(.contentSize)
        .commands {
            AppCommands()
        }

        WindowGroup("Session", id: WindowID.session, for: SessionRequest.self) { $request in
            if let request {
                SessionWindow(request: request)
            }
        }
        // PuTTY opens at the configured terminal size (default 80x24).
        .defaultSize(TerminalView.defaultSize(for: .defaults()))
        .windowResizability(.contentMinSize)

        Window("About SwiftPutty", id: WindowID.about) {
            AboutView()
        }
        .windowResizability(.contentSize)
    }
}

enum WindowID {
    static let launcher = "launcher"
    static let about = "about"
    static let session = "session"
}

private struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About SwiftPutty") {
                openWindow(id: WindowID.about)
            }
        }
        // No document-style "New Window"; File > New Session arrives with
        // the session launcher (M05).
        CommandGroup(replacing: .newItem) {}
        CommandGroup(after: .pasteboard) {
            Button("Copy All to Clipboard") {
                NSApp.sendAction(#selector(TerminalView.copyAllToClipboard(_:)), to: nil, from: nil)
            }
        }
    }
}
