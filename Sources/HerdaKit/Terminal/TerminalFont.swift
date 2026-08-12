import AppKit
import CoreText

/// The font set and cell geometry the terminal grid is drawn with.
///
/// Every metric the renderer needs is derived here, once, from the font's own
/// tables — nothing downstream hardcodes a size. Two properties matter enough
/// to state explicitly:
///
/// - `cellSize` is integral. Fractional advances accumulate rounding error
///   across a wide row and visibly shear the grid.
/// - `baselineFromTop` is a single value shared by *every* font that ends up
///   drawing into the grid, including CoreText's fallbacks. Letting each
///   resolved font place its own baseline is what leaves Latin, CJK and emoji
///   sitting on three different lines within one row.
/// Not `Sendable`: `NSFont` is not, and the renderer only ever touches this on
/// the main actor.
public struct TerminalFont {
    public let regular: NSFont
    public let bold: NSFont
    public let italic: NSFont
    public let boldItalic: NSFont

    public let cellSize: CGSize
    /// Distance from the top edge of a cell down to the text baseline.
    public let baselineFromTop: CGFloat

    /// Families tried in order. The first is the default because it is the only
    /// one measured to cover everything herdr's agents actually draw with —
    /// CJK at a true double advance, Nerd Font/Powerline private-use glyphs,
    /// braille, block elements, and real bold/italic faces rather than
    /// synthesised ones. The rest are progressively weaker fallbacks for a
    /// machine that does not have it installed.
    public static let preferredFamilies = [
        "Maple Mono NF CN",
        "JetBrains Mono",
        "Menlo",
    ]

    public init(size: CGFloat = 13) {
        self.init(regular: TerminalFont.resolve(size: size))
    }

    public init(regular: NSFont) {
        let manager = NSFontManager.shared
        self.regular = regular
        self.bold = manager.convert(regular, toHaveTrait: .boldFontMask)
        self.italic = manager.convert(regular, toHaveTrait: .italicFontMask)
        self.boldItalic = manager.convert(
            manager.convert(regular, toHaveTrait: .boldFontMask),
            toHaveTrait: .italicFontMask
        )

        let advance = TerminalFont.advance(of: regular)
        let ascent = regular.ascender
        let descent = -regular.descender
        let height = (ascent + descent + regular.leading).rounded()

        self.cellSize = CGSize(width: max(1, advance.rounded()), height: max(1, height))
        // Anchoring the baseline by reserving whole-pixel descender room keeps
        // descenders inside the cell without pushing the text off-centre.
        self.baselineFromTop = max(1, height - descent.rounded())
    }

    /// First preferred family that is actually installed, else the system
    /// monospace font.
    public static func resolve(size: CGFloat) -> NSFont {
        for family in preferredFamilies {
            if let font = NSFont(name: family, size: size) {
                return font
            }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// How many cells fit in a given pixel size.
    ///
    /// This lives here rather than on the view because `TerminalSession` still
    /// reports the whole terminal area's cols/rows for the app connection, while
    /// no longer owning a single view — there is one per pane. The measurement
    /// belongs to whatever owns `cellSize`.
    public func gridSize(for size: CGSize) -> (columns: UInt16, rows: UInt16) {
        let columns = max(1, Int(size.width / cellSize.width))
        let rows = max(1, Int(size.height / cellSize.height))
        return (UInt16(min(columns, Int(UInt16.max))), UInt16(min(rows, Int(UInt16.max))))
    }

    /// Horizontal advance of one cell, taken from the font's glyph metrics
    /// rather than a laid-out string: `NSString.size(withAttributes:)` reports
    /// a typographic width that can include side bearing padding.
    public static func advance(of font: NSFont) -> CGFloat {
        var character: UniChar = 0x004D // "M"
        var glyph = CGGlyph(0)
        guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) else {
            return font.maximumAdvancement.width
        }
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        return advance.width > 0 ? advance.width : font.maximumAdvancement.width
    }

    public func font(bold isBold: Bool, italic isItalic: Bool) -> NSFont {
        switch (isBold, isItalic) {
        case (true, true): return boldItalic
        case (true, false): return bold
        case (false, true): return italic
        case (false, false): return regular
        }
    }
}

/// Rounds a coordinate onto the backing store's pixel grid.
///
/// Shared by every path that fills a rectangle meant to abut its neighbour:
/// block elements, underlines, cursors. Because the same boundary always rounds
/// to the same value, adjacent cells land on a shared edge and no anti-aliased
/// seam appears between them — which holds at any font size, not just the ones
/// where the fractions happen to be integral.
@inlinable
public func snapToDevicePixels(_ value: CGFloat, scale: CGFloat) -> CGFloat {
    guard scale > 0 else { return value.rounded() }
    return (value * scale).rounded() / scale
}
