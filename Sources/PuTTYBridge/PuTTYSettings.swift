import PuTTYBridgeC

/// A PuTTY saved-session settings document: PuTTY save keywords
/// (`HostName`, `PortForwardings`, ...) mapped to their stored string
/// values, exactly as PuTTY's Unix session files hold them.
///
/// Conversion to and from PuTTY's internal configuration happens in C,
/// through upstream's own load/save code (docs/DECISIONS.md D-004).
public struct PuTTYSettings: Hashable, Sendable, Codable {
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

    /// These settings as PuTTY will use them to connect (upstream
    /// `prepare_session`): a `user@` prefix on the host name becomes the
    /// user name, a single `:suffix` is dropped, whitespace is removed.
    /// Sessions do this themselves; use it to show the destination.
    public func preparedForSession() -> PuTTYSettings {
        withBridgeHandle { handle in
            spb_settings_prepare_session(handle)
            return PuTTYSettings(handle: handle)
        }
    }

    /// PuTTY's character sets, as its configuration dialog lists them
    /// ("Remote character set", `LineCodePage`).
    public static let characterSets: [String] = {
        var names: [String] = []
        while let name = spb_charset_name(names.count) {
            names.append(String(cString: name))
        }
        return names
    }()

    /// The name PuTTY shows for a `LineCodePage` value: canonical, and
    /// UTF-8 for an empty value.
    public static func canonicalCharacterSet(_ lineCodePage: String) -> String {
        String(cString: spb_charset_canonical_name(lineCodePage))
    }

    // A keyword map, encoded as a plain JSON object.
    public init(from decoder: any Decoder) throws {
        values = try decoder.singleValueContainer().decode([String: String].self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
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
