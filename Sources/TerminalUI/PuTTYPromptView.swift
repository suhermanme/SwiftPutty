import PuTTYBridge
import SwiftUI

/// How a PuTTY dialog is laid out, following GTK PuTTY
/// (unix/dialog.c gtk_format_seatdialogtext and the "More info" box):
/// title, then warning heading, paragraphs and monospaced display lines
/// in order; the console-style question is left out; key/value details
/// go under "More info".
public struct PuTTYPromptPresentation: Equatable {
    public enum Block: Equatable {
        case warning(String)
        case paragraph(String)
        case display(String)
    }

    public struct Detail: Equatable {
        public var key: String
        public var value: String
        public var isLong: Bool

        public init(key: String, value: String, isLong: Bool) {
            self.key = key
            self.value = value
            self.isLong = isLong
        }
    }

    public struct Button: Equatable {
        public var label: String
        public var answer: PuTTYPrompt.Answer
        public var isCancel: Bool
        public var isDefault: Bool
    }

    public var title: String
    public var blocks: [Block]
    public var moreInfo: [Detail]
    public var buttons: [Button]

    public init(_ prompt: PuTTYPrompt) {
        title = prompt.title ?? "SwiftPutty"
        var blocks: [Block] = []
        var details: [Detail] = []
        var pendingKey: String?
        for item in prompt.items {
            switch item.style {
            case .scaryHeading: blocks.append(.warning(item.text))
            case .paragraph: blocks.append(.paragraph(item.text))
            case .display: blocks.append(.display(item.text))
            case .moreInfoKey: pendingKey = item.text
            case .moreInfoShortValue, .moreInfoLongValue:
                details.append(Detail(key: pendingKey ?? "", value: item.text,
                                      isLong: item.style == .moreInfoLongValue))
                pendingKey = nil
            case .title, .prompt: break
            }
        }
        self.blocks = blocks
        moreInfo = details

        // The buttons named in PuTTY's text (gtk_seat_prompt_descriptions).
        // A warning about a changed key has no default button, so Return
        // cannot accept it by accident.
        switch prompt.kind {
        case .hostKey:
            buttons = [
                Button(label: "Accept", answer: .acceptAndStore, isCancel: false,
                       isDefault: !prompt.isWarning),
                Button(label: "Connect Once", answer: .acceptOnce, isCancel: false, isDefault: false),
                Button(label: "Cancel", answer: .cancel, isCancel: true, isDefault: false),
            ]
        case .weakCrypto, .weakCachedHostKey:
            buttons = [
                Button(label: "Yes", answer: .acceptOnce, isCancel: false, isDefault: false),
                Button(label: "No", answer: .cancel, isCancel: true, isDefault: true),
            ]
        case .logFileExists:
            // unix/dialog.c gtkdlg_askappend
            buttons = [
                Button(label: "Overwrite", answer: .overwriteLog, isCancel: false, isDefault: true),
                Button(label: "Append", answer: .appendToLog, isCancel: false, isDefault: false),
                Button(label: "Disable", answer: .cancel, isCancel: true, isDefault: false),
            ]
        }
    }
}

/// A sheet showing a PuTTY dialog and returning the user's answer.
public struct PuTTYPromptView: View {
    public let prompt: PuTTYPrompt
    public let answer: (PuTTYPrompt.Answer) -> Void
    private let presentation: PuTTYPromptPresentation

    public init(prompt: PuTTYPrompt, answer: @escaping (PuTTYPrompt.Answer) -> Void) {
        self.prompt = prompt
        self.answer = answer
        presentation = PuTTYPromptPresentation(prompt)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                icon
                Text(presentation.title)
                    .font(.headline)
                    .padding(.top, 6)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(presentation.blocks.enumerated()), id: \.offset) { _, block in
                        blockView(block)
                    }
                    if !presentation.moreInfo.isEmpty {
                        DisclosureGroup("More info") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(presentation.moreInfo.enumerated()), id: \.offset) { _, detail in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(detail.key).font(.caption.weight(.semibold))
                                        Text(detail.value)
                                            .font(.system(.caption, design: .monospaced))
                                            .textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)
            HStack {
                Spacer()
                ForEach(Array(presentation.buttons.enumerated()), id: \.offset) { _, button in
                    buttonView(button)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    /// A question about the log file is not a security matter.
    @ViewBuilder
    private var icon: some View {
        if prompt.kind == .logFileExists {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
        } else {
            Image(systemName: prompt.isWarning ? "exclamationmark.octagon.fill"
                                               : "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(prompt.isWarning ? .red : .yellow)
        }
    }

    @ViewBuilder
    private func blockView(_ block: PuTTYPromptPresentation.Block) -> some View {
        switch block {
        case .warning(let text):
            Text(text)
                .font(.body.weight(.bold))
                .foregroundStyle(.red)
        case .paragraph(let text):
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        case .display(let text):
            Text(text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 16)
        }
    }

    @ViewBuilder
    private func buttonView(_ button: PuTTYPromptPresentation.Button) -> some View {
        let action = { answer(button.answer) }
        if button.isCancel {
            Button(button.label, role: .cancel, action: action)
                .keyboardShortcut(button.isDefault ? .defaultAction : .cancelAction)
        } else if button.isDefault {
            Button(button.label, action: action).keyboardShortcut(.defaultAction)
        } else {
            Button(button.label, action: action)
        }
    }
}
