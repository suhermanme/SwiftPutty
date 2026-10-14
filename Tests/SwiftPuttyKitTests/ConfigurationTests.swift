import ConfigurationUI
import Foundation
import Persistence
import PuTTYBridge
import Testing

extension KitTests {
@Suite("Configuration dialog")
@MainActor
struct ConfigurationTests {
    /// The model, its store, and how often it beeped.
    @MainActor
    final class Fixture {
        let storage = TemporaryStore()
        var beeps = 0
        lazy var model = ConfigurationModel(store: storage.store) { [unowned self] in beeps += 1 }

        deinit { storage.remove() }

        func save(_ name: String, host: String) throws {
            var settings = PuTTYSettings.defaults()
            settings["HostName"] = host
            try storage.store.save(settings, as: name)
        }
    }

    init() throws {
        try TestCore.initialize()
    }

    @Test func everyPanelKeywordIsOnePuTTYSaves() {
        let defaults = PuTTYSettings.defaults()
        for keyword in PuTTYKeyword.allCases {
            #expect(defaults[keyword.rawValue] != nil, "\(keyword.rawValue) is not a PuTTY keyword")
        }
    }

    @Test func startsFromDefaultSettings() throws {
        let f = Fixture()
        var defaults = PuTTYSettings.defaults()
        defaults["TermWidth"] = "100"
        try f.storage.store.save(defaults, as: "")
        try f.save("other", host: "h")
        #expect(f.model.settings["TermWidth"] == "100")
        #expect(f.model.sessionNames == ["Default Settings", "other"])
        #expect(f.model.savedSessionName == "")
        #expect(f.model.selectedSessionIndex == nil)
    }

    @Test func changingTheProtocolMovesOnlyADefaultPort() {
        let f = Fixture()
        #expect(f.model.connectionType == "ssh")
        #expect(f.model.port == 22)
        f.model.connectionType = "raw"
        #expect(f.model.port == 0)                     // shown blank, as PuTTY
        f.model.connectionType = "ssh"
        #expect(f.model.port == 22)
        f.model.port = 2222
        f.model.connectionType = "raw"
        #expect(f.model.port == 2222)                  // a chosen port is kept
        #expect(f.model.settings["PortNumber"] == "2222")
    }

    @Test func typingASessionNameSelectsLikePuTTY() throws {
        let f = Fixture()
        for name in ["alpha", "beta", "gamma"] { try f.save(name, host: name) }
        // ["Default Settings", "alpha", "beta", "gamma"]
        f.model.setSavedSessionName("beta")
        #expect(f.model.selectedSessionIndex == 2)
        f.model.setSavedSessionName("b")
        #expect(f.model.selectedSessionIndex == 2)     // first entry >= "b"
        f.model.setSavedSessionName("zzz")
        #expect(f.model.selectedSessionIndex == 3)     // past the end: the last
        f.model.setSavedSessionName("")
        #expect(f.model.selectedSessionIndex == 0)
    }

    @Test func savesUnderTheTypedNameOrTheSelectedSession() throws {
        let f = Fixture()
        f.model.setString(.hostName, "first.example")
        f.model.setSavedSessionName("work")
        f.model.save()
        #expect(f.model.sessionNames == ["Default Settings", "work"])
        #expect(f.model.selectedSessionIndex == 1)
        #expect(try f.storage.store.load("work").settings["HostName"] == "first.example")

        // An empty name saves over the selected session.
        f.model.setSavedSessionName("")
        f.model.selectedSessionIndex = 1
        f.model.setString(.hostName, "second.example")
        f.model.save()
        #expect(f.model.savedSessionName == "work")
        #expect(try f.storage.store.load("work").settings["HostName"] == "second.example")

        // ... and with "Default Settings" selected, saves the defaults.
        f.model.setSavedSessionName("")
        f.model.selectedSessionIndex = 0
        f.model.setString(.termWidth, "99")
        f.model.save()
        #expect(f.model.savedSessionName == "")
        #expect(try f.storage.store.loadDefaults()["TermWidth"] == "99")
        #expect(f.beeps == 0)

        // Nothing typed, nothing selected: a beep.
        f.model.setSavedSessionName("")
        f.model.selectedSessionIndex = nil
        f.model.save()
        #expect(f.beeps == 1)
    }

    @Test func loadsTheSelectedSession() throws {
        let f = Fixture()
        try f.save("server", host: "server.example")
        #expect(!f.model.loadSelectedSession())
        #expect(f.beeps == 1)

        f.model.selectedSessionIndex = 1
        #expect(f.model.loadSelectedSession())
        #expect(f.model.settings["HostName"] == "server.example")
        #expect(f.model.savedSessionName == "server")
        #expect(f.model.selectedSessionIndex == 1)

        f.model.selectedSessionIndex = 0
        #expect(f.model.loadSelectedSession())
        #expect(f.model.settings["HostName"] == "")
        #expect(f.model.savedSessionName == "")        // Default Settings: blank
    }

    @Test func deletesButNeverDefaultSettings() throws {
        let f = Fixture()
        try f.save("a", host: "a")
        try f.save("b", host: "b")
        f.model.selectedSessionIndex = 0
        f.model.deleteSelectedSession()
        #expect(f.beeps == 1)
        f.model.selectedSessionIndex = nil
        f.model.deleteSelectedSession()
        #expect(f.beeps == 2)

        f.model.selectedSessionIndex = 1
        f.model.deleteSelectedSession()
        #expect(f.model.sessionNames == ["Default Settings", "b"])
        #expect(f.model.selectedSessionIndex == nil)
        #expect(try f.storage.store.sessionNames() == ["Default Settings", "b"])
    }

    @Test func doubleClickOpensOnlyASavedSessionWithAHost() throws {
        let f = Fixture()
        try f.save("server", host: "server.example")
        try f.save("empty", host: "")
        // ["Default Settings", "empty", "server"]
        f.model.selectedSessionIndex = 0
        #expect(f.model.openSessionFromList() == nil)
        f.model.selectedSessionIndex = 1
        #expect(f.model.openSessionFromList() == nil)
        #expect(f.model.savedSessionName == "empty")   // still loaded
        f.model.selectedSessionIndex = 2
        #expect(f.model.openSessionFromList()?["HostName"] == "server.example")
        #expect(f.beeps == 0)
    }

    @Test func openNeedsADestination() throws {
        let f = Fixture()
        #expect(f.model.open() == nil)
        #expect(f.beeps == 1)
        f.model.setString(.hostName, "typed.example")
        #expect(f.model.open()?["HostName"] == "typed.example")

        // Serial sessions need a line instead.
        #expect(ConfigurationModel.isLaunchable(PuTTYSettings(values: ["Protocol": "serial",
                                                                       "HostName": "x"])) == false)
        #expect(ConfigurationModel.isLaunchable(PuTTYSettings(values: ["Protocol": "serial",
                                                                       "SerialLine": "/dev/cu.x"])))
    }

    @Test func openWithNoHostUsesTheFocusedListSelection() throws {
        let f = Fixture()
        try f.save("server", host: "server.example")
        f.model.selectedSessionIndex = 1

        // The list did not have the focus: Open just beeps.
        #expect(f.model.open() == nil)
        #expect(f.beeps == 1)

        f.model.sessionListWasLastFocused = true
        #expect(f.model.open()?["HostName"] == "server.example")
        #expect(f.model.settings["HostName"] == "server.example")

        // Default Settings selected: not launched.
        f.model.setString(.hostName, "")
        f.model.selectedSessionIndex = 0
        #expect(f.model.open() == nil)
        #expect(f.beeps == 2)
        // A typed host wins over the list.
        f.model.setString(.hostName, "typed.example")
        f.model.selectedSessionIndex = 1
        #expect(f.model.open()?["HostName"] == "typed.example")
    }

    @Test func keepalivesAreSavedAsMinutesAndSeconds() {
        let f = Fixture()
        f.model.keepaliveSeconds = 150
        #expect(f.model.settings["PingInterval"] == "2")
        #expect(f.model.settings["PingIntervalSecs"] == "30")
        #expect(f.model.settings.normalised()["PingIntervalSecs"] == "30")
        #expect(f.model.keepaliveSeconds == 150)
    }

    @Test func storeErrorsAreReported() throws {
        let storage = TemporaryStore()
        defer { storage.remove() }
        try storage.write("damaged")
        let model = ConfigurationModel(store: storage.store)
        #expect(model.errorMessage?.contains("cannot be read") == true)
        #expect(model.settings == PuTTYSettings.defaults())
        #expect(model.sessionNames == ["Default Settings"])
        model.errorMessage = nil
        model.setSavedSessionName("x")
        model.save()
        #expect(model.errorMessage != nil)
        #expect(try storage.contents() == "damaged")
    }

    @Test func numericKeypadIsOneRadioOverTwoKeywords() {
        let f = Fixture()
        #expect(f.model.numericKeypadMode == 0)
        f.model.numericKeypadMode = 2
        #expect(f.model.settings["NetHackKeypad"] == "1" && f.model.settings["ApplicationKeypad"] == "0")
        f.model.numericKeypadMode = 1
        #expect(f.model.settings["NetHackKeypad"] == "0" && f.model.settings["ApplicationKeypad"] == "1")
        #expect(f.model.numericKeypadMode == 1)
    }

    @Test func coloursAreRGBTriplesClampedLikePuTTY() {
        let f = Fixture()
        #expect(ConfigurationModel.colourNames.count == 22)
        #expect(f.model.colour(0) == (187, 187, 187))             // Default Foreground
        #expect(f.model.colour(5) == (0, 255, 0))                 // Cursor Colour
        f.model.setColour(8, red: 300, green: -5, blue: 17)
        #expect(f.model.settings["Colour8"] == "255,0,17")
        #expect(f.model.settings.normalised()["Colour8"] == "255,0,17")
    }

    @Test func characterClassesAreSetInGroupsOf32() {
        let f = Fixture()
        #expect(f.model.characterClass(Int(UInt8(ascii: "a"))) == 2)
        #expect(f.model.characterClass(Int(UInt8(ascii: " "))) == 0)
        f.model.setCharacterClass([45, 46, 47], to: "2")           // - . /
        #expect(f.model.characterClass(46) == 2)
        #expect(f.model.settings["Wordness32"]?.split(separator: ",").count == 32)
        let normalised = f.model.settings.normalised()
        #expect(normalised["Wordness32"] == f.model.settings["Wordness32"])
    }

    @Test func bellOverloadTimesAreMicrosecondsShownAsSeconds() {
        let f = Fixture()
        #expect(f.model.seconds(.bellOverloadT) == "2")
        f.model.setSeconds(.bellOverloadT, "2.5")
        #expect(f.model.settings["BellOverloadT"] == "2500000")
        #expect(f.model.seconds(.bellOverloadT) == "2.5")
        #expect(f.model.settings.normalised()["BellOverloadT"] == "2500000")
        #expect(ConfigurationModel.formatFixedPoint(1_250, denominator: 1_000_000) == "0.00125")
        #expect(ConfigurationModel.parseFixedPoint("x", denominator: 1_000_000) == 0)
    }

    @Test func metaKeySettingsAreSaved() throws {
        // Upstream saves these only with OSX_META_KEY_CONFIG (unix/platform.h).
        let f = Fixture()
        f.model.setBool(.osxOptionMeta, false)
        f.model.setBool(.osxCommandMeta, true)
        f.model.setSavedSessionName("meta")
        f.model.save()
        let loaded = try f.storage.store.load("meta").settings
        #expect(loaded["OSXOptionMeta"] == "0" && loaded["OSXCommandMeta"] == "1")
    }

    @Test func characterSetsArePuTTYs() {
        #expect(PuTTYSettings.characterSets.first == "UTF-8")
        #expect(PuTTYSettings.characterSets.contains("ISO-8859-15"))
        #expect(PuTTYSettings.canonicalCharacterSet("") == "UTF-8")
        #expect(PuTTYSettings.canonicalCharacterSet("KOI8-R") == "KOI8-R")
    }

    @Test func atoiIsCs() {
        #expect(ConfigurationModel.atoi("") == 0)
        #expect(ConfigurationModel.atoi(" 42abc") == 42)
        #expect(ConfigurationModel.atoi("-7") == -7)
        #expect(ConfigurationModel.atoi("x1") == 0)
        #expect(ConfigurationModel.atoi("99999999999999") == Int(Int32.max))
    }

    @Test func preparedSettingsSplitUserAndHost() {
        var settings = PuTTYSettings.defaults()
        settings["HostName"] = " me@example.org:2222 "
        let prepared = settings.preparedForSession()
        #expect(prepared["HostName"] == "example.org")
        #expect(prepared["UserName"] == "me")
        #expect(prepared["PortNumber"] == "22")         // the suffix is discarded
    }
}
}
