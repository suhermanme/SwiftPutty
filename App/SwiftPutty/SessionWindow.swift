import PuTTYBridge
import SessionLayer
import SwiftUI
import TerminalUI

/// What a session window connects to. Until saved sessions and the
/// configuration dialog exist (M05), the launcher opens Raw connections.
struct SessionRequest: Codable, Hashable {
    var id = UUID()
    var host: String
    var port: Int

    var settings: PuTTYSettings {
        var settings = PuTTYSettings.defaults()
        settings["Protocol"] = "raw"
        settings["HostName"] = host
        settings["PortNumber"] = String(port)
        return settings
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
        TerminalSessionView(controller: controller)
            .frame(minWidth: 160, minHeight: 80)
            .navigationTitle(windowTitle)
            .task { connect() }
            .onChange(of: controller.state) { _, state in stateChanged(state) }
            .alert("SwiftPutty Fatal Error", isPresented: $showingError) {
                Button("OK") {}
            } message: {
                Text(controller.stateDetail ?? "The connection failed.")
            }
    }

    /// As PuTTY: the terminal's title, else "host - PuTTY"; "(inactive)"
    /// once the session has ended.
    private var windowTitle: String {
        if controller.state.isFinal {
            return "SwiftPutty (inactive)"
        }
        return controller.title.isEmpty ? "\(request.host) - SwiftPutty" : controller.title
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
