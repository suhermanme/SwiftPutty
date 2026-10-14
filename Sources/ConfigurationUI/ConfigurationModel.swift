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
public final class ConfigurationModel {
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

    @ObservationIgnored public var beep: () -> Void
    @ObservationIgnored private let store: SavedSessionStore

    /// Starts from "Default Settings", as PuTTY's `do_defaults`.
    public init(store: SavedSessionStore, beep: @escaping () -> Void = {}) {
        self.store = store
        self.beep = beep
        do {
            settings = try store.loadDefaults()
        } catch {
            settings = PuTTYSettings.defaults()
            errorMessage = error.localizedDescription
        }
        refreshSessionNames()
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
        loadSelected(into: &settings) != nil
    }

    /// A double-click in the list: loads the session, and returns the
    /// settings to open if PuTTY would start it at once (a saved
    /// session, not "Default Settings", with a destination).
    public func openSessionFromList() -> PuTTYSettings? {
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
