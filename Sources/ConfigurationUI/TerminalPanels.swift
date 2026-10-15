import AppKit
import PuTTYBridge
import SwiftUI

// Terminal/Keyboard, Terminal/Bell and Terminal/Features (M06), as
// config.c and, for the bell's sound file and Dock indication,
// windows/config.c; the Meta keys as unix/config-gtk.c on OS X.

// MARK: - Terminal/Keyboard

struct KeyboardPanel: View {
    @Bindable var model: ConfigurationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(title: "Change the sequences sent by:") {
                RadioSetting(model: model, label: "The Backspace key", keyword: .backspaceIsDelete,
                             options: [("Control-H", "0"), ("Control-? (127)", "1")])
                RadioSetting(model: model, label: "The Home and End keys", keyword: .rxvtHomeEnd,
                             options: [("Standard", "0"), ("rxvt", "1")])
                RadioSetting(model: model, label: "The Function keys and keypad",
                             keyword: .linuxFunctionKeys,
                             options: [("ESC[n~", "0"), ("Linux", "1"), ("Xterm R6", "2"),
                                       ("VT400", "3"), ("VT100+", "4"), ("SCO", "5"),
                                       ("Xterm 216+", "6")],
                             horizontal: false)
                RadioSetting(model: model, label: "Shift/Ctrl/Alt with the arrow keys",
                             keyword: .shiftedArrowKeys,
                             options: [("Ctrl toggles app mode", "0"), ("xterm-style bitmap", "1")])
            }
            SettingsGroup(title: "Application keypad settings:") {
                RadioSetting(model: model, label: "Initial state of cursor keys:",
                             keyword: .applicationCursorKeys,
                             options: [("Normal", "0"), ("Application", "1")])
                VStack(alignment: .leading, spacing: 4) {
                    Text("Initial state of numeric keypad:")
                    Picker("Initial state of numeric keypad:", selection: $model.numericKeypadMode) {
                        Text("Normal").tag(0)
                        Text("Application").tag(1)
                        Text("NetHack").tag(2)
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    .labelsHidden()
                    .padding(.leading, 12)
                }
            }
            SettingsGroup(title: "Choose the Meta key:") {
                CheckboxSetting(model: model, label: "Option key acts as Meta", keyword: .osxOptionMeta)
                CheckboxSetting(model: model, label: "Command key acts as Meta", keyword: .osxCommandMeta)
            }
        }
    }
}

// MARK: - Terminal/Bell

struct BellPanel: View {
    let model: ConfigurationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(title: "Set the style of bell") {
                RadioSetting(model: model, label: "Action to happen when a bell occurs:", keyword: .beep,
                             options: [("None (bell disabled)", "0"),
                                       ("Make default system alert sound", "1"),
                                       ("Visual bell (flash window)", "2"),
                                       ("Play a custom sound file", "3")],
                             horizontal: false)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom sound file to play as a bell:")
                    HStack {
                        PlainTextField(label: "Custom sound file to play as a bell",
                                       text: Binding(get: { model.string(.bellWaveFile) },
                                                     set: { model.setString(.bellWaveFile, $0) }))
                        Button("Browse…") { chooseSoundFile() }
                    }
                }
                RadioSetting(model: model, label: "Dock indication on bell:", keyword: .beepInd,
                             options: [("Disabled", "0"), ("Bounce once", "1"),
                                       ("Bounce until activated", "2")])
            }
            SettingsGroup(title: "Control the bell overload behaviour") {
                CheckboxSetting(model: model, label: "Bell is temporarily disabled when over-used",
                                keyword: .bellOverload)
                NumberSetting(model: model, label: "Over-use means this many bells...",
                              keyword: .bellOverloadN)
                SecondsSetting(model: model, label: "... in this many seconds", keyword: .bellOverloadT)
                Text("The bell is re-enabled after a few seconds of silence.")
                SecondsSetting(model: model, label: "Seconds of silence required", keyword: .bellOverloadS)
            }
        }
    }

    /// windows/config.c: "Select bell sound file".
    private func chooseSoundFile() {
        let panel = NSOpenPanel()
        panel.title = "Select bell sound file"
        panel.allowedContentTypes = [.audio]
        if panel.runModal() == .OK, let url = panel.url {
            model.setString(.bellWaveFile, url.path)
        }
    }
}

/// config.c's fixed-point edit box for a time saved in microseconds.
struct SecondsSetting: View {
    let model: ConfigurationModel
    let label: String
    let keyword: PuTTYKeyword

    var body: some View {
        FixedPointSetting(model: model, label: label, keyword: keyword, denominator: 1_000_000)
    }
}

/// config.c's fixed-point edit box (`EDIT_FIXEDPOINT`): the saved value
/// over `denominator`. The text is the user's while they type.
struct FixedPointSetting: View {
    let model: ConfigurationModel
    let label: String
    let keyword: PuTTYKeyword
    let denominator: Int
    @State private var text = ""

    var body: some View {
        LabeledContent(label) {
            TextField("", text: $text)
                .labelsHidden()
                .accessibilityLabel(label)
                .frame(width: 80)
                .onAppear { text = ConfigurationModel.formatFixedPoint(model.int(keyword), denominator: denominator) }
                .onChange(of: text) { _, newText in
                    let value = ConfigurationModel.parseFixedPoint(newText, denominator: denominator)
                    if value != model.int(keyword) { model.setInt(keyword, value) }
                }
                .onChange(of: model.int(keyword)) { _, value in
                    if ConfigurationModel.parseFixedPoint(text, denominator: denominator) != value {
                        text = ConfigurationModel.formatFixedPoint(value, denominator: denominator)
                    }
                }
        }
    }
}

// MARK: - Terminal/Features

struct FeaturesPanel: View {
    let model: ConfigurationModel

    var body: some View {
        SettingsGroup(title: nil) {
            CheckboxSetting(model: model, label: "Disable application cursor keys mode",
                            keyword: .noApplicationCursors)
            CheckboxSetting(model: model, label: "Disable application keypad mode",
                            keyword: .noApplicationKeys)
            CheckboxSetting(model: model, label: "Disable xterm-style mouse reporting",
                            keyword: .noMouseReporting)
            CheckboxSetting(model: model, label: "Disable remote-controlled terminal resizing",
                            keyword: .noRemoteResize)
            CheckboxSetting(model: model, label: "Disable switching to alternate terminal screen",
                            keyword: .noAltScreen)
            CheckboxSetting(model: model, label: "Disable remote-controlled window title changing",
                            keyword: .noRemoteWinTitle)
            RadioSetting(model: model, label: "Response to remote title query (SECURITY):",
                         keyword: .remoteQTitleAction,
                         options: [("None", "0"), ("Empty string", "1"), ("Window title", "2")])
            CheckboxSetting(model: model, label: "Disable remote-controlled clearing of scrollback",
                            keyword: .noRemoteClearScroll)
            CheckboxSetting(model: model, label: "Disable destructive backspace on server sending ^?",
                            keyword: .noDBackspace)
            CheckboxSetting(model: model, label: "Disable remote-controlled character set configuration",
                            keyword: .noRemoteCharset)
            CheckboxSetting(model: model, label: "Disable Arabic text shaping",
                            keyword: .disableArabicShaping)
            CheckboxSetting(model: model, label: "Disable bidirectional text display",
                            keyword: .disableBidi)
            CheckboxSetting(model: model, label: "Disable bracketed paste mode",
                            keyword: .disableBracketedPaste)
        }
    }
}
