import Foundation
import Observation
import Persistence
import PuTTYBridge

/// The state of PuTTY's configuration dialog before a session starts:
/// the settings being edited (the dialog's `Conf`) and the Session
/// panel's saved-session controls.
///
/// The behaviour is upstream's `config.c`: `sessionsaver_handler` for
/// Load / Save / Delete / Open and the saved-session list,
/// `config_protocols_handler` and `config_port_handler` for the
/// destination. Places where PuTTY beeps call ``beep``.
@MainActor
@Observable
public final class ConfigurationModel: Identifiable {
    /// The settings being edited.
    public var settings: PuTTYSettings
    /// The "Saved Sessions" edit box.
    public private(set) var savedSessionName = ""
    /// The saved-session list (`get_sesslist`).
    public private(set) var sessionNames: [String] = []
    /// The list's selection.
    public var selectedSessionIndex: Int?
    /// Whether the session list had the keyboard focus last among the
    /// dialog's controls (PuTTY's `dlg_last_focused`), which changes what
    /// Open does.
    public var sessionListWasLastFocused = false
    /// An error to show (PuTTY's `dlg_error_msg`).
    public var errorMessage: String?

    /// Change Settings on a running session (PuTTY's `midsession`):
    /// settings that only a new connection could use are not shown.
    public let isMidSession: Bool
    /// Mid-session: PuTTY's `backend_cfg_info` (2 for SSH-2).
    public let protocolInfo: Int32

    @ObservationIgnored public var beep: () -> Void
    @ObservationIgnored private let store: SavedSessionStore

    /// Starts from "Default Settings", as PuTTY's `do_defaults`.
    public init(store: SavedSessionStore, beep: @escaping () -> Void = {}) {
        self.store = store
        self.beep = beep
        isMidSession = false
        protocolInfo = 0
        do {
            settings = try store.loadDefaults()
        } catch {
            settings = PuTTYSettings.defaults()
            errorMessage = error.localizedDescription
        }
        refreshSessionNames()
    }

    /// Change Settings: starts from the running session's settings.
    public init(changing running: PuTTYSettings, protocolInfo: Int32,
                store: SavedSessionStore, beep: @escaping () -> Void = {}) {
        self.store = store
        self.beep = beep
        isMidSession = true
        self.protocolInfo = protocolInfo
        settings = running
        refreshSessionNames()
    }

    /// config.c shows the SSH packet logging options for SSH sessions
    /// only once a session runs; before, whenever SSH is available.
    public var showsSSHLogging: Bool {
        !isMidSession || connectionType == "ssh"
    }

    // MARK: - Destination

    /// PuTTY's `conf_launchable`: there is somewhere to connect to.
    public static func isLaunchable(_ settings: PuTTYSettings) -> Bool {
        if settings[.protocolName] == "serial" {
            return !(settings[.serialLine] ?? "").isEmpty
        }
        return !(settings[.hostName] ?? "").isEmpty
    }

    public var isLaunchable: Bool { Self.isLaunchable(settings) }

    /// The connection type (PuTTY's `Protocol` keyword).
    public var connectionType: String {
        get { settings[.protocolName] ?? "ssh" }
        set { setConnectionType(newValue) }
    }

    /// The port (PuTTY's port box shows 0 as blank).
    public var port: Int {
        get { Self.atoi(settings[.portNumber] ?? "0") }
        set { settings[.portNumber] = String(newValue) }
    }

    /// Default ports of PuTTY's backends (`BackendVtable.default_port`).
    public static func defaultPort(for connectionType: String) -> Int {
        switch connectionType {
        case "ssh": 22
        case "telnet": 23
        case "rlogin": 513
        case "supdup": 95
        default: 0                      // raw, serial: no sensible default
        }
    }

    /// `config_protocols_handler`: if the port is still the old
    /// protocol's default, it becomes the new protocol's default.
    private func setConnectionType(_ newType: String) {
        let oldType = connectionType
        guard newType != oldType else { return }
        settings[.protocolName] = newType
        if Self.atoi(settings[.portNumber] ?? "0") == Self.defaultPort(for: oldType) {
            settings[.portNumber] = String(Self.defaultPort(for: newType))
        }
    }

    // MARK: - Saved sessions (sessionsaver_handler)

    /// Typing in the "Saved Sessions" box selects the first list entry
    /// at or after the text (PuTTY's binary search over the list).
    public func setSavedSessionName(_ name: String) {
        savedSessionName = name
        guard !sessionNames.isEmpty else { return }
        var top = sessionNames.count, bottom = -1
        while top - bottom > 1 {
            let halfway = (top + bottom) / 2
            // strcmp(name, sessionNames[halfway]) <= 0
            if name == sessionNames[halfway] || SavedSessionStore.precedes(name, sessionNames[halfway]) {
                top = halfway
            } else {
                bottom = halfway
            }
        }
        if top == sessionNames.count { top -= 1 }
        selectedSessionIndex = top
    }

    /// The Load button. Returns false (and beeps) with nothing selected.
    @discardableResult
    public func loadSelectedSession() -> Bool {
        guard !isMidSession else { return false }
        return loadSelected(into: &settings) != nil
    }

    /// A double-click in the list: loads the session, and returns the
    /// settings to open if PuTTY would start it at once (a saved
    /// session, not "Default Settings", with a destination). Nothing
    /// mid-session, where sessions cannot be loaded.
    public func openSessionFromList() -> PuTTYSettings? {
        guard !isMidSession else { return nil }
        guard let isDefault = loadSelected(into: &settings) else { return nil }
        return !isDefault && isLaunchable ? settings : nil
    }

    /// The Save button: saves under the typed name, or else over the
    /// selected session.
    public func save() {
        if savedSessionName.isEmpty {
            guard let index = selectedSessionIndex, sessionNames.indices.contains(index) else {
                beep()
                return
            }
            let name = sessionNames[index]
            savedSessionName = name == SavedSessionStore.defaultSettingsName ? "" : name
        }
        do {
            try store.save(settings, as: savedSessionName)
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshSessionNames()
        setSavedSessionName(savedSessionName)
    }

    /// The Delete button. "Default Settings" (the first entry) cannot be
    /// deleted.
    public func deleteSelectedSession() {
        guard !isMidSession else { return }
        guard let index = selectedSessionIndex, index > 0, index < sessionNames.count else {
            beep()
            return
        }
        do {
            try store.delete(sessionNames[index])
        } catch {
            errorMessage = error.localizedDescription
        }
        // Refilling the list clears its selection, as in PuTTY.
        refreshSessionNames()
        selectedSessionIndex = nil
    }

    /// The Open button: the settings to start a session with, or nil
    /// (after a beep) if there is nothing to connect to.
    ///
    /// PuTTY's "annoying special case": with no host name, if the list
    /// had the focus and a saved session with a destination is selected,
    /// that session is loaded and opened.
    public func open() -> PuTTYSettings? {
        // "In a mid-session Change Settings, Apply is always OK."
        if isMidSession {
            return settings
        }
        if sessionListWasLastFocused && !isLaunchable {
            var candidate = settings
            guard let isDefault = loadSelected(into: &candidate) else {
                beep()
                return nil
            }
            if !isDefault && Self.isLaunchable(candidate) {
                settings = candidate
                return settings
            }
            beep()
            return nil
        }
        guard isLaunchable else {
            beep()
            return nil
        }
        return settings
    }

    /// `load_selected_session`: loads the selected session into target
    /// and sets the name box. Returns whether it was "Default Settings",
    /// or nil (after a beep) if nothing is selected.
    private func loadSelected(into target: inout PuTTYSettings) -> Bool? {
        guard let index = selectedSessionIndex, sessionNames.indices.contains(index) else {
            beep()
            return nil
        }
        let name = sessionNames[index]
        let isDefault = name == SavedSessionStore.defaultSettingsName
        do {
            target = try store.load(name).settings
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
        savedSessionName = isDefault ? "" : name
        selectedSessionIndex = index
        return isDefault
    }

    private func refreshSessionNames() {
        do {
            sessionNames = try store.sessionNames()
        } catch {
            sessionNames = [SavedSessionStore.defaultSettingsName]
            errorMessage = error.localizedDescription
        }
        if let index = selectedSessionIndex, index >= sessionNames.count {
            selectedSessionIndex = nil
        }
    }

    // MARK: - Settings access for the panels

    public func string(_ keyword: PuTTYKeyword) -> String {
        settings[keyword] ?? ""
    }

    public func setString(_ keyword: PuTTYKeyword, _ value: String) {
        settings[keyword] = value
    }

    /// PuTTY stores booleans as "0"/"1".
    public func bool(_ keyword: PuTTYKeyword) -> Bool {
        Self.atoi(settings[keyword] ?? "0") != 0
    }

    public func setBool(_ keyword: PuTTYKeyword, _ value: Bool) {
        settings[keyword] = value ? "1" : "0"
    }

    public func int(_ keyword: PuTTYKeyword) -> Int {
        Self.atoi(settings[keyword] ?? "0")
    }

    public func setInt(_ keyword: PuTTYKeyword, _ value: Int) {
        settings[keyword] = String(value)
    }

    /// PuTTY's keepalive interval in seconds: saved as minutes plus
    /// seconds, `PingInterval` and `PingIntervalSecs` (settings.c).
    public var keepaliveSeconds: Int {
        get { int(.pingInterval) * 60 + int(.pingIntervalSecs) }
        set {
            let seconds = max(0, newValue)
            setInt(.pingInterval, seconds / 60)
            setInt(.pingIntervalSecs, seconds % 60)
        }
    }

    // MARK: Tunnels (config.c portfwd_handler, M08)

    /// The forwardings, as PuTTY lists them (Conf order: by key).
    public var forwardings: [PortForwarding] {
        settings.portForwardings.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
    }

    /// The "Add new forwarded port" fields.
    public var tunnelSource = ""
    public var tunnelDestination = ""
    public var tunnelKind = PortForwarding.Kind.local
    public var tunnelFamily = PortForwarding.AddressFamily.any
    /// The selected entry of the forwarded ports list.
    public var selectedForwarding: PortForwarding?

    /// Edits made with PuTTY's idiom (Remove fills the fields with the
    /// removed entry; Add then adds the changed one): Change Settings
    /// stages them so a failure keeps the old forwarding.
    public private(set) var tunnelEdits: [PortForwardingEdit] = []
    @ObservationIgnored private var removedForEditing: PortForwarding?

    /// Live state of a forwarding, mid-session (set by the session
    /// window; reads the session's observable state).
    @ObservationIgnored public var liveStatus: ((PortForwarding) -> PortForwardStatus?)?

    /// The Add button. Error messages are config.c's, plus a check
    /// SwiftPutty adds: two remote forwardings on the same server port
    /// would make PuTTY drop one (hazard H-2).
    public func addForwarding() {
        let source = tunnelSource
        guard !source.isEmpty else {
            errorMessage = "You need to specify a source port number"
            return
        }
        if tunnelKind != .dynamic {
            guard !tunnelDestination.isEmpty, Self.hostHasPort(tunnelDestination) else {
                errorMessage = "You need to specify a destination address\nin the form \"host.name:port\""
                return
            }
        }
        let new = PortForwarding(kind: tunnelKind, family: tunnelFamily, source: source,
                                 destination: tunnelDestination)
        var current = settings.portForwardings
        guard !current.contains(where: { $0.key == new.key }) else {
            errorMessage = "Specified forwarding already exists"
            return
        }
        let acceptAll = bool(.remotePortAcceptAll)
        if let address = new.remoteListenAddress(acceptAll: acceptAll),
           current.contains(where: { $0.remoteListenAddress(acceptAll: acceptAll) == address }) {
            errorMessage = "A remote forwarding from that server port already exists"
            return
        }
        current.append(new)
        settings.portForwardings = current
        if let old = removedForEditing {
            tunnelEdits.append(PortForwardingEdit(old: old, new: new))
            removedForEditing = nil
        }
    }

    /// The Remove button: removes the selected entry and puts it in the
    /// fields "for ease of editing", as config.c does.
    public func removeForwarding() {
        guard let selected = selectedForwarding,
              settings.portForwardings.contains(selected) else {
            beep()
            return
        }
        tunnelFamily = selected.family
        tunnelKind = selected.kind
        tunnelSource = selected.source
        tunnelDestination = selected.destination
        settings.portForwardings.removeAll { $0 == selected }
        selectedForwarding = nil
        // Removing the result of an edit continues that edit.
        if let index = tunnelEdits.firstIndex(where: { $0.new == selected }) {
            removedForEditing = tunnelEdits.remove(at: index).old
        } else {
            removedForEditing = selected
        }
    }

    /// host_strchr(text, ':') != NULL: a colon outside brackets.
    static func hostHasPort(_ text: String) -> Bool {
        var depth = 0
        for c in text {
            if c == "[" { depth += 1 } else if c == "]" { depth -= 1 } else if c == ":" && depth == 0 { return true }
        }
        return false
    }

    // MARK: Formats of the Terminal and Window panels (M06)

    /// "Initial state of numeric keypad" (`numeric_keypad_handler`): one
    /// radio over two keywords. 0 Normal, 1 Application, 2 NetHack.
    public var numericKeypadMode: Int {
        get { bool(.netHackKeypad) ? 2 : bool(.applicationKeypad) ? 1 : 0 }
        set {
            setBool(.applicationKeypad, newValue == 1)
            setBool(.netHackKeypad, newValue == 2)
        }
    }

    /// PuTTY's colour list (`CONF_COLOUR_LIST`), saved as `Colour0` ...
    /// `Colour21`.
    public static let colourNames = [
        "Default Foreground", "Default Bold Foreground",
        "Default Background", "Default Bold Background",
        "Cursor Text", "Cursor Colour",
        "ANSI Black", "ANSI Black Bold", "ANSI Red", "ANSI Red Bold",
        "ANSI Green", "ANSI Green Bold", "ANSI Yellow", "ANSI Yellow Bold",
        "ANSI Blue", "ANSI Blue Bold", "ANSI Magenta", "ANSI Magenta Bold",
        "ANSI Cyan", "ANSI Cyan Bold", "ANSI White", "ANSI White Bold",
    ]

    /// Colour `index` as (red, green, blue), each 0...255.
    public func colour(_ index: Int) -> (red: Int, green: Int, blue: Int) {
        let parts = (settings["Colour\(index)"] ?? "").split(separator: ",", omittingEmptySubsequences: false)
        func component(_ i: Int) -> Int {
            i < parts.count ? min(255, max(0, Self.atoi(String(parts[i])))) : 0
        }
        return (component(0), component(1), component(2))
    }

    /// As `colour_handler`: components are clamped to 0...255.
    public func setColour(_ index: Int, red: Int, green: Int, blue: Int) {
        let clamp = { (v: Int) in min(255, max(0, v)) }
        settings["Colour\(index)"] = "\(clamp(red)),\(clamp(green)),\(clamp(blue))"
    }

    /// The character class of `character` (0...255), saved as
    /// `Wordness0`, `Wordness32`, ... with 32 values each.
    public func characterClass(_ character: Int) -> Int {
        let parts = (settings["Wordness\(character / 32 * 32)"] ?? "").split(separator: ",")
        let i = character % 32
        return i < parts.count ? Self.atoi(String(parts[i])) : 0
    }

    /// `charclass_handler`'s Set button: the given characters get class
    /// `atoi(text)`.
    public func setCharacterClass(_ characters: some Sequence<Int>, to text: String) {
        let value = Self.atoi(text)
        for character in characters where (0..<256).contains(character) {
            let key = "Wordness\(character / 32 * 32)"
            var parts = (settings[key] ?? "").split(separator: ",").map(String.init)
            while parts.count < 32 { parts.append("0") }
            parts[character % 32] = String(value)
            settings[key] = parts.joined(separator: ",")
        }
    }

    /// The bell overload times: saved in microseconds on Unix
    /// (settings.c multiplies PuTTY's milliseconds by 1000); shown in
    /// seconds, as config.c's fixed-point edit box.
    public func seconds(_ keyword: PuTTYKeyword) -> String {
        Self.formatFixedPoint(int(keyword), denominator: 1_000_000)
    }

    public func setSeconds(_ keyword: PuTTYKeyword, _ text: String) {
        setInt(keyword, Self.parseFixedPoint(text, denominator: 1_000_000))
    }

    /// `EDIT_FIXEDPOINT`: the value over `denominator`, without trailing
    /// zeros.
    public static func formatFixedPoint(_ value: Int, denominator: Int) -> String {
        let whole = value / denominator, fraction = abs(value % denominator)
        guard fraction != 0 else { return String(whole) }
        var digits = String(fraction)
        digits = String(repeating: "0", count: String(denominator).count - 1 - digits.count) + digits
        while digits.hasSuffix("0") { digits.removeLast() }
        return (value < 0 && whole == 0 ? "-" : "") + "\(whole).\(digits)"
    }

    /// As config.c reads a fixed-point box (`atof` scaled, truncated).
    public static func parseFixedPoint(_ text: String, denominator: Int) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var number = ""
        for character in trimmed {
            guard character.isASCII, character.isNumber || character == "." || (number.isEmpty && character == "-") else { break }
            number.append(character)
        }
        guard let value = Double(number) else { return 0 }
        return Int((value * Double(denominator)).rounded(.towardZero))
    }

    /// C `atoi`: optional whitespace and sign, then leading digits;
    /// 0 if there are none.
    public static func atoi(_ text: String) -> Int {
        var scalars = Substring(text).drop { $0 == " " || $0 == "\t" || $0 == "\n" }
        var sign = 1
        if let first = scalars.first, first == "-" || first == "+" {
            if first == "-" { sign = -1 }
            scalars = scalars.dropFirst()
        }
        var value = 0
        for character in scalars {
            guard let digit = character.wholeNumberValue, character.isASCII else { break }
            let (product, overflow1) = value.multipliedReportingOverflow(by: 10)
            let (sum, overflow2) = product.addingReportingOverflow(digit)
            if overflow1 || overflow2 || sum > Int(Int32.max) { return sign * Int(Int32.max) }
            value = sum
        }
        return sign * value
    }
}
