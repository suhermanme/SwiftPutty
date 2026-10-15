import AppKit
import SessionLayer
import SwiftUI

/// A session's Event Log window, as GTK PuTTY's (unix/dialog.c
/// showeventlog): every entry with its time, several can be selected,
/// and the selection is copied as PuTTY copies it (one line each,
/// "time<TAB>event"). New entries appear while it is open.
public struct EventLogView: View {
    let controller: SessionController
    let onClose: () -> Void
    @State private var selection: Set<Int> = []

    public init(controller: SessionController, onClose: @escaping () -> Void) {
        self.controller = controller
        self.onClose = onClose
    }

    private struct Row: Identifiable {
        let id: Int
        let entry: EventLog.Entry
    }

    private var rows: [Row] {
        controller.eventLog.enumerated().map { Row(id: $0.offset, entry: $0.element) }
    }

    public var body: some View {
        VStack(spacing: 0) {
            Table(rows, selection: $selection) {
                TableColumn("Time") { row in
                    Text(row.entry.timeText).monospacedDigit()
                }
                .width(min: 120, ideal: 140, max: 180)
                TableColumn("Event") { row in
                    Text(row.entry.text).textSelection(.disabled)
                }
            }
            .onCopyCommand {
                selection.isEmpty ? [] : [NSItemProvider(object: clipboardText(selection) as NSString)]
            }
            .contextMenu(forSelectionType: Int.self) { indices in
                Button("Copy") { copy(indices) }.disabled(indices.isEmpty)
            }
            HStack {
                Button("Copy") { copy(selection) }
                    .disabled(selection.isEmpty)
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(minWidth: 520, idealWidth: 640, minHeight: 240, idealHeight: 320)
        .onExitCommand(perform: onClose)
    }

    private func clipboardText(_ indices: Set<Int>) -> String {
        let log = controller.eventLog
        return EventLog.clipboardText(for: indices.sorted().filter { log.indices.contains($0) }.map { log[$0] })
    }

    private func copy(_ indices: Set<Int>) {
        guard !indices.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(clipboardText(indices), forType: .string)
    }
}
