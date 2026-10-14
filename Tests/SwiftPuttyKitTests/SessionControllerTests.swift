import Foundation
import PuTTYBridge
import SessionLayer
import TestServers
import Testing

@MainActor
private func rawController(port: UInt16) -> SessionController {
    SessionController(settings: rawSettings(port: port))
}

private func waitUntil(timeout: Duration = .seconds(30),
                       _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while await !condition() {
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

extension KitTests {
@Suite("Session controller")
@MainActor
struct SessionControllerTests {
    init() throws {
        try TestCore.initialize()
    }

    @Test func connectsEchoesAndCloses() async throws {
        let server = try LoopbackServer(.echo)
        defer { server.stop() }

        let controller = rawController(port: server.port)
        #expect(controller.state == .created)
        try controller.connect()
        #expect(await controller.waitForState(.connected) == .connected)
        #expect(controller.sessionID != nil)

        controller.send("ping\n")
        #expect(await waitUntil { controller.transcript.count >= 5 })
        #expect(String(decoding: controller.transcript, as: UTF8.self) == "ping\n")
        #expect(controller.receivedByteCount == 5)
        #expect(!controller.eventLog.isEmpty)

        controller.close()
        #expect(await controller.waitForState(.closed) == .closed)
        #expect(controller.stateDetail == "Session closed by user")
        #expect(controller.exitCode == nil)
    }

    @Test func remoteExitIsRecorded() async throws {
        let server = try LoopbackServer(.greetAndClose("goodbye\n"))
        defer { server.stop() }

        let controller = rawController(port: server.port)
        try controller.connect()
        #expect(await controller.waitForState(.closed) == .closed)
        #expect(controller.exitCode == 0)
        #expect(String(decoding: controller.transcript, as: UTF8.self) == "goodbye\n")
    }

    @Test func failureIsReportedWithDetail() async throws {
        let controller = rawController(port: try LoopbackServer.unusedPort())
        try controller.connect()
        #expect(await controller.waitForState(.connected) == .failed)
        #expect(controller.stateDetail?.contains("refused") == true)
    }

    @Test func transcriptIsBounded() async throws {
        let server = try LoopbackServer(.echo)
        defer { server.stop() }
        let controller = rawController(port: server.port)
        try controller.connect()
        #expect(await controller.waitForState(.connected) == .connected)

        let chunk = Data(repeating: 0x41, count: 256 << 10)
        for _ in 0..<6 { controller.send(chunk) }
        let total = 6 * chunk.count
        #expect(await waitUntil(timeout: .seconds(60)) { controller.receivedByteCount >= total })
        #expect(controller.receivedByteCount == total)
        #expect(controller.transcript.count == SessionController.transcriptLimit)
    }

    @Test func droppingTheControllerReleasesTheSession() async throws {
        let server = try LoopbackServer(.echo)
        defer { server.stop() }
        var controller: SessionController? = rawController(port: server.port)
        try controller!.connect()
        #expect(await controller!.waitForState(.connected) == .connected)
        controller = nil
        #expect(await waitUntil {
            PuTTYCore.waitForPendingWork() && PuTTYCore.liveSessionCount == 0
        })
    }
}
}
