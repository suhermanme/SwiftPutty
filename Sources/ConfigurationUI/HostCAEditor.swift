import AppKit
import Observation
import PuTTYBridge
import SwiftUI
import UniformTypeIdentifiers

/// The "Configure host CAs" window's state and actions, as upstream's
/// dialog (ssh/ca-config.c): the record being edited, the saved records'
/// names, Load / Save / Delete, and the public key's fingerprint.
@MainActor
@Observable
public final class HostCAEditor {
    public var name = "" {
        didSet { selectTypedName() }
    }
    public var publicKey = "" {
        didSet { refreshKeyInfo() }
    }
    public var validity = ""
    public var permitRSASHA1 = false
    public var permitRSASHA256 = true
    public var permitRSASHA512 = true

    public private(set) var names: [String] = []
    public var selectedIndex: Int?
    /// The key's fingerprint, or why it is not usable.
    public private(set) var keyInfo = ""
    public var errorMessage: String?
    /// Where an expression error is (UTF-8 byte offsets), to select it.
    public private(set) var expressionErrorRange: Range<Int>?

    private let beep: () -> Void

    public init(beep: @escaping () -> Void = {}) {
        self.beep = beep
        set(from: .newDefault())
        refreshNames()
    }

    private func set(from ca: HostCA) {
        name = ca.name
        publicKey = ca.publicKey
        validity = ca.validity
        permitRSASHA1 = ca.permitRSASHA1
        permitRSASHA256 = ca.permitRSASHA256
        permitRSASHA512 = ca.permitRSASHA512
    }

    private func refreshNames() {
        names = HostCAStore.names()
    }

    private func refreshKeyInfo() {
        keyInfo = HostCAStore.keyInfo(publicKey).description
    }

    /// ca_name_handler: typing a name selects the first record at or
    /// after it (else the last).
    private func selectTypedName() {
        guard !names.isEmpty else { return }
        let typed = Array(name.utf8)
        selectedIndex = names.firstIndex { !Array($0.utf8).lexicographicallyPrecedes(typed) }
            ?? names.count - 1
    }

    /// Load (or a double-click): the selected record into the fields.
    public func loadSelected() {
        guard let index = selectedIndex, names.indices.contains(index) else {
            beep()
            return
        }
        guard let ca = HostCAStore.load(names[index]) else {
            errorMessage = "Unable to load host CA record '\(names[index])'"
            return
        }
        set(from: ca)
    }

    /// Save, with upstream's checks (expression, then key).
    public func save() {
        expressionErrorRange = nil
        let ca = HostCA(name: name, publicKey: publicKey, validity: validity,
                        permitRSASHA1: permitRSASHA1, permitRSASHA256: permitRSASHA256,
                        permitRSASHA512: permitRSASHA512)
        do {
            try HostCAStore.save(ca)
            refreshNames()
            selectTypedName()
        } catch {
            errorMessage = error.message
            expressionErrorRange = error.expressionRange
        }
    }

    /// Delete the selected record.
    public func deleteSelected() {
        guard let index = selectedIndex, names.indices.contains(index) else {
            beep()
            return
        }
        if let error = HostCAStore.delete(names[index]) {
            errorMessage = error
        } else {
            refreshNames()
            selectedIndex = nil
        }
    }

    /// "Read from file...": a public key file; its key replaces the text,
    /// as a base64 blob, or its error is shown.
    public func readPublicKey(from url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            errorMessage = "Unable to read \(url.path)"
            return
        }
        let info = HostCAStore.keyInfo(text)
        if let blob = info.blob {
            publicKey = blob
        } else {
            errorMessage = info.description
        }
    }
}

extension HostCA {
    public init(name: String, publicKey: String, validity: String,
                permitRSASHA1: Bool, permitRSASHA256: Bool, permitRSASHA512: Bool) {
        var ca = HostCA.newDefault()
        ca.name = name
        ca.publicKey = publicKey
        ca.validity = validity
        ca.permitRSASHA1 = permitRSASHA1
        ca.permitRSASHA256 = permitRSASHA256
        ca.permitRSASHA512 = permitRSASHA512
        self = ca
    }
}

/// The "Configure host CAs" window (SwiftPutty's native form of
/// upstream's dialog).
public struct HostCAView: View {
    @Bindable var editor: HostCAEditor
    let onDone: () -> Void

    public init(editor: HostCAEditor, onDone: @escaping () -> Void) {
        self.editor = editor
        self.onDone = onDone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(title: "Load, save or delete a host CA record") {
                Text("Name for this CA (shown in log messages)")
                PlainTextField(label: "Name for this CA", text: $editor.name)
                HStack(alignment: .top) {
                    List(selection: $editor.selectedIndex) {
                        ForEach(Array(editor.names.enumerated()), id: \.offset) { index, name in
                            Text(name).tag(index)
                        }
                    }
                    .listStyle(.bordered(alternatesRowBackgrounds: false))
                    .frame(height: 4 * 24)
                    .contextMenu(forSelectionType: Int.self) { _ in
                    } primaryAction: { _ in
                        editor.loadSelected()
                    }
                    VStack(spacing: 8) {
                        Button("Load") { editor.loadSelected() }
                        Button("Save") { editor.save() }
                        Button("Delete") { editor.deleteSelected() }
                    }
                    .frame(width: 80)
                    .buttonStyle(.bordered)
                }
            }
            SettingsGroup(title: "Public key for this CA record") {
                Text("Public key of certification authority")
                HStack {
                    PlainTextField(label: "Public key of certification authority", text: $editor.publicKey)
                    Button("Read from file…", action: chooseKeyFile)
                }
                Text(editor.keyInfo.isEmpty ? " " : editor.keyInfo)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            SettingsGroup(title: "What this CA is trusted to do") {
                Text("Valid hosts this key is trusted to certify")
                PlainTextField(label: "Valid hosts this key is trusted to certify", text: $editor.validity)
                HStack {
                    Text("Signature types (RSA keys only):")
                    Toggle("SHA-1", isOn: $editor.permitRSASHA1)
                    Toggle("SHA-256", isOn: $editor.permitRSASHA256)
                    Toggle("SHA-512", isOn: $editor.permitRSASHA512)
                }
            }
            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 620)
        .alert("SwiftPutty Error", isPresented: Binding(get: { editor.errorMessage != nil },
                                                        set: { if !$0 { editor.errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(editor.errorMessage ?? "")
        }
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Select public key file of certification authority"
        if panel.runModal() == .OK, let url = panel.url {
            editor.readPublicKey(from: url)
        }
    }
}
