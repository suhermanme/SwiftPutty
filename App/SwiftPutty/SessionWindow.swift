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
    @State private var controller: SessionController
    @State private var showingError = false
    @Environment(\.dismiss) private var dismiss

    init(request: SessionRequest) {
        self.request = request
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
        if let title = request.settings["WinTitle"], !title.isEmpty {
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
