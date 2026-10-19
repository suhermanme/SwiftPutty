import AppKit
import CoreText
import PuTTYBridge

/// Draws a ``TerminalScreen`` into a Core Graphics context with a
/// top-left origin (a flipped view's coordinate space).
///
/// Colours, reverse video, bold-as-colour, dim and the active block
/// cursor arrive resolved from the bridge, so drawing is: background
/// runs, glyphs, decorations, then cursor overlays (as GTK PuTTY's
/// do_text_internal and draw_cursor).
@MainActor
public struct TerminalRenderer {
    public var font: TerminalFont

    private struct GlyphKey: Hashable {
        var scalar: UInt32
        var fontName: String
        var pointSize: CGFloat
    }

    private enum GlyphLookup {
        case found(CGGlyph)
        case missing
    }

    /// Terminal contents commonly survive many redraws. Keep Core Text's
    /// scalar-to-glyph lookup out of that repeated paint path.
    private var glyphCache: [GlyphKey: GlyphLookup] = [:]

    public init(font: TerminalFont) {
        self.font = font
    }

    /// Draws `rows` of `screen`, origin at the top-left of row 0.
    public mutating func draw(_ screen: TerminalScreen, rows: Range<Int>, in context: CGContext) {
        let rows = rows.clamped(to: 0..<screen.rows)
        for row in rows {
            context.saveGState()
            let rowRect = CGRect(x: 0, y: CGFloat(row) * font.cellHeight,
                                 width: CGFloat(screen.columns) * font.cellWidth,
                                 height: font.cellHeight)
            context.clip(to: rowRect)
            context.translateBy(x: 0, y: rowRect.minY)

            // DEC double-width and double-height lines: each logical cell
            // is two columns wide; double height shows one half per row.
            let attribute = screen.lineAttribute(row: row)
            var logicalColumns = screen.columns
            switch attribute {
            case .normal:
                break
            case .doubleWidth:
                context.scaleBy(x: 2, y: 1)
                logicalColumns /= 2
            case .doubleHeightTop:
                context.scaleBy(x: 2, y: 2)
                logicalColumns /= 2
            case .doubleHeightBottom:
                context.translateBy(x: 0, y: -font.cellHeight)
                context.scaleBy(x: 2, y: 2)
                logicalColumns /= 2
            }
            drawRow(screen, row: row, columns: logicalColumns, in: context)
            context.restoreGState()
        }
    }

    private mutating func drawRow(_ screen: TerminalScreen, row: Int, columns: Int, in context: CGContext) {
        let cells = (0..<columns).map { screen.cell(column: $0, row: row) }
        let w = font.cellWidth, h = font.cellHeight

        // Backgrounds, merged into runs of one colour.
        var start = 0
        while start < columns {
            let colour = cells[start].background
            var end = start + 1
            while end < columns && cells[end].background == colour { end += 1 }
            context.setFillColor(Self.cgColour(colour))
            context.fill(CGRect(x: CGFloat(start) * w, y: 0, width: CGFloat(end - start) * w, height: h))
            start = end
        }

        // Glyphs. Characters the primary font has are batched per colour
        // and weight; anything else (fallback fonts, combining sequences,
        // emoji) is laid out by Core Text in its own cell. The text matrix
        // and text position are not part of the graphics state, so each
        // path sets both.
        var column = 0
        while column < columns {
            let cell = cells[column]
            guard !cell.flags.contains(.wideContinuation), !cell.scalars.isEmpty else {
                column += 1
                continue
            }
            let bold = cell.flags.contains(.bold)
            let wide = cell.flags.contains(.wide)
            let ctFont = font.font(bold: bold, wide: wide) as CTFont
            let shadow = bold && font.shadowBold
            let fontName = CTFontCopyPostScriptName(ctFont) as String
            let pointSize = CTFontGetSize(ctFont)
            var glyphs: [CGGlyph] = []
            var positions: [CGPoint] = []
            var runColumn = column
            while runColumn < columns {
                let c = cells[runColumn]
                if c.flags.contains(.wideContinuation) { runColumn += 1; continue }
                guard c.foreground == cell.foreground, c.flags.contains(.bold) == bold,
                      c.flags.contains(.wide) == wide,
                      c.scalars.count == 1,
                      let glyph = glyph(for: c.scalars[0], fontName: fontName,
                                        pointSize: pointSize, in: ctFont)
                else { break }
                glyphs.append(glyph)
                positions.append(CGPoint(x: CGFloat(runColumn) * w, y: 0))
                runColumn += 1
            }
            if !glyphs.isEmpty {
                // Flip about the baseline so glyphs stand upright in this
                // top-left-origin space.
                context.saveGState()
                context.translateBy(x: 0, y: font.baseline)
                context.scaleBy(x: 1, y: -1)
                context.textMatrix = .identity
                context.textPosition = .zero
                context.setFillColor(Self.cgColour(cell.foreground))
                CTFontDrawGlyphs(ctFont, glyphs, positions, glyphs.count, context)
                if shadow {
                    // GTK PuTTY's shadow bold: the same glyphs again,
                    // offset to the right.
                    let shifted = positions.map { CGPoint(x: $0.x + font.shadowBoldOffset, y: $0.y) }
                    CTFontDrawGlyphs(ctFont, glyphs, shifted, glyphs.count, context)
                }
                context.restoreGState()
                column = runColumn
            } else {
                drawComplexCell(cell, column: column, font: ctFont, in: context)
                if shadow {
                    context.saveGState()
                    context.translateBy(x: font.shadowBoldOffset, y: 0)
                    drawComplexCell(cell, column: column, font: ctFont, in: context)
                    context.restoreGState()
                }
                column += 1
            }
        }

        // Underline and strikethrough.
        for (column, cell) in cells.enumerated()
        where cell.flags.contains(.underline) || cell.flags.contains(.strikethrough) {
            context.setFillColor(Self.cgColour(cell.foreground))
            let width = (cell.flags.contains(.wide) ? 2 : 1) * w
            if cell.flags.contains(.underline) {
                context.fill(CGRect(x: CGFloat(column) * w, y: font.underlinePosition, width: width, height: 1))
            }
            if cell.flags.contains(.strikethrough) {
                context.fill(CGRect(x: CGFloat(column) * w, y: font.strikethroughPosition, width: width, height: 1))
            }
        }

        for (column, cell) in cells.enumerated() {
            if cell.flags.contains(.cursor) {
                drawCursor(cell, column: column, style: screen.cursorStyle,
                           colour: screen.cursorColour, in: context)
            }
            if cell.flags.contains(.trustSigil) {
                drawTrustSigil(column: column, in: context)
            }
        }
    }

    private func drawComplexCell(_ cell: TerminalCell, column: Int, font ctFont: CTFont,
                                 in context: CGContext) {
        guard let text = cell.text else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: ctFont,
            .foregroundColor: Self.cgColour(cell.foreground),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        // Centre the glyphs in their one or two cells.
        let cells: CGFloat = cell.flags.contains(.wide) ? 2 : 1
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let x = CGFloat(column) * font.cellWidth + max(0, (cells * font.cellWidth - width) / 2)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: x, y: font.baseline)
        CTLineDraw(line, context)
    }

    /// unix/window.c gtkwin_draw_cursor, for the overlay forms.
    private func drawCursor(_ cell: TerminalCell, column: Int, style: TerminalCursorStyle,
                            colour: UInt32, in context: CGContext) {
        let w = font.cellWidth, h = font.cellHeight
        let cells: CGFloat = cell.flags.contains(.wide) ? 2 : 1
        let passive = cell.flags.contains(.cursorPassive)
        let x = CGFloat(column) * w
        context.setStrokeColor(Self.cgColour(colour))
        context.setFillColor(Self.cgColour(colour))
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: passive && style != .block ? [1, 1] : [])

        switch style {
        case .block:
            // Only the passive (unfocused) block is drawn here: a box.
            context.stroke(CGRect(x: x + 0.5, y: 0.5, width: cells * w - 1, height: h - 1))
        case .underline:
            let y = font.underlinePosition + 0.5
            context.strokeLineSegments(between: [CGPoint(x: x, y: y), CGPoint(x: x + cells * w, y: y)])
        case .verticalLine:
            let lineX = (cell.flags.contains(.cursorRight) ? x + cells * w - 1 : x) + 0.5
            context.strokeLineSegments(between: [CGPoint(x: lineX, y: 0), CGPoint(x: lineX, y: h)])
        }
        context.setLineDash(phase: 0, lengths: [])
    }

    /// Resolved once per process: a bundle with no declared icon (a test
    /// bundle, which has no `CFBundleIconFile`/`CFBundleIconName`) makes
    /// `NSImage(named: .applicationIconName)` fall through to AppKit's
    /// dynamic icon generation, which goes out to IconServices over XPC
    /// and, on at least one class of CI runner, never returns. The real
    /// app bundle always declares one (`ASSETCATALOG_COMPILER_APPICON_NAME`),
    /// so this only skips the sigil where there was never a real icon to
    /// draw anyway.
    private static let applicationIcon: NSImage? = {
        guard Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") != nil
            || Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") != nil else {
            return nil
        }
        return NSImage(named: NSImage.applicationIconName)
    }()

    /// PuTTY's trust sigil marks lines PuTTY itself wrote (as opposed to
    /// the server) during authentication.
    private func drawTrustSigil(column: Int, in context: CGContext) {
        guard let image = Self.applicationIcon else { return }
        let rect = CGRect(x: CGFloat(column) * font.cellWidth, y: 0,
                          width: 2 * font.cellWidth, height: font.cellHeight).insetBy(dx: 1, dy: 1)
        let side = min(rect.width, rect.height)
        let square = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        image.draw(in: square)
        NSGraphicsContext.restoreGraphicsState()
    }

    private mutating func glyph(for scalar: Unicode.Scalar, fontName: String,
                                pointSize: CGFloat, in font: CTFont) -> CGGlyph? {
        let key = GlyphKey(scalar: scalar.value, fontName: fontName, pointSize: pointSize)
        if let cached = glyphCache[key] {
            if case .found(let glyph) = cached { return glyph }
            return nil
        }
        var units = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        if glyphCache.count >= 4096 { glyphCache.removeAll(keepingCapacity: true) }
        guard units.count == 1, CTFontGetGlyphsForCharacters(font, &units, &glyphs, 1),
              glyphs[0] != 0 else {
            glyphCache[key] = .missing
            return nil
        }
        glyphCache[key] = .found(glyphs[0])
        return glyphs[0]
    }

    static func cgColour(_ rgb: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
