import AppKit
import Foundation
import PuTTYBridge
import SessionLayer
import TerminalUI
import TestServers
import Testing

/// A connected Raw session whose remote end the test drives.
@MainActor
final class ScriptedTerminal {
    let peer: ScriptedPeer
    let controller: SessionController
    let view: TerminalView
    let window: NSWindow

    init(settings extra: [String: String] = [:]) throws {
        try TestCore.initialize()
        peer = try ScriptedPeer()
        var settings = rawSettings(port: peer.port)
        settings["LocalEcho"] = "1"      // force off: keys go straight out
        settings["LocalEdit"] = "1"
        for (key, value) in extra { settings[key] = value }
        controller = SessionController(settings: settings)
        try controller.prepare()
        view = TerminalView(controller: controller)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: view.size(columns: 80, rows: 24)),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeFirstResponder(view)
        try controller.connect()
        guard peer.waitForConnection() else { throw PuTTYBridgeError("no connection") }
    }

    var screen: TerminalScreen { view.screen }

    /// Waits until `condition` holds for the view's screen.
    func wait(timeout: Duration = .seconds(10),
              _ condition: (TerminalScreen) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !(screen.rows > 0 && condition(screen)) {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    func waitForRow(_ row: Int, _ text: String) async -> Bool {
        await wait { $0.rows > row && $0.text(row: row) == text }
    }

    func received(_ count: Int) -> String {
        String(decoding: peer.receive(count: count), as: UTF8.self)
    }

    func close() {
        window.close()
        peer.disconnect()
    }
}

/// A key event for `view`.
@MainActor
func keyEvent(_ characters: String, ignoringModifiers: String? = nil, keyCode: UInt16,
              modifiers: NSEvent.ModifierFlags = [], window: NSWindow) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                     windowNumber: window.windowNumber, context: nil, characters: characters,
                     charactersIgnoringModifiers: ignoringModifiers ?? characters,
                     isARepeat: false, keyCode: keyCode)!
}

extension KitTests {
    @Suite("Terminal")
    @MainActor
    struct TerminalTests {
        @Test func screenShowsTextColoursAndUnicode() async throws {
            let term = try ScriptedTerminal()
            defer { term.close() }
            #expect(await term.wait { $0.columns == 80 && $0.rows == 24 })

            term.peer.send("plain \u{1B}[31mred\u{1B}[0m \u{1B}[1;4mbold\u{1B}[0m 中e\u{301}\r\n")
            #expect(await term.waitForRow(0, "plain red bold 中e\u{301}"))
            let screen = term.screen
            #expect(screen.cell(column: 6, row: 0).foreground == 0xBB0000)
            #expect(screen.cell(column: 10, row: 0).foreground == 0xFFFFFF) // bold as colour
            #expect(screen.cell(column: 10, row: 0).flags.contains(.underline))
            #expect(screen.cell(column: 15, row: 0).flags.contains(.wide))
            #expect(screen.cell(column: 16, row: 0).flags.contains(.wideContinuation))
            #expect(screen.cell(column: 17, row: 0).scalars == ["e", "\u{301}"])
            #expect(screen.defaultBackground == 0x000000)
        }

        @Test func titleAndResize() async throws {
            let term = try ScriptedTerminal()
            defer { term.close() }
            term.peer.send("\u{1B}]2;Remote title\u{07}")
            #expect(await waitUntil { term.controller.title == "Remote title" })

            // A bigger window means a bigger terminal.
            term.window.setContentSize(term.view.size(columns: 100, rows: 30))
            #expect(await term.wait { $0.columns == 100 && $0.rows == 30 })
        }

        @Test func keyboardInput() async throws {
            let term = try ScriptedTerminal()
            defer { term.close() }
            let view = term.view, window = term.window
            #expect(await term.wait { $0.rows > 0 })

            view.keyDown(with: keyEvent("\u{F700}", keyCode: 126, window: window))   // Up
            #expect(term.received(3) == "\u{1B}[A")
            view.keyDown(with: keyEvent("\r", keyCode: 36, window: window))          // Return
            #expect(term.received(1) == "\r")
            view.keyDown(with: keyEvent("\u{7F}", keyCode: 51, window: window))      // Backspace
            #expect(term.received(1) == "\u{7F}")
            view.keyDown(with: keyEvent("\u{3}", ignoringModifiers: "c", keyCode: 8,
                                        modifiers: .control, window: window))      // Ctrl-C
            #expect(term.received(1) == "\u{3}")
            view.keyDown(with: keyEvent("\u{F704}", keyCode: 122, window: window))   // F1
            #expect(term.received(5) == "\u{1B}[11~")
            // Option is Meta by default (OSXOptionMeta): Option-x = ESC x.
            view.keyDown(with: keyEvent("≈", ignoringModifiers: "x", keyCode: 7,
                                        modifiers: .option, window: window))
            #expect(term.received(2) == "\u{1B}x")
            // Ordinary text goes through the input method.
            view.insertText("hé", replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(term.received(3) == "hé")
        }

        @Test func optionIsTextWhenNotMeta() async throws {
            let term = try ScriptedTerminal(settings: ["OSXOptionMeta": "0"])
            defer { term.close() }
            #expect(await term.wait { $0.rows > 0 })
            let action = TerminalKeyMapper.action(
                for: keyEvent("≈", ignoringModifiers: "x", keyCode: 7, modifiers: .option,
                              window: term.window),
                optionIsMeta: false, commandIsMeta: false)
            #expect(action == .interpret)
        }

        @Test func pasteSelectionAndCopyAll() async throws {
            let term = try ScriptedTerminal()
            defer { term.close() }
            term.peer.send("\u{1B}[?2004h")                 // bracketed paste
            term.peer.send("copy this line\r\n")
            #expect(await term.waitForRow(0, "copy this line"))

            term.controller.session!.paste("pasted")
            #expect(term.received(18) == "\u{1B}[200~pasted\u{1B}[201~")

            // Select "copy this" with the mouse: it becomes the selection.
            let session = term.controller.session!
            session.mouse(.left, .click, column: 0, row: 0)
            session.mouse(.left, .drag, column: 8, row: 0)
            session.mouse(.left, .release, column: 8, row: 0)
            #expect(await waitUntil { TerminalSelectionBuffer.text == "copy this" })
            #expect(term.view.lastSelectionRTF == nil)      // PasteRTF is off
        }

        /// Copy as RTF: the selection keeps its colours, bold and underline;
        /// text in the default colours carries none.
        @Test func copyAsRTF() async throws {
            let term = try ScriptedTerminal(settings: ["PasteRTF": "1", "BoldAsColour": "2"])
            defer { term.close() }
            term.peer.send("plain \u{1B}[1;31mbold\u{1B}[0m \u{1B}[4mund\u{1B}[0m\r\n")
            #expect(await term.waitForRow(0, "plain bold und"))

            let session = term.controller.session!
            session.mouse(.left, .click, column: 0, row: 0)
            session.mouse(.left, .drag, column: 13, row: 0)
            session.mouse(.left, .release, column: 13, row: 0)
            #expect(await waitUntil { term.view.lastSelectionRTF != nil })
            #expect(TerminalSelectionBuffer.text == "plain bold und")

            let rtf = try #require(term.view.lastSelectionRTF)
            let copied = try #require(NSAttributedString(rtf: rtf, documentAttributes: nil))
            #expect(copied.string == "plain bold und")
            func attributes(at index: Int) -> [NSAttributedString.Key: Any] {
                copied.attributes(at: index, effectiveRange: nil)
            }
            #expect(attributes(at: 0)[.foregroundColor] == nil)
            let bold = attributes(at: 6)
            let red = try #require((bold[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB))
            #expect(abs(red.redComponent - 1) < 0.01 && abs(red.greenComponent - 85.0 / 255) < 0.01)
            let boldFont = try #require(bold[.font] as? NSFont)
            #expect(boldFont.fontDescriptor.symbolicTraits.contains(.bold))
            #expect(attributes(at: 11)[.underlineStyle] as? Int == NSUnderlineStyle.single.rawValue)
            #expect(attributes(at: 11)[.foregroundColor] == nil)
        }

        @Test func scrollbackFollowsTheScroller() async throws {
            let term = try ScriptedTerminal()
            defer { term.close() }
            term.peer.send((1...60).map { "line \($0)" }.joined(separator: "\r\n"))
            #expect(await term.waitForRow(23, "line 60"))
            #expect(term.screen.scrollTotal == 60 && term.screen.scrollPage == 24)
            term.controller.session!.scroll(.lines(-10))
            #expect(await term.waitForRow(23, "line 50"))
            term.controller.session!.scroll(.toBottom)
            #expect(await term.waitForRow(23, "line 60"))
        }

        @Test func rendersCellsIntoPixels() async throws {
            let term = try ScriptedTerminal()
            defer { term.close() }
            // Row 0: a red-background cell, then an upper-half block
            // (U+2580) in white: proves glyphs are upright.
            term.peer.send("\u{1B}[41m \u{1B}[0m\u{1B}[97m\u{2580}\u{1B}[0m Hello, 世界 é\u{1B}[4mU\u{1B}[0m\u{1B}[3;1H")
            #expect(await term.wait { $0.cell(column: 1, row: 0).scalars == ["\u{2580}"] })

            let view = term.view
            view.layoutSubtreeIfNeeded()
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: rep)
            if let path = ProcessInfo.processInfo.environment["SPB_RENDER_DUMP"] {
                try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
            }
            let font = view.renderer.font
            let scale = CGFloat(rep.pixelsWide) / view.bounds.width
            func pixel(_ x: CGFloat, _ y: CGFloat) -> UInt32 {
                let colour = rep.colorAt(x: Int(x * scale), y: Int(y * scale))!
                    .usingColorSpace(.sRGB)!
                return UInt32((colour.redComponent * 255).rounded()) << 16
                    | UInt32((colour.greenComponent * 255).rounded()) << 8
                    | UInt32((colour.blueComponent * 255).rounded())
            }
            let b = view.border, w = font.cellWidth, h = font.cellHeight
            // Colours are sRGB; the bitmap may be in the display's colour
            // space, so compare approximately.
            func close(_ a: UInt32, _ b: UInt32) -> Bool {
                for shift: UInt32 in [0, 8, 16] {
                    let x = Int((a >> shift) & 0xFF)
                    let y = Int((b >> shift) & 0xFF)
                    if abs(x - y) > 0x30 { return false }
                }
                return true
            }
            #expect(close(pixel(b + w / 2, b + h / 2), 0xBB0000))       // red background
            #expect(close(pixel(b + w * 1.5, b + h * 0.25), 0xFFFFFF))  // block's top half
            #expect(close(pixel(b + w * 1.5, b + h * 0.85), 0x000000))  // bottom half empty
            #expect(close(pixel(b + w * 5.5, b + h * 5.5), 0x000000))   // background
        }

        /// GTK PuTTY's shadow bold: a bold glyph is the ordinary glyph
        /// drawn again ShadowBoldOffset points to the right.
        @Test func shadowBoldWidensBoldGlyphs() async throws {
            func inkWidth(shadow: Bool) async throws -> Int {
                let term = try ScriptedTerminal(settings: [
                    "BoldAsColour": "0", "ShadowBold": shadow ? "1" : "0", "ShadowBoldOffset": "3"])
                defer { term.close() }
                term.peer.send("\u{1B}[1mI\u{1B}[0m")
                #expect(await term.wait { $0.cell(column: 0, row: 0).scalars == ["I"] })
                let view = term.view
                view.layoutSubtreeIfNeeded()
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: rep)
                let scale = CGFloat(rep.pixelsWide) / view.bounds.width
                let font = view.renderer.font, b = view.border
                let y = Int((b + font.cellHeight / 2) * scale)
                var columns = 0
                for x in Int(b * scale)..<Int((b + font.cellWidth * 2) * scale) {
                    let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                    if c.redComponent + c.greenComponent + c.blueComponent > 1.2 { columns += 1 }
                }
                return columns
            }
            let plain = try await inkWidth(shadow: false)
            let shadowed = try await inkWidth(shadow: true)
            #expect(plain > 0)
            #expect(shadowed > plain)
        }

        /// "Use system colours": the window's appearance decides the
        /// default colours, and a change of appearance follows.
        @Test func systemColoursFollowTheAppearance() async throws {
            let term = try ScriptedTerminal(settings: ["UseSystemColours": "1"])
            defer { term.close() }
            func brightness(_ rgb: UInt32) -> Int {
                Int((rgb >> 16) & 0xFF) + Int((rgb >> 8) & 0xFF) + Int(rgb & 0xFF)
            }
            term.window.appearance = NSAppearance(named: .aqua)
            term.peer.send("light")
            #expect(await term.wait { brightness($0.defaultBackground) > 3 * 200 })
            #expect(brightness(term.screen.defaultForeground) < 3 * 100)
            term.window.appearance = NSAppearance(named: .darkAqua)
            term.peer.send(" dark")
            #expect(await term.wait { brightness($0.defaultBackground) < 3 * 80 })
            #expect(brightness(term.screen.defaultForeground) > 3 * 150)
        }

        /// "When window is resized": change the font size keeps the rows
        /// and columns; forbid makes the window fixed and refuses the
        /// application's resize requests.
        @Test func resizeActions() async throws {
            let font = try ScriptedTerminal(settings: ["LockSize": "2"])
            defer { font.close() }
            #expect(await font.wait { $0.columns == 80 && $0.rows == 24 })
            let before = font.view.renderer.font.font.pointSize
            font.window.setContentSize(NSSize(width: font.view.frame.width * 1.5,
                                              height: font.view.frame.height * 1.5))
            #expect(font.view.renderer.font.font.pointSize > before)
            try await Task.sleep(for: .milliseconds(200))
            #expect(font.screen.columns == 80 && font.screen.rows == 24)

            let forbid = try ScriptedTerminal(settings: ["LockSize": "1"])
            defer { forbid.close() }
            #expect(await forbid.wait { $0.columns == 80 })
            forbid.view.viewDidMoveToWindow()            // apply window options
            #expect(!forbid.window.styleMask.contains(.resizable))
            let frame = forbid.window.frame
            forbid.view.terminal(forbid.controller, requestsResizeTo: 132, rows: 24)
            #expect(forbid.window.frame == frame)

            // The default: an application's request resizes the window.
            let normal = try ScriptedTerminal()
            defer { normal.close() }
            #expect(await normal.wait { $0.columns == 80 })
            normal.view.terminal(normal.controller, requestsResizeTo: 100, rows: 30)
            #expect(await normal.wait { $0.columns == 100 && $0.rows == 30 })
        }

        /// SwiftUI's windows have a full-size content view: a resize to
        /// rows x columns still leaves room for the title bar (it lost two
        /// or three rows, also on Change Settings' Apply).
        @Test func resizeKeepsTheTitleBarOutOfTheRows() async throws {
            let term = try ScriptedTerminal()
            defer { term.close() }
            // As SwiftUI lays it out: under the title bar, in a view that
            // fills the whole window.
            term.window.styleMask.insert(.fullSizeContentView)
            let container = NSView()
            term.window.contentView = container
            term.window.setContentSize(term.view.size(columns: 80, rows: 26))
            term.view.frame = term.window.contentLayoutRect
            term.view.autoresizingMask = [.width, .height]
            container.addSubview(term.view)
            #expect(term.window.frame.height > term.view.frame.height)
            #expect(await term.wait { $0.columns == 80 })
            term.view.terminal(term.controller, requestsResizeTo: 100, rows: 30)
            #expect(await term.wait { $0.columns == 100 && $0.rows == 30 })
            #expect(term.window.frame.height > term.view.frame.height)
        }

        /// AppKit will not take a floating window full screen: Option-Return
        /// leaves "always on top" first.
        @Test func optionReturnLeavesTheFloatingLevel() async throws {
            let term = try ScriptedTerminal(settings: ["AlwaysOnTop": "1", "FullScreenOnAltEnter": "1"])
            defer { term.close() }
            #expect(await term.wait { $0.columns == 80 })
            term.view.viewDidMoveToWindow()            // apply window options
            #expect(term.window.level == .floating)
            term.view.keyDown(with: keyEvent("\r", keyCode: 36, modifiers: .option, window: term.window))
            #expect(term.window.level == .normal)
            #expect(!term.window.collectionBehavior.contains(.fullScreenNone))
        }

        @Test func sessionEndLeavesTheScreen() async throws {
            let term = try ScriptedTerminal()
            term.peer.send("goodbye\r\n")
            #expect(await term.waitForRow(0, "goodbye"))
            term.peer.disconnect()
            #expect(await term.controller.waitForState(.closed) == .closed)
            #expect(term.screen.text(row: 0) == "goodbye")
            term.close()
        }
    }

    @Suite("Terminal keyboard mapping")
    struct KeyMapperTests {
        func action(_ keyCode: UInt16, _ characters: String, ignoring: String? = nil,
                    _ flags: NSEvent.ModifierFlags = [], optionIsMeta: Bool = true,
                    commandIsMeta: Bool = false) -> TerminalKeyAction {
            TerminalKeyMapper.action(keyCode: keyCode, characters: characters,
                                     charactersIgnoringModifiers: ignoring ?? characters,
                                     charactersWithoutOption: ignoring ?? characters,
                                     modifierFlags: flags, optionIsMeta: optionIsMeta,
                                     commandIsMeta: commandIsMeta)
        }

        @Test func specialKeysAreTranslatedByPuTTY() {
            #expect(action(126, "\u{F700}") == .key(.up, []))
            #expect(action(123, "\u{F702}", [.shift]) == .key(.left, [.shift]))
            #expect(action(122, "\u{F704}") == .key(.function(1), []))
            #expect(action(90, "\u{F717}") == .key(.function(20), []))
            #expect(action(87, "5") == .key(.keypadDigit(5), []))
            #expect(action(76, "\u{3}") == .key(.keypadEnter, []))
            #expect(action(117, "\u{F728}") == .key(.delete, []))
            #expect(action(51, "\u{7F}", [.option]) == .key(.backspace, [.meta]))
        }

        @Test func controlCombinationsBecomeControlCharacters() {
            #expect(action(0, "\u{1}", ignoring: "a", [.control]) == .text("\u{1}", []))
            #expect(action(49, " ", ignoring: " ", [.control]) == .text("\u{0}", []))
            #expect(action(33, "\u{1B}", ignoring: "[", [.control]) == .text("\u{1B}", []))
            #expect(action(27, "\u{1F}", ignoring: "-", [.control]) == .text("\u{1F}", []))
            #expect(action(0, "\u{1}", ignoring: "a", [.control, .option])
                == .text("\u{1}", [.meta]))
        }

        @Test func metaAndCommand() {
            #expect(action(7, "≈", ignoring: "x", [.option]) == .text("x", [.meta]))
            #expect(action(7, "≈", ignoring: "x", [.option], optionIsMeta: false) == .interpret)
            #expect(action(9, "v", [.command]) == .ignore)
            #expect(action(9, "v", [.command], commandIsMeta: true) == .text("v", [.meta]))
            #expect(action(0, "a") == .interpret)
        }

        /// PuTTY decides what Ctrl+Shift+C/V do ("Ctrl + Shift + {C,V}").
        @Test func controlShiftCAndVGoToPuTTY() {
            #expect(action(8, "\u{3}", ignoring: "C", [.control, .shift]) == .key(.letterC, [.shift, .control]))
            #expect(action(9, "\u{16}", ignoring: "V", [.control, .shift, .option])
                == .key(.letterV, [.shift, .control, .meta]))
            // Without Shift they stay control characters.
            #expect(action(8, "\u{3}", ignoring: "c", [.control]) == .text("\u{3}", []))
        }
    }

    @Suite("Terminal view options")
    @MainActor
    struct TerminalViewOptionsTests {
        @Test func defaultsAreGTKPuTTYs() {
            let options = TerminalViewOptions(settings: .defaults())
            #expect(options.border == 1)
            #expect(options.showsScrollbar && !options.scrollbarOnLeft)
            #expect(options.optionIsMeta && !options.commandIsMeta)
            #expect(!options.hidesMousePointerWhenTyping)
            #expect(options.bellSoundFile == "" && options.bellIndication == 0)
            #expect(!options.alwaysOnTop && !options.fullScreenOnOptionReturn)
            #expect(!options.separateIconTitle)
        }

        @Test func readsTheWindowSettings() {
            var settings = PuTTYSettings.defaults()
            settings["WindowBorder"] = "6"
            settings["ScrollbarOnLeft"] = "1"
            settings["HideMousePtr"] = "1"
            settings["Beep"] = "3"
            settings["BellWaveFile"] = "/tmp/bell.aiff"
            settings["BeepInd"] = "2"
            settings["AlwaysOnTop"] = "1"
            settings["FullScreenOnAltEnter"] = "1"
            settings["WinNameAlways"] = "0"
            settings["OSXOptionMeta"] = "0"
            let options = TerminalViewOptions(settings: settings)
            #expect(options.border == 6 && options.scrollbarOnLeft)
            #expect(options.hidesMousePointerWhenTyping && !options.optionIsMeta)
            #expect(options.bellSoundFile == "/tmp/bell.aiff" && options.bellIndication == 2)
            #expect(options.alwaysOnTop && options.fullScreenOnOptionReturn && options.separateIconTitle)

            // The sound file only matters for "Play a custom sound file".
            settings["Beep"] = "1"
            #expect(TerminalViewOptions(settings: settings).bellSoundFile == "")
        }

        @Test func borderAndLeftScrollbarPlaceTheCells() {
            var settings = PuTTYSettings.defaults()
            settings["WindowBorder"] = "5"
            settings["ScrollbarOnLeft"] = "1"
            let view = TerminalView(controller: SessionController(settings: settings))
            let font = view.renderer.font
            let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
            #expect(view.textOrigin == NSPoint(x: 5 + scroller, y: 5))
            #expect(view.size(columns: 80, rows: 24)
                == NSSize(width: 80 * font.cellWidth + 10 + scroller, height: 24 * font.cellHeight + 10))
            #expect(TerminalView.defaultSize(for: settings) == view.size(columns: 80, rows: 24))
        }
    }

    @Suite("Terminal font")
    struct TerminalFontTests {
        @Test func parsesPuTTYFontNames() {
            // Window/Fonts: configured fonts per cell kind; derived ones
            // otherwise; shadow bold draws bold with the ordinary fonts.
            let configured = TerminalFont(spec: TerminalFontSpec(
                fontName: "Menlo-Regular 12", boldFontName: "Courier-Bold 12",
                wideFontName: "Monaco 12"))
            #expect(configured.font(bold: true, wide: false).fontName == "Courier-Bold")
            #expect(configured.font(bold: false, wide: true).fontName == "Monaco")
            let derived = TerminalFont(spec: TerminalFontSpec(fontName: "Menlo-Regular 12"))
            #expect(derived.font(bold: true, wide: false).fontName == "Menlo-Bold")
            #expect(derived.font(bold: false, wide: true).fontName == "Menlo-Regular")
            #expect(derived.font(bold: true, wide: true).fontName == "Menlo-Bold")
            let shadow = TerminalFont(spec: TerminalFontSpec(fontName: "Menlo-Regular 12", shadowBold: true))
            #expect(shadow.font(bold: true, wide: false).fontName == "Menlo-Regular")
            #expect(TerminalFont(puttyFontName: "Menlo-Regular 12").font.pointSize == 12)
            #expect(TerminalFont(puttyFontName: "Menlo-Bold 15").font.fontName == "Menlo-Bold")
            #expect(TerminalFont(puttyFontName: "client:Menlo-Regular 10").font.pointSize == 10)
            let fallback = TerminalFont(puttyFontName: "No Such Font 99")
            #expect(fallback.font.fontName == "Menlo-Regular" && fallback.font.pointSize == 12)
        }

        @Test func cellsAreWholePoints() {
            let font = TerminalFont(puttyFontName: "Menlo-Regular 12")
            #expect(font.cellWidth == font.cellWidth.rounded())
            #expect(font.cellHeight == font.cellHeight.rounded())
            #expect(font.cellWidth >= 7 && font.cellHeight >= 14)
            #expect(font.baseline < font.cellHeight)
        }
    }
}

@MainActor
func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}
