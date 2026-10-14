import SwiftUI
import TerminalUI

@main
struct SwiftPuttyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // As PuTTY: no windows are reopened at the next launch.
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
    }

    var body: some Scene {
        // As in PuTTY, the configuration dialog is the entry point and
        // each session gets its own terminal window.
        Window("SwiftPutty Configuration", id: WindowID.configuration) {
            ConfigurationWindow(appModel: appDelegate.model)
        }
        .windowResizability(.contentSize)
        .commands {
            AppCommands()
        }

        WindowGroup("Session", id: WindowID.session, for: SessionRequest.self) { $request in
            if let request {
                SessionWindow(request: request)
            } else {
                // A restored window whose request no longer decodes.
                ClosingWindow()
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

/// Closes the window it is shown in.
private struct ClosingWindow: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View { Color.clear.onAppear { dismiss() } }
}

enum WindowID {
    static let configuration = "configuration"
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
        // PuTTY's "New Session...": the configuration dialog.
        CommandGroup(replacing: .newItem) {
            Button("New Session…") {
                openWindow(id: WindowID.configuration)
            }
            .keyboardShortcut("n")
        }
        CommandGroup(after: .pasteboard) {
            Button("Copy All to Clipboard") {
                NSApp.sendAction(#selector(TerminalView.copyAllToClipboard(_:)), to: nil, from: nil)
            }
        }
    }
}
