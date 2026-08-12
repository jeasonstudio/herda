import XCTest
@testable import HerdaKit

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

    func testHelloCanDeclareTerminalAttach() {
        // Only the launch mode differs. That one byte is what makes the server
        // set pending_terminal_attach (client_transport.rs:566) and keeps the
        // connection out of is_full_app_client (clients.rs:176), so it never
        // becomes foreground and never drives effective_size.
        let app = WireEncoder.hello(columns: 100, rows: 30, cellWidth: 8, cellHeight: 16)
        let attach = WireEncoder.hello(
            columns: 100, rows: 30, cellWidth: 8, cellHeight: 16,
            launchMode: .terminalAttach
        )
        XCTAssertEqual(Array(app.dropLast()), Array(attach.dropLast()))
        XCTAssertEqual(app.last, 0x00)
        XCTAssertEqual(attach.last, 0x01)
    }

    func testControlTerminalMatchesGoldenBytes() {
        XCTAssertEqual(
            WireEncoder.controlTerminal(target: "w1:p1", takeover: true),
            [
                0x09,                                      // ClientMessage::ControlTerminal
                0x05, 0x77, 0x31, 0x3A, 0x70, 0x31,        // String "w1:p1"
                0x01,                                      // takeover true
            ]
        )
    }

    func testControlTerminalTakeoverFalseAndWideTarget() {
        // String is a varint length plus UTF-8, so a multi-byte target is longer
        // in bytes than in characters — the distinction that makes `char` and
        // `String` diverge above ASCII.
        let payload = WireEncoder.controlTerminal(target: "wé", takeover: false)
        XCTAssertEqual(payload, [0x09, 0x03, 0x77, 0xC3, 0xA9, 0x00])
    }

    func testInputCarriesRawBytesLengthPrefixed() {
        // ESC [ H — Home, which herdr's API vocabulary cannot name.
        XCTAssertEqual(
            WireEncoder.input([0x1B, 0x5B, 0x48]),
            [0x01, 0x03, 0x1B, 0x5B, 0x48]
        )
    }

    func testAttachScrollWheelMatchesGoldenBytes() {
        XCTAssertEqual(
            WireEncoder.attachScroll(
                direction: .up, lines: 3, column: 12, row: 7, modifiers: [.option]
            ),
            [
                0x06,        // ClientMessage::AttachScroll
                0x00,        // AttachScrollSource::Wheel
                0x00,        // AttachScrollDirection::Up
                0x03,        // lines
                0x01, 0x0C,  // column Some(12)
                0x01, 0x07,  // row Some(7)
                0x04,        // modifiers, raw u8
            ]
        )
    }

    func testAttachScrollOmitsAbsentCoordinates() {
        XCTAssertEqual(
            WireEncoder.attachScroll(
                direction: .down, lines: 1, column: nil, row: nil, modifiers: []
            ),
            [0x06, 0x00, 0x01, 0x01, 0x00, 0x00, 0x00]
        )
    }

    func testAttachScrollCarriesPageKeyBytes() {
        // PageUp travels this way rather than as an Input, because the server
        // decides per pane whether the page key moves host scrollback or goes to
        // the child application.
        XCTAssertEqual(
            WireEncoder.attachScroll(
                direction: .up, lines: 1, column: nil, row: nil, modifiers: [],
                pageKeyInput: [0x1B, 0x5B, 0x35, 0x7E]
            ),
            [
                0x06,                                // AttachScroll
                0x01,                                // AttachScrollSource::PageKey
                0x04, 0x1B, 0x5B, 0x35, 0x7E,        // input bytes, length prefixed
                0x00,                                // direction Up
                0x01,                                // lines
                0x00, 0x00,                          // column None, row None
                0x00,                                // modifiers
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
