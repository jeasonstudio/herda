import Foundation

/// Cuts one pane's subframe out of the whole grid.
///
/// There is a single render connection, so the server sends one `GridFrame`
/// covering the entire terminal area; each pane's view renders the slice taken
/// here. Pure, and tested without a window on purpose — the correctness of this
/// function is the foundation of the native layout, and an off-by-one shifts a
/// whole pane's contents in a way that is very hard to trace back once there is a
/// picture on screen.
public enum FrameSlice {
    /// Takes the region `rect` covers, clamped to the frame's bounds.
    public static func slice(_ frame: GridFrame, to rect: PaneLayoutRect) -> GridFrame {
        let frameWidth = Int(frame.width)
        let frameHeight = Int(frame.height)
        let originX = Int(rect.x)
        let originY = Int(rect.y)

        // Clamp instead of trusting the rect: between a window resize and the
        // layout_updated that follows, there is a frame where the rect still
        // describes the previous size.
        let width = max(0, min(Int(rect.width), frameWidth - originX))
        let height = max(0, min(Int(rect.height), frameHeight - originY))

        guard width > 0, height > 0 else {
            return GridFrame(
                cells: [], width: 0, height: 0, cursor: nil,
                hyperlinks: frame.hyperlinks, graphics: []
            )
        }

        let blank = GridCell(
            symbol: " ", foreground: 0, background: 0,
            modifier: 0, skip: false, hyperlink: nil
        )

        var cells: [GridCell] = []
        cells.reserveCapacity(width * height)
        for row in originY..<(originY + height) {
            let rowStart = row * frameWidth
            for column in originX..<(originX + width) {
                let index = rowStart + column
                // Downstream of a hand-written decoder: tolerate a cells array
                // shorter than width * height rather than reading out of bounds.
                cells.append(index < frame.cells.count ? frame.cells[index] : blank)
            }
        }

        // The whole grid carries exactly one cursor and it belongs to the focused
        // pane, so only the rect containing it keeps it. Otherwise every pane
        // would draw a blinking caret.
        var cursor: GridCursor?
        if let source = frame.cursor {
            let column = Int(source.column)
            let row = Int(source.row)
            if column >= originX, column < originX + width,
               row >= originY, row < originY + height {
                cursor = GridCursor(
                    column: UInt16(column - originX),
                    row: UInt16(row - originY),
                    isVisible: source.isVisible,
                    shape: source.shape
                )
            }
        }

        return GridFrame(
            cells: cells,
            width: UInt16(width),
            height: UInt16(height),
            cursor: cursor,
            // Carried whole: `cell.hyperlink` indexes into this table, so
            // renumbering would mean remapping every cell to save a few strings.
            hyperlinks: frame.hyperlinks,
            // Nothing renders it, and slicing a kitty payload by rect is not a
            // meaningful operation.
            graphics: []
        )
    }
}
