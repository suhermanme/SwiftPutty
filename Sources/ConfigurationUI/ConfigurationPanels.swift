import AppKit
import PuTTYBridge
import SwiftUI
import TerminalUI

// The panels follow config.c `setup_config_box` (non-mid-session), with
// PuTTY's wording, order and saved values. Controls whose behaviour
// SwiftPutty does not have yet are left out, not shown disabled
// (docs/CONFIGURATION_PARITY.md).

// MARK: - Session

struct SessionPanel: View {
    @Bindable var model: ConfigurationModel
    let onOpen: (PuTTYSettings) -> Void

    private enum Field: Hashable { case host, port, savedName, sessionList }
    @FocusState private var focus: Field?

    /// The connection types SwiftPutty can start so far: PuTTY's radio
    /// buttons are SSH and Serial, then "Other:" with a list (Telnet,
    /// Rlogin, SUPDUP, Raw); the others arrive with M11.
    private static let otherTypes = [(label: "Raw", value: "raw")]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(title: "Specify the destination you want to connect to") {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Host Name (or IP address)")
                        PlainTextField(label: "Host Name (or IP address)",
                                       text: Binding(get: { model.string(.hostName) },
                                                     set: { model.setString(.hostName, $0) }))
                            .focused($focus, equals: .host)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Port")
                        IntegerField(label: "Port", value: $model.port, blankWhenZero: true)
                            .focused($focus, equals: .port)
                            .frame(width: 80)
                    }
                }
                Text("Connection type:")
                HStack {
                    Picker("Connection type", selection: Binding(
                        get: { model.connectionType == "ssh" ? "ssh" : "other" },
                        set: { model.connectionType = $0 == "ssh" ? "ssh" : otherType })) {
                        Text("SSH").tag("ssh")
                        Text("Other:").tag("other")
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    .labelsHidden()
                    Picker("Other connection type", selection: Binding(
                        get: { otherType },
                        set: { model.connectionType = $0 })) {
                        ForEach(Self.otherTypes, id: \.value) { type in
                            Text(type.label).tag(type.value)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            SettingsGroup(title: "Load, save or delete a stored session") {
                Text("Saved Sessions")
                PlainTextField(label: "Saved Sessions",
                               text: Binding(get: { model.savedSessionName },
                                             set: { model.setSavedSessionName($0) }))
                    .focused($focus, equals: .savedName)
                HStack(alignment: .top) {
                    sessionList
                    VStack(spacing: 8) {
                        Button("Load") { model.loadSelectedSession() }
                        Button("Save") { model.save() }
                        Button("Delete") { model.deleteSelectedSession() }
                    }
                    .frame(width: 80)
                    .buttonStyle(.bordered)
                }
            }

            RadioSetting(model: model, label: "Close window on exit:", keyword: .closeOnExit,
                         options: [("Always", "2"), ("Never", "0"), ("Only on clean exit", "1")])
        }
        .onChange(of: focus) { _, field in
            // PuTTY's dlg_last_focused: buttons do not take the focus.
            if let field {
                model.sessionListWasLastFocused = field == .sessionList
            }
        }
    }

    /// The protocol shown in the "Other:" list: the current one if it is
    /// a list protocol, else the first ("runner-up"), as PuTTY.
    private var otherType: String {
        let current = model.connectionType
        return Self.otherTypes.contains { $0.value == current } ? current : Self.otherTypes[0].value
    }

    private var sessionList: some View {
        List(selection: $model.selectedSessionIndex) {
            ForEach(Array(model.sessionNames.enumerated()), id: \.offset) { index, name in
                Text(name).tag(index)
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: false))
        .focused($focus, equals: .sessionList)
        .contextMenu(forSelectionType: Int.self) { _ in
        } primaryAction: { _ in
            // Double-click: load, and start it if it is a saved session
            // with a destination.
            if let settings = model.openSessionFromList() {
                onOpen(settings)
            }
        }
        .frame(height: 7 * 22)
    }
}

// MARK: - Session/Logging

struct LoggingPanel: View {
    let model: ConfigurationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(title: nil) {
                RadioSetting(model: model, label: "Session logging:", keyword: .logType,
                             options: [("None", "0"), ("Printable output", "1"),
                                       ("All session output", "2"), ("SSH packets", "3"),
                                       ("SSH packets and raw data", "4")],
                             horizontal: false)
                LabeledContent("Log file name:") {
                    HStack {
                        PlainTextField(label: "Log file name",
                                       text: Binding(get: { model.string(.logFileName) },
                                                     set: { model.setString(.logFileName, $0) }))
                        Button("Browse…") { chooseLogFile() }
                    }
                }
                Text("(Log file name can contain &Y, &M, &D for date, &T for time, &H for host name, and &P for port number)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                RadioSetting(model: model, label: "What to do if the log file already exists:",
                             keyword: .logFileClash,
                             options: [("Always overwrite it", "1"),
                                       ("Always append to the end of it", "0"),
                                       ("Ask the user every time", "-1")],
                             horizontal: false)
                CheckboxSetting(model: model, label: "Flush log file frequently", keyword: .logFlush)
                CheckboxSetting(model: model, label: "Include header", keyword: .logHeader)
            }
            SettingsGroup(title: "Options specific to SSH packet logging") {
                CheckboxSetting(model: model, label: "Omit known password fields",
                                keyword: .sshLogOmitPasswords)
                CheckboxSetting(model: model, label: "Omit session data", keyword: .sshLogOmitData)
            }
        }
    }

    /// PuTTY's file selector ("Select session log file name").
    private func chooseLogFile() {
        let panel = NSSavePanel()
        panel.title = "Select session log file name"
        panel.canCreateDirectories = true
        let current = model.string(.logFileName)
        if !current.isEmpty {
            let url = URL(fileURLWithPath: current)
            panel.directoryURL = url.deletingLastPathComponent()
            panel.nameFieldStringValue = url.lastPathComponent
        }
        if panel.runModal() == .OK, let url = panel.url {
            model.setString(.logFileName, url.path)
        }
    }
}

// MARK: - Terminal

struct TerminalPanel: View {
    let model: ConfigurationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(title: "Set various terminal options") {
                CheckboxSetting(model: model, label: "Auto wrap mode initially on", keyword: .autoWrapMode)
                CheckboxSetting(model: model, label: "DEC Origin Mode initially on", keyword: .decOriginMode)
                CheckboxSetting(model: model, label: "Implicit CR in every LF", keyword: .lfImpliesCR)
                CheckboxSetting(model: model, label: "Implicit LF in every CR", keyword: .crImpliesLF)
                CheckboxSetting(model: model, label: "Use background colour to erase screen", keyword: .bce)
                CheckboxSetting(model: model, label: "Enable blinking text", keyword: .blinkText)
                TextSetting(model: model, label: "Answerback to ^E:", keyword: .answerback)
            }
            SettingsGroup(title: "Line discipline options") {
                RadioSetting(model: model, label: "Local echo:", keyword: .localEcho,
                             options: [("Auto", "2"), ("Force on", "0"), ("Force off", "1")])
                RadioSetting(model: model, label: "Local line editing:", keyword: .localEdit,
                             options: [("Auto", "2"), ("Force on", "0"), ("Force off", "1")])
            }
        }
    }
}

// MARK: - Window

struct WindowPanel: View {
    let model: ConfigurationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(title: "Set the size of the window") {
                HStack(spacing: 24) {
                    NumberSetting(model: model, label: "Columns", keyword: .termWidth)
                    NumberSetting(model: model, label: "Rows", keyword: .termHeight)
                }
            }
            SettingsGroup(title: "Control the scrollback in the window") {
                NumberSetting(model: model, label: "Lines of scrollback", keyword: .scrollbackLines)
                CheckboxSetting(model: model, label: "Display scrollbar", keyword: .scrollBar)
                CheckboxSetting(model: model, label: "Scrollbar on left", keyword: .scrollbarOnLeft)
                CheckboxSetting(model: model, label: "Reset scrollback on keypress", keyword: .scrollOnKey)
                CheckboxSetting(model: model, label: "Reset scrollback on display activity",
                                keyword: .scrollOnDisp)
                CheckboxSetting(model: model, label: "Push erased text into scrollback",
                                keyword: .eraseToScrollback)
            }
        }
    }
}

// MARK: - Window/Appearance

struct AppearancePanel: View {
    let model: ConfigurationModel
    @State private var choosingFont = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(title: "Adjust the use of the cursor") {
                RadioSetting(model: model, label: "Cursor appearance:", keyword: .curType,
                             options: [("Block", "0"), ("Underline", "1"), ("Vertical line", "2")])
                CheckboxSetting(model: model, label: "Cursor blinks", keyword: .blinkCur)
            }
            SettingsGroup(title: "Font settings") {
                Text("Font used in the terminal window")
                HStack {
                    Text(FontSetting.describe(model.string(.fontName)))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Change…") { choosingFont = true }
                        .popover(isPresented: $choosingFont, arrowEdge: .trailing) {
                            FontChooser(fontName: Binding(get: { model.string(.fontName) },
                                                          set: { model.setString(.fontName, $0) }))
                        }
                }
            }
            SettingsGroup(title: "Adjust the use of the mouse pointer") {
                CheckboxSetting(model: model, label: "Hide mouse pointer when typing in window",
                                keyword: .hideMousePtr)
            }
            SettingsGroup(title: "Adjust the window border") {
                NumberSetting(model: model, label: "Gap between text and window edge:",
                              keyword: .windowBorder)
            }
        }
    }
}

/// PuTTY's `FontName` as SwiftPutty writes it: "<PostScript name>
/// <points>" (D-016).
enum FontSetting {
    static func describe(_ fontName: String) -> String {
        let font = TerminalFont(puttyFontName: fontName).font
        return "\(font.displayName ?? font.fontName), \(formatSize(font.pointSize))-point"
    }

    static func formatSize(_ size: CGFloat) -> String {
        size == size.rounded() ? String(Int(size)) : String(format: "%.1f", Double(size))
    }

    /// Fixed-pitch fonts, by display name.
    @MainActor
    static let fixedPitchFonts: [(name: String, postScriptName: String)] = {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        return names.compactMap { name in
            NSFont(name: name, size: 12).map { (name: $0.displayName ?? name, postScriptName: name) }
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()
}

struct FontChooser: View {
    @Binding var fontName: String

    var body: some View {
        let font = TerminalFont(puttyFontName: fontName).font
        Form {
            Picker("Font", selection: Binding(get: { font.fontName },
                                              set: { fontName = "\($0) \(FontSetting.formatSize(font.pointSize))" })) {
                ForEach(FontSetting.fixedPitchFonts, id: \.postScriptName) { entry in
                    Text(entry.name).tag(entry.postScriptName)
                }
            }
            Stepper(value: Binding(get: { Double(font.pointSize) },
                                   set: { fontName = "\(font.fontName) \(FontSetting.formatSize(CGFloat($0)))" }),
                    in: 4...72, step: 1) {
                Text("Size: \(FontSetting.formatSize(font.pointSize)) points")
            }
            Text("The quick brown fox jumps over the lazy dog")
                .font(Font(font))
                .lineLimit(1)
        }
        .padding()
        .frame(width: 360)
    }
}

// MARK: - Window/Behaviour

struct BehaviourPanel: View {
    let model: ConfigurationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(title: "Adjust the behaviour of the window title") {
                TextSetting(model: model, label: "Window title:", keyword: .winTitle)
                // CHECKBOX_INVERT: ticked means WinNameAlways off.
                Toggle("Separate window and icon titles",
                       isOn: Binding(get: { !model.bool(.winNameAlways) },
                                     set: { model.setBool(.winNameAlways, !$0) }))
            }
            SettingsGroup(title: nil) {
                CheckboxSetting(model: model, label: "Ensure window is always on top", keyword: .alwaysOnTop)
                CheckboxSetting(model: model, label: "Full screen on Option-Return",
                                keyword: .fullScreenOnAltEnter)
            }
        }
    }
}

// MARK: - Connection

struct ConnectionPanel: View {
    @Bindable var model: ConfigurationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(title: "Sending of null packets to keep session active") {
                LabeledContent("Seconds between keepalives (0 to turn off)") {
                    IntegerField(label: "Seconds between keepalives", value: $model.keepaliveSeconds)
                        .frame(width: 80)
                }
            }
            SettingsGroup(title: "Low-level TCP connection options") {
                CheckboxSetting(model: model, label: "Disable Nagle's algorithm (TCP_NODELAY option)",
                                keyword: .tcpNoDelay)
                CheckboxSetting(model: model, label: "Enable TCP keepalives (SO_KEEPALIVE option)",
                                keyword: .tcpKeepalives)
            }
            SettingsGroup(title: "Internet protocol version") {
                RadioSetting(model: model, label: "", keyword: .addressFamily,
                             options: [("Auto", "0"), ("IPv4", "1"), ("IPv6", "2")])
            }
            SettingsGroup(title: "Logical name of remote host") {
                TextSetting(model: model, label: "Logical name of remote host (e.g. for SSH key lookup):",
                            keyword: .logHost)
            }
        }
    }
}

// MARK: - Connection/Data

struct DataPanel: View {
    let model: ConfigurationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(title: "Login details") {
                TextSetting(model: model, label: "Auto-login username", keyword: .userName)
                RadioSetting(model: model, label: "When username is not specified:",
                             keyword: .userNameFromEnvironment,
                             options: [("Prompt", "0"), ("Use system username (\(NSUserName()))", "1")])
            }
            SettingsGroup(title: "Terminal details") {
                TextSetting(model: model, label: "Terminal-type string", keyword: .terminalType)
                TextSetting(model: model, label: "Terminal speeds", keyword: .terminalSpeed)
            }
        }
    }
}
