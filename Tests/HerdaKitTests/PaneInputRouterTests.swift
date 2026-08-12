import XCTest
@testable import HerdaKit

final class PaneInputRouterTests: XCTestCase {
    private func route(_ input: TerminalInput) -> PaneInputRouter.Route {
        PaneInputRouter.route(input)
    }

    func testTextGoesToTheApiAsText() {
        // herdr wraps it for bracketed paste when the pane has that enabled,
        // which a client cannot know (app/api_helpers.rs:25).
        XCTAssertEqual(route(.text("hi", kind: .commit)), .text("hi"))
        XCTAssertEqual(route(.text("hi", kind: .paste)), .text("hi"))
    }

    func testNameableKeysGoToTheApiAsNames() {
        XCTAssertEqual(route(.key(.enter, [])), .keys(["enter"]))
        XCTAssertEqual(route(.key(.character("c"), [.control])), .keys(["ctrl+c"]))
        XCTAssertEqual(route(.key(.backTab, [])), .keys(["shift+tab"]))
    }

    func testTheFourUnnameableKeysGoOutAsRawBytes() {
        // Measured: herdr's API rejects these names outright, and pane.send_text
        // cannot carry escape sequences because bracketed paste neutralises them.
        XCTAssertEqual(route(.key(.home, [])), .bytes(Array("\u{1b}[H".utf8)))
        XCTAssertEqual(route(.key(.end, [])), .bytes(Array("\u{1b}[F".utf8)))
        XCTAssertEqual(route(.key(.delete, [])), .bytes(Array("\u{1b}[3~".utf8)))
        XCTAssertEqual(route(.key(.insert, [])), .bytes(Array("\u{1b}[2~".utf8)))
    }

    func testPageKeysGoOutAsScrollCarryingTheirBytes() {
        // AttachScroll's PageKey source exists for exactly this: the server
        // decides per pane whether the page key moves host scrollback or is
        // forwarded to the child application. Sending raw bytes instead would
        // take that decision away from it.
        XCTAssertEqual(
            route(.key(.pageUp, [])),
            .scroll(up: true, lines: 1, pageKeyInput: Array("\u{1b}[5~".utf8))
        )
        XCTAssertEqual(
            route(.key(.pageDown, [])),
            .scroll(up: false, lines: 1, pageKeyInput: Array("\u{1b}[6~".utf8))
        )
    }

    func testModifiedUnnameableKeysKeepTheirXtermParameter() {
        XCTAssertEqual(route(.key(.home, [.shift])), .bytes(Array("\u{1b}[1;2H".utf8)))
    }

    func testWheelScrollGoesToAttachScroll() {
        XCTAssertEqual(
            route(.mouse(.scrollUp, column: 4, row: 9, [])),
            .scroll(up: true, lines: 1, pageKeyInput: nil)
        )
        XCTAssertEqual(
            route(.mouse(.scrollDown, column: 4, row: 9, [])),
            .scroll(up: false, lines: 1, pageKeyInput: nil)
        )
    }

    func testHorizontalScrollIsDropped() {
        // AttachScroll has only Up and Down (wire.rs:400). Mapping left/right
        // onto them would scroll the wrong axis.
        XCTAssertEqual(route(.mouse(.scrollLeft, column: 0, row: 0, [])), .drop)
        XCTAssertEqual(route(.mouse(.scrollRight, column: 0, row: 0, [])), .drop)
    }

    func testMouseButtonsAreDropped() {
        // Forwarding needs to know whether the pane's application asked for mouse
        // reporting, and that is unobservable from an attached connection:
        // MouseCapture is streamed only to full app clients (headless.rs:3681)
        // and no API method exposes terminal mode. Sending SGR unconditionally
        // would type escape sequences into a shell that never asked.
        XCTAssertEqual(route(.mouse(.down(.left), column: 1, row: 1, [])), .drop)
        XCTAssertEqual(route(.mouse(.up(.left), column: 1, row: 1, [])), .drop)
        XCTAssertEqual(route(.mouse(.drag(.left), column: 1, row: 1, [])), .drop)
        XCTAssertEqual(route(.mouse(.moved, column: 1, row: 1, [])), .drop)
    }

    func testFocusReportsAreDropped() {
        // There is no app connection to report window focus to, and a pane
        // connection rejects InputEvents by design.
        XCTAssertEqual(route(.focus(gained: true)), .drop)
        XCTAssertEqual(route(.focus(gained: false)), .drop)
    }

    func testEveryKeyRoutesSomewhere() {
        // No key may silently vanish: that failure mode is a dead keyboard with
        // nothing in the log.
        let keys: [WireEncoder.Key] = [
            .backspace, .enter, .left, .right, .up, .down, .home, .end,
            .pageUp, .pageDown, .tab, .backTab, .delete, .insert, .escape,
            .character("a"), .function(1),
        ]
        for key in keys {
            XCTAssertNotEqual(route(.key(key, [])), .drop, "\(key) went nowhere")
        }
    }
}
