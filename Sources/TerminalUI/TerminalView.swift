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

/// What the terminal view takes from a session's settings: the options
/// that GTK PuTTY's window code (unix/window.c), not the terminal, acts
/// on, plus the Windows window options that have a macOS counterpart.
public struct TerminalViewOptions: Equatable, Sendable {
    /// GTK PuTTY's Window/Fonts settings.
    public var fonts: TerminalFontSpec
    public var fontName: String? { fonts.fontName }
    public var showsScrollbar: Bool
    /// Windows' "Display scrollbar in full screen mode".
    public var scrollbarInFullScreen: Bool
    /// Windows' "When window is resized" (`LockSize`): 0 change rows and
    /// columns, 1 forbid resizing, 2 change the font size, 3 change the
    /// font size only when maximised (zoomed or full screen).
    public var resizeAction: Int
    /// GTK PuTTY's "Scrollbar on left".
    public var scrollbarOnLeft: Bool
    /// "Gap between text and window edge", in points.
    public var border: CGFloat
    public var optionIsMeta: Bool
    public var commandIsMeta: Bool
    /// "Hide mouse pointer when typing in window".
    public var hidesMousePointerWhenTyping: Bool
    /// `Beep` = 3 ("Play a custom sound file"): this file.
    public var bellSoundFile: String
    /// "Taskbar/caption indication on bell": 0 disabled, 1 flashing,
    /// 2 steady (Dock: one bounce, or bouncing until activated).
    public var bellIndication: Int
    /// "Ensure window is always on top".
    public var alwaysOnTop: Bool
    /// Windows' "Full screen on Alt-Enter", as Option-Return.
    public var fullScreenOnOptionReturn: Bool
    /// "Separate window and icon titles" (`WinNameAlways` off): a
    /// minimised window shows the icon title.
    public var separateIconTitle: Bool

    public init(settings: PuTTYSettings) {
        func flag(_ keyword: String, default value: Bool) -> Bool {
            settings[keyword].map { (Int($0) ?? 0) != 0 } ?? value
        }
        fonts = TerminalFontSpec(fontName: settings["FontName"], boldFontName: settings["BoldFontName"],
                                 wideFontName: settings["WideFontName"],
                                 wideBoldFontName: settings["WideBoldFontName"],
                                 shadowBold: flag("ShadowBold", default: false),
                                 shadowBoldOffset: Int(settings["ShadowBoldOffset"] ?? "") ?? 1)
        showsScrollbar = flag("ScrollBar", default: true)
        scrollbarInFullScreen = flag("ScrollBarFullScreen", default: false)
        resizeAction = Int(settings["LockSize"] ?? "") ?? 0
        scrollbarOnLeft = flag("ScrollbarOnLeft", default: false)
        border = CGFloat(max(0, Int(settings["WindowBorder"] ?? "") ?? 1))
        optionIsMeta = flag("OSXOptionMeta", default: true)
        commandIsMeta = flag("OSXCommandMeta", default: false)
        hidesMousePointerWhenTyping = flag("HideMousePtr", default: false)
        bellSoundFile = settings["Beep"] == "3" ? settings["BellWaveFile"] ?? "" : ""
        bellIndication = Int(settings["BeepInd"] ?? "") ?? 0
        alwaysOnTop = flag("AlwaysOnTop", default: false)
        fullScreenOnOptionReturn = flag("FullScreenOnAltEnter", default: false)
        separateIconTitle = !flag("WinNameAlways", default: true)
    }
}

/// The terminal window's content: draws a session's terminal and turns
/// keyboard, mouse, scroll and focus events into terminal input.
@MainActor
public final class TerminalView: NSView, @preconcurrency NSTextInputClient,
    NSUserInterfaceValidations, SessionTerminalDelegate {
    public let controller: SessionController
    public let screen = TerminalScreen()
    public private(set) var renderer: TerminalRenderer

    public private(set) var options: TerminalViewOptions
    /// Space between the window edge and the cells.
    public var border: CGFloat { options.border }

    private let scroller = NSScroller()
    private var showsScrollbar: Bool {
        options.showsScrollbar && (!isFullScreen || options.scrollbarInFullScreen)
    }

    private var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }
    /// Windows' IsZoomed: zoomed, or full screen.
    private var isMaximised: Bool { isFullScreen || window?.isZoomed == true }

    /// Whether resizing the window changes the font size, keeping the
    /// rows and columns ("When window is resized").
    private var scalesFont: Bool {
        options.resizeAction == 2 || (options.resizeAction == 3 && isMaximised)
    }
    private var bellSound: NSSound?
    private var observingIconTitle = false
    private var markedText = NSMutableAttributedString()
    private var lastSelection = ""
    /// The last selection as RTF, when Copy as RTF made it styled.
    public private(set) var lastSelectionRTF: Data?
    private var gridSize = (columns: 0, rows: 0)
    private var scrollAccumulator: CGFloat = 0
    private var pressedButton: TerminalMouseButton?
    private var trackingArea: NSTrackingArea?
    /// Whether the session has the system colours yet.
    private var sentSystemColours = false

    public init(controller: SessionController) {
        self.controller = controller
        options = TerminalViewOptions(settings: controller.settings)
        renderer = TerminalRenderer(font: TerminalFont(spec: options.fonts))
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
        observeIconTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The view size that holds `columns` x `rows` cells.
    public func size(columns: Int, rows: Int) -> NSSize {
        Self.size(columns: columns, rows: rows, font: renderer.font, options: options)
    }

    /// The view size for `settings`' font, scrollbar, border and terminal
    /// size (`TermWidth` x `TermHeight`).
    public static func defaultSize(for settings: PuTTYSettings) -> NSSize {
        let options = TerminalViewOptions(settings: settings)
        return size(columns: Int(settings["TermWidth"] ?? "") ?? 80,
                    rows: Int(settings["TermHeight"] ?? "") ?? 24,
                    font: TerminalFont(spec: options.fonts), options: options)
    }

    private static func size(columns: Int, rows: Int, font: TerminalFont,
                             options: TerminalViewOptions) -> NSSize {
        let scroller = options.showsScrollbar
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        return NSSize(width: CGFloat(columns) * font.cellWidth + 2 * options.border + scroller,
                      height: CGFloat(rows) * font.cellHeight + 2 * options.border)
    }

    /// Where the cells start: inside the border, right of a scrollbar on
    /// the left.
    public var textOrigin: NSPoint {
        NSPoint(x: border + (options.scrollbarOnLeft ? scrollerWidth : 0), y: border)
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
        if !sentSystemColours {
            sendSystemColours()
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
        NSRect(x: textOrigin.x, y: textOrigin.y + CGFloat(row) * renderer.font.cellHeight,
               width: CGFloat(screen.columns) * renderer.font.cellWidth,
               height: renderer.font.cellHeight)
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(TerminalRenderer.cgColour(screen.defaultBackground))
        context.fill(dirtyRect)
        guard screen.rows > 0 else { return }
        let h = renderer.font.cellHeight
        let origin = textOrigin
        let first = max(0, Int(((dirtyRect.minY - origin.y) / h).rounded(.down)))
        let last = min(screen.rows, Int(((dirtyRect.maxY - origin.y) / h).rounded(.up)))
        guard first < last else { return }
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        renderer.draw(screen, rows: first..<last, in: context)
        context.restoreGState()
    }

    // MARK: Layout

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scroller.frame = NSRect(x: options.scrollbarOnLeft ? 0 : newSize.width - scrollerWidth, y: 0,
                                width: scrollerWidth, height: newSize.height)
        resizeTerminal()
    }

    private func resizeTerminal() {
        let usableWidth = bounds.width - scrollerWidth - 2 * border
        let usableHeight = bounds.height - 2 * border
        if scalesFont, gridSize != (0, 0) {
            fitFont(columns: gridSize.columns, rows: gridSize.rows,
                    width: usableWidth, height: usableHeight)
            return
        }
        let configured = TerminalFont(spec: options.fonts)
        if renderer.font != configured {
            renderer = TerminalRenderer(font: configured)    // back from scaling
            needsDisplay = true
        }
        let columns = max(1, Int(usableWidth / renderer.font.cellWidth))
        let rows = max(1, Int(usableHeight / renderer.font.cellHeight))
        guard (columns, rows) != gridSize, let session = controller.session else { return }
        gridSize = (columns, rows)
        session.resize(columns: columns, rows: rows,
                       pixelWidth: Int(CGFloat(columns) * renderer.font.cellWidth),
                       pixelHeight: Int(CGFloat(rows) * renderer.font.cellHeight))
    }

    /// The largest font (the configured fonts, scaled alike) that fits
    /// `columns` x `rows` cells in the space.
    private func fitFont(columns: Int, rows: Int, width: CGFloat, height: CGFloat) {
        let base = TerminalFont(spec: options.fonts)
        let factor = min(width / (CGFloat(columns) * base.cellWidth),
                         height / (CGFloat(rows) * base.cellHeight))
        var size = max(4, (base.font.pointSize * factor * 2).rounded(.down) / 2)
        var font = TerminalFont(spec: options.fonts.scaled(by: size / base.font.pointSize))
        while size > 4 && (CGFloat(columns) * font.cellWidth > width || CGFloat(rows) * font.cellHeight > height) {
            size -= 0.5
            font = TerminalFont(spec: options.fonts.scaled(by: size / base.font.pointSize))
        }
        if font != renderer.font {
            renderer = TerminalRenderer(font: font)
            needsDisplay = true
        }
    }

    /// An application's resize request (windows/window.c
    /// wintw_request_resize): refused if resizing is forbidden, or if the
    /// window is maximised and resizing changes rows and columns; with a
    /// scaled font, the window keeps its size and the font fits the new
    /// size; otherwise the window is resized to fit.
    public func terminal(_ controller: SessionController, requestsResizeTo columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        switch options.resizeAction {
        case 1:
            return
        case 0 where isMaximised:
            return
        default:
            break
        }
        if scalesFont {
            gridSize = (columns, rows)
            controller.session?.resize(columns: columns, rows: rows)
            resizeTerminal()
            return
        }
        resizeWindow(columns: columns, rows: rows)
    }

    /// Resize the window to hold `columns` x `rows`, keeping its top-left
    /// corner.
    private func resizeWindow(columns: Int, rows: Int) {
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

    /// "Use system colours" on macOS: the text and background colours,
    /// and the selection colours for the cursor (Windows PuTTY uses its
    /// highlight colours), as the view's appearance (light or dark)
    /// resolves them.
    func sendSystemColours() {
        guard let session = controller.session else { return }
        var values: [UInt32] = []
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for colour in [NSColor.textColor, .textBackgroundColor,
                           .selectedTextColor, .selectedTextBackgroundColor] {
                let c = colour.usingColorSpace(.sRGB) ?? .black
                values.append(UInt32((c.redComponent * 255).rounded()) << 16
                              | UInt32((c.greenComponent * 255).rounded()) << 8
                              | UInt32((c.blueComponent * 255).rounded()))
            }
        }
        session.setSystemColours(foreground: values[0], background: values[1],
                                 cursorText: values[2], cursor: values[3])
        sentSystemColours = true
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        sendSystemColours()
    }

    /// Full screen changes the scrollbar ("Display scrollbar in full
    /// screen mode") and, with "only when maximised", the font.
    @objc private func windowFullScreenChanged(_ notification: Notification) {
        scroller.isHidden = !showsScrollbar
        setFrameSize(frame.size)
        needsDisplay = true
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        sendSystemColours()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged),
                                                   name: name, object: window)
        }
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowFullScreenChanged),
                                                   name: name, object: window)
        }
        applyWindowOptions()
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
        if options.hidesMousePointerWhenTyping {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if options.fullScreenOnOptionReturn, event.keyCode == 36,
           flags.intersection([.option, .command, .control, .shift]) == .option {
            window?.toggleFullScreen(nil)
            return
        }
        if hasMarkedText() {
            inputContext?.handleEvent(event)
            return
        }
        switch TerminalKeyMapper.action(for: event, optionIsMeta: options.optionIsMeta,
                                        commandIsMeta: options.commandIsMeta) {
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
        guard options.commandIsMeta, event.type == .keyDown,
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
        let cellRect = NSRect(x: textOrigin.x + CGFloat(screen.cursorColumn) * renderer.font.cellWidth,
                              y: textOrigin.y + CGFloat(screen.cursorRow) * renderer.font.cellHeight,
                              width: renderer.font.cellWidth, height: renderer.font.cellHeight)
        return window?.convertToScreen(convert(cellRect, to: nil)) ?? cellRect
    }

    public func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    // MARK: Mouse

    private func cell(at point: NSPoint) -> (Int, Int) {
        let column = Int(((point.x - textOrigin.x) / renderer.font.cellWidth).rounded(.down))
        let row = Int(((point.y - textOrigin.y) / renderer.font.cellHeight).rounded(.down))
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

    /// The window's menu, for a right-click that asks for it.
    public var contextMenu: (() -> NSMenu?)?

    /// windows/window.c WM_RBUTTONDOWN: the menu, not the terminal, gets
    /// a right-click with Ctrl (also GTK PuTTY's gesture), or any
    /// right-click when "Action of mouse buttons" is Windows
    /// (`MouseIsXterm` 2), even if the application has the mouse.
    public static func rightClickShowsMenu(control: Bool, mouseIsXterm: String?) -> Bool {
        control || mouseIsXterm == "2"
    }

    public override func mouseDown(with event: NSEvent) { press(event, .left) }
    public override func rightMouseDown(with event: NSEvent) {
        if Self.rightClickShowsMenu(control: event.modifierFlags.contains(.control),
                                    mouseIsXterm: controller.settings["MouseIsXterm"]),
           let menu = contextMenu?() {
            window?.makeFirstResponder(self)
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        press(event, .right)
    }
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
        let terminalRect = NSRect(x: options.scrollbarOnLeft ? scrollerWidth : 0, y: 0,
                                  width: bounds.width - scrollerWidth, height: bounds.height)
        addCursorRect(terminalRect, cursor: screen.rawMousePointer ? .arrow : .iBeam)
    }

    // MARK: Clipboard, bell

    public func terminal(_ controller: SessionController, write text: String, to clipboard: PuTTYClipboard) {
        switch clipboard {
        case .selection:
            TerminalSelectionBuffer.text = text
            lastSelection = text
            lastSelectionRTF = nil
        case .system:
            Self.writeToGeneralPasteboard(text, rtf: nil)
        }
    }

    /// Copy as RTF: the plain text as usual, plus RTF in the terminal's
    /// font (windows/window.c win_clip_write adds RTF beside the text).
    public func terminal(_ controller: SessionController, write runs: [PuTTYStyleRun],
                         to clipboard: PuTTYClipboard) {
        let text = runs.map(\.text).joined()
        let rtf = Self.rtf(for: runs, font: renderer.font)
        switch clipboard {
        case .selection:
            TerminalSelectionBuffer.text = text
            lastSelection = text
            lastSelectionRTF = rtf
        case .system:
            Self.writeToGeneralPasteboard(text, rtf: rtf)
        }
    }

    /// The runs of a styled copy as RTF. Runs in the terminal's default
    /// colours carry no colour, so the receiver uses its own.
    public static func rtf(for runs: [PuTTYStyleRun], font: TerminalFont) -> Data? {
        let string = NSMutableAttributedString()
        for run in runs {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: run.bold ? font.boldFont : font.font,
            ]
            if let fg = run.fg { attributes[.foregroundColor] = colour(fg) }
            if let bg = run.bg { attributes[.backgroundColor] = colour(bg) }
            if run.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            string.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return string.rtf(from: NSRange(location: 0, length: string.length),
                          documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    private static func colour(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    private static func writeToGeneralPasteboard(_ text: String, rtf: Data?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if let rtf { pasteboard.setData(rtf, forType: .rtf) }
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
            return
        case 2:                                         // BELL_VISUAL
            flashVisualBell()
        case 3:                                         // BELL_WAVEFILE
            playBellSound()
        default:                                        // default, PC speaker
            NSSound.beep()
        }
        indicateBell()
    }

    /// Windows PuTTY plays the file, and beeps instead if it cannot.
    private func playBellSound() {
        if bellSound == nil, !options.bellSoundFile.isEmpty {
            bellSound = NSSound(contentsOf: URL(fileURLWithPath: options.bellSoundFile), byReference: true)
        }
        guard let bellSound else {
            NSSound.beep()
            return
        }
        bellSound.stop()
        bellSound.play()
    }

    /// "Taskbar/caption indication on bell", for a window in the
    /// background: the Dock icon bounces once (flashing) or until the
    /// app is activated (steady).
    private func indicateBell() {
        guard options.bellIndication != 0, !(NSApp.isActive && window?.isKeyWindow == true) else { return }
        NSApp.requestUserAttention(options.bellIndication == 2 ? .criticalRequest : .informationalRequest)
    }

    // MARK: Window options

    private func applyWindowOptions() {
        guard let window else { return }
        window.level = options.alwaysOnTop ? .floating : .normal
        // "Forbid resizing completely": no resizing, zooming or full screen.
        if options.resizeAction == 1 {
            window.styleMask.remove(.resizable)
            window.collectionBehavior.insert(.fullScreenNone)
        } else {
            window.styleMask.insert(.resizable)
            window.collectionBehavior.remove(.fullScreenNone)
        }
        // Left alone otherwise, so the minimised title follows the title.
        if options.separateIconTitle {
            window.miniwindowTitle = controller.iconTitle.isEmpty ? window.title : controller.iconTitle
        }
    }

    private func observeIconTitle() {
        guard options.separateIconTitle, !observingIconTitle else { return }
        observingIconTitle = true
        withObservationTracking {
            _ = controller.iconTitle
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observingIconTitle = false
                self?.applyWindowOptions()
                self?.observeIconTitle()
            }
        }
    }

    // MARK: Change Settings

    /// GTK PuTTY's after_change_settings_dialog, frontend half: new font,
    /// scrollbar, border and window options; the window is resized to the
    /// configured size if that, the font, the border or the scrollbar
    /// changed.
    public func terminal(_ controller: SessionController, settingsChangedFrom old: PuTTYSettings,
                         to new: PuTTYSettings) {
        let previous = options
        options = TerminalViewOptions(settings: new)
        if options.fonts != previous.fonts {
            renderer = TerminalRenderer(font: TerminalFont(spec: options.fonts))
        }
        if options.bellSoundFile != previous.bellSoundFile {
            bellSound = nil
        }
        scroller.isHidden = !showsScrollbar
        if previous.separateIconTitle && !options.separateIconTitle, let window {
            window.miniwindowTitle = window.title
        }
        applyWindowOptions()
        observeIconTitle()

        let columns = Int(new["TermWidth"] ?? "") ?? gridSize.columns
        let rows = Int(new["TermHeight"] ?? "") ?? gridSize.rows
        let needsSize = old["TermWidth"] != new["TermWidth"] || old["TermHeight"] != new["TermHeight"]
            || options.border != previous.border || options.fontName != previous.fontName
            || options.showsScrollbar != previous.showsScrollbar
            || options.scrollbarOnLeft != previous.scrollbarOnLeft
        if needsSize {
            gridSize = (0, 0)               // tell the terminal the size again
            if window != nil {
                resizeWindow(columns: columns, rows: rows)
            }
            setFrameSize(frame.size)
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
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
        Self.writeToGeneralPasteboard(lastSelection, rtf: lastSelectionRTF)
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
