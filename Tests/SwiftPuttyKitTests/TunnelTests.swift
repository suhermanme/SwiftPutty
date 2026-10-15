import AppKit
import ConfigurationUI
import Darwin
import Foundation
import PuTTYBridge
import SessionLayer
import TestServers
import Testing

/// Sends `text` to 127.0.0.1:port and returns what comes back (nil if the
/// connection is refused or nothing arrives).
private func echo(through port: Int, _ text: String) async -> String? {
    await Task.detached {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }
        let bytes = Array(text.utf8)
        guard write(fd, bytes, bytes.count) == bytes.count else { return nil }
        var buffer = [UInt8](repeating: 0, count: bytes.count)
        var got = 0
        while got < bytes.count {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, bytes.count - got) }
            if n <= 0 { return nil }
            got += n
        }
        return String(decoding: buffer, as: UTF8.self)
    }.value
}

extension KitTests {
@Suite("Port forwarding")
@MainActor
struct TunnelTests {
    init() throws {
        try TestCore.initialize()
    }

    // MARK: Saved format

    @Test func readsAndWritesPuTTYsSavedFormat() {
        let saved = "L8080=localhost:80,D1080=,4R2222=host:22,L127.0.0.1:9000=a\\=b:1"
        let forwardings = PuTTYSettings.parsePortForwardings(saved)
        #expect(forwardings == [
            PortForwarding(key: "L8080", value: "localhost:80"),
            PortForwarding(key: "L1080", value: "D"),
            PortForwarding(key: "4R2222", value: "host:22"),
            PortForwarding(key: "L127.0.0.1:9000", value: "a=b:1"),
        ])
        #expect(PuTTYSettings.formatPortForwardings(forwardings) == saved)

        // As PuTTY itself reads and writes them.
        var settings = PuTTYSettings.defaults()
        settings.portForwardings = forwardings
        #expect(Set(settings.normalised().portForwardings) == Set(forwardings))

        let dynamic = forwardings[1]
        #expect(dynamic.kind == .dynamic && dynamic.displayKey == "D1080" && dynamic.source == "1080")
        let remote = forwardings[2]
        #expect(remote.kind == .remote && remote.family == .ipv4 && remote.source == "2222")
        #expect(remote.destination == "host:22")
        #expect(forwardings[3].source == "127.0.0.1:9000")
    }

    @Test func remoteListeningAddressesAsPuTTYRequestsThem() {
        let r = PortForwarding(key: "R8080", value: "x:1")
        let r4 = PortForwarding(key: "4R8080", value: "y:2")
        #expect(r.remoteListenAddress(acceptAll: false) == "localhost:8080")
        #expect(r.remoteListenAddress(acceptAll: false) == r4.remoteListenAddress(acceptAll: false))
        #expect(r.remoteListenAddress(acceptAll: true) == ":8080")
        #expect(PortForwarding(key: "R10.0.0.1:80", value: "x:1").remoteListenAddress(acceptAll: false)
            == "10.0.0.1:80")
        #expect(PortForwarding(key: "L8080", value: "x:1").remoteListenAddress(acceptAll: false) == nil)
    }

    // MARK: The Tunnels panel (config.c portfwd_handler)

    @Test func addAndRemoveAsPuTTY() {
        let storage = TemporaryStore()
        defer { storage.remove() }
        var beeps = 0
        let model = ConfigurationModel(store: storage.store) { beeps += 1 }

        model.addForwarding()
        #expect(model.errorMessage == "You need to specify a source port number")
        model.errorMessage = nil
        model.tunnelSource = "8080"
        model.tunnelDestination = "nohost"
        model.addForwarding()
        #expect(model.errorMessage?.hasPrefix("You need to specify a destination address") == true)
        model.errorMessage = nil

        model.tunnelDestination = "localhost:80"
        model.addForwarding()
        #expect(model.forwardings == [PortForwarding(key: "L8080", value: "localhost:80")])
        model.addForwarding()
        #expect(model.errorMessage == "Specified forwarding already exists")
        model.errorMessage = nil

        model.tunnelKind = .dynamic
        model.tunnelSource = "1080"
        model.addForwarding()
        model.tunnelKind = .remote
        model.tunnelFamily = .ipv4
        model.tunnelSource = "2222"
        model.tunnelDestination = "localhost:22"
        model.addForwarding()
        #expect(model.settings["PortForwardings"] == "D1080=,4R2222=localhost:22,L8080=localhost:80"
            || model.forwardings.count == 3)
        #expect(model.forwardings.map(\.displayKey) == ["4R2222", "D1080", "L8080"])

        // SwiftPutty's check: a second remote forwarding on that port.
        model.tunnelFamily = .any
        model.addForwarding()
        #expect(model.errorMessage == "A remote forwarding from that server port already exists")
        model.errorMessage = nil

        // Remove fills in the fields with what was removed.
        model.removeForwarding()
        #expect(beeps == 1)                              // nothing selected
        model.selectedForwarding = PortForwarding(key: "L8080", value: "localhost:80")
        model.removeForwarding()
        #expect(model.tunnelKind == .local && model.tunnelSource == "8080")
        #expect(model.tunnelDestination == "localhost:80" && model.tunnelFamily == .any)
        #expect(model.forwardings.count == 2)
    }

    @Test func removeThenAddIsRecordedAsAnEdit() {
        let storage = TemporaryStore()
        defer { storage.remove() }
        var running = PuTTYSettings.defaults()
        running["PortForwardings"] = "L8080=localhost:80"
        let model = ConfigurationModel(changing: running, protocolInfo: 2, store: storage.store)
        let old = PortForwarding(key: "L8080", value: "localhost:80")
        model.selectedForwarding = old
        model.removeForwarding()
        model.tunnelSource = "8081"
        model.addForwarding()
        let first = PortForwarding(key: "L8081", value: "localhost:80")
        #expect(model.tunnelEdits == [PortForwardingEdit(old: old, new: first)])

        // Editing the result again continues the same edit.
        model.selectedForwarding = first
        model.removeForwarding()
        model.tunnelSource = "8082"
        model.addForwarding()
        #expect(model.tunnelEdits == [PortForwardingEdit(old: old, new: PortForwarding(key: "L8082",
                                                                                         value: "localhost:80"))])
        // A plain add is not an edit.
        model.tunnelSource = "9000"
        model.addForwarding()
        #expect(model.tunnelEdits.count == 1)
    }

    // MARK: Staged edits on a live SSH session (docs/ARCHITECTURE.md 6.4)

    private func loggedIn() async throws -> SSHTerminal {
        let ssh = try SSHTerminal(userName: "tester", keyboardInteractive: false)
        let prompt = try #require(await ssh.waitForPrompt())
        ssh.controller.answer(prompt, with: .acceptOnce)
        #expect(await ssh.waitForScreen("tester@127.0.0.1's password:"))
        ssh.typeLine("weasel")
        #expect(await ssh.controller.waitForState(.connected, within: .seconds(30)) == .connected)
        return ssh
    }

    private func apply(_ ssh: SSHTerminal, _ forwardings: [PortForwarding],
                       edits: [PortForwardingEdit] = []) async throws {
        let running = try #require(await ssh.controller.beginChangeSettings())
        var settings = running.settings
        settings.portForwardings = forwardings
        #expect(await ssh.controller.applyChangeSettings(settings, portForwardingEdits: edits) == nil)
    }

    private func local(_ port: Int, to target: UInt16) -> PortForwarding {
        PortForwarding(key: "L\(port)", value: "127.0.0.1:\(target)")
    }

    @Test func movingALocalForwardingToATakenPortKeepsTheOldOne() async throws {
        let echoServer = try LoopbackServer(.echo)
        let busy = try LoopbackServer(.echo)
        defer { echoServer.stop(); busy.stop() }
        let ssh = try await loggedIn()
        defer { ssh.close() }
        let transport = try #require(ssh.controller.session).transportID

        let first = local(Int(try LoopbackServer.unusedPort()), to: echoServer.port)
        try await apply(ssh, [first])
        #expect(ssh.controller.portForwardStatuses[first]?.state == .listening)
        let firstPort = Int(first.source)!
        #expect(await echo(through: firstPort, "one") == "one")

        // Make before break: the new one fails, so the old one stays.
        let taken = local(Int(busy.port), to: echoServer.port)
        try await apply(ssh, [taken], edits: [PortForwardingEdit(old: first, new: taken)])
        #expect(ssh.controller.lastPortForwardingReport.keptPrevious.map(\.edit.new) == [taken])
        #expect(ssh.controller.lastPortForwardingReport.message.contains("could not be set up"))
        #expect(ssh.controller.settings.portForwardings == [first])
        #expect(await echo(through: firstPort, "still") == "still")

        // To a free port: the new one comes up and the old one goes.
        let moved = local(Int(try LoopbackServer.unusedPort()), to: echoServer.port)
        try await apply(ssh, [moved], edits: [PortForwardingEdit(old: first, new: moved)])
        #expect(ssh.controller.lastPortForwardingReport.isEmpty)
        #expect(ssh.controller.settings.portForwardings == [moved])
        #expect(await echo(through: Int(moved.source)!, "moved") == "moved")
        #expect(await echo(through: firstPort, "gone") == nil)
        #expect(ssh.controller.portForwardStatuses[first] == nil)

        // Same port, new destination: replaced in place.
        let other = try LoopbackServer(.echo)
        defer { other.stop() }
        let redirected = local(Int(moved.source)!, to: other.port)
        try await apply(ssh, [redirected], edits: [PortForwardingEdit(old: moved, new: redirected)])
        #expect(ssh.controller.lastPortForwardingReport.isEmpty)
        #expect(ssh.controller.portForwardStatuses[redirected]?.state == .listening)
        #expect(await echo(through: Int(redirected.source)!, "other") == "other")

        #expect(ssh.controller.session?.transportID == transport)
        #expect(ssh.controller.state == .connected)
    }

    @Test func remoteForwardingStatusIsLive() async throws {
        let echoServer = try LoopbackServer(.echo)
        defer { echoServer.stop() }
        let ssh = try await loggedIn()
        defer { ssh.close() }
        let port = Int(try LoopbackServer.unusedPort())
        let remote = PortForwarding(key: "R\(port)", value: "127.0.0.1:\(echoServer.port)")
        try await apply(ssh, [remote])
        #expect(await waitUntil { ssh.controller.portForwardStatuses[remote]?.state == .remoteEnabled })
        #expect(await echo(through: port, "remote") == "remote")

        // A move to another server port, staged.
        let other = Int(try LoopbackServer.unusedPort())
        let moved = PortForwarding(key: "R\(other)", value: remote.value)
        try await apply(ssh, [moved], edits: [PortForwardingEdit(old: remote, new: moved)])
        #expect(ssh.controller.lastPortForwardingReport.isEmpty)
        #expect(await waitUntil { ssh.controller.portForwardStatuses[remote] == nil })
        #expect(ssh.controller.portForwardStatuses[moved]?.state == .remoteEnabled)
        #expect(await echo(through: other, "moved") == "moved")
    }
}
}
