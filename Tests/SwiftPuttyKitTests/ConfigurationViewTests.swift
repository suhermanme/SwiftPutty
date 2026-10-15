import AppKit
import ConfigurationUI
import Foundation
import PuTTYBridge
import SwiftUI
import Testing

extension KitTests {
    /// The configuration dialog's views in a real window, typed into
    /// through AppKit's field editor as the user types.
    @Suite("Configuration dialog views")
    @MainActor
    struct ConfigurationViewTests {
        init() throws {
            try TestCore.initialize()
        }

        private func textFields(in view: NSView) -> [NSTextField] {
            view.subviews.flatMap { sub -> [NSTextField] in
                ((sub as? NSTextField).map { [$0] } ?? []) + textFields(in: sub)
            }
        }

        private func type(_ text: String, into field: NSTextField, in window: NSWindow) async {
            window.makeFirstResponder(field)
            let editor = try? #require(field.currentEditor() as? NSTextView)
            editor?.selectAll(nil)
            // One key at a time, letting SwiftUI update in between.
            for character in text {
                editor?.insertText(String(character), replacementRange: editor?.selectedRange() ?? NSRange())
                try? await Task.sleep(for: .milliseconds(30))
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        @Test func typedHostAndPortReachTheSettings() async throws {
            let storage = TemporaryStore()
            defer { storage.remove() }
            let model = ConfigurationModel(store: storage.store)
            let host = NSHostingView(rootView: ConfigurationView(model: model, onOpen: { _ in },
                                                                 onCancel: {}, onAbout: {}))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 672),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(100))

            // The Session panel's edit boxes, in order: host, port, saved
            // session name.
            let fields = textFields(in: host).filter(\.isEditable)
            try #require(fields.count >= 3)
            let hostField = fields[0], portField = fields[1]
            #expect(portField.stringValue == "22")

            await type("example.org", into: hostField, in: window)
            await type("2222", into: portField, in: window)
            #expect(portField.stringValue == "2222")
            #expect(model.settings["HostName"] == "example.org")
            #expect(model.port == 2222)
            #expect(model.settings["PortNumber"] == "2222")
        }
    }
}
