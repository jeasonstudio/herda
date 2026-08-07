import AppKit
import XCTest
@testable import HerdrKit

final class TerminalGridViewTests: XCTestCase {
    private var view: TerminalGridView {
        TerminalGridView(font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
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
}
