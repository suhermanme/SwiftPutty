import ConfigurationUI
import Persistence
import PuTTYBridge
import SessionLayer
import SwiftUI
import TerminalUI

/// What a session window connects to: the settings from the
/// configuration dialog, as PuTTY will use them (`prepare_session`).
struct SessionRequest: Codable, Hashable {
    var id = UUID()
    /// The launch that opened this window. SwiftUI restores windows with
    /// their values at the next launch; PuTTY never reconnects by itself,
    /// so windows from an earlier launch close instead of connecting.
    var launch = SessionRequest.currentLaunch
    var settings: PuTTYSettings

    init(settings: PuTTYSettings) {
        self.settings = settings.preparedForSession()
    }

    static let currentLaunch = UUID()

    var isFromThisLaunch: Bool { launch == Self.currentLaunch }

    /// PuTTY's `conf_dest`: the host, or the serial line.
    var destination: String {
        settings["Protocol"] == "serial" ? settings["SerialLine"] ?? "" : settings["HostName"] ?? ""
    }
}

/// One terminal window, as each PuTTY session has its own window.
struct SessionWindow: View {
    let request: SessionRequest
    let store: SavedSessionStore
    @State private var controller: SessionController
    @State private var showingError = false
    /// The open Change Settings dialog (GTK PuTTY's "Reconfiguration").
    @State private var reconfiguration: ConfigurationModel?
    @State private var reconfigurationError: String?
    @Environment(\.dismiss) private var dismiss

    init(request: SessionRequest, store: SavedSessionStore) {
        self.request = request
        self.store = store
        _controller = State(initialValue: SessionController(settings: request.settings))
    }

    var body: some View {
        if request.isFromThisLaunch {
            session
        } else {
            Color.clear.onAppear { dismiss() }
        }
    }

    private var session: some View {
        TerminalSessionView(controller: controller)
            .frame(minWidth: 160, minHeight: 80)
            .navigationTitle(windowTitle)
            .task { connect() }
            .onChange(of: controller.state) { _, state in stateChanged(state) }
            .sheet(item: Binding(get: { controller.pendingPrompt },
                                 set: { _ in })) { prompt in
                PuTTYPromptView(prompt: prompt) { answer in
                    controller.answer(prompt, with: answer)
                }
                .interactiveDismissDisabled()
            }
            .alert("SwiftPutty Fatal Error", isPresented: $showingError) {
                Button("OK") {}
            } message: {
                Text(controller.stateDetail ?? "The connection failed.")
            }
            .background {
                // A second sheet needs a view of its own.
                Color.clear
                    .sheet(item: $reconfiguration) { model in
                        ConfigurationView(model: model,
                                          onOpen: { settings in apply(settings) },
                                          onCancel: cancelChangeSettings,
                                          onAbout: {})
                            .interactiveDismissDisabled()
                    }
            }
            .alert("SwiftPutty Reconfiguration", isPresented: Binding(
                get: { reconfigurationError != nil }, set: { if !$0 { reconfigurationError = nil } })) {
                Button("OK") {}
            } message: {
                Text(reconfigurationError ?? "")
            }
            .focusedSceneValue(\.sessionActions, SessionActions(
                changeSettings: changeSettings,
                canChangeSettings: controller.session != nil && !controller.isChangingSettings))
    }

    // MARK: Change Settings (GTK PuTTY change_settings_menuitem)

    private func changeSettings() {
        Task {
            guard let running = await controller.beginChangeSettings() else {
                NSSound.beep()
                return
            }
            let model = ConfigurationModel(changing: running.settings,
                                           protocolInfo: running.protocolInfo,
                                           store: store, beep: { NSSound.beep() })
            model.liveStatus = { [controller] in controller.portForwardStatuses[$0] }
            reconfiguration = model
        }
    }

    private func apply(_ settings: PuTTYSettings) {
        let edits = reconfiguration?.tunnelEdits ?? []
        reconfiguration = nil
        Task {
            if let error = await controller.applyChangeSettings(settings, portForwardingEdits: edits) {
                reconfigurationError = error
            } else if !controller.lastPortForwardingReport.isEmpty {
                reconfigurationError = controller.lastPortForwardingReport.message
            }
        }
    }

    private func cancelChangeSettings() {
        reconfiguration = nil
        controller.cancelChangeSettings()
    }

    /// As GTK PuTTY: the title the terminal set, else the configured
    /// window title, else "host - SwiftPutty"; "(inactive)" once the
    /// session has ended.
    private var windowTitle: String {
        if controller.state.isFinal {
            return "SwiftPutty (inactive)"
        }
        if !controller.title.isEmpty {
            return controller.title
        }
        if let title = controller.settings["WinTitle"], !title.isEmpty {
            return title
        }
        return "\(request.destination) - SwiftPutty"
    }

    private func connect() {
        do {
            try controller.connect()
        } catch {
            showingError = true
        }
    }

    /// PuTTY's "Close window on exit" (CloseOnExit: 0 never, 1 only on
    /// clean exit, 2 always). Failures are reported, and the window kept,
    /// as PuTTY does.
    private func stateChanged(_ state: PuTTYSessionState) {
        switch state {
        case .closed:
            let closeOnExit = controller.settings["CloseOnExit"] ?? "1"
            if closeOnExit == "2" || (closeOnExit == "1" && controller.exitCode == 0) {
                dismiss()
            }
        case .failed:
            showingError = true
        default:
            break
        }
    }
}
