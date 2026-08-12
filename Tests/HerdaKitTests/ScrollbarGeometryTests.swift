import XCTest
@testable import HerdaKit

final class ScrollbarGeometryTests: XCTestCase {
    func testNoThumbWhenNothingToScroll() {
        // maxOffsetFromBottom of 0 means the scrollback has not passed one screen
        // yet. This is the state a freshly created pane reports — measured:
        // {"max_offset_from_bottom":0,"offset_from_bottom":0,"viewport_rows":40}.
        XCTAssertNil(ScrollbarGeometry.thumb(
            offsetFromBottom: 0, maxOffsetFromBottom: 0, viewportRows: 40
        ))
    }

    func testThumbAtBottomWhenNotScrolledBack() throws {
        // offsetFromBottom counts rows away from the bottom, so 0 is pinned down.
        let thumb = try XCTUnwrap(ScrollbarGeometry.thumb(
            offsetFromBottom: 0, maxOffsetFromBottom: 76, viewportRows: 24
        ))
        XCTAssertEqual(thumb.length, 24.0 / 100.0, accuracy: 0.0001)
        XCTAssertEqual(thumb.start, 76.0 / 100.0, accuracy: 0.0001)
        XCTAssertEqual(thumb.start + thumb.length, 1.0, accuracy: 0.0001)
    }

    func testThumbAtTopWhenScrolledAllTheWayBack() throws {
        let thumb = try XCTUnwrap(ScrollbarGeometry.thumb(
            offsetFromBottom: 76, maxOffsetFromBottom: 76, viewportRows: 24
        ))
        XCTAssertEqual(thumb.start, 0, accuracy: 0.0001)
    }

    func testThumbLengthIsViewportShareOfTotalContent() throws {
        // Total content height is max + viewport, not max: max only says how much
        // further back it can go.
        let thumb = try XCTUnwrap(ScrollbarGeometry.thumb(
            offsetFromBottom: 0, maxOffsetFromBottom: 30, viewportRows: 10
        ))
        XCTAssertEqual(thumb.length, 0.25, accuracy: 0.0001)
    }

    func testGuardsAgainstAZeroViewport() {
        // Resize passes through a moment where the viewport is zero rows.
        XCTAssertNil(ScrollbarGeometry.thumb(
            offsetFromBottom: 0, maxOffsetFromBottom: 10, viewportRows: 0
        ))
    }

    func testClampsAnOffsetBeyondTheMaximum() throws {
        // Optimistic local updates during a scroll briefly exceed the reported
        // maximum before the next poll corrects them; start must not go negative.
        let thumb = try XCTUnwrap(ScrollbarGeometry.thumb(
            offsetFromBottom: 999, maxOffsetFromBottom: 76, viewportRows: 24
        ))
        XCTAssertEqual(thumb.start, 0, accuracy: 0.0001)
    }

    func testClampsANegativeOffset() throws {
        let thumb = try XCTUnwrap(ScrollbarGeometry.thumb(
            offsetFromBottom: -5, maxOffsetFromBottom: 76, viewportRows: 24
        ))
        XCTAssertEqual(thumb.start + thumb.length, 1.0, accuracy: 0.0001)
    }
}
