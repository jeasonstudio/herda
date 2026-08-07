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

    func testFunctionKeyMatchesGoldenBytes() {
        let payload = WireEncoder.functionKey(20, modifiers: WireEncoder.Modifiers.control.union(.option))
        XCTAssertEqual(
            payload,
            [
                0x07,  // ClientMessage::InputEvents
                0x01,  // events.count == 1
                0x00,  // ClientInputEvent::Key
                0x10,  // ClientKeyCode::F  (variant 16)
                0x14,  // F payload: 20 (u8, single byte)
                0x06,  // modifiers: CONTROL(2) | ALT(4)
                0x00,  // ClientKeyKind::Press
                0x01,  // repeat_count 1
                0x00,  // generated_text: None
                0x00,  // ClientKeySource::Synthesized
            ]
        )
    }

    func testModifierBitsMatchCrosstermLayout() {
        XCTAssertEqual(WireEncoder.Modifiers.shift.rawValue, 1)
        XCTAssertEqual(WireEncoder.Modifiers.control.rawValue, 2)
        XCTAssertEqual(WireEncoder.Modifiers.option.rawValue, 4)
        XCTAssertEqual(WireEncoder.Modifiers.command.rawValue, 8)
    }

    func testFunctionKeyWithoutModifiers() {
        let payload = WireEncoder.functionKey(1, modifiers: [])
        XCTAssertEqual(payload, [0x07, 0x01, 0x00, 0x10, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00])
    }

    func testCharKeyMatchesMeasuredBytes() {
        XCTAssertEqual(
            WireEncoder.key(.character("c"), modifiers: .control),
            [0x07, 0x01, 0x00, 0x0F, 0x63, 0x02, 0x00, 0x01, 0x00, 0x00]
        )
    }

    func testCharKeyWithoutModifiers() {
        XCTAssertEqual(
            WireEncoder.key(.character("a"), modifiers: []),
            [0x07, 0x01, 0x00, 0x0F, 0x61, 0x00, 0x00, 0x01, 0x00, 0x00]
        )
    }

    func testCharIsEncodedAsRawUTF8WithoutLengthPrefix() {
        // Unlike String, char carries no length prefix. "更" is three bytes.
        XCTAssertEqual(
            WireEncoder.key(.character("更"), modifiers: []),
            [0x07, 0x01, 0x00, 0x0F, 0xE6, 0x9B, 0xB4, 0x00, 0x00, 0x01, 0x00, 0x00]
        )
    }

    func testSpecialKeysUseTheirVariantIndices() {
        XCTAssertEqual(
            WireEncoder.key(.enter, modifiers: []),
            [0x07, 0x01, 0x00, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00]
        )
        XCTAssertEqual(
            WireEncoder.key(.escape, modifiers: []),
            [0x07, 0x01, 0x00, 0x0E, 0x00, 0x00, 0x01, 0x00, 0x00]
        )
        XCTAssertEqual(
            WireEncoder.key(.backspace, modifiers: []),
            [0x07, 0x01, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00]
        )
        XCTAssertEqual(
            WireEncoder.key(.tab, modifiers: []),
            [0x07, 0x01, 0x00, 0x0A, 0x00, 0x00, 0x01, 0x00, 0x00]
        )
        XCTAssertEqual(
            WireEncoder.key(.up, modifiers: []),
            [0x07, 0x01, 0x00, 0x04, 0x00, 0x00, 0x01, 0x00, 0x00]
        )
    }

    func testFunctionKeyGoesThroughTheSameEncoder() {
        // M1's functionKey(20, [.control, .option]) must stay byte-identical.
        XCTAssertEqual(
            WireEncoder.key(.function(20), modifiers: [.control, .option]),
            WireEncoder.functionKey(20, modifiers: [.control, .option])
        )
    }

    func testTextCommitIsLengthPrefixed() {
        XCTAssertEqual(
            WireEncoder.textCommit("a"),
            [0x07, 0x01, 0x01, 0x01, 0x61]
        )
        // "更新" is six UTF-8 bytes; TextCommit(String) IS length-prefixed.
        XCTAssertEqual(
            WireEncoder.textCommit("更新"),
            [0x07, 0x01, 0x01, 0x06, 0xE6, 0x9B, 0xB4, 0xE6, 0x96, 0xB0]
        )
    }

    func testPasteEncodesText() {
        XCTAssertEqual(WireEncoder.paste("hi"), [0x07, 0x01, 0x03, 0x02, 0x68, 0x69])
    }

    func testFocusEventsHaveNoPayload() {
        XCTAssertEqual(WireEncoder.focus(gained: true), [0x07, 0x01, 0x04])
        XCTAssertEqual(WireEncoder.focus(gained: false), [0x07, 0x01, 0x05])
    }

    func testEmptyTextCommitStillEncodes() {
        XCTAssertEqual(WireEncoder.textCommit(""), [0x07, 0x01, 0x01, 0x00])
    }

    func testMouseDownMatchesMeasuredBytes() {
        XCTAssertEqual(
            WireEncoder.mouse(.down(.left), column: 3, row: 4, modifiers: []),
            [0x07, 0x01, 0x02, 0x00, 0x00, 0x03, 0x04, 0x00]
        )
    }

    func testMouseUpWithRightButtonAndWideColumn() {
        // Column 300 needs the varint 251 tag plus a little-endian u16.
        XCTAssertEqual(
            WireEncoder.mouse(.up(.right), column: 300, row: 5, modifiers: []),
            [0x07, 0x01, 0x02, 0x01, 0x01, 251, 0x2C, 0x01, 0x05, 0x00]
        )
    }

    func testMouseDragCarriesModifiers() {
        XCTAssertEqual(
            WireEncoder.mouse(.drag(.left), column: 1, row: 2, modifiers: .shift),
            [0x07, 0x01, 0x02, 0x02, 0x00, 0x01, 0x02, 0x01]
        )
    }

    func testScrollKindsHaveNoButtonPayload() {
        XCTAssertEqual(
            WireEncoder.mouse(.scrollUp, column: 0, row: 0, modifiers: []),
            [0x07, 0x01, 0x02, 0x04, 0x00, 0x00, 0x00]
        )
        XCTAssertEqual(
            WireEncoder.mouse(.scrollDown, column: 7, row: 8, modifiers: []),
            [0x07, 0x01, 0x02, 0x05, 0x07, 0x08, 0x00]
        )
    }
}
