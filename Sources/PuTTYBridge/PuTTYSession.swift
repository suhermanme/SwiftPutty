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
    /// A copy of the data received from the connection, before the
    /// terminal interprets it.
    case output(Data, isStderr: Bool)
    /// The remote end exited (`Int32.max` for an unclean exit). Arrives
    /// before `.stateChanged(.closed, …)`.
    case remoteExit(code: Int32)
    /// The terminal has a new frame: read it with ``TerminalScreen/update(from:)``.
    /// Not sent again until the frame has been read.
    case terminalUpdated
    /// The terminal set the window title (or the icon title).
    case titleChanged(String, isIconTitle: Bool)
    /// The terminal rang the bell; `mode` is PuTTY's `CONF_beep` value.
    case bell(mode: Int32)
    /// Put text on a clipboard.
    case clipboardWrite(PuTTYClipboard, String)
    /// The terminal wants a paste: answer with ``PuTTYSession/paste(_:)``.
    case pasteRequested(PuTTYClipboard)
    /// The application asked for a terminal size (already acknowledged).
    case resizeRequested(cols: Int, rows: Int)
}

/// The clipboards PuTTY's terminal uses (docs/CONFIGURATION_PARITY.md).
public enum PuTTYClipboard: Sendable, Equatable {
    /// "Last selected text": an app-private buffer that mouse selection
    /// writes and middle/right-button paste reads (PuTTY `CLIP_PRIMARY`).
    case selection
    /// The general pasteboard (PuTTY `CLIP_CLIPBOARD`).
    case system

    init(_ clipboard: spb_clipboard) {
        self = clipboard == SPB_CLIPBOARD_SYSTEM ? .system : .selection
    }
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
            },
            terminal_updated: { ctx in
                EventSink.from(ctx).yield(.terminalUpdated)
            },
            title_changed: { ctx, title, isIcon in
                guard let title else { return }
                EventSink.from(ctx).yield(.titleChanged(String(cString: title), isIconTitle: isIcon))
            },
            bell: { ctx, mode in
                EventSink.from(ctx).yield(.bell(mode: mode))
            },
            clipboard_write: { ctx, clipboard, text, length in
                guard let text else { return }
                let data = Data(bytes: text, count: length)
                var string = String(decoding: data, as: UTF8.self)
                // PuTTY's Unix selection buffers are NUL-terminated.
                while string.hasSuffix("\0") { string.removeLast() }
                EventSink.from(ctx).yield(.clipboardWrite(PuTTYClipboard(clipboard), string))
            },
            paste_requested: { ctx, clipboard in
                EventSink.from(ctx).yield(.pasteRequested(PuTTYClipboard(clipboard)))
            },
            resize_requested: { ctx, cols, rows in
                EventSink.from(ctx).yield(.resizeRequested(cols: Int(cols), rows: Int(rows)))
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

    // MARK: Terminal input

    /// A non-text key, translated by PuTTY (cursor and keypad modes,
    /// function key type, Backspace and Return settings, Shift-PageUp
    /// scrollback, Shift-Insert paste).
    public func key(_ key: TerminalKey, modifiers: TerminalModifiers = []) {
        spb_session_key(handle, key.bridgeValue, modifiers.rawValue)
    }

    /// Typed or input-method text. With ``TerminalModifiers/meta`` it is
    /// prefixed with Escape.
    public func type(_ text: String, modifiers: TerminalModifiers = []) {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return }
        bytes.withUnsafeBufferPointer { buffer in
            buffer.withMemoryRebound(to: CChar.self) {
                spb_session_text(handle, $0.baseAddress, $0.count, modifiers.rawValue)
            }
        }
    }

    /// Input-method composition text, drawn by the terminal at the
    /// cursor; nil or empty ends the composition.
    public func setPreedit(_ text: String?) {
        if let text, !text.isEmpty {
            spb_session_set_preedit(handle, text)
        } else {
            spb_session_set_preedit(handle, nil)
        }
    }

    /// Pastes text (bracketed-paste aware).
    public func paste(_ text: String) {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return }
        bytes.withUnsafeBufferPointer { buffer in
            buffer.withMemoryRebound(to: CChar.self) {
                spb_session_paste(handle, $0.baseAddress, $0.count)
            }
        }
    }

    /// A mouse event at a cell position.
    public func mouse(_ button: TerminalMouseButton, _ action: TerminalMouseAction,
                      column: Int, row: Int, modifiers: TerminalModifiers = []) {
        spb_session_mouse(handle, button.bridgeValue, action.bridgeValue,
                          Int32(clamping: column), Int32(clamping: row), modifiers.rawValue)
    }

    /// Scroll-wheel notches (positive = up): to the application in raw
    /// mouse mode, otherwise five lines of scrollback each.
    public func wheel(notches: Int, column: Int, row: Int, modifiers: TerminalModifiers = []) {
        spb_session_wheel(handle, Int32(clamping: notches), Int32(clamping: column),
                          Int32(clamping: row), modifiers.rawValue)
    }

    /// Moves the view over the scrollback.
    public func scroll(_ scroll: TerminalScroll) {
        switch scroll {
        case .lines(let lines):
            spb_session_scroll(handle, SPB_SCROLL_RELATIVE, Int32(clamping: lines))
        case .toLine(let line):
            spb_session_scroll(handle, SPB_SCROLL_TO_LINE, Int32(clamping: line))
        case .toBottom:
            spb_session_scroll(handle, SPB_SCROLL_TO_BOTTOM, 0)
        }
    }

    /// Sets the terminal size in cells, and the pixel size reported to
    /// applications that ask.
    public func resize(columns: Int, rows: Int, pixelWidth: Int = 0, pixelHeight: Int = 0) {
        spb_session_resize(handle, Int32(clamping: columns), Int32(clamping: rows),
                           Int32(clamping: pixelWidth), Int32(clamping: pixelHeight))
    }

    /// Keyboard focus; without it the cursor is drawn passive.
    public func setFocus(_ focused: Bool) {
        spb_session_set_focus(handle, focused)
    }

    /// Copies the whole scrollback and screen to the system clipboard.
    public func copyAll() {
        spb_session_copy_all(handle)
    }

    func readFrame(info: inout spb_frame_info, cells: UnsafeMutablePointer<spb_cell>?,
                   cellCapacity: Int, lineAttributes: UnsafeMutablePointer<UInt8>?,
                   dirtyRows: UnsafeMutablePointer<UInt8>?, rowCapacity: Int) -> Bool {
        spb_session_read_frame(handle, &info, cells, cellCapacity, lineAttributes,
                               dirtyRows, rowCapacity)
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
