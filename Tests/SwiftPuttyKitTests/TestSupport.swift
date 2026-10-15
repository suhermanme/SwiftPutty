import Foundation
import Testing
@testable import PuTTYBridge
import SessionLayer

/// One state directory per test process; the core is process-wide and
/// cannot be re-initialised after shutdown, so tests never shut it down
/// (the C bridge test covers shutdown in its own process).
enum TestCore {
    static let stateDirectory: URL = FileManager.default.temporaryDirectory
        .appending(path: "SwiftPuttyTests-\(ProcessInfo.processInfo.processIdentifier)",
                   directoryHint: .isDirectory)
        .appending(path: "state", directoryHint: .isDirectory)

    static func initialize() throws {
        try PuTTYCore.initialize(stateDirectory: stateDirectory)
    }
}

/// Every test runs serially, in one root suite: many assert on
/// process-wide state (live sessions, live settings objects, watched
/// descriptors, core loop iterations) that parallel tests would perturb.
/// Each test also has a time limit, so a hang fails the test (and CI says
/// which) instead of stalling the run.
@Suite("SwiftPuttyKit", .serialized, .timeLimit(.minutes(3)))
enum KitTests {}


/// Consumes a session's events on a background task and lets a test
/// wait for conditions on what has arrived so far.
final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [PuTTYSessionEvent] = []
    private var streamFinished = false
    private var task: Task<Void, Never>?

    init(_ events: AsyncStream<PuTTYSessionEvent>) {
        task = Task.detached { [self] in
            for await event in events {
                lock.withLock { buffer.append(event) }
            }
            lock.withLock { streamFinished = true }
        }
    }

    deinit { task?.cancel() }

    var events: [PuTTYSessionEvent] { lock.withLock { buffer } }
    var finished: Bool { lock.withLock { streamFinished } }

    var states: [PuTTYSessionState] {
        events.compactMap { if case .stateChanged(let state, _) = $0 { state } else { nil } }
    }

    var lastDetail: String? {
        events.reversed().lazy.compactMap {
            if case .stateChanged(_, let detail) = $0 { detail } else { nil }
        }.first ?? nil
    }

    var output: Data {
        events.reduce(into: Data()) { if case .output(let data, _) = $1 { $0.append(data) } }
    }

    var eventLog: [String] {
        events.compactMap { if case .eventLog(let line, _) = $0 { line } else { nil } }
    }

    /// Waits until `condition` holds; false on timeout.
    func wait(timeout: Duration = .seconds(30),
              until condition: (EventCollector) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition(self) {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    func wait(for state: PuTTYSessionState, timeout: Duration = .seconds(30)) async -> Bool {
        await wait(timeout: timeout) { $0.states.contains(state) }
    }

    func waitForFinish(timeout: Duration = .seconds(30)) async -> Bool {
        await wait(timeout: timeout) { $0.finished }
    }
}

func rawSettings(host: String = "127.0.0.1", port: UInt16) -> PuTTYSettings {
    var settings = PuTTYSettings.defaults()
    settings["Protocol"] = "raw"
    settings["HostName"] = host
    settings["PortNumber"] = String(port)
    return settings
}

extension SessionController {
    /// ``waitForState(_:)`` with a time limit: returns the state reached,
    /// which is not `target` if the time ran out.
    func waitForState(_ target: PuTTYSessionState,
                      within timeout: Duration) async -> PuTTYSessionState {
        let deadline = ContinuousClock.now + timeout
        while state < target && !state.isFinal && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return state
    }
}
