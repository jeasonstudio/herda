import XCTest
@testable import HerdrKit

final class TerminalColorTests: XCTestCase {
    func testResetMapsToReset() {
        XCTAssertEqual(TerminalColor.unpack(0x00_00_00_00), .reset)
    }

    func testNamedColorsMapToConcreteRGB() {
        // ghostty "Tomorrow Night" base16 — the client's actual terminal defaults.
        XCTAssertEqual(TerminalColor.unpack(0x00_00_00_01), .rgb(0x1D, 0x1F, 0x21))  // Black
        XCTAssertEqual(TerminalColor.unpack(0x00_00_00_10), .rgb(0xEA, 0xEA, 0xEA))  // White (bright)
    }

    func testNamedGrayAndDarkGrayAreDistinct() {
        // ratatui Gray is ANSI 7, DarkGray is ANSI 8 (bright black).
        XCTAssertNotEqual(TerminalColor.unpack(0x00_00_00_08), TerminalColor.unpack(0x00_00_00_09))
    }

    func testUnknownNamedIndexFallsBackToReset() {
        XCTAssertEqual(TerminalColor.unpack(0x00_00_00_7F), .reset)
    }

    func testRGBIsUnpackedFromLowThreeBytes() {
        XCTAssertEqual(TerminalColor.unpack(0x02_2F_41_E4), .rgb(0x2F, 0x41, 0xE4))
    }

    func testIndexedBasicRangeMatchesNamedColors() {
        // Palette 0...15 are the same sixteen colors as the named variants.
        XCTAssertEqual(TerminalColor.unpack(0x01_00_00_00), .rgb(0x1D, 0x1F, 0x21))
        XCTAssertEqual(TerminalColor.unpack(0x01_00_00_0F), .rgb(0xEA, 0xEA, 0xEA))
    }

    func testIndexedCubeUsesStandardLevels() {
        // 16 is the cube origin (0,0,0); 231 is its far corner (255,255,255).
        XCTAssertEqual(TerminalColor.unpack(0x01_00_00_10), .rgb(0, 0, 0))
        XCTAssertEqual(TerminalColor.unpack(0x01_00_00_E7), .rgb(255, 255, 255))
        // 21 == index 5 in the cube -> blue at full level.
        XCTAssertEqual(TerminalColor.unpack(0x01_00_00_15), .rgb(0, 0, 255))
    }

    func testIndexedGrayscaleRamp() {
        XCTAssertEqual(TerminalColor.unpack(0x01_00_00_E8), .rgb(8, 8, 8))          // 232
        XCTAssertEqual(TerminalColor.unpack(0x01_00_00_FF), .rgb(238, 238, 238))    // 255
    }

    func testUnknownTagFallsBackToReset() {
        XCTAssertEqual(TerminalColor.unpack(0x09_00_00_00), .reset)
    }
}
