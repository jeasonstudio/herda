import XCTest
@testable import HerdaKit

/// Checks the input channel against herdr itself, not against a reading of it.
///
/// `HerdrKeyName` encodes a claim about another program's parser; these tests put
/// that claim to the parser. Skipped when no embedded server is running, so a
/// clean checkout and CI stay green.
///
/// Every case creates and closes its own pane. An earlier measurement ran
/// against a live pane and left 200 stray `~` on the prompt, because zsh splits
/// `ESC[15~` into an unknown sequence plus a literal tilde.
final class LivePaneInputTests: XCTestCase {
    private func liveApi() throws -> ApiClient {
        let paths = RuntimePaths.defaultLocation()
        guard FileManager.default.fileExists(atPath: paths.apiSocket.path) else {
            throw XCTSkip("no embedded server running; start it with Scripts/run.sh")
        }
        return ApiClient(socketPath: paths.apiSocket.path)
    }

    /// A pane of its own, so nothing lands in whatever the user is doing.
    private func scratchPane(_ api: ApiClient) throws -> String {
        try api.request(
            PaneInfoEnvelope.self,
            method: "pane.split",
            params: ["direction": "down", "focus": false],
            id: "scratch"
        ).pane.paneId
    }

    func testEveryNameHerdrKeyNameProducesIsAccepted() throws {
        let api = try liveApi()
        let pane = try scratchPane(api)
        defer { try? api.closePane(pane) }

        let keys: [WireEncoder.Key] = [
            .enter, .escape, .backspace, .tab, .backTab,
            .left, .right, .up, .down, .function(5),
            .character("a"), .character("+"), .character(" "), .character("/"),
            .character("="), .character("%"),
        ]
        let modifierSets: [WireEncoder.Modifiers] = [[], [.control], [.shift], [.option]]

        for key in keys {
            for modifiers in modifierSets {
                guard let name = HerdrKeyName.name(for: key, modifiers: modifiers) else {
                    continue
                }
                XCTAssertNoThrow(
                    try api.sendKeys(pane, keys: [name]),
                    "herdr rejected the name \(name) for \(key) + \(modifiers.rawValue)"
                )
            }
        }
    }

    func testTheSixUnnameableKeysAreStillUnnameable() throws {
        // Guards against a herdr upgrade silently adding them: if this starts
        // failing, the raw-bytes fallback in TerminalKeyBytes can be dropped.
        let api = try liveApi()
        let pane = try scratchPane(api)
        defer { try? api.closePane(pane) }

        for name in ["home", "end", "pageup", "pagedown", "delete", "insert"] {
            XCTAssertThrowsError(
                try api.sendKeys(pane, keys: [name]),
                "herdr now accepts \(name) — drop it from TerminalKeyBytes"
            )
        }
    }

    func testSerializedSendsArriveInOrder() throws {
        // Ordering is the reason PaneInputQueue exists, and this is the only
        // place it is checked against the real server rather than a fake.
        let api = try liveApi()
        let pane = try scratchPane(api)
        defer { try? api.closePane(pane) }

        // A leading comment marker so whatever accumulates stays on one line and
        // is never executed, whichever shell the pane is running.
        try api.sendText(pane, text: "# ")
        let expected = (0 ..< 60).map { String($0 % 10) }
        let queue = PaneInputQueue()
        for digit in expected {
            queue.submit(digit) { try api.sendText(pane, text: digit) }
        }

        let drained = expectation(description: "queue drained")
        Task { await queue.drain(); drained.fulfill() }
        wait(for: [drained], timeout: 10)

        // Let the PTY render before reading it back.
        Thread.sleep(forTimeInterval: 0.5)
        // `source` has no default in herdr's schema (api/schema/panes.rs:254), so
        // omitting it fails the request. `format` defaults to text.
        //
        // `recent_unwrapped` rather than `visible`: the scratch pane is only as
        // wide as the window makes it, and with `visible` a 62-character line
        // wraps and the joined digits no longer appear as one substring. That
        // made this test pass or fail on window size, which has nothing to do
        // with ordering.
        let text = try api.request(
            method: "pane.read",
            params: ["pane_id": pane, "source": "recent_unwrapped", "format": "text"],
            id: "read"
        )
        XCTAssertTrue(
            text.contains("# " + expected.joined()),
            "digits arrived out of order or were dropped:\n\(text)"
        )
    }
}
