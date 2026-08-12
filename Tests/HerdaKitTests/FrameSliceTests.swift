import XCTest
@testable import HerdaKit

final class FrameSliceTests: XCTestCase {
    /// A 4x3 grid with a distinguishable character per cell:
    ///   a b c d
    ///   e f g h
    ///   i j k l
    private func grid(cursor: GridCursor? = nil) -> GridFrame {
        let symbols = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"]
        return GridFrame(
            cells: symbols.map {
                GridCell(
                    symbol: $0, foreground: 1, background: 2,
                    modifier: 0, skip: false, hyperlink: nil
                )
            },
            width: 4,
            height: 3,
            cursor: cursor,
            hyperlinks: ["https://example.com"],
            graphics: [0x01, 0x02]
        )
    }

    func testSlicesTheRequestedRectangle() {
        let slice = FrameSlice.slice(
            grid(),
            to: PaneLayoutRect(x: 1, y: 1, width: 2, height: 2)
        )
        XCTAssertEqual(slice.width, 2)
        XCTAssertEqual(slice.height, 2)
        XCTAssertEqual(slice.cells.map(\.symbol), ["f", "g", "j", "k"])
    }

    func testPreservesCellAttributes() {
        let slice = FrameSlice.slice(grid(), to: PaneLayoutRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(slice.cells[0].foreground, 1)
        XCTAssertEqual(slice.cells[0].background, 2)
    }

    func testKeepsTheHyperlinkTableWhole() {
        // cell.hyperlink is an index into this table, so renumbering it would mean
        // remapping every cell to save a few strings.
        let slice = FrameSlice.slice(grid(), to: PaneLayoutRect(x: 0, y: 0, width: 2, height: 2))
        XCTAssertEqual(slice.hyperlinks, ["https://example.com"])
    }

    func testDropsGraphics() {
        // Nothing renders it, and slicing a kitty graphics payload by rect is not
        // a meaningful operation.
        let slice = FrameSlice.slice(grid(), to: PaneLayoutRect(x: 0, y: 0, width: 2, height: 2))
        XCTAssertTrue(slice.graphics.isEmpty)
    }

    func testCursorInsideTheRectIsTranslatedToLocalCoordinates() {
        let source = grid(cursor: GridCursor(column: 2, row: 1, isVisible: true, shape: 2))
        let slice = FrameSlice.slice(source, to: PaneLayoutRect(x: 1, y: 1, width: 3, height: 2))
        XCTAssertEqual(slice.cursor?.column, 1)
        XCTAssertEqual(slice.cursor?.row, 0)
        XCTAssertEqual(slice.cursor?.isVisible, true)
        XCTAssertEqual(slice.cursor?.shape, 2)
    }

    func testCursorOutsideTheRectIsDropped() {
        // The whole grid carries exactly one cursor and it belongs to the focused
        // pane. Without this, every pane would blink a caret.
        let source = grid(cursor: GridCursor(column: 0, row: 0, isVisible: true, shape: 2))
        let slice = FrameSlice.slice(source, to: PaneLayoutRect(x: 2, y: 1, width: 2, height: 2))
        XCTAssertNil(slice.cursor)
    }

    func testClampsRectToTheFrameBounds() {
        // Between a window resize and the layout_updated that follows there is a
        // frame where the rect still describes the previous size.
        let slice = FrameSlice.slice(grid(), to: PaneLayoutRect(x: 2, y: 2, width: 10, height: 10))
        XCTAssertEqual(slice.width, 2)
        XCTAssertEqual(slice.height, 1)
        XCTAssertEqual(slice.cells.map(\.symbol), ["k", "l"])
    }

    func testFullyOutOfBoundsRectYieldsAnEmptyFrame() {
        let slice = FrameSlice.slice(grid(), to: PaneLayoutRect(x: 9, y: 9, width: 2, height: 2))
        XCTAssertEqual(slice.width, 0)
        XCTAssertEqual(slice.height, 0)
        XCTAssertTrue(slice.cells.isEmpty)
        XCTAssertNil(slice.cursor)
    }

    func testToleratesATruncatedCellArray() {
        // Defensive: this sits downstream of a hand-written decoder, so cells
        // shorter than width*height must not read out of bounds.
        let truncated = GridFrame(
            cells: [GridCell(
                symbol: "a", foreground: 0, background: 0,
                modifier: 0, skip: false, hyperlink: nil
            )],
            width: 4, height: 3, cursor: nil, hyperlinks: [], graphics: []
        )
        let slice = FrameSlice.slice(truncated, to: PaneLayoutRect(x: 0, y: 0, width: 4, height: 3))
        XCTAssertEqual(slice.cells.count, Int(slice.width) * Int(slice.height))
    }

    func testWideCharacterFillerSurvivesSlicing() {
        // A wide character is followed by an unmarked space acting as filler. The
        // slice has to keep it, or every following column shifts left.
        let cells = ["更", " ", "x", "y"].map {
            GridCell(
                symbol: $0, foreground: 0, background: 0,
                modifier: 0, skip: false, hyperlink: nil
            )
        }
        let source = GridFrame(
            cells: cells, width: 4, height: 1, cursor: nil, hyperlinks: [], graphics: []
        )
        let slice = FrameSlice.slice(source, to: PaneLayoutRect(x: 0, y: 0, width: 3, height: 1))
        XCTAssertEqual(slice.cells.map(\.symbol), ["更", " ", "x"])
    }

    func testSlicesTheMeasuredThreePaneLayout() {
        // The real geometry: a 114-column grid split into 0..33, gap, 35..67, gap,
        // 69..113. Each slice must start exactly at its rect origin.
        let width = 114
        var cells: [GridCell] = []
        for column in 0..<width {
            cells.append(GridCell(
                symbol: String(column % 10), foreground: 0, background: 0,
                modifier: 0, skip: false, hyperlink: nil
            ))
        }
        let frame = GridFrame(
            cells: cells, width: UInt16(width), height: 1,
            cursor: nil, hyperlinks: [], graphics: []
        )

        let middle = FrameSlice.slice(frame, to: PaneLayoutRect(x: 35, y: 0, width: 33, height: 1))
        XCTAssertEqual(middle.width, 33)
        XCTAssertEqual(middle.cells.first?.symbol, "5", "column 35 ends in 5")
        XCTAssertEqual(middle.cells.last?.symbol, "7", "column 67 ends in 7")
    }
}
