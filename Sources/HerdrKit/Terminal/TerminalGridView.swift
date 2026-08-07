import AppKit

/// Draws a `GridFrame` with Core Text.
///
/// Cells are painted one at a time. That is enough for a prototype; if the
/// frame rate proves insufficient, the next step is to merge runs of cells
/// sharing the same attributes into a single draw call.
public final class TerminalGridView: NSView {
    public let cellSize: CGSize
    public private(set) var currentFrame: GridFrame?

    private let regularFont: NSFont
    private let boldFont: NSFont
    private let italicFont: NSFont
    private let defaultForeground: NSColor
    private let defaultBackground: NSColor

    public init(
        font: NSFont,
        foreground: NSColor = NSColor(srgbRed: 0.85, green: 0.85, blue: 0.85, alpha: 1),
        background: NSColor = NSColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1)
    ) {
        self.regularFont = font
        let manager = NSFontManager.shared
        self.boldFont = manager.convert(font, toHaveTrait: .boldFontMask)
        self.italicFont = manager.convert(font, toHaveTrait: .italicFontMask)
        self.defaultForeground = foreground
        self.defaultBackground = background
        self.cellSize = TerminalGridView.measureCell(font: font)
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TerminalGridView is created in code only")
    }

    /// Integral cell metrics. Fractional advances accumulate rounding error
    /// across a wide row and visibly shear the grid.
    public static func measureCell(font: NSFont) -> CGSize {
        let advance = ("M" as NSString).size(withAttributes: [.font: font]).width
        let height = font.ascender - font.descender + font.leading
        return CGSize(width: max(1, advance.rounded()), height: max(1, height.rounded()))
    }

    public func gridSize(for size: CGSize) -> (columns: UInt16, rows: UInt16) {
        let columns = max(1, Int(size.width / cellSize.width))
        let rows = max(1, Int(size.height / cellSize.height))
        return (UInt16(min(columns, Int(UInt16.max))), UInt16(min(rows, Int(UInt16.max))))
    }

    public func update(_ frame: GridFrame) {
        currentFrame = frame
        needsDisplay = true
    }

    /// Row 0 must be at the top, matching the row-major cell order.
    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        defaultBackground.setFill()
        bounds.fill()

        guard let grid = currentFrame else { return }

        for row in 0 ..< Int(grid.height) {
            var column = 0
            while column < Int(grid.width) {
                guard let cell = grid.cell(column: column, row: row) else { break }
                let advance = CharWidth.displayWidth(of: cell.symbol)
                draw(cell, column: column, row: row, advance: advance)
                // Skipping by display width is what keeps wide characters
                // aligned: the next cell is an unmarked filler space.
                column += advance
            }
        }

        drawCursor(grid)
    }

    private func draw(_ cell: GridCell, column: Int, row: Int, advance: Int) {
        let rect = CGRect(
            x: CGFloat(column) * cellSize.width,
            y: CGFloat(row) * cellSize.height,
            width: cellSize.width * CGFloat(advance),
            height: cellSize.height
        )

        let reversed = cell.modifier & Modifier.reversed != 0
        var foreground = TerminalColor.unpack(cell.foreground).nsColor(default: defaultForeground)
        var background = TerminalColor.unpack(cell.background).nsColor(default: defaultBackground)
        if reversed {
            swap(&foreground, &background)
        }

        if background != defaultBackground {
            background.setFill()
            rect.fill()
        }

        guard !cell.symbol.isEmpty, cell.symbol != " " else { return }

        var font = regularFont
        if cell.modifier & Modifier.bold != 0 {
            font = boldFont
        } else if cell.modifier & Modifier.italic != 0 {
            font = italicFont
        }

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: foreground,
        ]
        if cell.modifier & Modifier.underlined != 0 {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }

        // The view is flipped, so this point is the glyph's top-left corner.
        (cell.symbol as NSString).draw(
            at: CGPoint(x: rect.minX, y: rect.minY),
            withAttributes: attributes
        )
    }

    private func drawCursor(_ grid: GridFrame) {
        guard let cursor = grid.cursor, cursor.isVisible else { return }
        let rect = CGRect(
            x: CGFloat(cursor.column) * cellSize.width,
            y: CGFloat(cursor.row) * cellSize.height,
            width: cellSize.width,
            height: cellSize.height
        )
        defaultForeground.withAlphaComponent(0.6).setFill()
        rect.fill()
    }

    /// ratatui `Modifier` bit positions.
    private enum Modifier {
        static let bold: UInt16 = 1 << 0
        static let dim: UInt16 = 1 << 1
        static let italic: UInt16 = 1 << 2
        static let underlined: UInt16 = 1 << 3
        static let reversed: UInt16 = 1 << 6
    }
}
