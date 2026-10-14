import Foundation
import Persistence
import PuTTYBridge
import Testing

/// A store in a fresh temporary directory, removed afterwards.
struct TemporaryStore {
    let directory: URL
    let store: SavedSessionStore

    init() {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "SwiftPuttyStore-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "SwiftPutty", directoryHint: .isDirectory)
        store = SavedSessionStore(fileURL: directory.appending(path: "Saved Sessions.json"))
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
