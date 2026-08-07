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
        out += Varint.encode(UInt64(HerdrKit.protocolVersion))
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
    }

    private enum KeyKind: UInt64 {
        case press = 0
    }

    private enum KeySource: UInt64 {
        case synthesized = 0
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
        var out = Varint.encode(Variant.inputEvents.rawValue)
        out += Varint.encode(UInt64(1))              // events.count
        out += Varint.encode(InputEvent.key.rawValue)
        out += Varint.encode(key.variant)
        out += key.payload
        out.append(modifiers.rawValue)               // u8, raw byte
        out += Varint.encode(KeyKind.press.rawValue)
        out += Varint.encode(UInt64(1))              // repeat_count: u16
        out.append(0)                                // generated_text: None
        out += Varint.encode(KeySource.synthesized.rawValue)
        return out
    }

    /// Kept for the startup sidebar toggle; delegates to `key`.
    public static func functionKey(_ number: UInt8, modifiers: Modifiers) -> [UInt8] {
        key(.function(number), modifiers: modifiers)
    }
}
