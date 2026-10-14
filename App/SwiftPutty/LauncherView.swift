import PuTTYBridge
import SwiftUI

/// The launcher window. Until saved sessions and the configuration UI
/// exist (M04/M05) it reports the state of the PuTTY core.
struct LauncherView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

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

            Text("Session configuration and SSH connections are not available yet in this build.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("About SwiftPutty") {
                    openWindow(id: WindowID.about)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
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
