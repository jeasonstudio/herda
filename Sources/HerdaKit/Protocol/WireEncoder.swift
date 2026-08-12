import Foundation

/// Encodes the `ClientMessage` variants this prototype sends.
public enum WireEncoder {
    private enum Variant: UInt64 {
        case hello = 0
        case input = 1
        case resize = 3
        case detach = 4
        case attachScroll = 6
        case inputEvents = 7
        case controlTerminal = 9
    }

    private enum RenderEncoding: UInt64 {
        case semanticFrame = 0
    }

    private enum Keybindings: UInt64 {
        case server = 0
    }

    /// Mirrors `ClientLaunchMode` (`wire.rs:57`).
    ///
    /// `terminalAttach` does not attach on its own: it sets the server's
    /// `pending_terminal_attach` flag (`client_transport.rs:566`) while the mode
    /// stays `App`, which is exactly what `client_is_pending_terminal_mode`
    /// requires before it will accept a `ControlTerminal`
    /// (`headless.rs:2672`). It also keeps the connection out of
    /// `is_full_app_client` (`clients.rs:176`), so it never becomes foreground
    /// and never drives `effective_size`.
    public enum LaunchMode: UInt64, Sendable {
        case app = 0
        case terminalAttach = 1
    }

    public static func hello(
        columns: UInt16,
        rows: UInt16,
        cellWidth: UInt32,
        cellHeight: UInt32,
        launchMode: LaunchMode = .app
    ) -> [UInt8] {
        var out = Varint.encode(Variant.hello.rawValue)
        out += Varint.encode(UInt64(HerdaKit.protocolVersion))
        out += Varint.encode(UInt64(columns))
        out += Varint.encode(UInt64(rows))
        out += Varint.encode(UInt64(cellWidth))
        out += Varint.encode(UInt64(cellHeight))
        out += Varint.encode(RenderEncoding.semanticFrame.rawValue)
        out += Varint.encode(Keybindings.server.rawValue)
        out += Varint.encode(launchMode.rawValue)
        return out
    }

    /// Switches a pending-attach connection into writable control of one pane.
    ///
    /// `target` accepts a pane id: `resolve_terminal_target_id_string`
    /// (`headless.rs:1666`) falls through to `app.resolve_terminal_target`, and
    /// herdr's own test asserts a pane id resolves (`app/mod.rs:4191`).
    ///
    /// `takeover` matters because one terminal allows a single writable owner
    /// (`terminal_attach_owners`). A previous instance killed with SIGKILL never
    /// sent `Detach`, so its ownership can outlive it and lock the pane out.
    public static func controlTerminal(target: String, takeover: Bool) -> [UInt8] {
        var out = Varint.encode(Variant.controlTerminal.rawValue)
        out += string(target)
        out.append(takeover ? 1 : 0)
        return out
    }

    /// Raw bytes straight to the pane's PTY.
    ///
    /// On an attached connection `apply_terminal_attach_input` passes these
    /// through unchanged (`headless.rs:403`) — no re-encoding, no keybinding
    /// layer. Used only for what `pane.send_keys` cannot name: Home, End,
    /// Delete and Insert. See `TerminalKeyBytes`.
    public static func input(_ bytes: [UInt8]) -> [UInt8] {
        var out = Varint.encode(Variant.input.rawValue)
        out += Varint.encode(UInt64(bytes.count))
        out += bytes
        return out
    }

    /// Mirrors `AttachScrollDirection`.
    public enum ScrollDirection: UInt64, Sendable {
        case up = 0
        case down = 1
    }

    /// Scroll on an attached connection.
    ///
    /// Purpose-built for this mode: `handle_terminal_attach_scroll` requires
    /// `ClientConnectionMode::TerminalAttach` (`headless.rs:1791`) and decides
    /// per pane whether to move host scrollback or forward to the child
    /// application. `pageKeyInput` carries the original key bytes for the case
    /// where the child owns the page keys — which is how PageUp and PageDown
    /// travel, since herdr's API cannot name them.
    public static func attachScroll(
        direction: ScrollDirection,
        lines: UInt16,
        column: UInt16?,
        row: UInt16?,
        modifiers: Modifiers,
        pageKeyInput: [UInt8]? = nil
    ) -> [UInt8] {
        var out = Varint.encode(Variant.attachScroll.rawValue)
        // AttachScrollSource: Wheel = 0, PageKey { input } = 1.
        if let pageKeyInput {
            out += Varint.encode(1)
            out += Varint.encode(UInt64(pageKeyInput.count))
            out += pageKeyInput
        } else {
            out += Varint.encode(0)
        }
        out += Varint.encode(direction.rawValue)
        out += Varint.encode(UInt64(lines))
        out += option(column)
        out += option(row)
        out.append(modifiers.rawValue)     // u8, raw byte
        return out
    }

    /// bincode's `Option`: a 0/1 tag byte, then the payload. The same shape the
    /// `generated_text: None` byte in `key()` already relies on.
    private static func option(_ value: UInt16?) -> [UInt8] {
        guard let value else { return [0] }
        return [1] + Varint.encode(UInt64(value))
    }

    public static func resize(
        columns: UInt16,
        rows: UInt16,
        cellWidth: UInt32,
        cellHeight: UInt32
    ) -> [UInt8] {
        var out = Varint.encode(Variant.resize.rawValue)
        out += Varint.encode(UInt64(columns))
        out += Varint.encode(UInt64(rows))
        out += Varint.encode(UInt64(cellWidth))
        out += Varint.encode(UInt64(cellHeight))
        return out
    }

    public static func detach() -> [UInt8] {
        Varint.encode(Variant.detach.rawValue)
    }

    /// crossterm 0.29 `KeyModifiers` bit layout, as carried by
    /// `ClientInputEvent::Key.modifiers` (a raw `u8`).
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let shift = Modifiers(rawValue: 1)
        public static let control = Modifiers(rawValue: 2)
        public static let option = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    private enum InputEvent: UInt64 {
        case key = 0
        case textCommit = 1
        case mouse = 2
        case paste = 3
        case focusGained = 4
        case focusLost = 5
    }

    private enum KeyKind: UInt64 {
        case press = 0
    }

    private enum KeySource: UInt64 {
        case synthesized = 0
    }

    private static func envelope(_ event: UInt64) -> [UInt8] {
        var out = Varint.encode(Variant.inputEvents.rawValue)
        out += Varint.encode(UInt64(1))    // events.count
        out += Varint.encode(event)
        return out
    }

    private static func string(_ text: String) -> [UInt8] {
        let bytes = Array(text.utf8)
        return Varint.encode(UInt64(bytes.count)) + bytes
    }

    /// Committed text from the input method. Unlike `Char`, `String` is
    /// length-prefixed.
    public static func textCommit(_ text: String) -> [UInt8] {
        envelope(InputEvent.textCommit.rawValue) + string(text)
    }

    public static func paste(_ text: String) -> [UInt8] {
        envelope(InputEvent.paste.rawValue) + string(text)
    }

    public static func focus(gained: Bool) -> [UInt8] {
        envelope(gained ? InputEvent.focusGained.rawValue : InputEvent.focusLost.rawValue)
    }

    /// A key this client can send. Mirrors `ClientKeyCode`; only the variants
    /// the prototype produces are listed, with their wire indices.
    public enum Key: Equatable, Sendable {
        case backspace
        case enter
        case left
        case right
        case up
        case down
        case home
        case end
        case pageUp
        case pageDown
        case tab
        case backTab
        case delete
        case insert
        case escape
        case character(Character)
        case function(UInt8)

        var variant: UInt64 {
            switch self {
            case .backspace: return 0
            case .enter: return 1
            case .left: return 2
            case .right: return 3
            case .up: return 4
            case .down: return 5
            case .home: return 6
            case .end: return 7
            case .pageUp: return 8
            case .pageDown: return 9
            case .tab: return 10
            case .backTab: return 11
            case .delete: return 12
            case .insert: return 13
            case .escape: return 14
            case .character: return 15
            case .function: return 16
            }
        }

        /// Payload following the variant index.
        ///
        /// `Char` is raw UTF-8 with no length prefix — unlike `String`, which
        /// is length-prefixed. Measured, not inferred.
        var payload: [UInt8] {
            switch self {
            case .character(let character):
                return Array(String(character).utf8)
            case .function(let number):
                return [number]
            default:
                return []
            }
        }
    }

    public static func key(_ key: Key, modifiers: Modifiers) -> [UInt8] {
        var out = envelope(InputEvent.key.rawValue)
        out += Varint.encode(key.variant)
        out += key.payload
        out.append(modifiers.rawValue)               // u8, raw byte
        out += Varint.encode(KeyKind.press.rawValue)
        out += Varint.encode(UInt64(1))              // repeat_count: u16
        out.append(0)                                // generated_text: None
        out += Varint.encode(KeySource.synthesized.rawValue)
        return out
    }

    /// Convenience for a function-key press; delegates to `key`.
    public static func functionKey(_ number: UInt8, modifiers: Modifiers) -> [UInt8] {
        key(.function(number), modifiers: modifiers)
    }

    public enum MouseButton: UInt64, Sendable {
        case left = 0
        case right = 1
        case middle = 2
    }

    /// Mirrors `ClientMouseKind`. Down/Up/Drag carry a button payload; the
    /// scroll and moved variants do not.
    public enum MouseKind: Equatable, Sendable {
        case down(MouseButton)
        case up(MouseButton)
        case drag(MouseButton)
        case moved
        case scrollUp
        case scrollDown
        case scrollLeft
        case scrollRight

        var variant: UInt64 {
            switch self {
            case .down: return 0
            case .up: return 1
            case .drag: return 2
            case .moved: return 3
            case .scrollUp: return 4
            case .scrollDown: return 5
            case .scrollLeft: return 6
            case .scrollRight: return 7
            }
        }

        var button: MouseButton? {
            switch self {
            case .down(let button), .up(let button), .drag(let button):
                return button
            default:
                return nil
            }
        }
    }

    public static func mouse(
        _ kind: MouseKind,
        column: UInt16,
        row: UInt16,
        modifiers: Modifiers
    ) -> [UInt8] {
        var out = envelope(InputEvent.mouse.rawValue)
        out += Varint.encode(kind.variant)
        if let button = kind.button {
            out += Varint.encode(button.rawValue)
        }
        out += Varint.encode(UInt64(column))
        out += Varint.encode(UInt64(row))
        out.append(modifiers.rawValue)     // u8, raw byte
        return out
    }
}
