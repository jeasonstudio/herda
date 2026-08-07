import XCTest
@testable import HerdrKit

final class FramingTests: XCTestCase {
    func testPrependsLittleEndianLength() {
        XCTAssertEqual(Framing.frame([0xAA, 0xBB]), [2, 0, 0, 0, 0xAA, 0xBB])
    }

    func testFramesEmptyPayload() {
        XCTAssertEqual(Framing.frame([]), [0, 0, 0, 0])
    }

    func testDecodesLengthPrefix() throws {
        XCTAssertEqual(try Framing.payloadLength(from: [2, 0, 0, 0]), 2)
        XCTAssertEqual(try Framing.payloadLength(from: [0x00, 0x01, 0x00, 0x00]), 256)
    }

    func testRejectsOversizedLength() {
        let huge: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF]
        XCTAssertThrowsError(try Framing.payloadLength(from: huge)) { error in
            XCTAssertEqual(
                error as? Framing.Failure,
                .oversized(claimed: 4_294_967_295, max: Framing.maxPayloadSize)
            )
        }
    }

    func testRejectsShortPrefix() {
        XCTAssertThrowsError(try Framing.payloadLength(from: [1, 2, 3]))
    }
}
