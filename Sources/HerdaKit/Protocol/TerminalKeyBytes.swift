import Foundation

/// CSI byte sequences for the keys herdr's API vocabulary cannot name.
///
/// `pane.send_keys` is the right channel for everything it can express, because
/// herdr encodes there with the terminal's own modes. These six keys are not in
/// `config::parse_key_combo` — measured against a running server, they come back
/// as `unsupported key` — so they go out as raw bytes on the pane's own
/// connection, where `apply_terminal_attach_input` hands them straight to the
/// PTY without re-encoding (`headless.rs:403`).
///
/// See `HerdrKeyName` for the other half; a test pins that every key belongs to
/// exactly one of the two.
public enum TerminalKeyBytes {
    /// The bytes for a key, or nil when `HerdrKeyName` can name it.
    public static func csi(
        for key: WireEncoder.Key,
        modifiers: WireEncoder.Modifiers
    ) -> [UInt8]? {
        switch key {
        case .insert: return tilde(2, modifiers)
        case .delete: return tilde(3, modifiers)
        case .pageUp: return tilde(5, modifiers)
        case .pageDown: return tilde(6, modifiers)
        case .home: return cursor("H", modifiers)
        case .end: return cursor("F", modifiers)
        default: return nil
        }
    }


    /// `ESC [ n ~`, or `ESC [ n ; m ~` when modified.
    private static func tilde(_ number: Int, _ modifiers: WireEncoder.Modifiers) -> [UInt8] {
        guard let parameter = xtermParameter(modifiers) else {
            return Array("\u{1b}[\(number)~".utf8)
        }
        return Array("\u{1b}[\(number);\(parameter)~".utf8)
    }

    /// `ESC O X` unmodified, `ESC [ 1 ; m X` when modified.
    ///
    /// The unmodified form is SS3, not CSI, and that was measured rather than
    /// chosen. Through a real pane connection into zsh's line editor — type
    /// `echo abc`, send the sequence, type a marker:
    ///
    /// | sequence | result |
    /// |---|---|
    /// | `ESC [ H` | `echo abcA` — ignored, the marker landed at the end |
    /// | `ESC O H` | `Becho abc` — honoured, the marker landed at the start |
    ///
    /// SS3 is the application-cursor-mode form, and a shell running its line
    /// editor has that mode on. A client attached to one pane cannot observe the
    /// mode, so one form has to be picked, and this is the one that works where
    /// Home is actually pressed. An application that never enables DECCKM and
    /// wants the CSI form will not see it — closing that properly means herdr's
    /// `parse_key_combo` gaining these six names, after which this whole file can
    /// go away.
    ///
    /// Modified keys stay CSI because SS3 has no parameter form. The leading 1
    /// exists only so the modifier has a second slot to sit in; `ESC [ ; m X` is
    /// a different sequence.
    private static func cursor(_ final: String, _ modifiers: WireEncoder.Modifiers) -> [UInt8] {
        guard let parameter = xtermParameter(modifiers) else {
            return Array("\u{1b}O\(final)".utf8)
        }
        return Array("\u{1b}[1;\(parameter)\(final)".utf8)
    }

    /// xterm's modifier parameter: 1 + shift(1) + alt(2) + ctrl(4). nil when no
    /// modifier applies, so the unmodified form stays short.
    ///
    /// cmd is dropped rather than encoded: xterm has no bit for it, and a macOS
    /// cmd chord is an application shortcut rather than terminal input. The
    /// alternative would be inventing a parameter no terminal reads.
    private static func xtermParameter(_ modifiers: WireEncoder.Modifiers) -> Int? {
        var bits = 0
        if modifiers.contains(.shift) { bits += 1 }
        if modifiers.contains(.option) { bits += 2 }
        if modifiers.contains(.control) { bits += 4 }
        return bits == 0 ? nil : bits + 1
    }
}
