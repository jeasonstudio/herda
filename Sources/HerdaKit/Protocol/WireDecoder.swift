import Foundation

/// Decodes `ServerMessage` payloads.
public enum WireDecoder {
    public enum Failure: Error, Equatable {
        case cellCountMismatch(cells: Int, width: UInt16, height: UInt16)
        case dimensionOverflow(UInt64)
    }

    public static func gridFrame(from reader: inout ByteReader) throws -> GridFrame {
        let cellCount = try reader.length()
        var cells = [GridCell]()
        cells.reserveCapacity(cellCount)
        for _ in 0 ..< cellCount {
            cells.append(try cell(from: &reader))
        }

        let width = try dimension(from: &reader)
        let height = try dimension(from: &reader)

        guard cells.count == Int(width) * Int(height) else {
            throw Failure.cellCountMismatch(cells: cells.count, width: width, height: height)
        }

        let cursor = try reader.optionTag() ? try self.cursor(from: &reader) : nil

        let hyperlinkCount = try reader.length()
        var hyperlinks = [String]()
        hyperlinks.reserveCapacity(hyperlinkCount)
        for _ in 0 ..< hyperlinkCount {
            hyperlinks.append(try reader.string())
        }

        let graphics = try reader.byteArray()

        return GridFrame(
            cells: cells,
            width: width,
            height: height,
            cursor: cursor,
            hyperlinks: hyperlinks,
            graphics: graphics
        )
    }

    private static func cell(from reader: inout ByteReader) throws -> GridCell {
        let symbol = try reader.string()
        let foreground = UInt32(truncatingIfNeeded: try reader.varint())
        let background = UInt32(truncatingIfNeeded: try reader.varint())
        let modifier = UInt16(truncatingIfNeeded: try reader.varint())
        let skip = try reader.bool()
        let hyperlink: UInt32? = try reader.optionTag()
            ? UInt32(truncatingIfNeeded: try reader.varint())
            : nil
        return GridCell(
            symbol: symbol,
            foreground: foreground,
            background: background,
            modifier: modifier,
            skip: skip,
            hyperlink: hyperlink
        )
    }

    private static func cursor(from reader: inout ByteReader) throws -> GridCursor {
        let column = try dimension(from: &reader)
        let row = try dimension(from: &reader)
        let isVisible = try reader.bool()
        let shape = try reader.byte()
        return GridCursor(column: column, row: row, isVisible: isVisible, shape: shape)
    }

    private static func dimension(from reader: inout ByteReader) throws -> UInt16 {
        let raw = try reader.varint()
        guard let value = UInt16(exactly: raw) else {
            throw Failure.dimensionOverflow(raw)
        }
        return value
    }

    private enum Variant: UInt64 {
        case welcome = 0
        case frame = 1
        case shutdown = 4
        case clipboard = 6
    }

    /// Decodes one framed payload.
    ///
    /// Variants the prototype handles are decoded strictly: the payload must be
    /// consumed exactly, otherwise the codec and the server disagree and we
    /// fail loudly. Variants it does not handle return `.ignored` without
    /// touching their payload — framing already told us where the message ends.
    public static func serverMessage(from payload: [UInt8]) throws -> ServerMessage {
        var reader = ByteReader(payload)
        let variant = try reader.varint()

        switch Variant(rawValue: variant) {
        case .welcome:
            let version = UInt32(truncatingIfNeeded: try reader.varint())
            let encoding = UInt32(truncatingIfNeeded: try reader.varint())
            let error = try reader.optionTag() ? try reader.string() : nil
            try reader.requireFullyConsumed()
            return .welcome(version: version, encoding: encoding, error: error)

        case .frame:
            let frame = try gridFrame(from: &reader)
            try reader.requireFullyConsumed()
            return .frame(frame)

        case .shutdown:
            let reason = try reader.optionTag() ? try reader.string() : nil
            try reader.requireFullyConsumed()
            return .shutdown(reason: reason)

        case .clipboard:
            let base64 = try reader.string()
            try reader.requireFullyConsumed()
            return .clipboard(base64: base64)

        case nil:
            return .ignored(variant: variant)
        }
    }
}
