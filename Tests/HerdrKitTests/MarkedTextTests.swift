import CoreGraphics
import Foundation
import XCTest
@testable import HerdrKit

final class MarkedTextTests: XCTestCase {
    private let cell = CGSize(width: 8, height: 17)

    private func layout(
        _ text: String,
        column: Int = 0,
        row: Int = 0,
        width: Int = 10,
        height: Int = 4
    ) -> [MarkedText.Slot] {
        MarkedText.layout(
            text,
            cursorColumn: column,
            cursorRow: row,
            gridWidth: width,
            gridHeight: height
        )
    }

    func testEmptyTextProducesNoSlots() {
        XCTAssertTrue(layout("").isEmpty)
    }

    func testLayoutStartsAtTheCursor() {
        let slots = layout("ni", column: 4, row: 2)
        XCTAssertEqual(slots.first?.column, 4)
        XCTAssertEqual(slots.first?.row, 2)
    }

    func testNarrowCharactersAdvanceOneColumn() {
        let slots = layout("abc")
        XCTAssertEqual(slots.map(\.column), [0, 1, 2])
        XCTAssertEqual(slots.map(\.width), [1, 1, 1])
    }

    func testWideCharactersAdvanceTwoColumns() {
        let slots = layout("更新")
        XCTAssertEqual(slots.map(\.column), [0, 2])
        XCTAssertEqual(slots.map(\.width), [2, 2])
    }

    func testWrapsAtTheRightEdge() {
        let slots = layout("abcdef", column: 8, width: 10)
        XCTAssertEqual(slots.map(\.column), [8, 9, 0, 1, 2, 3])
        XCTAssertEqual(slots.map(\.row), [0, 0, 1, 1, 1, 1])
    }

    /// A wide character that would only half fit moves whole rather than being
    /// split across the edge.
    func testWideCharacterNeverStraddlesTheEdge() {
        let slots = layout("更更", column: 9, width: 10)
        XCTAssertEqual(slots.map(\.column), [0, 2])
        XCTAssertEqual(slots.map(\.row), [1, 1])
    }

    func testStopsAtTheBottomOfTheGrid() {
        let slots = layout("abcdefghij", column: 0, row: 1, width: 2, height: 2)
        XCTAssertTrue(slots.allSatisfy { $0.row < 2 })
        XCTAssertEqual(slots.count, 2, "only the last row's worth of cells is left")
    }

    func testUTF16OffsetsTrackMultiUnitCharacters() {
        let slots = layout("a😀b")
        XCTAssertEqual(slots.map(\.utf16Offset), [0, 1, 3], "the emoji is a surrogate pair")
    }

    func testClampsAnOutOfRangeCursor() {
        let slots = layout("a", column: 99, row: 99, width: 4, height: 2)
        XCTAssertEqual(slots.first?.column, 3)
        XCTAssertEqual(slots.first?.row, 1)
    }

    // MARK: - Candidate window anchoring

    /// The candidate window is placed from the same layout the text is drawn
    /// with, in display columns — counting characters would report a half-typed
    /// CJK phrase as half as wide as it is.
    func testBoundingRectUsesDisplayColumnsNotCharacterCount() {
        let slots = layout("更新")
        let rect = MarkedText.boundingRect(
            for: NSRange(location: 0, length: 2),
            in: slots,
            cellSize: cell
        )
        XCTAssertEqual(rect?.width, cell.width * 4)
    }

    func testBoundingRectAnchorsToTheRangesOwnRow() {
        let slots = layout("abcdef", column: 8, width: 10)
        let rect = MarkedText.boundingRect(
            for: NSRange(location: 2, length: 1),
            in: slots,
            cellSize: cell
        )
        XCTAssertEqual(rect?.minY, cell.height, "third character wrapped to row 1")
        XCTAssertEqual(rect?.minX, 0)
    }

    /// A multi-row range still yields one anchor rectangle: an input method has
    /// nowhere to put a two-row union.
    func testBoundingRectClipsToOneRow() {
        let slots = layout("abcdef", column: 8, width: 10)
        let rect = MarkedText.boundingRect(
            for: NSRange(location: 0, length: 6),
            in: slots,
            cellSize: cell
        )
        XCTAssertEqual(rect?.minY, 0)
        XCTAssertEqual(rect?.width, cell.width * 2, "only the two cells on row 0")
    }

    func testBoundingRectPastTheEndAnchorsAfterTheLastCharacter() {
        let slots = layout("ab")
        let rect = MarkedText.boundingRect(
            for: NSRange(location: 9, length: 0),
            in: slots,
            cellSize: cell
        )
        XCTAssertEqual(rect?.minX, cell.width * 2)
    }

    func testBoundingRectWithoutSlotsIsNil() {
        XCTAssertNil(MarkedText.boundingRect(for: NSRange(location: 0, length: 0), in: [], cellSize: cell))
    }

    func testBoundingRectAgreesWithTheDrawnColumn() {
        let slots = layout("更新", column: 3, row: 1)
        let rect = MarkedText.boundingRect(
            for: NSRange(location: 1, length: 1),
            in: slots,
            cellSize: cell
        )
        let drawn = slots[1]
        XCTAssertEqual(rect?.minX, CGFloat(drawn.column) * cell.width)
        XCTAssertEqual(rect?.minY, CGFloat(drawn.row) * cell.height)
    }
}
