import ConfigurationUI
import Persistence
import PuTTYBridge
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
            AppCommands(model: appDelegate.model)
        }

        WindowGroup("Session", id: WindowID.session, for: SessionRequest.self) { $request in
            if let request {
                SessionWindow(request: request, appModel: appDelegate.model)
            } else {
                // A restored window whose request no longer decodes.
                ClosingWindow()
            }
        }
        // PuTTY opens at the configured terminal size (default 80x24).
        .defaultSize(TerminalView.defaultSize(for: .defaults()))
        .windowResizability(.contentMinSize)

        // One Event Log per session window, as in PuTTY.
        WindowGroup("SwiftPutty Event Log", id: WindowID.eventLog, for: UUID.self) { $window in
            EventLogWindow(window: window, appModel: appDelegate.model)
        }
        .defaultSize(width: 640, height: 320)

        Window("About SwiftPutty", id: WindowID.about) {
            AboutView()
        }
        .windowResizability(.contentSize)
    }
}

/// Closes the window it is shown in: a window SwiftUI restored from an
/// earlier launch. The configuration dialog opens first, so that a launch
/// that restored only such windows shows the dialog, as PuTTY's does,
/// instead of ending with its last window.
struct ClosingWindow: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear.onAppear {
            openWindow(id: WindowID.configuration)
            dismiss()
        }
    }
}

/// The Event Log of the session window `window`; closes itself if that
/// window is gone (for example a window restored from an earlier launch).
private struct EventLogWindow: View {
    let window: UUID?
    let appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let window, let controller = appModel.sessions[window] {
            EventLogView(controller: controller, onClose: { dismiss() })
        } else {
            ClosingWindow()
        }
    }
}

enum WindowID {
    static let configuration = "configuration"
    static let about = "about"
    static let session = "session"
    static let eventLog = "event-log"
}

/// What the focused session window offers to the menus.
struct SessionActions {
    var changeSettings: () -> Void
    var canChangeSettings: Bool
    var restart: () -> Void
    var canRestart: Bool
    var duplicate: () -> Void
    var showEventLog: () -> Void
    /// The connection's Special Commands (none: the menu is hidden).
    var specials: [SessionSpecial]
    var runSpecial: (SessionSpecialCommand) -> Void
    var clearScrollback: () -> Void
    var resetTerminal: () -> Void
}

extension FocusedValues {
    @Entry var sessionActions: SessionActions?
}

private struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.sessionActions) private var sessionActions

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
        // GTK PuTTY's window menu (unix/window.c), in its order; New
        // Session is in the File menu, the clipboard items in Edit.
        CommandMenu("Session") {
            Button("Restart Session") {
                sessionActions?.restart()
            }
            .disabled(sessionActions?.canRestart != true)
            Button("Duplicate Session") {
                sessionActions?.duplicate()
            }
            .disabled(sessionActions == nil)
            Menu("Saved Sessions") {
                if model.savedSessionNames.isEmpty {
                    Button("(No sessions)") {}.disabled(true)
                }
                ForEach(model.savedSessionNames, id: \.self) { name in
                    Button(name) { launchSavedSession(name) }
                }
            }
            Divider()
            Button("Change Settings…") {
                sessionActions?.changeSettings()
            }
            .keyboardShortcut(",", modifiers: [.command, .shift])
            .disabled(sessionActions?.canChangeSettings != true)
            Divider()
            Button("Event Log") {
                sessionActions?.showEventLog()
            }
            .disabled(sessionActions == nil)
            if let actions = sessionActions, !actions.specials.isEmpty {
                Menu("Special Commands") {
                    SpecialCommandsMenu(entries: actions.specials, run: actions.runSpecial)
                }
                Divider()
            }
            Button("Clear Scrollback") {
                sessionActions?.clearScrollback()
            }
            .disabled(sessionActions == nil)
            Button("Reset Terminal") {
                sessionActions?.resetTerminal()
            }
            .disabled(sessionActions == nil)
        }
        CommandGroup(after: .pasteboard) {
            Button("Copy All to Clipboard") {
                NSApp.sendAction(#selector(TerminalView.copyAllToClipboard(_:)), to: nil, from: nil)
            }
        }
    }

    /// GTK PuTTY's launch_saved_session: straight to a session window
    /// if the session says where to connect, else the configuration
    /// dialog with it loaded.
    private func launchSavedSession(_ name: String) {
        guard let settings = try? model.sessionStore.load(name).settings else {
            NSSound.beep()
            return
        }
        if ConfigurationModel.isLaunchable(settings) {
            guard case .running = model.coreState else {
                NSSound.beep()
                return
            }
            openWindow(id: WindowID.session, value: SessionRequest(settings: settings))
        } else {
            model.configurationToLoad = name
            openWindow(id: WindowID.configuration)
        }
    }
}

/// Special Commands entries as menu items, submenus and separators.
private struct SpecialCommandsMenu: View {
    let entries: [SessionSpecial]
    let run: (SessionSpecialCommand) -> Void

    var body: some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            switch entry {
            case .command(let command):
                Button(command.name) { run(command) }
            case .separator:
                Divider()
            case .submenu(let title, let children):
                Menu(title) {
                    SpecialCommandsMenu(entries: children, run: run)
                }
            }
        }
    }
}
