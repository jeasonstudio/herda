import AppKit
import CoreText

/// Resolves a cell symbol into something the renderer can draw, and remembers
/// the answer.
///
/// Resolution does two jobs the previous per-cell `NSString.draw` could not:
///
/// 1. It records which font CoreText actually picked. Terminal content mixes
///    scripts freely, and a fallback font's advance has nothing to do with the
///    cell width — measured at 13pt, CJK came back 12.9 wide for a 16-wide slot
///    and colour emoji came back 19. Each glyph is centred in its slot, and
///    scaled down when it would otherwise spill into the next cell.
/// 2. It leaves vertical placement to the caller's single shared baseline, so
///    Latin, CJK and emoji in one row sit on one line instead of three.
///
/// The cache matters because resolution costs a `CTLine` construction, and a
/// terminal redraws the same few hundred symbols over and over.
public final class GlyphCache {
    /// Where a resolved glyph sits inside its cell slot.
    ///
    /// `xOffset` is measured from the left edge of the slot; `scale` is 1 unless
    /// the glyph had to be shrunk to fit. Vertical placement is not here: the
    /// renderer supplies one baseline for every font in the grid.
    public struct Placement: Equatable, Sendable {
        public let xOffset: CGFloat
        public let scale: CGFloat
        public let slotWidth: CGFloat
        /// PostScript name of the font CoreText resolved the symbol to. Kept so
        /// fallback behaviour is assertable rather than assumed.
        public let fontName: String
    }

    /// How one cell's symbol is drawn. `fontId` identifies the resolved font for
    /// draw-call batching without repeated name comparisons.
    public enum Resolved {
        case blank
        case glyph(font: CTFont, fontId: Int, glyph: CGGlyph, placement: Placement)
        /// Symbols the single-glyph path cannot express — combining sequences,
        /// multi-scalar emoji clusters. Drawn as a whole line.
        case line(CTLine, placement: Placement)

        public var placement: Placement? {
            switch self {
            case .blank: return nil
            case .glyph(_, _, _, let placement), .line(_, let placement): return placement
            }
        }
    }

    private struct Key: Hashable {
        let symbol: String
        let bold: Bool
        let italic: Bool
    }

    /// Distinct symbols a long-lived session accumulates before the cache is
    /// dropped and rebuilt. Terminal content reuses a few hundred symbols, so
    /// this is a ceiling against pathological input, not a working limit.
    private static let capacity = 4096

    private let font: TerminalFont
    private var cache: [Key: Resolved] = [:]
    private var fontIds: [String: Int] = [:]

    public init(font: TerminalFont) {
        self.font = font
    }

    public func resolve(symbol: String, bold: Bool = false, italic: Bool = false) -> Resolved {
        let key = Key(symbol: symbol, bold: bold, italic: italic)
        if let hit = cache[key] { return hit }
        let resolved = compute(key)
        if cache.count >= GlyphCache.capacity { cache.removeAll(keepingCapacity: true) }
        cache[key] = resolved
        return resolved
    }

    /// Placement only, for callers that need the geometry without the glyph.
    public func placement(symbol: String, bold: Bool = false, italic: Bool = false) -> Placement? {
        resolve(symbol: symbol, bold: bold, italic: italic).placement
    }

    private func compute(_ key: Key) -> Resolved {
        guard !key.symbol.isEmpty, !key.symbol.allSatisfy(\.isWhitespace) else { return .blank }

        let base = font.font(bold: key.bold, italic: key.italic)
        let slot = font.cellSize.width * CGFloat(CharWidth.displayWidth(of: key.symbol))
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: key.symbol, attributes: [.font: base])
        )

        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun],
              runs.count == 1,
              CTRunGetGlyphCount(runs[0]) == 1,
              let resolvedFont = runFont(runs[0])
        else {
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            guard width > 0 else { return .blank }
            let scale = width > slot ? slot / width : 1
            return .line(
                line,
                placement: Placement(
                    xOffset: (slot - width * scale) / 2,
                    scale: scale,
                    slotWidth: slot,
                    fontName: base.fontName
                )
            )
        }

        var glyph = CGGlyph(0)
        CTRunGetGlyphs(runs[0], CFRange(location: 0, length: 1), &glyph)

        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(resolvedFont, .horizontal, &glyph, &advance, 1)
        guard advance.width > 0 else { return .blank }

        let name = CTFontCopyPostScriptName(resolvedFont) as String
        let scale = advance.width > slot ? slot / advance.width : 1
        return .glyph(
            font: resolvedFont,
            fontId: id(forFontNamed: name),
            glyph: glyph,
            placement: Placement(
                xOffset: (slot - advance.width * scale) / 2,
                scale: scale,
                slotWidth: slot,
                fontName: name
            )
        )
    }

    private func runFont(_ run: CTRun) -> CTFont? {
        let attributes = CTRunGetAttributes(run) as NSDictionary
        // The value is untyped here, so it is checked as an `NSFont` — the
        // toll-free counterpart — rather than force-cast to `CTFont`.
        return attributes[kCTFontAttributeName as String] as? NSFont
    }

    /// Small dense integer per distinct font, so the renderer can group draw
    /// calls by font without hashing names on every cell.
    private func id(forFontNamed name: String) -> Int {
        if let existing = fontIds[name] { return existing }
        let next = fontIds.count
        fontIds[name] = next
        return next
    }
}
