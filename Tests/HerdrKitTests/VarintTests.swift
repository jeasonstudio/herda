import XCTest
@testable import HerdrKit

final class VarintTests: XCTestCase {
    func testEncodesSmallValuesAsSingleByte() {
        XCTAssertEqual(Varint.encode(0), [0])
        XCTAssertEqual(Varint.encode(1), [1])
        XCTAssertEqual(Varint.encode(250), [250])
    }

    func testEncodesU16RangeWithTag251() {
        XCTAssertEqual(Varint.encode(251), [251, 251, 0])
        XCTAssertEqual(Varint.encode(65535), [251, 0xFF, 0xFF])
    }

    func testEncodesU32RangeWithTag252() {
        XCTAssertEqual(Varint.encode(65536), [252, 0x00, 0x00, 0x01, 0x00])
    }

    func testEncodesU64RangeWithTag253() {
        XCTAssertEqual(
            Varint.encode(UInt64(UInt32.max) + 1),
            [253, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00]
        )
    }

    func testRoundTripsBoundaryValues() throws {
        for value in [UInt64(0), 1, 250, 251, 65535, 65536, UInt64(UInt32.max), UInt64(UInt32.max) + 1] {
            var reader = ByteReader(Varint.encode(value))
            XCTAssertEqual(try reader.varint(), value, "round trip failed for \(value)")
            XCTAssertTrue(reader.isAtEnd)
        }
    }

    func testReadsSingleBytesAndBools() throws {
        var reader = ByteReader([7, 0, 1])
        XCTAssertEqual(try reader.byte(), 7)
        XCTAssertFalse(try reader.bool())
        XCTAssertTrue(try reader.bool())
    }

    func testReadsLengthPrefixedString() throws {
        var reader = ByteReader([3, 0x61, 0x62, 0x63])
        XCTAssertEqual(try reader.string(), "abc")
    }

    func testReadsMultiByteUTF8String() throws {
        let bytes: [UInt8] = [3, 0xE6, 0x9B, 0xB4]
        var reader = ByteReader(bytes)
        XCTAssertEqual(try reader.string(), "更")
    }

    func testOptionTagDistinguishesNoneAndSome() throws {
        var none = ByteReader([0])
        XCTAssertFalse(try none.optionTag())
        var some = ByteReader([1])
        XCTAssertTrue(try some.optionTag())
    }

    func testThrowsOnTruncatedInput() {
        var reader = ByteReader([251, 0x01])
        XCTAssertThrowsError(try reader.varint())
    }

    func testThrowsOnBadVarintTag() {
        var reader = ByteReader([254])
        XCTAssertThrowsError(try reader.varint()) { error in
            XCTAssertEqual(error as? ByteReader.Failure, .badVarintTag(254))
        }
    }

    func testThrowsOnBadOptionTag() {
        var reader = ByteReader([2])
        XCTAssertThrowsError(try reader.optionTag()) { error in
            XCTAssertEqual(error as? ByteReader.Failure, .unexpectedOptionTag(2))
        }
    }

    func testRequireFullyConsumedDetectsTrailingBytes() throws {
        var reader = ByteReader([1, 99])
        _ = try reader.byte()
        XCTAssertThrowsError(try reader.requireFullyConsumed()) { error in
            XCTAssertEqual(error as? ByteReader.Failure, .trailingBytes(consumed: 1, total: 2))
        }
    }
}
