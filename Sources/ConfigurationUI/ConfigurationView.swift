import AppKit
import PuTTYBridge
import SwiftUI

/// The categories of PuTTY's configuration tree that SwiftPutty has so
/// far (`config.c` `setup_config_box`; the rest arrive with M06, M09 and
/// M12). Order and nesting are PuTTY's.
public enum ConfigurationCategory: String, CaseIterable, Identifiable, Sendable {
    case session, logging, terminal, window, appearance, behaviour, connection, data

    public var id: Self { self }

    /// The name in the tree.
    public var name: String {
        switch self {
        case .session: "Session"
        case .logging: "Logging"
        case .terminal: "Terminal"
        case .window: "Window"
        case .appearance: "Appearance"
        case .behaviour: "Behaviour"
        case .connection: "Connection"
        case .data: "Data"
        }
    }

    /// Nesting depth in the tree.
    public var depth: Int {
        switch self {
        case .logging, .appearance, .behaviour, .data: 1
        default: 0
        }
    }

    /// The panel's title (`ctrl_settitle`).
    public var title: String {
        switch self {
        case .session: "Basic options for your SwiftPutty session"
        case .logging: "Options controlling session logging"
        case .terminal: "Options controlling the terminal emulation"
        case .window: "Options controlling SwiftPutty's window"
        case .appearance: "Configure the appearance of SwiftPutty's window"
        case .behaviour: "Configure the behaviour of SwiftPutty's window"
        case .connection: "Options controlling the connection"
        case .data: "Data to send to the server"
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
                Button("About", action: onAbout)
                Spacer()
                Button("Open") {
                    if let settings = model.open() {
                        onOpen(settings)
                    }
                }
                .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 680, height: 560)
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
            ForEach(ConfigurationCategory.allCases) { category in
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
        case .window: WindowPanel(model: model)
        case .appearance: AppearancePanel(model: model)
        case .behaviour: BehaviourPanel(model: model)
        case .connection: ConnectionPanel(model: model)
        case .data: DataPanel(model: model)
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

    var body: some View {
        Picker(label, selection: Binding(get: { model.string(keyword) },
                                         set: { model.setString(keyword, $0) })) {
            ForEach(options, id: \.value) { option in
                Text(option.label).tag(option.value)
            }
        }
        .pickerStyle(.radioGroup)
        .horizontalRadioGroupLayout(horizontal)
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
