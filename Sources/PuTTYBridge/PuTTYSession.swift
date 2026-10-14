import Foundation
import PuTTYBridgeC

/// Lifecycle state of a ``PuTTYSession``.
///
/// States only move forward, in declaration order; `closed` and `failed`
/// are final.
public enum PuTTYSessionState: Int, Sendable, Comparable, CustomStringConvertible {
    /// Not started yet.
    case created
    /// Started; the connection is not ready for input yet.
    case connecting
    /// The connection accepts input.
    case connected
    /// Ended normally: the remote end exited, or the session was closed.
    case closed
    /// Ended with an error.
    case failed

    public var isFinal: Bool { self == .closed || self == .failed }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String {
        switch self {
        case .created: "created"
        case .connecting: "connecting"
        case .connected: "connected"
        case .closed: "closed"
        case .failed: "failed"
        }
    }

    init(_ state: spb_session_state) {
        switch state {
        case SPB_SESSION_CREATED: self = .created
        case SPB_SESSION_CONNECTING: self = .connecting
        case SPB_SESSION_CONNECTED: self = .connected
        case SPB_SESSION_CLOSED: self = .closed
        default: self = .failed
        }
    }
}

/// Something a running session reports.
public enum PuTTYSessionEvent: Sendable, Equatable {
    /// The session moved to `state`; `detail` explains why, if known.
    case stateChanged(PuTTYSessionState, detail: String?)
    /// One line of PuTTY's Event Log.
    case eventLog(String)
    /// Data received from the connection. Raw bytes until the terminal
    /// exists (M03).
    case output(Data, isStderr: Bool)
    /// The remote end exited (`Int32.max` for an unclean exit). Arrives
    /// before `.stateChanged(.closed, …)`.
    case remoteExit(code: Int32)
}

/// One PuTTY session, executed on the process-wide PuTTY core thread.
///
/// Every operation returns at once; the work is queued for the core
/// thread and runs in call order. What the session reports arrives on
/// ``events``, which finishes once the session has been torn down after
/// this object is deinitialised.
///
/// Received output is buffered without limit until it is consumed; flow
/// control towards the connection is part of the performance pass (M14).
public final class PuTTYSession: Sendable {
    /// Process-unique, never-reused session identifier.
    public let id: UInt64

    /// Everything the session reports, in order.
    public let events: AsyncStream<PuTTYSessionEvent>

    // The C handle may be used from any thread (PuTTYBridge.h).
    nonisolated(unsafe) private let handle: OpaquePointer

    public init(settings: PuTTYSettings) throws(PuTTYBridgeError) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: PuTTYSessionEvent.self, bufferingPolicy: .unbounded)
        let sink = Unmanaged.passRetained(EventSink(continuation))

        var callbacks = spb_session_callbacks(
            state_changed: { ctx, state, detail in
                EventSink.from(ctx).yield(.stateChanged(
                    PuTTYSessionState(state), detail: detail.map { String(cString: $0) }))
            },
            event_log: { ctx, line in
                guard let line else { return }
                EventSink.from(ctx).yield(.eventLog(String(cString: line)))
            },
            output: { ctx, data, length, isStderr in
                guard let data, length > 0 else { return }
                EventSink.from(ctx).yield(.output(Data(bytes: data, count: length),
                                                  isStderr: isStderr))
            },
            remote_exit: { ctx, code in
                EventSink.from(ctx).yield(.remoteExit(code: code))
            },
            released: { ctx in
                // Balances passRetained: the last call made with ctx.
                Unmanaged<EventSink>.fromOpaque(ctx!).takeRetainedValue().finish()
            })

        var error: UnsafeMutablePointer<CChar>?
        let created = settings.withBridgeHandle {
            spb_session_create($0, &callbacks, sink.toOpaque(), &error)
        }
        guard let created else {
            // No callback is ever made for a session that was not created.
            sink.release()
            throw .consuming(error, fallback: "Could not create PuTTY session")
        }
        handle = created
        id = spb_session_id(created)
        events = stream
    }

    deinit {
        spb_session_release(handle)
    }

    /// Connects, as PuTTY does when a session window opens.
    ///
    /// M02 supports the Raw protocol only; other protocols fail with an
    /// explanatory message until their milestone (SSH: M04).
    public func start() {
        spb_session_start(handle)
    }

    /// Sends bytes to the connection, as typed input. Ignored unless the
    /// session is connecting or connected.
    public func send(_ data: Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { spb_session_send(handle, $0.baseAddress, $0.count) }
    }

    /// Sends the UTF-8 encoding of `text`.
    public func send(_ text: String) {
        send(Data(text.utf8))
    }

    /// Sends end-of-file to the connection.
    public func sendEOF() {
        spb_session_send_eof(handle)
    }

    /// Disconnects; the session becomes ``PuTTYSessionState/closed``.
    public func close() {
        spb_session_close(handle)
    }

    /// Snapshot of the session's configuration.
    public var currentSettings: PuTTYSettings {
        let copy = spb_session_copy_settings(handle)!
        defer { spb_settings_free(copy) }
        return PuTTYSettings(handle: copy)
    }
}

/// Receives a session's callbacks on the core thread and forwards them
/// to the session's event stream.
private final class EventSink: Sendable {
    private let continuation: AsyncStream<PuTTYSessionEvent>.Continuation

    init(_ continuation: AsyncStream<PuTTYSessionEvent>.Continuation) {
        self.continuation = continuation
    }

    static func from(_ ctx: UnsafeMutableRawPointer?) -> EventSink {
        Unmanaged<EventSink>.fromOpaque(ctx!).takeUnretainedValue()
    }

    func yield(_ event: PuTTYSessionEvent) {
        continuation.yield(event)
    }

    func finish() {
        continuation.finish()
    }
}
