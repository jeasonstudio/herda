import AppKit
import XCTest
@testable import HerdrKit

final class KeyMapTests: XCTestCase {
    func testTranslatesModifierFlags() {
        XCTAssertEqual(KeyMap.modifiers(from: []), [])
        XCTAssertEqual(KeyMap.modifiers(from: .shift), .shift)
        XCTAssertEqual(KeyMap.modifiers(from: .control), .control)
        XCTAssertEqual(KeyMap.modifiers(from: .option), .option)
        XCTAssertEqual(KeyMap.modifiers(from: .command), .command)
        XCTAssertEqual(
            KeyMap.modifiers(from: [.control, .option]),
            [.control, .option]
        )
    }

    func testIgnoresNonInputModifierFlags() {
        // capsLock, numericPad, function etc. have no wire representation.
        XCTAssertEqual(KeyMap.modifiers(from: [.capsLock, .numericPad, .control]), .control)
    }

    func testMapsSpecialKeyCodes() {
        XCTAssertEqual(KeyMap.specialKey(forKeyCode: 36), .enter)        // Return
        XCTAssertEqual(KeyMap.specialKey(forKeyCode: 76), .enter)        // Keypad Enter
        XCTAssertEqual(KeyMap.specialKey(forKeyCode: 48), .tab)
        XCTAssertEqual(KeyMap.specialKey(forKeyCode: 51), .backspace)    // Delete key
        XCTAssertEqual(KeyMap.specialKey(forKeyCode: 117), .delete)      // Forward delete
        XCTAssertEqual(KeyMap.specialKey(forKeyCode: 53), .escape)
        XCTAssertEqual(KeyMap.specialKey(forKeyCode: 123), .left)
        XCTAssertEqual(KeyMap.specialKey(forKeyCode: 124), .right)
        XCTAssertEqual(KeyMap.specialKey(forKeyCode: 126), .up)
        XCTAssertEqual(KeyMap.specialKey(forKeyCode: 125), .down)
        XCTAssertEqual(KeyMap.specialKey(forKeyCode: 115), .home)
        XCTAssertEqual(KeyMap.specialKey(forKeyCode: 119), .end)
        XCTAssertEqual(KeyMap.specialKey(forKeyCode: 116), .pageUp)
        XCTAssertEqual(KeyMap.specialKey(forKeyCode: 121), .pageDown)
    }

    func testMapsFunctionKeyCodes() {
        XCTAssertEqual(KeyMap.specialKey(forKeyCode: 122), .function(1))
        XCTAssertEqual(KeyMap.specialKey(forKeyCode: 120), .function(2))
        XCTAssertEqual(KeyMap.specialKey(forKeyCode: 111), .function(12))
    }

    func testReturnsNilForOrdinaryLetters() {
        XCTAssertNil(KeyMap.specialKey(forKeyCode: 0))   // 'a'
        XCTAssertNil(KeyMap.specialKey(forKeyCode: 8))   // 'c'
    }

    func testControlledLetterBypassesInputMethod() {
        // ctrl+c must reach the pane as Char('c') + CONTROL, not as text.
        let decision = KeyMap.decide(
            keyCode: 8,
            charactersIgnoringModifiers: "c",
            flags: .control
        )
        XCTAssertEqual(decision, .send(.character("c"), [.control]))
    }

    func testCommandedLetterBypassesInputMethod() {
        let decision = KeyMap.decide(
            keyCode: 8,
            charactersIgnoringModifiers: "c",
            flags: .command
        )
        XCTAssertEqual(decision, .send(.character("c"), [.command]))
    }

    func testSpecialKeyBypassesInputMethodEvenWithoutModifiers() {
        XCTAssertEqual(
            KeyMap.decide(keyCode: 36, charactersIgnoringModifiers: "\r", flags: []),
            .send(.enter, [])
        )
        XCTAssertEqual(
            KeyMap.decide(keyCode: 126, charactersIgnoringModifiers: nil, flags: []),
            .send(.up, [])
        )
    }

    func testSpecialKeyKeepsItsModifiers() {
        XCTAssertEqual(
            KeyMap.decide(keyCode: 126, charactersIgnoringModifiers: nil, flags: .shift),
            .send(.up, .shift)
        )
    }

    func testPlainLetterGoesToInputMethod() {
        // Must not be sent directly: the input method may compose it.
        XCTAssertEqual(
            KeyMap.decide(keyCode: 0, charactersIgnoringModifiers: "a", flags: []),
            .inputMethod
        )
    }

    func testOptionedLetterGoesToInputMethod() {
        // option+e is a dead key on many layouts; let the IME own it.
        XCTAssertEqual(
            KeyMap.decide(keyCode: 14, charactersIgnoringModifiers: "e", flags: .option),
            .inputMethod
        )
    }

    func testShiftedLetterGoesToInputMethod() {
        XCTAssertEqual(
            KeyMap.decide(keyCode: 0, charactersIgnoringModifiers: "a", flags: .shift),
            .inputMethod
        )
    }

    func testUnknownKeyWithoutCharactersIsDropped() {
        XCTAssertEqual(
            KeyMap.decide(keyCode: 999, charactersIgnoringModifiers: nil, flags: []),
            .ignore
        )
    }
}
