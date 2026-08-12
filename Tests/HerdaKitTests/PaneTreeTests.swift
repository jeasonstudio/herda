import XCTest
@testable import HerdaKit

final class PaneTreeTests: XCTestCase {
    private func twoPanes() -> PaneTree {
        var tree = PaneTree()
        tree.adopt(paneId: "p1")
        tree.split(paneId: "p1", with: "p2", orientation: .horizontal)
        return tree
    }

    func testStartsEmpty() {
        let tree = PaneTree()
        XCTAssertNil(tree.root)
        XCTAssertNil(tree.focusedPaneId)
        XCTAssertTrue(tree.paneIds.isEmpty)
    }

    func testAdoptingTheFirstPaneFocusesIt() {
        var tree = PaneTree()
        tree.adopt(paneId: "p1")
        XCTAssertEqual(tree.paneIds, ["p1"])
        XCTAssertEqual(tree.focusedPaneId, "p1")
    }

    func testSplittingPutsTheNewPaneSecondAndFocusesIt() {
        // Second, so a split right puts the new pane on the right and a split
        // down puts it below — which is what the menu items say they do.
        let tree = twoPanes()
        XCTAssertEqual(tree.paneIds, ["p1", "p2"])
        XCTAssertEqual(tree.focusedPaneId, "p2")
    }

    func testSplittingNestsThreeDeep() {
        var tree = twoPanes()
        tree.split(paneId: "p2", with: "p3", orientation: .vertical)
        tree.split(paneId: "p3", with: "p4", orientation: .horizontal)
        XCTAssertEqual(tree.paneIds, ["p1", "p2", "p3", "p4"])
    }

    func testSplittingAnUnknownPaneDoesNothing() {
        var tree = twoPanes()
        let before = tree
        tree.split(paneId: "nope", with: "p9", orientation: .horizontal)
        XCTAssertEqual(tree, before)
    }

    func testClosingCollapsesTheParentIntoTheSibling() {
        var tree = twoPanes()
        tree.close(paneId: "p2")
        XCTAssertEqual(tree.root, .pane("p1"), "the split is gone, not left with one child")
        XCTAssertEqual(tree.focusedPaneId, "p1")
    }

    func testClosingAnInnerPaneKeepsTheRestOfTheShape() {
        var tree = twoPanes()
        tree.split(paneId: "p2", with: "p3", orientation: .vertical)
        tree.close(paneId: "p2")
        XCTAssertEqual(tree.paneIds, ["p1", "p3"])
    }

    func testClosingTheFocusedPaneMovesFocusToTheSibling() {
        var tree = twoPanes()
        tree.focus(paneId: "p2")
        tree.close(paneId: "p2")
        XCTAssertEqual(tree.focusedPaneId, "p1")
    }

    func testClosingTheLastPaneEmptiesTheTree() {
        var tree = PaneTree()
        tree.adopt(paneId: "p1")
        tree.close(paneId: "p1")
        XCTAssertNil(tree.root)
        XCTAssertNil(tree.focusedPaneId)
    }

    func testClosingClearsZoomWhenItPointedAtThatPane() {
        // A zoom left pointing at a closed pane would render nothing at all.
        var tree = twoPanes()
        tree.toggleZoom(paneId: "p2")
        XCTAssertEqual(tree.zoomedPaneId, "p2")
        tree.close(paneId: "p2")
        XCTAssertNil(tree.zoomedPaneId)
    }

    func testZoomHidesTheSiblings() {
        var tree = twoPanes()
        tree.toggleZoom(paneId: "p1")
        XCTAssertEqual(tree.visiblePaneIds, ["p1"])
        XCTAssertEqual(tree.paneIds, ["p1", "p2"], "the tree itself is unchanged")
        tree.toggleZoom(paneId: "p1")
        XCTAssertEqual(tree.visiblePaneIds, ["p1", "p2"])
    }

    func testRatioIsClampedAwayFromZero() {
        // A pane at ratio 0 would be asked for 0 columns, and herdr sizes a PTY
        // from what the client declares.
        var tree = twoPanes()
        tree.setRatio(0, at: [])
        XCTAssertEqual(tree.ratio(at: []), 0.1)
        tree.setRatio(1, at: [])
        XCTAssertEqual(tree.ratio(at: []), 0.9)
        tree.setRatio(0.42, at: [])
        XCTAssertEqual(tree.ratio(at: []) ?? 0, 0.42, accuracy: 0.0001)
    }

    func testPaneOrderIsLeftToRightThenTopToBottom() {
        // The order the sidebar and the focus-cycling commands both read.
        var tree = PaneTree()
        tree.adopt(paneId: "a")
        tree.split(paneId: "a", with: "b", orientation: .horizontal)
        tree.split(paneId: "a", with: "c", orientation: .vertical)
        XCTAssertEqual(tree.paneIds, ["a", "c", "b"])
    }

    func testDirectionalNeighbourUsesTheTreeNotGeometry() {
        // a | b horizontally: right of a is b, left of b is a, and there is
        // nothing above either.
        let tree = twoPanes()
        XCTAssertEqual(tree.neighbour(of: "p1", .right), "p2")
        XCTAssertEqual(tree.neighbour(of: "p2", .left), "p1")
        XCTAssertNil(tree.neighbour(of: "p1", .up))
        XCTAssertNil(tree.neighbour(of: "p1", .left))
    }

    func testDirectionalNeighbourWalksUpPastAMismatchedSplit() {
        // a | (b over c). Right of a is the b/c subtree, whose first leaf is b.
        // Down from b is c. Up from c is b. Left of c walks up to a.
        var tree = PaneTree()
        tree.adopt(paneId: "a")
        tree.split(paneId: "a", with: "b", orientation: .horizontal)
        tree.split(paneId: "b", with: "c", orientation: .vertical)

        XCTAssertEqual(tree.neighbour(of: "a", .right), "b")
        XCTAssertEqual(tree.neighbour(of: "b", .down), "c")
        XCTAssertEqual(tree.neighbour(of: "c", .up), "b")
        XCTAssertEqual(tree.neighbour(of: "c", .left), "a")
    }

    func testFocusIgnoresAnUnknownPane() {
        var tree = twoPanes()
        tree.focus(paneId: "ghost")
        XCTAssertEqual(tree.focusedPaneId, "p2")
    }
}
