import Foundation
import PuTTYBridgeC

/// Modifier keys for terminal input. ``meta`` is the frontend's resolved
/// Meta key (Option or Command, per `OSXOptionMeta` / `OSXCommandMeta`).
public struct TerminalModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let shift = TerminalModifiers(rawValue: UInt32(SPB_MOD_SHIFT))
    public static let control = TerminalModifiers(rawValue: UInt32(SPB_MOD_CTRL))
    public static let meta = TerminalModifiers(rawValue: UInt32(SPB_MOD_META))
}

/// Keys that PuTTY translates itself (everything else is typed text).
public enum TerminalKey: Sendable, Hashable {
    case up, down, right, left, begin
    case home, end, insert, delete, pageUp, pageDown
    case returnKey, backspace, tab, escape
    /// F1 ... F20.
    case function(Int)
    /// Keypad 0 ... 9.
    case keypadDigit(Int)
    case keypadDecimal, keypadEnter, keypadPlus, keypadMinus
    case keypadMultiply, keypadDivide
    /// The Mac keypad's Clear key, which PuTTY treats as Num Lock.
    case keypadNumLock
    /// The C and V keys with Control+Shift: copy and paste, or Ctrl-C and
    /// Ctrl-V, per PuTTY's "Ctrl + Shift + {C,V}" setting.
    case letterC, letterV

    var bridgeValue: spb_key {
        switch self {
        case .up: SPB_KEY_UP
        case .down: SPB_KEY_DOWN
        case .right: SPB_KEY_RIGHT
        case .left: SPB_KEY_LEFT
        case .begin: SPB_KEY_BEGIN
        case .home: SPB_KEY_HOME
        case .end: SPB_KEY_END
        case .insert: SPB_KEY_INSERT
        case .delete: SPB_KEY_DELETE
        case .pageUp: SPB_KEY_PAGE_UP
        case .pageDown: SPB_KEY_PAGE_DOWN
        case .returnKey: SPB_KEY_RETURN
        case .backspace: SPB_KEY_BACKSPACE
        case .tab: SPB_KEY_TAB
        case .escape: SPB_KEY_ESCAPE
        case .function(let n):
            spb_key(rawValue: SPB_KEY_F1.rawValue + UInt32(min(max(n, 1), 20) - 1))
        case .keypadDigit(let n):
            spb_key(rawValue: SPB_KEY_KP_0.rawValue + UInt32(min(max(n, 0), 9)))
        case .keypadDecimal: SPB_KEY_KP_DECIMAL
        case .keypadEnter: SPB_KEY_KP_ENTER
        case .keypadPlus: SPB_KEY_KP_PLUS
        case .keypadMinus: SPB_KEY_KP_MINUS
        case .keypadMultiply: SPB_KEY_KP_MULTIPLY
        case .keypadDivide: SPB_KEY_KP_DIVIDE
        case .keypadNumLock: SPB_KEY_KP_NUM_LOCK
        case .letterC: SPB_KEY_C
        case .letterV: SPB_KEY_V
        }
    }
}

public enum TerminalMouseButton: Sendable {
    case left, middle, right

    var bridgeValue: spb_mouse_button {
        switch self {
        case .left: SPB_MOUSE_LEFT
        case .middle: SPB_MOUSE_MIDDLE
        case .right: SPB_MOUSE_RIGHT
        }
    }
}

public enum TerminalMouseAction: Sendable {
    case click, doubleClick, tripleClick, drag, release, move

    var bridgeValue: spb_mouse_action {
        switch self {
        case .click: SPB_MOUSE_CLICK
        case .doubleClick: SPB_MOUSE_DOUBLE_CLICK
        case .tripleClick: SPB_MOUSE_TRIPLE_CLICK
        case .drag: SPB_MOUSE_DRAG
        case .release: SPB_MOUSE_RELEASE
        case .move: SPB_MOUSE_MOVE
        }
    }
}

public enum TerminalScroll: Sendable, Equatable {
    /// Relative, in lines (negative = towards the top).
    case lines(Int)
    /// Make `line` (a ``TerminalScreen/scrollStart`` value) the first
    /// visible line.
    case toLine(Int)
    case toBottom
}

/// One terminal cell, colours resolved by the bridge.
public struct TerminalCell: Equatable, Sendable {
    /// Base character, then combining characters. Empty for a blank.
    public var scalars: [Unicode.Scalar]
    /// 0xRRGGBB.
    public var foreground: UInt32
    public var background: UInt32
    public var flags: Flags

    public struct Flags: OptionSet, Sendable, Hashable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let bold = Flags(rawValue: UInt32(SPB_CELL_BOLD))
        public static let underline = Flags(rawValue: UInt32(SPB_CELL_UNDERLINE))
        public static let strikethrough = Flags(rawValue: UInt32(SPB_CELL_STRIKE))
        /// First half of a two-column character.
        public static let wide = Flags(rawValue: UInt32(SPB_CELL_WIDE))
        /// Second half of a two-column character: draw nothing.
        public static let wideContinuation = Flags(rawValue: UInt32(SPB_CELL_WIDE_CONT))
        /// Draw the cursor overlay (``TerminalScreen/cursorStyle``) here.
        public static let cursor = Flags(rawValue: UInt32(SPB_CELL_CURSOR))
        /// ...in its unfocused (hollow or dotted) form.
        public static let cursorPassive = Flags(rawValue: UInt32(SPB_CELL_CURSOR_PASSIVE))
        /// Vertical-line cursor on the right edge of the cell.
        public static let cursorRight = Flags(rawValue: UInt32(SPB_CELL_CURSOR_RIGHT))
        /// PuTTY's trust sigil (two columns).
        public static let trustSigil = Flags(rawValue: UInt32(SPB_CELL_TRUST_SIGIL))
    }

    /// The cell's text, or nil for a blank.
    public var text: String? {
        guard !scalars.isEmpty else { return nil }
        var string = ""
        string.unicodeScalars.append(contentsOf: scalars)
        return string
    }
}

public enum TerminalLineAttribute: UInt8, Sendable {
    case normal, doubleWidth, doubleHeightTop, doubleHeightBottom
}

public enum TerminalCursorStyle: Sendable {
    /// An active block cursor is already in the cell colours.
    case block, underline, verticalLine
}

/// The frontend's copy of a session's terminal screen.
///
/// ``update(from:)`` copies the rows that changed since the last call
/// (all rows after a resize) out of the bridge. Not thread-safe: use it
/// from one thread (the main thread, in the app).
public final class TerminalScreen {
    public private(set) var columns = 0
    public private(set) var rows = 0
    public private(set) var cursorStyle = TerminalCursorStyle.block
    /// Colour of overlay cursors, 0xRRGGBB.
    public private(set) var cursorColour: UInt32 = 0x00FF00
    public private(set) var defaultForeground: UInt32 = 0xBBBBBB
    public private(set) var defaultBackground: UInt32 = 0x000000
    /// Text cursor position (for input method candidate windows).
    public private(set) var cursorColumn = 0
    public private(set) var cursorRow = 0
    /// Scrollback, as PuTTY's scrollbar: lines in total, first visible
    /// line, visible lines.
    public private(set) var scrollTotal = 0
    public private(set) var scrollStart = 0
    public private(set) var scrollPage = 0
    /// The application asked for mouse events.
    public private(set) var rawMouse = false
    /// Show the mouse-reporting pointer.
    public private(set) var rawMousePointer = false

    private var cells: UnsafeMutablePointer<spb_cell>?
    private var cellCapacity = 0
    private var lineAttributes: UnsafeMutablePointer<UInt8>?
    private var dirty: UnsafeMutablePointer<UInt8>?
    private var rowCapacity = 0

    public init() {}

    deinit {
        cells?.deallocate()
        lineAttributes?.deallocate()
        dirty?.deallocate()
    }

    /// The result of an ``update(from:)``.
    public struct Update: Sendable, Equatable {
        /// Rows whose cells changed.
        public var changedRows: IndexSet
        /// The size changed, or this was the first frame: redraw everything.
        public var isFull: Bool
    }

    /// Copies the latest frame from `session`.
    @discardableResult
    public func update(from session: PuTTYSession) -> Update {
        var info = spb_frame_info()
        while !session.readFrame(info: &info, cells: cells, cellCapacity: cellCapacity,
                                 lineAttributes: lineAttributes, dirtyRows: dirty,
                                 rowCapacity: rowCapacity) {
            let needed = Int(info.cols) * Int(info.rows)
            guard needed > 0 else { return Update(changedRows: [], isFull: false) }
            reserve(cells: needed, rows: Int(info.rows))
        }
        columns = Int(info.cols)
        rows = Int(info.rows)
        cursorStyle = switch info.cursor_style {
        case SPB_CURSOR_UNDERLINE: .underline
        case SPB_CURSOR_VERTICAL_LINE: .verticalLine
        default: .block
        }
        cursorColour = info.cursor_colour
        defaultForeground = info.default_fg
        defaultBackground = info.default_bg
        cursorColumn = Int(info.cursor_x)
        cursorRow = Int(info.cursor_y)
        scrollTotal = Int(info.scroll_total)
        scrollStart = Int(info.scroll_start)
        scrollPage = Int(info.scroll_page)
        rawMouse = info.raw_mouse
        rawMousePointer = info.raw_mouse_pointer

        var changed = IndexSet()
        for row in 0..<rows where info.full || dirty![row] != 0 {
            changed.insert(row)
        }
        return Update(changedRows: changed, isFull: info.full)
    }

    public func cell(column: Int, row: Int) -> TerminalCell {
        precondition(column >= 0 && column < columns && row >= 0 && row < rows)
        let raw = cells![row * columns + column]
        var scalars: [Unicode.Scalar] = []
        withUnsafeBytes(of: raw.chars) { bytes in
            for value in bytes.bindMemory(to: UInt32.self) {
                guard value != 0, let scalar = Unicode.Scalar(value) else { break }
                scalars.append(scalar)
            }
        }
        return TerminalCell(scalars: scalars, foreground: raw.fg, background: raw.bg,
                            flags: TerminalCell.Flags(rawValue: raw.flags))
    }

    public func lineAttribute(row: Int) -> TerminalLineAttribute {
        TerminalLineAttribute(rawValue: lineAttributes![row]) ?? .normal
    }

    /// A row's text, blanks as spaces, trailing spaces removed.
    public func text(row: Int) -> String {
        var line = ""
        for column in 0..<columns {
            let cell = cell(column: column, row: row)
            if cell.flags.contains(.wideContinuation) { continue }
            line += cell.text ?? " "
        }
        while line.hasSuffix(" ") { line.removeLast() }
        return line
    }

    private func reserve(cells needed: Int, rows neededRows: Int) {
        if needed > cellCapacity {
            cells?.deallocate()
            cells = .allocate(capacity: needed)
            cells!.initialize(repeating: spb_cell(), count: needed)
            cellCapacity = needed
        }
        if neededRows > rowCapacity {
            lineAttributes?.deallocate()
            dirty?.deallocate()
            lineAttributes = .allocate(capacity: neededRows)
            lineAttributes!.initialize(repeating: 0, count: neededRows)
            dirty = .allocate(capacity: neededRows)
            dirty!.initialize(repeating: 0, count: neededRows)
            rowCapacity = neededRows
        }
    }
}
