import XCTest
@testable import HerdrKit

final class WireEncoderTests: XCTestCase {
    func testHelloMatchesGoldenBytes() {
        let payload = WireEncoder.hello(columns: 100, rows: 30, cellWidth: 8, cellHeight: 16)
        XCTAssertEqual(
            payload,
            [
                0x00,  // ClientMessage::Hello
                0x13,  // version 19
                0x64,  // cols 100
                0x1E,  // rows 30
                0x08,  // cell_width_px 8
                0x10,  // cell_height_px 16
                0x00,  // RenderEncoding::SemanticFrame
                0x00,  // ClientKeybindings::Server
                0x00,  // ClientLaunchMode::App
            ]
        )
    }

    func testHelloWidensLargeDimensionsWithVarintTag() {
        let payload = WireEncoder.hello(columns: 300, rows: 30, cellWidth: 8, cellHeight: 16)
        // 300 does not fit in one byte: tag 251 then u16 little endian.
        XCTAssertEqual(Array(payload[0 ... 1]), [0x00, 0x13])
        XCTAssertEqual(Array(payload[2 ... 4]), [251, 0x2C, 0x01])
    }

    func testResizeEncodesAllFourDimensions() {
        let payload = WireEncoder.resize(columns: 80, rows: 24, cellWidth: 8, cellHeight: 16)
        XCTAssertEqual(payload, [0x03, 0x50, 0x18, 0x08, 0x10])
    }

    func testDetachIsSingleVariantByte() {
        XCTAssertEqual(WireEncoder.detach(), [0x04])
    }

    func testFramedHelloCarriesCorrectLength() throws {
        let payload = WireEncoder.hello(columns: 100, rows: 30, cellWidth: 8, cellHeight: 16)
        let framed = Framing.frame(payload)
        XCTAssertEqual(try Framing.payloadLength(from: Array(framed[0 ..< 4])), 9)
        XCTAssertEqual(Array(framed[4...]), payload)
    }
}
