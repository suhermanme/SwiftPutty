import AppKit
import PuTTYBridge
import SwiftUI

/// The categories of PuTTY's configuration tree that SwiftPutty has so
/// far (`config.c` `setup_config_box`). Order and nesting are PuTTY's.
public enum ConfigurationCategory: String, CaseIterable, Identifiable, Sendable {
    case session, logging
    case terminal, keyboard, bell, features
    case window, appearance, behaviour, translation, selection, copy, colours, fonts
    case connection, data, proxy, ssh, kex, hostKeys, cipher, auth, credentials, gssapi, tty, x11, tunnels
    case bugs, moreBugs
    case serial, telnet, rlogin, supdup

    public var id: Self { self }

    /// The name in the tree.
    public var name: String {
        switch self {
        case .session: "Session"
        case .logging: "Logging"
        case .terminal: "Terminal"
        case .keyboard: "Keyboard"
        case .bell: "Bell"
        case .features: "Features"
        case .window: "Window"
        case .appearance: "Appearance"
        case .behaviour: "Behaviour"
        case .translation: "Translation"
        case .selection: "Selection"
        case .copy: "Copy"
        case .colours: "Colours"
        case .fonts: "Fonts"
        case .connection: "Connection"
        case .data: "Data"
        case .proxy: "Proxy"
        case .ssh: "SSH"
        case .kex: "Kex"
        case .hostKeys: "Host keys"
        case .cipher: "Cipher"
        case .auth: "Auth"
        case .credentials: "Credentials"
        case .gssapi: "GSSAPI"
        case .tty: "TTY"
        case .x11: "X11"
        case .tunnels: "Tunnels"
        case .bugs: "Bugs"
        case .moreBugs: "More bugs"
        case .serial: "Serial"
        case .telnet: "Telnet"
        case .rlogin: "Rlogin"
        case .supdup: "SUPDUP"
        }
    }

    /// Nesting depth in the tree.
    public var depth: Int {
        switch self {
        case .copy, .kex, .hostKeys, .cipher, .auth, .tty, .x11, .tunnels, .bugs, .moreBugs: 2
        case .credentials, .gssapi: 3
        case .session, .terminal, .window, .connection: 0
        default: 1
        }
    }

    /// The panel's title (`ctrl_settitle`).
    public var title: String {
        switch self {
        case .session: "Basic options for your SwiftPutty session"
        case .logging: "Options controlling session logging"
        case .terminal: "Options controlling the terminal emulation"
        case .keyboard: "Options controlling the effects of keys"
        case .bell: "Options controlling the terminal bell"
        case .features: "Enabling and disabling advanced terminal features"
        case .window: "Options controlling SwiftPutty's window"
        case .appearance: "Configure the appearance of SwiftPutty's window"
        case .behaviour: "Configure the behaviour of SwiftPutty's window"
        case .translation: "Options controlling character set translation"
        case .selection: "Options controlling copy and paste"
        case .copy: "Options controlling copying from terminal to clipboard"
        case .colours: "Options controlling use of colours"
        case .fonts: "Options controlling font usage"
        case .connection: "Options controlling the connection"
        case .data: "Data to send to the server"
        case .proxy: "Options controlling proxy usage"
        case .ssh: "Options controlling SSH connections"
        case .tunnels: "Options controlling SSH port forwarding"
        case .kex: "Options controlling SSH key exchange"
        case .hostKeys: "Options controlling SSH host keys"
        case .cipher: "Options controlling SSH encryption"
        case .auth: "Options controlling SSH authentication"
        case .credentials: "Credentials to authenticate with"
        case .gssapi: "Options controlling GSSAPI authentication"
        case .tty: "Remote terminal settings"
        case .x11: "Options controlling SSH X11 forwarding"
        case .bugs: "Workarounds for SSH server bugs"
        case .moreBugs: "Further workarounds for SSH server bugs"
        case .serial: "Options controlling local serial lines"
        case .telnet: "Options controlling Telnet connections"
        case .rlogin: "Options controlling Rlogin connections"
        case .supdup: "Options controlling SUPDUP connections"
        }
    }
}

/// PuTTY's configuration dialog, before a session starts: the category
/// tree, the selected panel, and About / Open / Cancel.
public struct ConfigurationView: View {
    @Bindable var model: ConfigurationModel
    let onOpen: (PuTTYSettings) -> Void
    let onCancel: () -> Void
    let onAbout: () -> Void
    @State private var category: ConfigurationCategory

    public init(model: ConfigurationModel,
                initialCategory: ConfigurationCategory = .session,
                onOpen: @escaping (PuTTYSettings) -> Void,
                onCancel: @escaping () -> Void,
                onAbout: @escaping () -> Void) {
        self.model = model
        _category = State(initialValue: initialCategory)
        self.onOpen = onOpen
        self.onCancel = onCancel
        self.onAbout = onAbout
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                categoryTree
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text(category.title)
                        .font(.headline)
                    Divider()
                    ScrollView {
                        panel
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.trailing, 4)
                    }
                }
                .padding(16)
            }
            Divider()
            HStack {
                if !model.isMidSession {
                    Button("About", action: onAbout)
                }
                Spacer()
                Button(model.isMidSession ? "Apply" : "Open") {
                    if let settings = model.open() {
                        onOpen(settings)
                    }
                }
                .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(model.choosingFont == nil ? .cancelAction : nil)
                if model.choosingFont != nil {
                    Button("") { model.choosingFont = nil }
                        .keyboardShortcut(.cancelAction)
                        .hidden()
                }
            }
            .padding(12)
        }
        .frame(width: 680, height: 640)
        .alert("SwiftPutty Error", isPresented: Binding(get: { model.errorMessage != nil },
                                                        set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var categoryTree: some View {
        List(selection: $category) {
            Text("Category:")
                .font(.caption)
                .foregroundStyle(.secondary)
                .selectionDisabled()
            ForEach(ConfigurationCategory.allCases.filter(model.shows)) { category in
                Text(category.name)
                    .padding(.leading, CGFloat(category.depth) * 16)
                    .tag(category)
            }
        }
        .listStyle(.sidebar)
        .frame(width: 170)
    }

    @ViewBuilder
    private var panel: some View {
        switch category {
        case .session: SessionPanel(model: model, onOpen: onOpen)
        case .logging: LoggingPanel(model: model)
        case .terminal: TerminalPanel(model: model)
        case .keyboard: KeyboardPanel(model: model)
        case .bell: BellPanel(model: model)
        case .features: FeaturesPanel(model: model)
        case .window: WindowPanel(model: model)
        case .appearance: AppearancePanel(model: model)
        case .behaviour: BehaviourPanel(model: model)
        case .translation: TranslationPanel(model: model)
        case .selection: SelectionPanel(model: model)
        case .copy: CopyPanel(model: model)
        case .colours: ColoursPanel(model: model)
        case .fonts: FontsPanel(model: model)
        case .connection: ConnectionPanel(model: model)
        case .data: DataPanel(model: model)
        case .proxy: ProxyPanel(model: model)
        case .ssh: SSHPanel(model: model)
        case .tunnels: TunnelsPanel(model: model)
        case .kex: KexPanel(model: model)
        case .hostKeys: HostKeysPanel(model: model)
        case .cipher: CipherPanel(model: model)
        case .auth: AuthPanel(model: model)
        case .credentials: CredentialsPanel(model: model)
        case .gssapi: GSSAPIPanel(model: model)
        case .tty: TTYPanel(model: model)
        case .x11: X11Panel(model: model)
        case .bugs: BugsPanel(model: model)
        case .moreBugs: MoreBugsPanel(model: model)
        case .serial: SerialPanel(model: model)
        case .telnet: TelnetPanel(model: model)
        case .rlogin: RloginPanel(model: model)
        case .supdup: SUPDUPPanel(model: model)
        }
    }
}


extension ConfigurationModel {
    /// Which panels the tree lists: all before a session; mid-session,
    /// config.c's rules.
    public func shows(_ category: ConfigurationCategory) -> Bool {
        guard isMidSession else { return true }
        switch category {
        // Connection/Data and Connection/Proxy only matter to a new
        // connection.
        case .data, .proxy: return false
        // DISPLAY_RECONFIGURABLE_PROTOCOL: SSH panels for SSH sessions.
        case .ssh, .tunnels: return connectionType == "ssh"
        // Re-keying makes these meaningful mid-session, except on SSH-1
        // or a connection-sharing downstream.
        case .kex, .hostKeys, .cipher:
            return connectionType == "ssh" && protocolInfo != 1 && protocolInfo != -1
        // Only a new connection uses these.
        case .auth, .credentials, .gssapi, .tty, .x11, .bugs, .moreBugs: return false
        // DISPLAY_RECONFIGURABLE_PROTOCOL / DISPLAY_NON_RECONFIGURABLE_PROTOCOL
        case .serial: return connectionType == "serial"
        case .telnet: return connectionType == "telnet"
        case .rlogin, .supdup: return false
        default: return true
        }
    }
}

// MARK: - Controls bound to PuTTY keywords

/// A titled group of controls (PuTTY's `controlset`).
struct SettingsGroup<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            if let title {
                Text(title)
            }
        }
    }
}

struct CheckboxSetting: View {
    let model: ConfigurationModel
    let label: String
    let keyword: PuTTYKeyword

    var body: some View {
        Toggle(label, isOn: Binding(get: { model.bool(keyword) },
                                    set: { model.setBool(keyword, $0) }))
    }
}

/// Radio buttons storing PuTTY's saved values.
struct RadioSetting: View {
    let model: ConfigurationModel
    let label: String
    let keyword: PuTTYKeyword
    let options: [(label: String, value: String)]
    var horizontal = true

    /// As PuTTY lays out a radio group: the label, then the buttons.
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !label.isEmpty {
                Text(label)
            }
            Picker(label, selection: Binding(get: { model.string(keyword) },
                                             set: { model.setString(keyword, $0) })) {
                ForEach(options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout(horizontal)
            .labelsHidden()
            .padding(.leading, label.isEmpty ? 0 : 12)
        }
    }
}

/// A drop-down list storing PuTTY's saved values.
struct PopupSetting: View {
    let model: ConfigurationModel
    let label: String
    let keyword: PuTTYKeyword
    let options: [(label: String, value: String)]

    var body: some View {
        Picker(label, selection: Binding(get: { model.string(keyword) },
                                         set: { model.setString(keyword, $0) })) {
            ForEach(options, id: \.value) { option in
                Text(option.label).tag(option.value)
            }
        }
        .fixedSize()
    }
}

/// An edit box with its label above it, as PuTTY lays out a
/// full-width edit box.
struct TextSetting: View {
    let model: ConfigurationModel
    let label: String
    let keyword: PuTTYKeyword

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
            PlainTextField(label: label, text: Binding(get: { model.string(keyword) },
                                                       set: { model.setString(keyword, $0) }))
        }
    }
}

/// A text field without placeholder text (PuTTY's edit boxes have none);
/// the label is for accessibility.
struct PlainTextField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        TextField("", text: $text)
            .labelsHidden()
            .accessibilityLabel(label)
    }
}

/// An integer edit box; PuTTY reads it with `atoi`.
struct NumberSetting: View {
    let model: ConfigurationModel
    let label: String
    let keyword: PuTTYKeyword

    var body: some View {
        LabeledContent(label) {
            IntegerField(label: label,
                         value: Binding(get: { model.int(keyword) },
                                        set: { model.setInt(keyword, $0) }))
                .frame(width: 80)
        }
    }
}

/// An edit box holding a number. The text is the user's while they type
/// (it may be blank or partial); the value is its `atoi`. The text
/// follows the value only when the value changes from elsewhere (e.g. a
/// session is loaded).
struct IntegerField: View {
    let label: String
    @Binding var value: Int
    /// PuTTY shows a port of 0 as blank.
    var blankWhenZero = false
    @State private var text = ""

    var body: some View {
        TextField("", text: $text)
            .labelsHidden()
            .accessibilityLabel(label)
            .onAppear { text = format(value) }
            .onChange(of: text) { _, newText in
                let parsed = ConfigurationModel.atoi(newText)
                if parsed != value { value = parsed }
            }
            .onChange(of: value) { _, newValue in
                if ConfigurationModel.atoi(text) != newValue { text = format(newValue) }
            }
    }

    private func format(_ value: Int) -> String {
        blankWhenZero && value == 0 ? "" : String(value)
    }
}

extension View {
    @ViewBuilder
    func horizontalRadioGroupLayout(_ horizontal: Bool) -> some View {
        if horizontal {
            self.horizontalRadioGroupLayout()
        } else {
            self
        }
    }
}
