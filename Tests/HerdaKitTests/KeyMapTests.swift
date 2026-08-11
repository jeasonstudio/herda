import AppKit
import XCTest
@testable import HerdaKit

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

    // MARK: - Composition

    /// Return, backspace, escape and the arrows all mean something to an input
    /// method mid-composition — commit, delete a syllable, cancel, page the
    /// candidate list. Consulting the special-key table first is what makes CJK
    /// input unusable: enter submits a half-finished line and backspace deletes
    /// pane content instead of the phrase being typed.
    func testCompositionClaimsTheKeysAnInputMethodNeeds() {
        let cases: [(UInt16, String?)] = [
            (36, "\r"),   // Return — commit
            (51, nil),    // Backspace — delete a syllable
            (53, nil),    // Escape — cancel
            (126, nil),   // Up — previous candidate page
            (125, nil),   // Down — next candidate page
            (123, nil),   // Left — move within the phrase
            (124, nil),   // Right
            (48, "\t"),   // Tab
        ]
        for (keyCode, characters) in cases {
            XCTAssertEqual(
                KeyMap.decide(
                    keyCode: keyCode,
                    charactersIgnoringModifiers: characters,
                    flags: [],
                    composing: true
                ),
                .inputMethod,
                "key code \(keyCode) must reach the input method while composing"
            )
        }
    }

    func testSameKeysGoToThePaneWhenNotComposing() {
        XCTAssertEqual(
            KeyMap.decide(keyCode: 36, charactersIgnoringModifiers: "\r", flags: [], composing: false),
            .send(.enter, [])
        )
        XCTAssertEqual(
            KeyMap.decide(keyCode: 51, charactersIgnoringModifiers: nil, flags: [], composing: false),
            .send(.backspace, [])
        )
    }

    /// A phrase half typed must not stop ctrl+c from interrupting a process.
    func testControlStillBypassesTheInputMethodWhileComposing() {
        XCTAssertEqual(
            KeyMap.decide(
                keyCode: 8,
                charactersIgnoringModifiers: "c",
                flags: .control,
                composing: true
            ),
            .send(.character("c"), [.control])
        )
    }

    func testCommandStillBypassesTheInputMethodWhileComposing() {
        XCTAssertEqual(
            KeyMap.decide(
                keyCode: 8,
                charactersIgnoringModifiers: "c",
                flags: .command,
                composing: true
            ),
            .send(.character("c"), [.command])
        )
    }

    func testCompositionDefaultsToOff() {
        XCTAssertEqual(
            KeyMap.decide(keyCode: 36, charactersIgnoringModifiers: "\r", flags: []),
            .send(.enter, [])
        )
    }

    /// An input method often answers a key by turning it into one of these and
    /// reporting success, so the translation back is what keeps the key alive.
    func testStandardEditingCommandsMapBackToWireKeys() {
        XCTAssertEqual(
            KeyMap.key(forCommand: #selector(NSStandardKeyBindingResponding.insertNewline(_:))),
            .enter
        )
        XCTAssertEqual(
            KeyMap.key(forCommand: #selector(NSStandardKeyBindingResponding.deleteBackward(_:))),
            .backspace
        )
        XCTAssertEqual(
            KeyMap.key(forCommand: #selector(NSStandardKeyBindingResponding.deleteForward(_:))),
            .delete
        )
        XCTAssertEqual(KeyMap.key(forCommand: #selector(NSResponder.cancelOperation(_:))), .escape)
        XCTAssertEqual(KeyMap.key(forCommand: #selector(NSStandardKeyBindingResponding.insertTab(_:))), .tab)
        XCTAssertEqual(KeyMap.key(forCommand: #selector(NSStandardKeyBindingResponding.moveUp(_:))), .up)
        XCTAssertEqual(
            KeyMap.key(forCommand: #selector(NSStandardKeyBindingResponding.moveToEndOfLine(_:))),
            .end
        )
    }

    /// Commands with no terminal equivalent must stay unmapped so the view can
    /// swallow them instead of sending something wrong.
    func testUnrelatedCommandsHaveNoWireKey() {
        XCTAssertNil(KeyMap.key(forCommand: #selector(NSStandardKeyBindingResponding.selectAll(_:))))
        XCTAssertNil(KeyMap.key(forCommand: #selector(NSStandardKeyBindingResponding.centerSelectionInVisibleArea(_:))))
    }

    func testCandidateSelectionDigitsReachTheInputMethod() {
        XCTAssertEqual(
            KeyMap.decide(keyCode: 18, charactersIgnoringModifiers: "1", flags: [], composing: true),
            .inputMethod
        )
        XCTAssertEqual(
            KeyMap.decide(keyCode: 49, charactersIgnoringModifiers: " ", flags: [], composing: true),
            .inputMethod
        )
    }
}
