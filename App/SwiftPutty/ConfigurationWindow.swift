import ConfigurationUI
import PuTTYBridge
import SwiftUI

/// PuTTY's configuration dialog as the app's entry point: Open starts a
/// session in its own window and closes the dialog, as PuTTY does;
/// Cancel closes it (and the app, if no session is open).
struct ConfigurationWindow: View {
    let appModel: AppModel
    @State private var model: ConfigurationModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    init(appModel: AppModel) {
        self.appModel = appModel
        _model = State(initialValue: ConfigurationModel(store: appModel.sessionStore,
                                                        beep: { NSSound.beep() }))
    }

    var body: some View {
        VStack(spacing: 0) {
            if case .failed(let message) = appModel.coreState {
                Label("The PuTTY core could not start: \(message)",
                      systemImage: "exclamationmark.triangle.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.yellow.opacity(0.25))
            }
            ConfigurationView(model: model,
                              onOpen: open,
                              onCancel: { dismissWindow(id: WindowID.configuration) },
                              onAbout: { openWindow(id: WindowID.about) })
        }
        .onAppear(perform: loadRequestedSession)
        .onChange(of: appModel.configurationToLoad) { loadRequestedSession() }
        #if DEBUG
        .task { openDebugSessions() }
        #endif
    }

    /// The Saved Sessions menu asked for a session with no destination:
    /// load it, as `putty -load` shows the dialog with it.
    private func loadRequestedSession() {
        guard let name = appModel.configurationToLoad else { return }
        appModel.configurationToLoad = nil
        model.setSavedSessionName(name)
        model.loadSelectedSession()
    }

    private func open(_ settings: PuTTYSettings) {
        guard case .running = appModel.coreState else {
            NSSound.beep()
            return
        }
        openWindow(id: WindowID.session, value: SessionRequest(settings: settings))
        dismissWindow(id: WindowID.configuration)
    }

    #if DEBUG
    @MainActor private static var openedDebugSessions = false

    /// Developer aid (debug builds only): SWIFTPUTTY_DEBUG_OPEN_RAW or
    /// SWIFTPUTTY_DEBUG_OPEN_SSH=[user@]host:port opens a session at
    /// launch from "Default Settings", for screenshots and manual checks.
    /// Once per launch: opening closes this dialog, and doing that again
    /// while a reopened dialog appears leaves it unable to update.
    private func openDebugSessions() {
        guard !Self.openedDebugSessions else { return }
        Self.openedDebugSessions = true
        let environment = ProcessInfo.processInfo.environment
        for (variable, type) in [("SWIFTPUTTY_DEBUG_OPEN_RAW", "raw"), ("SWIFTPUTTY_DEBUG_OPEN_SSH", "ssh")] {
            guard let target = environment[variable],
                  let colon = target.lastIndex(of: ":"),
                  let port = Int(target[target.index(after: colon)...]) else { continue }
            var settings = model.settings
            settings["Protocol"] = type
            settings["HostName"] = String(target[..<colon])   // "user@" is PuTTY's to split
            settings["PortNumber"] = String(port)
            open(settings)
        }
    }
    #endif
}
