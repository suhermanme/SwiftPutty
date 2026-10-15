import Foundation
import PuTTYBridgeC

/// Lifecycle state of a ``PuTTYSession``.
///
/// States move forward, in declaration order; `closed` and `failed` end
/// a connection. Only ``PuTTYSession/restart()`` starts a new one, from
/// `connecting` again.
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
    /// One line of PuTTY's Event Log, and when PuTTY logged it.
    case eventLog(String, time: Date)
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
    /// PuTTY needs an answer to a dialog: reply with
    /// ``PuTTYSession/answer(_:with:)``. The connection waits meanwhile.
    case prompt(PuTTYPrompt)
    /// The connection ended before the prompt was answered: dismiss it.
    case promptCancelled(id: UInt64)
    /// Answer to ``PuTTYSession/exportSettings(request:)``: the running
    /// settings, and PuTTY's `backend_cfg_info` (0 unknown or no
    /// connection, 1 SSH-1, 2 SSH-2, -1 connection-sharing downstream).
    case settingsExported(request: UInt64, PuTTYSettings, protocolInfo: Int32)
    /// Answer to ``PuTTYSession/reconfigure(_:request:)``; `error` is nil
    /// on success.
    case reconfigured(request: UInt64, error: String?)
    /// A configured port forwarding changed state (set up, answered by
    /// the server, removed). Nothing is reported when the connection
    /// ends: every forwarding goes with it.
    case portForwardStatus(PortForwardStatus)
    /// The Special Commands menu changed: the whole list (empty without
    /// a connection).
    case specialsChanged([SessionSpecial])
    /// A non-fatal error PuTTY shows in a message box.
    case errorMessage(String)
    /// Answer to ``PuTTYSession/queryCloseWarning(request:)``: whether
    /// closing would end a connection, and the connection's extra warning
    /// text (such as connection-sharing downstreams it would close).
    case closeWarning(request: UInt64, connected: Bool, text: String?)
}

/// A question PuTTY asks in a dialog box: host key confirmation, a
/// weak-cryptography warning, or what to do with an existing log file.
/// The text is PuTTY's own, structured as upstream's `SeatDialogText`.
public struct PuTTYPrompt: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// Unknown or changed host key. Answers: ``Answer/acceptAndStore``
        /// ("Accept"), ``Answer/acceptOnce`` ("Connect Once"), ``Answer/cancel``.
        case hostKey
        /// An algorithm below the warning threshold. Answers:
        /// ``Answer/acceptOnce`` ("Yes"), ``Answer/cancel`` ("No").
        case weakCrypto
        /// The cached host key's type is below the warning threshold.
        /// Answers as for ``weakCrypto``.
        case weakCachedHostKey
        /// The session log file exists and the settings say to ask.
        /// Answers: ``Answer/overwriteLog``, ``Answer/appendToLog``,
        /// ``Answer/cancel`` ("Disable"). Asked independently of the
        /// connection's dialogs, and kept when the connection ends.
        case logFileExists
    }

    public enum Answer: Sendable {
        case cancel, acceptOnce, acceptAndStore
        case overwriteLog, appendToLog
    }

    public struct Item: Sendable, Equatable {
        public enum Style: Sendable, Equatable {
            case paragraph
            /// Monospaced, on its own line (fingerprints, key types).
            case display
            /// "WARNING - POTENTIAL SECURITY BREACH!"
            case scaryHeading
            case title
            /// The console-style question; GUIs omit it, as GTK PuTTY does.
            case prompt
            case moreInfoKey
            case moreInfoShortValue
            case moreInfoLongValue
        }
        public var style: Style
        public var text: String

        public init(style: Style, text: String) {
            self.style = style
            self.text = text
        }
    }

    public let id: UInt64
    public let kind: Kind
    public let items: [Item]

    public var title: String? {
        items.first { $0.style == .title }?.text
    }

    /// Whether PuTTY marked this as a possible attack (changed host key).
    public var isWarning: Bool {
        items.contains { $0.style == .scaryHeading }
    }

    init(_ prompt: UnsafePointer<spb_prompt>) {
        let p = prompt.pointee
        id = p.id
        kind = switch p.kind {
        case SPB_PROMPT_WEAK_CRYPTO: .weakCrypto
        case SPB_PROMPT_WEAK_CACHED_HOST_KEY: .weakCachedHostKey
        case SPB_PROMPT_LOG_FILE_EXISTS: .logFileExists
        default: .hostKey
        }
        items = (0..<p.n_items).map { index in
            let item = p.items[index]
            let style: Item.Style = switch item.type {
            case SPB_DIALOG_DISPLAY: .display
            case SPB_DIALOG_SCARY_HEADING: .scaryHeading
            case SPB_DIALOG_TITLE: .title
            case SPB_DIALOG_PROMPT: .prompt
            case SPB_DIALOG_MORE_INFO_KEY: .moreInfoKey
            case SPB_DIALOG_MORE_INFO_SHORT: .moreInfoShortValue
            case SPB_DIALOG_MORE_INFO_BLOB: .moreInfoLongValue
            default: .paragraph
            }
            return Item(style: style, text: String(cString: item.text))
        }
    }

    public init(id: UInt64, kind: Kind, items: [Item]) {
        self.id = id
        self.kind = kind
        self.items = items
    }
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
                EventSink.from(ctx).yield(.eventLog(String(cString: line), time: Date()))
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
            },
            prompt: { ctx, prompt in
                guard let prompt else { return }
                EventSink.from(ctx).yield(.prompt(PuTTYPrompt(prompt)))
            },
            prompt_cancelled: { ctx, id in
                EventSink.from(ctx).yield(.promptCancelled(id: id))
            },
            settings_exported: { ctx, request, settings, info in
                guard let settings else { return }
                let exported = PuTTYSettings(handle: settings)
                spb_settings_free(settings)
                EventSink.from(ctx).yield(.settingsExported(request: request, exported,
                                                            protocolInfo: info))
            },
            reconfigured: { ctx, request, error in
                EventSink.from(ctx).yield(.reconfigured(request: request,
                                                        error: error.map { String(cString: $0) }))
            },
            portfwd_status: { ctx, status in
                guard let status else { return }
                EventSink.from(ctx).yield(.portForwardStatus(PortForwardStatus(status)))
            },
            specials_changed: { ctx, list, count in
                EventSink.from(ctx).yield(.specialsChanged(SessionSpecial.tree(from: list, count: count)))
            },
            error_message: { ctx, message in
                guard let message else { return }
                EventSink.from(ctx).yield(.errorMessage(String(cString: message)))
            },
            close_warning: { ctx, request, connected, text in
                EventSink.from(ctx).yield(.closeWarning(request: request, connected: connected,
                                                        text: text.map { String(cString: $0) }))
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
    /// Every protocol PuTTY has on Unix: SSH, Serial, Telnet, Rlogin,
    /// SUPDUP and Raw. Logins are prompted for in the terminal; host keys
    /// through ``PuTTYSessionEvent/prompt(_:)``.
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

    /// Answers a ``PuTTYSessionEvent/prompt(_:)``. Answers to prompts
    /// that are no longer pending are ignored.
    public func answer(_ prompt: PuTTYPrompt, with answer: PuTTYPrompt.Answer) {
        let value: spb_prompt_answer = switch answer {
        case .cancel: SPB_ANSWER_CANCEL
        case .acceptOnce: SPB_ANSWER_ACCEPT_ONCE
        case .acceptAndStore: SPB_ANSWER_ACCEPT_AND_STORE
        case .overwriteLog: SPB_ANSWER_LOG_OVERWRITE
        case .appendToLog: SPB_ANSWER_LOG_APPEND
        }
        spb_session_answer_prompt(handle, prompt.id, value)
    }

    /// Disconnects; the session becomes ``PuTTYSessionState/closed``.
    public func close() {
        spb_session_close(handle)
    }

    /// Restart Session: once the connection has ended, connects again
    /// with the running settings (state `connecting` again; the terminal
    /// is reset but keeps its scrollback). Ignored while connected.
    public func restart() {
        spb_session_restart(handle)
    }

    /// Runs a Special Commands entry from the last
    /// ``PuTTYSessionEvent/specialsChanged(_:)`` list; anything else is
    /// ignored.
    public func special(_ command: SessionSpecialCommand) {
        spb_session_special(handle, command.code, command.argument)
    }

    /// Asks what closing would end: answered by
    /// ``PuTTYSessionEvent/closeWarning(request:connected:text:)``.
    public func queryCloseWarning(request: UInt64) {
        spb_session_query_close_warning(handle, request)
    }

    /// Clear Scrollback.
    public func clearScrollback() {
        spb_session_clear_scrollback(handle)
    }

    /// Reset Terminal (as at power-on, clearing the screen).
    public func resetTerminal() {
        spb_session_reset_terminal(handle)
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

    /// Asks for the running settings (Change Settings starts from them):
    /// answered by ``PuTTYSessionEvent/settingsExported(request:_:protocolInfo:)``.
    public func exportSettings(request: UInt64) {
        spb_session_export_settings(handle, request)
    }

    /// Applies edited settings to the running session without
    /// reconnecting: answered by ``PuTTYSessionEvent/reconfigured(request:error:)``.
    public func reconfigure(_ settings: PuTTYSettings, request: UInt64) {
        settings.withBridgeHandle { spb_session_reconfigure(handle, $0, request) }
    }

    /// Changes whenever the session's connection is created; the same
    /// across reconfigurations.
    public var transportID: UInt64 {
        spb_session_transport_id(handle)
    }

    /// The settings the session was created with (not changed by
    /// reconfiguration).
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
