import PuTTYBridge
import SwiftUI

/// About window with the licence notices required by PuTTY's MIT licence.
struct AboutView: View {
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private var thirdPartyNotices: String? {
        Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SwiftPutty")
                    .font(.title.weight(.semibold))
                Text("Version \(appVersion)")
                    .foregroundStyle(.secondary)
                Text("A macOS frontend for the PuTTY \(PuTTYCore.version) core.")
                Text("SwiftPutty is not an official PuTTY product and is not affiliated with or endorsed by the PuTTY developers.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("PuTTY licence")
                .font(.headline)
            ScrollView {
                Text(PuTTYCore.licenceText)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 220)
            .background(.background.secondary, in: .rect(cornerRadius: 6))

            if let notices = thirdPartyNotices {
                DisclosureGroup("Third-party notices") {
                    ScrollView {
                        Text(notices)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(height: 180)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
