import AppKit
import XCTest
@testable import HerdrKit

/// `TerminalGridView` is an `NSView`, so it is main-actor isolated; the tests
/// have to be too in order to hand it non-`Sendable` values like fonts.
@MainActor
final class TerminalGridViewTests: XCTestCase {
    private var view: TerminalGridView {
        TerminalGridView(terminalFont: TerminalFont(size: 13))
    }

    func testCellSizeIsPositiveAndIntegral() {
        let size = view.cellSize
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
        XCTAssertEqual(size.width, size.width.rounded(), "cell width must be integral to avoid drift")
        XCTAssertEqual(size.height, size.height.rounded())
    }

    func testGridSizeDividesAvailableArea() {
        let subject = view
        let cell = subject.cellSize
        let bounds = CGSize(width: cell.width * 40, height: cell.height * 12)
        let grid = subject.gridSize(for: bounds)
        XCTAssertEqual(grid.columns, 40)
        XCTAssertEqual(grid.rows, 12)
    }

    func testGridSizeFloorsPartialCells() {
        let subject = view
        let cell = subject.cellSize
        let bounds = CGSize(width: cell.width * 10 + cell.width * 0.9, height: cell.height * 5 + 1)
        let grid = subject.gridSize(for: bounds)
        XCTAssertEqual(grid.columns, 10)
        XCTAssertEqual(grid.rows, 5)
    }

    func testGridSizeNeverReturnsZero() {
        let grid = view.gridSize(for: CGSize(width: 1, height: 1))
        XCTAssertEqual(grid.columns, 1)
        XCTAssertEqual(grid.rows, 1)
    }

    func testUpdateStoresFrame() {
        let subject = view
        let frame = GridFrame(
            cells: [
                GridCell(
                    symbol: "A",
                    foreground: 0,
                    background: 0,
                    modifier: 0,
                    skip: false,
                    hyperlink: nil
                )
            ],
            width: 1,
            height: 1,
            cursor: nil,
            hyperlinks: [],
            graphics: []
        )
        subject.update(frame)
        XCTAssertEqual(subject.currentFrame, frame)
    }

    func testConvertsPointToCellCoordinates() {
        let subject = view
        let cell = subject.cellSize
        let point = CGPoint(x: cell.width * 3 + 2, y: cell.height * 5 + 2)
        let position = subject.cellPosition(for: point)
        XCTAssertEqual(position.column, 3)
        XCTAssertEqual(position.row, 5)
    }

    func testClampsNegativeCoordinatesToOrigin() {
        let position = view.cellPosition(for: CGPoint(x: -50, y: -50))
        XCTAssertEqual(position.column, 0)
        XCTAssertEqual(position.row, 0)
    }

    func testCellPositionAtExactBoundaryBelongsToNextCell() {
        let subject = view
        let cell = subject.cellSize
        let position = subject.cellPosition(for: CGPoint(x: cell.width, y: cell.height))
        XCTAssertEqual(position.column, 1)
        XCTAssertEqual(position.row, 1)
    }

    func testCellSizeComesFromTheFontMetrics() {
        let font = TerminalFont(size: 13)
        XCTAssertEqual(TerminalGridView(terminalFont: font).cellSize, font.cellSize)
    }

    // MARK: - Rendering

    /// Expands a row the way the wire format does: a wide character is followed
    /// by an unmarked filler cell (see `CharWidth`).
    private func cells(_ row: String) -> [GridCell] {
        var out: [GridCell] = []
        for character in row {
            let symbol = String(character)
            out.append(
                GridCell(symbol: symbol, foreground: 0, background: 0, modifier: 0, skip: false, hyperlink: nil)
            )
            for _ in 1 ..< CharWidth.displayWidth(of: symbol) {
                out.append(
                    GridCell(symbol: " ", foreground: 0, background: 0, modifier: 0, skip: false, hyperlink: nil)
                )
            }
        }
        return out
    }

    private func render(
        _ rows: [String],
        font: TerminalFont = TerminalFont(size: 13),
        cursor: GridCursor? = nil
    ) -> NSBitmapImageRep {
        let expanded = rows.map(cells)
        let width = expanded.map(\.count).max() ?? 1
        // White ink on black, so "did anything get drawn here" is a brightness
        // test rather than a colour match.
        let palette = TerminalPalette(
            defaultForeground: ThemeColor(255, 255, 255),
            defaultBackground: ThemeColor(0, 0, 0),
            ansi: TerminalPalette.ghostty.ansi
        )
        let subject = TerminalGridView(terminalFont: font, palette: palette)
        subject.frame = CGRect(
            x: 0,
            y: 0,
            width: font.cellSize.width * CGFloat(width),
            height: font.cellSize.height * CGFloat(rows.count)
        )

        var grid: [GridCell] = []
        for var line in expanded {
            while line.count < width {
                line.append(
                    GridCell(symbol: " ", foreground: 0, background: 0, modifier: 0, skip: false, hyperlink: nil)
                )
            }
            grid += line
        }
        subject.update(
            GridFrame(
                cells: grid,
                width: UInt16(width),
                height: UInt16(rows.count),
                cursor: cursor,
                hyperlinks: [],
                graphics: []
            )
        )

        let scale = 2
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(subject.bounds.width) * scale,
            pixelsHigh: Int(subject.bounds.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        // The view is flipped; a bitmap context is not.
        context.cgContext.translateBy(x: 0, y: subject.bounds.height)
        context.cgContext.scaleBy(x: 1, y: -1)
        subject.draw(subject.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// The regression the geometry table exists for. A font's `█` outline covers
    /// only 13 of the cell's 17 points, so stacked full blocks used to leave a
    /// visible band between rows — which is what broke Claude Code's block-art
    /// logo. Every pixel of a two-row column of blocks must be ink.
    func testStackedFullBlocksLeaveNoGapInTheRenderedPixels() {
        let rep = render(["█", "█"])
        for y in 0 ..< rep.pixelsHigh {
            for x in 0 ..< rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                XCTAssertGreaterThan(
                    color.brightnessComponent,
                    0.9,
                    "gap at \(x),\(y): block characters must fill their cell"
                )
            }
        }
    }

    func testSideBySideFullBlocksLeaveNoGapInTheRenderedPixels() {
        let rep = render(["██"])
        for x in 0 ..< rep.pixelsWide {
            let color = rep.colorAt(x: x, y: rep.pixelsHigh / 2)
            XCTAssertGreaterThan(color?.brightnessComponent ?? 0, 0.9, "gap at column \(x)")
        }
    }

    /// Shades are drawn as a flat blend precisely so they tile; a font's stipple
    /// pattern does not continue across a cell boundary.
    func testShadeIsUniformAcrossACellBoundary() {
        let rep = render(["░░"])
        let y = rep.pixelsHigh / 2
        let samples = (0 ..< rep.pixelsWide).compactMap { rep.colorAt(x: $0, y: y)?.brightnessComponent }
        XCTAssertFalse(samples.isEmpty)
        for sample in samples {
            XCTAssertEqual(sample, samples[0], accuracy: 0.02, "shade must not vary within or between cells")
        }
    }

    func testOrdinaryTextIsDrawn() {
        let rep = render(["M"])
        let lit = (0 ..< rep.pixelsHigh).flatMap { y in
            (0 ..< rep.pixelsWide).compactMap { rep.colorAt(x: $0, y: y)?.brightnessComponent }
        }
        XCTAssertTrue(lit.contains { $0 > 0.5 }, "glyph pass drew nothing")
    }

    /// A fallback font's advance does not match the cell, so wide characters are
    /// centred in their two-column slot rather than left-aligned — and they must
    /// stay inside it.
    func testWideCharacterIsCentredInsideItsTwoCells() {
        let rep = render(["更"])
        let brightest = { (x: Int) -> CGFloat in
            (0 ..< rep.pixelsHigh)
                .compactMap { rep.colorAt(x: x, y: $0)?.brightnessComponent }
                .max() ?? 0
        }
        XCTAssertLessThan(brightest(0), 0.5, "ink touches the left edge of the slot")
        XCTAssertLessThan(brightest(rep.pixelsWide - 1), 0.5, "ink touches the right edge of the slot")
        XCTAssertGreaterThan(brightest(rep.pixelsWide / 2), 0.5, "nothing was drawn in the slot")
    }

    /// Emoji resolve to a font whose advance is wider than two cells; unscaled
    /// they would spill into the cell after the filler.
    func testEmojiIsScaledIntoItsSlot() {
        let rep = render(["😀 "])
        let column = Int(TerminalFont(size: 13).cellSize.width) * 2 * 2 // past two cells, 2x backing
        for x in column ..< rep.pixelsWide {
            for y in 0 ..< rep.pixelsHigh {
                let brightness = rep.colorAt(x: x, y: y)?.brightnessComponent ?? 0
                XCTAssertLessThan(brightness, 0.2, "emoji spilled past its slot at \(x),\(y)")
            }
        }
    }

    // MARK: - Cursor

    func testFocusedCursorShapesFollowDECSCUSR() {
        XCTAssertEqual(CursorPresentation.resolve(shape: 0, focused: true), .block)
        XCTAssertEqual(CursorPresentation.resolve(shape: 1, focused: true), .block)
        XCTAssertEqual(CursorPresentation.resolve(shape: 2, focused: true), .block)
        XCTAssertEqual(CursorPresentation.resolve(shape: 3, focused: true), .underline)
        XCTAssertEqual(CursorPresentation.resolve(shape: 4, focused: true), .underline)
        XCTAssertEqual(CursorPresentation.resolve(shape: 5, focused: true), .bar)
        XCTAssertEqual(CursorPresentation.resolve(shape: 6, focused: true), .bar)
    }

    func testUnknownShapesFallBackToABlock() {
        XCTAssertEqual(CursorPresentation.resolve(shape: 99, focused: true), .block)
    }

    /// An unfocused pane must not invert the cell: an inverted block reads as
    /// "typing goes here", which is exactly what is not true.
    func testUnfocusedCursorIsAnOutlineWhateverTheShape() {
        for shape in UInt8(0) ... 6 {
            XCTAssertEqual(CursorPresentation.resolve(shape: shape, focused: false), .outline)
        }
    }

    /// A view with no window has no keyboard focus, so a rendered cursor cell
    /// keeps the character under it rather than being filled over — the old
    /// renderer painted a translucent block on top of the glyph.
    func testUnfocusedCursorDoesNotHideTheCharacterUnderIt() {
        let plain = render(["M"])
        let withCursor = render(["M"], cursor: GridCursor(column: 0, row: 0, isVisible: true, shape: 0))

        XCTAssertEqual(
            litPixels(withCursor, insetBy: 4),
            litPixels(plain, insetBy: 4),
            "the cell's interior must be untouched by an unfocused cursor"
        )
        XCTAssertGreaterThan(
            litPixels(withCursor),
            litPixels(plain),
            "the outline itself should be drawn"
        )
    }

    func testHiddenCursorDrawsNothingAtAll() {
        let plain = render(["M"])
        let hidden = render(["M"], cursor: GridCursor(column: 0, row: 0, isVisible: false, shape: 0))
        XCTAssertEqual(litPixels(hidden), litPixels(plain))
    }

    /// Number of ink pixels, optionally ignoring a border — the palette used by
    /// `render` is white ink on black, so bright means drawn.
    private func litPixels(_ rep: NSBitmapImageRep, insetBy inset: Int = 0) -> Int {
        var count = 0
        for y in inset ..< max(inset, rep.pixelsHigh - inset) {
            for x in inset ..< max(inset, rep.pixelsWide - inset) {
                if (rep.colorAt(x: x, y: y)?.brightnessComponent ?? 0) > 0.5 { count += 1 }
            }
        }
        return count
    }

    // MARK: - Composition

    func testMarkedTextRoundTrips() {
        let subject = view
        XCTAssertFalse(subject.hasMarkedText())
        subject.setMarkedText("ni hao", selectedRange: NSRange(location: 3, length: 3), replacementRange: NSRange())
        XCTAssertTrue(subject.hasMarkedText())
        XCTAssertEqual(subject.markedRange(), NSRange(location: 0, length: 6))
        XCTAssertEqual(subject.selectedRange(), NSRange(location: 3, length: 3))
    }

    func testUnmarkClearsComposition() {
        let subject = view
        subject.setMarkedText("ni", selectedRange: NSRange(location: 0, length: 2), replacementRange: NSRange())
        subject.unmarkText()
        XCTAssertFalse(subject.hasMarkedText())
        XCTAssertEqual(subject.markedRange(), NSRange(location: NSNotFound, length: 0))
    }

    func testInsertTextEndsComposition() {
        let subject = view
        subject.setMarkedText("ni", selectedRange: NSRange(location: 0, length: 2), replacementRange: NSRange())
        subject.insertText("你", replacementRange: NSRange())
        XCTAssertFalse(subject.hasMarkedText())
    }

    func testAttributedSubstringReturnsTheComposingText() {
        let subject = view
        subject.setMarkedText("nihao", selectedRange: NSRange(location: 0, length: 5), replacementRange: NSRange())
        let slice = subject.attributedSubstring(
            forProposedRange: NSRange(location: 2, length: 3),
            actualRange: nil
        )
        XCTAssertEqual(slice?.string, "hao")
    }

    func testAttributedSubstringRejectsAnOutOfBoundsRange() {
        let subject = view
        subject.setMarkedText("ni", selectedRange: NSRange(location: 0, length: 2), replacementRange: NSRange())
        XCTAssertNil(
            subject.attributedSubstring(forProposedRange: NSRange(location: 0, length: 99), actualRange: nil)
        )
    }

    /// The candidate window has to sit at the composing text, measured in display
    /// columns: two CJK characters are four columns wide, not two.
    func testCandidateRectWidthFollowsDisplayColumns() {
        let subject = view
        subject.frame = CGRect(x: 0, y: 0, width: subject.cellSize.width * 20, height: subject.cellSize.height * 4)
        subject.update(
            GridFrame(
                cells: Array(
                    repeating: GridCell(
                        symbol: " ", foreground: 0, background: 0, modifier: 0, skip: false, hyperlink: nil
                    ),
                    count: 80
                ),
                width: 20,
                height: 4,
                cursor: GridCursor(column: 0, row: 0, isVisible: true, shape: 0),
                hyperlinks: [],
                graphics: []
            )
        )
        subject.setMarkedText("更新", selectedRange: NSRange(location: 0, length: 2), replacementRange: NSRange())
        let rect = subject.firstRect(forCharacterRange: NSRange(location: 0, length: 2), actualRange: nil)
        XCTAssertEqual(rect.width, subject.cellSize.width * 4)
    }

    func testValidAttributesIncludeTheClauseSegment() {
        XCTAssertTrue(view.validAttributesForMarkedText().contains(.markedClauseSegment))
    }
}
