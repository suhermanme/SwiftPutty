import PuTTYBridge
import SessionLayer
import SwiftUI
import TerminalUI

/// What a session window connects to. Until saved sessions and the
/// configuration dialog exist (M05), the launcher sets only these.
struct SessionRequest: Codable, Hashable {
    /// PuTTY's `Protocol` keywords for the connection types available.
    enum ConnectionType: String, Codable, CaseIterable {
        case ssh, raw

        var label: String {
            switch self {
            case .ssh: "SSH"
            case .raw: "Raw"
            }
        }

        /// As PuTTY's configuration dialog: choosing a type sets its port.
        var defaultPort: Int {
            switch self {
            case .ssh: 22
            case .raw: 23
            }
        }
    }

    var id = UUID()
    /// The launch that opened this window. SwiftUI restores windows with
    /// their values at the next launch; PuTTY never reconnects by itself,
    /// so windows from an earlier launch close instead of connecting.
    var launch = SessionRequest.currentLaunch
    var connectionType = ConnectionType.ssh
    var host: String
    var port: Int
    /// Empty: PuTTY asks "login as:" in the terminal.
    var userName = ""

    static let currentLaunch = UUID()

    var isFromThisLaunch: Bool { launch == Self.currentLaunch }

    var settings: PuTTYSettings {
        var settings = PuTTYSettings.defaults()
        settings["Protocol"] = connectionType.rawValue
        settings["HostName"] = host
        settings["PortNumber"] = String(port)
        settings["UserName"] = userName
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
