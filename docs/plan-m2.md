# M2「能用」实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 M1 的只读窗口接受键盘、鼠标、输入法与粘贴，成为一个真正能打字的终端。

**Architecture:** 沿用 M1 已打通的 `ClientProtocolConn.send` 路径，只增加编码与事件翻译。`TerminalGridView` 成为 first responder 并实现 `NSTextInputClient`：特殊键与带 ctrl/cmd 的组合直接编码为 `Key` 事件，其余交给系统输入法，由 `insertText` 产出 `TextCommit`。剪贴板双向打通（server 的 OSC 52 → `NSPasteboard`，cmd+v → `Paste`）。

**Tech Stack:** 承接 M1——Swift 6 / AppKit / Core Text / XCTest / xcodegen

前置：M1 已完成并验收（见 `plan-m1.md`）。设计见 `design.md`。

---

## 前置事实（已实测，勿重新推导）

用 `.local/charprobe`（一次性 Rust 程序）实测得出。所有字节均为 `ClientInputEvent` 裸编码；`ClientMessage::InputEvents` 需在前面加 `07`（变体）+ `01`（events 数量 1）。

| 事件 | 字节 |
|---|---|
| `Key Char('c')` +ctrl | `00 0f 63 02 00 01 00 00` |
| `Key Char('a')` 无修饰 | `00 0f 61 00 00 01 00 00` |
| `Key Enter` | `00 01 00 00 01 00 00` |
| `Key Esc` | `00 0e 00 00 01 00 00` |
| `Key Backspace` | `00 00 00 00 01 00 00` |
| `Key Tab` | `00 0a 00 00 01 00 00` |
| `Key Up` | `00 04 00 00 01 00 00` |
| `Key F(20)` +ctrl+alt | `00 10 14 06 00 01 00 00` |
| `TextCommit("a")` | `01 01 61` |
| `TextCommit("更新")` | `01 06 e6 9b b4 e6 96 b0` |
| `Paste("hi")` | `03 02 68 69` |
| `FocusGained` / `FocusLost` | `04` / `05` |
| `Mouse Down(Left)` 3,4 | `02 00 00 03 04 00` |
| `Mouse Up(Right)` 300,5 | `02 01 01 fb 2c 01 05 00` |
| `Mouse Drag(Left)` 1,2 +shift | `02 02 00 01 02 01` |
| `Mouse ScrollUp` 0,0 | `02 04 00 00 00` |
| `Mouse ScrollDown` 7,8 | `02 05 07 08 00` |

`Key` 字段顺序：`code`、`modifiers`(u8 裸字节)、`kind`(varint)、`repeat_count`(varint)、`generated_text`(Option tag)、`source`(varint)。

**`char` 编码为 UTF-8 字节且无长度前缀**——与 `String`（varint 长度 + UTF-8）不同。`ClientKeyCode` 变体序号：`Backspace`=0、`Enter`=1、`Left`=2、`Right`=3、`Up`=4、`Down`=5、`Home`=6、`End`=7、`PageUp`=8、`PageDown`=9、`Tab`=10、`BackTab`=11、`Delete`=12、`Insert`=13、`Esc`=14、`Char`=15、`F`=16、`Null`=17。

`ClientMouseKind`：`Down`=0、`Up`=1、`Drag`=2（均带 button payload）、`Moved`=3、`ScrollUp`=4、`ScrollDown`=5、`ScrollLeft`=6、`ScrollRight`=7。`ClientMouseButton`：`Left`=0、`Right`=1、`Middle`=2。

modifier 位（crossterm 0.29）：SHIFT=1、CONTROL=2、ALT=4、SUPER=8。

`ServerMessage::Clipboard`=变体 6，载荷是 base64 编码的 `String`。

## 文件结构

| 文件 | 变更 |
|---|---|
| `Sources/HerdrKit/Protocol/WireEncoder.swift` | 扩展：通用 `key`、`textCommit`、`paste`、`focus`、`mouse` |
| `Sources/HerdrKit/Protocol/WireDecoder.swift` | 扩展：解码 `Clipboard`（M1 归为 `.ignored`） |
| `Sources/HerdrKit/Protocol/WireTypes.swift` | 扩展：`ServerMessage.clipboard` case |
| `Sources/HerdrKit/Terminal/KeyMap.swift` | 新建：`NSEvent` → `ClientKeyCode` / modifiers，并判定是否绕过输入法 |
| `Sources/HerdrKit/Terminal/TerminalGridView.swift` | 扩展：first responder、键鼠事件、`NSTextInputClient`、marked text 渲染 |
| `Sources/HerdrKit/Runtime/TerminalSession.swift` | 扩展：接线输入与剪贴板 |
| `Tests/HerdrKitTests/KeyMapTests.swift` | 新建 |

---

## Task 1: 通用按键编码

**Files:**
- Modify: `macos-client/Sources/HerdrKit/Protocol/WireEncoder.swift`
- Modify: `macos-client/Tests/HerdrKitTests/WireEncoderTests.swift`

- [ ] **Step 1: 追加失败测试**

在 `WireEncoderTests` 类内追加：

```swift
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
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd macos-client && ./Scripts/test.sh -only-testing:HerdrKitTests/WireEncoderTests
```

Expected: 编译失败，`type 'WireEncoder' has no member 'key'`

- [ ] **Step 3: 实现**

在 `WireEncoder` 内追加，并让 `functionKey` 复用新实现：

```swift
    /// A key this client can send. Mirrors `ClientKeyCode`; only the variants
    /// the prototype produces are listed, with their wire indices.
    public enum Key: Equatable, Sendable {
        case backspace
        case enter
        case left
        case right
        case up
        case down
        case home
        case end
        case pageUp
        case pageDown
        case tab
        case backTab
        case delete
        case insert
        case escape
        case character(Character)
        case function(UInt8)

        var variant: UInt64 {
            switch self {
            case .backspace: return 0
            case .enter: return 1
            case .left: return 2
            case .right: return 3
            case .up: return 4
            case .down: return 5
            case .home: return 6
            case .end: return 7
            case .pageUp: return 8
            case .pageDown: return 9
            case .tab: return 10
            case .backTab: return 11
            case .delete: return 12
            case .insert: return 13
            case .escape: return 14
            case .character: return 15
            case .function: return 16
            }
        }

        /// Payload following the variant index.
        ///
        /// `Char` is raw UTF-8 with no length prefix — unlike `String`, which
        /// is length-prefixed. Measured, not inferred.
        var payload: [UInt8] {
            switch self {
            case .character(let character):
                return Array(String(character).utf8)
            case .function(let number):
                return [number]
            default:
                return []
            }
        }
    }

    public static func key(_ key: Key, modifiers: Modifiers) -> [UInt8] {
        var out = Varint.encode(Variant.inputEvents.rawValue)
        out += Varint.encode(UInt64(1))              // events.count
        out += Varint.encode(InputEvent.key.rawValue)
        out += Varint.encode(key.variant)
        out += key.payload
        out.append(modifiers.rawValue)               // u8, raw byte
        out += Varint.encode(KeyKind.press.rawValue)
        out += Varint.encode(UInt64(1))              // repeat_count: u16
        out.append(0)                                // generated_text: None
        out += Varint.encode(KeySource.synthesized.rawValue)
        return out
    }
```

然后把既有的 `functionKey` 改为转发，避免两份编码逻辑漂移：

```swift
    /// Kept for the startup sidebar toggle; delegates to `key`.
    public static func functionKey(_ number: UInt8, modifiers: Modifiers) -> [UInt8] {
        key(.function(number), modifiers: modifiers)
    }
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cd macos-client && xcodegen generate && ./Scripts/test.sh -only-testing:HerdrKitTests/WireEncoderTests
```

Expected: 全部 passed，包含 M1 原有的 `testFunctionKeyMatchesGoldenBytes`（证明转发未改变字节）

- [ ] **Step 5: 提交**

```bash
cd macos-client && git add -A && git commit -m "feat: encode arbitrary key presses"
```

---

## Task 2: 文本、粘贴与焦点编码

**Files:**
- Modify: `macos-client/Sources/HerdrKit/Protocol/WireEncoder.swift`
- Modify: `macos-client/Tests/HerdrKitTests/WireEncoderTests.swift`

- [ ] **Step 1: 追加失败测试**

```swift
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
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd macos-client && ./Scripts/test.sh -only-testing:HerdrKitTests/WireEncoderTests
```

Expected: `type 'WireEncoder' has no member 'textCommit'`

- [ ] **Step 3: 实现**

在 `WireEncoder.InputEvent` 枚举中补齐变体，并追加编码函数：

```swift
    private enum InputEvent: UInt64 {
        case key = 0
        case textCommit = 1
        case mouse = 2
        case paste = 3
        case focusGained = 4
        case focusLost = 5
    }

    private static func envelope(_ event: UInt64) -> [UInt8] {
        var out = Varint.encode(Variant.inputEvents.rawValue)
        out += Varint.encode(UInt64(1))    // events.count
        out += Varint.encode(event)
        return out
    }

    private static func string(_ text: String) -> [UInt8] {
        let bytes = Array(text.utf8)
        return Varint.encode(UInt64(bytes.count)) + bytes
    }

    /// Committed text from the input method. Unlike `Char`, `String` is
    /// length-prefixed.
    public static func textCommit(_ text: String) -> [UInt8] {
        envelope(InputEvent.textCommit.rawValue) + string(text)
    }

    public static func paste(_ text: String) -> [UInt8] {
        envelope(InputEvent.paste.rawValue) + string(text)
    }

    public static func focus(gained: Bool) -> [UInt8] {
        envelope(gained ? InputEvent.focusGained.rawValue : InputEvent.focusLost.rawValue)
    }
```

同时把 `key` 里手写的 envelope 换成 `envelope(InputEvent.key.rawValue)`，保持一处定义。

- [ ] **Step 4: 运行测试确认通过**

```bash
cd macos-client && xcodegen generate && ./Scripts/test.sh -only-testing:HerdrKitTests/WireEncoderTests
```

Expected: 全部 passed

- [ ] **Step 5: 提交**

```bash
cd macos-client && git add -A && git commit -m "feat: encode text commit, paste and focus events"
```

---

## Task 3: 鼠标事件编码

**Files:**
- Modify: `macos-client/Sources/HerdrKit/Protocol/WireEncoder.swift`
- Modify: `macos-client/Tests/HerdrKitTests/WireEncoderTests.swift`

- [ ] **Step 1: 追加失败测试**

```swift
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
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd macos-client && ./Scripts/test.sh -only-testing:HerdrKitTests/WireEncoderTests
```

Expected: `type 'WireEncoder' has no member 'mouse'`

- [ ] **Step 3: 实现**

```swift
    public enum MouseButton: UInt64, Sendable {
        case left = 0
        case right = 1
        case middle = 2
    }

    /// Mirrors `ClientMouseKind`. Down/Up/Drag carry a button payload; the
    /// scroll and moved variants do not.
    public enum MouseKind: Equatable, Sendable {
        case down(MouseButton)
        case up(MouseButton)
        case drag(MouseButton)
        case moved
        case scrollUp
        case scrollDown
        case scrollLeft
        case scrollRight

        var variant: UInt64 {
            switch self {
            case .down: return 0
            case .up: return 1
            case .drag: return 2
            case .moved: return 3
            case .scrollUp: return 4
            case .scrollDown: return 5
            case .scrollLeft: return 6
            case .scrollRight: return 7
            }
        }

        var button: MouseButton? {
            switch self {
            case .down(let button), .up(let button), .drag(let button):
                return button
            default:
                return nil
            }
        }
    }

    public static func mouse(
        _ kind: MouseKind,
        column: UInt16,
        row: UInt16,
        modifiers: Modifiers
    ) -> [UInt8] {
        var out = envelope(InputEvent.mouse.rawValue)
        out += Varint.encode(kind.variant)
        if let button = kind.button {
            out += Varint.encode(button.rawValue)
        }
        out += Varint.encode(UInt64(column))
        out += Varint.encode(UInt64(row))
        out.append(modifiers.rawValue)     // u8, raw byte
        return out
    }
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cd macos-client && xcodegen generate && ./Scripts/test.sh -only-testing:HerdrKitTests/WireEncoderTests
```

Expected: 全部 passed

- [ ] **Step 5: 提交**

```bash
cd macos-client && git add -A && git commit -m "feat: encode mouse events"
```

---

## Task 4: 解码剪贴板消息

M1 把 `Clipboard`（变体 6）归为 `.ignored`。粘贴要双向工作，需要真正解码它。

**Files:**
- Modify: `macos-client/Sources/HerdrKit/Protocol/WireTypes.swift`
- Modify: `macos-client/Sources/HerdrKit/Protocol/WireDecoder.swift`
- Modify: `macos-client/Tests/HerdrKitTests/WireDecoderTests.swift`

- [ ] **Step 1: 追加失败测试**

```swift
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
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd macos-client && ./Scripts/test.sh -only-testing:HerdrKitTests/WireDecoderTests
```

Expected: `type 'ServerMessage' has no member 'clipboard'`

- [ ] **Step 3: 实现**

`WireTypes.swift` 的 `ServerMessage` 增加一个 case：

```swift
    case clipboard(base64: String)
```

`WireDecoder` 的 `Variant` 增加 `case clipboard = 6`，并在 switch 中处理：

```swift
        case .clipboard:
            let base64 = try reader.string()
            try reader.requireFullyConsumed()
            return .clipboard(base64: base64)
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cd macos-client && xcodegen generate && ./Scripts/test.sh -only-testing:HerdrKitTests/WireDecoderTests
```

Expected: 全部 passed。注意 M1 的 `testIgnoresUnhandledVariantsWithoutInspectingPayload` 不涉及变体 6，无需改动。

- [ ] **Step 5: 提交**

```bash
cd macos-client && git add -A && git commit -m "feat: decode clipboard messages from the server"
```

---

## Task 5: NSEvent 到按键的映射

纯函数，是 M2 最容易出错的逻辑，也是唯一值得重点测试的部分。

**Files:**
- Create: `macos-client/Sources/HerdrKit/Terminal/KeyMap.swift`
- Create: `macos-client/Tests/HerdrKitTests/KeyMapTests.swift`

- [ ] **Step 1: 写失败测试**

`Tests/HerdrKitTests/KeyMapTests.swift`:

```swift
import AppKit
import XCTest
@testable import HerdrKit

final class KeyMapTests: XCTestCase {
    func testTranslatesModifierFlags() {
        XCTAssertEqual(KeyMap.modifiers(from: []), [])
        XCTAssertEqual(KeyMap.modifiers(from: .shift), .shift)
        XCTAssertEqual(KeyMap.modifiers(from: .control), .control)
        XCTAssertEqual(KeyMap.modifiers(from: .option), .option)
        XCTAssertEqual(KeyMap.modifiers(from: .command), .command)
        XCTAssertEqual(
            KeyMap.modifiers(from: [.control, .option]),
            [.control, .option]
        )
    }

    func testIgnoresNonInputModifierFlags() {
        // capsLock, numericPad, function etc. have no wire representation.
        XCTAssertEqual(KeyMap.modifiers(from: [.capsLock, .numericPad, .control]), .control)
    }

    func testMapsSpecialKeyCodes() {
        XCTAssertEqual(KeyMap.specialKey(forKeyCode: 36), .enter)        // Return
        XCTAssertEqual(KeyMap.specialKey(forKeyCode: 76), .enter)        // Keypad Enter
        XCTAssertEqual(KeyMap.specialKey(forKeyCode: 48), .tab)
        XCTAssertEqual(KeyMap.specialKey(forKeyCode: 51), .backspace)    // Delete key
        XCTAssertEqual(KeyMap.specialKey(forKeyCode: 117), .delete)      // Forward delete
        XCTAssertEqual(KeyMap.specialKey(forKeyCode: 53), .escape)
        XCTAssertEqual(KeyMap.specialKey(forKeyCode: 123), .left)
        XCTAssertEqual(KeyMap.specialKey(forKeyCode: 124), .right)
        XCTAssertEqual(KeyMap.specialKey(forKeyCode: 126), .up)
        XCTAssertEqual(KeyMap.specialKey(forKeyCode: 125), .down)
        XCTAssertEqual(KeyMap.specialKey(forKeyCode: 115), .home)
        XCTAssertEqual(KeyMap.specialKey(forKeyCode: 119), .end)
        XCTAssertEqual(KeyMap.specialKey(forKeyCode: 116), .pageUp)
        XCTAssertEqual(KeyMap.specialKey(forKeyCode: 121), .pageDown)
    }

    func testMapsFunctionKeyCodes() {
        XCTAssertEqual(KeyMap.specialKey(forKeyCode: 122), .function(1))
        XCTAssertEqual(KeyMap.specialKey(forKeyCode: 120), .function(2))
        XCTAssertEqual(KeyMap.specialKey(forKeyCode: 111), .function(12))
    }

    func testReturnsNilForOrdinaryLetters() {
        XCTAssertNil(KeyMap.specialKey(forKeyCode: 0))   // 'a'
        XCTAssertNil(KeyMap.specialKey(forKeyCode: 8))   // 'c'
    }

    func testControlledLetterBypassesInputMethod() {
        // ctrl+c must reach the pane as Char('c') + CONTROL, not as text.
        let decision = KeyMap.decide(
            keyCode: 8,
            charactersIgnoringModifiers: "c",
            flags: .control
        )
        XCTAssertEqual(decision, .send(.character("c"), [.control]))
    }

    func testCommandedLetterBypassesInputMethod() {
        let decision = KeyMap.decide(
            keyCode: 8,
            charactersIgnoringModifiers: "c",
            flags: .command
        )
        XCTAssertEqual(decision, .send(.character("c"), [.command]))
    }

    func testSpecialKeyBypassesInputMethodEvenWithoutModifiers() {
        XCTAssertEqual(
            KeyMap.decide(keyCode: 36, charactersIgnoringModifiers: "\r", flags: []),
            .send(.enter, [])
        )
        XCTAssertEqual(
            KeyMap.decide(keyCode: 126, charactersIgnoringModifiers: nil, flags: []),
            .send(.up, [])
        )
    }

    func testSpecialKeyKeepsItsModifiers() {
        XCTAssertEqual(
            KeyMap.decide(keyCode: 126, charactersIgnoringModifiers: nil, flags: .shift),
            .send(.up, .shift)
        )
    }

    func testPlainLetterGoesToInputMethod() {
        // Must not be sent directly: the input method may compose it.
        XCTAssertEqual(
            KeyMap.decide(keyCode: 0, charactersIgnoringModifiers: "a", flags: []),
            .inputMethod
        )
    }

    func testOptionedLetterGoesToInputMethod() {
        // option+e is a dead key on many layouts; let the IME own it.
        XCTAssertEqual(
            KeyMap.decide(keyCode: 14, charactersIgnoringModifiers: "e", flags: .option),
            .inputMethod
        )
    }

    func testShiftedLetterGoesToInputMethod() {
        XCTAssertEqual(
            KeyMap.decide(keyCode: 0, charactersIgnoringModifiers: "a", flags: .shift),
            .inputMethod
        )
    }

    func testUnknownKeyWithoutCharactersIsDropped() {
        XCTAssertEqual(
            KeyMap.decide(keyCode: 999, charactersIgnoringModifiers: nil, flags: []),
            .ignore
        )
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd macos-client && ./Scripts/test.sh -only-testing:HerdrKitTests/KeyMapTests
```

Expected: `cannot find 'KeyMap' in scope`

- [ ] **Step 3: 实现**

`Sources/HerdrKit/Terminal/KeyMap.swift`:

```swift
import AppKit

/// Translates AppKit key events into wire keys, and decides which events must
/// bypass the input method.
///
/// A terminal cannot route everything through the IME: ctrl+c has to reach the
/// pane as a key press, not as composed text. Conversely plain letters must go
/// through the IME, or CJK composition never happens.
public enum KeyMap {
    public enum Decision: Equatable {
        /// Encode and send immediately.
        case send(WireEncoder.Key, WireEncoder.Modifiers)
        /// Hand to `NSTextInputContext`; expect `insertText`/`setMarkedText`.
        case inputMethod
        /// Nothing meaningful to send.
        case ignore
    }

    public static func modifiers(from flags: NSEvent.ModifierFlags) -> WireEncoder.Modifiers {
        var result: WireEncoder.Modifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }

    /// Virtual key codes are layout-independent, so this mapping holds across
    /// keyboard layouts where `characters` would not.
    public static func specialKey(forKeyCode keyCode: UInt16) -> WireEncoder.Key? {
        switch keyCode {
        case 36, 76: return .enter
        case 48: return .tab
        case 51: return .backspace
        case 117: return .delete
        case 53: return .escape
        case 123: return .left
        case 124: return .right
        case 126: return .up
        case 125: return .down
        case 115: return .home
        case 119: return .end
        case 116: return .pageUp
        case 121: return .pageDown
        case 122: return .function(1)
        case 120: return .function(2)
        case 99: return .function(3)
        case 118: return .function(4)
        case 96: return .function(5)
        case 97: return .function(6)
        case 98: return .function(7)
        case 100: return .function(8)
        case 101: return .function(9)
        case 109: return .function(10)
        case 103: return .function(11)
        case 111: return .function(12)
        default: return nil
        }
    }

    public static func decide(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        flags: NSEvent.ModifierFlags
    ) -> Decision {
        let mods = modifiers(from: flags)

        if let special = specialKey(forKeyCode: keyCode) {
            return .send(special, mods)
        }

        // ctrl and cmd combinations are commands, never composable text.
        let isCommandLike = flags.contains(.control) || flags.contains(.command)
        if isCommandLike,
           let characters = charactersIgnoringModifiers,
           let character = characters.first
        {
            return .send(.character(character), mods)
        }

        if charactersIgnoringModifiers?.isEmpty == false {
            return .inputMethod
        }
        return .ignore
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cd macos-client && xcodegen generate && ./Scripts/test.sh -only-testing:HerdrKitTests/KeyMapTests
```

Expected: 14 个 test case passed

- [ ] **Step 5: 提交**

```bash
cd macos-client && git add -A && git commit -m "feat: map appkit key events to wire keys"
```

---

## Task 6: 视图接收键盘事件

**Files:**
- Modify: `macos-client/Sources/HerdrKit/Terminal/TerminalGridView.swift`

- [ ] **Step 1: 让视图可获得焦点并转发按键**

在 `TerminalGridView` 内追加：

```swift
    /// Set by the session; receives encoded payloads ready for the socket.
    public var onPayload: (@Sendable ([UInt8]) -> Void)?

    public override var acceptsFirstResponder: Bool { true }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // SwiftUI does not focus an NSViewRepresentable automatically.
        window?.makeFirstResponder(self)
    }

    public override func keyDown(with event: NSEvent) {
        switch KeyMap.decide(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            flags: event.modifierFlags
        ) {
        case .send(let key, let modifiers):
            onPayload?(WireEncoder.key(key, modifiers: modifiers))
        case .inputMethod:
            // Produces insertText or setMarkedText (Task 7).
            inputContext?.handleEvent(event)
        case .ignore:
            break
        }
    }

    /// Swallow the system beep for keys the pane consumes.
    public override func doCommand(by selector: Selector) {}
```

- [ ] **Step 2: 构建确认无错**

```bash
cd macos-client && xcodegen generate && ./Scripts/test.sh
```

Expected: `** TEST SUCCEEDED **`（既有测试不受影响）

- [ ] **Step 3: 提交**

```bash
cd macos-client && git add -A && git commit -m "feat: accept keyboard focus and forward key presses"
```

---

## Task 7: 输入法支持（NSTextInputClient）

没有这一步中文输入完全不可用。

**Files:**
- Modify: `macos-client/Sources/HerdrKit/Terminal/TerminalGridView.swift`

- [ ] **Step 1: 实现协议**

```swift
extension TerminalGridView: NSTextInputClient {
    /// Composition finished: send the committed text.
    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        switch string {
        case let value as String: text = value
        case let value as NSAttributedString: text = value.string
        default: return
        }
        markedText = ""
        needsDisplay = true
        guard !text.isEmpty else { return }
        onPayload?(WireEncoder.textCommit(text))
    }

    /// Composition in progress: hold the provisional text for drawing.
    public func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        switch string {
        case let value as String: markedText = value
        case let value as NSAttributedString: markedText = value.string
        default: markedText = ""
        }
        needsDisplay = true
    }

    public func unmarkText() {
        markedText = ""
        needsDisplay = true
    }

    public func hasMarkedText() -> Bool { !markedText.isEmpty }

    public func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0)
                           : NSRange(location: 0, length: markedText.utf16.count)
    }

    public func selectedRange() -> NSRange {
        NSRange(location: markedText.utf16.count, length: 0)
    }

    public func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? { nil }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// Positions the candidate window at the cursor. Without this it appears in
    /// a corner of the screen, which makes CJK input unusable in practice.
    public func firstRect(
        forCharacterRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSRect {
        let cursor = currentFrame?.cursor
        let column = CGFloat(cursor?.column ?? 0)
        let row = CGFloat(cursor?.row ?? 0)
        let local = CGRect(
            x: column * cellSize.width,
            y: row * cellSize.height,
            width: cellSize.width * CGFloat(max(1, markedText.count)),
            height: cellSize.height
        )
        let inWindow = convert(local, to: nil)
        return window?.convertToScreen(inWindow) ?? inWindow
    }

    public func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}
```

在类内加存储属性：

```swift
    /// Provisional input-method text, drawn at the cursor until committed.
    var markedText: String = ""
```

- [ ] **Step 2: 构建确认无错**

```bash
cd macos-client && xcodegen generate && ./Scripts/test.sh
```

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 3: 提交**

```bash
cd macos-client && git add -A && git commit -m "feat: support input method composition"
```

---

## Task 8: 绘制预编辑文本

`markedText` 若不绘制，用户在候选确认前看不到自己打了什么。

**Files:**
- Modify: `macos-client/Sources/HerdrKit/Terminal/TerminalGridView.swift`

- [ ] **Step 1: 在 draw 末尾绘制**

把 `draw(_:)` 里 `drawCursor(grid)` 一行替换为：

```swift
        drawCursor(grid)
        drawMarkedText(grid)
```

并追加方法：

```swift
    /// Draws in-progress input-method text at the cursor, underlined, so the
    /// user can see the composition before committing it.
    private func drawMarkedText(_ grid: GridFrame) {
        guard !markedText.isEmpty else { return }
        let column = CGFloat(grid.cursor?.column ?? 0)
        let row = CGFloat(grid.cursor?.row ?? 0)

        let columns = markedText.reduce(into: 0) { total, character in
            total += CharWidth.displayWidth(of: String(character))
        }
        let rect = CGRect(
            x: column * cellSize.width,
            y: row * cellSize.height,
            width: cellSize.width * CGFloat(max(1, columns)),
            height: cellSize.height
        )

        defaultBackground.setFill()
        rect.fill()

        (markedText as NSString).draw(
            at: CGPoint(x: rect.minX, y: rect.minY),
            withAttributes: [
                .font: regularFont,
                .foregroundColor: defaultForeground,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
        )
    }
```

- [ ] **Step 2: 构建确认无错**

```bash
cd macos-client && xcodegen generate && ./Scripts/test.sh
```

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 3: 提交**

```bash
cd macos-client && git add -A && git commit -m "feat: draw in-progress input method text"
```

---

## Task 9: 鼠标事件与坐标换算

**Files:**
- Modify: `macos-client/Sources/HerdrKit/Terminal/TerminalGridView.swift`
- Modify: `macos-client/Tests/HerdrKitTests/TerminalGridViewTests.swift`

- [ ] **Step 1: 追加坐标换算测试**

```swift
    func testConvertsPointToCellCoordinates() {
        let subject = view
        let cell = subject.cellSize
        let point = CGPoint(x: cell.width * 3 + 2, y: cell.height * 5 + 2)
        let position = subject.cellPosition(for: point)
        XCTAssertEqual(position.column, 3)
        XCTAssertEqual(position.row, 5)
    }

    func testClampsNegativeCoordinatesToOrigin() {
        let position = view.cellPosition(for: CGPoint(x: -50, y: -50))
        XCTAssertEqual(position.column, 0)
        XCTAssertEqual(position.row, 0)
    }

    func testCellPositionAtExactBoundaryBelongsToNextCell() {
        let subject = view
        let cell = subject.cellSize
        let position = subject.cellPosition(for: CGPoint(x: cell.width, y: cell.height))
        XCTAssertEqual(position.column, 1)
        XCTAssertEqual(position.row, 1)
    }
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd macos-client && ./Scripts/test.sh -only-testing:HerdrKitTests/TerminalGridViewTests
```

Expected: `value of type 'TerminalGridView' has no member 'cellPosition'`

- [ ] **Step 3: 实现**

```swift
    /// Converts a point in view coordinates to a cell position. The view is
    /// flipped, so y increases downward and matches the row order directly.
    public func cellPosition(for point: CGPoint) -> (column: UInt16, row: UInt16) {
        let column = max(0, Int(point.x / cellSize.width))
        let row = max(0, Int(point.y / cellSize.height))
        return (
            UInt16(min(column, Int(UInt16.max))),
            UInt16(min(row, Int(UInt16.max)))
        )
    }

    private func sendMouse(_ kind: WireEncoder.MouseKind, _ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let position = cellPosition(for: point)
        onPayload?(
            WireEncoder.mouse(
                kind,
                column: position.column,
                row: position.row,
                modifiers: KeyMap.modifiers(from: event.modifierFlags)
            )
        )
    }

    public override func mouseDown(with event: NSEvent) { sendMouse(.down(.left), event) }
    public override func mouseUp(with event: NSEvent) { sendMouse(.up(.left), event) }
    public override func mouseDragged(with event: NSEvent) { sendMouse(.drag(.left), event) }
    public override func rightMouseDown(with event: NSEvent) { sendMouse(.down(.right), event) }
    public override func rightMouseUp(with event: NSEvent) { sendMouse(.up(.right), event) }

    public override func scrollWheel(with event: NSEvent) {
        // One event per notch; herdr treats each as a discrete scroll step.
        if event.scrollingDeltaY > 0 {
            sendMouse(.scrollUp, event)
        } else if event.scrollingDeltaY < 0 {
            sendMouse(.scrollDown, event)
        }
        if event.scrollingDeltaX > 0 {
            sendMouse(.scrollLeft, event)
        } else if event.scrollingDeltaX < 0 {
            sendMouse(.scrollRight, event)
        }
    }
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cd macos-client && xcodegen generate && ./Scripts/test.sh -only-testing:HerdrKitTests/TerminalGridViewTests
```

Expected: 8 个 test case passed

- [ ] **Step 5: 提交**

```bash
cd macos-client && git add -A && git commit -m "feat: forward mouse events with cell coordinates"
```

---

## Task 10: 接线输入与焦点

**Files:**
- Modify: `macos-client/Sources/HerdrKit/Runtime/TerminalSession.swift`
- Modify: `macos-client/Sources/HerdrPrototype/ContentView.swift`

- [ ] **Step 1: 在 session 里接线**

在 `TerminalSession.attach` 里，`state = .running` 之后追加：

```swift
        view.onPayload = { [weak self] payload in
            Task { @MainActor in self?.send(payload) }
        }
```

并追加方法：

```swift
    /// Sends an already-encoded payload. Input failures are logged rather than
    /// surfaced: a dropped keypress must not tear down the session.
    private func send(_ payload: [UInt8]) {
        guard let connection else { return }
        do {
            try connection.send(payload)
        } catch {
            log("input send failed: \(error)")
        }
    }

    public func reportFocus(gained: Bool) {
        guard case .running = state else { return }
        send(WireEncoder.focus(gained: gained))
    }
```

- [ ] **Step 2: 在视图层报告窗口焦点**

`ContentView` 的 `GridViewRepresentable` 之后追加窗口焦点监听：

```swift
                    .onReceive(
                        NotificationCenter.default.publisher(
                            for: NSWindow.didBecomeKeyNotification
                        )
                    ) { _ in session.reportFocus(gained: true) }
                    .onReceive(
                        NotificationCenter.default.publisher(
                            for: NSWindow.didResignKeyNotification
                        )
                    ) { _ in session.reportFocus(gained: false) }
```

并在 `ContentView` 顶部加 `import Combine`。

- [ ] **Step 3: 构建并跑测试**

```bash
cd macos-client && xcodegen generate && ./Scripts/test.sh
```

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 4: 端到端手动验证打字**

```bash
cd macos-client && xcodebuild -project macos-client.xcodeproj -scheme HerdrPrototype -configuration Debug -derivedDataPath build build 2>&1 | tail -2 && open build/Build/Products/Debug/HerdrPrototype.app
```

在窗口里输入 `echo hello` 并按回车。

Expected: 字符出现在终端里，回车后 shell 执行并回显 `hello`。若无反应，先确认视图拿到了 first responder（点一下窗口内容区再试）。

- [ ] **Step 5: 提交**

```bash
cd macos-client && git add -A && git commit -m "feat: wire input and window focus into the session"
```

---

## Task 11: 剪贴板双向

**Files:**
- Modify: `macos-client/Sources/HerdrKit/Runtime/TerminalSession.swift`
- Modify: `macos-client/Sources/HerdrKit/Terminal/TerminalGridView.swift`

- [ ] **Step 1: server → 系统剪贴板**

`TerminalSession.attach` 的 `startReadLoop` 需要处理新的 `.clipboard` 消息。`ClientProtocolConn.startReadLoop` 目前只暴露 frame/shutdown/failure，因此先给它加一个回调参数：

在 `ClientProtocolConn.startReadLoop` 的签名中加入

```swift
        onClipboard: @escaping @Sendable (String) -> Void,
```

并在其 switch 中把

```swift
                    case .welcome, .ignored:
                        continue
```

替换为

```swift
                    case .clipboard(let base64):
                        onClipboard(base64)
                    case .welcome, .ignored:
                        continue
```

`TerminalSession.attach` 传入：

```swift
            onClipboard: { [weak self] base64 in
                Task { @MainActor in self?.copyToPasteboard(base64: base64) }
            },
```

并追加：

```swift
    /// herdr forwards OSC 52 as base64. Decode failures are ignored — a bad
    /// clipboard payload is not worth interrupting the session for.
    private func copyToPasteboard(base64: String) {
        guard let data = Data(base64Encoded: base64),
              let text = String(data: data, encoding: .utf8)
        else {
            log("clipboard payload was not valid base64 utf8")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
```

- [ ] **Step 2: cmd+v → Paste 事件**

`KeyMap.decide` 会把 cmd+v 判为 `.send(.character("v"), .command)`，但粘贴应读取本地剪贴板。在 `TerminalGridView.keyDown` 方法体的**最开头**（`switch KeyMap.decide(...)` 之前）插入拦截：

```swift
        // cmd+v is handled locally: the pane cannot read the host pasteboard.
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "v"
        {
            if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
                onPayload?(WireEncoder.paste(text))
            }
            return
        }
```

- [ ] **Step 3: 构建并跑测试**

```bash
cd macos-client && xcodegen generate && ./Scripts/test.sh
```

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 4: 提交**

```bash
cd macos-client && git add -A && git commit -m "feat: bridge clipboard in both directions"
```

---

## Task 12: M2 验收

- [ ] **Step 1: 全量测试**

```bash
cd macos-client && ./Scripts/test.sh 2>&1 | grep -cE "Test Case.*passed"
```

Expected: 数量不少于 M1 的 85 个，且 `** TEST SUCCEEDED **`

- [ ] **Step 2: 启动并逐项验收**

```bash
cd macos-client && xcodebuild -project macos-client.xcodeproj -scheme HerdrPrototype -configuration Debug -derivedDataPath build build 2>&1 | tail -2 && open build/Build/Products/Debug/HerdrPrototype.app
```

- [ ] 打字有回显，延迟主观无感
- [ ] 回车执行命令
- [ ] Backspace / 方向键 / Tab 补全工作
- [ ] `ctrl+c` 能中断运行中的命令（跑 `sleep 30` 再按）
- [ ] `ctrl+b` 前缀键进入 herdr prefix 模式（按 `ctrl+b` 再按 `?` 应出现帮助面板）
- [ ] 中文输入法能输入并 commit，候选窗口出现在光标附近
- [ ] 预编辑文本在确认前可见（带下划线）
- [ ] 鼠标点击能切换 herdr 焦点；滚轮能滚动 pane 历史
- [ ] cmd+v 能粘贴系统剪贴板内容
- [ ] 窗口 resize 后内容重排且不错位

- [ ] **Step 3: 记录验收结果**

把结果写入本文件末尾的「M2 验收结果」小节，未达成项写明现象与已排除的可能。若发现 UI 层异常且无法从数据侧定位，**尽早请人描述所见**——M1 的 onboarding 问题就是这样才定位的。

- [ ] **Step 4: 清理原型进程**

```bash
pkill -x HerdrPrototype; sleep 2; pkill -f "herdr server" 2>/dev/null; echo cleaned
```

- [ ] **Step 5: 提交**

```bash
cd macos-client && git add -A && git commit -m "docs: record M2 acceptance results"
```

---

## 自检结果

**Spec 覆盖对照**（design.md §7 的 M2 条目）

| 设计要求 | 对应 task |
|---|---|
| 键盘 → `InputEvents` | Task 1、5、6 |
| IME → `TextCommit` | Task 7 |
| 预编辑可见 | Task 8 |
| 鼠标 → `InputEvents` | Task 3、9 |
| 剪贴板 | Task 4、11 |
| `Resize` | M1 已实现并接线，Task 12 验收 |
| 不需要拦截 `prefix+b` | 已由 M1 的 `ctrl+alt+f20` 绑定消除，无需 task |
| `Char` 编码 | Task 1，用实测字节 |

**范围外（有意不做）**：图片粘贴（`ClipboardImage`）、`Mouse Moved`（herdr 仅在鼠标 UI 激活时需要，原型不涉及）、Kitty keyboard report-all、按键重复（`repeat_count` 固定为 1）。

**类型一致性**：`WireEncoder.Key` / `Modifiers` / `MouseKind` / `MouseButton`、`KeyMap.Decision`、`ServerMessage.clipboard`、`TerminalGridView.onPayload` / `cellPosition` / `markedText` 在各 task 间命名一致。Task 11 修改 `ClientProtocolConn.startReadLoop` 签名，其唯一调用方是 `TerminalSession.attach`，同一 task 内一并更新。
