import Foundation

/// Decides which channel each piece of input travels on.
///
/// Pure, because this is the part that is easy to get subtly wrong and impossible
/// to debug from the outside: input that goes down the wrong channel either
/// vanishes, arrives as literal escape text, or — in the case of `InputEvents` on
/// a pane connection — silently resizes every pane in the session.
///
/// Three destinations, none of them `InputEvents`:
///
/// | Input | Channel |
/// |---|---|
/// | text, and keys herdr can name | the API, `pane.send_text` / `pane.send_keys` |
/// | Home, End, Delete, Insert | the pane connection, raw `Input` |
/// | PageUp, PageDown, wheel | the pane connection, `AttachScroll` |
public enum PaneInputRouter {
    public enum Route: Equatable, Sendable {
        /// `pane.send_keys` with herdr's key names.
        case keys([String])
        /// `pane.send_text`, which herdr wraps for bracketed paste when the pane
        /// has it enabled.
        case text(String)
        /// Raw `Input` on the pane's own connection.
        case bytes([UInt8])
        /// `AttachScroll`. `pageKeyInput` carries the original key bytes when the
        /// child application owns the page keys.
        case scroll(up: Bool, lines: UInt16, pageKeyInput: [UInt8]?)
        case drop
    }

    public static func route(_ input: TerminalInput) -> Route {
        switch input {
        case .text(let value, _):
            return .text(value)

        case .key(let key, let modifiers):
            return routeKey(key, modifiers)

        case .mouse(let kind, _, _, _):
            switch kind {
            case .scrollUp: return .scroll(up: true, lines: 1, pageKeyInput: nil)
            case .scrollDown: return .scroll(up: false, lines: 1, pageKeyInput: nil)
            // AttachScroll carries only Up and Down (`wire.rs:400`); mapping the
            // horizontal wheel onto them would scroll the wrong axis.
            case .scrollLeft, .scrollRight: return .drop
            // Forwarding a button needs to know whether the pane's application
            // asked for mouse reporting, and that is unobservable here:
            // MouseCapture reaches only full app clients (`headless.rs:3681`) and
            // no API method exposes terminal mode. Sending SGR unconditionally
            // would type escape sequences into a shell that never asked for them.
            case .down, .up, .drag, .moved: return .drop
            }

        // Nothing to report window focus to without an app connection.
        case .focus:
            return .drop
        }
    }

    private static func routeKey(
        _ key: WireEncoder.Key,
        _ modifiers: WireEncoder.Modifiers
    ) -> Route {
        // The page keys have their own channel, which has to be checked before
        // the byte fallback: AttachScroll lets the server decide per pane whether
        // the key moves host scrollback or goes to the child application, and raw
        // bytes would take that decision away from it.
        switch key {
        case .pageUp, .pageDown:
            guard let bytes = TerminalKeyBytes.csi(for: key, modifiers: modifiers) else {
                return .drop
            }
            return .scroll(up: key == .pageUp, lines: 1, pageKeyInput: bytes)
        default:
            break
        }

        if let name = HerdrKeyName.name(for: key, modifiers: modifiers) {
            return .keys([name])
        }
        if let bytes = TerminalKeyBytes.csi(for: key, modifiers: modifiers) {
            return .bytes(bytes)
        }
        return .drop
    }
}
