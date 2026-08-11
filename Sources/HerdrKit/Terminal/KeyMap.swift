import AppKit

/// Translates AppKit key events into wire keys, and decides which events must
/// bypass the input method.
///
/// A terminal cannot route everything through the IME: ctrl+c has to reach the
/// pane as a key press, not as composed text. Conversely plain letters must go
/// through the IME, or CJK composition never happens.
public enum KeyMap {
    public enum Decision: Equatable {
        /// Encode and send immediately.
        case send(WireEncoder.Key, WireEncoder.Modifiers)
        /// Hand to `NSTextInputContext`; expect `insertText`/`setMarkedText`.
        case inputMethod
        /// Nothing meaningful to send.
        case ignore
    }

    public static func modifiers(from flags: NSEvent.ModifierFlags) -> WireEncoder.Modifiers {
        var result: WireEncoder.Modifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }

    /// Virtual key codes are layout-independent, so this mapping holds across
    /// keyboard layouts where `characters` would not.
    public static func specialKey(forKeyCode keyCode: UInt16) -> WireEncoder.Key? {
        switch keyCode {
        case 36, 76: return .enter
        case 48: return .tab
        case 51: return .backspace
        case 117: return .delete
        case 53: return .escape
        case 123: return .left
        case 124: return .right
        case 126: return .up
        case 125: return .down
        case 115: return .home
        case 119: return .end
        case 116: return .pageUp
        case 121: return .pageDown
        case 122: return .function(1)
        case 120: return .function(2)
        case 99: return .function(3)
        case 118: return .function(4)
        case 96: return .function(5)
        case 97: return .function(6)
        case 98: return .function(7)
        case 100: return .function(8)
        case 101: return .function(9)
        case 109: return .function(10)
        case 103: return .function(11)
        case 111: return .function(12)
        default: return nil
        }
    }

    /// `composing` is whether the input method currently holds marked text.
    ///
    /// It has to be consulted before the special-key table, not after. Return,
    /// backspace, escape and the arrows all mean something to an input method
    /// mid-composition — commit, delete a syllable, cancel, page the candidate
    /// list — and sending them straight to the pane instead is what makes CJK
    /// input unusable: enter submits a half-finished line, backspace deletes
    /// pane content rather than the phrase being typed.
    ///
    /// ctrl and cmd still bypass composition. ctrl+c has to be able to interrupt
    /// a runaway process even with a phrase half typed.
    /// The wire key a standard AppKit editing command stands for.
    ///
    /// An input method does not always answer a key by composing or by declining
    /// it. Frequently it "handles" it by translating it into one of these
    /// commands and reporting success — return becomes `insertNewline:`,
    /// backspace becomes `deleteBackward:`. A terminal that only watches
    /// `handleEvent`'s return value therefore loses those keys entirely.
    ///
    /// Modifiers are not represented: `doCommand(by:)` does not carry them, and
    /// the modified variants are separate selectors that a pane has no key for.
    public static func key(forCommand selector: Selector) -> WireEncoder.Key? {
        commands[selector]
    }

    private static let commands: [Selector: WireEncoder.Key] = [
        #selector(NSStandardKeyBindingResponding.insertNewline(_:)): .enter,
        #selector(NSStandardKeyBindingResponding.insertLineBreak(_:)): .enter,
        #selector(NSStandardKeyBindingResponding.insertTab(_:)): .tab,
        #selector(NSStandardKeyBindingResponding.insertBacktab(_:)): .backTab,
        #selector(NSStandardKeyBindingResponding.deleteBackward(_:)): .backspace,
        #selector(NSStandardKeyBindingResponding.deleteForward(_:)): .delete,
        #selector(NSResponder.cancelOperation(_:)): .escape,
        #selector(NSStandardKeyBindingResponding.moveLeft(_:)): .left,
        #selector(NSStandardKeyBindingResponding.moveRight(_:)): .right,
        #selector(NSStandardKeyBindingResponding.moveUp(_:)): .up,
        #selector(NSStandardKeyBindingResponding.moveDown(_:)): .down,
        #selector(NSStandardKeyBindingResponding.moveToBeginningOfLine(_:)): .home,
        #selector(NSStandardKeyBindingResponding.moveToEndOfLine(_:)): .end,
        #selector(NSStandardKeyBindingResponding.scrollPageUp(_:)): .pageUp,
        #selector(NSStandardKeyBindingResponding.scrollPageDown(_:)): .pageDown,
    ]

    public static func decide(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        flags: NSEvent.ModifierFlags,
        composing: Bool = false
    ) -> Decision {
        let mods = modifiers(from: flags)
        let isCommandLike = flags.contains(.control) || flags.contains(.command)

        if composing, !isCommandLike {
            return .inputMethod
        }

        if let special = specialKey(forKeyCode: keyCode) {
            return .send(special, mods)
        }

        // ctrl and cmd combinations are commands, never composable text.
        if isCommandLike,
           let characters = charactersIgnoringModifiers,
           let character = characters.first
        {
            return .send(.character(character), mods)
        }

        if charactersIgnoringModifiers?.isEmpty == false {
            return .inputMethod
        }
        return .ignore
    }
}
