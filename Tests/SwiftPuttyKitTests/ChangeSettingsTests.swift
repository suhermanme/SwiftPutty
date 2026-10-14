import AppKit
import ConfigurationUI
import Foundation
import PuTTYBridge
import SessionLayer
import TerminalUI
import TestServers
import Testing

extension KitTests {
/// Change Settings on running sessions (M07).
@Suite("Change Settings")
@MainActor
struct ChangeSettingsTests {
    init() throws {
        try TestCore.initialize()
    }

    @Test func exportsAppliesAndKeepsTheConnection() async throws {
        let server = try LoopbackServer(.echo)
        defer { server.stop() }
        let controller = SessionController(settings: rawSettings(port: server.port))
        try controller.connect()
        #expect(await controller.waitForState(.connected, within: .seconds(30)) == .connected)
        let transport = try #require(controller.session).transportID

        let running = try #require(await controller.beginChangeSettings())
        #expect(running.settings["HostName"] == "127.0.0.1")
        #expect(running.protocolInfo == 0)
        #expect(controller.isChangingSettings)
        // One Change Settings at a time, as PuTTY.
        #expect(await controller.beginChangeSettings() == nil)

        var edited = running.settings
        edited["CloseOnExit"] = "2"
        edited["ScrollbackLines"] = "500"
        #expect(await controller.applyChangeSettings(edited) == nil)
        #expect(!controller.isChangingSettings)
        #expect(controller.settings["CloseOnExit"] == "2")
        #expect(controller.settings["ScrollbackLines"] == "500")
        #expect(controller.session?.transportID == transport)

        // Still connected and working.
        controller.send("ping\n")
        #expect(await waitUntilTrue { controller.transcript.count >= 5 })

        // The next Change Settings starts from what was applied.
        let again = try #require(await controller.beginChangeSettings())
        #expect(again.settings["ScrollbackLines"] == "500")
        controller.cancelChangeSettings()
        #expect(!controller.isChangingSettings)
    }

    @Test func appliedSettingsReachTheTerminalAndTheWindow() async throws {
        let t = try ScriptedTerminal()
        defer { t.close() }
        #expect(await t.wait { $0.rows == 24 })

        // Backspace sends ^? by default.
        t.view.keyDown(with: keyEvent("\u{7F}", keyCode: 51, window: t.window))
        #expect(t.received(1) == "\u{7F}")

        let running = try #require(await t.controller.beginChangeSettings())
        var edited = running.settings
        edited["BackspaceIsDelete"] = "0"
        edited["WindowBorder"] = "6"
        edited["TermWidth"] = "100"
        edited["TermHeight"] = "30"
        edited["FontName"] = "Menlo-Regular 14"
        #expect(await t.controller.applyChangeSettings(edited) == nil)

        // The terminal: ^H now.
        t.view.keyDown(with: keyEvent("\u{7F}", keyCode: 51, window: t.window))
        #expect(t.received(1) == "\u{8}")

        // The window: new font, border and size.
        #expect(t.view.options.border == 6)
        #expect(t.view.renderer.font.font.pointSize == 14)
        #expect(t.window.contentLayoutRect.size == t.view.size(columns: 100, rows: 30))
        #expect(await t.wait { $0.columns == 100 && $0.rows == 30 })
    }

    @Test func theDialogMidSessionIsPuTTYs() throws {
        let storage = TemporaryStore()
        defer { storage.remove() }
        var running = rawSettings(port: 1)
        running["HostName"] = ""
        let model = ConfigurationModel(changing: running, protocolInfo: 0, store: storage.store)
        #expect(model.isMidSession)
        // Apply is always OK, even without a host name.
        #expect(model.open() == running)
        // Sessions cannot be loaded or deleted mid-session; saving works.
        try storage.store.save(PuTTYSettings.defaults(), as: "other")
        model.selectedSessionIndex = 1
        #expect(!model.loadSelectedSession())
        #expect(model.openSessionFromList() == nil)
        model.deleteSelectedSession()
        #expect(try storage.store.sessionNames() == ["Default Settings", "other"])
        model.setSavedSessionName("mine")
        model.save()
        #expect(try storage.store.load("mine").exists)
        // SSH packet logging only for SSH sessions.
        #expect(!model.showsSSHLogging)
        var ssh = running
        ssh["Protocol"] = "ssh"
        #expect(ConfigurationModel(changing: ssh, protocolInfo: 2, store: storage.store).showsSSHLogging)
        // Before a session, SSH logging is always offered.
        #expect(ConfigurationModel(store: storage.store).showsSSHLogging)
    }
}
}

@MainActor
private func waitUntilTrue(timeout: Duration = .seconds(30), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}
