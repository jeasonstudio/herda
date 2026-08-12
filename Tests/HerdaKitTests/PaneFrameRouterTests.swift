import XCTest
@testable import HerdaKit

final class PaneFrameRouterTests: XCTestCase {
    private func frame(width: UInt16, height: UInt16, fill: String = "x") -> GridFrame {
        GridFrame(
            cells: Array(
                repeating: GridCell(
                    symbol: fill, foreground: 0, background: 0,
                    modifier: 0, skip: false, hyperlink: nil
                ),
                count: Int(width) * Int(height)
            ),
            width: width, height: height, cursor: nil, hyperlinks: [], graphics: []
        )
    }

    /// Two panes side by side with the gap on column 2, mirroring what herdr
    /// reports under pane_gaps.
    private let twoPanes = PaneLayoutSnapshot(
        workspaceId: "w1", tabId: "w1:t1", zoomed: false,
        area: PaneLayoutRect(x: 0, y: 0, width: 5, height: 2),
        focusedPaneId: "w1:p1",
        panes: [
            PaneLayoutPane(paneId: "w1:p1", focused: true,
                           rect: PaneLayoutRect(x: 0, y: 0, width: 2, height: 2)),
            PaneLayoutPane(paneId: "w1:p2", focused: false,
                           rect: PaneLayoutRect(x: 3, y: 0, width: 2, height: 2)),
        ],
        splits: []
    )

    func testRoutesOneSliceToEachPane() {
        var router = PaneFrameRouter()
        router.apply(twoPanes)
        let slices = router.slices(for: frame(width: 5, height: 2))

        XCTAssertEqual(slices.count, 2)
        XCTAssertEqual(slices["w1:p1"]?.width, 2)
        XCTAssertEqual(slices["w1:p2"]?.width, 2)
    }

    func testFallsBackToTheWholeGridWhenContentCrossesPanes() {
        // A modal opened with a prefix key spans panes. Slicing would cut it at the
        // card gap and drop whatever sits in the gap column.
        var router = PaneFrameRouter()
        router.apply(twoPanes)

        var cells = frame(width: 5, height: 2, fill: " ").cells
        cells[2] = GridCell(
            symbol: "─", foreground: 0, background: 0,
            modifier: 0, skip: false, hyperlink: nil
        )
        let crossing = GridFrame(
            cells: cells, width: 5, height: 2,
            cursor: nil, hyperlinks: [], graphics: []
        )

        XCTAssertTrue(router.shouldRenderWholeGrid(crossing))
    }

    func testDoesNotFallBackWhenTheGapIsBlank() {
        var router = PaneFrameRouter()
        router.apply(twoPanes)
        XCTAssertFalse(router.shouldRenderWholeGrid(frame(width: 5, height: 2, fill: " ")))
    }

    func testZoomedRoutesEverythingToTheFocusedPane() {
        // Measured: with zoomed set, the server still reports every pane at its
        // unzoomed rect while only the focused one is drawn, filling the area.
        var router = PaneFrameRouter()
        router.apply(PaneLayoutSnapshot(
            workspaceId: "w1", tabId: "w1:t1", zoomed: true,
            area: PaneLayoutRect(x: 0, y: 0, width: 5, height: 2),
            focusedPaneId: "w1:p1",
            panes: twoPanes.panes, splits: []
        ))
        let slices = router.slices(for: frame(width: 5, height: 2))
        XCTAssertEqual(Array(slices.keys), ["w1:p1"])
        XCTAssertEqual(slices["w1:p1"]?.width, 5, "the focused pane fills the whole area")
    }

    func testNoLayoutYetRoutesNothing() {
        // The first frame can arrive before pane.layout answers. Guessing a layout
        // then would flash a wrong picture.
        let router = PaneFrameRouter()
        XCTAssertTrue(router.slices(for: frame(width: 5, height: 2)).isEmpty)
        XCTAssertTrue(router.shouldRenderWholeGrid(frame(width: 5, height: 2)))
    }

    func testTracksTheFocusedPaneAndOrder() {
        var router = PaneFrameRouter()
        router.apply(twoPanes)
        XCTAssertEqual(router.focusedPaneId, "w1:p1")
        XCTAssertEqual(router.paneIds, ["w1:p1", "w1:p2"])
    }

    func testCursorGoesOnlyToThePaneContainingIt() {
        // The whole grid carries one cursor. Without this, every pane would blink.
        var router = PaneFrameRouter()
        router.apply(twoPanes)
        let withCursor = GridFrame(
            cells: frame(width: 5, height: 2, fill: " ").cells,
            width: 5, height: 2,
            cursor: GridCursor(column: 3, row: 1, isVisible: true, shape: 2),
            hyperlinks: [], graphics: []
        )
        let slices = router.slices(for: withCursor)
        XCTAssertNil(slices["w1:p1"]?.cursor)
        XCTAssertEqual(slices["w1:p2"]?.cursor?.column, 0, "translated into pane-local space")
        XCTAssertEqual(slices["w1:p2"]?.cursor?.row, 1)
    }
}
