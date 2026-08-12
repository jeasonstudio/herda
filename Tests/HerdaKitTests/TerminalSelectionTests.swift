import XCTest
@testable import HerdaKit

final class TerminalSelectionTests: XCTestCase {
    /// Builds a frame from rows of text, padding each to the widest, the way the
    /// wire does. A wide character is followed by an unmarked filler cell.
    private func frame(_ rows: [String]) -> GridFrame {
        let width = rows.map { $0.count }.max() ?? 0
        var cells: [GridCell] = []
        for row in rows {
            var columns = 0
            for character in row {
                cells.append(GridCell(
                    symbol: String(character), foreground: 0, background: 0,
                    modifier: 0, skip: false, hyperlink: nil
                ))
                columns += 1
            }
            while columns < width {
                cells.append(GridCell(
                    symbol: " ", foreground: 0, background: 0,
                    modifier: 0, skip: false, hyperlink: nil
                ))
                columns += 1
            }
        }
        return GridFrame(
            cells: cells, width: UInt16(width), height: UInt16(rows.count),
            cursor: nil, hyperlinks: [], graphics: []
        )
    }

    private func cell(_ column: Int, _ row: Int) -> TerminalSelection.Cell {
        TerminalSelection.Cell(column: column, row: row)
    }

    func testASingleCellCountsAsEmpty() {
        // A plain click produces anchor == focus. Treating that as a selection
        // would make every click put a character on the pasteboard.
        let selection = TerminalSelection(anchor: cell(3, 1), focus: cell(3, 1))
        XCTAssertTrue(selection.isEmpty)
        XCTAssertFalse(selection.contains(column: 3, row: 1))
        XCTAssertEqual(selection.text(from: frame(["abc"])), "")
    }

    func testDraggingBackwardsSelectsTheSameRange() {
        let forward = TerminalSelection(anchor: cell(1, 0), focus: cell(4, 0))
        let backward = TerminalSelection(anchor: cell(4, 0), focus: cell(1, 0))
        XCTAssertEqual(forward.bounds.start, backward.bounds.start)
        XCTAssertEqual(forward.bounds.end, backward.bounds.end)
        let grid = frame(["hello"])
        XCTAssertEqual(forward.text(from: grid), backward.text(from: grid))
    }

    func testSelectionWithinOneRowExcludesTheEndColumn() {
        // The end is exclusive so a drag that stops on a column does not take the
        // character under the pointer, matching how text selection reads
        // everywhere else.
        let selection = TerminalSelection(anchor: cell(0, 0), focus: cell(3, 0))
        XCTAssertEqual(selection.text(from: frame(["abcdef"])), "abc")
        XCTAssertTrue(selection.contains(column: 2, row: 0))
        XCTAssertFalse(selection.contains(column: 3, row: 0))
    }

    func testSelectionIsLinearNotRectangular() {
        // Across rows the range runs to the end of each and continues on the next.
        // A rectangular selection would give "b\nf", which is not how copying a
        // wrapped command line should behave.
        let selection = TerminalSelection(anchor: cell(1, 0), focus: cell(2, 1))
        XCTAssertEqual(selection.text(from: frame(["abcd", "efgh"])), "bcd\nef")
    }

    func testTrailingBlanksAreDroppedPerRow() {
        // Every row is padded to full width on the wire, so keeping the padding
        // would put a run of spaces after each line on the pasteboard.
        let selection = TerminalSelection(anchor: cell(0, 0), focus: cell(6, 1))
        XCTAssertEqual(selection.text(from: frame(["ab", "cdefgh"])), "ab\ncdefgh")
    }

    func testAnEntirelyBlankRowStaysAnEmptyLine() {
        // It is a real blank line in the output, not padding.
        let selection = TerminalSelection(anchor: cell(0, 0), focus: cell(1, 2))
        XCTAssertEqual(selection.text(from: frame(["a", " ", "b"])), "a\n\nb")
    }

    func testFillerCellsAfterAWideCharacterAreSkipped() {
        // A wide character occupies two cells and the second is marked `skip`.
        // Including it would add a space after every CJK glyph.
        var cells: [GridCell] = [
            GridCell(symbol: "世", foreground: 0, background: 0,
                     modifier: 0, skip: false, hyperlink: nil),
            GridCell(symbol: " ", foreground: 0, background: 0,
                     modifier: 0, skip: true, hyperlink: nil),
            GridCell(symbol: "a", foreground: 0, background: 0,
                     modifier: 0, skip: false, hyperlink: nil),
        ]
        cells.append(GridCell(symbol: " ", foreground: 0, background: 0,
                              modifier: 0, skip: false, hyperlink: nil))
        let grid = GridFrame(
            cells: cells, width: 4, height: 1,
            cursor: nil, hyperlinks: [], graphics: []
        )
        let selection = TerminalSelection(anchor: cell(0, 0), focus: cell(4, 0))
        XCTAssertEqual(selection.text(from: grid), "世a")
    }

    func testWordExpansionKeepsAPathWhole() {
        // Double-clicking a path has to give the path. Splitting on / or . would
        // give one segment, which is never what was meant.
        let grid = frame(["run /usr/local/bin/herdr now"])
        let selection = TerminalSelection.word(at: cell(10, 0), in: grid)
        XCTAssertEqual(selection?.text(from: grid), "/usr/local/bin/herdr")
    }

    func testWordExpansionStopsAtSpaces() {
        let grid = frame(["alpha beta"])
        XCTAssertEqual(TerminalSelection.word(at: cell(7, 0), in: grid)?.text(from: grid), "beta")
        XCTAssertEqual(TerminalSelection.word(at: cell(0, 0), in: grid)?.text(from: grid), "alpha")
    }

    func testWordExpansionOnABlankCellSelectsNothing() {
        let grid = frame(["alpha beta"])
        XCTAssertNil(TerminalSelection.word(at: cell(5, 0), in: grid))
    }

    func testLineExpansionTakesTheWholeRowWithoutPadding() {
        let grid = frame(["short", "much longer row"])
        XCTAssertEqual(TerminalSelection.line(at: cell(2, 0), in: grid)?.text(from: grid), "short")
    }

    func testSelectAllSpansEveryRow() {
        let grid = frame(["one", "two", "three"])
        XCTAssertEqual(TerminalSelection.all(in: grid)?.text(from: grid), "one\ntwo\nthree")
    }

    func testOutOfRangeRowsAreClamped() {
        // The pointer can leave the view during a drag; a row past the end must
        // not index out of bounds.
        let grid = frame(["abc"])
        let selection = TerminalSelection(anchor: cell(0, 0), focus: cell(3, 40))
        XCTAssertEqual(selection.text(from: grid), "abc")
    }

    func testAnEmptyFrameYieldsNoText() {
        let grid = GridFrame(
            cells: [], width: 0, height: 0, cursor: nil, hyperlinks: [], graphics: []
        )
        let selection = TerminalSelection(anchor: cell(0, 0), focus: cell(5, 2))
        XCTAssertEqual(selection.text(from: grid), "")
        XCTAssertNil(TerminalSelection.all(in: grid))
        XCTAssertNil(TerminalSelection.word(at: cell(0, 0), in: grid))
    }
}
