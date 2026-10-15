import AppKit
import CoreText

/// The terminal font and the character-cell metrics derived from it.
///
/// PuTTY stores the font as `FontName`; SwiftPutty writes
/// `"<PostScript name> <points>"` (default `"Menlo-Regular 12"`, D-016).
/// Cells are whole points wide and high, so backgrounds tile exactly.
/// GTK PuTTY's Window/Fonts settings (unix/config-gtk.c): the ordinary
/// font, optional fonts for bold, wide (CJK) and bold wide text (empty:
/// derived), and shadow bold.
public struct TerminalFontSpec: Equatable, Sendable {
    public var fontName: String?
    public var boldFontName: String?
    public var wideFontName: String?
    public var wideBoldFontName: String?
    /// "Use shadow bold instead of bold fonts": bold is the ordinary
    /// glyph drawn again `shadowBoldOffset` points to the right.
    public var shadowBold: Bool
    public var shadowBoldOffset: Int

    public init(fontName: String?, boldFontName: String? = nil, wideFontName: String? = nil,
                wideBoldFontName: String? = nil, shadowBold: Bool = false, shadowBoldOffset: Int = 1) {
        self.fontName = fontName
        self.boldFontName = boldFontName
        self.wideFontName = wideFontName
        self.wideBoldFontName = wideBoldFontName
        self.shadowBold = shadowBold
        self.shadowBoldOffset = shadowBoldOffset
    }
}

extension TerminalFontSpec {
    /// The same fonts at `factor` times their sizes (Windows' "change the
    /// size of the font" on resize).
    public func scaled(by factor: CGFloat) -> TerminalFontSpec {
        func scale(_ name: String?) -> String? {
            guard let name, !name.isEmpty else { return name }
            let font = TerminalFont.font(forPuTTYName: name)
            let size = max(1, (font.pointSize * factor * 2).rounded() / 2)
            let formatted = size == size.rounded() ? String(Int(size)) : String(format: "%.1f", Double(size))
            return "\(font.fontName) \(formatted)"
        }
        var spec = self
        spec.fontName = scale(fontName ?? "\(TerminalFont.fallbackName) \(Int(TerminalFont.fallbackSize))")
        spec.boldFontName = scale(boldFontName)
        spec.wideFontName = scale(wideFontName)
        spec.wideBoldFontName = scale(wideBoldFontName)
        return spec
    }
}

public struct TerminalFont: Equatable {
    public let font: NSFont
    public let boldFont: NSFont
    /// For wide (two-column) characters; the ordinary fonts if not set.
    public let wideFont: NSFont
    public let wideBoldFont: NSFont
    public let shadowBold: Bool
    public let shadowBoldOffset: CGFloat
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
        self.init(font: font, boldFont: nil, wideFont: nil, wideBoldFont: nil,
                  shadowBold: false, shadowBoldOffset: 1)
    }

    /// The fonts for a `TerminalFontSpec`. A font that is not set is
    /// derived: bold from the ordinary font, wide from the ordinary
    /// fonts, bold wide from the wide font.
    public init(spec: TerminalFontSpec) {
        let font = Self.font(forPuTTYName: spec.fontName)
        func optional(_ name: String?) -> NSFont? {
            guard let name, !name.isEmpty else { return nil }
            return Self.font(forPuTTYName: name, fallback: nil)
        }
        self.init(font: font, boldFont: optional(spec.boldFontName),
                  wideFont: optional(spec.wideFontName), wideBoldFont: optional(spec.wideBoldFontName),
                  shadowBold: spec.shadowBold, shadowBoldOffset: CGFloat(spec.shadowBoldOffset))
    }

    private init(font: NSFont, boldFont: NSFont?, wideFont: NSFont?, wideBoldFont: NSFont?,
                 shadowBold: Bool, shadowBoldOffset: CGFloat) {
        func bold(_ f: NSFont) -> NSFont { NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
        self.font = font
        self.boldFont = boldFont ?? bold(font)
        self.wideFont = wideFont ?? font
        self.wideBoldFont = wideBoldFont ?? wideFont.map(bold) ?? self.boldFont
        self.shadowBold = shadowBold
        self.shadowBoldOffset = shadowBoldOffset
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

    /// The font to draw a cell with (shadow bold draws bold cells with the
    /// ordinary fonts).
    public func font(bold: Bool, wide: Bool) -> NSFont {
        let useBold = bold && !shadowBold
        switch (useBold, wide) {
        case (false, false): return font
        case (true, false): return boldFont
        case (false, true): return wideFont
        case (true, true): return wideBoldFont
        }
    }

    static func font(forPuTTYName name: String?) -> NSFont {
        font(forPuTTYName: name, fallback: NSFont(name: fallbackName, size: fallbackSize)
             ?? .monospacedSystemFont(ofSize: fallbackSize, weight: .regular))!
    }

    static func font(forPuTTYName name: String?, fallback: NSFont?) -> NSFont? {
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
        return fallback
    }
}
