import XCTest
@testable import HerdaKit

final class GapProbeTests: XCTestCase {
    private func frame(_ rows: [String]) -> GridFrame {
        let width = rows.map(\.count).max() ?? 0
        var cells: [GridCell] = []
        for row in rows {
            let padded = row.padding(toLength: width, withPad: " ", startingAt: 0)
            for character in padded {
                cells.append(GridCell(
                    symbol: String(character), foreground: 0, background: 0,
                    modifier: 0, skip: false, hyperlink: nil
                ))
            }
        }
        return GridFrame(
            cells: cells, width: UInt16(width), height: UInt16(rows.count),
            cursor: nil, hyperlinks: [], graphics: []
        )
    }

    /// Left pane covers 0..<2, the gap is column 2, right pane covers 3..<5.
    private let panes = [
        PaneLayoutRect(x: 0, y: 0, width: 2, height: 2),
        PaneLayoutRect(x: 3, y: 0, width: 2, height: 2),
    ]

    func testEmptyGapReportsNoOverflow() {
        // With pane_borders off, that column is blank by construction.
        let grid = frame(["ab cd",
                          "ef gh"])
        XCTAssertFalse(GapProbe.hasContentOutsidePanes(grid, panes: panes))
    }

    func testContentInTheGapReportsOverflow() {
        // A modal spanning both panes occupies the gap column.
        let grid = frame(["ab─cd",
                          "ef│gh"])
        XCTAssertTrue(GapProbe.hasContentOutsidePanes(grid, panes: panes))
    }

    func testTreatsTabsAndBlanksAsEmpty() {
        // ratatui pads with ordinary spaces, but a stray tab is not content either.
        let grid = frame(["ab\tcd",
                          "ef gh"])
        XCTAssertFalse(GapProbe.hasContentOutsidePanes(grid, panes: panes))
    }

    func testRowsBelowEveryPaneCountAsOutside() {
        // That is where herdr's tab row reappears once a workspace has a second
        // tab, which deserves the same whole-grid fallback.
        let grid = frame(["ab cd",
                          "ef gh",
                          "tab1 "])
        XCTAssertTrue(GapProbe.hasContentOutsidePanes(grid, panes: panes))
    }

    func testSinglePaneCoveringEverythingReportsNoOverflow() {
        let grid = frame(["abcde",
                          "fghij"])
        XCTAssertFalse(GapProbe.hasContentOutsidePanes(
            grid,
            panes: [PaneLayoutRect(x: 0, y: 0, width: 5, height: 2)]
        ))
    }

    func testToleratesRectsLargerThanTheFrame() {
        let grid = frame(["ab"])
        XCTAssertFalse(GapProbe.hasContentOutsidePanes(
            grid,
            panes: [PaneLayoutRect(x: 0, y: 0, width: 99, height: 99)]
        ))
    }

    func testEmptyFrameReportsNoOverflow() {
        let empty = GridFrame(
            cells: [], width: 0, height: 0, cursor: nil, hyperlinks: [], graphics: []
        )
        XCTAssertFalse(GapProbe.hasContentOutsidePanes(empty, panes: panes))
    }

    func testNoPanesReportsOverflowWhenAnythingIsDrawn() {
        // Before pane.layout answers there are no rects, so nothing is covered.
        // Reporting overflow keeps the caller on whole-grid rendering, which is
        // the safe state.
        let grid = frame(["ab"])
        XCTAssertTrue(GapProbe.hasContentOutsidePanes(grid, panes: []))
    }
}
