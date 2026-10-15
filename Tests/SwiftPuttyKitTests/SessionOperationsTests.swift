import Foundation
import PuTTYBridge
import SessionLayer
import Testing

extension KitTests {
    @Suite("Event Log")
    struct EventLogTests {
        /// As PuTTY's logevent_dlg: the first 128 lines, "..", then the
        /// most recent 127.
        @Test func keepsTheFirstAndTheMostRecentEntries() {
            var log = EventLog()
            for n in 0..<128 { log.append("e\(n)") }
            #expect(log.count == 128)
            for n in 128..<256 { log.append("e\(n)") }
            #expect(log.count == 256)
            #expect(!log.contains(.gap))           // full, nothing dropped yet

            for n in 256..<300 { log.append("e\(n)") }
            #expect(log.count == 256)
            #expect(log.prefix(128).map(\.text) == (0..<128).map { "e\($0)" })
            #expect(log[128] == .gap)
            #expect(log.suffix(127).map(\.text) == (173..<300).map { "e\($0)" })
        }

        @Test func linesAreTimestampedAsPuTTYShowsThem() throws {
            let time = try #require(Calendar.current.date(
                from: DateComponents(year: 2026, month: 10, day: 5, hour: 9, minute: 4, second: 7)))
            let entry = EventLog.Entry(time: time, text: "Connected to example.org")
            #expect(entry.line == "2026-10-05 09:04:07\tConnected to example.org")
            #expect(EventLog.Entry.gap.line == "..")
            #expect(EventLog.clipboardText(for: [entry, .gap])
                    == "2026-10-05 09:04:07\tConnected to example.org\n..\n")
        }
    }

    @Suite("Session operations")
    @MainActor
    struct SessionOperationsTests {
        private func login(_ ssh: SSHTerminal) async throws {
            let prompt = try #require(await ssh.waitForPrompt())
            ssh.controller.answer(prompt, with: .acceptOnce)
            #expect(await ssh.waitForScreen("tester@127.0.0.1's password:"))
            ssh.typeLine("weasel")
            #expect(await ssh.controller.waitForState(.connected, within: .seconds(30)) == .connected)
        }

        @Test func specialCommandsCloseWarningAndRestart() async throws {
            let ssh = try SSHTerminal(userName: "tester", keyboardInteractive: false)
            defer { ssh.close() }
            let controller = ssh.controller
            try await login(ssh)

            // SSH-2's Special Commands, as a menu tree.
            #expect(await waitUntil(timeout: .seconds(20)) { !controller.specials.isEmpty })
            let commands = controller.specials.allCommands.map(\.name)
            #expect(commands.contains("Break"))
            #expect(commands.contains("SIGINT (Interrupt)"))
            #expect(controller.specials.contains { if case .submenu("More signals", let entries) = $0 {
                !entries.isEmpty } else { false } })
            #expect(controller.specials.contains(.separator))

            let rekey = try #require(controller.specials.allCommands.first { $0.name == "Repeat key exchange" })
            let transport = controller.session?.transportID
            controller.runSpecial(rekey)
            #expect(await waitUntil(timeout: .seconds(20)) {
                controller.eventLog.contains { $0.text == "Initiating key re-exchange (at user request)" }
            })
            #expect(controller.session?.transportID == transport)

            // Connected: closing asks first, with PuTTY's wording.
            #expect(controller.mayNeedCloseWarning)
            #expect(!controller.canRestart)
            let warning = try #require(await controller.closeWarning())
            #expect(warning.message == "Are you sure you want to close this session?")

            // Ended: no specials, no warning, Restart available.
            controller.close()
            #expect(await controller.waitForState(.closed, within: .seconds(10)) == .closed)
            #expect(await waitUntil { controller.specials.isEmpty })
            #expect(await controller.closeWarning() == nil)
            #expect(controller.canRestart)

            controller.resetTerminal()                 // forget the old prompt
            #expect(await waitUntil { !ssh.screenText.contains("password:") })
            controller.restart()
            #expect(await waitUntil { !controller.state.isFinal })   // connecting again
            try await login(ssh)
            #expect(controller.exitCode == nil)
            #expect(controller.session?.transportID != transport)
            #expect(controller.eventLog.contains { $0.text == "----- Session restarted -----" })
            ssh.typeLine("echo back-$((8*8))")
            #expect(await ssh.waitForScreen("\nback-64"))
        }

        @Test func clearScrollback() async throws {
            let ssh = try SSHTerminal(userName: "tester", keyboardInteractive: false)
            defer { ssh.close() }
            try await login(ssh)
            ssh.typeLine("seq 1 80")
            #expect(await ssh.waitForScreen("\n80"))
            #expect(await waitUntil { ssh.view.screen.scrollTotal > ssh.view.screen.scrollPage })
            ssh.controller.clearScrollback()
            #expect(await waitUntil { ssh.view.screen.scrollTotal == ssh.view.screen.scrollPage })
        }
    }
}
