import XCTest
@testable import HerdaKit

final class TerminalInputTests: XCTestCase {
    func testKeyIntentEncodesToTheSameBytesAsBefore() {
        // The refactor must not change a single byte on the app connection.
        // These are the payloads TerminalGridView used to build inline.
        XCTAssertEqual(
            TerminalInput.key(.enter, []).appInputEventsPayload(),
            WireEncoder.key(.enter, modifiers: [])
        )
        XCTAssertEqual(
            TerminalInput.key(.character("c"), [.control]).appInputEventsPayload(),
            WireEncoder.key(.character("c"), modifiers: [.control])
        )
        XCTAssertEqual(
            TerminalInput.key(.function(5), [.shift, .option]).appInputEventsPayload(),
            WireEncoder.key(.function(5), modifiers: [.shift, .option])
        )
    }

    func testTextIntentDistinguishesPasteFromCommit() {
        // Both carry a String on the wire, but they are different variants and
        // herdr treats a paste as a bracketed block.
        XCTAssertEqual(
            TerminalInput.text("hi", kind: .commit).appInputEventsPayload(),
            WireEncoder.textCommit("hi")
        )
        XCTAssertEqual(
            TerminalInput.text("hi", kind: .paste).appInputEventsPayload(),
            WireEncoder.paste("hi")
        )
        XCTAssertNotEqual(
            TerminalInput.text("hi", kind: .commit).appInputEventsPayload(),
            TerminalInput.text("hi", kind: .paste).appInputEventsPayload(),
            "the two text kinds are different wire variants"
        )
    }

    func testMouseAndFocusIntentsEncodeUnchanged() {
        XCTAssertEqual(
            TerminalInput.mouse(.down(.left), column: 4, row: 9, []).appInputEventsPayload(),
            WireEncoder.mouse(.down(.left), column: 4, row: 9, modifiers: [])
        )
        XCTAssertEqual(
            TerminalInput.mouse(.scrollUp, column: 0, row: 0, [.shift])
                .appInputEventsPayload(),
            WireEncoder.mouse(.scrollUp, column: 0, row: 0, modifiers: [.shift])
        )
        XCTAssertEqual(
            TerminalInput.focus(gained: true).appInputEventsPayload(),
            WireEncoder.focus(gained: true)
        )
        XCTAssertEqual(
            TerminalInput.focus(gained: false).appInputEventsPayload(),
            WireEncoder.focus(gained: false)
        )
    }

    func testCarriesEnoughToRouteToEitherChannel() {
        // The point of the type: a key intent has to survive long enough for the
        // session to ask HerdrKeyName and TerminalKeyBytes which channel it
        // belongs to. Encoded bytes would have thrown that away.
        guard case .key(let key, let modifiers) =
            TerminalInput.key(.home, [.shift])
        else { return XCTFail("expected a key intent") }

        XCTAssertNil(HerdrKeyName.name(for: key, modifiers: modifiers))
        XCTAssertEqual(
            TerminalKeyBytes.csi(for: key, modifiers: modifiers)
                .map { String(decoding: $0, as: UTF8.self) },
            "\u{1b}[1;2H"
        )
    }
}
