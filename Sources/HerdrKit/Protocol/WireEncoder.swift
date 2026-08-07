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
}
