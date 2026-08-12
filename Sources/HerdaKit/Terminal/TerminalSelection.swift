import Foundation

/// A text selection over a cell grid, and the text it yields.
///
/// Pure so the awkward parts are testable without a window: reading order across
/// wrapped lines, where a word ends, and what trailing blanks to drop. herdr's own
/// mouse selection went away with the app render connection, so this is the only
/// way to copy from a pane.
public struct TerminalSelection: Equatable, Sendable {
    /// A cell position. Not `GridCursor` — that carries visibility and a shape,
    /// neither of which means anything here.
    public struct Cell: Equatable, Comparable, Sendable {
        public var column: Int
        public var row: Int

        public init(column: Int, row: Int) {
            self.column = column
            self.row = row
        }

        /// Reading order: row first, then column.
        public static func < (lhs: Cell, rhs: Cell) -> Bool {
            (lhs.row, lhs.column) < (rhs.row, rhs.column)
        }
    }

    /// Where the drag started. Stays put while the other end moves, so dragging
    /// back past the origin selects in the other direction.
    public let anchor: Cell
    /// Where the pointer is now.
    public let focus: Cell

    public init(anchor: Cell, focus: Cell) {
        self.anchor = anchor
        self.focus = focus
    }

    /// The two ends in reading order.
    public var bounds: (start: Cell, end: Cell) {
        anchor <= focus ? (anchor, focus) : (focus, anchor)
    }

    /// Whether the selection covers no cells at all.
    ///
    /// A plain click produces anchor == focus, which is one cell wide. Treating
    /// that as a selection would make every click copy a character, so a single
    /// cell counts as empty and the caller discards it.
    public var isEmpty: Bool { anchor == focus }

    /// Whether a cell is inside the selection.
    ///
    /// Linear, not rectangular: the range runs to the end of each row and
    /// continues on the next, which is how a terminal's own selection reads and
    /// what makes copying a wrapped command line give back one line.
    public func contains(column: Int, row: Int) -> Bool {
        guard !isEmpty else { return false }
        let (start, end) = bounds
        if row < start.row || row > end.row { return false }
        if start.row == end.row { return column >= start.column && column < end.column }
        if row == start.row { return column >= start.column }
        if row == end.row { return column < end.column }
        return true
    }

    /// The selected text, one entry per row, joined with newlines.
    ///
    /// Trailing blanks are dropped per row: a terminal pads every row to full
    /// width, so keeping them would put dozens of spaces after each line on the
    /// pasteboard. Rows that are entirely blank stay as empty lines, because they
    /// are real blank lines in the output.
    public func text(from frame: GridFrame) -> String {
        guard !isEmpty else { return "" }
        let width = Int(frame.width)
        let height = Int(frame.height)
        let (start, end) = bounds
        guard width > 0, height > 0 else { return "" }

        var lines: [String] = []
        for row in max(0, start.row) ... min(height - 1, end.row) where row >= 0 {
            var line = ""
            for column in 0 ..< width where contains(column: column, row: row) {
                let cell = frame.cells[row * width + column]
                // A wide character is followed by an unmarked filler cell, which
                // is an ordinary space on the wire. Skipping `skip` cells is what
                // keeps CJK from gaining a space after every glyph.
                if cell.skip { continue }
                line += cell.symbol
            }
            while line.hasSuffix(" ") { line.removeLast() }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Expansion

    /// The word under a cell, for a double-click.
    ///
    /// Word characters are letters, digits, and the punctuation that appears
    /// inside things people double-click in a terminal — paths, flags, hostnames.
    /// Splitting on `/` or `.` would make double-clicking a path give one segment,
    /// which is never what was wanted.
    public static func word(
        at cell: Cell,
        in frame: GridFrame
    ) -> TerminalSelection? {
        let width = Int(frame.width)
        guard width > 0, cell.row >= 0, cell.row < Int(frame.height),
              cell.column >= 0, cell.column < width
        else { return nil }

        let row = cell.row
        func isWord(_ column: Int) -> Bool {
            let symbol = frame.cells[row * width + column].symbol
            guard let scalar = symbol.unicodeScalars.first, symbol != " " else { return false }
            if CharacterSet.alphanumerics.contains(scalar) { return true }
            return "_-./:~@+=".unicodeScalars.contains(scalar)
        }

        guard isWord(cell.column) else { return nil }
        var first = cell.column
        while first > 0, isWord(first - 1) { first -= 1 }
        var last = cell.column
        while last + 1 < width, isWord(last + 1) { last += 1 }
        // The end is exclusive, matching `contains`.
        return TerminalSelection(
            anchor: Cell(column: first, row: row),
            focus: Cell(column: last + 1, row: row)
        )
    }

    /// The whole row, for a triple-click. The end is exclusive and sits one past
    /// the last column, so `contains` covers the final character.
    public static func line(at cell: Cell, in frame: GridFrame) -> TerminalSelection? {
        guard cell.row >= 0, cell.row < Int(frame.height), frame.width > 0 else { return nil }
        return TerminalSelection(
            anchor: Cell(column: 0, row: cell.row),
            focus: Cell(column: Int(frame.width), row: cell.row)
        )
    }

    /// Everything in the frame.
    public static func all(in frame: GridFrame) -> TerminalSelection? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        return TerminalSelection(
            anchor: Cell(column: 0, row: 0),
            focus: Cell(column: Int(frame.width), row: Int(frame.height) - 1)
        )
    }
}
