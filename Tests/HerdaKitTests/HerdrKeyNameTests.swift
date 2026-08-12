import XCTest
@testable import HerdaKit

final class HerdrKeyNameTests: XCTestCase {
    private func name(
        _ key: WireEncoder.Key,
        _ modifiers: WireEncoder.Modifiers = []
    ) -> String? {
        HerdrKeyName.name(for: key, modifiers: modifiers)
    }

    func testNamesTheKeysHerdrAccepts() {
        // Measured against the running server: these are accepted, and the six
        // in testReturnsNilForKeysOutsideTheVocabulary are rejected with
        // "unsupported key".
        XCTAssertEqual(name(.enter), "enter")
        XCTAssertEqual(name(.escape), "esc")
        XCTAssertEqual(name(.backspace), "backspace")
        XCTAssertEqual(name(.tab), "tab")
        XCTAssertEqual(name(.left), "left")
        XCTAssertEqual(name(.right), "right")
        XCTAssertEqual(name(.up), "up")
        XCTAssertEqual(name(.down), "down")
        XCTAssertEqual(name(.function(5)), "f5")
        XCTAssertEqual(name(.function(12)), "f12")
        XCTAssertEqual(name(.character("a")), "a")
    }

    func testBackTabIsSpelledShiftTab() {
        // parse_key_combo has no "backtab": it produces BackTab from
        // "tab" + SHIFT, removing the shift bit as it does so
        // (config/keybinds.rs, the two "tab" arms).
        XCTAssertEqual(name(.backTab), "shift+tab")
    }

    func testBackTabDoesNotDoubleTheShiftPrefix() {
        // The shift bit is already spelled by the base name, so carrying it
        // again would emit "shift+shift+tab", which does not parse.
        XCTAssertEqual(name(.backTab, [.shift]), "shift+tab")
    }

    func testReturnsNilForKeysOutsideTheVocabulary() {
        // Measured: rejected as "unsupported key", including the spellings
        // page_up, pgup and del. Grepping keybinds.rs for these finds nothing —
        // it is not a spelling problem, the vocabulary lacks them.
        XCTAssertNil(name(.home))
        XCTAssertNil(name(.end))
        XCTAssertNil(name(.pageUp))
        XCTAssertNil(name(.pageDown))
        XCTAssertNil(name(.delete))
        XCTAssertNil(name(.insert))
    }

    func testPrefixesModifiersInACanonicalOrder() {
        XCTAssertEqual(name(.character("c"), [.control]), "ctrl+c")
        XCTAssertEqual(name(.character("b"), [.option]), "alt+b")
        XCTAssertEqual(name(.left, [.shift]), "shift+left")
        XCTAssertEqual(name(.character("k"), [.command]), "cmd+k")
        XCTAssertEqual(
            name(.character("x"), [.control, .shift, .option, .command]),
            "ctrl+shift+alt+cmd+x"
        )
    }

    func testUsesPunctuationNamesWhereACharacterWouldNotParse() {
        // parse_key_combo splits on "+", so a literal plus can never be a key
        // token: "ctrl++" splits into ["ctrl", "", ""] and the empty part makes
        // the whole combo fail. The named form is the only one that survives.
        XCTAssertEqual(name(.character("+"), [.control]), "ctrl+plus")
        XCTAssertEqual(name(.character(" ")), "space")
        XCTAssertEqual(name(.character("-")), "minus")
        XCTAssertEqual(name(.character(",")), "comma")
        XCTAssertEqual(name(.character(".")), "period")
        XCTAssertEqual(name(.character("/")), "slash")
        XCTAssertEqual(name(.character("\\")), "backslash")
        XCTAssertEqual(name(.character(";")), "semicolon")
        XCTAssertEqual(name(.character(":")), "colon")
        XCTAssertEqual(name(.character("'")), "quote")
        XCTAssertEqual(name(.character("\"")), "double_quote")
        XCTAssertEqual(name(.character("%")), "percent")
        XCTAssertEqual(name(.character("&")), "ampersand")
        XCTAssertEqual(name(.character("`")), "backtick")
    }

    func testPassesThroughCharactersWithNoSpecialName() {
        XCTAssertEqual(name(.character("=")), "=")
        XCTAssertEqual(name(.character("[")), "[")
    }
}
