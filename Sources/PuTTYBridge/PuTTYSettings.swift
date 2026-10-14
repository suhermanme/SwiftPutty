import PuTTYBridgeC

/// A PuTTY saved-session settings document: PuTTY save keywords
/// (`HostName`, `PortForwardings`, ...) mapped to their stored string
/// values, exactly as PuTTY's Unix session files hold them.
///
/// Conversion to and from PuTTY's internal configuration happens in C,
/// through upstream's own load/save code (docs/DECISIONS.md D-004).
public struct PuTTYSettings: Equatable, Sendable {
    public var values: [String: String]

    public init(values: [String: String] = [:]) {
        self.values = values
    }

    /// PuTTY's built-in defaults ("Default Settings" with nothing saved).
    public static func defaults() -> PuTTYSettings {
        let handle = spb_settings_new_defaults()!
        defer { spb_settings_free(handle) }
        return PuTTYSettings(handle: handle)
    }

    public subscript(keyword: String) -> String? {
        get { values[keyword] }
        set { values[keyword] = newValue }
    }

    /// Keywords in PuTTY's deterministic (byte-wise ascending) order.
    public var sortedKeywords: [String] {
        values.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    /// These settings as PuTTY itself would save them: unknown keywords
    /// dropped, missing ones defaulted, legacy forms converted.
    public func normalised() -> PuTTYSettings {
        withBridgeHandle { handle in
            spb_settings_normalise(handle)
            return PuTTYSettings(handle: handle)
        }
    }

    init(handle: OpaquePointer) {
        var values: [String: String] = [:]
        let count = spb_settings_count(handle)
        values.reserveCapacity(count)
        for index in 0..<count {
            let key = String(cString: spb_settings_key_at(handle, index))
            let value = String(cString: spb_settings_value_at(handle, index))
            values[key] = value
        }
        self.values = values
    }

    /// Runs `body` with a temporary bridge settings object holding these
    /// values. The handle is freed afterwards and must not escape.
    func withBridgeHandle<R>(_ body: (OpaquePointer) throws -> R) rethrows -> R {
        let handle = spb_settings_new_empty()!
        defer { spb_settings_free(handle) }
        for (key, value) in values {
            spb_settings_set(handle, key, value)
        }
        return try body(handle)
    }
}
