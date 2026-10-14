import PuTTYBridge
import SwiftUI

/// The launcher window. Until saved sessions and the configuration UI
/// exist (M05) it reports the state of the PuTTY core and opens SSH and
/// Raw connections.
struct LauncherView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var host = ""
    @State private var port = "22"
    @State private var userName = ""
    @State private var connectionType = SessionRequest.ConnectionType.ssh

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("SwiftPutty")
                        .font(.title2.weight(.semibold))
                    Text("Based on PuTTY \(PuTTYCore.version)")
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox {
                coreStatus
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
            } label: {
                Text("PuTTY core")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Host Name (or IP address)", text: $host)
                        TextField("Port", text: $port)
                            .frame(width: 64)
                    }
                    HStack {
                        Picker("Connection type", selection: $connectionType) {
                            ForEach(SessionRequest.ConnectionType.allCases, id: \.self) { type in
                                Text(type.label).tag(type)
                            }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .onChange(of: connectionType) { _, type in
                            port = String(type.defaultPort)
                        }
                        if connectionType == .ssh {
                            TextField("User name (optional)", text: $userName)
                        }
                    }
                    HStack {
                        Text("Saved sessions and the full configuration arrive in a later milestone.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Open") { open() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!canOpen)
                    }
                }
                .padding(4)
            } label: {
                Text("Connection")
            }

            HStack {
                Spacer()
                Button("About SwiftPutty") {
                    openWindow(id: WindowID.about)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        #if DEBUG
        .task {
            // Developer aid (debug builds only): SWIFTPUTTY_DEBUG_OPEN_RAW or
            // SWIFTPUTTY_DEBUG_OPEN_SSH=[user@]host:port opens a session at
            // launch, for screenshots and manual checks.
            let environment = ProcessInfo.processInfo.environment
            for (variable, type) in [("SWIFTPUTTY_DEBUG_OPEN_RAW", SessionRequest.ConnectionType.raw),
                                     ("SWIFTPUTTY_DEBUG_OPEN_SSH", .ssh)] {
                guard var target = environment[variable] else { continue }
                if let at = target.lastIndex(of: "@") {
                    userName = String(target[..<at])
                    target = String(target[target.index(after: at)...])
                }
                guard let colon = target.lastIndex(of: ":"),
                      let port = Int(target[target.index(after: colon)...]) else { continue }
                connectionType = type
                host = String(target[..<colon])
                self.port = String(port)
                open()
            }
        }
        #endif
    }

    private var canOpen: Bool {
        guard case .running = model.coreState else { return false }
        let port = Int(port) ?? 0
        return !host.trimmingCharacters(in: .whitespaces).isEmpty && (1...65535).contains(port)
    }

    private func open() {
        guard canOpen, let port = Int(port) else { return }
        openWindow(id: WindowID.session,
                   value: SessionRequest(connectionType: connectionType,
                                         host: host.trimmingCharacters(in: .whitespaces),
                                         port: port,
                                         userName: connectionType == .ssh
                                             ? userName.trimmingCharacters(in: .whitespaces) : ""))
    }

    @ViewBuilder
    private var coreStatus: some View {
        switch model.coreState {
        case .notStarted:
            Label("Starting…", systemImage: "hourglass")
        case .running(let directory):
            VStack(alignment: .leading, spacing: 6) {
                Label("Running", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                LabeledContent("State directory") {
                    Text(directory.path)
                        .textSelection(.enabled)
                        .truncationMode(.middle)
                        .lineLimit(1)
                }
                LabeledContent("Bridge API") {
                    Text("\(PuTTYCore.bridgeAPIVersion)")
                }
                LabeledContent("Core thread") {
                    Text("Running (shared by all sessions)")
                }
            }
        case .failed(let message):
            Label {
                Text("The PuTTY core could not start: \(message)")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
            }
        }
    }
}
