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
        #expect(await controller.waitForState(.connected, within: .seconds(30)) == .connected)
        #expect(controller.sessionID != nil)

        controller.send("ping\n")
        #expect(await waitUntil { controller.transcript.count >= 5 })
        #expect(String(decoding: controller.transcript, as: UTF8.self) == "ping\n")
        #expect(controller.receivedByteCount == 5)
        #expect(!controller.eventLog.isEmpty)

        controller.close()
        #expect(await controller.waitForState(.closed, within: .seconds(30)) == .closed)
        #expect(controller.stateDetail == "Session closed by user")
        #expect(controller.exitCode == nil)
    }

    @Test func remoteExitIsRecorded() async throws {
        let server = try LoopbackServer(.greetAndClose("goodbye\n"))
        defer { server.stop() }

        let controller = rawController(port: server.port)
        try controller.connect()
        #expect(await controller.waitForState(.closed, within: .seconds(30)) == .closed)
        #expect(controller.exitCode == 0)
        #expect(String(decoding: controller.transcript, as: UTF8.self) == "goodbye\n")
    }

    @Test func failureIsReportedWithDetail() async throws {
        let controller = rawController(port: try LoopbackServer.unusedPort())
        try controller.connect()
        #expect(await controller.waitForState(.connected, within: .seconds(30)) == .failed)
        #expect(controller.stateDetail?.contains("refused") == true)
    }

    @Test func transcriptIsBounded() async throws {
        let server = try LoopbackServer(.echo)
        defer { server.stop() }
        let controller = rawController(port: server.port)
        try controller.connect()
        #expect(await controller.waitForState(.connected, within: .seconds(30)) == .connected)

        let chunk = Data(repeating: 0x41, count: 256 << 10)
        for _ in 0..<6 { controller.send(chunk) }
        let total = 6 * chunk.count
        #expect(await waitUntil(timeout: .seconds(60)) { controller.receivedByteCount >= total })
        #expect(controller.receivedByteCount == total)
        #expect(controller.transcript.count == SessionController.transcriptLimit)
    }

    /// The log file question (PuTTY's askappend) arrives as a prompt,
    /// and outlives the connection.
    @Test func asksAboutAnExistingLogFile() async throws {
        let server = try LoopbackServer(.echo)
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SwiftPuttyLog-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appending(path: "session.log")
        try Data("old\n".utf8).write(to: log)

        var settings = rawSettings(port: server.port)
        settings["LogType"] = "2"                  // all session output
        settings["LogFileName"] = log.path
        settings["LogFileClash"] = "-1"            // ask
        settings["LogHeader"] = "0"
        var controller: SessionController? = SessionController(settings: settings)
        try controller!.connect()
        #expect(await controller!.waitForState(.connected, within: .seconds(30)) == .connected)
        controller!.send("ping\n")
        #expect(await waitUntil { controller!.pendingPrompt != nil })
        let prompt = try #require(controller!.pendingPrompt)
        #expect(prompt.kind == .logFileExists)
        #expect(prompt.title == "SwiftPutty Log to File")

        controller!.close()
        #expect(await controller!.waitForState(.closed, within: .seconds(30)) == .closed)
        #expect(controller!.pendingPrompt == prompt)
        controller!.answer(prompt, with: .appendToLog)
        #expect(controller!.pendingPrompts.isEmpty)
        #expect(await waitUntil { controller!.eventLog.contains { $0.text.hasPrefix("Appending session log") } })

        controller = nil                           // closes the log file
        #expect(await waitUntil { PuTTYCore.waitForPendingWork() && PuTTYCore.liveSessionCount == 0 })
        #expect(try String(contentsOf: log, encoding: .utf8) == "old\nping\n")
    }

    @Test func droppingTheControllerReleasesTheSession() async throws {
        let server = try LoopbackServer(.echo)
        defer { server.stop() }
        var controller: SessionController? = rawController(port: server.port)
        try controller!.connect()
        #expect(await controller!.waitForState(.connected, within: .seconds(30)) == .connected)
        controller = nil
        #expect(await waitUntil {
            PuTTYCore.waitForPendingWork() && PuTTYCore.liveSessionCount == 0
        })
    }
}
}
