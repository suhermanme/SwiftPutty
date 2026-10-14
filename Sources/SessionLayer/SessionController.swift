import Foundation
import Observation
import PuTTYBridge

/// The main-actor model of one PuTTY session: what a session window
/// observes and drives.
///
/// The session itself runs on the PuTTY core thread; its events hop to
/// the main actor here, in order. Received output is kept in a bounded
/// transcript until the terminal (M03) consumes it.
@MainActor
@Observable
public final class SessionController {
    /// Bytes of received output kept in ``transcript``.
    public static let transcriptLimit = 1 << 20

    public let settings: PuTTYSettings

    public private(set) var state: PuTTYSessionState = .created
    /// Why the session reached its current state, if known (for example
    /// the error that made it fail).
    public private(set) var stateDetail: String?
    public private(set) var eventLog: [String] = []
    /// The most recent received output (at most ``transcriptLimit``
    /// bytes), stdout and stderr interleaved as received.
    public private(set) var transcript = Data()
    /// Total bytes received, including any dropped from ``transcript``.
    public private(set) var receivedByteCount = 0
    public private(set) var exitCode: Int32?

    /// Process-unique identifier of the running session, once started.
    public var sessionID: UInt64? { session?.id }

    @ObservationIgnored private var session: PuTTYSession?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var stateWaiters: [CheckedContinuation<Void, Never>] = []

    public init(settings: PuTTYSettings) {
        self.settings = settings
    }

    /// Creates the PuTTY session and connects. Only valid once.
    public func connect() throws(PuTTYBridgeError) {
        guard session == nil else { return }
        let session = try PuTTYSession(settings: settings)
        self.session = session
        let events = session.events
        // The task holds the controller weakly: dropping the controller
        // drops the session, whose stream then finishes.
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.apply(event)
            }
        }
        session.start()
    }

    public func send(_ data: Data) {
        session?.send(data)
    }

    public func send(_ text: String) {
        session?.send(text)
    }

    public func sendEOF() {
        session?.sendEOF()
    }

    /// Disconnects. The session object is kept until the controller goes
    /// away, so its final events still arrive.
    public func close() {
        session?.close()
    }

    /// Waits until the session has reached `target` or a final state, and
    /// returns the state reached.
    @discardableResult
    public func waitForState(_ target: PuTTYSessionState) async -> PuTTYSessionState {
        while state < target && !state.isFinal {
            await withCheckedContinuation { continuation in
                stateWaiters.append(continuation)
            }
        }
        return state
    }

    private func apply(_ event: PuTTYSessionEvent) {
        switch event {
        case .stateChanged(let newState, let detail):
            state = newState
            stateDetail = detail
            let waiters = stateWaiters
            stateWaiters.removeAll()
            waiters.forEach { $0.resume() }
        case .eventLog(let line):
            eventLog.append(line)
        case .output(let data, _):
            receivedByteCount += data.count
            transcript.append(data)
            if transcript.count > Self.transcriptLimit {
                transcript.removeFirst(transcript.count - Self.transcriptLimit)
            }
        case .remoteExit(let code):
            exitCode = code
        }
    }
}
