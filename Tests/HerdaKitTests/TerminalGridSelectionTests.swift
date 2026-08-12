import AppKit
import XCTest
@testable import HerdaKit

/// Selection driven through the real view with synthesized events.
///
/// Constructed rather than automated for the reason the input tests give: GUI
/// keyboard and mouse automation lands in whatever is frontmost, while this
/// exercises the exact path a click takes.
@MainActor
final class TerminalGridSelectionTests: XCTestCase {
    private func makeView(_ rows: [String]) -> TerminalGridView {
        let view = TerminalGridView(terminalFont: TerminalFont(size: 13))
        let width = rows.map { $0.count }.max() ?? 0
        var cells: [GridCell] = []
        for row in rows {
            var text = Array(row)
            while text.count < width { text.append(" ") }
            for character in text {
                cells.append(GridCell(
                    symbol: String(character), foreground: 0, background: 0,
                    modifier: 0, skip: false, hyperlink: nil
                ))
            }
        }
        view.frame = NSRect(
            x: 0, y: 0,
            width: CGFloat(width) * view.cellSize.width,
            height: CGFloat(rows.count) * view.cellSize.height
        )
        view.update(GridFrame(
            cells: cells, width: UInt16(width), height: UInt16(rows.count),
            cursor: nil, hyperlinks: [], graphics: []
        ))
        return view
    }

    /// A mouse event at a cell's leading edge.
    ///
    /// The y is flipped on the way in. The view sets `isFlipped` so row 0 is at
    /// the top, and `convert(_:from: nil)` flips a window-coordinate point to
    /// match — so a test that passes view-space y targets the mirrored row. That
    /// mistake is invisible on a single-row frame, where the mirror is the
    /// identity, which is exactly how it survived the first run here.
    private func mouse(
        _ type: NSEvent.EventType,
        column: Int,
        row: Int,
        clicks: Int = 1,
        in view: TerminalGridView
    ) -> NSEvent {
        let viewY = CGFloat(row) * view.cellSize.height + view.cellSize.height / 2
        return NSEvent.mouseEvent(
            with: type,
            location: CGPoint(
                x: CGFloat(column) * view.cellSize.width,
                y: view.bounds.height - viewY
            ),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clicks,
            pressure: 1
        ) ?? NSEvent()
    }

    private func drag(
        _ view: TerminalGridView,
        from: (Int, Int),
        to: (Int, Int)
    ) {
        view.mouseDown(with: mouse(.leftMouseDown, column: from.0, row: from.1, in: view))
        view.mouseDragged(with: mouse(.leftMouseDragged, column: to.0, row: to.1, in: view))
        view.mouseUp(with: mouse(.leftMouseUp, column: to.0, row: to.1, in: view))
    }

    func testDraggingAcrossOneRowSelectsThatText() {
        let view = makeView(["hello world"])
        drag(view, from: (0, 0), to: (5, 0))
        XCTAssertEqual(view.selectedText, "hello")
    }

    func testDraggingAcrossRowsReadsLinearly() {
        let view = makeView(["abcd", "efgh"])
        drag(view, from: (1, 0), to: (2, 1))
        XCTAssertEqual(view.selectedText, "bcd\nef")
    }

    func testDraggingBackwardsSelectsTheSameText() {
        let view = makeView(["hello world"])
        drag(view, from: (5, 0), to: (0, 0))
        XCTAssertEqual(view.selectedText, "hello")
    }

    func testAPlainClickSelectsNothing() {
        // A click that never moves has to clear the selection without making a
        // one-cell one, which would put a single character on the pasteboard.
        let view = makeView(["hello"])
        drag(view, from: (2, 0), to: (2, 0))
        XCTAssertNil(view.selectedText)
    }

    func testAClickClearsAPreviousSelection() {
        let view = makeView(["hello world"])
        drag(view, from: (0, 0), to: (5, 0))
        XCTAssertNotNil(view.selectedText)
        drag(view, from: (8, 0), to: (8, 0))
        XCTAssertNil(view.selectedText)
    }

    func testDoubleClickSelectsAWord() {
        let view = makeView(["run /usr/local/bin/herdr now"])
        view.mouseDown(with: mouse(.leftMouseDown, column: 10, row: 0, clicks: 2, in: view))
        view.mouseUp(with: mouse(.leftMouseUp, column: 10, row: 0, clicks: 2, in: view))
        XCTAssertEqual(view.selectedText, "/usr/local/bin/herdr")
    }

    func testTripleClickSelectsTheLine() {
        let view = makeView(["first line", "second"])
        view.mouseDown(with: mouse(.leftMouseDown, column: 3, row: 0, clicks: 3, in: view))
        view.mouseUp(with: mouse(.leftMouseUp, column: 3, row: 0, clicks: 3, in: view))
        XCTAssertEqual(view.selectedText, "first line")
    }

    func testTypingClearsTheSelection() {
        // A highlight over a line that has since scrolled means nothing, and every
        // terminal drops it on input.
        let view = makeView(["hello world"])
        drag(view, from: (0, 0), to: (5, 0))
        XCTAssertNotNil(view.selectedText)
        view.keyDown(with: NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "a",
            charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0
        ) ?? NSEvent())
        XCTAssertNil(view.selectedText)
    }

    func testSelectAllTakesEveryRow() {
        let view = makeView(["one", "two"])
        view.selectAll()
        XCTAssertEqual(view.selectedText, "one\ntwo")
    }

    func testClearSelectionRemovesIt() {
        let view = makeView(["hello"])
        view.selectAll()
        view.clearSelection()
        XCTAssertNil(view.selectedText)
    }

    func testDraggingBeyondTheViewDoesNotCrash() {
        // The pointer leaves the view during a drag; the ends are deliberately
        // unclamped so the selection keeps following it.
        let view = makeView(["abc"])
        drag(view, from: (0, 0), to: (99, 99))
        XCTAssertEqual(view.selectedText, "abc")
    }

    func testSelectingBlankSpaceYieldsNoText() {
        // Trailing padding is dropped per row, so a selection entirely inside the
        // padding has nothing in it and must not be reported as copyable.
        let view = makeView(["ab        "])
        drag(view, from: (5, 0), to: (9, 0))
        XCTAssertNil(view.selectedText)
    }
}
