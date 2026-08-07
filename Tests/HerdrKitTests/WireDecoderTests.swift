import XCTest
@testable import HerdrKit

final class WireDecoderTests: XCTestCase {
    /// A 2x1 grid: "更" (wide, RGB foreground) followed by its space filler.
    var twoByOneFramePayload: [UInt8] {
        var out = [UInt8]()
        out += Varint.encode(UInt64(2))            // cells.count

        // cell 0: "更", fg rgb(1,2,3), bg named(0), bold-ish modifier, no link
        out += Varint.encode(UInt64(3))            // symbol byte count
        out += [0xE6, 0x9B, 0xB4]                  // 更
        out += Varint.encode(UInt64(0x02_01_02_03))
        out += Varint.encode(UInt64(0))
        out += Varint.encode(UInt64(1))            // modifier bits
        out.append(0)                              // skip = false
        out.append(0)                              // hyperlink = None

        // cell 1: filler space, indexed(4) foreground, hyperlink index 0
        out += Varint.encode(UInt64(1))
        out += [0x20]
        out += Varint.encode(UInt64(0x01_00_00_04))
        out += Varint.encode(UInt64(0))
        out += Varint.encode(UInt64(0))
        out.append(0)
        out.append(1)                              // hyperlink = Some
        out += Varint.encode(UInt64(0))

        out += Varint.encode(UInt64(2))            // width
        out += Varint.encode(UInt64(1))            // height

        out.append(1)                              // cursor = Some
        out += Varint.encode(UInt64(1))            // x
        out += Varint.encode(UInt64(0))            // y
        out.append(1)                              // visible
        out.append(2)                              // shape (steady block)

        let uri = "https://example/"
        out += Varint.encode(UInt64(1))            // hyperlinks.count
        out += Varint.encode(UInt64(uri.utf8.count))
        out += Array(uri.utf8)

        out += Varint.encode(UInt64(2))            // graphics.count
        out += [0xDE, 0xAD]
        return out
    }

    func testDecodesGridFrameFields() throws {
        var reader = ByteReader(twoByOneFramePayload)
        let frame = try WireDecoder.gridFrame(from: &reader)
        try reader.requireFullyConsumed()

        XCTAssertEqual(frame.width, 2)
        XCTAssertEqual(frame.height, 1)
        XCTAssertEqual(frame.cells.count, 2)
        XCTAssertEqual(frame.cells[0].symbol, "更")
        XCTAssertEqual(frame.cells[0].foreground, 0x02_01_02_03)
        XCTAssertEqual(frame.cells[0].modifier, 1)
        XCTAssertFalse(frame.cells[0].skip)
        XCTAssertNil(frame.cells[0].hyperlink)
        XCTAssertEqual(frame.cells[1].symbol, " ")
        XCTAssertEqual(frame.cells[1].hyperlink, 0)
        XCTAssertEqual(frame.cursor, GridCursor(column: 1, row: 0, isVisible: true, shape: 2))
        XCTAssertEqual(frame.hyperlinks, ["https://example/"])
        XCTAssertEqual(frame.graphics, [0xDE, 0xAD])
    }

    func testCellLookupIsRowMajor() throws {
        var reader = ByteReader(twoByOneFramePayload)
        let frame = try WireDecoder.gridFrame(from: &reader)
        XCTAssertEqual(frame.cell(column: 0, row: 0)?.symbol, "更")
        XCTAssertEqual(frame.cell(column: 1, row: 0)?.symbol, " ")
        XCTAssertNil(frame.cell(column: 2, row: 0))
        XCTAssertNil(frame.cell(column: 0, row: 1))
    }

    func testRejectsFrameWhoseCellCountDisagreesWithDimensions() {
        var payload = [UInt8]()
        payload += Varint.encode(UInt64(1))        // one cell
        payload += Varint.encode(UInt64(1))
        payload += [0x41]
        payload += Varint.encode(UInt64(0))
        payload += Varint.encode(UInt64(0))
        payload += Varint.encode(UInt64(0))
        payload.append(0)
        payload.append(0)
        payload += Varint.encode(UInt64(4))        // width 4 -> expects 4 cells
        payload += Varint.encode(UInt64(1))
        payload.append(0)                          // cursor None
        payload += Varint.encode(UInt64(0))        // hyperlinks
        payload += Varint.encode(UInt64(0))        // graphics

        var reader = ByteReader(payload)
        XCTAssertThrowsError(try WireDecoder.gridFrame(from: &reader)) { error in
            XCTAssertEqual(
                error as? WireDecoder.Failure,
                .cellCountMismatch(cells: 1, width: 4, height: 1)
            )
        }
    }

    func testDecodesFrameWithoutCursor() throws {
        var payload = [UInt8]()
        payload += Varint.encode(UInt64(0))        // no cells
        payload += Varint.encode(UInt64(0))        // width
        payload += Varint.encode(UInt64(0))        // height
        payload.append(0)                          // cursor None
        payload += Varint.encode(UInt64(0))
        payload += Varint.encode(UInt64(0))

        var reader = ByteReader(payload)
        let frame = try WireDecoder.gridFrame(from: &reader)
        XCTAssertNil(frame.cursor)
        XCTAssertTrue(frame.cells.isEmpty)
    }

    func testDecodesWelcomeWithoutError() throws {
        let payload: [UInt8] = [0x00, 0x13, 0x00, 0x00]
        let message = try WireDecoder.serverMessage(from: payload)
        XCTAssertEqual(message, .welcome(version: 19, encoding: 0, error: nil))
    }

    func testDecodesWelcomeWithError() throws {
        var payload: [UInt8] = [0x00, 0x13, 0x00, 0x01]
        payload += Varint.encode(UInt64(2))
        payload += Array("no".utf8)
        let message = try WireDecoder.serverMessage(from: payload)
        XCTAssertEqual(message, .welcome(version: 19, encoding: 0, error: "no"))
    }

    func testDecodesShutdownReason() throws {
        var payload: [UInt8] = [0x04, 0x01]
        payload += Varint.encode(UInt64(4))
        payload += Array("bye!".utf8)
        XCTAssertEqual(try WireDecoder.serverMessage(from: payload), .shutdown(reason: "bye!"))
    }

    func testDecodesFrameVariant() throws {
        let payload = [UInt8]([0x01]) + twoByOneFramePayload
        guard case .frame(let frame) = try WireDecoder.serverMessage(from: payload) else {
            return XCTFail("expected a frame")
        }
        XCTAssertEqual(frame.width, 2)
    }

    func testIgnoresUnhandledVariantsWithoutInspectingPayload() throws {
        // MouseCapture(9) carries a bool the prototype does not use.
        XCTAssertEqual(try WireDecoder.serverMessage(from: [0x09, 0x01]), .ignored(variant: 9))
        // ReloadSoundConfig(8) has no payload.
        XCTAssertEqual(try WireDecoder.serverMessage(from: [0x08]), .ignored(variant: 8))
        // Graphics(3) carries arbitrary bytes.
        XCTAssertEqual(
            try WireDecoder.serverMessage(from: [0x03, 0x02, 0xAA, 0xBB]),
            .ignored(variant: 3)
        )
    }

    func testRejectsTrailingBytesInHandledVariant() {
        let payload: [UInt8] = [0x00, 0x13, 0x00, 0x00, 0xFF]
        XCTAssertThrowsError(try WireDecoder.serverMessage(from: payload)) { error in
            XCTAssertEqual(error as? ByteReader.Failure, .trailingBytes(consumed: 4, total: 5))
        }
    }

    func testRejectsTruncatedHandledVariant() {
        XCTAssertThrowsError(try WireDecoder.serverMessage(from: [0x00, 0x13]))
    }

    func testDecodesClipboardPayload() throws {
        // Server sends base64; decoding to text is the caller's job.
        var payload: [UInt8] = [0x06]
        let base64 = "aGk="                      // "hi"
        payload += Varint.encode(UInt64(base64.utf8.count))
        payload += Array(base64.utf8)
        XCTAssertEqual(
            try WireDecoder.serverMessage(from: payload),
            .clipboard(base64: "aGk=")
        )
    }

    func testRejectsTrailingBytesAfterClipboard() {
        var payload: [UInt8] = [0x06]
        payload += Varint.encode(UInt64(1))
        payload += Array("x".utf8)
        payload.append(0xFF)
        XCTAssertThrowsError(try WireDecoder.serverMessage(from: payload))
    }
}
