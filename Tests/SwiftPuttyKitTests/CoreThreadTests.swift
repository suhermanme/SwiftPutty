import Foundation
import Testing
@testable import PuTTYBridge
import TestServers

extension KitTests {
    @Suite("Core thread")
    struct CoreThreadTests {
        @Test func coreThreadIsNotTheCaller() throws {
            try TestCore.initialize()
            #expect(!PuTTYCore.isCoreThread)
            // The second wait runs in a later loop iteration than the
            // first, so at least one iteration has completed.
            let before = PuTTYCore.coreLoopIterations
            #expect(PuTTYCore.waitForPendingWork())
            #expect(PuTTYCore.waitForPendingWork())
            #expect(PuTTYCore.coreLoopIterations > before)
        }

        @Test func idleLoopDoesNotSpin() async throws {
            try TestCore.initialize()
            PuTTYCore.waitForPendingWork()
            let start = PuTTYCore.coreLoopIterations
            try await Task.sleep(for: .milliseconds(300))
            #expect(PuTTYCore.coreLoopIterations - start <= 2)
        }
    }
}

extension KitTests {
    @Suite("Raw sessions")
    struct RawSessionTests {
        @Test func echoRoundTrip() async throws {
            try TestCore.initialize()
            let server = try LoopbackServer(.echo)
            defer { server.stop() }

            var session: PuTTYSession? = try PuTTYSession(settings: rawSettings(port: server.port))
            let collector = EventCollector(session!.events)
            session!.start()
            #expect(await collector.wait(for: .connected))
            session!.send("héllo, 世界\n")
            #expect(await collector.wait { $0.output.count >= "héllo, 世界\n".utf8.count })
            #expect(String(decoding: collector.output, as: UTF8.self) == "héllo, 世界\n")
            #expect(collector.states == [.connecting, .connected])
            #expect(collector.eventLog.contains { $0.contains("Connected to 127.0.0.1") })

            session!.close()
            #expect(await collector.wait(for: .closed))
            #expect(collector.lastDetail == "Session closed by user")

            session = nil
            #expect(await collector.waitForFinish())
        }

        @Test func remoteCloseReportsExitThenClosed() async throws {
            try TestCore.initialize()
            let server = try LoopbackServer(.greetAndClose("bye\n"))
            defer { server.stop() }

            let session = try PuTTYSession(settings: rawSettings(port: server.port))
            let collector = EventCollector(session.events)
            session.start()
            #expect(await collector.wait(for: .closed))
            #expect(String(decoding: collector.output, as: UTF8.self) == "bye\n")
            let tail = collector.events.suffix(2)
            #expect(tail.first == .remoteExit(code: 0))
            #expect(collector.states.last == .closed)
        }

        @Test func refusedConnectionFails() async throws {
            try TestCore.initialize()
            let session = try PuTTYSession(settings: rawSettings(port: LoopbackServer.unusedPort()))
            let collector = EventCollector(session.events)
            session.start()
            #expect(await collector.wait(for: .failed))
            #expect(collector.lastDetail?.contains("refused") == true)
            #expect(collector.states == [.connecting, .failed])
        }

        @Test func unknownHostFails() async throws {
            try TestCore.initialize()
            let session = try PuTTYSession(settings: rawSettings(host: "no-such-host.invalid", port: 9))
            let collector = EventCollector(session.events)
            session.start()
            #expect(await collector.wait(for: .failed))
            #expect(collector.lastDetail?.hasPrefix("Unable to open connection to no-such-host.invalid") == true)
        }

        @Test func sshIsNotAvailableYet() async throws {
            try TestCore.initialize()
            var settings = PuTTYSettings.defaults()
            settings["HostName"] = "127.0.0.1"
            let session = try PuTTYSession(settings: settings)
            let collector = EventCollector(session.events)
            session.start()
            #expect(await collector.wait(for: .failed))
            #expect(collector.states == [.failed])
            #expect(collector.lastDetail?.contains("M04") == true)
        }

        @Test func callbacksRunOnTheCoreThreadNotTheMainThread() async throws {
            try TestCore.initialize()
            let server = try LoopbackServer(.echo)
            defer { server.stop() }
            let session = try PuTTYSession(settings: rawSettings(port: server.port))
            let collector = EventCollector(session.events)
            await MainActor.run { session.start() }
            #expect(await collector.wait(for: .connected))
            // The main thread was never needed for the connection.
            #expect(!PuTTYCore.isCoreThread)
        }

        @Test func manyConcurrentSessions() async throws {
            try TestCore.initialize()
            let server = try LoopbackServer(.echo)
            defer { server.stop() }
            let fdsBefore = PuTTYCore.watchedDescriptorCount

            try await withThrowingTaskGroup(of: Bool.self) { group in
                for index in 0..<100 {
                    group.addTask {
                        let session = try PuTTYSession(settings: rawSettings(port: server.port))
                        let collector = EventCollector(session.events)
                        let payload = "session \(index) payload\n"
                        session.start()
                        session.send(payload)
                        let ok = await collector.wait { $0.output.count >= payload.utf8.count }
                        return ok && String(decoding: collector.output, as: UTF8.self) == payload
                    }
                }
                for try await ok in group { #expect(ok) }
            }

            #expect(PuTTYCore.waitForPendingWork())
            #expect(PuTTYCore.liveSessionCount == 0)
            #expect(PuTTYCore.watchedDescriptorCount == fdsBefore)
        }

        @Test func largeTransferIsIntact() async throws {
            try TestCore.initialize()
            let server = try LoopbackServer(.echo)
            defer { server.stop() }
            let session = try PuTTYSession(settings: rawSettings(port: server.port))
            let collector = EventCollector(session.events)
            session.start()
            #expect(await collector.wait(for: .connected))

            // Printable text: the terminal answers some control sequences,
            // and the echoed answers would add to the output.
            var generator = SystemRandomNumberGenerator()
            let payload = Data((0..<(2 << 20)).map { index in
                index % 80 == 79 ? 0x0A : UInt8.random(in: 0x21...0x7E, using: &generator)
            })
            stride(from: 0, to: payload.count, by: 64 << 10).forEach {
                session.send(payload[$0..<min($0 + (64 << 10), payload.count)])
            }
            #expect(await collector.wait(timeout: .seconds(60)) { $0.output.count >= payload.count })
            #expect(collector.output == payload)
        }
    }
}
