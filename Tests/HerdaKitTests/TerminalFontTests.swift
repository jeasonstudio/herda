import AppKit
import XCTest
@testable import HerdaKit

final class TerminalFontTests: XCTestCase {
    func testCellMetricsAreIntegral() {
        let font = TerminalFont(size: 13)
        XCTAssertEqual(font.cellSize.width, font.cellSize.width.rounded(), "fractional advances shear the grid")
        XCTAssertEqual(font.cellSize.height, font.cellSize.height.rounded())
        XCTAssertGreaterThan(font.cellSize.width, 0)
        XCTAssertGreaterThan(font.cellSize.height, 0)
    }

    func testBaselineLeavesRoomAboveAndBelow() {
        let font = TerminalFont(size: 13)
        XCTAssertGreaterThan(font.baselineFromTop, 0)
        XCTAssertLessThan(font.baselineFromTop, font.cellSize.height)
    }

    func testBaselineReservesWholePixelsForDescenders() {
        let font = TerminalFont(size: 13)
        let descenderRoom = font.cellSize.height - font.baselineFromTop
        XCTAssertGreaterThanOrEqual(descenderRoom, -font.regular.descender.rounded())
    }

    func testMetricsScaleWithSize() {
        let small = TerminalFont(size: 11)
        let large = TerminalFont(size: 18)
        XCTAssertLessThan(small.cellSize.width, large.cellSize.width)
        XCTAssertLessThan(small.cellSize.height, large.cellSize.height)
    }

    func testResolveFallsBackWhenNoPreferredFamilyIsInstalled() {
        // The concrete family may or may not be present on a given machine, so
        // the contract under test is only that resolution always succeeds.
        let resolved = TerminalFont.resolve(size: 13)
        XCTAssertGreaterThan(resolved.pointSize, 0)
        XCTAssertFalse(resolved.fontName.isEmpty)
    }

    func testAdvanceMatchesTheFontsOwnGlyphMetrics() {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        XCTAssertEqual(TerminalFont.advance(of: font), font.maximumAdvancement.width, accuracy: 0.01)
    }

    func testBoldAndItalicAreDistinctFaces() {
        let font = TerminalFont(size: 13)
        XCTAssertNotEqual(font.bold.fontName, font.regular.fontName)
        XCTAssertEqual(font.font(bold: true, italic: false).fontName, font.bold.fontName)
        XCTAssertEqual(font.font(bold: false, italic: true).fontName, font.italic.fontName)
        XCTAssertEqual(font.font(bold: false, italic: false).fontName, font.regular.fontName)
    }

    func testMonospaceAdvanceIsUniform() {
        let font = TerminalFont(size: 13).regular
        let widths = ["M", "i", "W", "1", "@"].map {
            ($0 as NSString).size(withAttributes: [.font: font]).width
        }
        for width in widths {
            XCTAssertEqual(width, widths[0], accuracy: 0.01, "terminal font must be monospaced")
        }
    }

    func testSnapToDevicePixelsIsIdempotentAndSharesBoundaries() {
        for scale in [CGFloat(1), 2, 3] {
            let snapped = snapToDevicePixels(10.3, scale: scale)
            XCTAssertEqual(snapToDevicePixels(snapped, scale: scale), snapped)
            // Two cells computing the same boundary must land on the same pixel.
            XCTAssertEqual(snapToDevicePixels(10.3, scale: scale), snapped)
        }
    }

    func testSnapToDevicePixelsToleratesAnInvalidScale() {
        XCTAssertEqual(snapToDevicePixels(10.6, scale: 0), 11)
    }

    func testGridSizeDividesBySizeOfACell() {
        // TerminalSession still reports the whole terminal area's cols/rows for
        // the app connection, but it no longer owns a single view — there is one
        // per pane now — so the measurement lives on the type that owns cellSize.
        let font = TerminalFont(size: 13)
        let cell = font.cellSize
        let grid = font.gridSize(for: CGSize(width: cell.width * 80, height: cell.height * 24))
        XCTAssertEqual(grid.columns, 80)
        XCTAssertEqual(grid.rows, 24)
    }

    func testGridSizeNeverReportsZero() {
        // Startup and resize both pass through .zero, and a handshake declaring
        // zero columns is rejected by the server.
        let grid = TerminalFont(size: 13).gridSize(for: .zero)
        XCTAssertEqual(grid.columns, 1)
        XCTAssertEqual(grid.rows, 1)
    }
}
