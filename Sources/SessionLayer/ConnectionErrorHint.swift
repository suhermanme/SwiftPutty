import Foundation

/// Extra help for connection errors whose cause is on this Mac rather than
/// the server.
public enum ConnectionErrorHint {
    /// macOS 15 blocks apps from the local network until the user allows
    /// it, and then connections fail with EHOSTUNREACH ("No route to
    /// host"); macOS does not always ask (an earlier answer, or a build it
    /// has not registered). PuTTY's message alone does not say so.
    public static let localNetwork = """
        If the server is on your local network, macOS may be blocking \
        SwiftPutty from it: allow SwiftPutty in System Settings > Privacy & \
        Security > Local Network, then quit and reopen SwiftPutty.
        """

    /// `detail` (a fatal error from the session) with the hint that fits
    /// it, if any.
    public static func message(for detail: String, localNetworkPrivacy: Bool = hasLocalNetworkPrivacy) -> String {
        guard localNetworkPrivacy, detail.contains("No route to host") else { return detail }
        return detail + "\n\n" + localNetwork
    }

    /// Local Network privacy exists from macOS 15.
    public static var hasLocalNetworkPrivacy: Bool {
        if #available(macOS 15, *) { return true }
        return false
    }
}
