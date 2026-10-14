import Foundation
import Observation
import PuTTYBridge

/// Receives a session's terminal events on the main actor (the terminal
/// view, in the app).
@MainActor
public protocol SessionTerminalDelegate: AnyObject {
    /// A new frame is ready: read it with `TerminalScreen.update(from:)`.
    func terminalDidUpdate(_ controller: SessionController)
    func terminal(_ controller: SessionController, ringBell mode: Int32)
    func terminal(_ controller: SessionController, write text: String, to clipboard: PuTTYClipboard)
    /// Answer with `PuTTYSession.paste(_:)`.
    func terminal(_ controller: SessionController, requestsPasteFrom clipboard: PuTTYClipboard)
    func terminal(_ controller: SessionController, requestsResizeTo columns: Int, rows: Int)
}

/// The main-actor model of one PuTTY session: what a session window
/// observes and drives.
///
/// The session itself runs on the PuTTY core thread; its events hop to
/// the main actor here, in order. Terminal events go to
/// ``terminalDelegate``. A bounded transcript of the raw received data is
/// kept for diagnostics.
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
    /// Window title set by the terminal (empty until set).
    public private(set) var title = ""
    /// Icon title set by the terminal.
    public private(set) var iconTitle = ""
    /// A dialog PuTTY is waiting on (host key, weak crypto): show it and
    /// call ``answer(_:with:)``.
    public private(set) var pendingPrompt: PuTTYPrompt?

    /// Process-unique identifier of the running session, once started.
    public var sessionID: UInt64? { session?.id }

    /// The running session, once ``connect()`` has created it: the
    /// terminal view sends input and reads frames through it.
    @ObservationIgnored public private(set) var session: PuTTYSession?
    @ObservationIgnored public weak var terminalDelegate: SessionTerminalDelegate?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var stateWaiters: [CheckedContinuation<Void, Never>] = []

    public init(settings: PuTTYSettings) {
        self.settings = settings
    }

    /// Creates the PuTTY session (and its terminal) without connecting,
    /// so that a view can attach first. ``connect()`` calls it if needed.
    public func prepare() throws(PuTTYBridgeError) {
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
    }

    /// Creates the session if needed and connects. Only valid once.
    public func connect() throws(PuTTYBridgeError) {
        let fresh = session == nil
        try prepare()
        if fresh || state == .created {
            session?.start()
        }
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

    /// Answers the pending prompt.
    public func answer(_ prompt: PuTTYPrompt, with answer: PuTTYPrompt.Answer) {
        guard pendingPrompt?.id == prompt.id else { return }
        pendingPrompt = nil
        session?.answer(prompt, with: answer)
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
        case .terminalUpdated:
            terminalDelegate?.terminalDidUpdate(self)
        case .titleChanged(let text, let isIconTitle):
            if isIconTitle { iconTitle = text } else { title = text }
        case .bell(let mode):
            terminalDelegate?.terminal(self, ringBell: mode)
        case .clipboardWrite(let clipboard, let text):
            terminalDelegate?.terminal(self, write: text, to: clipboard)
        case .pasteRequested(let clipboard):
            terminalDelegate?.terminal(self, requestsPasteFrom: clipboard)
        case .resizeRequested(let columns, let rows):
            terminalDelegate?.terminal(self, requestsResizeTo: columns, rows: rows)
        case .prompt(let prompt):
            pendingPrompt = prompt
        case .promptCancelled(let id):
            if pendingPrompt?.id == id { pendingPrompt = nil }
        }
    }
}
