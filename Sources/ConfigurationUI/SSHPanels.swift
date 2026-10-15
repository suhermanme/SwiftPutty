import PuTTYBridge
import SwiftUI

// Connection/SSH and Connection/SSH/Tunnels (M08, M12), as config.c.

// MARK: - Connection/SSH

struct SSHPanel: View {
    let model: ConfigurationModel

    /// SSH-1 or a connection-sharing downstream (backend_cfg_info).
    private var isSSH1OrDownstream: Bool {
        model.protocolInfo == 1 || model.protocolInfo == -1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.isMidSession && isSSH1OrDownstream {
                Text("Nothing on this panel may be reconfigured in mid-session; it is only here so that sub-panels of it can exist without looking strange.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.isMidSession {
                SettingsGroup(title: "Data to send to the server") {
                    TextSetting(model: model, label: "Remote command:", keyword: .remoteCommand)
                }
            }
            if !model.isMidSession || !isSSH1OrDownstream {
                SettingsGroup(title: "Protocol options") {
                    if !model.isMidSession {
                        CheckboxSetting(model: model, label: "Don't start a shell or command at all",
                                        keyword: .sshNoShell)
                    }
                    CheckboxSetting(model: model, label: "Enable compression", keyword: .compression)
                    if !model.isMidSession {
                        RadioSetting(model: model, label: "SSH protocol version:",
                                     keyword: .sshProtocolVersion,
                                     options: [("2", "3"), ("1 (INSECURE)", "0")])
                    }
                }
            }
            if !model.isMidSession {
                // unix/sharing.c: a Unix-domain socket in a private
                // directory under /tmp, as GTK PuTTY.
                SettingsGroup(title: "Sharing an SSH connection between PuTTY tools") {
                    CheckboxSetting(model: model, label: "Share SSH connections if possible",
                                    keyword: .connectionSharing)
                    Text("Permitted roles in a shared connection:")
                    CheckboxSetting(model: model, label: "Upstream (connecting to the real server)",
                                    keyword: .connectionSharingUpstream)
                    CheckboxSetting(model: model, label: "Downstream (connecting to the upstream PuTTY)",
                                    keyword: .connectionSharingDownstream)
                }
            }
        }
    }
}

// MARK: - Connection/SSH/Tunnels

struct TunnelsPanel: View {
    @Bindable var model: ConfigurationModel

    var body: some View {
        SettingsGroup(title: "Port forwarding") {
            CheckboxSetting(model: model, label: "Local ports accept connections from other hosts",
                            keyword: .localPortAcceptAll)
            CheckboxSetting(model: model, label: "Remote ports do the same (SSH-2 only)",
                            keyword: .remotePortAcceptAll)
            Text("Forwarded ports:")
            HStack(alignment: .top) {
                forwardedPorts
                Button("Remove") { model.removeForwarding() }
                    .frame(width: 80)
            }
            Text("Add new forwarded port:")
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Source port")
                    PlainTextField(label: "Source port", text: $model.tunnelSource)
                        .frame(width: 140)
                }
                Spacer()
                Button("Add") { model.addForwarding() }
                    .frame(width: 80)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Destination")
                PlainTextField(label: "Destination", text: $model.tunnelDestination)
                    .disabled(model.tunnelKind == .dynamic)
            }
            Picker("Direction", selection: $model.tunnelKind) {
                Text("Local").tag(PortForwarding.Kind.local)
                Text("Remote").tag(PortForwarding.Kind.remote)
                Text("Dynamic").tag(PortForwarding.Kind.dynamic)
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
            .labelsHidden()
            Picker("Address family", selection: $model.tunnelFamily) {
                Text("Auto").tag(PortForwarding.AddressFamily.any)
                Text("IPv4").tag(PortForwarding.AddressFamily.ipv4)
                Text("IPv6").tag(PortForwarding.AddressFamily.ipv6)
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
            .labelsHidden()
        }
    }

    /// config.c's two-column list ("L8080", "localhost:80"); mid-session
    /// with each forwarding's live state.
    private var forwardedPorts: some View {
        List(selection: $model.selectedForwarding) {
            ForEach(model.forwardings, id: \.self) { forwarding in
                HStack {
                    Text(forwarding.displayKey)
                        .frame(width: 110, alignment: .leading)
                    Text(forwarding.destination)
                    Spacer()
                    if model.isMidSession {
                        Text(Self.describe(model.liveStatus?(forwarding)))
                            .foregroundStyle(.secondary)
                            .help(model.liveStatus?(forwarding)?.message ?? "")
                    }
                }
                .tag(forwarding)
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: false))
        .frame(height: 5 * 22)
    }

    static func describe(_ status: PortForwardStatus?) -> String {
        guard let status else { return "Not active" }
        return switch status.state {
        case .listening: "Listening"
        case .listenFailed: "Failed"
        case .remoteRequested: "Requested"
        case .remoteEnabled: "Enabled"
        case .remoteRefused: "Refused"
        case .duplicate: "Duplicate"
        case .closed: "Closed"
        }
    }
}
