import ConfigurationUI
import Foundation
import Persistence
import PuTTYBridge
import SessionLayer
import TestServers
import Testing

extension KitTests {
    /// Proxies through the Swift API (M12): an SSH jump host named by a
    /// saved session in SwiftPutty's store.
    @Suite("Proxies")
    @MainActor
    struct ProxyTests {
        init() throws {
            try TestCore.initialize()
        }

        @Test func sshJumpHostFromASavedSession() async throws {
            let storage = TemporaryStore()
            defer { storage.remove() }
            let jump = try SSHFixture()
            defer { jump.stop() }
            let echo = try LoopbackServer(.echo)
            defer { echo.stop() }

            var saved = PuTTYSettings.defaults()
            saved["HostName"] = "127.0.0.1"
            saved["PortNumber"] = String(jump.port)
            saved["UserName"] = "tester"
            saved["AuthKI"] = "0"
            saved["TryAgent"] = "0"
            saved["AuthGSSAPI"] = "0"
            saved["AuthGSSAPIKEX"] = "0"
            try storage.store.save(saved, as: "jump box")
            let store = storage.store
            PuTTYCore.setSavedSessionLookup { name in
                guard let (settings, exists) = try? store.load(name), exists else { return nil }
                return settings
            }
            defer { PuTTYCore.setSavedSessionLookup(nil) }

            var settings = rawSettings(port: echo.port)
            settings["ProxyMethod"] = "6"
            settings["ProxyHost"] = "jump box"
            settings["ProxyLocalhost"] = "1"
            settings["ProxyPassword"] = "weasel"
            let controller = SessionController(settings: settings)
            try controller.connect()

            // The jump host's key is new: PuTTY asks, through the session.
            #expect(await waitUntil(timeout: .seconds(20)) { controller.pendingPrompt != nil })
            let prompt = try #require(controller.pendingPrompt)
            #expect(prompt.kind == .hostKey)
            controller.answer(prompt, with: .acceptOnce)
            #expect(await controller.waitForState(.connected, within: .seconds(20)) == .connected)
            #expect(controller.eventLog.contains { $0.text == "proxy: Using username \"tester\"." })
            #expect(controller.eventLog.contains { $0.text == "proxy: Opened main channel" })

            controller.send("through the jump host\r\n")
            #expect(await waitUntil(timeout: .seconds(20)) {
                String(decoding: controller.transcript, as: UTF8.self).contains("through the jump host")
            })
            controller.close()
            #expect(await controller.waitForState(.closed, within: .seconds(10)) == .closed)
        }
    }
}

extension KitTests {
    /// Connection/Data's environment variables (config.c environ_handler).
    @Suite("Environment variables")
    @MainActor
    struct EnvironmentTests {
        @Test func addRemoveAndPuTTYsSavedForm() {
            let storage = TemporaryStore()
            defer { storage.remove() }
            var beeps = 0
            let model = ConfigurationModel(store: storage.store) { beeps += 1 }
            model.addEnvironmentVariable()                  // both empty
            model.environmentName = "LANG"
            model.addEnvironmentVariable()                  // no value
            #expect(beeps == 2 && model.environmentVariables.isEmpty)

            model.environmentValue = "en_GB.UTF-8"
            model.addEnvironmentVariable()
            #expect(model.environmentName.isEmpty && model.environmentValue.isEmpty)
            model.environmentName = "A_LIST"
            model.environmentValue = "x,y=z\\w"
            model.addEnvironmentVariable()
            // Byte-wise order by name, escaped as settings.c's wmap writes it.
            #expect(model.environmentVariables.map(\.name) == ["A_LIST", "LANG"])
            #expect(model.settings["Environment"] == #"A_LIST=x\,y\=z\\w,LANG=en_GB.UTF-8"#)
            #expect(model.settings.normalised()["Environment"] == model.settings["Environment"])

            // The same name replaces the value.
            model.environmentName = "LANG"
            model.environmentValue = "C"
            model.addEnvironmentVariable()
            #expect(model.environmentVariables.map(\.value) == ["x,y=z\\w", "C"])

            // Remove puts the entry back in the boxes.
            model.removeEnvironmentVariable(at: 0)
            #expect(model.environmentName == "A_LIST" && model.environmentValue == "x,y=z\\w")
            #expect(model.environmentVariables.map(\.name) == ["LANG"])
            model.removeEnvironmentVariable(at: nil)
            #expect(beeps == 3)
        }
    }
}

extension KitTests {
    /// Connection/SSH/Host keys: manually configured host keys
    /// (config.c manual_hostkey_handler).
    @Suite("Manual host keys")
    @MainActor
    struct ManualHostKeyTests {
        init() throws {
            try TestCore.initialize()
        }

        @Test func addCanonicalisesAndRejects() {
            let storage = TemporaryStore()
            defer { storage.remove() }
            var beeps = 0
            let model = ConfigurationModel(store: storage.store) { beeps += 1 }

            model.addManualHostKey()
            #expect(model.errorMessage == "You need to specify a host key or fingerprint")
            model.manualHostKeyText = "nonsense"
            model.addManualHostKey()
            #expect(model.errorMessage == "Host key is not in a valid format")

            // A known_hosts-style line: the fingerprint is kept, canonical.
            model.manualHostKeyText = "example.org ssh-ed25519 255 SHA256:ADly5k1O7s2C72nWl2ReSxP+HnNPcmTIGAcWJE/gMmg"
            model.addManualHostKey()
            model.manualHostKeyText = "MD5:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99"
            model.addManualHostKey()
            #expect(model.manualHostKeys == ["SHA256:ADly5k1O7s2C72nWl2ReSxP+HnNPcmTIGAcWJE/gMmg",
                                              "aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99"])
            model.errorMessage = nil
            model.manualHostKeyText = "aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99"
            model.addManualHostKey()
            #expect(model.errorMessage == "Specified host key is already listed")

            // Saved as keys only, and PuTTY reads it back unchanged.
            let saved = model.settings["SSHManualHostKeys"]
            #expect(saved == "SHA256:ADly5k1O7s2C72nWl2ReSxP+HnNPcmTIGAcWJE/gMmg,aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99")
            #expect(model.settings.normalised()["SSHManualHostKeys"] == saved)

            model.removeManualHostKey(at: 1)
            #expect(model.manualHostKeyText == "aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99")
            #expect(model.manualHostKeys.count == 1)
            model.removeManualHostKey(at: nil)
            #expect(beeps == 1)
        }
    }
}

extension KitTests {
    /// "Configure host CAs" (upstream ssh/ca-config.c rules).
    @Suite("Host CAs")
    @MainActor
    struct HostCATests {
        init() throws {
            try TestCore.initialize()
        }

        @Test func editSaveLoadAndDelete() throws {
            let keyFile = SSHFixture.repositoryRoot.appending(path: "Core/tests/fixtures/userkey.pub")
            var beeps = 0
            let editor = HostCAEditor { beeps += 1 }
            let before = editor.names
            #expect(!editor.permitRSASHA1 && editor.permitRSASHA256 && editor.permitRSASHA512)

            editor.name = "SwiftPutty test CA"
            editor.readPublicKey(from: keyFile)
            #expect(editor.publicKey.hasPrefix("AAAAC3NzaC1lZDI1NTE5"))      // as a blob
            #expect(editor.keyInfo.hasPrefix("ssh-ed25519 255 SHA256:"))

            editor.save()
            #expect(editor.errorMessage == "No validity expression configured for this key")
            editor.errorMessage = nil
            editor.validity = "*.example.org &&"
            editor.save()
            #expect(editor.errorMessage?.hasPrefix("Error in expression: ") == true)
            #expect(editor.expressionErrorRange != nil)
            editor.errorMessage = nil
            editor.validity = "*.example.org"
            editor.save()
            #expect(editor.errorMessage == nil)
            #expect(editor.names == (before + ["SwiftPutty test CA"])
                .sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) })

            // Load it back into a fresh editor, selected by typing.
            let other = HostCAEditor()
            other.name = "SwiftPutty test CA"
            other.loadSelected()
            #expect(other.validity == "*.example.org")
            #expect(other.publicKey == editor.publicKey)

            other.deleteSelected()
            #expect(other.names == before)
            other.selectedIndex = nil
            other.deleteSelected()
            other.loadSelected()
            #expect(beeps == 0)                 // that editor's beep is a no-op
            editor.selectedIndex = nil
            editor.loadSelected()
            #expect(beeps == 1)
        }
    }
}
