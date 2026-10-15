import AppKit
import PuTTYBridge
import SwiftUI

// Window/Translation, Window/Selection, Window/Selection/Copy and
// Window/Colours (M06), as config.c and unix/config-gtk.c.

// MARK: - Window/Translation

struct TranslationPanel: View {
    let model: ConfigurationModel

    /// "Use font encoding" is left out: SwiftPutty draws Unicode only, so
    /// a font has no encoding of its own (a saved value still loads).
    private static let characterSets = PuTTYSettings.characterSets.filter { $0 != "Use font encoding" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(title: "Character set translation on received data") {
                Picker("Remote character set:", selection: Binding(
                    get: { PuTTYSettings.canonicalCharacterSet(model.string(.lineCodePage)) },
                    set: { model.setString(.lineCodePage, $0) })) {
                    ForEach(Self.characterSets, id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
                CheckboxSetting(model: model, label: "Override with UTF-8 if locale says so",
                                keyword: .utf8Override)
            }
            SettingsGroup(title: nil) {
                CheckboxSetting(model: model, label: "Treat CJK ambiguous characters as wide",
                                keyword: .cjkAmbigWide)
            }
            SettingsGroup(title: "Adjust how SwiftPutty handles line drawing characters") {
                RadioSetting(model: model, label: "Handling of line drawing characters:",
                             keyword: .fontVTMode,
                             options: [("Use Unicode line drawing code points", "4"),
                                       ("Poor man's line drawing (+, - and |)", "3")],
                             horizontal: false)
                CheckboxSetting(model: model, label: "Copy and paste line drawing characters as lqqqk",
                                keyword: .rawCNP)
                CheckboxSetting(model: model, label: "Enable VT100 line drawing even in UTF-8 mode",
                                keyword: .utf8linedraw)
            }
        }
    }
}

// MARK: - Window/Selection

struct SelectionPanel: View {
    let model: ConfigurationModel

    /// `clipboard_selector_handler` with OS X's names. Named ("custom")
    /// clipboards are an X11 feature and are not offered.
    private static let clipboards = [("No action", "none"),
                                     ("Last selected text", "implicit"),
                                     ("System clipboard", "explicit")]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(title: "Control use of mouse") {
                CheckboxSetting(model: model, label: "Shift overrides application's use of mouse",
                                keyword: .mouseOverride)
                // Windows PuTTY's option; GTK PuTTY behaves as
                // Compromise, with Ctrl+right-click for its menu.
                RadioSetting(model: model, label: "Action of mouse buttons:", keyword: .mouseIsXterm,
                             options: [("Windows (Middle extends, Right brings up menu)", "2"),
                                       ("Compromise (Middle extends, Right pastes)", "0"),
                                       ("xterm (Right extends, Middle pastes)", "1")],
                             horizontal: false)
                RadioSetting(model: model,
                             label: "Default selection mode (Option+drag does the other one):",
                             keyword: .rectSelect,
                             options: [("Normal", "0"), ("Rectangular block", "1")])
            }
            SettingsGroup(title: "Assign copy/paste actions to clipboards") {
                CheckboxSetting(model: model, label: "Auto-copy selected text to system clipboard",
                                keyword: .mouseAutocopy)
                PopupSetting(model: model, label: "Mouse paste action:", keyword: .mousePaste,
                             options: Self.clipboards)
                PopupSetting(model: model, label: "{Ctrl,Shift} + Ins:", keyword: .ctrlShiftIns,
                             options: Self.clipboards)
                PopupSetting(model: model, label: "Ctrl + Shift + {C,V}:", keyword: .ctrlShiftCV,
                             options: Self.clipboards)
            }
            SettingsGroup(title: "Control pasting of text from clipboard to terminal") {
                CheckboxSetting(model: model, label: "Permit control characters in pasted text",
                                keyword: .pasteControls)
            }
        }
    }
}

// MARK: - Window/Selection/Copy

struct CopyPanel: View {
    let model: ConfigurationModel
    @State private var selection = Set<Int>()
    @State private var classText = ""

    var body: some View {
        SettingsGroup(title: "Classes of character that group together") {
            Text("Character classes:")
            // charclass_handler: code, hex, the character, its class.
            Table(of: CharacterRow.self, selection: $selection) {
                TableColumn("Code") { Text(String($0.id)) }.width(50)
                TableColumn("Hex") { Text(String(format: "(0x%02X)", $0.id)) }.width(70)
                TableColumn("Char") { row in
                    Text(row.id >= 0x21 && row.id != 0x7F ? String(UnicodeScalar(UInt8(row.id))) : " ")
                        .font(.system(.body, design: .monospaced))
                }
                .width(50)
                TableColumn("Class") { Text(String(model.characterClass($0.id))) }
            } rows: {
                ForEach(0..<128, id: \.self) { TableRow(CharacterRow(id: $0)) }
            }
            .frame(height: 240)
            HStack {
                Text("Set to class")
                TextField("", text: $classText)
                    .labelsHidden()
                    .accessibilityLabel("Set to class")
                    .frame(width: 60)
                Button("Set") {
                    model.setCharacterClass(selection, to: classText)
                }
                .disabled(selection.isEmpty)
            }
        }
        // Windows PuTTY's "format" getset of the same panel. Windows copies
        // RTF to the clipboard; here the styled copy is RTF as well as
        // plain text (docs/DECISIONS.md).
        SettingsGroup(title: "Formatting of copied characters") {
            CheckboxSetting(model: model,
                            label: "Copy to clipboard in RTF as well as plain text",
                            keyword: .pasteRTF)
        }
    }
}

private struct CharacterRow: Identifiable {
    let id: Int
}

// MARK: - Window/Colours

struct ColoursPanel: View {
    let model: ConfigurationModel
    @State private var selected: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(title: "General options for colour usage") {
                CheckboxSetting(model: model, label: "Allow terminal to specify ANSI colours",
                                keyword: .ansiColour)
                CheckboxSetting(model: model, label: "Allow terminal to use xterm 256-colour mode",
                                keyword: .xterm256Colour)
                CheckboxSetting(model: model, label: "Allow terminal to use 24-bit colours",
                                keyword: .trueColour)
                RadioSetting(model: model, label: "Indicate bolded text by changing:",
                             keyword: .boldAsColour,
                             options: [("The font", "0"), ("The colour", "1"), ("Both", "2")])
                // Windows PuTTY's option: here macOS's text colours, which
                // follow light and dark mode.
                CheckboxSetting(model: model, label: "Use system colours", keyword: .useSystemColours)
            }
            SettingsGroup(title: "Adjust the precise colours SwiftPutty displays") {
                Text("Select a colour from the list, and then change its red, green and blue values or click Modify.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top) {
                    List(selection: $selected) {
                        ForEach(Array(ConfigurationModel.colourNames.enumerated()), id: \.offset) { index, name in
                            HStack {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(swatch(index))
                                    .frame(width: 14, height: 14)
                                Text(name)
                            }
                            .tag(index)
                        }
                    }
                    .listStyle(.bordered(alternatesRowBackgrounds: false))
                    .frame(height: 7 * 24)
                    VStack(alignment: .leading, spacing: 6) {
                        if let index = selected {
                            componentField("Red", index, \.red)
                            componentField("Green", index, \.green)
                            componentField("Blue", index, \.blue)
                            ColorPicker("Modify…", selection: colourBinding(index), supportsOpacity: false)
                        } else {
                            Text("No colour selected")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 140, alignment: .leading)
                }
            }
        }
    }

    private func swatch(_ index: Int) -> Color {
        let c = model.colour(index)
        return Color(red: Double(c.red) / 255, green: Double(c.green) / 255, blue: Double(c.blue) / 255)
    }

    private func componentField(_ label: String, _ index: Int,
                                _ component: WritableKeyPath<ColourComponents, Int>) -> some View {
        LabeledContent(label) {
            IntegerField(label: label, value: Binding(
                get: { ColourComponents(model.colour(index))[keyPath: component] },
                set: {
                    var c = ColourComponents(model.colour(index))
                    c[keyPath: component] = $0
                    model.setColour(index, red: c.red, green: c.green, blue: c.blue)
                }))
                .frame(width: 50)
        }
    }

    private func colourBinding(_ index: Int) -> Binding<CGColor> {
        Binding(get: { swatch(index).resolve(in: EnvironmentValues()).cgColor },
                set: { colour in
                    guard let srgb = colour.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                      intent: .defaultIntent, options: nil),
                          let parts = srgb.components, parts.count >= 3 else { return }
                    model.setColour(index, red: Int((parts[0] * 255).rounded()),
                                    green: Int((parts[1] * 255).rounded()),
                                    blue: Int((parts[2] * 255).rounded()))
                })
    }
}

private struct ColourComponents {
    var red, green, blue: Int
    init(_ c: (red: Int, green: Int, blue: Int)) {
        red = c.red
        green = c.green
        blue = c.blue
    }
}
