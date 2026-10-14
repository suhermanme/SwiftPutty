import AppKit
import Foundation
import PuTTYBridge
import SessionLayer
import TerminalUI
import TestServers
import Testing

/// The exit status uppity sends when it loses its pty/child race.
let uppityExitRace: Int32 = 127

/// An SSH session to the local uppity fixture, in a real terminal view.
@MainActor
final class SSHTerminal {
    let server: SSHFixture
    let controller: SessionController
    let view: TerminalView
    let window: NSWindow

    init(userName: String = "", keyboardInteractive: Bool = true) throws {
        try TestCore.initialize()
        server = try SSHFixture()
        var settings = PuTTYSettings.defaults()
        settings["HostName"] = "127.0.0.1"
        settings["PortNumber"] = String(server.port)
        settings["UserName"] = userName
        settings["AuthKI"] = keyboardInteractive ? "1" : "0"
        // Independent of the developer's ssh-agent and Kerberos setup.
        settings["TryAgent"] = "0"
        settings["AuthGSSAPI"] = "0"
        settings["AuthGSSAPIKEX"] = "0"
        controller = SessionController(settings: settings)
        try controller.prepare()
        view = TerminalView(controller: controller)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: view.size(columns: 80, rows: 24)),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeFirstResponder(view)
        try controller.connect()
    }

    /// Screen rows joined with newlines (PuTTY's trust sigil reads as spaces).
    var screenText: String {
        (0..<view.screen.rows).map { view.screen.text(row: $0) }.joined(separator: "\n")
    }

    func waitForScreen(_ needle: String, timeout: Duration = .seconds(20)) async -> Bool {
        let found = await waitUntil(timeout: timeout) { self.screenText.contains(needle) }
        if !found { print("Screen lacks \"\(needle)\":\n\(screenText)") }
        return found
    }

    func waitForPrompt() async -> PuTTYPrompt? {
        _ = await waitUntil(timeout: .seconds(20)) { self.controller.pendingPrompt != nil }
        return controller.pendingPrompt
    }

    /// Types a line as the user would: text through the input method,
    /// then the Return key.
    func typeLine(_ text: String) {
        view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        view.keyDown(with: keyEvent("\r", keyCode: 36, window: window))
    }

    func close() {
        window.close()
        server.stop()
    }
}

extension KitTests {
    @Suite("SSH sessions")
    @MainActor
    struct SSHTests {
        @Test func hostKeyThenKeyboardInteractiveLoginThenShell() async throws {
            let ssh = try SSHTerminal()
            defer { ssh.close() }

            let prompt = try #require(await ssh.waitForPrompt())
            #expect(prompt.kind == .hostKey)
            #expect(!prompt.isWarning)
            #expect(prompt.title == "SwiftPutty Security Alert")
            #expect(prompt.items.contains { $0.style == .display && $0.text.hasPrefix("ssh-ed25519 255 SHA256:") })
            #expect(ssh.controller.state == .connecting)
            ssh.controller.answer(prompt, with: .acceptOnce)

            #expect(await ssh.waitForScreen("login as:"))
            ssh.typeLine("tester")
            #expect(await ssh.waitForScreen("Echoey prompt:"))
            ssh.typeLine("stoat")
            #expect(await ssh.waitForScreen("Silent prompt:"))
            ssh.typeLine("weasel")
            #expect(await ssh.controller.waitForState(.connected, within: .seconds(30)) == .connected)
            #expect(!ssh.screenText.contains("weasel"))

            ssh.typeLine("echo answer-$((6*7))")
            #expect(await ssh.waitForScreen("\nanswer-42"))

            // The window's size reaches the remote pty.
            ssh.window.setContentSize(ssh.view.size(columns: 90, rows: 30))
            ssh.typeLine("stty size")
            #expect(await ssh.waitForScreen("\n30 90"))

            ssh.typeLine("exit 0")
            #expect(await ssh.controller.waitForState(.closed, within: .seconds(30)) == .closed)
            // uppity reports 127 when its pty reaches EOF before it has
            // reaped the shell (unix/pty.c, EXITTYPE_WEIRD): a race in the
            // test server, not in the client, which reports what it is
            // sent. Exact codes are checked against OpenSSH by hand.
            #expect([0, uppityExitRace].contains(ssh.controller.exitCode))
            #expect(ssh.controller.title.hasPrefix("127.0.0.1"))
        }

        @Test func passwordLoginWithConfiguredUserName() async throws {
            let ssh = try SSHTerminal(userName: "tester", keyboardInteractive: false)
            defer { ssh.close() }
            let prompt = try #require(await ssh.waitForPrompt())
            ssh.controller.answer(prompt, with: .acceptOnce)
            #expect(await ssh.waitForScreen("Using username \"tester\"."))
            #expect(await ssh.waitForScreen("tester@127.0.0.1's password:"))
            ssh.typeLine("weasel")
            #expect(await ssh.controller.waitForState(.connected, within: .seconds(30)) == .connected)
        }

        @Test func cancellingTheHostKeyEndsTheSession() async throws {
            let ssh = try SSHTerminal()
            defer { ssh.close() }
            let prompt = try #require(await ssh.waitForPrompt())
            ssh.controller.answer(prompt, with: .cancel)
            let state = await ssh.controller.waitForState(.closed, within: .seconds(30))
            #expect(state.isFinal)
            #expect(ssh.controller.pendingPrompt == nil)
        }
    }

    @Suite("PuTTY dialogs")
    struct PromptPresentationTests {
        static let unknownKey = PuTTYPrompt(id: 1, kind: .hostKey, items: [
            .init(style: .title, text: "SwiftPutty Security Alert"),
            .init(style: .paragraph, text: "The host key is not cached for this server:"),
            .init(style: .display, text: "example.org (port 22)"),
            .init(style: .prompt, text: "Store key in cache?"),
            .init(style: .moreInfoKey, text: "SHA256 fingerprint"),
            .init(style: .moreInfoShortValue, text: "ssh-ed25519 255 SHA256:abc"),
            .init(style: .moreInfoKey, text: "Full text of host's public key"),
            .init(style: .moreInfoLongValue, text: "ssh-ed25519 AAAA"),
        ])

        @Test func laysOutPuTTYsTextLikeGTKPuTTY() {
            let p = PuTTYPromptPresentation(Self.unknownKey)
            #expect(p.title == "SwiftPutty Security Alert")
            #expect(p.blocks == [.paragraph("The host key is not cached for this server:"),
                                 .display("example.org (port 22)")])
            #expect(p.moreInfo == [
                .init(key: "SHA256 fingerprint", value: "ssh-ed25519 255 SHA256:abc", isLong: false),
                .init(key: "Full text of host's public key", value: "ssh-ed25519 AAAA", isLong: true),
            ])
            #expect(p.buttons.map(\.label) == ["Accept", "Connect Once", "Cancel"])
            #expect(p.buttons.map(\.answer) == [.acceptAndStore, .acceptOnce, .cancel])
            #expect(p.buttons.first?.isDefault == true)
        }

        @Test func aChangedKeyHasNoDefaultAccept() {
            let changed = PuTTYPrompt(id: 2, kind: .hostKey, items: [
                .init(style: .scaryHeading, text: "WARNING - POTENTIAL SECURITY BREACH!"),
                .init(style: .paragraph, text: "The host key does not match the one cached."),
            ])
            let p = PuTTYPromptPresentation(changed)
            #expect(changed.isWarning)
            #expect(p.blocks.first == .warning("WARNING - POTENTIAL SECURITY BREACH!"))
            #expect(!p.buttons.contains { $0.isDefault && $0.answer != .cancel })
        }

        @Test func weakCryptoIsYesNo() {
            let p = PuTTYPromptPresentation(PuTTYPrompt(id: 3, kind: .weakCrypto, items: []))
            #expect(p.buttons.map(\.label) == ["Yes", "No"])
            #expect(p.buttons.map(\.answer) == [.acceptOnce, .cancel])
        }
    }
}
