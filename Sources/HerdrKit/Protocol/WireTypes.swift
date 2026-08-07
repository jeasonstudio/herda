import Foundation

/// One terminal cell as sent by the server.
///
/// `symbol` is a grapheme cluster, usually one or two scalars. A wide
/// character occupies two cells: this one carries the symbol, the next is a
/// plain space with `skip == false`. The protocol does not mark that filler,
/// so consumers must skip it by display width. See `CharWidth`.
public struct GridCell: Equatable, Sendable {
    public let symbol: String
    public let foreground: UInt32
    public let background: UInt32
    public let modifier: UInt16
    public let skip: Bool
    public let hyperlink: UInt32?

    public init(
        symbol: String,
        foreground: UInt32,
        background: UInt32,
        modifier: UInt16,
        skip: Bool,
        hyperlink: UInt32?
    ) {
        self.symbol = symbol
        self.foreground = foreground
        self.background = background
        self.modifier = modifier
        self.skip = skip
        self.hyperlink = hyperlink
    }
}

public struct GridCursor: Equatable, Sendable {
    public let column: UInt16
    public let row: UInt16
    public let isVisible: Bool
    /// DECSCUSR parameter: 0 default, 1/2 block, 3/4 underline, 5/6 bar.
    public let shape: UInt8

    public init(column: UInt16, row: UInt16, isVisible: Bool, shape: UInt8) {
        self.column = column
        self.row = row
        self.isVisible = isVisible
        self.shape = shape
    }
}

/// A full rendered screen: `cells` is row-major, `width * height` long.
public struct GridFrame: Equatable, Sendable {
    public let cells: [GridCell]
    public let width: UInt16
    public let height: UInt16
    public let cursor: GridCursor?
    public let hyperlinks: [String]
    /// Kitty graphics protocol bytes. Decoded to keep the stream aligned;
    /// M1 does not render them.
    public let graphics: [UInt8]

    public init(
        cells: [GridCell],
        width: UInt16,
        height: UInt16,
        cursor: GridCursor?,
        hyperlinks: [String],
        graphics: [UInt8]
    ) {
        self.cells = cells
        self.width = width
        self.height = height
        self.cursor = cursor
        self.hyperlinks = hyperlinks
        self.graphics = graphics
    }

    public func cell(column: Int, row: Int) -> GridCell? {
        guard column >= 0, row >= 0, column < Int(width), row < Int(height) else { return nil }
        let index = row * Int(width) + column
        guard index < cells.count else { return nil }
        return cells[index]
    }
}

/// Messages this client understands. Variants the prototype does not handle
/// decode to `.ignored` rather than failing — see `WireDecoder`.
public enum ServerMessage: Equatable, Sendable {
    case welcome(version: UInt32, encoding: UInt32, error: String?)
    case frame(GridFrame)
    case shutdown(reason: String?)
    case ignored(variant: UInt64)
}
