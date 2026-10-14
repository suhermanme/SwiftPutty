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

    public init(font: TerminalFont) {
        self.font = font
    }

    /// Draws `rows` of `screen`, origin at the top-left of row 0.
    public func draw(_ screen: TerminalScreen, rows: Range<Int>, in context: CGContext) {
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

    private func drawRow(_ screen: TerminalScreen, row: Int, columns: Int, in context: CGContext) {
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
            let ctFont = (bold ? font.boldFont : font.font) as CTFont
            var glyphs: [CGGlyph] = []
            var positions: [CGPoint] = []
            var runColumn = column
            while runColumn < columns {
                let c = cells[runColumn]
                if c.flags.contains(.wideContinuation) { runColumn += 1; continue }
                guard c.foreground == cell.foreground, c.flags.contains(.bold) == bold,
                      c.scalars.count == 1, let glyph = Self.glyph(for: c.scalars[0], in: ctFont)
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
                context.restoreGState()
                column = runColumn
            } else {
                drawComplexCell(cell, column: column, font: ctFont, in: context)
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

    /// PuTTY's trust sigil marks lines PuTTY itself wrote (as opposed to
    /// the server) during authentication.
    private func drawTrustSigil(column: Int, in context: CGContext) {
        let rect = CGRect(x: CGFloat(column) * font.cellWidth, y: 0,
                          width: 2 * font.cellWidth, height: font.cellHeight).insetBy(dx: 1, dy: 1)
        let side = min(rect.width, rect.height)
        let square = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        let image = NSImage(named: NSImage.applicationIconName)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        image?.draw(in: square)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func glyph(for scalar: Unicode.Scalar, in font: CTFont) -> CGGlyph? {
        var units = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        guard units.count == 1, CTFontGetGlyphsForCharacters(font, &units, &glyphs, 1),
              glyphs[0] != 0 else { return nil }
        return glyphs[0]
    }

    static func cgColour(_ rgb: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
