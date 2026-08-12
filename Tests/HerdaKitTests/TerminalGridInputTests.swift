import AppKit
import XCTest
@testable import HerdaKit

/// `keyDown` routing, driven with synthetic events.
///
/// The view has a real `NSTextInputContext` even outside a window, so these tests
/// exercise the actual input-method handshake rather than a stub. Whichever input
/// source the machine has active has no composition of its own, so it answers
/// composition keys by translating them into standard editing commands — the
/// exact path a key gets swallowed on.
@MainActor
final class TerminalGridInputTests: XCTestCase {
    private func makeView() -> (TerminalGridView, () -> [[UInt8]]) {
        let view = TerminalGridView(terminalFont: TerminalFont(size: 13))
        let sent = Sent()
        // Collected as the bytes the intent encodes to, so every byte assertion
        // below still checks what actually reaches the wire — and still proves
        // each emit site in the view fires.
        view.onInput = { input in sent.append(input.appInputEventsPayload()) }
        return (view, { sent.all })
    }

    /// Collects payloads from the view's `@Sendable` callback.
    ///
    /// `@unchecked Sendable`: the view invokes the callback synchronously on the
    /// same thread the test drives it from, so there is no concurrent access.
    private final class Sent: @unchecked Sendable {
        private(set) var all: [[UInt8]] = []
        func append(_ payload: [UInt8]) { all.append(payload) }
    }

    /// Characters a real key event carries. The input context inspects them, so
    /// an event built without them is not answered the way the real one is.
    private enum Keys {
        static let (returnKey, characters) = (UInt16(36), "\r")
        static let backspace = (code: UInt16(51), characters: "\u{7f}")
        static let escape = (code: UInt16(53), characters: "\u{1b}")
        static let up = (code: UInt16(126), characters: "\u{f700}")
        static let down = (code: UInt16(125), characters: "\u{f701}")
    }

    private func event(
        keyCode: UInt16,
        characters: String = "",
        flags: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    func testReturnReachesThePane() {
        let (view, sent) = makeView()
        view.keyDown(with: event(keyCode: Keys.returnKey, characters: Keys.characters))
        XCTAssertEqual(sent(), [WireEncoder.key(.enter, modifiers: [])])
    }

    func testControlCReachesThePane() {
        let (view, sent) = makeView()
        view.keyDown(with: event(keyCode: 8, characters: "c", flags: .control))
        XCTAssertEqual(sent(), [WireEncoder.key(.character("c"), modifiers: [.control])])
    }

    func testArrowKeysReachThePane() {
        let (view, sent) = makeView()
        view.keyDown(with: event(keyCode: Keys.up.code, characters: Keys.up.characters))
        view.keyDown(with: event(keyCode: Keys.down.code, characters: Keys.down.characters))
        XCTAssertEqual(
            sent(),
            [WireEncoder.key(.up, modifiers: []), WireEncoder.key(.down, modifiers: [])]
        )
    }

    /// While composing, these keys go to the input method first. The active input
    /// source here has no composition of its own, so it answers each one by
    /// translating it into a standard editing command and reporting success —
    /// which is precisely the case a terminal loses the key in if it only watches
    /// `handleEvent`'s return value.
    func testCompositionKeysTheInputMethodTurnsIntoCommandsStillReachThePane() {
        for (keyCode, characters, expected) in [
            (Keys.returnKey, Keys.characters, WireEncoder.Key.enter),
            (Keys.backspace.code, Keys.backspace.characters, .backspace),
            (Keys.escape.code, Keys.escape.characters, .escape),
        ] {
            let (view, sent) = makeView()
            view.setMarkedText("ni", selectedRange: NSRange(location: 0, length: 2), replacementRange: NSRange())
            XCTAssertTrue(view.hasMarkedText())

            view.keyDown(with: event(keyCode: keyCode, characters: characters))
            XCTAssertEqual(
                sent(),
                [WireEncoder.key(expected, modifiers: [])],
                "key code \(keyCode) was swallowed"
            )
        }
    }

    /// The other half of the same guarantee: exactly one key, never two, even
    /// though both the command path and the declined path could fire.
    func testACommandKeyIsNotSentTwice() {
        let (view, sent) = makeView()
        view.setMarkedText("ni", selectedRange: NSRange(location: 0, length: 2), replacementRange: NSRange())
        view.keyDown(with: event(keyCode: Keys.returnKey, characters: Keys.characters))
        XCTAssertEqual(sent().count, 1)
    }

    func testControlStillInterruptsWhileComposing() {
        let (view, sent) = makeView()
        view.setMarkedText("ni", selectedRange: NSRange(location: 0, length: 2), replacementRange: NSRange())
        view.keyDown(with: event(keyCode: 8, characters: "c", flags: .control))
        XCTAssertEqual(sent(), [WireEncoder.key(.character("c"), modifiers: [.control])])
    }

    func testCommittedTextIsSentAsText() {
        let (view, sent) = makeView()
        view.insertText("你好", replacementRange: NSRange())
        XCTAssertEqual(sent(), [WireEncoder.textCommit("你好")])
    }

    func testCommittingClearsTheComposition() {
        let (view, _) = makeView()
        view.setMarkedText("nihao", selectedRange: NSRange(location: 0, length: 5), replacementRange: NSRange())
        view.insertText("你好", replacementRange: NSRange())
        XCTAssertFalse(view.hasMarkedText())
    }

    func testEmptyCommitSendsNothing() {
        let (view, sent) = makeView()
        view.insertText("", replacementRange: NSRange())
        XCTAssertTrue(sent().isEmpty)
    }

    func testCommandVPastesTheHostPasteboard() {
        let (view, sent) = makeView()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("pasted", forType: .string)
        view.keyDown(with: event(keyCode: 9, characters: "v", flags: .command))
        XCTAssertEqual(sent(), [WireEncoder.paste("pasted")])
    }

    func testLosingFirstResponderAbandonsTheComposition() {
        let (view, _) = makeView()
        view.setMarkedText("ni", selectedRange: NSRange(location: 0, length: 2), replacementRange: NSRange())
        _ = view.resignFirstResponder()
        XCTAssertFalse(view.hasMarkedText(), "stale composition would be left on screen")
    }

    // MARK: - Scrolling

    func testTrackpadScrollIsRateLimited() {
        let (view, sent) = makeView()
        // Four small precise deltas add up to less than one cell of travel.
        for _ in 0 ..< 4 {
            view.scrollWheel(with: scrollEvent(deltaY: 3, precise: true))
        }
        XCTAssertTrue(sent().isEmpty, "momentum scrolling used to emit one step per event")
    }

    func testTrackpadScrollEmitsOncePerCellOfTravel() {
        let (view, sent) = makeView()
        view.scrollWheel(with: scrollEvent(deltaY: view.cellSize.height * 3, precise: true))
        XCTAssertEqual(sent().count, 3)
    }

    private func scrollEvent(deltaY: CGFloat, precise: Bool) -> NSEvent {
        // CGEvent is the only way to set scrolling deltas; NSEvent's are read-only.
        let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: precise ? .pixel : .line,
            wheelCount: 1,
            wheel1: Int32(deltaY),
            wheel2: 0,
            wheel3: 0
        )!
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: precise ? 1 : 0)
        return NSEvent(cgEvent: event)!
    }
}
