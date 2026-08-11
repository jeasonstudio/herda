import CoreGraphics

/// Block elements drawn as geometry instead of glyphs.
///
/// A font's block-element outlines are sized to its em box, not to the terminal
/// cell: measured at 13pt, `█` covers 13 of the cell's 15 points and sits
/// 2.5 points below the cell's top edge. Rows of blocks therefore never touch,
/// which is why block-art — Claude Code's startup logo, progress bars — comes
/// out banded and broken. Terminals solve this by drawing these characters
/// themselves; this is that table.
///
/// Only the blocks and shades are handled here. Box-drawing lines (U+2500…257F)
/// deliberately stay on the glyph path: their outlines already overhang the cell
/// on purpose so neighbouring lines connect, and reproducing 128 of them as
/// geometry would buy nothing.
public enum CellGeometry {
    /// A rectangle in unit cell space: origin top-left, 0…1 on both axes. The
    /// view is flipped, so `y` grows downward and matches row order.
    public struct UnitRect: Equatable, Sendable {
        public let x: CGFloat
        public let y: CGFloat
        public let width: CGFloat
        public let height: CGFloat

        public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public static let full = UnitRect(x: 0, y: 0, width: 1, height: 1)
    }

    public enum Fill: Equatable, Sendable {
        /// Solid areas of the cell, in the foreground colour.
        case rects([UnitRect])
        /// The whole cell in the foreground colour at this opacity. The shade
        /// characters are stipple patterns in a font, and stipples do not tile
        /// across cell boundaries; a flat blend does, and reads the same.
        case shade(CGFloat)
    }

    /// The geometry for `symbol`, or `nil` when it should be drawn as a glyph.
    public static func fill(for symbol: String) -> Fill? {
        guard symbol.unicodeScalars.count == 1,
              let scalar = symbol.unicodeScalars.first
        else { return nil }
        return table[scalar.value]
    }

    /// Converts unit rectangles into view-space rectangles aligned to the
    /// backing store's pixel grid.
    ///
    /// Every edge is snapped independently. Two cells that share a boundary
    /// compute the same unsnapped coordinate and therefore snap to the same
    /// pixel, so their fills abut exactly and leave no anti-aliased seam — at
    /// any font size, not only the ones where the eighths divide evenly.
    public static func deviceRects(
        _ fill: Fill,
        cellOrigin: CGPoint,
        cellSize: CGSize,
        backingScale: CGFloat
    ) -> [CGRect] {
        let units: [UnitRect]
        switch fill {
        case .rects(let rects): units = rects
        case .shade: units = [.full]
        }

        return units.map { unit in
            let left = snapToDevicePixels(cellOrigin.x + unit.x * cellSize.width, scale: backingScale)
            let top = snapToDevicePixels(cellOrigin.y + unit.y * cellSize.height, scale: backingScale)
            let right = snapToDevicePixels(
                cellOrigin.x + (unit.x + unit.width) * cellSize.width,
                scale: backingScale
            )
            let bottom = snapToDevicePixels(
                cellOrigin.y + (unit.y + unit.height) * cellSize.height,
                scale: backingScale
            )
            return CGRect(x: left, y: top, width: right - left, height: bottom - top)
        }
    }

    // MARK: - Table

    private static func lower(_ eighths: CGFloat) -> Fill {
        .rects([UnitRect(x: 0, y: 1 - eighths / 8, width: 1, height: eighths / 8)])
    }

    private static func left(_ eighths: CGFloat) -> Fill {
        .rects([UnitRect(x: 0, y: 0, width: eighths / 8, height: 1)])
    }

    private static let upperLeft = UnitRect(x: 0, y: 0, width: 0.5, height: 0.5)
    private static let upperRight = UnitRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
    private static let lowerLeft = UnitRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
    private static let lowerRight = UnitRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
    private static let upperHalf = UnitRect(x: 0, y: 0, width: 1, height: 0.5)
    private static let lowerHalf = UnitRect(x: 0, y: 0.5, width: 1, height: 0.5)
    private static let leftHalf = UnitRect(x: 0, y: 0, width: 0.5, height: 1)

    /// Keyed by scalar value. Three-quadrant shapes are emitted as a half plus
    /// a quadrant rather than three quadrants: fewer fills, same result.
    private static let table: [UInt32: Fill] = [
        0x2580: .rects([upperHalf]),           // ▀ upper half
        0x2581: lower(1),                      // ▁ lower one eighth
        0x2582: lower(2),                      // ▂ lower one quarter
        0x2583: lower(3),                      // ▃ lower three eighths
        0x2584: lower(4),                      // ▄ lower half
        0x2585: lower(5),                      // ▅ lower five eighths
        0x2586: lower(6),                      // ▆ lower three quarters
        0x2587: lower(7),                      // ▇ lower seven eighths
        0x2588: .rects([.full]),               // █ full block
        0x2589: left(7),                       // ▉ left seven eighths
        0x258A: left(6),                       // ▊ left three quarters
        0x258B: left(5),                       // ▋ left five eighths
        0x258C: left(4),                       // ▌ left half
        0x258D: left(3),                       // ▍ left three eighths
        0x258E: left(2),                       // ▎ left one quarter
        0x258F: left(1),                       // ▏ left one eighth
        0x2590: .rects([UnitRect(x: 0.5, y: 0, width: 0.5, height: 1)]), // ▐ right half
        0x2591: .shade(0.25),                  // ░ light shade
        0x2592: .shade(0.5),                   // ▒ medium shade
        0x2593: .shade(0.75),                  // ▓ dark shade
        0x2594: .rects([UnitRect(x: 0, y: 0, width: 1, height: 1.0 / 8)]),   // ▔ upper one eighth
        0x2595: .rects([UnitRect(x: 7.0 / 8, y: 0, width: 1.0 / 8, height: 1)]), // ▕ right one eighth
        0x2596: .rects([lowerLeft]),           // ▖
        0x2597: .rects([lowerRight]),          // ▗
        0x2598: .rects([upperLeft]),           // ▘
        0x2599: .rects([leftHalf, lowerRight]), // ▙ UL+LL+LR
        0x259A: .rects([upperLeft, lowerRight]), // ▚
        0x259B: .rects([upperHalf, lowerLeft]), // ▛ UL+UR+LL
        0x259C: .rects([upperHalf, lowerRight]), // ▜ UL+UR+LR
        0x259D: .rects([upperRight]),          // ▝
        0x259E: .rects([upperRight, lowerLeft]), // ▞
        0x259F: .rects([lowerHalf, upperRight]), // ▟ UR+LL+LR
    ]
}
