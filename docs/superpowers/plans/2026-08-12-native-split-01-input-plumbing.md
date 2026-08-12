# Native Split, Plan 1: Input Plumbing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and test everything needed to send input to a pane by pane id, without changing any behaviour yet.

**Architecture:** `TerminalGridView` stops emitting encoded wire bytes and starts emitting a `TerminalInput` intent. `TerminalSession` translates that intent back into today's `InputEvents` bytes, so the app behaves exactly as it does now. Alongside that, the pieces the switchover needs — herdr key names, CSI bytes for the six keys herdr's API vocabulary lacks, `pane.send_keys`/`pane.send_text`, and a serial send queue — are built and unit-tested but not yet wired in.

**Why this order:** Plan 1 of the first design shipped config changes, and plans 2–4 then had to be corrected twice by what plan 1 measured. This plan front-loads the risk instead: by the end, the input channel is proven and nothing has been bet on it.

**Tech Stack:** Swift 6 strict concurrency, XCTest, AppKit. Spec: `docs/superpowers/specs/2026-08-12-native-split-layout-design.md`.

**Definition of done:** `Scripts/test.sh` passes, the app builds and runs, and typing, pasting, input-method composition, mouse and scroll all behave exactly as before this plan.

---

### Task 1: `HerdrKeyName` — a key press as a herdr API key name

herdr's `pane.send_keys` takes key *names*, parsed by `config::parse_key_combo`
(`config/keybinds.rs:1201`). The accepted vocabulary was measured against the
running server; six keys are not in it and must return `nil` so the caller falls
back to raw bytes (Task 2).

**Files:**
- Create: `Sources/HerdaKit/Protocol/HerdrKeyName.swift`
- Test: `Tests/HerdaKitTests/HerdrKeyNameTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import HerdaKit

final class HerdrKeyNameTests: XCTestCase {
    private func name(
        _ key: WireEncoder.Key,
        _ modifiers: WireEncoder.Modifiers = []
    ) -> String? {
        HerdrKeyName.name(for: key, modifiers: modifiers)
    }

    func testNamesTheKeysHerdrAccepts() {
        // Measured against the running server: these are accepted, and the six
        // in testReturnsNilForKeysOutsideTheVocabulary are rejected with
        // "unsupported key". See the spec's verified fact five.
        XCTAssertEqual(name(.enter), "enter")
        XCTAssertEqual(name(.escape), "esc")
        XCTAssertEqual(name(.backspace), "backspace")
        XCTAssertEqual(name(.tab), "tab")
        XCTAssertEqual(name(.left), "left")
        XCTAssertEqual(name(.right), "right")
        XCTAssertEqual(name(.up), "up")
        XCTAssertEqual(name(.down), "down")
        XCTAssertEqual(name(.function(5)), "f5")
        XCTAssertEqual(name(.function(12)), "f12")
        XCTAssertEqual(name(.character("a")), "a")
    }

    func testBackTabIsSpelledShiftTab() {
        // parse_key_combo has no "backtab": it produces BackTab from
        // "tab" + SHIFT, removing the shift bit as it does so
        // (config/keybinds.rs, the "tab" arms).
        XCTAssertEqual(name(.backTab), "shift+tab")
    }

    func testReturnsNilForKeysOutsideTheVocabulary() {
        // Measured: rejected as "unsupported key", including the spellings
        // page_up, pgup and del. Grepping keybinds.rs for these finds nothing —
        // it is not a spelling problem, the vocabulary lacks them.
        XCTAssertNil(name(.home))
        XCTAssertNil(name(.end))
        XCTAssertNil(name(.pageUp))
        XCTAssertNil(name(.pageDown))
        XCTAssertNil(name(.delete))
        XCTAssertNil(name(.insert))
    }

    func testPrefixesModifiersInACanonicalOrder() {
        XCTAssertEqual(name(.character("c"), [.control]), "ctrl+c")
        XCTAssertEqual(name(.character("b"), [.option]), "alt+b")
        XCTAssertEqual(name(.left, [.shift]), "shift+left")
        XCTAssertEqual(name(.character("k"), [.command]), "cmd+k")
        XCTAssertEqual(
            name(.character("x"), [.control, .shift, .option, .command]),
            "ctrl+shift+alt+cmd+x"
        )
    }

    func testUsesPunctuationNamesWhereACharacterWouldNotParse() {
        // parse_key_combo splits on "+", so a literal plus can never be a key
        // token: "ctrl++" splits into ["ctrl", "", ""] and the empty part makes
        // the whole combo fail. The named form is the only one that survives.
        XCTAssertEqual(name(.character("+"), [.control]), "ctrl+plus")
        XCTAssertEqual(name(.character(" ")), "space")
        XCTAssertEqual(name(.character("-")), "minus")
        XCTAssertEqual(name(.character(",")), "comma")
        XCTAssertEqual(name(.character(".")), "period")
        XCTAssertEqual(name(.character("/")), "slash")
        XCTAssertEqual(name(.character("\\")), "backslash")
        XCTAssertEqual(name(.character(";")), "semicolon")
        XCTAssertEqual(name(.character(":")), "colon")
        XCTAssertEqual(name(.character("'")), "quote")
        XCTAssertEqual(name(.character("\"")), "double_quote")
        XCTAssertEqual(name(.character("%")), "percent")
        XCTAssertEqual(name(.character("&")), "ampersand")
        XCTAssertEqual(name(.character("`")), "backtick")
    }

    func testPassesThroughCharactersWithNoSpecialName() {
        XCTAssertEqual(name(.character("=")), "=")
        XCTAssertEqual(name(.character("[")), "[")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `Scripts/test.sh 2>&1 | tail -20`
Expected: compile failure, `cannot find 'HerdrKeyName' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Renders a key press as a herdr API key name for `pane.send_keys`.
///
/// The inverse of herdr's `config::parse_key_combo` (`config/keybinds.rs:1201`),
/// which is what `pane.send_keys` runs each name through
/// (`app/api_helpers.rs:11`). Only the names that parser accepts are produced;
/// anything else returns nil so the caller can fall back to raw CSI bytes.
public enum HerdrKeyName {
    /// Characters that cannot be sent as themselves, or that herdr spells out.
    ///
    /// `+` is the load-bearing one: `parse_key_combo` splits the combo on `+`,
    /// so "ctrl++" becomes ["ctrl", "", ""] and the empty component fails the
    /// whole parse. The rest are included because herdr names them and a name
    /// is easier to read in a log than a bare glyph.
    private static let punctuationNames: [Character: String] = [
        " ": "space", "-": "minus", ",": "comma", ".": "period",
        "/": "slash", "\\": "backslash", "'": "quote", "\"": "double_quote",
        ";": "semicolon", ":": "colon", "%": "percent", "&": "ampersand",
        "`": "backtick", "+": "plus",
    ]

    /// The name for a key, or nil when herdr's vocabulary cannot express it.
    ///
    /// Measured against a running server: home, end, pageup, pagedown, delete
    /// and insert are rejected with `unsupported key` in every spelling tried,
    /// and grepping `keybinds.rs` for them finds nothing. Those six go through
    /// `TerminalKeyBytes` instead.
    public static func name(
        for key: WireEncoder.Key,
        modifiers: WireEncoder.Modifiers
    ) -> String? {
        guard var token = baseName(for: key) else { return nil }
        var modifiers = modifiers

        // BackTab has no name of its own: herdr derives it from "tab" + SHIFT
        // and strips the shift bit while doing so. Emitting "shift+shift+tab"
        // would not parse, so the base name carries the shift itself.
        if case .backTab = key { modifiers.remove(.shift) }

        var prefix = ""
        // Canonical order, so a log line for the same chord always reads the
        // same. herdr's parser is order-insensitive.
        if modifiers.contains(.control) { prefix += "ctrl+" }
        if modifiers.contains(.shift) { prefix += "shift+" }
        if modifiers.contains(.option) { prefix += "alt+" }
        if modifiers.contains(.command) { prefix += "cmd+" }
        token = prefix + token
        return token
    }

    private static func baseName(for key: WireEncoder.Key) -> String? {
        switch key {
        case .enter: return "enter"
        case .escape: return "esc"
        case .backspace: return "backspace"
        case .tab: return "tab"
        case .backTab: return "shift+tab"
        case .left: return "left"
        case .right: return "right"
        case .up: return "up"
        case .down: return "down"
        case .function(let number): return "f\(number)"
        case .character(let character):
            return punctuationNames[character] ?? String(character)
        // Not in herdr's vocabulary — see the doc comment on `name(for:)`.
        case .home, .end, .pageUp, .pageDown, .delete, .insert:
            return nil
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `Scripts/test.sh 2>&1 | tail -5`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
xcodegen generate
git add Sources/HerdaKit/Protocol/HerdrKeyName.swift Tests/HerdaKitTests/HerdrKeyNameTests.swift
git commit -m "feat: render a key press as a herdr API key name

pane.send_keys parses each name through config::parse_key_combo. The
vocabulary was measured against a running server rather than read off the
parser: f5, backspace, shift+tab, ctrl+a and alt+b are accepted, and home,
end, pageup, pagedown, delete and insert are rejected as unsupported key in
every spelling tried, including page_up, pgup and del. Grepping keybinds.rs
for those six finds nothing, so it is the vocabulary and not the spelling.
Those return nil for a raw-bytes fallback.

Punctuation goes through herdr's names because parse_key_combo splits the
combo on +, which makes a literal plus unrepresentable as itself: ctrl++
splits into [ctrl, \"\", \"\"] and the empty component fails the parse."
```

---

### Task 2: `TerminalKeyBytes` — CSI bytes for the six keys herdr cannot name

**Files:**
- Create: `Sources/HerdaKit/Protocol/TerminalKeyBytes.swift`
- Test: `Tests/HerdaKitTests/TerminalKeyBytesTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import HerdaKit

final class TerminalKeyBytesTests: XCTestCase {
    private func bytes(
        _ key: WireEncoder.Key,
        _ modifiers: WireEncoder.Modifiers = []
    ) -> [UInt8]? {
        TerminalKeyBytes.csi(for: key, modifiers: modifiers)
    }

    private func text(_ value: [UInt8]?) -> String? {
        value.map { String(decoding: $0, as: UTF8.self) }
    }

    func testEncodesTheTildeKeys() {
        XCTAssertEqual(text(bytes(.insert)), "\u{1b}[2~")
        XCTAssertEqual(text(bytes(.delete)), "\u{1b}[3~")
        XCTAssertEqual(text(bytes(.pageUp)), "\u{1b}[5~")
        XCTAssertEqual(text(bytes(.pageDown)), "\u{1b}[6~")
    }

    func testEncodesHomeAndEndInTheCursorForm() {
        // The one mode-dependent pair: xterm sends ESC[H / ESC[F in normal mode
        // and ESC OH / ESC OF under DECCKM. A client attached to one pane cannot
        // observe that mode — MouseCapture-style state is only streamed to full
        // app clients and no API method exposes it — so the CSI form is sent
        // unconditionally and verified against real apps in Task 7.
        XCTAssertEqual(text(bytes(.home)), "\u{1b}[H")
        XCTAssertEqual(text(bytes(.end)), "\u{1b}[F")
    }

    func testEncodesModifiersInTheXtermParameterForm() {
        // xterm's modifier parameter is 1 + shift(1) + alt(2) + ctrl(4).
        XCTAssertEqual(text(bytes(.delete, [.shift])), "\u{1b}[3;2~")
        XCTAssertEqual(text(bytes(.pageUp, [.control])), "\u{1b}[5;5~")
        XCTAssertEqual(text(bytes(.pageDown, [.option])), "\u{1b}[6;3~")
        // Home and End take a leading 1 parameter when modified, because a
        // parameter list needs a first element for the modifier to be second.
        XCTAssertEqual(text(bytes(.home, [.shift])), "\u{1b}[1;2H")
        XCTAssertEqual(text(bytes(.end, [.control, .shift])), "\u{1b}[1;6F")
    }

    func testCommandIsNotAnXtermModifier() {
        // xterm has no bit for cmd, and macOS cmd chords are application
        // shortcuts rather than terminal input. Dropping it is deliberate: the
        // alternative is inventing a parameter no terminal reads.
        XCTAssertEqual(text(bytes(.home, [.command])), "\u{1b}[H")
    }

    func testReturnsNilForKeysHerdrCanName() {
        // These have to go through pane.send_keys so herdr encodes them with
        // the terminal's own modes. Returning bytes here would bypass that.
        XCTAssertNil(bytes(.enter))
        XCTAssertNil(bytes(.left))
        XCTAssertNil(bytes(.character("a")))
        XCTAssertNil(bytes(.function(5)))
    }

    func testEveryKeyIsCoveredByExactlyOneChannel() {
        // The invariant the two tasks exist to satisfy: no key may fall through
        // both, and none may be claimed by both.
        let keys: [WireEncoder.Key] = [
            .backspace, .enter, .left, .right, .up, .down, .home, .end,
            .pageUp, .pageDown, .tab, .backTab, .delete, .insert, .escape,
            .character("a"), .function(1),
        ]
        for key in keys {
            let named = HerdrKeyName.name(for: key, modifiers: []) != nil
            let raw = TerminalKeyBytes.csi(for: key, modifiers: []) != nil
            XCTAssertTrue(named != raw, "\(key) must be in exactly one channel")
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `Scripts/test.sh 2>&1 | tail -20`
Expected: compile failure, `cannot find 'TerminalKeyBytes' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// CSI byte sequences for the keys herdr's API vocabulary cannot name.
///
/// `pane.send_keys` is the right channel for everything it can express, because
/// herdr encodes there with the terminal's own modes. These six keys are not in
/// `config::parse_key_combo` (measured: rejected as `unsupported key`), so they
/// go out as raw bytes on the pane's own connection instead, where
/// `apply_terminal_attach_input` passes them straight to the PTY
/// (`headless.rs:403`).
public enum TerminalKeyBytes {
    /// The bytes for a key, or nil when `HerdrKeyName` can name it.
    public static func csi(
        for key: WireEncoder.Key,
        modifiers: WireEncoder.Modifiers
    ) -> [UInt8]? {
        switch key {
        case .insert: return tilde(2, modifiers)
        case .delete: return tilde(3, modifiers)
        case .pageUp: return tilde(5, modifiers)
        case .pageDown: return tilde(6, modifiers)
        case .home: return cursor("H", modifiers)
        case .end: return cursor("F", modifiers)
        default: return nil
        }
    }

    /// `ESC [ n ~`, or `ESC [ n ; m ~` when modified.
    private static func tilde(_ number: Int, _ modifiers: WireEncoder.Modifiers) -> [UInt8] {
        guard let parameter = xtermParameter(modifiers) else {
            return Array("\u{1b}[\(number)~".utf8)
        }
        return Array("\u{1b}[\(number);\(parameter)~".utf8)
    }

    /// `ESC [ X`, or `ESC [ 1 ; m X` when modified — the leading 1 exists only
    /// so the modifier has a second parameter slot to sit in.
    private static func cursor(_ final: String, _ modifiers: WireEncoder.Modifiers) -> [UInt8] {
        guard let parameter = xtermParameter(modifiers) else {
            return Array("\u{1b}[\(final)".utf8)
        }
        return Array("\u{1b}[1;\(parameter)\(final)".utf8)
    }

    /// xterm's modifier parameter: 1 + shift(1) + alt(2) + ctrl(4). nil when no
    /// modifier applies, so the unmodified form stays short.
    ///
    /// cmd has no xterm bit and is dropped rather than invented: a macOS cmd
    /// chord is an application shortcut, not terminal input.
    private static func xtermParameter(_ modifiers: WireEncoder.Modifiers) -> Int? {
        var bits = 0
        if modifiers.contains(.shift) { bits += 1 }
        if modifiers.contains(.option) { bits += 2 }
        if modifiers.contains(.control) { bits += 4 }
        return bits == 0 ? nil : bits + 1
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `Scripts/test.sh 2>&1 | tail -5`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
xcodegen generate
git add Sources/HerdaKit/Protocol/TerminalKeyBytes.swift Tests/HerdaKitTests/TerminalKeyBytesTests.swift
git commit -m "feat: encode the six keys herdr's API cannot name

Insert, Delete, PageUp and PageDown are mode-independent, so their CSI
forms are exact. Home and End are not: xterm sends ESC[H / ESC[F normally
and ESC OH / ESC OF under DECCKM, and a client attached to one pane cannot
observe that mode — MouseCapture is streamed only to full app clients and
no API method or response field exposes terminal state. The CSI form goes
out unconditionally and gets verified against real apps.

A test asserts the invariant the two channels exist for: every key is
claimed by exactly one of HerdrKeyName and TerminalKeyBytes, so none can
fall through both or be sent twice."
```

---

### Task 3: `TerminalInput` — the view reports intent instead of bytes

`TerminalGridView.onPayload` currently hands out finished `InputEvents` wire
payloads. On a pane connection those bytes trigger the cascade in the spec's
first hard constraint: `ClientInputEvents` has no early return for
`TerminalAttach`, so it reaches `promote_client_to_foreground`, which has no
guard, and `effective_size` becomes one pane's size with every pane relaid out
inside it.

This task changes the outlet only. `TerminalSession` converts the intent straight
back into today's bytes, so behaviour is identical.

**Files:**
- Create: `Sources/HerdaKit/Terminal/TerminalInput.swift`
- Modify: `Sources/HerdaKit/Terminal/TerminalGridView.swift:87` and its six emit sites (`:170`, `:182`, `:198`, `:212`, `:231`, `:815`)
- Modify: `Sources/HerdaKit/Runtime/TerminalSession.swift:120-122`, `:175-177`, `:404-411`
- Test: `Tests/HerdaKitTests/TerminalInputTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import HerdaKit

final class TerminalInputTests: XCTestCase {
    func testKeyIntentEncodesToTheSameBytesAsBefore() {
        // The refactor must not change a single byte on the app connection.
        // These are the payloads TerminalGridView used to build inline.
        XCTAssertEqual(
            TerminalInput.key(.enter, []).appInputEventsPayload(),
            WireEncoder.key(.enter, modifiers: [])
        )
        XCTAssertEqual(
            TerminalInput.key(.character("c"), [.control]).appInputEventsPayload(),
            WireEncoder.key(.character("c"), modifiers: [.control])
        )
    }

    func testTextIntentDistinguishesPasteFromCommit() {
        // Both carry a String on the wire, but they are different variants and
        // herdr treats a paste as a bracketed block.
        XCTAssertEqual(
            TerminalInput.text("hi", kind: .commit).appInputEventsPayload(),
            WireEncoder.textCommit("hi")
        )
        XCTAssertEqual(
            TerminalInput.text("hi", kind: .paste).appInputEventsPayload(),
            WireEncoder.paste("hi")
        )
    }

    func testMouseAndFocusIntentsEncodeUnchanged() {
        XCTAssertEqual(
            TerminalInput.mouse(.down(.left), column: 4, row: 9, []).appInputEventsPayload(),
            WireEncoder.mouse(.down(.left), column: 4, row: 9, modifiers: [])
        )
        XCTAssertEqual(
            TerminalInput.focus(gained: true).appInputEventsPayload(),
            WireEncoder.focus(gained: true)
        )
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `Scripts/test.sh 2>&1 | tail -20`
Expected: compile failure, `cannot find 'TerminalInput' in scope`.

- [ ] **Step 3: Create `TerminalInput`**

```swift
import Foundation

/// What the terminal view wants sent, before anything decides where it goes or
/// how it is encoded.
///
/// The view used to hand out finished `InputEvents` bytes. Those cannot be sent
/// on a per-pane connection: `ClientInputEvents` has no early return for
/// `TerminalAttach` (`headless.rs:2893`), so it reaches
/// `promote_client_to_foreground`, which has no guard (`:1460`), and the server
/// then relays out every pane inside the size of the one that sent the key.
/// Reporting intent keeps that routing decision with the session.
public enum TerminalInput: Equatable, Sendable {
    public enum TextKind: Equatable, Sendable {
        /// Committed by the input method.
        case commit
        /// Pasted from the host pasteboard.
        case paste
    }

    case key(WireEncoder.Key, WireEncoder.Modifiers)
    case text(String, kind: TextKind)
    case mouse(WireEncoder.MouseKind, column: UInt16, row: UInt16, WireEncoder.Modifiers)
    case focus(gained: Bool)

    /// The `InputEvents` payload this intent used to be emitted as.
    ///
    /// Only valid on a full app connection. Kept so this plan changes no bytes;
    /// the switchover replaces the call sites rather than this method.
    public func appInputEventsPayload() -> [UInt8] {
        switch self {
        case .key(let key, let modifiers):
            return WireEncoder.key(key, modifiers: modifiers)
        case .text(let value, .commit):
            return WireEncoder.textCommit(value)
        case .text(let value, .paste):
            return WireEncoder.paste(value)
        case .mouse(let kind, let column, let row, let modifiers):
            return WireEncoder.mouse(kind, column: column, row: row, modifiers: modifiers)
        case .focus(let gained):
            return WireEncoder.focus(gained: gained)
        }
    }
}
```

- [ ] **Step 4: Swap the view's outlet**

In `Sources/HerdaKit/Terminal/TerminalGridView.swift`, replace line 86-87:

```swift
    /// Set by the session; receives what the user did, not encoded bytes. The
    /// session decides which pane it belongs to and which channel carries it —
    /// see `TerminalInput`.
    public var onInput: (@Sendable (TerminalInput) -> Void)?
```

Then replace each emit site, changing nothing else:

| Line | Was | Becomes |
|---|---|---|
| `:170` | `onPayload?(WireEncoder.paste(text))` | `onInput?(.text(text, kind: .paste))` |
| `:182` | `onPayload?(WireEncoder.key(key, modifiers: modifiers))` | `onInput?(.key(key, modifiers))` |
| `:198` | `onPayload?(WireEncoder.key(key, modifiers: modifiers))` | `onInput?(.key(key, modifiers))` |
| `:212` | `onPayload?(WireEncoder.key(key, modifiers: []))` | `onInput?(.key(key, []))` |
| `:815` | `onPayload?(WireEncoder.textCommit(text))` | `onInput?(.text(text, kind: .commit))` |

And `sendMouse` at `:228`:

```swift
    private func sendMouse(_ kind: WireEncoder.MouseKind, _ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let position = cellPosition(for: point)
        onInput?(
            .mouse(
                kind,
                column: position.column,
                row: position.row,
                KeyMap.modifiers(from: event.modifierFlags)
            )
        )
    }
```

- [ ] **Step 5: Adapt `TerminalSession` so behaviour is unchanged**

In `Sources/HerdaKit/Runtime/TerminalSession.swift`, replace the two outlet
assignments (`:120-122` in `attach`, `:175-177` in `viewForPane`) with:

```swift
        view.onInput = { [weak self] input in
            Task { @MainActor in self?.send(input) }
        }
```

(for `wholeGridView` in `attach`, the same body with `wholeGridView.onInput`).

Then replace `send(_ payload:)` at `:404` with:

```swift
    /// Sends one input intent. Still `InputEvents` on the app connection —
    /// Plan 1 changes the plumbing, not the destination. Failures are logged
    /// rather than surfaced: a dropped keypress must not tear down the session.
    private func send(_ input: TerminalInput) {
        guard let connection else { return }
        do {
            try connection.send(input.appInputEventsPayload())
        } catch {
            log("input send failed: \(error)")
        }
    }
```

`reportFocus(gained:)` at `:413` becomes:

```swift
    public func reportFocus(gained: Bool) {
        guard case .running = state else { return }
        send(.focus(gained: gained))
    }
```

- [ ] **Step 6: Run the whole suite**

Run: `Scripts/test.sh 2>&1 | tail -5`
Expected: all tests pass, including the existing `TerminalGridInputTests`, which
drives `keyDown(with:)` on a real view — that suite is what proves the six emit
sites still fire.

- [ ] **Step 7: Verify the app still behaves identically**

Run: `Scripts/run.sh --reset`

Check by hand, in the running window:
- typing ASCII reaches the shell
- `cmd+v` pastes
- an input method (e.g. Pinyin) composes and commits
- arrow keys move the shell cursor
- clicking inside the terminal focuses it
- the scroll wheel scrolls

Expected: identical to before this plan. If any one of these regressed, the
outlet swap missed an emit site — `grep -n onPayload Sources/` must return
nothing.

- [ ] **Step 8: Commit**

```bash
xcodegen generate
git add Sources/HerdaKit/Terminal/TerminalInput.swift \
        Sources/HerdaKit/Terminal/TerminalGridView.swift \
        Sources/HerdaKit/Runtime/TerminalSession.swift \
        Tests/HerdaKitTests/TerminalInputTests.swift
git commit -m "refactor: have the terminal view report intent, not bytes

onPayload handed out finished InputEvents payloads. Those cannot go on a
per-pane connection: ClientInputEvents has no early return for
TerminalAttach (headless.rs:2893), so it reaches
promote_client_to_foreground, which has no guard (:1460), and the server
then relays out every pane inside the size of the one pane that sent the
key. The symptom is global and gives no way back to the keypress that
caused it.

No behaviour change here. TerminalSession converts each intent straight
back into the same bytes, and a test asserts byte equality with what the
view used to build inline, so the switchover can move the destination
without also moving the plumbing."
```

---

### Task 4: `pane.send_keys` and `pane.send_text` on `ApiClient`

**Files:**
- Modify: `Sources/HerdaKit/Protocol/ApiClient.swift` (after `closePane` at `:141`)
- Test: `Tests/HerdaKitTests/ApiClientTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/HerdaKitTests/ApiClientTests.swift`:

```swift
    func testEncodesSendKeysAsAKeyNameList() throws {
        let line = try ApiClient.requestLine(
            id: "k",
            method: "pane.send_keys",
            params: ["pane_id": "w1:p2", "keys": ["ctrl+c"]]
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["method"] as? String, "pane.send_keys")
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        XCTAssertEqual(params["pane_id"] as? String, "w1:p2")
        XCTAssertEqual(params["keys"] as? [String], ["ctrl+c"])
    }

    func testEncodesSendTextWithTheLiteralPayload() throws {
        // Text goes as text, not as a key list: herdr wraps it for bracketed
        // paste when the pane has it enabled (app/api_helpers.rs:25), which a
        // client cannot know.
        let line = try ApiClient.requestLine(
            id: "t",
            method: "pane.send_text",
            params: ["pane_id": "w1:p2", "text": "héllo 世界"]
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        XCTAssertEqual(params["text"] as? String, "héllo 世界")
    }

    func testRequestLineIsASingleLineEvenWithNewlinesInText() throws {
        // The API is newline-delimited, so an embedded newline in a paste must
        // be escaped by the JSON encoder rather than splitting the request.
        let line = try ApiClient.requestLine(
            id: "t",
            method: "pane.send_text",
            params: ["pane_id": "w1:p2", "text": "a\nb"]
        )
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1, "only the terminator")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `Scripts/test.sh 2>&1 | tail -20`
Expected: `testRequestLineIsASingleLineEvenWithNewlinesInText` passes already
(JSONSerialization escapes it), the other two fail only if the methods are
missing — they test `requestLine`, so they should pass. This is deliberate:
they pin the wire shape before the wrappers exist.

If all three pass, proceed; they are the contract for Step 3.

- [ ] **Step 3: Add the wrappers**

In `Sources/HerdaKit/Protocol/ApiClient.swift`, after `closePane` (`:141`):

```swift
    /// Sends key presses to one pane by name.
    ///
    /// herdr encodes each name with that terminal's own modes
    /// (`encode_api_keys` -> `runtime.encode_terminal_key`), which is why this
    /// is the preferred channel: application cursor mode and bracketed paste
    /// are invisible from here. Names come from `HerdrKeyName`.
    public func sendKeys(_ paneId: String, keys: [String]) throws {
        _ = try request(
            method: "pane.send_keys",
            params: ["pane_id": paneId, "keys": keys],
            id: "send-keys"
        )
    }

    /// Sends literal text to one pane. herdr wraps it for bracketed paste when
    /// the pane has that enabled (`app/api_helpers.rs:25`).
    public func sendText(_ paneId: String, text: String) throws {
        _ = try request(
            method: "pane.send_text",
            params: ["pane_id": paneId, "text": text],
            id: "send-text"
        )
    }
```

- [ ] **Step 4: Run the suite**

Run: `Scripts/test.sh 2>&1 | tail -5`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
xcodegen generate
git add Sources/HerdaKit/Protocol/ApiClient.swift Tests/HerdaKitTests/ApiClientTests.swift
git commit -m "feat: add pane.send_keys and pane.send_text to the API client

Both are addressed by pane id and encoded server-side with that terminal's
own modes, which is the whole reason input moves to the API rather than to
raw bytes on the render connection.

A test pins that a request stays one line even when the text contains a
newline: the API is newline-delimited, so an unescaped paste would split
into two requests and the second would fail to parse."
```

---

### Task 5: `PaneInputQueue` — one request at a time, in order

The API is one request per connection: `handle_connection` reads a single line
and returns (`api/server.rs:139`). Concurrent one-shot connections all funnel
through `api_tx` into the app event queue with no ordering guarantee, so fast
typing would arrive scrambled — and a scrambled character stream is close to
impossible to trace back.

Measured ceiling for serializing: p50 0.16ms per call, so roughly 6200 keys/sec.

**Files:**
- Create: `Sources/HerdaKit/Runtime/PaneInputQueue.swift`
- Test: `Tests/HerdaKitTests/PaneInputQueueTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import HerdaKit

final class PaneInputQueueTests: XCTestCase {
    /// Records what it was asked to send, and how many sends overlapped.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var inFlight = 0
        private(set) var maxInFlight = 0
        private(set) var order: [String] = []

        func send(_ label: String) {
            lock.lock()
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
            order.append(label)
            lock.unlock()
            // Long enough that an unserialized queue would overlap.
            Thread.sleep(forTimeInterval: 0.002)
            lock.lock()
            inFlight -= 1
            lock.unlock()
        }
    }

    func testSendsInSubmissionOrder() async {
        let recorder = Recorder()
        let queue = PaneInputQueue { recorder.send($0) }
        for index in 0 ..< 50 { queue.submit("k\(index)") }
        await queue.drain()

        XCTAssertEqual(recorder.order, (0 ..< 50).map { "k\($0)" })
    }

    func testNeverOverlapsTwoSends() async {
        // The reason this type exists. herdr's API is one request per
        // connection (api/server.rs:139) and concurrent connections reach the
        // app event queue in any order, so overlapping sends can reorder keys.
        let recorder = Recorder()
        let queue = PaneInputQueue { recorder.send($0) }
        for index in 0 ..< 30 { queue.submit("k\(index)") }
        await queue.drain()

        XCTAssertEqual(recorder.maxInFlight, 1)
    }

    func testKeepsGoingAfterASendThrows() async {
        // A dropped keypress must not stop the queue: one invalid_key would
        // otherwise wedge every later key in the session.
        let recorder = Recorder()
        let queue = PaneInputQueue { label in
            if label == "k1" { throw ApiClient.Failure.errorResponse("invalid_key") }
            recorder.send(label)
        }
        for index in 0 ..< 4 { queue.submit("k\(index)") }
        await queue.drain()

        XCTAssertEqual(recorder.order, ["k0", "k2", "k3"])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `Scripts/test.sh 2>&1 | tail -20`
Expected: compile failure, `cannot find 'PaneInputQueue' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Serializes input sends, in submission order, one at a time.
///
/// herdr's API is one request per connection — `handle_connection`
/// (`api/server.rs:139`) reads a single line and returns — so every send opens
/// its own socket. Those sockets all funnel through `api_tx` into the app event
/// queue with no ordering guarantee between them, which means overlapping sends
/// can deliver keys out of order. A scrambled character stream gives almost
/// nothing to debug from, so ordering is enforced here rather than hoped for.
///
/// The cost is a ceiling of one round trip per key. Measured against the
/// embedded server: p50 0.16ms, p95 0.38ms, so roughly 6200 keys/sec — three
/// orders of magnitude above human typing.
public final class PaneInputQueue: @unchecked Sendable {
    private let send: @Sendable (String) throws -> Void
    private let onFailure: (@Sendable (String, Error) -> Void)?
    /// Serial by construction: one queue, no concurrent attribute.
    private let queue = DispatchQueue(label: "app.herda.pane-input")

    public init(
        onFailure: (@Sendable (String, Error) -> Void)? = nil,
        send: @escaping @Sendable (String) throws -> Void
    ) {
        self.send = send
        self.onFailure = onFailure
    }

    /// Enqueues one payload. Returns immediately — the caller is the main actor
    /// handling a key event and must not wait on a socket.
    public func submit(_ payload: String) {
        queue.async { [send, onFailure] in
            do {
                try send(payload)
            } catch {
                // Swallowed on purpose: one rejected key must not wedge every
                // later key in the session.
                onFailure?(payload, error)
            }
        }
    }

    /// Waits for everything submitted so far. Tests only — nothing in the app
    /// blocks on input.
    func drain() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `Scripts/test.sh 2>&1 | tail -5`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
xcodegen generate
git add Sources/HerdaKit/Runtime/PaneInputQueue.swift Tests/HerdaKitTests/PaneInputQueueTests.swift
git commit -m "feat: serialize pane input sends

herdr's API is one request per connection: handle_connection
(api/server.rs:139) reads a single line and returns, and only
events.subscribe and pane.graphics.stream take the connection over. So
every send opens its own socket, and those sockets all funnel through
api_tx into the app event queue with no ordering guarantee — overlapping
sends can deliver keys out of order, and a scrambled character stream
leaves almost nothing to debug from.

The ceiling this imposes is not a constraint in practice: measured against
the embedded server, pane.send_keys is p50 0.16ms and p95 0.38ms, roughly
6200 keys/sec serialized.

A rejected send is logged and skipped rather than propagated, so one
invalid_key cannot wedge every later key in the session."
```

---

### Task 6: Prove the channel end to end against a real pane

Nothing is wired into the app yet. This task runs the new pieces against the
running server directly, so the switchover starts from measurements rather than
hope.

**Files:**
- Create: `Tests/HerdaKitTests/LivePaneInputTests.swift`

- [ ] **Step 1: Write the test, skipped unless a server is present**

```swift
import XCTest
@testable import HerdaKit

/// Runs against the app's own embedded server when one is up. Skipped
/// otherwise, so CI and a clean checkout stay green.
///
/// Uses a pane it creates and closes itself. An earlier measurement ran against
/// a live pane and left 200 stray `~` characters on the user's prompt, because
/// zsh splits ESC[15~ into an unknown sequence plus a literal tilde.
final class LivePaneInputTests: XCTestCase {
    private func liveApi() throws -> ApiClient {
        let paths = RuntimePaths.defaultLocation()
        guard FileManager.default.fileExists(atPath: paths.apiSocket.path) else {
            throw XCTSkip("no embedded server running; start it with Scripts/run.sh")
        }
        return ApiClient(socketPath: paths.apiSocket.path)
    }

    func testEveryNameHerdrKeyNameProducesIsAccepted() throws {
        // The point of the test: HerdrKeyName's vocabulary is a claim about
        // another program's parser. This checks the claim against that parser
        // instead of against a reading of it.
        let api = try liveApi()
        let scratch = try api.request(
            PaneInfoEnvelope.self,
            method: "pane.split",
            params: ["direction": "down", "focus": false],
            id: "scratch"
        ).pane
        defer { try? api.closePane(scratch.paneId) }

        let keys: [WireEncoder.Key] = [
            .enter, .escape, .backspace, .tab, .backTab,
            .left, .right, .up, .down, .function(5),
            .character("a"), .character("+"), .character(" "), .character("/"),
        ]
        for key in keys {
            for modifiers in [WireEncoder.Modifiers(), [.control], [.shift], [.option]] {
                guard let name = HerdrKeyName.name(for: key, modifiers: modifiers) else {
                    continue
                }
                XCTAssertNoThrow(
                    try api.sendKeys(scratch.paneId, keys: [name]),
                    "herdr rejected \(name)"
                )
            }
        }
    }

    func testTheSixUnnameableKeysAreStillUnnameable() throws {
        // Guards against a herdr upgrade silently adding them: if this starts
        // failing, the raw-bytes fallback can be deleted.
        let api = try liveApi()
        let scratch = try api.request(
            PaneInfoEnvelope.self,
            method: "pane.split",
            params: ["direction": "down", "focus": false],
            id: "scratch"
        ).pane
        defer { try? api.closePane(scratch.paneId) }

        for name in ["home", "end", "pageup", "pagedown", "delete", "insert"] {
            XCTAssertThrowsError(
                try api.sendKeys(scratch.paneId, keys: [name]),
                "herdr now accepts \(name) — drop it from TerminalKeyBytes"
            )
        }
    }

    func testSerializedSendsArriveInOrder() throws {
        // Ordering is the reason PaneInputQueue exists. This is the only place
        // it is checked against the real server rather than a fake.
        let api = try liveApi()
        let scratch = try api.request(
            PaneInfoEnvelope.self,
            method: "pane.split",
            params: ["direction": "down", "focus": false],
            id: "scratch"
        ).pane
        defer { try? api.closePane(scratch.paneId) }

        // Disable the shell's own line editing interference by sending a
        // comment: whatever arrives stays on one line and is never executed.
        try api.sendText(scratch.paneId, text: "# ")
        let expected = (0 ..< 60).map { String($0 % 10) }
        let queue = PaneInputQueue { text in try api.sendText(scratch.paneId, text: text) }
        for digit in expected { queue.submit(digit) }
        let drained = expectation(description: "queue drained")
        Task { await queue.drain(); drained.fulfill() }
        wait(for: [drained], timeout: 10)

        // Give the PTY a moment to render, then read the line back.
        Thread.sleep(forTimeInterval: 0.4)
        // `source` has no default in herdr's schema (api/schema/panes.rs:254) —
        // omitting it fails the request. `format` defaults to text.
        let text = try api.request(
            method: "pane.read",
            params: ["pane_id": scratch.paneId, "source": "visible", "format": "text"],
            id: "read"
        )
        XCTAssertTrue(
            text.contains("# " + expected.joined()),
            "digits arrived out of order or were dropped:\n\(text)"
        )
    }
}
```

- [ ] **Step 2: Add the response envelope the test needs**

`pane.split` answers `ResponseResult::PaneInfo { pane }`
(`app/api/panes.rs:125`), so `result` has a `pane` key and needs an envelope,
the same shape as `SessionSnapshotEnvelope`.

In `Sources/HerdaKit/Protocol/ApiTypes.swift`, alongside the existing envelopes:

```swift
/// `pane.split` and `pane.get` answer `{"pane": {...}, "type": "pane_info"}`, so
/// the pane sits one level below `result`.
public struct PaneInfoEnvelope: Decodable, Sendable {
    public let pane: PaneInfo
}
```

- [ ] **Step 3: Run with no server to confirm it skips**

```bash
pkill -9 -f 'build/Build/Products/Debug/Herda.app' || true
R="$HOME/Library/Application Support/app.herda/runtime"
[ -S "$R/herdr.sock" ] && lsof -t "$R/herdr.sock" | xargs -r kill
Scripts/test.sh 2>&1 | tail -8
```

Expected: pass, with the `LivePaneInputTests` cases reported as skipped.

- [ ] **Step 4: Run with a server to confirm it passes**

```bash
Scripts/run.sh --reset
sleep 5
Scripts/test.sh 2>&1 | tail -8
```

Expected: all pass. If `testEveryNameHerdrKeyNameProducesIsAccepted` fails, the
name in the failure message is wrong in `HerdrKeyName` — fix it there, not in
the test. If `testTheSixUnnameableKeysAreStillUnnameable` fails, herdr gained
those names and `TerminalKeyBytes` can be reduced.

- [x] **Step 5: Find out whether Home and End can be verified yet — they cannot**

The intent was to compare `ESC[H` / `ESC[F` against the DECCKM forms
`ESC OH` / `ESC OF` in real applications. Attempted through `pane.send_text`,
which was the only channel available at this stage:

```
send-text "echo abc", then ESC[H, then "X"
pane read  ->  echo abc^[[HX
```

**The escape sequence arrives as literal text.** `pane.send_text` goes through
`encode_api_text` (`app/api_helpers.rs:25`), which wraps the payload in
`ESC[200~ … ESC[201~` whenever the pane has bracketed paste enabled — and
neutralising control sequences is exactly what bracketed paste is for.

Two conclusions, both worth having:

1. **`pane.send_text` cannot carry the six keys.** It is paste semantics, not key
   semantics. This closes off the shortcut of routing them through the API, and
   confirms the spec's choice of raw `Input` on the pane's own connection.
2. **Home/End correctness cannot be measured in this plan.** Raw `Input` needs a
   `ControlTerminal` connection, which arrives in Plan 3. The check moves there,
   against `vim`, `less`, `nano` and zsh line editing, as the first thing done
   once a pane connection exists — before anything is built on top of it.

`TerminalKeyBytes` is unchanged by this: its golden bytes are still what the spec
specifies, and the open question is only whether applications accept that form.

- [ ] **Step 6: Commit**

```bash
xcodegen generate
git add Tests/HerdaKitTests/LivePaneInputTests.swift Sources/HerdaKit/Protocol/ApiTypes.swift
git commit -m "test: check the key vocabulary against herdr itself

HerdrKeyName encodes a claim about another program's parser. These tests
check it against that parser: every name the mapping can produce is sent to
a scratch pane and must be accepted, and the six it refuses to name must
still be rejected — if that second test ever fails, herdr gained the names
and the raw-bytes fallback can go.

Skipped when no embedded server is running so a clean checkout stays green.
Each case creates and closes its own pane: an earlier measurement ran
against a live pane and left 200 stray tildes on the prompt, because zsh
splits ESC[15~ into an unknown sequence plus a literal tilde."
```

---

## What this plan deliberately does not do

- **Nothing switches.** Input still goes out as `InputEvents` on the app render
  connection. `PaneInputQueue`, `HerdrKeyName` and `TerminalKeyBytes` are built
  and proven but unused. The switchover is Plan 3, after `PaneConnection` exists.
- **No `PaneTree`, no `PaneConnection`, no card grid.** Plan 2 and Plan 3.
- **No removal of the first design's code.** `FrameSlice`, `GapProbe`,
  `PaneFrameRouter`, `LayoutSnapshot` and `LayoutGeometry` all stay and keep
  working, because the app still renders through them. They come out in Plan 3,
  in the same commit that stops using them — deleting them earlier would break
  the build for no gain.

## Roadmap

| Plan | Content | Depends on |
|---|---|---|
| **1 (this)** | Input plumbing: intent outlet, key names, CSI bytes, serial queue, measured against the real server | — |
| 2 | `PaneTree` + `PaneTreeLayout`: pure split tree and point geometry, `(cols, rows)` per pane. No app change. | — |
| 3 | `PaneConnection` + `PaneSessionCoordinator` + `SplitContainerView`. Deletes the app render connection and the first design's layout code. The switchover. | 1, 2 |
| 4 | Native commands and menu bar: split, close, focus, zoom via the API | 3 |
| 5 | Interaction: divider drag, native text selection, per-pane mouse-forwarding toggle | 3 |
| 6 | Native replacements for herdr's modals, one at a time | 4 |

Plans 2 and 3 are written after this one lands, for the reason in the header:
the first design wrote four plans up front and had to correct plans 2 through 4
twice from what plan 1 measured.
