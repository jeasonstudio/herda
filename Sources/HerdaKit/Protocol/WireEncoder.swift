import Foundation

/// Encodes the `ClientMessage` variants this prototype sends.
public enum WireEncoder {
    private enum Variant: UInt64 {
        case hello = 0
        case resize = 3
        case detach = 4
        case inputEvents = 7
    }

    private enum RenderEncoding: UInt64 {
        case semanticFrame = 0
    }

    private enum Keybindings: UInt64 {
        case server = 0
    }

    private enum LaunchMode: UInt64 {
        case app = 0
    }

    public static func hello(
        columns: UInt16,
        rows: UInt16,
        cellWidth: UInt32,
        cellHeight: UInt32
    ) -> [UInt8] {
        var out = Varint.encode(Variant.hello.rawValue)
        out += Varint.encode(UInt64(HerdaKit.protocolVersion))
        out += Varint.encode(UInt64(columns))
        out += Varint.encode(UInt64(rows))
        out += Varint.encode(UInt64(cellWidth))
        out += Varint.encode(UInt64(cellHeight))
        out += Varint.encode(RenderEncoding.semanticFrame.rawValue)
        out += Varint.encode(Keybindings.server.rawValue)
        out += Varint.encode(LaunchMode.app.rawValue)
        return out
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
