import CoreGraphics
import Foundation

/// Grid layout for in-progress input-method text.
///
/// Composition has to be shown somewhere, and the only place it belongs is at
/// the cursor — but a composing phrase is frequently wider than the space left
/// on the row, and CJK characters occupy two columns each. Both the drawing pass
/// and `firstRect(forCharacterRange:)` (which positions the candidate window)
/// read this one layout, so the text the user sees and the panel that floats
/// above it can never disagree.
public enum MarkedText {
    /// One composing character placed on the grid.
    public struct Slot: Equatable, Sendable {
        public let symbol: String
        public let column: Int
        public let row: Int
        /// Columns this character occupies — 2 for wide characters.
        public let width: Int
        /// Offset of this character within the marked string, in UTF-16 units,
        /// which is the unit `NSTextInputClient` ranges are expressed in.
        public let utf16Offset: Int

        public init(symbol: String, column: Int, row: Int, width: Int, utf16Offset: Int) {
            self.symbol = symbol
            self.column = column
            self.row = row
            self.width = width
            self.utf16Offset = utf16Offset
        }
    }

    /// Places `text` starting at the cursor, wrapping at the right edge and
    /// stopping at the bottom of the grid. A character never straddles the edge:
    /// a wide character that would only half fit moves to the next row whole.
    public static func layout(
        _ text: String,
        cursorColumn: Int,
        cursorRow: Int,
        gridWidth: Int,
        gridHeight: Int
    ) -> [Slot] {
        guard !text.isEmpty, gridWidth > 0, gridHeight > 0 else { return [] }

        var slots: [Slot] = []
        var column = min(max(0, cursorColumn), gridWidth - 1)
        var row = min(max(0, cursorRow), gridHeight - 1)
        var offset = 0

        for character in text {
            let symbol = String(character)
            let width = min(CharWidth.displayWidth(of: symbol), gridWidth)
            if column + width > gridWidth {
                column = 0
                row += 1
            }
            guard row < gridHeight else { break }
            slots.append(
                Slot(symbol: symbol, column: column, row: row, width: width, utf16Offset: offset)
            )
            column += width
            offset += symbol.utf16.count
        }
        return slots
    }

    /// Cell rectangle a UTF-16 range occupies, clipped to the row its first
    /// character landed on — an input method wants one anchor rectangle, not a
    /// multi-row union.
    ///
    /// An empty or out-of-range request resolves to the position the next
    /// character would take, which is where the caret is.
    public static func boundingRect(
        for range: NSRange,
        in slots: [Slot],
        cellSize: CGSize
    ) -> CGRect? {
        guard !slots.isEmpty else { return nil }

        let covered = slots.filter { slot in
            let end = slot.utf16Offset + slot.symbol.utf16.count
            return slot.utf16Offset >= range.location && end <= range.location + max(range.length, 1)
        }

        guard let first = covered.first else {
            // Past the end: anchor just after the final character.
            guard let last = slots.last else { return nil }
            return CGRect(
                x: CGFloat(last.column + last.width) * cellSize.width,
                y: CGFloat(last.row) * cellSize.height,
                width: cellSize.width,
                height: cellSize.height
            )
        }

        let sameRow = covered.filter { $0.row == first.row }
        let columns = sameRow.reduce(0) { $0 + $1.width }
        return CGRect(
            x: CGFloat(first.column) * cellSize.width,
            y: CGFloat(first.row) * cellSize.height,
            width: cellSize.width * CGFloat(max(1, columns)),
            height: cellSize.height
        )
    }
}
