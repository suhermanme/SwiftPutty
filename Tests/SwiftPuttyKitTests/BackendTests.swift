import Darwin
import Foundation
import PuTTYBridge
import SessionLayer
import ConfigurationUI
import Testing

extension KitTests {
    /// The other backends (M11): their configuration rules, and a serial
    /// session end to end, the line played by a pseudo-terminal.
    @Suite("Other backends")
    @MainActor
    struct BackendTests {
        init() throws {
            try TestCore.initialize()
        }

        @Test func connectionTypesMoveOnlyADefaultPort() {
            let storage = TemporaryStore()
            defer { storage.remove() }
            let model = ConfigurationModel(store: storage.store)
            #expect(model.port == 22)
            for (type, port) in [("telnet", 23), ("rlogin", 513), ("supdup", 95), ("raw", 0),
                                 ("serial", 0), ("ssh", 22)] {
                model.connectionType = type
                #expect(model.port == port, "\(type)")
            }
            model.port = 2323
            model.connectionType = "telnet"
            #expect(model.port == 2323)
        }

        @Test func aSerialSessionNeedsALine() {
            var settings = PuTTYSettings.defaults()
            settings["Protocol"] = "serial"
            settings["HostName"] = "example.org"
            #expect(!ConfigurationModel.isLaunchable(settings))
            settings["SerialLine"] = "/dev/cu.usbserial"
            #expect(ConfigurationModel.isLaunchable(settings))
        }

        @Test func stopBitsAreSavedInHalfBits() {
            #expect(ConfigurationModel.formatFixedPoint(2, denominator: 2) == "1")
            #expect(ConfigurationModel.formatFixedPoint(3, denominator: 2) == "1.5")
            #expect(ConfigurationModel.formatFixedPoint(4, denominator: 2) == "2")
            #expect(ConfigurationModel.parseFixedPoint("1.5", denominator: 2) == 3)
            #expect(ConfigurationModel.parseFixedPoint("2", denominator: 2) == 4)
            #expect(PuTTYSettings.defaults()["SerialStopHalfbits"] == "2")
        }

        @Test func serialDevicesAreTheCallOutDevices() throws {
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "spb-dev-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            for name in ["tty.usbserial-1", "cu.usbserial-1", "cu.Bluetooth-Incoming-Port", "null"] {
                FileManager.default.createFile(atPath: directory.appending(path: name).path, contents: nil)
            }
            #expect(ConfigurationModel.serialDevices(in: directory.path)
                    == [directory.path + "/cu.Bluetooth-Incoming-Port", directory.path + "/cu.usbserial-1"])
        }

        /// config.c: mid-session, the Serial and Telnet panels only for
        /// their own protocol; Rlogin and SUPDUP never.
        @Test func protocolPanelsMidSession() {
            let storage = TemporaryStore()
            defer { storage.remove() }
            #expect(ConfigurationCategory.allCases.allSatisfy(ConfigurationModel(store: storage.store).shows))
            for type in ["serial", "telnet", "rlogin", "supdup", "ssh"] {
                var running = PuTTYSettings.defaults()
                running["Protocol"] = type
                let model = ConfigurationModel(changing: running, protocolInfo: 0, store: storage.store)
                #expect(model.shows(.serial) == (type == "serial"), "\(type)")
                #expect(model.shows(.telnet) == (type == "telnet"), "\(type)")
                #expect(!model.shows(.rlogin) && !model.shows(.supdup))
            }
        }

        @Test func serialSessionThroughAPseudoTerminal() async throws {
            var master: Int32 = -1, slave: Int32 = -1
            var name = [CChar](repeating: 0, count: 128)
            try #require(openpty(&master, &slave, &name, nil, nil) == 0)
            defer { close(master); close(slave) }
            var raw = termios()
            tcgetattr(slave, &raw)
            cfmakeraw(&raw)
            tcsetattr(slave, TCSANOW, &raw)
            let line = String(cString: name)

            var settings = PuTTYSettings.defaults()
            settings["Protocol"] = "serial"
            settings["SerialLine"] = line
            settings["SerialSpeed"] = "38400"
            settings["SerialFlowControl"] = "0"
            let controller = SessionController(settings: settings)
            try controller.connect()
            #expect(await controller.waitForState(.connected, within: .seconds(10)) == .connected)
            #expect(controller.eventLog.contains { $0.text == "Opening serial device \(line)" })
            #expect(controller.eventLog.contains { $0.text == "Configuring baud rate 38400" })
            // The serial backend's Special Commands: Break.
            #expect(await waitUntil { controller.specials.allCommands.map(\.name) == ["Break"] })

            controller.send("hello line")
            var received = [UInt8](repeating: 0, count: 64)
            var got = Data()
            let deadline = ContinuousClock.now + .seconds(10)
            while !String(decoding: got, as: UTF8.self).contains("hello line") && ContinuousClock.now < deadline {
                var poller = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
                if poll(&poller, 1, 50) > 0 {
                    let n = read(master, &received, received.count)
                    if n > 0 { got.append(contentsOf: received[0..<n]) }
                }
                await Task.yield()
            }
            #expect(String(decoding: got, as: UTF8.self).contains("hello line"))

            controller.close()
            #expect(await controller.waitForState(.closed, within: .seconds(10)) == .closed)
        }
    }
}
