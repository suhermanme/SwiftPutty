import AppKit
import CoreText

/// The terminal font and the character-cell metrics derived from it.
///
/// PuTTY stores the font as `FontName`; SwiftPutty writes
/// `"<PostScript name> <points>"` (default `"Menlo-Regular 12"`, D-016).
/// Cells are whole points wide and high, so backgrounds tile exactly.
public struct TerminalFont: Equatable {
    public let font: NSFont
    public let boldFont: NSFont
    /// Cell size in points.
    public let cellWidth: CGFloat
    public let cellHeight: CGFloat
    /// Distance from the top of a cell to the text baseline.
    public let baseline: CGFloat
    public let underlinePosition: CGFloat
    public let strikethroughPosition: CGFloat

    public static let fallbackName = "Menlo-Regular"
    public static let fallbackSize: CGFloat = 12

    public init(font: NSFont) {
        self.font = font
        boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let ctFont = font as CTFont
        var glyph = CGGlyph()
        var character: UniChar = 0x4D           // "M"
        CTFontGetGlyphsForCharacters(ctFont, &character, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyph, &advance, 1)
        let ascent = CTFontGetAscent(ctFont)
        let descent = CTFontGetDescent(ctFont)
        let leading = CTFontGetLeading(ctFont)
        cellWidth = max(1, advance.width.rounded(.up))
        cellHeight = max(1, (ascent + descent + leading).rounded(.up))
        baseline = (ascent + leading / 2).rounded(.up)
        underlinePosition = min(cellHeight - 1, baseline + 1)
        strikethroughPosition = (baseline - CTFontGetXHeight(ctFont) / 2).rounded()
    }

    /// Parses PuTTY's `FontName` setting, falling back to Menlo 12.
    public init(puttyFontName name: String?) {
        self.init(font: Self.font(forPuTTYName: name))
    }

    static func font(forPuTTYName name: String?) -> NSFont {
        if let name {
            // Strip an optional upstream "client:"/"server:" prefix.
            var spec = Substring(name)
            if let colon = spec.firstIndex(of: ":"), spec[..<colon].allSatisfy(\.isLetter) {
                spec = spec[spec.index(after: colon)...]
            }
            let parts = spec.split(separator: " ")
            if let last = parts.last, let size = Double(last), size > 0, parts.count > 1 {
                let family = parts.dropLast().joined(separator: " ")
                if let font = NSFont(name: family, size: size) {
                    return font
                }
            }
        }
        return NSFont(name: fallbackName, size: fallbackSize)
            ?? .monospacedSystemFont(ofSize: fallbackSize, weight: .regular)
    }
}
