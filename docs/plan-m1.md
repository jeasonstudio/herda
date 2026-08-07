# M1「能看到画面」实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 做出一个 macOS app，它拉起自己内嵌的 herdr server，连上 client socket，把 herdr 的终端区 cell grid 用 Core Text 画在原生窗口里。

**Architecture:** App 是 herdr server 的父进程，用 `XDG_CONFIG_HOME` / `XDG_STATE_HOME` / `HERDR_SESSION` 三个环境变量与开发机上已有的 herdr session 完全隔离。逻辑全部放在 `HerdrKit` framework（app target 只有 UI 入口），使单元测试无需 host app、不会误启动真实 server。协议走纯 Swift 手写的 bincode 2 `standard` 编解码 + `[u32 LE length][payload]` framing。

**Tech Stack:** Swift 6 / AppKit + SwiftUI / Core Text / XCTest / xcodegen / POSIX Unix domain socket

参见设计文档 `docs/design.md`。本计划只覆盖 M1；M2（输入）与 M3（侧边栏）待 M1 验收后另写。

---

## 前置事实（已实证，实现时不必重新查证）

- 协议版本 `PROTOCOL_VERSION = 19`
- framing：`[u32 LE length][bincode payload]`
- bincode 2 `standard`：整数 varint 小端；`u8` 与 `bool` 为单字节（不参与 varint）
- varint 首字节：`0...250` 即值本身；`251` 后随 u16 LE；`252` 后随 u32 LE；`253` 后随 u64 LE
- `String` / `Vec<T>`：varint 长度 + 内容；`Option`：`0` / `1` tag；enum：变体序号 varint
- `ClientMessage` 变体：`Hello`=0、`Input`=1、`Resize`=3、`Detach`=4、`InputEvents`=7
- `ServerMessage` 变体：`Welcome`=0、`Frame`=1、`ServerShutdown`=4、`Notify`=5、`Clipboard`=6、`WindowTitle`=7、`MouseCapture`=9
- `ClientInputEvent` 变体：`Key`=0、`TextCommit`=1、`Mouse`=2、`Paste`=3、`FocusGained`=4、`FocusLost`=5
- `ClientKeyCode` 变体：`Backspace`=0 … `Esc`=14、`Char`=15、`F`=16、`Null`=17
- `ClientKeyKind`：`Press`=0；`ClientKeySource`：`Synthesized`=0
- `modifiers: u8` 为 crossterm 0.29 位：SHIFT=1、CONTROL=2、ALT=4、SUPER=8 → `ctrl+alt` = `6`
- 颜色 packed u32：高位 tag `0x00` 命名色（低字节 0…16）、`0x01` 调色板索引、`0x02` RGB（低 3 字节）
- `modifier: u16`：ratatui `Modifier` 位，underline style 占高 4 位（shift 12、mask `0xF000`）
- **宽字符占位 cell 是普通空格且 `skip == false`**，协议不标记它，必须自行按显示宽度跳过

## 文件结构

| 文件 | 职责 |
|---|---|
| `project.yml` | xcodegen 输入，定义三个 target |
| `Scripts/test.sh` | 跑测试并过滤 xcodebuild 噪音 |
| `Sources/HerdrKit/Protocol/Varint.swift` | varint 编码 |
| `Sources/HerdrKit/Protocol/ByteReader.swift` | 读游标 + varint/string/option 解码 |
| `Sources/HerdrKit/Protocol/Framing.swift` | 长度前缀封帧 |
| `Sources/HerdrKit/Protocol/WireTypes.swift` | `GridFrame` / `GridCell` / `GridCursor` / `ServerMessage` |
| `Sources/HerdrKit/Protocol/WireEncoder.swift` | `ClientMessage` 编码 |
| `Sources/HerdrKit/Protocol/WireDecoder.swift` | `ServerMessage` 解码 |
| `Sources/HerdrKit/Protocol/UnixSocket.swift` | POSIX Unix domain socket 封装 |
| `Sources/HerdrKit/Protocol/ClientProtocolConn.swift` | 握手与收发循环 |
| `Sources/HerdrKit/Runtime/RuntimePaths.swift` | 隔离目录、socket 路径、config.toml 生成 |
| `Sources/HerdrKit/Runtime/HerdrRuntime.swift` | server 进程 spawn / 监控 / 停止 |
| `Sources/HerdrKit/Terminal/TerminalColor.swift` | packed u32 → `NSColor` |
| `Sources/HerdrKit/Terminal/CharWidth.swift` | 字符显示宽度 |
| `Sources/HerdrKit/Terminal/TerminalGridView.swift` | `GridFrame` → Core Text 绘制 |
| `Sources/HerdrPrototype/HerdrPrototypeApp.swift` | `@main`、窗口 |
| `Sources/HerdrPrototype/ContentView.swift` | 终端区容器、启动编排、错误展示 |

---

## Task 1: 项目脚手架与空窗口

**Files:**
- Create: `macos-client/.gitignore`
- Create: `macos-client/project.yml`
- Create: `macos-client/Scripts/test.sh`
- Create: `macos-client/Sources/HerdrKit/HerdrKit.swift`
- Create: `macos-client/Sources/HerdrPrototype/HerdrPrototypeApp.swift`
- Create: `macos-client/Sources/HerdrPrototype/ContentView.swift`
- Create: `macos-client/Tests/HerdrKitTests/SmokeTests.swift`

- [ ] **Step 1: 写 `.gitignore`**

```gitignore
# xcodegen output — regenerate with `xcodegen generate`
*.xcodeproj

# build artifacts
build/
DerivedData/
.DS_Store

# xcode user state
xcuserdata/
*.xcworkspace/xcuserdata/
```

- [ ] **Step 2: 写 `project.yml`**

```yaml
name: macos-client

options:
  bundleIdPrefix: dev.herdr
  deploymentTarget:
    macOS: "14.0"
  createIntermediateGroups: true

settings:
  base:
    SWIFT_VERSION: "6.0"
    CODE_SIGN_IDENTITY: "-"
    CODE_SIGNING_REQUIRED: "NO"
    ENABLE_HARDENED_RUNTIME: "NO"

targets:
  HerdrKit:
    type: framework
    platform: macOS
    sources:
      - path: Sources/HerdrKit
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.herdr.HerdrKit

  HerdrPrototype:
    type: application
    platform: macOS
    sources:
      - path: Sources/HerdrPrototype
    dependencies:
      - target: HerdrKit
        embed: true
    info:
      path: Sources/HerdrPrototype/Info.plist
      properties:
        CFBundleName: HerdrPrototype
        CFBundleDisplayName: Herdr Prototype
        NSHighResolutionCapable: true
        NSPrincipalClass: NSApplication
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.herdr.macos-client-prototype

  HerdrKitTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: Tests/HerdrKitTests
    dependencies:
      - target: HerdrKit

schemes:
  HerdrPrototype:
    build:
      targets:
        HerdrPrototype: all
        HerdrKitTests: [test]
    run:
      config: Debug
    test:
      config: Debug
      targets:
        - HerdrKitTests
```

注意：`HerdrKitTests` 只依赖 `HerdrKit`，**不依赖 app target**。这样它是 logic test bundle，不会以 app 为 test host，跑测试不会启动 app、不会 spawn server。

`ENABLE_HARDENED_RUNTIME: NO` 与不配置 entitlements 是必需的——原型要 spawn 子进程并连 Unix socket，沙盒会阻止。

- [ ] **Step 3: 写 `Scripts/test.sh`**

```bash
#!/usr/bin/env bash
# Runs the HerdrKit unit tests and filters xcodebuild noise.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodebuild test \
  -project macos-client.xcodeproj \
  -scheme HerdrPrototype \
  -destination 'platform=macOS' \
  "$@" \
  2>&1 | grep -E "Test Suite|Test Case|error:|\*\* TEST" || true
```

- [ ] **Step 4: 写 framework 占位与 app 入口**

`Sources/HerdrKit/HerdrKit.swift`:

```swift
import Foundation

/// Marker for the HerdrKit framework. Real types live in Protocol/, Runtime/, Terminal/.
public enum HerdrKit {
    /// Client protocol version this build speaks. Must match the bundled herdr binary.
    public static let protocolVersion: UInt32 = 19
}
```

`Sources/HerdrPrototype/HerdrPrototypeApp.swift`:

```swift
import SwiftUI

@main
struct HerdrPrototypeApp: App {
    var body: some Scene {
        WindowGroup("Herdr Prototype") {
            ContentView()
                .frame(minWidth: 800, minHeight: 500)
        }
    }
}
```

`Sources/HerdrPrototype/ContentView.swift`:

```swift
import HerdrKit
import SwiftUI

struct ContentView: View {
    var body: some View {
        Text("herdr protocol v\(HerdrKit.protocolVersion)")
            .font(.system(.body, design: .monospaced))
    }
}
```

- [ ] **Step 5: 写 smoke 测试**

`Tests/HerdrKitTests/SmokeTests.swift`:

```swift
import XCTest
@testable import HerdrKit

final class SmokeTests: XCTestCase {
    func testProtocolVersionIsPinnedTo19() {
        XCTAssertEqual(HerdrKit.protocolVersion, 19)
    }
}
```

- [ ] **Step 6: 生成工程并构建**

```bash
cd macos-client && chmod +x Scripts/test.sh && xcodegen generate
```

Expected: `Created project at .../macos-client.xcodeproj`

- [ ] **Step 7: 跑测试验证基础设施可用**

```bash
cd macos-client && ./Scripts/test.sh
```

Expected: 出现 `Test Case '-[SmokeTests testProtocolVersionIsPinnedTo19]' passed` 与 `** TEST SUCCEEDED **`

- [ ] **Step 8: 手动确认窗口能开**

```bash
cd macos-client && xcodebuild -project macos-client.xcodeproj -scheme HerdrPrototype -configuration Debug -derivedDataPath build build 2>&1 | tail -3 && open build/Build/Products/Debug/HerdrPrototype.app
```

Expected: 一个窗口出现，显示 `herdr protocol v19`。确认后关闭窗口。

- [ ] **Step 9: 提交**

```bash
cd macos-client && git add -A && git commit -m "feat: scaffold xcodegen project with HerdrKit framework"
```

---

## Task 2: Varint 编码与 ByteReader 解码

**Files:**
- Create: `macos-client/Sources/HerdrKit/Protocol/Varint.swift`
- Create: `macos-client/Sources/HerdrKit/Protocol/ByteReader.swift`
- Create: `macos-client/Tests/HerdrKitTests/VarintTests.swift`

- [ ] **Step 1: 写失败测试**

`Tests/HerdrKitTests/VarintTests.swift`:

```swift
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
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd macos-client && ./Scripts/test.sh -only-testing:HerdrKitTests/VarintTests
```

Expected: 编译失败，`cannot find 'Varint' in scope`

- [ ] **Step 3: 实现 `Varint`**

`Sources/HerdrKit/Protocol/Varint.swift`:

```swift
import Foundation

/// bincode 2 `standard` variable-length integer encoding.
///
/// First byte selects the width: `0...250` is the value itself, `251` is
/// followed by a little-endian `u16`, `252` by a `u32`, `253` by a `u64`.
public enum Varint {
    public static func encode(_ value: UInt64) -> [UInt8] {
        if value < 251 {
            return [UInt8(value)]
        }
        if value <= UInt64(UInt16.max) {
            return [251] + littleEndianBytes(UInt16(value))
        }
        if value <= UInt64(UInt32.max) {
            return [252] + littleEndianBytes(UInt32(value))
        }
        return [253] + littleEndianBytes(value)
    }

    public static func encode<T: FixedWidthInteger & UnsignedInteger>(_ value: T) -> [UInt8] {
        encode(UInt64(value))
    }

    private static func littleEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }
}
```

- [ ] **Step 4: 实现 `ByteReader`**

`Sources/HerdrKit/Protocol/ByteReader.swift`:

```swift
import Foundation

/// Sequential reader over a bincode payload.
///
/// Every accessor is strict: it throws rather than returning a partial or
/// guessed value. Silent misalignment in a hand-written codec shows up as
/// intermittent visual corruption, which is far harder to diagnose than a
/// hard failure at the point of the mistake.
public struct ByteReader {
    public enum Failure: Error, Equatable {
        case truncated(need: Int, offset: Int, remaining: Int)
        case badVarintTag(UInt8)
        case unexpectedOptionTag(UInt8)
        case lengthOverflow(UInt64)
        case invalidUTF8
        case trailingBytes(consumed: Int, total: Int)
    }

    private let bytes: [UInt8]
    public private(set) var offset: Int = 0

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    public var isAtEnd: Bool { offset == bytes.count }
    public var remaining: Int { bytes.count - offset }

    public mutating func byte() throws -> UInt8 {
        guard offset < bytes.count else {
            throw Failure.truncated(need: 1, offset: offset, remaining: 0)
        }
        let value = bytes[offset]
        offset += 1
        return value
    }

    public mutating func bool() throws -> Bool {
        try byte() != 0
    }

    public mutating func varint() throws -> UInt64 {
        let tag = try byte()
        switch tag {
        case 0 ... 250:
            return UInt64(tag)
        case 251:
            return UInt64(try fixedWidth(UInt16.self))
        case 252:
            return UInt64(try fixedWidth(UInt32.self))
        case 253:
            return try fixedWidth(UInt64.self)
        default:
            throw Failure.badVarintTag(tag)
        }
    }

    /// Reads an `Option` discriminant. Returns true for `Some`.
    public mutating func optionTag() throws -> Bool {
        let tag = try byte()
        switch tag {
        case 0: return false
        case 1: return true
        default: throw Failure.unexpectedOptionTag(tag)
        }
    }

    public mutating func string() throws -> String {
        let slice = try take(try length())
        guard let text = String(bytes: slice, encoding: .utf8) else {
            throw Failure.invalidUTF8
        }
        return text
    }

    public mutating func byteArray() throws -> [UInt8] {
        Array(try take(try length()))
    }

    /// Reads a varint length and converts it to `Int`, rejecting values that
    /// cannot be represented (corrupt or hostile input).
    public mutating func length() throws -> Int {
        let raw = try varint()
        guard let value = Int(exactly: raw) else {
            throw Failure.lengthOverflow(raw)
        }
        return value
    }

    public func requireFullyConsumed() throws {
        guard isAtEnd else {
            throw Failure.trailingBytes(consumed: offset, total: bytes.count)
        }
    }

    private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, offset + count <= bytes.count else {
            throw Failure.truncated(need: count, offset: offset, remaining: remaining)
        }
        let slice = bytes[offset ..< offset + count]
        offset += count
        return slice
    }

    private mutating func fixedWidth<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let slice = try take(MemoryLayout<T>.size)
        var value = T.zero
        for (index, byte) in slice.enumerated() {
            value |= T(byte) << (8 * index)
        }
        return value
    }
}
```

- [ ] **Step 5: 运行测试确认通过**

```bash
cd macos-client && xcodegen generate && ./Scripts/test.sh -only-testing:HerdrKitTests/VarintTests
```

Expected: 13 个 test case 全部 passed，`** TEST SUCCEEDED **`

- [ ] **Step 6: 提交**

```bash
cd macos-client && git add -A && git commit -m "feat: add bincode varint encoder and strict byte reader"
```

---

## Task 3: 长度前缀封帧

**Files:**
- Create: `macos-client/Sources/HerdrKit/Protocol/Framing.swift`
- Create: `macos-client/Tests/HerdrKitTests/FramingTests.swift`

- [ ] **Step 1: 写失败测试**

`Tests/HerdrKitTests/FramingTests.swift`:

```swift
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
            XCTAssertEqual(error as? Framing.Failure, .oversized(claimed: 4_294_967_295, max: Framing.maxPayloadSize))
        }
    }

    func testRejectsShortPrefix() {
        XCTAssertThrowsError(try Framing.payloadLength(from: [1, 2, 3]))
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd macos-client && ./Scripts/test.sh -only-testing:HerdrKitTests/FramingTests
```

Expected: 编译失败，`cannot find 'Framing' in scope`

- [ ] **Step 3: 实现**

`Sources/HerdrKit/Protocol/Framing.swift`:

```swift
import Foundation

/// Wire framing: `[u32 little-endian payload length][payload]`.
public enum Framing {
    public enum Failure: Error, Equatable {
        case shortPrefix(count: Int)
        case oversized(claimed: UInt32, max: Int)
    }

    /// Mirrors the server's own frame ceiling closely enough for a prototype;
    /// its purpose is to refuse absurd allocations from a corrupt prefix.
    public static let maxPayloadSize = 64 * 1024 * 1024

    public static let prefixSize = 4

    public static func frame(_ payload: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(prefixSize + payload.count)
        out.append(contentsOf: withUnsafeBytes(of: UInt32(payload.count).littleEndian) { Array($0) })
        out.append(contentsOf: payload)
        return out
    }

    public static func payloadLength(from prefix: [UInt8]) throws -> Int {
        guard prefix.count == prefixSize else {
            throw Failure.shortPrefix(count: prefix.count)
        }
        var claimed: UInt32 = 0
        for (index, byte) in prefix.enumerated() {
            claimed |= UInt32(byte) << (8 * index)
        }
        guard Int(claimed) <= maxPayloadSize else {
            throw Failure.oversized(claimed: claimed, max: maxPayloadSize)
        }
        return Int(claimed)
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cd macos-client && xcodegen generate && ./Scripts/test.sh -only-testing:HerdrKitTests/FramingTests
```

Expected: 5 个 test case passed

- [ ] **Step 5: 提交**

```bash
cd macos-client && git add -A && git commit -m "feat: add length-prefixed wire framing"
```

---

## Task 4: 线协议数据类型

**Files:**
- Create: `macos-client/Sources/HerdrKit/Protocol/WireTypes.swift`

本 task 只定义类型，行为在 Task 7/8 测试。

- [ ] **Step 1: 定义类型**

`Sources/HerdrKit/Protocol/WireTypes.swift`:

```swift
import Foundation

/// One terminal cell as sent by the server.
///
/// `symbol` is a grapheme cluster, usually one or two scalars. A wide
/// character occupies two cells: this one carries the symbol, the next is a
/// plain space with `skip == false`. The protocol does not mark that filler,
/// so consumers must skip it by display width. See `CharWidth`.
public struct GridCell: Equatable, Sendable {
    public let symbol: String
    public let foreground: UInt32
    public let background: UInt32
    public let modifier: UInt16
    public let skip: Bool
    public let hyperlink: UInt32?

    public init(
        symbol: String,
        foreground: UInt32,
        background: UInt32,
        modifier: UInt16,
        skip: Bool,
        hyperlink: UInt32?
    ) {
        self.symbol = symbol
        self.foreground = foreground
        self.background = background
        self.modifier = modifier
        self.skip = skip
        self.hyperlink = hyperlink
    }
}

public struct GridCursor: Equatable, Sendable {
    public let column: UInt16
    public let row: UInt16
    public let isVisible: Bool
    /// DECSCUSR parameter: 0 default, 1/2 block, 3/4 underline, 5/6 bar.
    public let shape: UInt8

    public init(column: UInt16, row: UInt16, isVisible: Bool, shape: UInt8) {
        self.column = column
        self.row = row
        self.isVisible = isVisible
        self.shape = shape
    }
}

/// A full rendered screen: `cells` is row-major, `width * height` long.
public struct GridFrame: Equatable, Sendable {
    public let cells: [GridCell]
    public let width: UInt16
    public let height: UInt16
    public let cursor: GridCursor?
    public let hyperlinks: [String]
    /// Kitty graphics protocol bytes. Decoded to keep the stream aligned;
    /// M1 does not render them.
    public let graphics: [UInt8]

    public init(
        cells: [GridCell],
        width: UInt16,
        height: UInt16,
        cursor: GridCursor?,
        hyperlinks: [String],
        graphics: [UInt8]
    ) {
        self.cells = cells
        self.width = width
        self.height = height
        self.cursor = cursor
        self.hyperlinks = hyperlinks
        self.graphics = graphics
    }

    public func cell(column: Int, row: Int) -> GridCell? {
        guard column >= 0, row >= 0, column < Int(width), row < Int(height) else { return nil }
        let index = row * Int(width) + column
        guard index < cells.count else { return nil }
        return cells[index]
    }
}

/// Messages this client understands. Variants the prototype does not handle
/// decode to `.ignored` rather than failing — see `WireDecoder`.
public enum ServerMessage: Equatable, Sendable {
    case welcome(version: UInt32, encoding: UInt32, error: String?)
    case frame(GridFrame)
    case shutdown(reason: String?)
    case ignored(variant: UInt64)
}
```

- [ ] **Step 2: 确认编译通过**

```bash
cd macos-client && xcodegen generate && ./Scripts/test.sh -only-testing:HerdrKitTests/SmokeTests
```

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 3: 提交**

```bash
cd macos-client && git add -A && git commit -m "feat: add wire protocol data types"
```

---

## Task 5: Hello / Resize / Detach 编码

**Files:**
- Create: `macos-client/Sources/HerdrKit/Protocol/WireEncoder.swift`
- Create: `macos-client/Tests/HerdrKitTests/WireEncoderTests.swift`

golden 字节可以手工推导，因为编码规则简单且探针已用同样字节完成过真实握手。`Hello{version:19, cols:100, rows:30, cell:8x16, SemanticFrame, Server, App}` 每个字段都 < 251，故各占一字节：`00 13 64 1E 08 10 00 00 00`。

- [ ] **Step 1: 写失败测试**

`Tests/HerdrKitTests/WireEncoderTests.swift`:

```swift
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
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd macos-client && ./Scripts/test.sh -only-testing:HerdrKitTests/WireEncoderTests
```

Expected: 编译失败，`cannot find 'WireEncoder' in scope`

- [ ] **Step 3: 实现**

`Sources/HerdrKit/Protocol/WireEncoder.swift`:

```swift
import Foundation

/// Encodes the `ClientMessage` variants this prototype sends.
public enum WireEncoder {
    private enum Variant: UInt64 {
        case hello = 0
        case resize = 3
        case detach = 4
        case inputEvents = 7
    }

    private enum RenderEncoding: UInt64 {
        case semanticFrame = 0
    }

    private enum Keybindings: UInt64 {
        case server = 0
    }

    private enum LaunchMode: UInt64 {
        case app = 0
    }

    public static func hello(
        columns: UInt16,
        rows: UInt16,
        cellWidth: UInt32,
        cellHeight: UInt32
    ) -> [UInt8] {
        var out = Varint.encode(Variant.hello.rawValue)
        out += Varint.encode(UInt64(HerdrKit.protocolVersion))
        out += Varint.encode(UInt64(columns))
        out += Varint.encode(UInt64(rows))
        out += Varint.encode(UInt64(cellWidth))
        out += Varint.encode(UInt64(cellHeight))
        out += Varint.encode(RenderEncoding.semanticFrame.rawValue)
        out += Varint.encode(Keybindings.server.rawValue)
        out += Varint.encode(LaunchMode.app.rawValue)
        return out
    }

    public static func resize(
        columns: UInt16,
        rows: UInt16,
        cellWidth: UInt32,
        cellHeight: UInt32
    ) -> [UInt8] {
        var out = Varint.encode(Variant.resize.rawValue)
        out += Varint.encode(UInt64(columns))
        out += Varint.encode(UInt64(rows))
        out += Varint.encode(UInt64(cellWidth))
        out += Varint.encode(UInt64(cellHeight))
        return out
    }

    public static func detach() -> [UInt8] {
        Varint.encode(Variant.detach.rawValue)
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cd macos-client && xcodegen generate && ./Scripts/test.sh -only-testing:HerdrKitTests/WireEncoderTests
```

Expected: 5 个 test case passed

- [ ] **Step 5: 提交**

```bash
cd macos-client && git add -A && git commit -m "feat: encode hello, resize and detach client messages"
```

---

## Task 6: 功能键 InputEvents 编码

M1 需要它发一次 `ctrl+alt+f20` 来隐藏 herdr 自己的 sidebar。只需 `ClientKeyCode::F(u8)`，**不需要 `Char`**——`char` 的 bincode 表示尚未验证，M2 处理字母键时才需要确认。

**Files:**
- Modify: `macos-client/Sources/HerdrKit/Protocol/WireEncoder.swift`
- Modify: `macos-client/Tests/HerdrKitTests/WireEncoderTests.swift`

- [ ] **Step 1: 追加失败测试**

在 `WireEncoderTests` 类内追加：

```swift
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
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd macos-client && ./Scripts/test.sh -only-testing:HerdrKitTests/WireEncoderTests
```

Expected: 编译失败，`type 'WireEncoder' has no member 'functionKey'`

- [ ] **Step 3: 实现**

在 `Sources/HerdrKit/Protocol/WireEncoder.swift` 的 `WireEncoder` 内追加：

```swift
    /// crossterm 0.29 `KeyModifiers` bit layout, as carried by
    /// `ClientInputEvent::Key.modifiers` (a raw `u8`).
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let shift = Modifiers(rawValue: 1)
        public static let control = Modifiers(rawValue: 2)
        public static let option = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    private enum InputEvent: UInt64 {
        case key = 0
    }

    private enum KeyCode: UInt64 {
        case function = 16
    }

    private enum KeyKind: UInt64 {
        case press = 0
    }

    private enum KeySource: UInt64 {
        case synthesized = 0
    }

    /// Encodes a single synthesized function-key press as an `InputEvents`
    /// message. Used at startup to trigger herdr's `toggle_sidebar` action.
    public static func functionKey(_ number: UInt8, modifiers: Modifiers) -> [UInt8] {
        var out = Varint.encode(Variant.inputEvents.rawValue)
        out += Varint.encode(UInt64(1))                      // events.count
        out += Varint.encode(InputEvent.key.rawValue)
        out += Varint.encode(KeyCode.function.rawValue)
        out.append(number)                                   // F(u8) payload, raw byte
        out.append(modifiers.rawValue)                       // u8, raw byte
        out += Varint.encode(KeyKind.press.rawValue)
        out += Varint.encode(UInt64(1))                      // repeat_count: u16
        out.append(0)                                        // generated_text: None
        out += Varint.encode(KeySource.synthesized.rawValue)
        return out
    }
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cd macos-client && xcodegen generate && ./Scripts/test.sh -only-testing:HerdrKitTests/WireEncoderTests
```

Expected: 8 个 test case passed

- [ ] **Step 5: 提交**

```bash
cd macos-client && git add -A && git commit -m "feat: encode synthesized function-key input events"
```

---

## Task 7: GridFrame 解码

**Files:**
- Create: `macos-client/Sources/HerdrKit/Protocol/WireDecoder.swift`
- Create: `macos-client/Tests/HerdrKitTests/WireDecoderTests.swift`

用手工构造的 2×1 grid 做单元测试——小、可读、无外部依赖。真实数据对照留到 Task 16。

- [ ] **Step 1: 写失败测试**

`Tests/HerdrKitTests/WireDecoderTests.swift`:

```swift
import XCTest
@testable import HerdrKit

final class WireDecoderTests: XCTestCase {
    /// A 2x1 grid: "更" (wide, RGB foreground) followed by its space filler.
    private var twoByOneFramePayload: [UInt8] {
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

        out += Varint.encode(UInt64(1))            // hyperlinks.count
        out += Varint.encode(UInt64(11))
        out += Array("https://x/".utf8) + [0x21]   // "https://x/!" == 11 bytes

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
        XCTAssertEqual(frame.hyperlinks, ["https://x/!"])
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
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd macos-client && ./Scripts/test.sh -only-testing:HerdrKitTests/WireDecoderTests
```

Expected: 编译失败，`cannot find 'WireDecoder' in scope`

- [ ] **Step 3: 实现**

`Sources/HerdrKit/Protocol/WireDecoder.swift`:

```swift
import Foundation

/// Decodes `ServerMessage` payloads.
public enum WireDecoder {
    public enum Failure: Error, Equatable {
        case cellCountMismatch(cells: Int, width: UInt16, height: UInt16)
        case dimensionOverflow(UInt64)
    }

    public static func gridFrame(from reader: inout ByteReader) throws -> GridFrame {
        let cellCount = try reader.length()
        var cells = [GridCell]()
        cells.reserveCapacity(cellCount)
        for _ in 0 ..< cellCount {
            cells.append(try cell(from: &reader))
        }

        let width = try dimension(from: &reader)
        let height = try dimension(from: &reader)

        guard cells.count == Int(width) * Int(height) else {
            throw Failure.cellCountMismatch(cells: cells.count, width: width, height: height)
        }

        let cursor = try reader.optionTag() ? try self.cursor(from: &reader) : nil

        let hyperlinkCount = try reader.length()
        var hyperlinks = [String]()
        hyperlinks.reserveCapacity(hyperlinkCount)
        for _ in 0 ..< hyperlinkCount {
            hyperlinks.append(try reader.string())
        }

        let graphics = try reader.byteArray()

        return GridFrame(
            cells: cells,
            width: width,
            height: height,
            cursor: cursor,
            hyperlinks: hyperlinks,
            graphics: graphics
        )
    }

    private static func cell(from reader: inout ByteReader) throws -> GridCell {
        let symbol = try reader.string()
        let foreground = UInt32(truncatingIfNeeded: try reader.varint())
        let background = UInt32(truncatingIfNeeded: try reader.varint())
        let modifier = UInt16(truncatingIfNeeded: try reader.varint())
        let skip = try reader.bool()
        let hyperlink: UInt32? = try reader.optionTag()
            ? UInt32(truncatingIfNeeded: try reader.varint())
            : nil
        return GridCell(
            symbol: symbol,
            foreground: foreground,
            background: background,
            modifier: modifier,
            skip: skip,
            hyperlink: hyperlink
        )
    }

    private static func cursor(from reader: inout ByteReader) throws -> GridCursor {
        let column = try dimension(from: &reader)
        let row = try dimension(from: &reader)
        let isVisible = try reader.bool()
        let shape = try reader.byte()
        return GridCursor(column: column, row: row, isVisible: isVisible, shape: shape)
    }

    private static func dimension(from reader: inout ByteReader) throws -> UInt16 {
        let raw = try reader.varint()
        guard let value = UInt16(exactly: raw) else {
            throw Failure.dimensionOverflow(raw)
        }
        return value
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cd macos-client && xcodegen generate && ./Scripts/test.sh -only-testing:HerdrKitTests/WireDecoderTests
```

Expected: 4 个 test case passed

- [ ] **Step 5: 提交**

```bash
cd macos-client && git add -A && git commit -m "feat: decode grid frames with strict dimension checks"
```

---

## Task 8: ServerMessage 分发与严格校验

已知但不处理的变体必须整帧丢弃而非报错——server 会发 `Graphics`、`ReloadSoundConfig`、`MouseCapture` 等本原型不用的消息。这与「认识该变体但解码出错时严格失败」是两件事。

**Files:**
- Modify: `macos-client/Sources/HerdrKit/Protocol/WireDecoder.swift`
- Modify: `macos-client/Tests/HerdrKitTests/WireDecoderTests.swift`

- [ ] **Step 1: 追加失败测试**

在 `WireDecoderTests` 类内追加：

```swift
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
        XCTAssertEqual(try WireDecoder.serverMessage(from: [0x03, 0x02, 0xAA, 0xBB]), .ignored(variant: 3))
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
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd macos-client && ./Scripts/test.sh -only-testing:HerdrKitTests/WireDecoderTests
```

Expected: 编译失败，`type 'WireDecoder' has no member 'serverMessage'`

- [ ] **Step 3: 实现**

在 `Sources/HerdrKit/Protocol/WireDecoder.swift` 的 `WireDecoder` 内追加：

```swift
    private enum Variant: UInt64 {
        case welcome = 0
        case frame = 1
        case shutdown = 4
    }

    /// Decodes one framed payload.
    ///
    /// Variants the prototype handles are decoded strictly: the payload must be
    /// consumed exactly, otherwise the codec and the server disagree and we
    /// fail loudly. Variants it does not handle return `.ignored` without
    /// touching their payload — framing already told us where the message ends.
    public static func serverMessage(from payload: [UInt8]) throws -> ServerMessage {
        var reader = ByteReader(payload)
        let variant = try reader.varint()

        switch Variant(rawValue: variant) {
        case .welcome:
            let version = UInt32(truncatingIfNeeded: try reader.varint())
            let encoding = UInt32(truncatingIfNeeded: try reader.varint())
            let error = try reader.optionTag() ? try reader.string() : nil
            try reader.requireFullyConsumed()
            return .welcome(version: version, encoding: encoding, error: error)

        case .frame:
            let frame = try gridFrame(from: &reader)
            try reader.requireFullyConsumed()
            return .frame(frame)

        case .shutdown:
            let reason = try reader.optionTag() ? try reader.string() : nil
            try reader.requireFullyConsumed()
            return .shutdown(reason: reason)

        case nil:
            return .ignored(variant: variant)
        }
    }
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cd macos-client && xcodegen generate && ./Scripts/test.sh -only-testing:HerdrKitTests/WireDecoderTests
```

Expected: 11 个 test case passed

- [ ] **Step 5: 提交**

```bash
cd macos-client && git add -A && git commit -m "feat: dispatch server messages and ignore unhandled variants"
```

---

## Task 9: 颜色解包

**Files:**
- Create: `macos-client/Sources/HerdrKit/Terminal/TerminalColor.swift`
- Create: `macos-client/Tests/HerdrKitTests/TerminalColorTests.swift`

- [ ] **Step 1: 写失败测试**

`Tests/HerdrKitTests/TerminalColorTests.swift`:

```swift
import XCTest
@testable import HerdrKit

final class TerminalColorTests: XCTestCase {
    func testResetMapsToReset() {
        XCTAssertEqual(TerminalColor.unpack(0x00_00_00_00), .reset)
    }

    func testNamedColorsMapToConcreteRGB() {
        XCTAssertEqual(TerminalColor.unpack(0x00_00_00_01), .rgb(0, 0, 0))          // Black
        XCTAssertEqual(TerminalColor.unpack(0x00_00_00_10), .rgb(255, 255, 255))    // White
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
        XCTAssertEqual(TerminalColor.unpack(0x01_00_00_00), .rgb(0, 0, 0))
        XCTAssertEqual(TerminalColor.unpack(0x01_00_00_0F), .rgb(255, 255, 255))
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
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd macos-client && ./Scripts/test.sh -only-testing:HerdrKitTests/TerminalColorTests
```

Expected: 编译失败，`cannot find 'TerminalColor' in scope`

- [ ] **Step 3: 实现**

`Sources/HerdrKit/Terminal/TerminalColor.swift`:

```swift
import AppKit

/// A cell color after unpacking the wire representation.
///
/// `reset` means "terminal default", which differs for foreground and
/// background, so the renderer resolves it rather than this type.
public enum TerminalColor: Equatable, Sendable {
    case reset
    case rgb(UInt8, UInt8, UInt8)

    /// Unpacks the `u32` produced by herdr's `color_to_u32`:
    /// tag `0x00` named (low byte 0…16, 0 == Reset), `0x01` palette index,
    /// `0x02` RGB in the low three bytes.
    public static func unpack(_ packed: UInt32) -> TerminalColor {
        switch packed >> 24 {
        case 0x00:
            return named(UInt8(truncatingIfNeeded: packed))
        case 0x01:
            return palette(UInt8(truncatingIfNeeded: packed))
        case 0x02:
            return .rgb(
                UInt8(truncatingIfNeeded: packed >> 16),
                UInt8(truncatingIfNeeded: packed >> 8),
                UInt8(truncatingIfNeeded: packed)
            )
        default:
            return .reset
        }
    }

    /// ratatui named colors. Index 0 is Reset; 1…16 follow the enum order
    /// Black, Red, Green, Yellow, Blue, Magenta, Cyan, Gray, DarkGray,
    /// LightRed, LightGreen, LightYellow, LightBlue, LightMagenta, LightCyan,
    /// White. Note Gray is ANSI 7 and DarkGray is ANSI 8.
    private static func named(_ index: UInt8) -> TerminalColor {
        switch index {
        case 1: return .rgb(0, 0, 0)
        case 2: return .rgb(205, 49, 49)
        case 3: return .rgb(13, 188, 121)
        case 4: return .rgb(229, 229, 16)
        case 5: return .rgb(36, 114, 200)
        case 6: return .rgb(188, 63, 188)
        case 7: return .rgb(17, 168, 205)
        case 8: return .rgb(229, 229, 229)
        case 9: return .rgb(102, 102, 102)
        case 10: return .rgb(241, 76, 76)
        case 11: return .rgb(35, 209, 139)
        case 12: return .rgb(245, 245, 67)
        case 13: return .rgb(59, 142, 234)
        case 14: return .rgb(214, 112, 214)
        case 15: return .rgb(41, 184, 219)
        case 16: return .rgb(255, 255, 255)
        default: return .reset
        }
    }

    /// Standard xterm 256-color palette.
    private static func palette(_ index: UInt8) -> TerminalColor {
        if index < 16 {
            return named(index + 1)
        }
        if index < 232 {
            let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
            let offset = Int(index) - 16
            return .rgb(levels[offset / 36], levels[(offset % 36) / 6], levels[offset % 6])
        }
        let level = UInt8(8 + (Int(index) - 232) * 10)
        return .rgb(level, level, level)
    }

    /// Resolves to an `NSColor`, using the supplied default for `reset`.
    public func nsColor(default fallback: NSColor) -> NSColor {
        switch self {
        case .reset:
            return fallback
        case .rgb(let r, let g, let b):
            return NSColor(
                srgbRed: CGFloat(r) / 255,
                green: CGFloat(g) / 255,
                blue: CGFloat(b) / 255,
                alpha: 1
            )
        }
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cd macos-client && xcodegen generate && ./Scripts/test.sh -only-testing:HerdrKitTests/TerminalColorTests
```

Expected: 9 个 test case passed

- [ ] **Step 5: 提交**

```bash
cd macos-client && git add -A && git commit -m "feat: unpack terminal cell colors"
```

---

## Task 10: 字符显示宽度

M1 最大的技术风险。宽字符占位 cell 与真空格在数据上无法区分，所以渲染必须靠显示宽度跳过占位格；若这里与 server 端 ghostty-vt 的判断不一致，整行会错位。

**Files:**
- Create: `macos-client/Sources/HerdrKit/Terminal/CharWidth.swift`
- Create: `macos-client/Tests/HerdrKitTests/CharWidthTests.swift`

- [ ] **Step 1: 写失败测试**

`Tests/HerdrKitTests/CharWidthTests.swift`:

```swift
import XCTest
@testable import HerdrKit

final class CharWidthTests: XCTestCase {
    func testASCIIIsSingleWidth() {
        XCTAssertEqual(CharWidth.displayWidth(of: "a"), 1)
        XCTAssertEqual(CharWidth.displayWidth(of: " "), 1)
        XCTAssertEqual(CharWidth.displayWidth(of: "~"), 1)
    }

    func testCJKIsDoubleWidth() {
        XCTAssertEqual(CharWidth.displayWidth(of: "更"), 2)
        XCTAssertEqual(CharWidth.displayWidth(of: "新"), 2)
        XCTAssertEqual(CharWidth.displayWidth(of: "あ"), 2)
        XCTAssertEqual(CharWidth.displayWidth(of: "한"), 2)
    }

    func testFullWidthFormsAreDoubleWidth() {
        XCTAssertEqual(CharWidth.displayWidth(of: "！"), 2)
        XCTAssertEqual(CharWidth.displayWidth(of: "Ａ"), 2)
    }

    func testEmojiPresentationIsDoubleWidth() {
        XCTAssertEqual(CharWidth.displayWidth(of: "👍"), 2)
        XCTAssertEqual(CharWidth.displayWidth(of: "🐑"), 2)
    }

    func testBoxDrawingIsSingleWidth() {
        // herdr draws pane borders with these; treating them as wide would
        // shear every frame.
        XCTAssertEqual(CharWidth.displayWidth(of: "╭"), 1)
        XCTAssertEqual(CharWidth.displayWidth(of: "─"), 1)
        XCTAssertEqual(CharWidth.displayWidth(of: "│"), 1)
        XCTAssertEqual(CharWidth.displayWidth(of: "╯"), 1)
    }

    func testPrecomposedAccentIsSingleWidth() {
        XCTAssertEqual(CharWidth.displayWidth(of: "é"), 1)
    }

    func testCombiningSequenceStillOccupiesOneCell() {
        // The server already grouped this into one cell; a cell never
        // advances zero columns.
        XCTAssertEqual(CharWidth.displayWidth(of: "e\u{0301}"), 1)
    }

    func testEmptySymbolOccupiesOneCell() {
        XCTAssertEqual(CharWidth.displayWidth(of: ""), 1)
    }

    func testWidthIsClampedToTwo() {
        for symbol in ["a", "更", "👍", "", "é"] {
            let width = CharWidth.displayWidth(of: symbol)
            XCTAssertTrue((1 ... 2).contains(width), "\(symbol) reported \(width)")
        }
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd macos-client && ./Scripts/test.sh -only-testing:HerdrKitTests/CharWidthTests
```

Expected: 编译失败，`cannot find 'CharWidth' in scope`

- [ ] **Step 3: 实现**

`Sources/HerdrKit/Terminal/CharWidth.swift`:

```swift
import Darwin
import Foundation

/// Display width of a cell symbol, in terminal columns.
///
/// The wire format does not mark the filler cell that follows a wide
/// character — it is an ordinary space with `skip == false`. The renderer
/// therefore has to know which symbols advance two columns and skip the
/// following cell itself. This must agree with the server's own width
/// judgement (ghostty-vt); disagreement shears the whole row.
public enum CharWidth {
    /// `wcwidth` consults the C locale; without this it misreports non-ASCII.
    private static let localeReady: Bool = {
        setlocale(LC_CTYPE, "UTF-8")
        return true
    }()

    public static func displayWidth(of symbol: String) -> Int {
        _ = localeReady
        guard let scalar = symbol.unicodeScalars.first else { return 1 }

        // Checked before wcwidth: Darwin's wcwidth reports 1 for many emoji,
        // which terminals render at two columns.
        if scalar.properties.isEmojiPresentation {
            return 2
        }

        let reported = wcwidth(wchar_t(bitPattern: scalar.value))
        if reported <= 0 {
            // Combining marks report 0, but the server already folded them
            // into a single cell, and a cell always advances at least once.
            return 1
        }
        return min(2, Int(reported))
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cd macos-client && xcodegen generate && ./Scripts/test.sh -only-testing:HerdrKitTests/CharWidthTests
```

Expected: 9 个 test case passed

若 `testEmojiPresentationIsDoubleWidth` 或 `testBoxDrawingIsSingleWidth` 失败，说明本机 `wcwidth` 的判断与预期不符——记录实际值，并在 Task 16 的真实数据对照中确认哪一方与 server 一致，再据此调整。**不要为了让测试通过而放宽断言。**

- [ ] **Step 5: 提交**

```bash
cd macos-client && git add -A && git commit -m "feat: compute cell display width for wide-character handling"
```

---

## Task 11: 运行时路径与隔离环境

不预测 `HERDR_SESSION` 的 socket 路径规则，而用 `HERDR_SOCKET_PATH` 显式指定 API socket；client socket 由 herdr 从它派生（`foo.sock` → `foo-client.sock`，见 `src/server/socket_paths.rs`）。两个路径因此完全确定。该派生规则已由探针实证。

**Files:**
- Create: `macos-client/Sources/HerdrKit/Runtime/RuntimePaths.swift`
- Create: `macos-client/Tests/HerdrKitTests/RuntimePathsTests.swift`

- [ ] **Step 1: 写失败测试**

`Tests/HerdrKitTests/RuntimePathsTests.swift`:

```swift
import XCTest
@testable import HerdrKit

final class RuntimePathsTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/herdr-proto-test", isDirectory: true)

    private var paths: RuntimePaths {
        RuntimePaths(root: root)
    }

    func testDerivesSocketPaths() {
        XCTAssertEqual(paths.apiSocket.path, "/tmp/herdr-proto-test/herdr.sock")
        XCTAssertEqual(paths.clientSocket.path, "/tmp/herdr-proto-test/herdr-client.sock")
    }

    func testConfigFileLivesUnderHerdrSubdirectoryOfConfigHome() {
        // config_dir() appends "herdr" to XDG_CONFIG_HOME.
        XCTAssertEqual(paths.configHome.path, "/tmp/herdr-proto-test/config")
        XCTAssertEqual(paths.configFile.path, "/tmp/herdr-proto-test/config/herdr/config.toml")
    }

    func testConfigContentsHidesSidebarAndBindsToggle() {
        let toml = paths.configContents
        XCTAssertTrue(toml.contains("sidebar_collapsed_mode = \"hidden\""))
        XCTAssertTrue(toml.contains("toggle_sidebar = \"ctrl+alt+f20\""))
        XCTAssertTrue(toml.contains("[ui]"))
        XCTAssertTrue(toml.contains("[keys]"))
    }

    func testEnvironmentSetsIsolationVariables() {
        let env = paths.environment(basedOn: [:])
        XCTAssertEqual(env["HERDR_SOCKET_PATH"], "/tmp/herdr-proto-test/herdr.sock")
        XCTAssertEqual(env["XDG_CONFIG_HOME"], "/tmp/herdr-proto-test/config")
        XCTAssertEqual(env["XDG_STATE_HOME"], "/tmp/herdr-proto-test/state")
    }

    func testEnvironmentDropsInheritedHerdrVariables() {
        // The app may be launched from inside a real herdr session (directly,
        // or via an Xcode that was). Inherited HERDR_* would point the child
        // at the developer's live server.
        let parent = [
            "HERDR_SOCKET_PATH": "/Users/dev/.config/herdr/herdr.sock",
            "HERDR_CLIENT_SOCKET_PATH": "/Users/dev/.config/herdr/herdr-client.sock",
            "HERDR_SESSION": "default",
            "HERDR_PANE_ID": "w8:p1",
            "HERDR_ENV": "1",
            "PATH": "/usr/bin",
        ]
        let env = paths.environment(basedOn: parent)

        XCTAssertEqual(env["HERDR_SOCKET_PATH"], "/tmp/herdr-proto-test/herdr.sock")
        XCTAssertNil(env["HERDR_CLIENT_SOCKET_PATH"])
        XCTAssertNil(env["HERDR_SESSION"])
        XCTAssertNil(env["HERDR_PANE_ID"])
        XCTAssertNil(env["HERDR_ENV"])
        XCTAssertEqual(env["PATH"], "/usr/bin", "unrelated variables must survive")
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd macos-client && ./Scripts/test.sh -only-testing:HerdrKitTests/RuntimePathsTests
```

Expected: 编译失败，`cannot find 'RuntimePaths' in scope`

- [ ] **Step 3: 实现**

`Sources/HerdrKit/Runtime/RuntimePaths.swift`:

```swift
import Foundation

/// Filesystem layout for the embedded herdr runtime.
///
/// Everything lives under one root so the prototype cannot touch the
/// developer's real herdr session, its config, or its persisted state.
public struct RuntimePaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Default location: `~/Library/Application Support/<bundle id>/runtime`.
    public static func defaultLocation(
        bundleIdentifier: String = "dev.herdr.macos-client-prototype"
    ) -> RuntimePaths {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return RuntimePaths(
            root: support
                .appendingPathComponent(bundleIdentifier, isDirectory: true)
                .appendingPathComponent("runtime", isDirectory: true)
        )
    }

    public var configHome: URL { root.appendingPathComponent("config", isDirectory: true) }
    public var stateHome: URL { root.appendingPathComponent("state", isDirectory: true) }

    /// herdr's `config_dir()` appends "herdr" to `XDG_CONFIG_HOME`.
    public var configFile: URL {
        configHome
            .appendingPathComponent("herdr", isDirectory: true)
            .appendingPathComponent("config.toml")
    }

    public var apiSocket: URL { root.appendingPathComponent("herdr.sock") }

    /// herdr derives this from the API socket by inserting "-client" before
    /// the extension, so it must not be set independently.
    public var clientSocket: URL { root.appendingPathComponent("herdr-client.sock") }

    /// Hides herdr's own sidebar (the native UI replaces it) and binds the
    /// toggle to a chord the user cannot hit by accident. Binding it to a
    /// function key also means the startup toggle needs only
    /// `ClientKeyCode::F`, avoiding `Char`, whose bincode form is unverified.
    public var configContents: String {
        """
        # Generated by HerdrPrototype. Do not edit; it is rewritten on launch.
        [ui]
        sidebar_collapsed_mode = "hidden"

        [keys]
        toggle_sidebar = "ctrl+alt+f20"
        """
    }

    public func createDirectories() throws {
        for directory in [root, configHome, stateHome, configFile.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }

    public func writeConfig() throws {
        try createDirectories()
        try configContents.write(to: configFile, atomically: true, encoding: .utf8)
    }

    /// Builds the child environment. Inherited `HERDR_*` variables are removed
    /// first: the app may itself have been launched from inside a herdr
    /// session, and those would redirect the child at the real server.
    public func environment(basedOn parent: [String: String]) -> [String: String] {
        var env = parent
        for key in env.keys where key.hasPrefix("HERDR_") {
            env.removeValue(forKey: key)
        }
        env["HERDR_SOCKET_PATH"] = apiSocket.path
        env["XDG_CONFIG_HOME"] = configHome.path
        env["XDG_STATE_HOME"] = stateHome.path
        return env
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cd macos-client && xcodegen generate && ./Scripts/test.sh -only-testing:HerdrKitTests/RuntimePathsTests
```

Expected: 5 个 test case passed

- [ ] **Step 5: 提交**

```bash
cd macos-client && git add -A && git commit -m "feat: add isolated runtime paths and child environment"
```

---

## Task 12: Unix domain socket

**Files:**
- Create: `macos-client/Sources/HerdrKit/Protocol/UnixSocket.swift`
- Create: `macos-client/Tests/HerdrKitTests/UnixSocketTests.swift`

- [ ] **Step 1: 写失败测试**

用一个进程内的 `socketpair` 验证读写，不依赖真实 server。

`Tests/HerdrKitTests/UnixSocketTests.swift`:

```swift
import Darwin
import XCTest
@testable import HerdrKit

final class UnixSocketTests: XCTestCase {
    func testWritesAndReadsExactCounts() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let a = UnixSocket(adopting: fds[0])
        let b = UnixSocket(adopting: fds[1])
        defer { a.close(); b.close() }

        try a.write([1, 2, 3, 4, 5])
        XCTAssertEqual(try b.readExactly(2), [1, 2])
        XCTAssertEqual(try b.readExactly(3), [3, 4, 5])
    }

    func testReadExactlyReassemblesAcrossWrites() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let a = UnixSocket(adopting: fds[0])
        let b = UnixSocket(adopting: fds[1])
        defer { a.close(); b.close() }

        let reader = Task.detached { try b.readExactly(4) }
        try a.write([9])
        try a.write([8, 7])
        try a.write([6])
        XCTAssertEqual(try awaitValue(of: reader), [9, 8, 7, 6])
    }

    func testReadingAfterPeerCloseThrowsClosed() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let a = UnixSocket(adopting: fds[0])
        let b = UnixSocket(adopting: fds[1])
        a.close()
        defer { b.close() }

        XCTAssertThrowsError(try b.readExactly(1)) { error in
            XCTAssertEqual(error as? UnixSocket.Failure, .closed)
        }
    }

    func testZeroLengthReadReturnsEmpty() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let a = UnixSocket(adopting: fds[0])
        defer { a.close(); close(fds[1]) }
        XCTAssertEqual(try a.readExactly(0), [])
    }

    func testConnectingToMissingPathThrows() {
        XCTAssertThrowsError(try UnixSocket(connectingTo: "/tmp/herdr-proto-does-not-exist.sock"))
    }

    func testRejectsOverlongPath() {
        let long = "/tmp/" + String(repeating: "x", count: 200) + ".sock"
        XCTAssertThrowsError(try UnixSocket(connectingTo: long)) { error in
            guard case .pathTooLong = error as? UnixSocket.Failure else {
                return XCTFail("expected pathTooLong, got \(error)")
            }
        }
    }

    private func awaitValue<T>(of task: Task<T, Error>) throws -> T {
        let box = ResultBox<T>()
        let done = expectation(description: "task finished")
        Task {
            box.result = await task.result
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return try XCTUnwrap(box.result).get()
    }

    private final class ResultBox<T>: @unchecked Sendable {
        var result: Result<T, Error>?
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd macos-client && ./Scripts/test.sh -only-testing:HerdrKitTests/UnixSocketTests
```

Expected: 编译失败，`cannot find 'UnixSocket' in scope`

- [ ] **Step 3: 实现**

`Sources/HerdrKit/Protocol/UnixSocket.swift`:

```swift
import Darwin
import Foundation

/// Blocking Unix domain socket.
///
/// Reads happen on a background thread while writes come from the UI thread.
/// That is safe at the kernel level for a stream socket, so this type is
/// `@unchecked Sendable`; only the close flag needs a lock.
public final class UnixSocket: @unchecked Sendable {
    public enum Failure: Error, Equatable {
        case pathTooLong(Int)
        case socketCreationFailed(errno: Int32)
        case connectFailed(errno: Int32)
        case readFailed(errno: Int32)
        case writeFailed(errno: Int32)
        case closed
    }

    private let descriptor: Int32
    private let lock = NSLock()
    private var closed = false

    /// Takes ownership of an existing descriptor (used by tests).
    public init(adopting descriptor: Int32) {
        self.descriptor = descriptor
    }

    public init(connectingTo path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            throw Failure.pathTooLong(pathBytes.count)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.copyMemory(from: source)
            }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw Failure.socketCreationFailed(errno: errno)
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let outcome = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(fd, generic, size)
            }
        }
        guard outcome == 0 else {
            let code = errno
            Darwin.close(fd)
            throw Failure.connectFailed(errno: code)
        }

        self.descriptor = fd
    }

    deinit {
        close()
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(descriptor)
    }

    public func write(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress, buffer.count)
            }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0 && errno == EINTR { continue }
            throw written == 0 ? Failure.closed : Failure.writeFailed(errno: errno)
        }
    }

    /// Reads exactly `count` bytes, reassembling partial reads.
    /// Throws `.closed` on EOF before the count is met.
    public func readExactly(_ count: Int) throws -> [UInt8] {
        guard count > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let received = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(descriptor, base.advanced(by: offset), count - offset)
            }
            if received > 0 {
                offset += received
                continue
            }
            if received == 0 { throw Failure.closed }
            if errno == EINTR { continue }
            throw Failure.readFailed(errno: errno)
        }
        return buffer
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cd macos-client && xcodegen generate && ./Scripts/test.sh -only-testing:HerdrKitTests/UnixSocketTests
```

Expected: 6 个 test case passed

- [ ] **Step 5: 提交**

```bash
cd macos-client && git add -A && git commit -m "feat: add blocking unix domain socket wrapper"
```

---

## Task 13: herdr server 进程管理

**Files:**
- Create: `macos-client/Sources/HerdrKit/Runtime/HerdrRuntime.swift`
- Create: `macos-client/Tests/HerdrKitTests/HerdrRuntimeTests.swift`

`stop()` 在 M1 用 SIGTERM。M3 有了 `ApiClient` 后改为优先调 `server.stop`，超时再 SIGTERM。

- [ ] **Step 1: 写失败测试**

只测不需要真实 server 的部分：binary 查找顺序与 socket 等待超时。

`Tests/HerdrKitTests/HerdrRuntimeTests.swift`:

```swift
import XCTest
@testable import HerdrKit

final class HerdrRuntimeTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("herdr-runtime-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testPrefersBundledBinaryOverPathCandidates() throws {
        let bundled = scratch.appendingPathComponent("herdr")
        let fallback = scratch.appendingPathComponent("fallback-herdr")
        try Data().write(to: bundled)
        try Data().write(to: fallback)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fallback.path)

        let located = HerdrRuntime.locateBinary(candidates: [bundled, fallback])
        XCTAssertEqual(located, bundled)
    }

    func testSkipsMissingAndNonExecutableCandidates() throws {
        let missing = scratch.appendingPathComponent("nope")
        let notExecutable = scratch.appendingPathComponent("data")
        let usable = scratch.appendingPathComponent("herdr")
        try Data().write(to: notExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: notExecutable.path)
        try Data().write(to: usable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: usable.path)

        XCTAssertEqual(HerdrRuntime.locateBinary(candidates: [missing, notExecutable, usable]), usable)
    }

    func testReturnsNilWhenNoCandidateIsUsable() {
        XCTAssertNil(HerdrRuntime.locateBinary(candidates: [scratch.appendingPathComponent("absent")]))
    }

    func testWaitForSocketsTimesOutWithBothPaths() {
        let paths = RuntimePaths(root: scratch)
        let runtime = HerdrRuntime(paths: paths, binary: scratch.appendingPathComponent("herdr"))
        XCTAssertThrowsError(try runtime.waitForSockets(timeout: 0.2)) { error in
            guard case .socketTimeout(let missing, _) = error as? HerdrRuntime.Failure else {
                return XCTFail("expected socketTimeout, got \(error)")
            }
            XCTAssertEqual(missing.count, 2)
        }
    }

    func testWaitForSocketsSucceedsOnceBothExist() throws {
        let paths = RuntimePaths(root: scratch)
        try Data().write(to: paths.apiSocket)
        try Data().write(to: paths.clientSocket)
        let runtime = HerdrRuntime(paths: paths, binary: scratch.appendingPathComponent("herdr"))
        XCTAssertNoThrow(try runtime.waitForSockets(timeout: 1))
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd macos-client && ./Scripts/test.sh -only-testing:HerdrKitTests/HerdrRuntimeTests
```

Expected: 编译失败，`cannot find 'HerdrRuntime' in scope`

- [ ] **Step 3: 实现**

`Sources/HerdrKit/Runtime/HerdrRuntime.swift`:

```swift
import Foundation

/// Owns the embedded herdr server process.
public final class HerdrRuntime {
    public enum Failure: Error {
        case binaryNotFound(searched: [String])
        case socketTimeout(missing: [String], seconds: TimeInterval)
        case launchFailed(underlying: String)
        case serverExited(status: Int32, stderr: String)
    }

    public let paths: RuntimePaths
    public let binary: URL

    private let process = Process()
    private let errorPipe = Pipe()
    private let errorLock = NSLock()
    private var errorText = ""

    public init(paths: RuntimePaths, binary: URL) {
        self.paths = paths
        self.binary = binary
    }

    /// Search order: bundled copy, then `PATH`, then the conventional
    /// user-local install location.
    public static func defaultCandidates() -> [URL] {
        var candidates: [URL] = []
        if let bundled = Bundle.main.url(forResource: "herdr", withExtension: nil) {
            candidates.append(bundled)
        }
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            candidates.append(URL(fileURLWithPath: String(directory)).appendingPathComponent("herdr"))
        }
        candidates.append(
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".local/bin/herdr")
        )
        return candidates
    }

    public static func locateBinary(candidates: [URL] = defaultCandidates()) -> URL? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public var capturedStderr: String {
        errorLock.lock()
        defer { errorLock.unlock() }
        return errorText
    }

    public var isRunning: Bool { process.isRunning }

    public func start() throws {
        try paths.writeConfig()

        process.executableURL = binary
        process.arguments = ["server"]
        process.environment = paths.environment(basedOn: ProcessInfo.processInfo.environment)
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.errorLock.lock()
            self?.errorText += text
            self?.errorLock.unlock()
        }

        do {
            try process.run()
        } catch {
            throw Failure.launchFailed(underlying: String(describing: error))
        }
    }

    /// Polls until both sockets exist. A dead server is reported immediately
    /// with its stderr rather than after the full timeout.
    public func waitForSockets(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let missing = [paths.apiSocket, paths.clientSocket]
                .filter { !FileManager.default.fileExists(atPath: $0.path) }
            if missing.isEmpty { return }

            if process.isRunning == false, process.processIdentifier != 0 {
                throw Failure.serverExited(
                    status: process.terminationStatus,
                    stderr: capturedStderr
                )
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let missing = [paths.apiSocket, paths.clientSocket]
            .filter { !FileManager.default.fileExists(atPath: $0.path) }
            .map(\.path)
        throw Failure.socketTimeout(missing: missing, seconds: timeout)
    }

    /// M1 stops the server with SIGTERM. Once M3 adds `ApiClient`, prefer the
    /// `server.stop` API and fall back to this.
    public func stop() {
        errorPipe.fileHandleForReading.readabilityHandler = nil
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cd macos-client && xcodegen generate && ./Scripts/test.sh -only-testing:HerdrKitTests/HerdrRuntimeTests
```

Expected: 5 个 test case passed

- [ ] **Step 5: 提交**

```bash
cd macos-client && git add -A && git commit -m "feat: manage embedded herdr server process"
```

---

## Task 14: 客户端协议连接

**Files:**
- Create: `macos-client/Sources/HerdrKit/Protocol/ClientProtocolConn.swift`
- Create: `macos-client/Tests/HerdrKitTests/ClientProtocolConnTests.swift`

- [ ] **Step 1: 写失败测试**

用 `socketpair` 扮演 server，验证握手的三种结果与帧分发。

`Tests/HerdrKitTests/ClientProtocolConnTests.swift`:

```swift
import Darwin
import XCTest
@testable import HerdrKit

final class ClientProtocolConnTests: XCTestCase {
    private func makePair() throws -> (client: UnixSocket, server: UnixSocket) {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        return (UnixSocket(adopting: fds[0]), UnixSocket(adopting: fds[1]))
    }

    private func welcomePayload(version: UInt32, error: String?) -> [UInt8] {
        var out: [UInt8] = [0x00]
        out += Varint.encode(UInt64(version))
        out += Varint.encode(UInt64(0))
        if let error {
            out.append(1)
            out += Varint.encode(UInt64(error.utf8.count))
            out += Array(error.utf8)
        } else {
            out.append(0)
        }
        return out
    }

    func testHandshakeSendsHelloAndAcceptsMatchingVersion() throws {
        let (client, server) = try makePair()
        defer { client.close(); server.close() }

        try server.write(Framing.frame(welcomePayload(version: 19, error: nil)))

        let conn = ClientProtocolConn(socket: client)
        XCTAssertNoThrow(
            try conn.handshake(columns: 100, rows: 30, cellWidth: 8, cellHeight: 16)
        )

        let prefix = try server.readExactly(4)
        let length = try Framing.payloadLength(from: prefix)
        let payload = try server.readExactly(length)
        XCTAssertEqual(payload, WireEncoder.hello(columns: 100, rows: 30, cellWidth: 8, cellHeight: 16))
    }

    func testHandshakeRejectsVersionMismatch() throws {
        let (client, server) = try makePair()
        defer { client.close(); server.close() }
        try server.write(Framing.frame(welcomePayload(version: 18, error: nil)))

        let conn = ClientProtocolConn(socket: client)
        XCTAssertThrowsError(
            try conn.handshake(columns: 80, rows: 24, cellWidth: 8, cellHeight: 16)
        ) { error in
            guard case .protocolVersionMismatch(let server, let client) =
                error as? ClientProtocolConn.Failure
            else {
                return XCTFail("expected protocolVersionMismatch, got \(error)")
            }
            XCTAssertEqual(server, 18)
            XCTAssertEqual(client, 19)
        }
    }

    func testHandshakeSurfacesServerError() throws {
        let (client, server) = try makePair()
        defer { client.close(); server.close() }
        try server.write(Framing.frame(welcomePayload(version: 19, error: "no room")))

        let conn = ClientProtocolConn(socket: client)
        XCTAssertThrowsError(
            try conn.handshake(columns: 80, rows: 24, cellWidth: 8, cellHeight: 16)
        ) { error in
            XCTAssertEqual(
                error as? ClientProtocolConn.Failure,
                .handshakeRejected("no room")
            )
        }
    }

    func testHandshakeRejectsNonWelcomeFirstMessage() throws {
        let (client, server) = try makePair()
        defer { client.close(); server.close() }
        try server.write(Framing.frame([0x08]))  // ReloadSoundConfig

        let conn = ClientProtocolConn(socket: client)
        XCTAssertThrowsError(
            try conn.handshake(columns: 80, rows: 24, cellWidth: 8, cellHeight: 16)
        ) { error in
            XCTAssertEqual(
                error as? ClientProtocolConn.Failure,
                .unexpectedFirstMessage(variantDescription: "ignored(9223372036854775807)")
            )
        }
    }

    func testReadLoopDeliversFramesAndIgnoresOtherVariants() throws {
        let (client, server) = try makePair()
        defer { client.close(); server.close() }

        var framePayload: [UInt8] = [0x01]
        framePayload += Varint.encode(UInt64(1))     // one cell
        framePayload += Varint.encode(UInt64(1))
        framePayload += [0x41]                       // "A"
        framePayload += Varint.encode(UInt64(0))
        framePayload += Varint.encode(UInt64(0))
        framePayload += Varint.encode(UInt64(0))
        framePayload.append(0)
        framePayload.append(0)
        framePayload += Varint.encode(UInt64(1))     // width
        framePayload += Varint.encode(UInt64(1))     // height
        framePayload.append(0)                       // cursor None
        framePayload += Varint.encode(UInt64(0))
        framePayload += Varint.encode(UInt64(0))

        try server.write(Framing.frame([0x09, 0x01]))   // MouseCapture, must be ignored
        try server.write(Framing.frame(framePayload))

        let received = expectation(description: "frame delivered")
        let box = FrameBox()
        let conn = ClientProtocolConn(socket: client)
        conn.startReadLoop(
            onFrame: { frame in
                box.frame = frame
                received.fulfill()
            },
            onShutdown: { _ in },
            onFailure: { XCTFail("unexpected failure: \($0)") }
        )
        wait(for: [received], timeout: 5)
        conn.stop()

        XCTAssertEqual(box.frame?.cells.first?.symbol, "A")
    }

    func testReadLoopReportsShutdown() throws {
        let (client, server) = try makePair()
        defer { client.close(); server.close() }

        var payload: [UInt8] = [0x04, 0x01]
        payload += Varint.encode(UInt64(5))
        payload += Array("adieu".utf8)
        try server.write(Framing.frame(payload))

        let notified = expectation(description: "shutdown reported")
        let box = ReasonBox()
        let conn = ClientProtocolConn(socket: client)
        conn.startReadLoop(
            onFrame: { _ in },
            onShutdown: { reason in
                box.reason = reason
                notified.fulfill()
            },
            onFailure: { _ in }
        )
        wait(for: [notified], timeout: 5)
        conn.stop()

        XCTAssertEqual(box.reason, "adieu")
    }

    private final class FrameBox: @unchecked Sendable {
        var frame: GridFrame?
    }

    private final class ReasonBox: @unchecked Sendable {
        var reason: String?
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd macos-client && ./Scripts/test.sh -only-testing:HerdrKitTests/ClientProtocolConnTests
```

Expected: 编译失败，`cannot find 'ClientProtocolConn' in scope`

- [ ] **Step 3: 实现**

`Sources/HerdrKit/Protocol/ClientProtocolConn.swift`:

```swift
import Foundation

/// One connection on herdr's client protocol socket.
public final class ClientProtocolConn: @unchecked Sendable {
    public enum Failure: Error, Equatable {
        case handshakeRejected(String)
        case protocolVersionMismatch(server: UInt32, client: UInt32)
        case unexpectedFirstMessage(variantDescription: String)
    }

    private let socket: UnixSocket
    private var readThread: Thread?
    private let stopFlag = StopFlag()

    public init(socket: UnixSocket) {
        self.socket = socket
    }

    /// Sends `Hello` and validates `Welcome`.
    ///
    /// A version mismatch is fatal by design: the bundled binary and this app
    /// are versioned together, so a mismatch means the install is broken
    /// rather than something to negotiate around.
    public func handshake(
        columns: UInt16,
        rows: UInt16,
        cellWidth: UInt32,
        cellHeight: UInt32
    ) throws {
        try send(
            WireEncoder.hello(
                columns: columns,
                rows: rows,
                cellWidth: cellWidth,
                cellHeight: cellHeight
            )
        )

        let message = try readMessage()
        guard case .welcome(let version, _, let error) = message else {
            throw Failure.unexpectedFirstMessage(variantDescription: String(describing: message))
        }
        if let error {
            throw Failure.handshakeRejected(error)
        }
        guard version == HerdrKit.protocolVersion else {
            throw Failure.protocolVersionMismatch(
                server: version,
                client: HerdrKit.protocolVersion
            )
        }
    }

    public func send(_ payload: [UInt8]) throws {
        try socket.write(Framing.frame(payload))
    }

    public func startReadLoop(
        onFrame: @escaping @Sendable (GridFrame) -> Void,
        onShutdown: @escaping @Sendable (String?) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        let thread = Thread { [weak self] in
            guard let self else { return }
            while !self.stopFlag.isSet {
                do {
                    switch try self.readMessage() {
                    case .frame(let frame):
                        onFrame(frame)
                    case .shutdown(let reason):
                        onShutdown(reason)
                        return
                    case .welcome, .ignored:
                        continue
                    }
                } catch {
                    if !self.stopFlag.isSet {
                        onFailure(error)
                    }
                    return
                }
            }
        }
        thread.name = "herdr.client-protocol.read"
        thread.stackSize = 1 << 20
        readThread = thread
        thread.start()
    }

    public func stop() {
        stopFlag.set()
        socket.close()
        readThread = nil
    }

    private func readMessage() throws -> ServerMessage {
        let prefix = try socket.readExactly(Framing.prefixSize)
        let length = try Framing.payloadLength(from: prefix)
        let payload = try socket.readExactly(length)
        return try WireDecoder.serverMessage(from: payload)
    }

    private final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cd macos-client && xcodegen generate && ./Scripts/test.sh -only-testing:HerdrKitTests/ClientProtocolConnTests
```

Expected: 6 个 test case passed

若 `testHandshakeRejectsNonWelcomeFirstMessage` 因期望字符串不符而失败，把断言改为只检查是 `.unexpectedFirstMessage`，不比对其描述文本：

```swift
        ) { error in
            guard case .unexpectedFirstMessage = error as? ClientProtocolConn.Failure else {
                return XCTFail("expected unexpectedFirstMessage, got \(error)")
            }
        }
```

- [ ] **Step 5: 提交**

```bash
cd macos-client && git add -A && git commit -m "feat: add client protocol handshake and read loop"
```

---

## Task 15: cell grid 渲染

**Files:**
- Create: `macos-client/Sources/HerdrKit/Terminal/TerminalGridView.swift`
- Create: `macos-client/Tests/HerdrKitTests/TerminalGridViewTests.swift`

不测像素输出（demo 级不值得），只测 cell 尺寸与网格换算这两处会算错的逻辑。

- [ ] **Step 1: 写失败测试**

`Tests/HerdrKitTests/TerminalGridViewTests.swift`:

```swift
import AppKit
import XCTest
@testable import HerdrKit

final class TerminalGridViewTests: XCTestCase {
    private var view: TerminalGridView {
        TerminalGridView(font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
    }

    func testCellSizeIsPositiveAndIntegral() {
        let size = view.cellSize
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
        XCTAssertEqual(size.width, size.width.rounded(), "cell width must be integral to avoid drift")
        XCTAssertEqual(size.height, size.height.rounded())
    }

    func testGridSizeDividesAvailableArea() {
        let subject = view
        let cell = subject.cellSize
        let bounds = CGSize(width: cell.width * 40, height: cell.height * 12)
        let grid = subject.gridSize(for: bounds)
        XCTAssertEqual(grid.columns, 40)
        XCTAssertEqual(grid.rows, 12)
    }

    func testGridSizeFloorsPartialCells() {
        let subject = view
        let cell = subject.cellSize
        let bounds = CGSize(width: cell.width * 10 + cell.width * 0.9, height: cell.height * 5 + 1)
        let grid = subject.gridSize(for: bounds)
        XCTAssertEqual(grid.columns, 10)
        XCTAssertEqual(grid.rows, 5)
    }

    func testGridSizeNeverReturnsZero() {
        let grid = view.gridSize(for: CGSize(width: 1, height: 1))
        XCTAssertEqual(grid.columns, 1)
        XCTAssertEqual(grid.rows, 1)
    }

    func testUpdateStoresFrame() {
        let subject = view
        let frame = GridFrame(
            cells: [
                GridCell(symbol: "A", foreground: 0, background: 0, modifier: 0, skip: false, hyperlink: nil)
            ],
            width: 1,
            height: 1,
            cursor: nil,
            hyperlinks: [],
            graphics: []
        )
        subject.update(frame)
        XCTAssertEqual(subject.currentFrame, frame)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd macos-client && ./Scripts/test.sh -only-testing:HerdrKitTests/TerminalGridViewTests
```

Expected: 编译失败，`cannot find 'TerminalGridView' in scope`

- [ ] **Step 3: 实现**

`Sources/HerdrKit/Terminal/TerminalGridView.swift`:

```swift
import AppKit

/// Draws a `GridFrame` with Core Text.
///
/// Cells are painted one at a time. That is enough for a prototype; if the
/// frame rate proves insufficient, the next step is to merge runs of cells
/// sharing the same attributes into a single draw call.
public final class TerminalGridView: NSView {
    public let cellSize: CGSize
    public private(set) var currentFrame: GridFrame?

    private let regularFont: NSFont
    private let boldFont: NSFont
    private let italicFont: NSFont
    private let defaultForeground: NSColor
    private let defaultBackground: NSColor

    public init(
        font: NSFont,
        foreground: NSColor = NSColor(srgbRed: 0.85, green: 0.85, blue: 0.85, alpha: 1),
        background: NSColor = NSColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1)
    ) {
        self.regularFont = font
        let manager = NSFontManager.shared
        self.boldFont = manager.convert(font, toHaveTrait: .boldFontMask)
        self.italicFont = manager.convert(font, toHaveTrait: .italicFontMask)
        self.defaultForeground = foreground
        self.defaultBackground = background
        self.cellSize = TerminalGridView.measureCell(font: font)
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TerminalGridView is created in code only")
    }

    /// Integral cell metrics. Fractional advances accumulate rounding error
    /// across a wide row and visibly shear the grid.
    public static func measureCell(font: NSFont) -> CGSize {
        let advance = ("M" as NSString).size(withAttributes: [.font: font]).width
        let height = font.ascender - font.descender + font.leading
        return CGSize(width: max(1, advance.rounded()), height: max(1, height.rounded()))
    }

    public func gridSize(for size: CGSize) -> (columns: UInt16, rows: UInt16) {
        let columns = max(1, Int(size.width / cellSize.width))
        let rows = max(1, Int(size.height / cellSize.height))
        return (UInt16(min(columns, Int(UInt16.max))), UInt16(min(rows, Int(UInt16.max))))
    }

    public func update(_ frame: GridFrame) {
        currentFrame = frame
        needsDisplay = true
    }

    /// Row 0 must be at the top, matching the row-major cell order.
    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        defaultBackground.setFill()
        bounds.fill()

        guard let grid = currentFrame else { return }

        for row in 0 ..< Int(grid.height) {
            var column = 0
            while column < Int(grid.width) {
                guard let cell = grid.cell(column: column, row: row) else { break }
                let advance = CharWidth.displayWidth(of: cell.symbol)
                draw(cell, column: column, row: row, advance: advance)
                // Skipping by display width is what keeps wide characters
                // aligned: the next cell is an unmarked filler space.
                column += advance
            }
        }

        drawCursor(grid)
    }

    private func draw(_ cell: GridCell, column: Int, row: Int, advance: Int) {
        let rect = CGRect(
            x: CGFloat(column) * cellSize.width,
            y: CGFloat(row) * cellSize.height,
            width: cellSize.width * CGFloat(advance),
            height: cellSize.height
        )

        let reversed = cell.modifier & Modifier.reversed != 0
        var foreground = TerminalColor.unpack(cell.foreground).nsColor(default: defaultForeground)
        var background = TerminalColor.unpack(cell.background).nsColor(default: defaultBackground)
        if reversed {
            swap(&foreground, &background)
        }

        if background != defaultBackground {
            background.setFill()
            rect.fill()
        }

        guard !cell.symbol.isEmpty, cell.symbol != " " else { return }

        var font = regularFont
        if cell.modifier & Modifier.bold != 0 {
            font = boldFont
        } else if cell.modifier & Modifier.italic != 0 {
            font = italicFont
        }

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: foreground,
        ]
        if cell.modifier & Modifier.underlined != 0 {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }

        let origin = CGPoint(x: rect.minX, y: rect.minY + (cellSize.height + regularFont.descender) - regularFont.ascender)
        (cell.symbol as NSString).draw(
            at: CGPoint(x: origin.x, y: rect.minY),
            withAttributes: attributes
        )
    }

    private func drawCursor(_ grid: GridFrame) {
        guard let cursor = grid.cursor, cursor.isVisible else { return }
        let rect = CGRect(
            x: CGFloat(cursor.column) * cellSize.width,
            y: CGFloat(cursor.row) * cellSize.height,
            width: cellSize.width,
            height: cellSize.height
        )
        defaultForeground.withAlphaComponent(0.6).setFill()
        rect.fill()
    }

    /// ratatui `Modifier` bit positions.
    private enum Modifier {
        static let bold: UInt16 = 1 << 0
        static let dim: UInt16 = 1 << 1
        static let italic: UInt16 = 1 << 2
        static let underlined: UInt16 = 1 << 3
        static let reversed: UInt16 = 1 << 6
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cd macos-client && xcodegen generate && ./Scripts/test.sh -only-testing:HerdrKitTests/TerminalGridViewTests
```

Expected: 5 个 test case passed

- [ ] **Step 5: 提交**

```bash
cd macos-client && git add -A && git commit -m "feat: render cell grid with core text"
```

---

## Task 16: 集成启动序列并验收 M1

把前面的部件接成完整启动序列，端到端跑通。

**Files:**
- Create: `macos-client/Sources/HerdrKit/Runtime/TerminalSession.swift`
- Modify: `macos-client/Sources/HerdrPrototype/ContentView.swift`

- [ ] **Step 1: 写会话编排器**

`Sources/HerdrKit/Runtime/TerminalSession.swift`:

```swift
import AppKit
import Foundation

/// Drives the full startup sequence and feeds frames to a view.
///
/// Sequence: locate binary, write config, spawn server, wait for sockets,
/// connect, handshake, hide herdr's own sidebar, then stream frames.
@MainActor
public final class TerminalSession: ObservableObject {
    public enum State: Equatable {
        case idle
        case starting(String)
        case running
        case failed(String)
        case disconnected(String)
    }

    @Published public private(set) var state: State = .idle

    public let view: TerminalGridView

    private let paths: RuntimePaths
    private var runtime: HerdrRuntime?
    private var connection: ClientProtocolConn?

    public init(
        paths: RuntimePaths = .defaultLocation(),
        font: NSFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    ) {
        self.paths = paths
        self.view = TerminalGridView(font: font)
    }

    public func start(viewportSize: CGSize) {
        guard case .idle = state else { return }

        guard let binary = HerdrRuntime.locateBinary() else {
            state = .failed("herdr binary not found. Searched bundle Resources, PATH and ~/.local/bin.")
            return
        }
        state = .starting("using \(binary.path)")

        let runtime = HerdrRuntime(paths: paths, binary: binary)
        self.runtime = runtime

        let grid = view.gridSize(for: viewportSize)

        Task.detached { [weak self] in
            do {
                try runtime.start()
                try runtime.waitForSockets(timeout: 10)
                let socket = try UnixSocket(connectingTo: runtime.paths.clientSocket.path)
                let connection = ClientProtocolConn(socket: socket)
                try connection.handshake(
                    columns: grid.columns,
                    rows: grid.rows,
                    cellWidth: 8,
                    cellHeight: 16
                )
                // Hide herdr's own sidebar; the native UI replaces it.
                try connection.send(
                    WireEncoder.functionKey(20, modifiers: [.control, .option])
                )
                await self?.attach(connection)
            } catch {
                let stderr = runtime.capturedStderr
                await self?.fail(error, stderr: stderr)
            }
        }
    }

    private func attach(_ connection: ClientProtocolConn) {
        self.connection = connection
        state = .running
        connection.startReadLoop(
            onFrame: { [weak self] frame in
                Task { @MainActor in self?.view.update(frame) }
            },
            onShutdown: { [weak self] reason in
                Task { @MainActor in
                    self?.state = .disconnected(reason ?? "server shut down")
                }
            },
            onFailure: { [weak self] error in
                Task { @MainActor in
                    self?.state = .disconnected(String(describing: error))
                }
            }
        )
    }

    private func fail(_ error: Error, stderr: String) {
        var message = String(describing: error)
        if !stderr.isEmpty {
            message += "\n\nserver stderr:\n" + stderr
        }
        state = .failed(message)
    }

    public func resize(to size: CGSize) {
        guard case .running = state, let connection else { return }
        let grid = view.gridSize(for: size)
        try? connection.send(
            WireEncoder.resize(
                columns: grid.columns,
                rows: grid.rows,
                cellWidth: 8,
                cellHeight: 16
            )
        )
    }

    public func shutdown() {
        connection?.send(WireEncoder.detach()).map { _ in } ?? ()
        connection?.stop()
        runtime?.stop()
        connection = nil
        runtime = nil
        state = .idle
    }
}
```

注意 `shutdown()` 里 `send` 是 `throws` 且返回 `Void`，上面那行写法不合法。改成：

```swift
    public func shutdown() {
        if let connection {
            try? connection.send(WireEncoder.detach())
            connection.stop()
        }
        runtime?.stop()
        connection = nil
        runtime = nil
        state = .idle
    }
```

- [ ] **Step 2: 接入视图**

`Sources/HerdrPrototype/ContentView.swift`（整体替换）:

```swift
import HerdrKit
import SwiftUI

struct ContentView: View {
    @StateObject private var session = TerminalSession()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                GridViewRepresentable(view: session.view)
                    .onAppear { session.start(viewportSize: geometry.size) }
                    .onChange(of: geometry.size) { _, size in session.resize(to: size) }

                switch session.state {
                case .idle, .starting:
                    ProgressView(statusText)
                        .padding()
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                case .failed(let message), .disconnected(let message):
                    ScrollView {
                        Text(message)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding()
                    }
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(40)
                case .running:
                    EmptyView()
                }
            }
        }
        .onDisappear { session.shutdown() }
    }

    private var statusText: String {
        if case .starting(let detail) = session.state { return detail }
        return "starting herdr…"
    }
}

private struct GridViewRepresentable: NSViewRepresentable {
    let view: TerminalGridView

    func makeNSView(context: Context) -> TerminalGridView { view }
    func updateNSView(_ nsView: TerminalGridView, context: Context) {}
}
```

- [ ] **Step 3: 构建并跑全部测试**

```bash
cd macos-client && xcodegen generate && ./Scripts/test.sh
```

Expected: 全部测试 passed，`** TEST SUCCEEDED **`

- [ ] **Step 4: 端到端运行**

```bash
cd macos-client && xcodebuild -project macos-client.xcodeproj -scheme HerdrPrototype -configuration Debug -derivedDataPath build build 2>&1 | tail -3 && open build/Build/Products/Debug/HerdrPrototype.app
```

Expected: 窗口出现，显示 herdr 的终端区（一个 shell 提示符）。

- [ ] **Step 5: 确认隔离生效**

```bash
ls -la ~/Library/Application\ Support/dev.herdr.macos-client-prototype/runtime/ && printf '{"id":"v","method":"pane.list","params":{}}\n' | nc -U ~/Library/Application\ Support/dev.herdr.macos-client-prototype/runtime/herdr.sock | head -c 400
```

Expected: 看到 `herdr.sock`、`herdr-client.sock`、`config/`、`state/`；pane.list 只返回原型自己的 pane，**不包含**开发机上真实 session 的 pane。

同时确认真实 session 未受影响：

```bash
printf '{"id":"v","method":"pane.list","params":{}}\n' | nc -U ~/.config/herdr/herdr.sock | python3 -c "import json,sys; print('real session panes:', len(json.load(sys.stdin)['result']['panes']))"
```

Expected: 数量与原型启动前一致。

- [ ] **Step 6: 逐项走 M1 验收清单**

- [ ] 窗口中无 herdr sidebar 残留（左侧没有 workspace 列表）
- [ ] 终端区内容与 `herdr pane read` 对照一致
- [ ] 颜色正确（对比 TUI 中同一 pane 的观感）
- [ ] 光标位置正确
- [ ] 窗口 resize 后内容重排且不错位

- [ ] **Step 7: 中文对照验证（M1 的关键验收项）**

在原型的终端里跑一条含中日韩与 emoji 的命令，然后用官方 CLI 读同一 pane 逐字符对照：

```bash
printf '{"id":"p","method":"pane.list","params":{}}\n' | nc -U ~/Library/Application\ Support/dev.herdr.macos-client-prototype/runtime/herdr.sock | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['panes'][0]['pane_id'])"
```

拿到 pane id 后（下面以 `w1:p1` 为例），在原型窗口里输入一行含宽字符的文本，再运行：

```bash
HERDR_SOCKET_PATH=~/Library/Application\ Support/dev.herdr.macos-client-prototype/runtime/herdr.sock herdr pane read w1:p1 --format text | head -20
```

Expected: CLI 输出的字符列位置与原型窗口中肉眼所见一致。**若中文之间出现多余空隙或后续字符左移，即为 `CharWidth` 与 ghostty-vt 判断不一致**——记录具体字符，回到 Task 10 修正宽度规则。

注：M1 不处理键盘输入，此步需要输入文本时，用另一个终端通过 API 注入：

```bash
HERDR_SOCKET_PATH=~/Library/Application\ Support/dev.herdr.macos-client-prototype/runtime/herdr.sock herdr pane send-text w1:p1 'echo "更新接口参数 needQuery 👍 done"'
HERDR_SOCKET_PATH=~/Library/Application\ Support/dev.herdr.macos-client-prototype/runtime/herdr.sock herdr pane send-keys w1:p1 Enter
```

- [ ] **Step 8: 记录帧率观感**

在原型终端里通过 API 注入一条产生大量输出的命令（如 `find / -maxdepth 3 2>/dev/null`），观察滚动是否流畅。若明显卡顿，在 `docs/plan-m1.md` 末尾记录现象；优化方向是把 `TerminalGridView.draw` 从逐 cell 绘制改为合并相同属性的 run。**本 task 不做该优化**——先确认是否真的需要。

- [ ] **Step 9: 提交**

```bash
cd macos-client && git add -A && git commit -m "feat: wire up startup sequence and render live frames"
```

---

## 自检结果

**Spec 覆盖对照**

| 设计文档要求 | 对应 task |
|---|---|
| 隔离（XDG_CONFIG_HOME / XDG_STATE_HOME / socket 路径） | Task 11、Task 16 Step 5 |
| config.toml 生成（sidebar hidden + toggle 绑定） | Task 11 |
| 启动序列 8 步 | Task 13、14、16 |
| 定位 binary 三级回落 | Task 13 |
| 协议版本严格校验 | Task 14 |
| 发一次 toggle 隐藏 sidebar | Task 6、Task 16 |
| framing + bincode varint | Task 2、3 |
| Hello / Resize / Detach 编码 | Task 5 |
| `InputEvents` 的 Key 编码（M1 也需要） | Task 6 |
| GridFrame 解码 + 严格字节数校验 | Task 7、8 |
| 未关心变体整帧丢弃 | Task 8 |
| `graphics` 照常解码但不渲染 | Task 7（解码）、Task 15（不绘制） |
| 颜色三种编码 | Task 9 |
| modifier（含 Reversed） | Task 15 |
| CharWidth 与宽字符跳格 | Task 10、Task 15 |
| 错误可诊断（stderr、明确信息） | Task 13、16 |
| 三个纯函数组件的单测 | Task 2、5–11 |
| M1 手动验收清单 | Task 16 Step 6–8 |

无未覆盖项。`ApiClient` 与 `InputTranslator` 属 M2/M3，本计划不含，符合范围划分。

**已知偏离设计文档之处（有意为之，已在对应 task 说明理由）**

1. `stop()` 在 M1 用 SIGTERM 而非 `server.stop` API——M1 没有 `ApiClient`。Task 13 已注明 M3 再改。
2. 设计文档原先列出 `HERDR_SESSION`；实现改用 `HERDR_SOCKET_PATH` 显式指定，使两个 socket 路径完全确定而不必推断 session 路径规则。Task 11 已说明，设计文档 §4 已同步回写（并补入「必须清除继承的 `HERDR_*`」这一原先遗漏的要点）。

**类型一致性**：`GridFrame` / `GridCell` / `GridCursor` / `ServerMessage` / `ByteReader.Failure` / `WireDecoder.Failure` / `WireEncoder.Modifiers` / `UnixSocket.Failure` / `HerdrRuntime.Failure` / `ClientProtocolConn.Failure` 在各 task 间命名与签名一致；`Framing.prefixSize` 在 Task 3 定义、Task 14 使用；`HerdrKit.protocolVersion` 在 Task 1 定义、Task 5/14 使用。

