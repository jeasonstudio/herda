import Foundation

/// Renders a key press as a herdr API key name for `pane.send_keys`.
///
/// The inverse of herdr's `config::parse_key_combo` (`config/keybinds.rs:1201`),
/// which is what `pane.send_keys` runs each name through
/// (`app/api_helpers.rs:11`). Only names that parser accepts are produced;
/// anything else returns nil so the caller falls back to raw CSI bytes.
///
/// Preferring this channel over raw bytes is the whole reason per-pane
/// connections became viable: herdr encodes each name with that terminal's own
/// modes, so application cursor mode and bracketed paste — neither of which a
/// client can observe — stay on the side that knows them.
public enum HerdrKeyName {
    /// Characters herdr names rather than accepting literally.
    ///
    /// `+` is the load-bearing entry: `parse_key_combo` splits the combo on
    /// `+`, so "ctrl++" becomes `["ctrl", "", ""]` and the empty component
    /// fails the whole parse. The rest are included because herdr names them
    /// and a name survives a log file better than a bare glyph.
    private static let punctuationNames: [Character: String] = [
        " ": "space", "-": "minus", ",": "comma", ".": "period",
        "/": "slash", "\\": "backslash", "'": "quote", "\"": "double_quote",
        ";": "semicolon", ":": "colon", "%": "percent", "&": "ampersand",
        "`": "backtick", "+": "plus",
    ]

    /// The name for a key, or nil when herdr's vocabulary cannot express it.
    ///
    /// Measured against a running server: home, end, pageup, pagedown, delete
    /// and insert are rejected with `unsupported key` in every spelling tried
    /// (`page_up`, `pgup`, `del` included), and grepping `keybinds.rs` for them
    /// finds nothing — the vocabulary lacks them, it is not a spelling problem.
    /// Those six go through `TerminalKeyBytes` instead.
    public static func name(
        for key: WireEncoder.Key,
        modifiers: WireEncoder.Modifiers
    ) -> String? {
        guard let base = baseName(for: key) else { return nil }

        var modifiers = modifiers
        // BackTab has no name of its own: herdr derives it from "tab" + SHIFT
        // and strips the shift bit while doing so. The base name already spells
        // that shift, so carrying it again would emit "shift+shift+tab", which
        // does not parse.
        if case .backTab = key { modifiers.remove(.shift) }

        // Fixed order, so the same chord always reads the same in a log.
        // herdr's parser itself is order-insensitive.
        var prefix = ""
        if modifiers.contains(.control) { prefix += "ctrl+" }
        if modifiers.contains(.shift) { prefix += "shift+" }
        if modifiers.contains(.option) { prefix += "alt+" }
        if modifiers.contains(.command) { prefix += "cmd+" }
        return prefix + base
    }

    private static func baseName(for key: WireEncoder.Key) -> String? {
        switch key {
        case .enter: return "enter"
        case .escape: return "esc"
        case .backspace: return "backspace"
        case .tab: return "tab"
        case .backTab: return "shift+tab"
        case .left: return "left"
        case .right: return "right"
        case .up: return "up"
        case .down: return "down"
        case .function(let number): return "f\(number)"
        case .character(let character):
            return punctuationNames[character] ?? String(character)
        // Not in herdr's vocabulary — see the doc comment on `name(for:)`.
        case .home, .end, .pageUp, .pageDown, .delete, .insert:
            return nil
        }
    }
}
