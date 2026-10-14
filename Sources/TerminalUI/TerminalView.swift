import AppKit
import PuTTYBridge
import SessionLayer

/// App-wide "last selected text" (PuTTY's `CLIP_PRIMARY`): mouse
/// selection writes it, middle/right-button paste reads it. It is private
/// to SwiftPutty, as macOS has no primary selection
/// (docs/CONFIGURATION_PARITY.md).
@MainActor
public enum TerminalSelectionBuffer {
    public static var text = ""
}

/// The terminal window's content: draws a session's terminal and turns
/// keyboard, mouse, scroll and focus events into terminal input.
@MainActor
public final class TerminalView: NSView, @preconcurrency NSTextInputClient,
    NSUserInterfaceValidations, SessionTerminalDelegate {
    public let controller: SessionController
    public let screen = TerminalScreen()
    public private(set) var renderer: TerminalRenderer

    /// Space between the window edge and the cells.
    public static let border: CGFloat = 1

    private let scroller = NSScroller()
    private let showsScrollbar: Bool
    private let optionIsMeta: Bool
    private let commandIsMeta: Bool
    private var markedText = NSMutableAttributedString()
    private var lastSelection = ""
    private var gridSize = (columns: 0, rows: 0)
    private var scrollAccumulator: CGFloat = 0
    private var pressedButton: TerminalMouseButton?
    private var trackingArea: NSTrackingArea?

    public init(controller: SessionController) {
        self.controller = controller
        let settings = controller.settings
        renderer = TerminalRenderer(font: TerminalFont(puttyFontName: settings["FontName"]))
        showsScrollbar = settings["ScrollBar"] != "0"
        optionIsMeta = settings["OSXOptionMeta"] != "0"
        commandIsMeta = settings["OSXCommandMeta"] == "1"
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        scroller.scrollerStyle = .legacy
        scroller.knobStyle = .light
        scroller.isEnabled = true
        scroller.target = self
        scroller.action = #selector(scrollerMoved(_:))
        scroller.isHidden = !showsScrollbar
        addSubview(scroller)

        controller.terminalDelegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The view size that holds `columns` x `rows` cells.
    public func size(columns: Int, rows: Int) -> NSSize {
        Self.size(columns: columns, rows: rows, font: renderer.font, scrollbar: showsScrollbar)
    }

    /// The view size for `settings`' font, scrollbar and terminal size
    /// (`TermWidth` x `TermHeight`).
    public static func defaultSize(for settings: PuTTYSettings) -> NSSize {
        size(columns: Int(settings["TermWidth"] ?? "") ?? 80,
             rows: Int(settings["TermHeight"] ?? "") ?? 24,
             font: TerminalFont(puttyFontName: settings["FontName"]),
             scrollbar: settings["ScrollBar"] != "0")
    }

    private static func size(columns: Int, rows: Int, font: TerminalFont, scrollbar: Bool) -> NSSize {
        let scroller = scrollbar ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        return NSSize(width: CGFloat(columns) * font.cellWidth + 2 * border + scroller,
                      height: CGFloat(rows) * font.cellHeight + 2 * border)
    }

    private var scrollerWidth: CGFloat {
        showsScrollbar ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override var isOpaque: Bool { true }

    // MARK: Frames

    public func terminalDidUpdate(_ controller: SessionController) {
        guard let session = controller.session else { return }
        if gridSize == (0, 0) {
            // The view was laid out before the session existed.
            resizeTerminal()
        }
        let update = screen.update(from: session)
        updateScroller()
        if update.isFull {
            needsDisplay = true
        } else {
            for row in update.changedRows {
                setNeedsDisplay(rowRect(row))
            }
        }
        window?.invalidateCursorRects(for: self)
        if screen.rawMousePointer { NSCursor.arrow.set() }
    }

    private func rowRect(_ row: Int) -> NSRect {
        NSRect(x: Self.border, y: Self.border + CGFloat(row) * renderer.font.cellHeight,
               width: CGFloat(screen.columns) * renderer.font.cellWidth,
               height: renderer.font.cellHeight)
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(TerminalRenderer.cgColour(screen.defaultBackground))
        context.fill(dirtyRect)
        guard screen.rows > 0 else { return }
        let h = renderer.font.cellHeight
        let first = max(0, Int(((dirtyRect.minY - Self.border) / h).rounded(.down)))
        let last = min(screen.rows, Int(((dirtyRect.maxY - Self.border) / h).rounded(.up)))
        guard first < last else { return }
        context.saveGState()
        context.translateBy(x: Self.border, y: Self.border)
        renderer.draw(screen, rows: first..<last, in: context)
        context.restoreGState()
    }

    // MARK: Layout

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scroller.frame = NSRect(x: newSize.width - scrollerWidth, y: 0,
                                width: scrollerWidth, height: newSize.height)
        resizeTerminal()
    }

    private func resizeTerminal() {
        let usableWidth = bounds.width - scrollerWidth - 2 * Self.border
        let usableHeight = bounds.height - 2 * Self.border
        let columns = max(1, Int(usableWidth / renderer.font.cellWidth))
        let rows = max(1, Int(usableHeight / renderer.font.cellHeight))
        guard (columns, rows) != gridSize, let session = controller.session else { return }
        gridSize = (columns, rows)
        session.resize(columns: columns, rows: rows,
                       pixelWidth: Int(CGFloat(columns) * renderer.font.cellWidth),
                       pixelHeight: Int(CGFloat(rows) * renderer.font.cellHeight))
    }

    public func terminal(_ controller: SessionController, requestsResizeTo columns: Int, rows: Int) {
        // As PuTTY's default "change the number of rows and columns":
        // resize the window to fit, keeping its top-left corner.
        guard let window, columns > 0, rows > 0 else { return }
        var frame = window.frame
        let content = window.frameRect(forContentRect: NSRect(origin: .zero, size: size(columns: columns, rows: rows)))
        frame.origin.y += frame.height - content.height
        frame.size = content.size
        window.setFrame(frame, display: true)
    }

    // MARK: Scrollback

    private func updateScroller() {
        let total = screen.scrollTotal, page = screen.scrollPage
        guard total > page, page > 0 else {
            scroller.knobProportion = 1
            scroller.doubleValue = 0
            scroller.isEnabled = false
            return
        }
        scroller.isEnabled = true
        scroller.knobProportion = CGFloat(page) / CGFloat(total)
        scroller.doubleValue = Double(screen.scrollStart) / Double(total - page)
    }

    @objc private func scrollerMoved(_ sender: NSScroller) {
        guard let session = controller.session else { return }
        let range = screen.scrollTotal - screen.scrollPage
        switch sender.hitPart {
        case .decrementPage: session.scroll(.lines(-max(1, screen.scrollPage - 1)))
        case .incrementPage: session.scroll(.lines(max(1, screen.scrollPage - 1)))
        case .decrementLine: session.scroll(.lines(-1))
        case .incrementLine: session.scroll(.lines(1))
        default: session.scroll(.toLine(Int((sender.doubleValue * Double(range)).rounded())))
        }
    }

    public override func scrollWheel(with event: NSEvent) {
        guard let session = controller.session else { return }
        let (column, row) = cell(at: convert(event.locationInWindow, from: nil))
        let modifiers = mouseModifiers(event)
        if screen.rawMouse && !(modifiers.contains(.shift)) {
            // Whole notches for the application.
            scrollAccumulator += event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaY / (renderer.font.cellHeight * 3) : event.scrollingDeltaY
            let notches = Int(scrollAccumulator)
            if notches != 0 {
                scrollAccumulator -= CGFloat(notches)
                session.wheel(notches: notches, column: column, row: row, modifiers: modifiers)
            }
        } else {
            // Lines of scrollback; trackpads scroll smoothly by line.
            scrollAccumulator += event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaY / renderer.font.cellHeight : event.scrollingDeltaY * 5
            let lines = Int(scrollAccumulator)
            if lines != 0 {
                scrollAccumulator -= CGFloat(lines)
                session.scroll(.lines(-lines))
            }
        }
    }

    // MARK: Focus

    public override func becomeFirstResponder() -> Bool {
        controller.session?.setFocus(window?.isKeyWindow ?? false)
        return true
    }

    public override func resignFirstResponder() -> Bool {
        controller.session?.setFocus(false)
        return true
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged),
                                                   name: name, object: window)
        }
        // The terminal takes the keyboard as soon as its window shows.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    @objc private func windowKeyChanged() {
        controller.session?.setFocus(window?.isKeyWindow == true && window?.firstResponder === self)
    }

    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        guard let session = controller.session else { return }
        NSCursor.setHiddenUntilMouseMoves(true)
        if hasMarkedText() {
            inputContext?.handleEvent(event)
            return
        }
        switch TerminalKeyMapper.action(for: event, optionIsMeta: optionIsMeta,
                                        commandIsMeta: commandIsMeta) {
        case .key(let key, let modifiers):
            session.key(key, modifiers: modifiers)
        case .text(let text, let modifiers):
            session.type(text, modifiers: modifiers)
        case .interpret:
            if inputContext?.handleEvent(event) != true {
                interpretKeyEvents([event])
            }
        case .ignore:
            super.keyDown(with: event)
        }
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Command combinations reach the terminal only when Command is
        // configured as Meta; otherwise they belong to the menus.
        guard commandIsMeta, event.type == .keyDown,
              event.modifierFlags.contains(.command), window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    public override func doCommand(by selector: Selector) {
        // Editing commands are not terminal input; keys PuTTY translates
        // never get here.
    }

    // MARK: NSTextInputClient

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        unmarkText()
        if !text.isEmpty {
            controller.session?.type(text)
        }
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let attributed = string as? NSAttributedString {
            markedText = NSMutableAttributedString(attributedString: attributed)
        } else {
            markedText = NSMutableAttributedString(string: string as? String ?? "")
        }
        controller.session?.setPreedit(markedText.length > 0 ? markedText.string : nil)
    }

    public func unmarkText() {
        if markedText.length > 0 {
            markedText = NSMutableAttributedString()
            controller.session?.setPreedit(nil)
        }
        inputContext?.discardMarkedText()
    }

    public func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    public func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length)
                              : NSRange(location: NSNotFound, length: 0)
    }

    public func hasMarkedText() -> Bool { markedText.length > 0 }

    public func attributedSubstring(forProposedRange range: NSRange,
                                    actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let cellRect = NSRect(x: Self.border + CGFloat(screen.cursorColumn) * renderer.font.cellWidth,
                              y: Self.border + CGFloat(screen.cursorRow) * renderer.font.cellHeight,
                              width: renderer.font.cellWidth, height: renderer.font.cellHeight)
        return window?.convertToScreen(convert(cellRect, to: nil)) ?? cellRect
    }

    public func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    // MARK: Mouse

    private func cell(at point: NSPoint) -> (Int, Int) {
        let column = Int(((point.x - Self.border) / renderer.font.cellWidth).rounded(.down))
        let row = Int(((point.y - Self.border) / renderer.font.cellHeight).rounded(.down))
        return (column, row)
    }

    private func mouseModifiers(_ event: NSEvent) -> TerminalModifiers {
        var modifiers: TerminalModifiers = []
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        // Option plays Windows PuTTY's Alt here (rectangular selection).
        if event.modifierFlags.contains(.option) { modifiers.insert(.meta) }
        return modifiers
    }

    private func sendMouse(_ event: NSEvent, button: TerminalMouseButton, action: TerminalMouseAction) {
        let (column, row) = cell(at: convert(event.locationInWindow, from: nil))
        controller.session?.mouse(button, action, column: column, row: row,
                                  modifiers: mouseModifiers(event))
    }

    private func press(_ event: NSEvent, _ button: TerminalMouseButton) {
        window?.makeFirstResponder(self)
        pressedButton = button
        let action: TerminalMouseAction = switch event.clickCount {
        case 2: .doubleClick
        case 3...: .tripleClick
        default: .click
        }
        sendMouse(event, button: button, action: action)
    }

    public override func mouseDown(with event: NSEvent) { press(event, .left) }
    public override func rightMouseDown(with event: NSEvent) { press(event, .right) }
    public override func otherMouseDown(with event: NSEvent) { press(event, .middle) }
    public override func mouseDragged(with event: NSEvent) { sendMouse(event, button: .left, action: .drag) }
    public override func rightMouseDragged(with event: NSEvent) { sendMouse(event, button: .right, action: .drag) }
    public override func otherMouseDragged(with event: NSEvent) { sendMouse(event, button: .middle, action: .drag) }
    public override func mouseUp(with event: NSEvent) { sendMouse(event, button: .left, action: .release) }
    public override func rightMouseUp(with event: NSEvent) { sendMouse(event, button: .right, action: .release) }
    public override func otherMouseUp(with event: NSEvent) { sendMouse(event, button: .middle, action: .release) }

    public override func mouseMoved(with event: NSEvent) {
        if screen.rawMouse {
            sendMouse(event, button: .left, action: .move)
        }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    public override func resetCursorRects() {
        let terminalRect = NSRect(x: 0, y: 0, width: bounds.width - scrollerWidth, height: bounds.height)
        addCursorRect(terminalRect, cursor: screen.rawMousePointer ? .arrow : .iBeam)
    }

    // MARK: Clipboard, bell

    public func terminal(_ controller: SessionController, write text: String, to clipboard: PuTTYClipboard) {
        switch clipboard {
        case .selection:
            TerminalSelectionBuffer.text = text
            lastSelection = text
        case .system:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    public func terminal(_ controller: SessionController, requestsPasteFrom clipboard: PuTTYClipboard) {
        let text = switch clipboard {
        case .selection: TerminalSelectionBuffer.text
        case .system: NSPasteboard.general.string(forType: .string) ?? ""
        }
        controller.session?.paste(text)
    }

    public func terminal(_ controller: SessionController, ringBell mode: Int32) {
        switch mode {
        case 0:                                         // BELL_DISABLED
            break
        case 2:                                         // BELL_VISUAL
            flashVisualBell()
        default:                                        // default, wave, PC speaker
            NSSound.beep()
        }
    }

    private func flashVisualBell() {
        guard let layer else { return }
        let flash = CALayer()
        flash.frame = layer.bounds
        flash.backgroundColor = TerminalRenderer.cgColour(screen.defaultForeground)
        flash.opacity = 0.6
        layer.addSublayer(flash)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { flash.removeFromSuperlayer() }
    }

    /// Edit > Copy: the current selection to the general pasteboard.
    @objc public func copy(_ sender: Any?) {
        guard !lastSelection.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastSelection, forType: .string)
    }

    /// Edit > Paste: the general pasteboard, bracketed-paste aware.
    @objc public func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string) {
            controller.session?.paste(text)
        }
    }

    /// PuTTY's "Copy All to Clipboard".
    @objc public func copyAllToClipboard(_ sender: Any?) {
        controller.session?.copyAll()
    }

    public func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): !lastSelection.isEmpty
        case #selector(paste(_:)): NSPasteboard.general.string(forType: .string) != nil
        case #selector(copyAllToClipboard(_:)): controller.session != nil
        default: true
        }
    }
}
