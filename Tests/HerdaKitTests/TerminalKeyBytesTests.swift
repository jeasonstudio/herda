import XCTest
@testable import HerdaKit

final class TerminalKeyBytesTests: XCTestCase {
    private func text(
        _ key: WireEncoder.Key,
        _ modifiers: WireEncoder.Modifiers = []
    ) -> String? {
        TerminalKeyBytes.csi(for: key, modifiers: modifiers)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    func testEncodesTheTildeKeys() {
        XCTAssertEqual(text(.insert), "\u{1b}[2~")
        XCTAssertEqual(text(.delete), "\u{1b}[3~")
        XCTAssertEqual(text(.pageUp), "\u{1b}[5~")
        XCTAssertEqual(text(.pageDown), "\u{1b}[6~")
    }

    func testEncodesHomeAndEndAsSS3() {
        // Measured, not chosen. Through a real pane connection into zsh's line
        // editor: ESC[H was ignored and the marker landed at the end of the line,
        // ESC OH moved to the start. SS3 is the application-cursor-mode form and
        // a shell running its line editor has that mode on, which is where Home
        // actually gets pressed. The mode is unobservable from an attached
        // connection, so one form has to be picked.
        XCTAssertEqual(text(.home), "\u{1b}OH")
        XCTAssertEqual(text(.end), "\u{1b}OF")
    }

    func testEncodesModifiersInTheXtermParameterForm() {
        // xterm's modifier parameter is 1 + shift(1) + alt(2) + ctrl(4).
        XCTAssertEqual(text(.delete, [.shift]), "\u{1b}[3;2~")
        XCTAssertEqual(text(.pageUp, [.control]), "\u{1b}[5;5~")
        XCTAssertEqual(text(.pageDown, [.option]), "\u{1b}[6;3~")
        XCTAssertEqual(text(.insert, [.control, .shift, .option]), "\u{1b}[2;8~")
    }

    func testModifiedHomeAndEndTakeALeadingParameter() {
        // A parameter list needs a first element for the modifier to be second,
        // so the unmodified ESC[H grows a 1 rather than becoming ESC[;2H.
        XCTAssertEqual(text(.home, [.shift]), "\u{1b}[1;2H")
        XCTAssertEqual(text(.end, [.control, .shift]), "\u{1b}[1;6F")
    }

    func testCommandIsNotAnXtermModifier() {
        // xterm has no bit for cmd, and a macOS cmd chord is an application
        // shortcut rather than terminal input. Dropping it is deliberate: the
        // alternative is inventing a parameter no terminal reads.
        XCTAssertEqual(text(.home, [.command]), "\u{1b}OH")
        XCTAssertEqual(text(.delete, [.command]), "\u{1b}[3~")
    }

    func testReturnsNilForKeysHerdrCanName() {
        // These must go through pane.send_keys so herdr encodes them with the
        // terminal's own modes. Returning bytes here would bypass that.
        XCTAssertNil(TerminalKeyBytes.csi(for: .enter, modifiers: []))
        XCTAssertNil(TerminalKeyBytes.csi(for: .left, modifiers: []))
        XCTAssertNil(TerminalKeyBytes.csi(for: .character("a"), modifiers: []))
        XCTAssertNil(TerminalKeyBytes.csi(for: .function(5), modifiers: []))
    }

    func testEveryKeyIsCoveredByExactlyOneChannel() {
        // The invariant both types exist to satisfy: no key may fall through
        // both channels, and none may be claimed by both.
        let keys: [WireEncoder.Key] = [
            .backspace, .enter, .left, .right, .up, .down, .home, .end,
            .pageUp, .pageDown, .tab, .backTab, .delete, .insert, .escape,
            .character("a"), .function(1),
        ]
        for key in keys {
            let named = HerdrKeyName.name(for: key, modifiers: []) != nil
            let raw = TerminalKeyBytes.csi(for: key, modifiers: []) != nil
            XCTAssertTrue(named != raw, "\(key) must be in exactly one channel")
        }
    }
}
