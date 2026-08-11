import XCTest
@testable import HerdaKit

final class CharWidthTests: XCTestCase {
    func testASCIIIsSingleWidth() {
        XCTAssertEqual(CharWidth.displayWidth(of: "a"), 1)
        XCTAssertEqual(CharWidth.displayWidth(of: " "), 1)
        XCTAssertEqual(CharWidth.displayWidth(of: "~"), 1)
    }

    func testCJKIsDoubleWidth() {
        XCTAssertEqual(CharWidth.displayWidth(of: "更"), 2)
        XCTAssertEqual(CharWidth.displayWidth(of: "新"), 2)
        XCTAssertEqual(CharWidth.displayWidth(of: "あ"), 2)
        XCTAssertEqual(CharWidth.displayWidth(of: "한"), 2)
    }

    func testFullWidthFormsAreDoubleWidth() {
        XCTAssertEqual(CharWidth.displayWidth(of: "！"), 2)
        XCTAssertEqual(CharWidth.displayWidth(of: "Ａ"), 2)
    }

    func testEmojiPresentationIsDoubleWidth() {
        XCTAssertEqual(CharWidth.displayWidth(of: "👍"), 2)
        XCTAssertEqual(CharWidth.displayWidth(of: "🐑"), 2)
    }

    func testBoxDrawingIsSingleWidth() {
        // herdr draws pane borders with these; treating them as wide would
        // shear every frame.
        XCTAssertEqual(CharWidth.displayWidth(of: "╭"), 1)
        XCTAssertEqual(CharWidth.displayWidth(of: "─"), 1)
        XCTAssertEqual(CharWidth.displayWidth(of: "│"), 1)
        XCTAssertEqual(CharWidth.displayWidth(of: "╯"), 1)
    }

    func testPrecomposedAccentIsSingleWidth() {
        XCTAssertEqual(CharWidth.displayWidth(of: "é"), 1)
    }

    func testCombiningSequenceStillOccupiesOneCell() {
        // The server already grouped this into one cell; a cell never
        // advances zero columns.
        XCTAssertEqual(CharWidth.displayWidth(of: "e\u{0301}"), 1)
    }

    func testEmptySymbolOccupiesOneCell() {
        XCTAssertEqual(CharWidth.displayWidth(of: ""), 1)
    }

    func testWidthIsClampedToTwo() {
        for symbol in ["a", "更", "👍", "", "é"] {
            let width = CharWidth.displayWidth(of: symbol)
            XCTAssertTrue((1 ... 2).contains(width), "\(symbol) reported \(width)")
        }
    }
}
