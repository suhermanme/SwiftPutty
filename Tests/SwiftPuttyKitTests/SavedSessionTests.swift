import Foundation
import Persistence
import PuTTYBridge
import Testing

/// A store in a fresh temporary directory, removed afterwards.
struct TemporaryStore {
    let directory: URL
    let store: SavedSessionStore
    let secrets = InMemorySecretStore()

    init() {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "SwiftPuttyStore-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "SwiftPutty", directoryHint: .isDirectory)
        store = SavedSessionStore(fileURL: directory.appending(path: "Saved Sessions.json"),
                                  secrets: secrets)
    }

    var fileURL: URL { store.fileURL }

    func remove() {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: fileURL)
    }

    func contents() throws -> String {
        try String(contentsOf: fileURL, encoding: .utf8)
    }
}

extension KitTests {
@Suite("Saved sessions")
struct SavedSessionTests {
    init() throws {
        try TestCore.initialize()
    }

    @Test func anEmptyStoreListsDefaultSettingsAndLoadsPuTTYDefaults() throws {
        let t = TemporaryStore()
        defer { t.remove() }
        #expect(try t.store.sessionNames() == ["Default Settings"])
        let (settings, exists) = try t.store.load("Default Settings")
        #expect(!exists)
        #expect(settings == PuTTYSettings.defaults())
        #expect(try t.store.loadDefaults() == PuTTYSettings.defaults())
        // Reading never creates the file.
        #expect(!FileManager.default.fileExists(atPath: t.fileURL.path))
    }

    @Test func savesAndLoadsAsPuTTYDoes() throws {
        let t = TemporaryStore()
        defer { t.remove() }
        var settings = PuTTYSettings.defaults()
        settings["HostName"] = "example.org"
        settings["TermWidth"] = "132"
        settings["UnknownKeyword"] = "dropped"
        settings["ScrollbackLines"] = nil                 // filled in again
        try t.store.save(settings, as: "Production")

        let (loaded, exists) = try t.store.load("Production")
        #expect(exists)
        #expect(loaded["HostName"] == "example.org")
        #expect(loaded["TermWidth"] == "132")
        #expect(loaded["UnknownKeyword"] == nil)
        #expect(loaded["ScrollbackLines"] == "2000")
        #expect(loaded == settings.normalised())

        // A session that does not exist loads as PuTTY's built-in
        // defaults, not as "Default Settings".
        var defaults = PuTTYSettings.defaults()
        defaults["TermWidth"] = "100"
        try t.store.save(defaults, as: "")
        let (missing, missingExists) = try t.store.load("Nowhere")
        #expect(!missingExists)
        #expect(missing["TermWidth"] == "80")
        #expect(try t.store.loadDefaults()["TermWidth"] == "100")
    }

    @Test func listsDefaultSettingsFirstThenStrcmpOrder() throws {
        let t = TemporaryStore()
        defer { t.remove() }
        for name in ["beta", "Alpha", "alpha", "Zulu", "Ärger", "10.0.0.1", "Default Settings"] {
            try t.store.save(PuTTYSettings.defaults(), as: name)
        }
        // Byte order: digits, upper case, lower case, then non-ASCII.
        #expect(try t.store.sessionNames() ==
                ["Default Settings", "10.0.0.1", "Alpha", "Zulu", "alpha", "beta", "Ärger"])
    }

    @Test func anEmptyNameIsDefaultSettings() throws {
        let t = TemporaryStore()
        defer { t.remove() }
        var settings = PuTTYSettings.defaults()
        settings["TermHeight"] = "50"
        try t.store.save(settings, as: "")
        #expect(try t.store.sessionNames() == ["Default Settings"])
        #expect(try t.store.load("Default Settings").exists)
        #expect(try t.store.load("").settings["TermHeight"] == "50")
    }

    @Test func deletes() throws {
        let t = TemporaryStore()
        defer { t.remove() }
        try t.store.save(PuTTYSettings.defaults(), as: "one")
        try t.store.save(PuTTYSettings.defaults(), as: "two")
        try t.store.delete("one")
        try t.store.delete("never saved")
        #expect(try t.store.sessionNames() == ["Default Settings", "two"])
        #expect(try !t.store.load("one").exists)
    }

    // MARK: Proxy password (D-040)

    @Test func theProxyPasswordIsKeptOutOfTheFile() throws {
        let t = TemporaryStore()
        defer { t.remove() }
        var settings = PuTTYSettings.defaults()
        settings["ProxyMethod"] = "5"
        settings["ProxyPassword"] = "s3cret-proxy-pw"
        try t.store.save(settings, as: "via proxy")

        #expect(try !t.contents().contains("s3cret-proxy-pw"))
        #expect(t.secrets.all == ["via proxy": "s3cret-proxy-pw"])
        let (loaded, _) = try t.store.load("via proxy")
        #expect(loaded["ProxyPassword"] == "s3cret-proxy-pw")
        #expect(loaded == settings.normalised())

        // Saving without one removes it; so does deleting the session.
        settings["ProxyPassword"] = ""
        try t.store.save(settings, as: "via proxy")
        #expect(t.secrets.all.isEmpty)
        settings["ProxyPassword"] = "again"
        try t.store.save(settings, as: "via proxy")
        try t.store.delete("via proxy")
        #expect(t.secrets.all.isEmpty)
        // Default Settings is stored under its name, also for "".
        try t.store.save(settings, as: "")
        #expect(t.secrets.all == ["Default Settings": "again"])
        #expect(try t.store.loadDefaults()["ProxyPassword"] == "again")
    }

    @Test func aPasswordSavedInTheFileMovesToTheSecretStore() throws {
        let t = TemporaryStore()
        defer { t.remove() }
        try t.store.save(PuTTYSettings.defaults(), as: "old")
        // As a file written before D-040 holds it.
        let old = try t.contents().replacingOccurrences(of: "\"ProxyPassword\" : \"\"",
                                                        with: "\"ProxyPassword\" : \"from-the-file\"")
        #expect(old.contains("from-the-file"))
        try t.write(old)

        #expect(try t.store.load("old").settings["ProxyPassword"] == "from-the-file")
        #expect(t.secrets.all == ["old": "from-the-file"])
        #expect(try !t.contents().contains("from-the-file"))
        #expect(try t.store.load("old").settings["ProxyPassword"] == "from-the-file")
    }

    @Test func aSecretThatCannotBeSavedLeavesTheFileAlone() throws {
        struct Failing: SecretStore {
            func secret(for session: String) -> String? { nil }
            func setSecret(_ secret: String, for session: String) throws { throw SecretStoreError("locked") }
            func removeSecret(for session: String) throws {}
        }
        let t = TemporaryStore()
        defer { t.remove() }
        try t.store.save(PuTTYSettings.defaults(), as: "s")
        let before = try t.contents()
        let failing = SavedSessionStore(fileURL: t.fileURL, secrets: Failing())
        var settings = PuTTYSettings.defaults()
        settings["HostName"] = "changed"
        settings["ProxyPassword"] = "pw"
        #expect(throws: SavedSessionStoreError.secret(message: "locked")) {
            try failing.save(settings, as: "s")
        }
        #expect(try t.contents() == before)
    }

    /// The real keychain, under a service of its own that is removed again.
    @Test func keychainSecretStoreRoundTrip() throws {
        let keychain = KeychainSecretStore(service: "org.swiftputty.test.\(UUID().uuidString)")
        defer { try? keychain.removeSecret(for: "session") }
        #expect(keychain.secret(for: "session") == nil)
        try keychain.setSecret("first", for: "session")
        #expect(keychain.secret(for: "session") == "first")
        try keychain.setSecret("sëcond", for: "session")        // replaces
        #expect(keychain.secret(for: "session") == "sëcond")
        try keychain.removeSecret(for: "session")
        #expect(keychain.secret(for: "session") == nil)
        try keychain.removeSecret(for: "session")               // already gone
    }

    /// Damaged files (M13): 500 deterministic mutations of a real file.
    /// Each either loads or is reported; none crashes, and a file that
    /// cannot be read is never rewritten.
    @Test func mutatedFilesLoadOrAreReported() throws {
        let t = TemporaryStore()
        defer { t.remove() }
        var settings = PuTTYSettings.defaults()
        settings["HostName"] = "example.org"
        settings["PortForwardings"] = "L8080=localhost:80,R2222=host:22"
        settings["ProxyPassword"] = "pw"
        try t.store.save(settings, as: "one")
        try t.store.save(PuTTYSettings.defaults(), as: "two")
        let original = Array(try t.contents().utf8)
        let tokens = Array("{}[]\",:0-1e9\\u0000 truenull".utf8)

        var state: UInt64 = 0x9E3779B97F4A7C15
        func next(_ n: Int) -> Int {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Int(state % UInt64(max(n, 1)))
        }
        for _ in 0..<500 {
            var bytes = original
            for _ in 0..<(1 + next(6)) {
                let at = next(bytes.count)
                switch next(4) {
                case 0: bytes[at] = UInt8(truncatingIfNeeded: next(256))
                case 1: bytes.insert(tokens[next(tokens.count)], at: at)
                case 2: bytes.remove(at: at)
                default: bytes.removeSubrange(at..<min(bytes.count, at + next(40)))
                }
            }
            try t.write(String(decoding: bytes, as: UTF8.self))
            let before = try t.contents()
            do {
                for name in try t.store.sessionNames() {
                    _ = try t.store.load(name)
                }
            } catch is SavedSessionStoreError {
                #expect(try t.contents() == before)     // never rewritten
            }
        }
    }

    /// M13: a directory that cannot be written. Saving and deleting are
    /// reported; loading still works, and nothing is half-written.
    @Test func anUnwritableStoreIsReportedAndStillLoads() throws {
        let t = TemporaryStore()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: t.directory.path)
            t.remove()
        }
        var settings = PuTTYSettings.defaults()
        settings["HostName"] = "kept.example"
        try t.store.save(settings, as: "kept")
        let before = try t.contents()
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: t.directory.path)

        settings["HostName"] = "changed.example"
        #expect(throws: SavedSessionStoreError.self) { try t.store.save(settings, as: "kept") }
        #expect(throws: SavedSessionStoreError.self) { try t.store.delete("kept") }
        #expect(try t.store.load("kept").settings["HostName"] == "kept.example")
        #expect(try t.contents() == before)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: t.directory.path)
        #expect(leftovers == ["Saved Sessions.json"])
    }

    @Test func theFileIsPrivateAndReplacedAtomically() throws {
        let t = TemporaryStore()
        defer { t.remove() }
        try t.store.save(PuTTYSettings.defaults(), as: "s")
        try t.store.save(PuTTYSettings.defaults(), as: "t")
        let fileMode = try FileManager.default.attributesOfItem(atPath: t.fileURL.path)[.posixPermissions] as? Int
        let directoryMode = try FileManager.default.attributesOfItem(atPath: t.directory.path)[.posixPermissions] as? Int
        #expect(fileMode == 0o600)
        #expect(directoryMode == 0o700)
        // No temporary files are left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.directory.path) == ["Saved Sessions.json"])
    }

    @Test func theFormatIsVersionedAndDeterministic() throws {
        let t = TemporaryStore()
        defer { t.remove() }
        var settings = PuTTYSettings.defaults()
        settings["HostName"] = "host"
        try t.store.save(settings, as: "s")
        let first = try t.contents()
        try t.store.save(settings, as: "s")
        #expect(try t.contents() == first)

        let json = try JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any]
        #expect(json?["format"] as? String == "org.swiftputty.saved-sessions")
        #expect(json?["version"] as? Int == 1)
        let sessions = json?["sessions"] as? [String: [String: String]]
        #expect(sessions?["s"]?["HostName"] == "host")
        #expect(sessions?["s"]?.count == settings.values.count)
    }

    @Test func aNewerFileIsNeverOverwritten() throws {
        let t = TemporaryStore()
        defer { t.remove() }
        let newer = #"{"format":"org.swiftputty.saved-sessions","version":2,"sessions":{},"more":[]}"#
        try t.write(newer)
        #expect(throws: SavedSessionStoreError.newerFormat(path: t.fileURL.path, version: 2)) {
            try t.store.sessionNames()
        }
        #expect(throws: SavedSessionStoreError.self) {
            try t.store.save(PuTTYSettings.defaults(), as: "x")
        }
        #expect(throws: SavedSessionStoreError.self) { try t.store.delete("x") }
        #expect(try t.contents() == newer)
    }

    @Test func aDamagedFileIsReportedAndKept() throws {
        let t = TemporaryStore()
        defer { t.remove() }
        for damaged in ["not json", #"{"format":"something else","version":1,"sessions":{}}"#,
                        #"{"format":"org.swiftputty.saved-sessions","version":1,"sessions":{"s":3}}"#] {
            try t.write(damaged)
            let error = #expect(throws: SavedSessionStoreError.self) { try t.store.sessionNames() }
            if case .unreadable = error {} else { Issue.record("unexpected error \(String(describing: error))") }
            #expect(throws: SavedSessionStoreError.self) {
                try t.store.save(PuTTYSettings.defaults(), as: "x")
            }
            #expect(try t.contents() == damaged)
        }
    }

    @Test func settingsAreCodableAsAPlainKeywordMap() throws {
        var settings = PuTTYSettings()
        settings["HostName"] = "h"
        settings["WinTitle"] = "Ünïcödé ✓"
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode([String: String].self, from: data) == settings.values)
        #expect(try JSONDecoder().decode(PuTTYSettings.self, from: data) == settings)
    }
}
}
