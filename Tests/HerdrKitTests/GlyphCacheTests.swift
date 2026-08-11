import AppKit
import XCTest
@testable import HerdrKit

final class GlyphCacheTests: XCTestCase {
    private let font = TerminalFont(size: 13)
    private var cache: GlyphCache { GlyphCache(font: font) }

    func testBlankSymbolsResolveToNothing() {
        for symbol in ["", " ", "\u{a0}", "\t"] {
            XCTAssertNil(cache.placement(symbol: symbol), "\(symbol.debugDescription) should not draw")
        }
    }

    func testAsciiFitsItsSlotUnscaled() {
        guard let placement = cache.placement(symbol: "M") else { return XCTFail("no placement") }
        XCTAssertEqual(placement.scale, 1)
        XCTAssertEqual(placement.slotWidth, font.cellSize.width)
    }

    func testWideCharactersGetATwoColumnSlot() {
        guard let placement = cache.placement(symbol: "更") else { return XCTFail("no placement") }
        XCTAssertEqual(placement.slotWidth, font.cellSize.width * 2)
    }

    /// A fallback font's advance has nothing to do with the cell width, so the
    /// glyph is centred rather than left-aligned — otherwise CJK drifts left and
    /// the row reads unevenly.
    func testGlyphsNarrowerThanTheirSlotAreCentred() {
        let narrow = GlyphCache(font: TerminalFont(regular: NSFont(name: "Menlo", size: 13)!))
        guard let placement = narrow.placement(symbol: "更") else { return XCTFail("no placement") }
        XCTAssertGreaterThan(placement.xOffset, 0)
        XCTAssertEqual(placement.scale, 1)
    }

    /// Colour emoji resolve to AppleColorEmoji, whose advance is wider than two
    /// cells; unscaled they spill into the next cell.
    func testGlyphsWiderThanTheirSlotAreScaledToFit() {
        guard let placement = cache.placement(symbol: "😀") else { return XCTFail("no placement") }
        XCTAssertLessThan(placement.scale, 1)
        XCTAssertGreaterThan(placement.scale, 0.5)
        XCTAssertGreaterThanOrEqual(placement.xOffset, 0)
    }

    func testPlacementNeverOverflowsItsSlot() {
        let subject = cache
        for symbol in ["M", "更", "😀", "❯", "⚠", "░", "\u{e0b0}", "⣿"] {
            guard let placement = subject.placement(symbol: symbol) else { continue }
            XCTAssertGreaterThanOrEqual(placement.xOffset, -0.01, "\(symbol) starts left of its slot")
            XCTAssertLessThanOrEqual(
                placement.xOffset,
                placement.slotWidth / 2,
                "\(symbol) is offset past the middle of its slot"
            )
        }
    }

    func testRepeatedResolutionIsStable() {
        let subject = cache
        let first = subject.placement(symbol: "更")
        let second = subject.placement(symbol: "更")
        XCTAssertEqual(first, second)
    }

    func testBoldAndItalicAreCachedSeparately() {
        let subject = cache
        let regular = subject.placement(symbol: "M")
        let bold = subject.placement(symbol: "M", bold: true)
        XCTAssertNotNil(regular)
        XCTAssertNotNil(bold)
        XCTAssertNotEqual(regular?.fontName, bold?.fontName)
    }

    func testGlyphsShareAFontIdWhenTheyShareAFont() {
        let subject = cache
        guard case .glyph(_, let first, _, _) = subject.resolve(symbol: "A"),
              case .glyph(_, let second, _, _) = subject.resolve(symbol: "B")
        else { return XCTFail("expected single glyphs") }
        XCTAssertEqual(first, second, "same font must batch together")
    }

    func testFallbackGlyphsGetTheirOwnFontId() {
        let subject = cache
        guard case .glyph(_, let latin, _, _) = subject.resolve(symbol: "A") else {
            return XCTFail("expected a glyph")
        }
        guard case .glyph(_, let emoji, _, _) = subject.resolve(symbol: "😀") else {
            return XCTFail("expected a glyph")
        }
        XCTAssertNotEqual(latin, emoji)
    }

    func testCombiningSequencesFallBackToLineDrawing() {
        // A base plus a combining mark is more than one glyph, so it cannot join
        // the batched single-glyph path.
        if case .line = cache.resolve(symbol: "e\u{0301}") { return }
        // Some fonts precompose it into one glyph, which is also correct.
        XCTAssertNotNil(cache.placement(symbol: "e\u{0301}"))
    }
}
