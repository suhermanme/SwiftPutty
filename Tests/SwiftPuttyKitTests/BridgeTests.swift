import Foundation
import Testing
@testable import PuTTYBridge

extension KitTests {
    @Suite("Bridge loading")
    struct BridgeLoadingTests {
        @Test func reportsPuTTYVersion() {
            #expect(PuTTYCore.version == "Release 0.85")
            #expect(PuTTYCore.sshVersionSuffix == "-Release-0.85")
        }

        @Test func bridgeAPIVersionMatchesHeader() {
            #expect(PuTTYCore.bridgeAPIVersion == PuTTYCore.expectedBridgeAPIVersion)
        }

        @Test func exposesUpstreamLicence() {
            let licence = PuTTYCore.licenceText
            #expect(licence.hasPrefix("PuTTY is copyright 1997-2026 Simon Tatham."))
            #expect(licence.contains("Permission is hereby granted, free of charge"))
            #expect(licence.contains("THE SOFTWARE IS PROVIDED \"AS IS\""))
            #expect(PuTTYCore.copyright.contains("Simon Tatham"))
        }
    }
}

extension KitTests {
    @Suite("Core lifecycle")
    struct CoreLifecycleTests {
        @Test func initializationIsIdempotentAndCreatesPrivateDirectory() throws {
            try TestCore.initialize()
            try TestCore.initialize()
            #expect(PuTTYCore.isInitialized)

            let attributes = try FileManager.default
                .attributesOfItem(atPath: TestCore.stateDirectory.path)
            #expect(attributes[.type] as? FileAttributeType == .typeDirectory)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        }

        @Test func rejectsADifferentStateDirectory() throws {
            try TestCore.initialize()
            let other = FileManager.default.temporaryDirectory
                .appending(path: "SwiftPuttyTests-other", directoryHint: .isDirectory)
            #expect(throws: PuTTYBridgeError.self) {
                try PuTTYCore.initialize(stateDirectory: other)
            }
        }

        @Test func rejectsNonFileURL() {
            #expect(throws: PuTTYBridgeError.self) {
                try PuTTYCore.initialize(stateDirectory: URL(string: "https://example.invalid/")!)
            }
        }
    }
}

extension KitTests {
    @Suite("Settings conversion")
    struct SettingsTests {
        @Test func defaultsMatchUpstream() {
            let defaults = PuTTYSettings.defaults()
            #expect(defaults["Protocol"] == "ssh")
            #expect(defaults["PortNumber"] == "22")
            #expect(defaults["HostName"] == "")
            #expect(defaults["TerminalType"] == "xterm")
            #expect(defaults["PortForwardings"] == "")
            #expect(defaults["FontName"] == "Menlo-Regular 12")
            #expect(defaults.values.count > 150)
        }

        @Test func normalisationCanonicalisesAndIsIdempotent() {
            var settings = PuTTYSettings()
            settings["HostName"] = "example.invalid"
            settings["Protocol"] = "ssh"
            settings["PortNumber"] = "2222"
            settings["PortForwardings"] = "L5432=10.0.0.15:5432,R8080=localhost:80,L1080=D"
            settings["NotAPuTTYKeyword"] = "x"

            let normalised = settings.normalised()
            #expect(normalised["HostName"] == "example.invalid")
            #expect(normalised["PortNumber"] == "2222")
            #expect(normalised["PortForwardings"] == "D1080=,L5432=10.0.0.15:5432,R8080=localhost:80")
            #expect(normalised["NotAPuTTYKeyword"] == nil)
            #expect(normalised.normalised() == normalised)
        }

        @Test func unicodeValuesRoundTrip() {
            var settings = PuTTYSettings.defaults()
            settings["WinTitle"] = "Сервер – 東京 🚀"
            settings["UserName"] = "zoë"
            let normalised = settings.normalised()
            #expect(normalised["WinTitle"] == "Сервер – 東京 🚀")
            #expect(normalised["UserName"] == "zoë")
        }

        @Test func sortedKeywordsAreByteOrdered() {
            let keys = PuTTYSettings.defaults().sortedKeywords
            #expect(keys == keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })
            #expect(keys.first == keys.min { $0.utf8.lexicographicallyPrecedes($1.utf8) })
        }

        @Test func conversionDoesNotLeakBridgeObjects() {
            let before = PuTTYCore.liveSettingsObjectCount
            for _ in 0..<200 {
                _ = PuTTYSettings.defaults().normalised()
            }
            #expect(PuTTYCore.liveSettingsObjectCount == before)
        }
    }
}

extension KitTests {
    @Suite("Session lifecycle")
    struct SessionLifecycleTests {
        @Test func createAndDestroyRepeatedly() throws {
            try TestCore.initialize()
            var settings = PuTTYSettings.defaults()
            settings["HostName"] = "host.invalid"

            var lastID: UInt64 = 0
            for _ in 0..<10_000 {
                let session = try PuTTYSession(settings: settings)
                #expect(session.id > lastID)
                lastID = session.id
            }
            // Teardown after release runs on the core thread.
            #expect(PuTTYCore.waitForPendingWork())
            #expect(PuTTYCore.liveSessionCount == 0)
        }

        @Test func manySessionsAliveAtOnce() throws {
            try TestCore.initialize()
            let settings = PuTTYSettings.defaults()
            var sessions = try (0..<500).map { _ in try PuTTYSession(settings: settings) }
            #expect(PuTTYCore.liveSessionCount == 500)
            #expect(Set(sessions.map(\.id)).count == 500)
            sessions.shuffle()
            sessions.removeAll()
            #expect(PuTTYCore.waitForPendingWork())
            #expect(PuTTYCore.liveSessionCount == 0)
        }

        @Test func sessionKeepsItsConfiguration() throws {
            try TestCore.initialize()
            var settings = PuTTYSettings.defaults()
            settings["HostName"] = "db.internal"
            settings["PortForwardings"] = "4L127.0.0.1:5432=10.0.0.15:5432"
            let session = try PuTTYSession(settings: settings)
            let current = session.currentSettings
            #expect(current["HostName"] == "db.internal")
            #expect(current["PortForwardings"] == "4L127.0.0.1:5432=10.0.0.15:5432")
            #expect(current == settings.normalised())
        }

        @Test func eventStreamFinishesAfterRelease() async throws {
            try TestCore.initialize()
            var session: PuTTYSession? = try PuTTYSession(settings: .defaults())
            let events = session!.events
            session = nil
            // The terminal may publish its first frame before the release;
            // nothing else can happen to a session that never started.
            var received: [PuTTYSessionEvent] = []
            for await event in events { received.append(event) }
            #expect(received.allSatisfy { $0 == .terminalUpdated })
        }
    }
}
