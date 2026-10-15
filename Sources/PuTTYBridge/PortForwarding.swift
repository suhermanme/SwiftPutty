import Foundation
import PuTTYBridgeC

/// One configured SSH port forwarding, as PuTTY's `CONF_portfwd` holds
/// it: a key such as `L8080`, `4R2222` or `L127.0.0.1:8080` (optional
/// address family `4`/`6`, then `L` or `R`, then the source port with an
/// optional address) and a value `host:port`, or `D` for a dynamic
/// (SOCKS) forwarding, which is filed under `L`.
public struct PortForwarding: Hashable, Sendable {
    public enum Kind: Sendable { case local, remote, dynamic }
    public enum AddressFamily: Sendable { case any, ipv4, ipv6 }

    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    /// As config.c's Add button builds it.
    public init(kind: Kind, family: AddressFamily, source: String, destination: String) {
        let familyPrefix = switch family {
        case .any: ""
        case .ipv4: "4"
        case .ipv6: "6"
        }
        key = familyPrefix + (kind == .remote ? "R" : "L") + source
        value = kind == .dynamic ? "D" : destination
    }

    public var family: AddressFamily {
        switch key.first {
        case "4": .ipv4
        case "6": .ipv6
        default: .any
        }
    }

    private var afterFamily: Substring {
        key.first.map { "A46".contains($0) } == true ? key.dropFirst() : Substring(key)
    }

    public var kind: Kind {
        if value == "D" { return .dynamic }
        return afterFamily.first == "R" ? .remote : .local
    }

    /// The source: `[address:]port`.
    public var source: String {
        String(afterFamily.first.map { "LR".contains($0) } == true ? afterFamily.dropFirst() : afterFamily)
    }

    /// The destination `host:port` (empty for dynamic forwardings).
    public var destination: String { kind == .dynamic ? "" : value }

    /// How config.c lists it: `L8080` / `D1080` and the destination.
    public var displayKey: String {
        guard kind == .dynamic, let l = key.firstIndex(of: "L") else { return key }
        var shown = key
        shown.replaceSubrange(l...l, with: "D")
        return shown
    }

    /// Where a remote forwarding listens on the server, as
    /// portfwdmgr_config() asks for it: two remote forwardings with the
    /// same listening address make PuTTY drop one ("duplicate"). nil for
    /// local and dynamic forwardings.
    public func remoteListenAddress(acceptAll: Bool) -> String? {
        guard kind == .remote else { return nil }
        let src = source
        // host_strchr: a colon outside brackets separates address and port.
        var depth = 0
        var colon: String.Index?
        for index in src.indices {
            switch src[index] {
            case "[": depth += 1
            case "]": depth -= 1
            case ":" where depth == 0: colon = colon ?? index
            default: break
            }
        }
        let address: String
        let port: String
        if let colon {
            address = String(src[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            port = String(src[src.index(after: colon)...])
        } else {
            address = acceptAll ? "" : "localhost"
            port = src
        }
        return "\(address):\(port)"
    }
}

/// A forwarding changed by editing it (PuTTY's Remove, then Add with the
/// fields it filled in): staged so that a failed change keeps the old one.
public struct PortForwardingEdit: Hashable, Sendable {
    public var old: PortForwarding
    public var new: PortForwarding

    public init(old: PortForwarding, new: PortForwarding) {
        self.old = old
        self.new = new
    }
}

/// What PuTTY reports about a configured forwarding (patch 0006).
public struct PortForwardStatus: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case listening, listenFailed
        case remoteRequested, remoteEnabled, remoteRefused, duplicate
        case closed

        init(_ state: spb_portfwd_state) {
            self = switch state {
            case SPB_PORTFWD_LISTENING: .listening
            case SPB_PORTFWD_LISTEN_FAILED: .listenFailed
            case SPB_PORTFWD_REMOTE_REQUESTED: .remoteRequested
            case SPB_PORTFWD_REMOTE_ENABLED: .remoteEnabled
            case SPB_PORTFWD_REMOTE_REFUSED: .remoteRefused
            case SPB_PORTFWD_DUPLICATE: .duplicate
            default: .closed
            }
        }

        /// The forwarding is working.
        public var isUp: Bool { self == .listening || self == .remoteEnabled }
        /// Setting it up has finished, one way or the other.
        public var isSettled: Bool { self != .remoteRequested }
    }

    public var state: State
    public var forwarding: PortForwarding
    public var message: String?

    public init(state: State, forwarding: PortForwarding, message: String?) {
        self.state = state
        self.forwarding = forwarding
        self.message = message
    }

    init(_ status: UnsafePointer<spb_portfwd_status>) {
        let s = status.pointee
        state = State(s.state)
        forwarding = PortForwarding(key: String(cString: s.key), value: String(cString: s.value))
        message = s.message.map { String(cString: $0) }
    }
}

extension PuTTYSettings {
    /// The `PortForwardings` setting, in order. Parsed and written as
    /// settings.c's gppmap / wmap do: entries separated by commas, `key`
    /// and value separated by `=`, a backslash escaping the next
    /// character; dynamic forwardings stored as `D<port>` with no value.
    public var portForwardings: [PortForwarding] {
        get { Self.parsePortForwardings(self["PortForwardings"] ?? "") }
        set { self["PortForwardings"] = Self.formatPortForwardings(newValue) }
    }

    public static func parsePortForwardings(_ text: String) -> [PortForwarding] {
        var result: [PortForwarding] = []
        var iterator = text.makeIterator()
        var key = "", value = "", inValue = false, atEnd = false
        while !atEnd {
            guard let c = iterator.next() else {
                atEnd = true
                if !key.isEmpty || inValue { result.append(entry(key, value)) }
                break
            }
            switch c {
            case ",":
                result.append(entry(key, value))
                key = ""; value = ""; inValue = false
            case "=" where !inValue:
                inValue = true
            case "\\":
                if let next = iterator.next() {
                    if inValue { value.append(next) } else { key.append(next) }
                }
            default:
                if inValue { value.append(c) } else { key.append(c) }
            }
        }
        return result
    }

    /// gppmap's compatibility rule: a key containing `D` is dynamic.
    private static func entry(_ key: String, _ value: String) -> PortForwarding {
        if let d = key.firstIndex(of: "D") {
            var internalKey = key
            internalKey.replaceSubrange(d...d, with: "L")
            return PortForwarding(key: internalKey, value: "D")
        }
        return PortForwarding(key: key, value: value)
    }

    public static func formatPortForwardings(_ forwardings: [PortForwarding]) -> String {
        func escaped(_ s: String) -> String {
            var out = ""
            for c in s {
                if c == "=" || c == "," || c == "\\" { out.append("\\") }
                out.append(c)
            }
            return out
        }
        return forwardings.map { f in
            if f.value == "D" {
                return escaped(f.displayKey) + "="
            }
            return escaped(f.key) + "=" + escaped(f.value)
        }.joined(separator: ",")
    }
}
