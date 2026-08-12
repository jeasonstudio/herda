import XCTest
@testable import HerdaKit

final class PaneTreeLayoutTests: XCTestCase {
    private let area = CGRect(x: 0, y: 0, width: 1000, height: 600)
    private let gap: CGFloat = 8

    private func sideBySide() -> PaneTree {
        var tree = PaneTree()
        tree.adopt(paneId: "p1")
        tree.split(paneId: "p1", with: "p2", orientation: .horizontal)
        return tree
    }

    func testASinglePaneFillsTheArea() {
        var tree = PaneTree()
        tree.adopt(paneId: "p1")
        let frames = PaneTreeLayout.frames(for: tree, in: area, gap: gap)
        XCTAssertEqual(frames["p1"], area, "no gap is spent when there is no neighbour")
    }

    func testTwoPanesSplitTheAreaMinusOneGap() {
        let frames = PaneTreeLayout.frames(for: sideBySide(), in: area, gap: gap)
        let left = try? XCTUnwrap(frames["p1"])
        let right = try? XCTUnwrap(frames["p2"])
        guard let left, let right else { return XCTFail("both panes need a frame") }

        XCTAssertEqual(left.width + right.width, area.width - gap, accuracy: 0.001)
        XCTAssertEqual(left.minX, 0)
        XCTAssertEqual(right.minX, left.maxX + gap, accuracy: 0.001)
        XCTAssertEqual(left.height, area.height)
        XCTAssertEqual(right.height, area.height)
    }

    func testTheGapIsIndependentOfTheFont() {
        // The whole point of owning layout: the first design's gap was one
        // character cell, so it moved when the font size did.
        let wide = PaneTreeLayout.frames(for: sideBySide(), in: area, gap: 24)
        guard let left = wide["p1"], let right = wide["p2"] else {
            return XCTFail("both panes need a frame")
        }
        XCTAssertEqual(right.minX - left.maxX, 24, accuracy: 0.001)
    }

    func testARatioShiftsTheBoundary() {
        var tree = sideBySide()
        tree.setRatio(0.25, at: [])
        let frames = PaneTreeLayout.frames(for: tree, in: area, gap: gap)
        guard let left = frames["p1"] else { return XCTFail("missing frame") }
        XCTAssertEqual(left.width, (area.width - gap) * 0.25, accuracy: 0.001)
    }

    func testNestingThreeDeepStillTiles() {
        var tree = sideBySide()
        tree.split(paneId: "p2", with: "p3", orientation: .vertical)
        tree.split(paneId: "p3", with: "p4", orientation: .horizontal)

        let frames = PaneTreeLayout.frames(for: tree, in: area, gap: gap)
        XCTAssertEqual(frames.count, 4)
        for (id, frame) in frames {
            XCTAssertGreaterThan(frame.width, 0, "\(id) collapsed horizontally")
            XCTAssertGreaterThan(frame.height, 0, "\(id) collapsed vertically")
            XCTAssertTrue(area.contains(frame), "\(id) escaped the area: \(frame)")
        }
    }

    func testFramesNeverOverlap() {
        var tree = sideBySide()
        tree.split(paneId: "p2", with: "p3", orientation: .vertical)
        let frames = Array(PaneTreeLayout.frames(for: tree, in: area, gap: gap).values)
        for (index, frame) in frames.enumerated() {
            for other in frames[(index + 1)...] {
                XCTAssertFalse(frame.intersects(other), "\(frame) overlaps \(other)")
            }
        }
    }

    func testAnAreaTooSmallForTheGapStillYieldsFrames() {
        // A window can be dragged narrower than the chrome wants. Returning
        // negative widths here would produce a NaN frame and an empty screen.
        let tiny = CGRect(x: 0, y: 0, width: 6, height: 6)
        let frames = PaneTreeLayout.frames(for: sideBySide(), in: tiny, gap: gap)
        XCTAssertEqual(frames.count, 2)
        for frame in frames.values {
            XCTAssertGreaterThanOrEqual(frame.width, 0)
            XCTAssertFalse(frame.width.isNaN)
        }
    }

    func testZoomGivesTheFocusedPaneTheWholeArea() {
        var tree = sideBySide()
        tree.toggleZoom(paneId: "p1")
        let frames = PaneTreeLayout.frames(for: tree, in: area, gap: gap)
        XCTAssertEqual(frames, ["p1": area])
    }

    func testGridSizeFloorsAndNeverReturnsZero() {
        let cell = CGSize(width: 8, height: 17)
        let grid = PaneTreeLayout.gridSize(
            for: CGRect(x: 0, y: 0, width: 100, height: 100), cellSize: cell
        )
        XCTAssertEqual(grid.columns, 12, "100 / 8 = 12.5, floored")
        XCTAssertEqual(grid.rows, 5, "100 / 17 = 5.88, floored")

        let sliver = PaneTreeLayout.gridSize(
            for: CGRect(x: 0, y: 0, width: 3, height: 3), cellSize: cell
        )
        XCTAssertEqual(sliver.columns, 1, "a size herdr will accept, unlike 0")
        XCTAssertEqual(sliver.rows, 1)
    }

    func testDividersSitInTheGapsAndCarryTheirPath() {
        let dividers = PaneTreeLayout.dividers(for: sideBySide(), in: area, gap: gap)
        XCTAssertEqual(dividers.count, 1)
        guard let divider = dividers.first else { return }

        XCTAssertEqual(divider.path, [])
        XCTAssertEqual(divider.orientation, .horizontal)
        XCTAssertEqual(divider.rect.width, gap, accuracy: 0.001)
        XCTAssertEqual(divider.rect.height, area.height)
        // Hit target is wider than what gets drawn: an 8pt strip is hard to grab.
        XCTAssertGreaterThan(divider.hitRect.width, divider.rect.width)
        XCTAssertTrue(divider.hitRect.contains(divider.rect.insetBy(dx: 0.5, dy: 0)))
    }

    func testNestedDividersCarryDistinctPaths() {
        var tree = sideBySide()
        tree.split(paneId: "p2", with: "p3", orientation: .vertical)
        let dividers = PaneTreeLayout.dividers(for: tree, in: area, gap: gap)
        XCTAssertEqual(dividers.count, 2)
        XCTAssertEqual(Set(dividers.map(\.path)), [[], [.second]])
    }

    func testZoomHasNoDividers() {
        var tree = sideBySide()
        tree.toggleZoom(paneId: "p1")
        XCTAssertTrue(PaneTreeLayout.dividers(for: tree, in: area, gap: gap).isEmpty)
    }
}
