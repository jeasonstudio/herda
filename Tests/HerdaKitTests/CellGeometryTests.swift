import CoreGraphics
import XCTest
@testable import HerdaKit

final class CellGeometryTests: XCTestCase {
    private let cell = CGSize(width: 8, height: 17)

    private func rects(_ symbol: String, at origin: CGPoint = .zero, scale: CGFloat = 2) -> [CGRect] {
        guard let fill = CellGeometry.fill(for: symbol) else {
            XCTFail("\(symbol) has no geometry")
            return []
        }
        return CellGeometry.deviceRects(
            fill,
            cellOrigin: origin,
            cellSize: cell,
            backingScale: scale
        )
    }

    func testFullBlockCoversTheWholeCell() {
        XCTAssertEqual(rects("█"), [CGRect(x: 0, y: 0, width: 8, height: 17)])
    }

    func testUpperHalfBlockCoversExactlyTheTopHalf() {
        let rect = rects("▀")[0]
        XCTAssertEqual(rect.minY, 0)
        XCTAssertEqual(rect.width, 8)
        XCTAssertEqual(rect.maxY, 8.5, accuracy: 0.001)
    }

    func testUpperLeftQuadrantCoversOneQuarter() {
        let rect = rects("▘")[0]
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 4, height: 8.5))
    }

    func testLowerEighthSitsAtTheBottomEdge() {
        let rect = rects("▁")[0]
        XCTAssertEqual(rect.maxY, 17, accuracy: 0.001)
        XCTAssertLessThan(rect.height, cell.height / 4)
    }

    func testLeftHalfAndRightHalfTileTheCell() {
        let left = rects("▌")[0]
        let right = rects("▐")[0]
        XCTAssertEqual(left.maxX, right.minX, "halves must meet, not overlap or gap")
        XCTAssertEqual(left.minX, 0)
        XCTAssertEqual(right.maxX, 8)
    }

    /// The regression this whole table exists for: a font's block outlines cover
    /// 13 of the cell's 17 points, so stacked rows of them never touch and
    /// block-art comes out banded.
    func testStackedFullBlocksMeetWithoutASeam() {
        for scale in [CGFloat(1), 2, 3] {
            let upper = rects("█", at: CGPoint(x: 0, y: 0), scale: scale)[0]
            let lower = rects("█", at: CGPoint(x: 0, y: cell.height), scale: scale)[0]
            XCTAssertEqual(
                upper.maxY,
                lower.minY,
                "backing scale \(scale): rows \(upper.maxY) and \(lower.minY) leave a seam"
            )
        }
    }

    func testSideBySideFullBlocksMeetWithoutASeam() {
        let left = rects("█", at: .zero)[0]
        let right = rects("█", at: CGPoint(x: cell.width, y: 0))[0]
        XCTAssertEqual(left.maxX, right.minX)
    }

    /// Quadrants of two vertically adjacent cells have to share the boundary
    /// too, or the logo shows a hairline where the halves meet.
    func testAdjacentQuadrantsShareTheirBoundary() {
        let upperRow = rects("▄", at: .zero)[0]                       // lower half
        let lowerRow = rects("▀", at: CGPoint(x: 0, y: cell.height))[0] // upper half
        XCTAssertEqual(upperRow.maxY, lowerRow.minY)
    }

    func testEighthBoundariesLandOnBackingPixels() {
        // 17 points does not divide into eighths evenly; snapping is what keeps
        // adjacent fills aligned anyway.
        let scale: CGFloat = 2
        for symbol in ["▁", "▂", "▃", "▄", "▅", "▆", "▇"] {
            let rect = rects(symbol, scale: scale)[0]
            XCTAssertEqual(
                rect.minY * scale,
                (rect.minY * scale).rounded(),
                "\(symbol) top edge is off the pixel grid"
            )
        }
    }

    func testShadesMapToOpacities() {
        XCTAssertEqual(CellGeometry.fill(for: "░"), .shade(0.25))
        XCTAssertEqual(CellGeometry.fill(for: "▒"), .shade(0.5))
        XCTAssertEqual(CellGeometry.fill(for: "▓"), .shade(0.75))
    }

    func testShadeFillsTheWholeCellSoItTilesAcrossCells() {
        XCTAssertEqual(rects("░"), [CGRect(x: 0, y: 0, width: 8, height: 17)])
    }

    func testThreeQuadrantShapesCoverThreeQuarters() {
        // ▛ is upper-left + upper-right + lower-left.
        let area = rects("▛").reduce(0) { $0 + $1.width * $1.height }
        XCTAssertEqual(area, 8 * 17 * 0.75, accuracy: 0.5)
    }

    func testBoxDrawingStaysOnTheGlyphPath() {
        // Their outlines already overhang the cell so neighbours connect;
        // replacing them with geometry would break that.
        for symbol in ["─", "│", "┌", "┼", "╭"] {
            XCTAssertNil(CellGeometry.fill(for: symbol), "\(symbol) must be drawn as a glyph")
        }
    }

    func testOrdinaryTextHasNoGeometry() {
        for symbol in ["A", " ", "更", "😀", "❯"] {
            XCTAssertNil(CellGeometry.fill(for: symbol))
        }
    }

    func testMultiScalarSymbolsAreNotMistakenForBlocks() {
        XCTAssertNil(CellGeometry.fill(for: "█\u{0301}"))
    }
}
