import CoreGraphics
import XCTest
@testable import HerdaKit

final class LayoutGeometryTests: XCTestCase {
    /// Measured: MapleMono-NF-CN at 13pt gives a cell of 8x17 (advance 7.8
    /// rounded to 8).
    private let cell = CGSize(width: 8, height: 17)

    // MARK: Cell to pixel

    func testMapsCellRectToPixelFrame() {
        let rect = PaneLayoutRect(x: 40, y: 2, width: 40, height: 22)
        let frame = LayoutGeometry.frame(for: rect, cellSize: cell)
        XCTAssertEqual(frame, CGRect(x: 320, y: 34, width: 320, height: 374))
    }

    func testAppliesOrigin() {
        // The terminal area does not start at the window origin; the card insets
        // come from ChromeMetrics and this function only consumes the result.
        let rect = PaneLayoutRect(x: 0, y: 0, width: 10, height: 1)
        let frame = LayoutGeometry.frame(
            for: rect,
            cellSize: cell,
            origin: CGPoint(x: 8, y: 40)
        )
        XCTAssertEqual(frame, CGRect(x: 8, y: 40, width: 80, height: 17))
    }

    func testGapBetweenAdjacentFramesIsOneCellWide() {
        // One cell is 8pt, which is exactly ChromeMetrics.cardGap — so the gap
        // herdr leaves between panes needs no conversion to become the card gap.
        let left = LayoutGeometry.frame(
            for: PaneLayoutRect(x: 0, y: 0, width: 39, height: 24), cellSize: cell
        )
        let right = LayoutGeometry.frame(
            for: PaneLayoutRect(x: 40, y: 0, width: 40, height: 24), cellSize: cell
        )
        XCTAssertEqual(right.minX - left.maxX, cell.width)
        XCTAssertEqual(right.minX - left.maxX, ChromeMetrics.cardGap)
    }

    // MARK: Zoom

    func testVisiblePanesPassesThroughWhenNotZoomed() {
        let snapshot = Self.twoPanes(zoomed: false)
        XCTAssertEqual(LayoutGeometry.visiblePanes(in: snapshot).map(\.paneId), ["w1:p1", "w1:p2"])
    }

    func testZoomedCollapsesToTheFocusedPaneFillingTheArea() {
        // Measured: with zoomed true the server still reports every pane at its
        // unzoomed rect, while ui/panes.rs renders only the focused pane filling
        // the whole area. Slicing by the reported rects would misplace everything.
        let snapshot = Self.twoPanes(zoomed: true)
        let visible = LayoutGeometry.visiblePanes(in: snapshot)
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible[0].paneId, "w1:p1")
        XCTAssertTrue(visible[0].focused)
        XCTAssertEqual(visible[0].rect, snapshot.area, "the focused pane must fill the area")
    }

    func testZoomedFallsBackWhenFocusedPaneIsMissing() {
        // A self-contradictory snapshot must not crash or blank the screen:
        // returning the panes as given makes the misplacement visible and
        // diagnosable, whereas an empty result is just a black window.
        let snapshot = PaneLayoutSnapshot(
            workspaceId: "w1", tabId: "w1:t1", zoomed: true,
            area: PaneLayoutRect(x: 0, y: 0, width: 80, height: 24),
            focusedPaneId: "w1:pX",
            panes: [PaneLayoutPane(
                paneId: "w1:p1", focused: true,
                rect: PaneLayoutRect(x: 0, y: 0, width: 80, height: 24)
            )],
            splits: []
        )
        XCTAssertEqual(LayoutGeometry.visiblePanes(in: snapshot).map(\.paneId), ["w1:p1"])
    }

    // MARK: Pixel back to cell

    func testConvertsPaneLocalPointBackToGridCoordinates() {
        // Inverse of frame(for:). herdr routes mouse events with pane_at(col,row)
        // on whole-grid coordinates, so a pane-local point has to be offset by
        // its rect origin before being reported.
        let rect = PaneLayoutRect(x: 40, y: 2, width: 40, height: 22)
        let position = LayoutGeometry.gridPosition(
            forPointInPane: CGPoint(x: 12, y: 20),
            paneRect: rect,
            cellSize: cell
        )
        XCTAssertEqual(position.column, 41)   // 40 + floor(12/8)
        XCTAssertEqual(position.row, 3)       // 2 + floor(20/17)
    }

    func testGridPositionClampsNegativePoints() {
        // AppKit hands out negative coordinates when a drag leaves the view, and
        // converting those to UInt16 unclamped would trap.
        let position = LayoutGeometry.gridPosition(
            forPointInPane: CGPoint(x: -30, y: -5),
            paneRect: PaneLayoutRect(x: 0, y: 0, width: 10, height: 10),
            cellSize: cell
        )
        XCTAssertEqual(position.column, 0)
        XCTAssertEqual(position.row, 0)
    }

    func testGridPositionSurvivesADegenerateCellSize() {
        // Startup and resize both pass through a moment where metrics are zero.
        let position = LayoutGeometry.gridPosition(
            forPointInPane: CGPoint(x: 10, y: 10),
            paneRect: PaneLayoutRect(x: 7, y: 3, width: 10, height: 10),
            cellSize: .zero
        )
        XCTAssertEqual(position.column, 7)
        XCTAssertEqual(position.row, 3)
    }

    private static func twoPanes(zoomed: Bool) -> PaneLayoutSnapshot {
        PaneLayoutSnapshot(
            workspaceId: "w1", tabId: "w1:t1", zoomed: zoomed,
            area: PaneLayoutRect(x: 0, y: 0, width: 80, height: 24),
            focusedPaneId: "w1:p1",
            panes: [
                PaneLayoutPane(
                    paneId: "w1:p1", focused: true,
                    rect: PaneLayoutRect(x: 0, y: 0, width: 39, height: 24)
                ),
                PaneLayoutPane(
                    paneId: "w1:p2", focused: false,
                    rect: PaneLayoutRect(x: 40, y: 0, width: 40, height: 24)
                ),
            ],
            splits: []
        )
    }
}
