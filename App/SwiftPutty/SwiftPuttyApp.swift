import SwiftUI

@main
struct SwiftPuttyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The launcher window. In PuTTY the configuration dialog is the
        // entry point and each session gets its own terminal window; the
        // session windows arrive with SSH support (M04).
        Window("SwiftPutty", id: WindowID.launcher) {
            LauncherView(model: appDelegate.model)
        }
        .windowResizability(.contentSize)
        .commands {
            AppCommands()
        }

        Window("About SwiftPutty", id: WindowID.about) {
            AboutView()
        }
        .windowResizability(.contentSize)
    }
}

enum WindowID {
    static let launcher = "launcher"
    static let about = "about"
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
        // the session launcher (M04/M05).
        CommandGroup(replacing: .newItem) {}
    }
}
