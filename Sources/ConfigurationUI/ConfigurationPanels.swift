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

    /// PuTTY's connection types on Unix, in be_list.c's order: SSH and
    /// Serial as radio buttons, then "Other:" with a list.
    private static let otherTypes = [(label: "Telnet", value: "telnet"), (label: "Rlogin", value: "rlogin"),
                                     (label: "SUPDUP", value: "supdup"), (label: "Raw", value: "raw")]

    private var isSerial: Bool { model.connectionType == "serial" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !model.isMidSession {
                SettingsGroup(title: "Specify the destination you want to connect to") {
                    HStack(alignment: .bottom) {
                        // config_host_handler / config_port_handler: for
                        // Serial the boxes are the line and its speed.
                        VStack(alignment: .leading, spacing: 4) {
                            if isSerial {
                                Text("Serial line")
                                SerialLineField(label: "Serial line",
                                                line: Binding(get: { model.string(.serialLine) },
                                                              set: { model.setString(.serialLine, $0) }))
                                    .focused($focus, equals: .host)
                            } else {
                                Text("Host Name (or IP address)")
                                PlainTextField(label: "Host Name (or IP address)",
                                               text: Binding(get: { model.string(.hostName) },
                                                             set: { model.setString(.hostName, $0) }))
                                    .focused($focus, equals: .host)
                            }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(isSerial ? "Speed" : "Port")
                            Group {
                                if isSerial {
                                    IntegerField(label: "Speed",
                                                 value: Binding(get: { model.int(.serialSpeed) },
                                                                set: { model.setInt(.serialSpeed, $0) }))
                                } else {
                                    IntegerField(label: "Port", value: $model.port, blankWhenZero: true)
                                }
                            }
                            .id(isSerial)          // each box keeps its own text
                            .focused($focus, equals: .port)
                            .frame(width: 80)
                        }
                    }
                    Text("Connection type:")
                    HStack {
                        Picker("Connection type", selection: Binding(
                            get: { ["ssh", "serial"].contains(model.connectionType) ? model.connectionType : "other" },
                            set: { model.connectionType = $0 == "other" ? otherType : $0 })) {
                            Text("SSH").tag("ssh")
                            Text("Serial").tag("serial")
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

            }

            SettingsGroup(title: model.isMidSession ? "Save the current session settings"
                                                    : "Load, save or delete a stored session") {
                Text("Saved Sessions")
                PlainTextField(label: "Saved Sessions",
                               text: Binding(get: { model.savedSessionName },
                                             set: { model.setSavedSessionName($0) }))
                    .focused($focus, equals: .savedName)
                HStack(alignment: .top) {
                    sessionList
                    VStack(spacing: 8) {
                        // Mid-session only Save (config.c): loading could
                        // change settings the dialog does not show.
                        if !model.isMidSession {
                            Button("Load") { model.loadSelectedSession() }
                        }
                        Button("Save") { model.save() }
                        if !model.isMidSession {
                            Button("Delete") { model.deleteSelectedSession() }
                        }
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
                                       ("All session output", "2")]
                                 + (model.showsSSHLogging
                                    ? [("SSH packets", "3"), ("SSH packets and raw data", "4")] : []),
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
            if model.showsSSHLogging {
                SettingsGroup(title: "Options specific to SSH packet logging") {
                    CheckboxSetting(model: model, label: "Omit known password fields",
                                    keyword: .sshLogOmitPasswords)
                    CheckboxSetting(model: model, label: "Omit session data", keyword: .sshLogOmitData)
                }
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
            SettingsGroup(title: "Remote-controlled printing") {
                Text("Printer to send ANSI printer output to:")
                PrinterField(text: Binding(get: { model.string(.printer) },
                                           set: { model.setString(.printer, $0) }))
            }
        }
    }
}

/// As unix/printing.c: the printer is a command that print jobs are piped
/// to (empty: printing disabled). The menu offers PuTTY's "None" and an
/// `lpr` command for each printer macOS knows.
struct PrinterField: View {
    @Binding var text: String
    static let disabled = "None (printing disabled)"

    var body: some View {
        HStack(spacing: 4) {
            TextField(Self.disabled, text: $text)
                .labelsHidden()
                .accessibilityLabel("Printer to send ANSI printer output to")
            Menu {
                Button(Self.disabled) { text = "" }
                Divider()
                ForEach(NSPrinter.printerNames, id: \.self) { name in
                    Button(name) { text = Self.lprCommand(for: name) }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Printers")
        }
    }

    /// The command that prints to a macOS (CUPS) printer.
    static func lprCommand(for printer: String) -> String {
        "lpr -P '" + printer.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
                // Windows PuTTY's option; "maximised" is zoomed or full
                // screen.
                RadioSetting(model: model, label: "When window is resized:", keyword: .lockSize,
                             options: [("Change the number of rows and columns", "0"),
                                       ("Change the size of the font", "2"),
                                       ("Change font size only when maximised", "3"),
                                       ("Forbid resizing completely", "1")],
                             horizontal: false)
            }
            SettingsGroup(title: "Control the scrollback in the window") {
                NumberSetting(model: model, label: "Lines of scrollback", keyword: .scrollbackLines)
                CheckboxSetting(model: model, label: "Display scrollbar", keyword: .scrollBar)
                CheckboxSetting(model: model, label: "Scrollbar on left", keyword: .scrollbarOnLeft)
                CheckboxSetting(model: model, label: "Display scrollbar in full screen mode",
                                keyword: .scrollBarFullScreen)
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
                    Button("Change…") { model.choosingFont = .fontName }
                        .popover(isPresented: model.choosingFontBinding(.fontName), arrowEdge: .trailing) {
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

// MARK: - Window/Fonts (GTK PuTTY, unix/config-gtk.c)

struct FontsPanel: View {
    let model: ConfigurationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(title: "Fonts for displaying non-bold text") {
                FontRow(model: model, label: "Font used for ordinary text", keyword: .fontName,
                        optional: false)
                FontRow(model: model, label: "Font used for wide (CJK) text", keyword: .wideFontName,
                        optional: true)
            }
            SettingsGroup(title: "Fonts for displaying bolded text") {
                FontRow(model: model, label: "Font used for bolded text", keyword: .boldFontName,
                        optional: true)
                FontRow(model: model, label: "Font used for bold wide text", keyword: .wideBoldFontName,
                        optional: true)
                CheckboxSetting(model: model, label: "Use shadow bold instead of bold fonts",
                                keyword: .shadowBold)
                Text("(Note that bold fonts or shadow bolding are only used if you have not requested bolding to be done by changing the text colour.)")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                NumberSetting(model: model, label: "Horizontal offset for shadow bold:",
                              keyword: .shadowBoldOffset)
            }
        }
    }
}

/// A font setting: its description, Change…, and (for fonts that are
/// derived when not set) Clear.
private struct FontRow: View {
    let model: ConfigurationModel
    let label: String
    let keyword: PuTTYKeyword
    let optional: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
            HStack {
                let name = model.string(keyword)
                Text(optional && name.isEmpty ? "Not set (derived from the ordinary font)"
                                              : FontSetting.describe(name))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Change…") { model.choosingFont = keyword }
                    .popover(isPresented: model.choosingFontBinding(keyword), arrowEdge: .trailing) {
                        FontChooser(fontName: Binding(
                            get: { name.isEmpty ? model.string(.fontName) : name },
                            set: { model.setString(keyword, $0) }))
                    }
                if optional {
                    Button("Clear") { model.setString(keyword, "") }
                        .disabled(name.isEmpty)
                }
            }
        }
    }
}

extension ConfigurationModel {
    /// Whether the chooser for `keyword` is open, for `.popover`.
    func choosingFontBinding(_ keyword: PuTTYKeyword) -> Binding<Bool> {
        Binding(get: { self.choosingFont == keyword },
                set: { isOpen in
                    if isOpen {
                        self.choosingFont = keyword
                    } else if self.choosingFont == keyword {
                        self.choosingFont = nil
                    }
                })
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
    static let fixedPitchFonts = entries(NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? [])

    /// Every font, by display name.
    @MainActor
    static let allFonts = entries(NSFontManager.shared.availableFonts)

    private static func entries(_ names: [String]) -> [(name: String, postScriptName: String)] {
        names.compactMap { name in
            NSFont(name: name, size: 12).map { (name: $0.displayName ?? name, postScriptName: name) }
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct FontChooser: View {
    @Binding var fontName: String
    /// Windows PuTTY's "Allow selection of variable-pitch fonts" (GTK's
    /// font selector has the same switch); not saved, as there.
    @State private var variablePitch = false

    var body: some View {
        let font = TerminalFont(puttyFontName: fontName).font
        let fonts = variablePitch ? FontSetting.allFonts : FontSetting.fixedPitchFonts
        Form {
            Picker("Font", selection: Binding(get: { font.fontName },
                                              set: { fontName = "\($0) \(FontSetting.formatSize(font.pointSize))" })) {
                ForEach(fonts, id: \.postScriptName) { entry in
                    Text(entry.name).tag(entry.postScriptName)
                }
                // The current font, even if the list does not have it.
                if !fonts.contains(where: { $0.postScriptName == font.fontName }) {
                    Text(font.displayName ?? font.fontName).tag(font.fontName)
                }
            }
            Toggle("Allow selection of variable-pitch fonts", isOn: $variablePitch)
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
                CheckboxSetting(model: model, label: "Warn before closing window", keyword: .warnOnClose)
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
            // Only the keepalive interval can change on a live connection.
            if !model.isMidSession {
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
                // Runs through upstream's proxy/newmain.c with the M13
                // hardening (patches 0014, 0015; D-041).
                SettingsGroup(title: "Command to run at connection event") {
                    TextSetting(model: model, label: "Command to run before connection",
                                keyword: .preConnectCommand)
                }
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
            EnvironmentSettings(model: model)
        }
    }
}

/// config.c's "Environment variables" box: Variable / Value, Add, the
/// list and Remove.
private struct EnvironmentSettings: View {
    @Bindable var model: ConfigurationModel
    @State private var selection: Int?

    var body: some View {
        SettingsGroup(title: "Environment variables") {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Variable")
                    PlainTextField(label: "Variable", text: $model.environmentName)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Value")
                    PlainTextField(label: "Value", text: $model.environmentValue)
                }
                Button("Add") { model.addEnvironmentVariable() }
                    .buttonStyle(.bordered)
            }
            HStack(alignment: .top) {
                List(selection: $selection) {
                    ForEach(Array(model.environmentVariables.enumerated()), id: \.offset) { index, variable in
                        HStack {
                            Text(variable.name).frame(width: 140, alignment: .leading)
                            Text(variable.value)
                        }
                        .tag(index)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: false))
                .frame(height: 3 * 24)
                Button("Remove") {
                    model.removeEnvironmentVariable(at: selection)
                    selection = nil
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
