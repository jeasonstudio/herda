# 原生 split 布局 — 计划四：交互（坐标、拖分隔线、滚动条）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 鼠标事件落到正确的 pane；pane 之间的间隙可以拖动改变分割比例；每个 pane 卡片右侧有原生滚动条。

**Architecture:** 三件事都建立在计划二的纯函数上。坐标偏移加在 `TerminalGridView` 内部（鼠标 payload 是它自己发的，在外面换算会漏掉滚轮）；拖动手柄从 pane rect 的几何推出来，不复现 herdr 的布局算法；滚动条读 snapshot 轮询来的 `PaneInfo.scroll`，拖动时本地乐观更新。

**Tech Stack:** Swift 6 严格并发 / AppKit `NSEvent` / SwiftUI / XCTest

**前置：** 计划三完成。计划三末尾留下一个已知缺陷 —— 每个 pane 的 view 把局部 cell 坐标当全局坐标发出去，点击和滚轮会打到错的 pane。Task 1 修它。

**完成后的可见变化：** 点击任一 pane 能正确聚焦它、在它里面滚轮滚它自己、拖间隙能改变分割比例、内容超过一屏时右侧出现原生滚动条。阶段 1 到此完成。

---

## File Structure

| 文件 | 责任 | 改动 |
|---|---|---|
| `Sources/HerdaKit/Terminal/TerminalGridView.swift` | 单个 pane 的渲染与输入 | 新增 `cellOrigin`，`cellPosition` 叠加它 |
| `Sources/HerdaKit/Layout/SplitHandles.swift` | **新增** — 从 pane 几何推出可拖手柄 | |
| `Sources/HerdaKit/Runtime/TerminalSession.swift` | 协调者 | 设置每个 view 的 `cellOrigin`；缓存 `PaneScrollInfo`；`setSplitRatio` 出口 |
| `Sources/Herda/PaneGridView.swift` | 卡片布局 | 叠加拖动手柄与滚动条 |
| `Tests/HerdaKitTests/SplitHandlesTests.swift` | **新增** | |
| `Tests/HerdaKitTests/TerminalGridInputTests.swift` | 输入 | 新增 `cellOrigin` 的断言 |

---

## Task 1: `cellOrigin` — 让鼠标事件带全局 grid 坐标

herdr 用 `pane_at(col, row)`（`src/app/input/mouse.rs:1426`）决定鼠标事件属于哪个 pane，所以事件里必须是整块 grid 的坐标。每个 pane 的 view 局部 `(0,0)` 对应全局 `(rect.x, rect.y)`。

偏移必须加在 view 内部：`sendMouse`（`TerminalGridView.swift:230`）自己调 `cellPosition` 并发 payload，`scrollWheel`（`:256`）也走它。在外面换算会漏掉滚轮。

**Files:**
- Modify: `Sources/HerdaKit/Terminal/TerminalGridView.swift:219-228`
- Modify: `Sources/HerdaKit/Runtime/TerminalSession.swift`
- Test: `Tests/HerdaKitTests/TerminalGridInputTests.swift`

- [ ] **Step 1: 写失败的测试**

追加到 `TerminalGridInputTests.swift`：

```swift
func testCellPositionIsRelativeToTheGridWhenOriginIsSet() {
    // 每个 pane 的 view 局部 (0,0) 是它 rect 的左上角。herdr 按整块 grid 的
    // 坐标命中 pane(pane_at(col,row)),所以发出去的必须是全局坐标。
    let view = TerminalGridView(terminalFont: TerminalFont(size: 13))
    view.cellOrigin = (column: 40, row: 2)
    let cell = view.cellSize

    let position = view.cellPosition(
        for: CGPoint(x: cell.width * 1.5, y: cell.height * 3.5)
    )
    XCTAssertEqual(position.column, 41)
    XCTAssertEqual(position.row, 5)
}

func testCellPositionDefaultsToNoOffset() {
    // 回退到整块渲染时用的那个 view 没有偏移。
    let view = TerminalGridView(terminalFont: TerminalFont(size: 13))
    let cell = view.cellSize
    let position = view.cellPosition(for: CGPoint(x: cell.width * 2, y: 0))
    XCTAssertEqual(position.column, 2)
    XCTAssertEqual(position.row, 0)
}

func testMouseDownReportsGlobalColumnAndRow() throws {
    // 端到端:构造一个 NSEvent 走真实的 mouseDown,断言 payload 里的坐标带了偏移。
    // 不用 GUI 自动化 —— 见 CLAUDE.md「Do not use GUI keyboard automation」。
    let view = TerminalGridView(terminalFont: TerminalFont(size: 13))
    view.cellOrigin = (column: 10, row: 4)
    view.setFrameSize(CGSize(width: 400, height: 400))

    var payloads: [[UInt8]] = []
    view.onPayload = { payloads.append($0) }

    let cell = view.cellSize
    let event = try XCTUnwrap(NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: CGPoint(x: cell.width * 2 + 1, y: cell.height * 1 + 1),
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
    ))
    view.mouseDown(with: event)

    let expected = WireEncoder.mouse(
        .down(.left), column: 12, row: 5, modifiers: []
    )
    XCTAssertEqual(payloads.last, expected)
}
```

`mouseDown` 里的 `convert(event.locationInWindow, from: nil)` 在没有 window 时返回原坐标，而 view 是 flipped，所以 location 直接当作 view 坐标使用。若断言的 row 与实际差一，先打印 `view.cellPosition(for:)` 的输入确认翻转方向，再改测试里的期望值 —— 不要改生产代码去迁就测试。

- [ ] **Step 2: 运行测试确认失败**

Run: `Scripts/test.sh 2>&1 | grep -E "cellOrigin|error:" | head -5`

Expected: `value of type 'TerminalGridView' has no member 'cellOrigin'`。

- [ ] **Step 3: 实现**

在 `TerminalGridView` 的 `cellSize`（`:22`）之后加：

```swift
    /// 这个 view 的左上角在整块 grid 里的 cell 坐标。
    ///
    /// 每个 pane 一个 view,但只有一条 render 连接:server 按整块 grid 的坐标
    /// 用 `pane_at(col, row)` 决定鼠标事件属于哪个 pane。所以发出去的坐标必须
    /// 加上这个偏移,否则点第二个 pane 会被当成点第一个。
    ///
    /// 偏移加在这里而不是调用点:`sendMouse` 自己调 `cellPosition` 并发 payload,
    /// 滚轮也走它。在外面换算会漏掉滚轮。
    public var cellOrigin: (column: UInt16, row: UInt16) = (0, 0)
```

把 `cellPosition(for:)`（`:221-228`）改为：

```swift
    public func cellPosition(for point: CGPoint) -> (column: UInt16, row: UInt16) {
        let column = max(0, Int(point.x / cellSize.width)) + Int(cellOrigin.column)
        let row = max(0, Int(point.y / cellSize.height)) + Int(cellOrigin.row)
        return (
            UInt16(min(column, Int(UInt16.max))),
            UInt16(min(row, Int(UInt16.max)))
        )
    }
```

在 `TerminalSession.applyLayout` 里给每个 view 设置偏移。把计划三的 `applyLayout` 改为：

```swift
    private func applyLayout(_ snapshot: PaneLayoutSnapshot) {
        router.apply(snapshot)
        let live = Set(snapshot.panes.map(\.paneId))
        for paneId in paneViews.keys where !live.contains(paneId) {
            paneViews.removeValue(forKey: paneId)
        }
        // 偏移必须跟着布局更新:split 之后每个 pane 的 rect 都可能变,漏掉这一步
        // 点击会打到错的 pane。zoom 时焦点 pane 铺满 area,偏移回到 area 的原点。
        for pane in LayoutGeometry.visiblePanes(in: snapshot) {
            let view = viewForPane(pane.paneId)
            view.cellOrigin = (column: pane.rect.x, row: pane.rect.y)
        }
    }
```

- [ ] **Step 4: 运行测试确认通过**

Run: `Scripts/test.sh 2>&1 | tail -5`

Expected: 全部通过。

- [ ] **Step 5: 手动验证**

```bash
Scripts/run.sh --reset
```

split 出两个 pane，在右边那个 pane 里点一下并打字，确认字出现在右边 pane。再在右边 pane 里滚轮，确认滚的是它自己而不是左边。

- [ ] **Step 6: 提交**

```bash
git add Sources/HerdaKit/Terminal/TerminalGridView.swift Sources/HerdaKit/Runtime/TerminalSession.swift Tests/HerdaKitTests/TerminalGridInputTests.swift
git commit -m "fix: report mouse positions in whole-grid coordinates

There is one view per pane but still one render connection, and herdr decides
which pane a mouse event belongs to with pane_at(col,row) on whole-grid
coordinates. Without the offset, clicking the second pane was reported as
clicking the first.

The offset lives on the view because sendMouse calls cellPosition and emits the
payload itself, and scrollWheel goes through the same path — converting at the
call site would have silently missed the wheel. applyLayout refreshes it on every
layout change, since a split moves every rect."
```

---

## Task 2: 拖间隙改变分割比例

**Files:**
- Create: `Sources/HerdaKit/Layout/SplitHandles.swift`
- Create: `Tests/HerdaKitTests/SplitHandlesTests.swift`
- Modify: `Sources/HerdaKit/Runtime/TerminalSession.swift`
- Modify: `Sources/Herda/PaneGridView.swift`

- [ ] **Step 1: 写失败的测试**

```swift
import XCTest
@testable import HerdaKit

final class SplitHandlesTests: XCTestCase {
    /// 左右两 pane:左 0..<39,间隙第 39 列,右 40..<80。
    private let horizontal = PaneLayoutSnapshot(
        workspaceId: "w1", tabId: "w1:t1", zoomed: false,
        area: PaneLayoutRect(x: 0, y: 0, width: 80, height: 24),
        focusedPaneId: "w1:p1",
        panes: [
            PaneLayoutPane(paneId: "w1:p1", focused: true,
                           rect: PaneLayoutRect(x: 0, y: 0, width: 39, height: 24)),
            PaneLayoutPane(paneId: "w1:p2", focused: false,
                           rect: PaneLayoutRect(x: 40, y: 0, width: 40, height: 24)),
        ],
        splits: [
            PaneLayoutSplit(id: "s0", direction: .right, ratio: 0.5,
                            rect: PaneLayoutRect(x: 0, y: 0, width: 80, height: 24)),
        ]
    )

    func testFindsTheVerticalGapBetweenSideBySidePanes() {
        let handles = SplitHandles.handles(in: horizontal)
        XCTAssertEqual(handles.count, 1)
        let handle = handles[0]
        XCTAssertEqual(handle.splitId, "s0")
        XCTAssertEqual(handle.direction, .right)
        // 手柄就是那一格间隙。
        XCTAssertEqual(handle.rect, PaneLayoutRect(x: 39, y: 0, width: 1, height: 24))
    }

    func testFindsTheHorizontalGapBetweenStackedPanes() {
        let stacked = PaneLayoutSnapshot(
            workspaceId: "w1", tabId: "w1:t1", zoomed: false,
            area: PaneLayoutRect(x: 0, y: 0, width: 80, height: 24),
            focusedPaneId: "w1:p1",
            panes: [
                PaneLayoutPane(paneId: "w1:p1", focused: true,
                               rect: PaneLayoutRect(x: 0, y: 0, width: 80, height: 11)),
                PaneLayoutPane(paneId: "w1:p2", focused: false,
                               rect: PaneLayoutRect(x: 0, y: 12, width: 80, height: 12)),
            ],
            splits: [
                PaneLayoutSplit(id: "s0", direction: .down, ratio: 0.5,
                                rect: PaneLayoutRect(x: 0, y: 0, width: 80, height: 24)),
            ]
        )
        let handles = SplitHandles.handles(in: stacked)
        XCTAssertEqual(handles.count, 1)
        XCTAssertEqual(handles[0].direction, .down)
        XCTAssertEqual(handles[0].rect, PaneLayoutRect(x: 0, y: 11, width: 80, height: 1))
    }

    func testSinglePaneHasNoHandles() {
        let single = PaneLayoutSnapshot(
            workspaceId: "w1", tabId: "w1:t1", zoomed: false,
            area: PaneLayoutRect(x: 0, y: 0, width: 80, height: 24),
            focusedPaneId: "w1:p1",
            panes: [PaneLayoutPane(paneId: "w1:p1", focused: true,
                                   rect: PaneLayoutRect(x: 0, y: 0, width: 80, height: 24))],
            splits: []
        )
        XCTAssertTrue(SplitHandles.handles(in: single).isEmpty)
    }

    func testZoomedHasNoHandles() {
        // zoom 时只有一张卡片铺满,没有可拖的缝。
        let zoomed = PaneLayoutSnapshot(
            workspaceId: "w1", tabId: "w1:t1", zoomed: true,
            area: horizontal.area, focusedPaneId: "w1:p1",
            panes: horizontal.panes, splits: horizontal.splits
        )
        XCTAssertTrue(SplitHandles.handles(in: zoomed).isEmpty)
    }

    func testIgnoresPanesThatDoNotOverlapOnTheOtherAxis() {
        // 田字格布局里,右上和左下水平相隔一格但垂直不重叠 —— 它们之间没有缝。
        let quad = PaneLayoutSnapshot(
            workspaceId: "w1", tabId: "w1:t1", zoomed: false,
            area: PaneLayoutRect(x: 0, y: 0, width: 80, height: 24),
            focusedPaneId: "w1:p1",
            panes: [
                PaneLayoutPane(paneId: "a", focused: true,
                               rect: PaneLayoutRect(x: 0, y: 0, width: 39, height: 11)),
                PaneLayoutPane(paneId: "b", focused: false,
                               rect: PaneLayoutRect(x: 40, y: 12, width: 40, height: 12)),
            ],
            splits: [
                PaneLayoutSplit(id: "s0", direction: .right, ratio: 0.5,
                                rect: PaneLayoutRect(x: 0, y: 0, width: 80, height: 24)),
            ]
        )
        XCTAssertTrue(SplitHandles.handles(in: quad).isEmpty)
    }

    func testRatioFromDraggedPosition() {
        // 拖到第 20 列 → 20/80。
        let handle = SplitHandles.handles(in: horizontal)[0]
        let ratio = SplitHandles.ratio(forGridColumn: 20, row: 0, handle: handle)
        XCTAssertEqual(ratio, 0.25, accuracy: 0.0001)
    }

    func testRatioIsClampedToAUsableRange() {
        // 拖到边缘不能产出 0 或 1 —— 那会让一侧变成 0 列,herdr 会拒绝或产生退化布局。
        let handle = SplitHandles.handles(in: horizontal)[0]
        XCTAssertEqual(SplitHandles.ratio(forGridColumn: 0, row: 0, handle: handle), 0.05, accuracy: 0.0001)
        XCTAssertEqual(SplitHandles.ratio(forGridColumn: 79, row: 0, handle: handle), 0.95, accuracy: 0.0001)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `Scripts/test.sh 2>&1 | grep -E "SplitHandles|error:" | head -5`

Expected: `cannot find 'SplitHandles' in scope`。

- [ ] **Step 3: 实现**

创建 `Sources/HerdaKit/Layout/SplitHandles.swift`：

```swift
import Foundation

/// 一条可拖动的分隔缝。
public struct SplitHandle: Equatable, Sendable, Identifiable {
    /// `layout.set_split_ratio` 的目标。
    public let splitId: String
    public let direction: SplitDirection
    /// 缝本身,恰好一格宽(或高)。
    public let rect: PaneLayoutRect
    /// 这条 split 覆盖的总区域。拖动位置换算成 ratio 时的分母。
    public let splitRect: PaneLayoutRect

    public var id: String { splitId }

    public init(
        splitId: String,
        direction: SplitDirection,
        rect: PaneLayoutRect,
        splitRect: PaneLayoutRect
    ) {
        self.splitId = splitId
        self.direction = direction
        self.rect = rect
        self.splitRect = splitRect
    }
}

/// 从 pane 的几何推出可拖手柄。
///
/// **不用 `split.ratio` 反算分隔线位置。** 那要在客户端复现 herdr 的布局算法
/// (整除、余数归谁、最小尺寸),复现错了就会得到一条拖不准的缝。改成直接找几何
/// 事实:两个 pane 在一个轴上相隔恰好一格、在另一个轴上重叠,中间那一格就是缝。
/// split id 再用「缝落在哪个 `split.rect` 里且 direction 匹配」反查。
public enum SplitHandles {
    public static func handles(in snapshot: PaneLayoutSnapshot) -> [SplitHandle] {
        // zoom 时只有一张卡片铺满,没有缝可拖。
        guard !snapshot.zoomed else { return [] }

        var found: [SplitHandle] = []
        var seen = Set<String>()

        for left in snapshot.panes {
            for right in snapshot.panes where left.paneId != right.paneId {
                if let gap = verticalGap(between: left, and: right),
                   let split = split(containing: gap, direction: .right, in: snapshot),
                   seen.insert(split.id).inserted {
                    found.append(SplitHandle(
                        splitId: split.id, direction: .right,
                        rect: gap, splitRect: split.rect
                    ))
                }
                if let gap = horizontalGap(between: left, and: right),
                   let split = split(containing: gap, direction: .down, in: snapshot),
                   seen.insert(split.id).inserted {
                    found.append(SplitHandle(
                        splitId: split.id, direction: .down,
                        rect: gap, splitRect: split.rect
                    ))
                }
            }
        }
        return found
    }

    /// 拖到某个 grid 位置时对应的新 ratio。
    ///
    /// 夹在 0.05…0.95:拖到边缘若产出 0 或 1,一侧会变成 0 列,herdr 要么拒绝要么
    /// 给出退化布局。
    public static func ratio(
        forGridColumn column: UInt16,
        row: UInt16,
        handle: SplitHandle
    ) -> Double {
        let raw: Double
        switch handle.direction {
        case .right:
            guard handle.splitRect.width > 0 else { return 0.5 }
            raw = Double(Int(column) - Int(handle.splitRect.x)) / Double(handle.splitRect.width)
        case .down:
            guard handle.splitRect.height > 0 else { return 0.5 }
            raw = Double(Int(row) - Int(handle.splitRect.y)) / Double(handle.splitRect.height)
        }
        return min(0.95, max(0.05, raw))
    }

    /// `left` 的右边缘与 `right` 的左边缘之间恰好一格,且两者垂直重叠。
    private static func verticalGap(
        between left: PaneLayoutPane,
        and right: PaneLayoutPane
    ) -> PaneLayoutRect? {
        let leftEnd = Int(left.rect.x) + Int(left.rect.width)
        guard Int(right.rect.x) == leftEnd + 1 else { return nil }
        guard let overlap = overlap(
            start: Int(left.rect.y), length: Int(left.rect.height),
            otherStart: Int(right.rect.y), otherLength: Int(right.rect.height)
        ) else { return nil }
        return PaneLayoutRect(
            x: UInt16(leftEnd), y: UInt16(overlap.start),
            width: 1, height: UInt16(overlap.length)
        )
    }

    /// `top` 的下边缘与 `bottom` 的上边缘之间恰好一格,且两者水平重叠。
    private static func horizontalGap(
        between top: PaneLayoutPane,
        and bottom: PaneLayoutPane
    ) -> PaneLayoutRect? {
        let topEnd = Int(top.rect.y) + Int(top.rect.height)
        guard Int(bottom.rect.y) == topEnd + 1 else { return nil }
        guard let overlap = overlap(
            start: Int(top.rect.x), length: Int(top.rect.width),
            otherStart: Int(bottom.rect.x), otherLength: Int(bottom.rect.width)
        ) else { return nil }
        return PaneLayoutRect(
            x: UInt16(overlap.start), y: UInt16(topEnd),
            width: UInt16(overlap.length), height: 1
        )
    }

    private static func overlap(
        start: Int, length: Int,
        otherStart: Int, otherLength: Int
    ) -> (start: Int, length: Int)? {
        let begin = max(start, otherStart)
        let end = min(start + length, otherStart + otherLength)
        guard end > begin else { return nil }
        return (start: begin, length: end - begin)
    }

    private static func split(
        containing gap: PaneLayoutRect,
        direction: SplitDirection,
        in snapshot: PaneLayoutSnapshot
    ) -> PaneLayoutSplit? {
        snapshot.splits.first { split in
            guard split.direction == direction else { return false }
            return Int(gap.x) >= Int(split.rect.x)
                && Int(gap.x) < Int(split.rect.x) + Int(split.rect.width)
                && Int(gap.y) >= Int(split.rect.y)
                && Int(gap.y) < Int(split.rect.y) + Int(split.rect.height)
        }
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `Scripts/test.sh 2>&1 | tail -5`

Expected: 全部通过。

- [ ] **Step 5: 加 session 出口**

在 `TerminalSession` 里加（放在 `focusPane` 之后）：

```swift
    public func setSplitRatio(_ splitId: String, ratio: Double) {
        guard let api else { return }
        Task.detached { [weak self] in
            do {
                try api.setSplitRatio(splitId, ratio: ratio)
            } catch {
                await MainActor.run { self?.log("set split ratio failed: \(error)") }
            }
        }
    }

    /// 当前可拖的分隔缝。
    public var splitHandles: [SplitHandle] { router.splitHandles }
```

并在 `PaneFrameRouter` 里加：

```swift
    public var splitHandles: [SplitHandle] {
        guard let snapshot else { return [] }
        return SplitHandles.handles(in: snapshot)
    }
```

- [ ] **Step 6: 在 `PaneGridView` 里叠加手柄**

在 `PaneGridView` 的 `ZStack` 里（`ForEach(session.router.visiblePanes)` 之后）加：

```swift
                        ForEach(session.splitHandles) { handle in
                            dragHandle(handle)
                        }
```

并新增（`paneCard` 之后）：

```swift
    /// 一条可拖的缝。命中区比那一格宽 —— 8pt 太窄,HIG 的最小命中目标要大得多。
    /// 视觉上不画任何东西:缝本来就是卡片之间的空隙,加一条线会把「间距取代分隔线」
    /// 这个决定推翻掉。
    @ViewBuilder private func dragHandle(_ handle: SplitHandle) -> some View {
        let frame = LayoutGeometry.frame(for: handle.rect, cellSize: session.cellSize)
        let hitPadding: CGFloat = 4

        Color.clear
            .frame(
                width: frame.width + (handle.direction == .right ? hitPadding * 2 : 0),
                height: frame.height + (handle.direction == .down ? hitPadding * 2 : 0)
            )
            .contentShape(Rectangle())
            .offset(
                x: frame.minX - (handle.direction == .right ? hitPadding : 0),
                y: frame.minY - (handle.direction == .down ? hitPadding : 0)
            )
            .onHover { inside in
                if inside {
                    (handle.direction == .right
                        ? NSCursor.resizeLeftRight
                        : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(coordinateSpace: .named(Self.gridSpace))
                    .onEnded { value in
                        // 拖动过程中不发请求:布局的真相在 herdr,每一帧都往返会
                        // 让拖动变成一串迟到的跳变。松手发一次,事件回来对齐。
                        let position = LayoutGeometry.gridPosition(
                            forPointInPane: value.location,
                            paneRect: PaneLayoutRect(x: 0, y: 0, width: 0, height: 0),
                            cellSize: session.cellSize
                        )
                        session.setSplitRatio(
                            handle.splitId,
                            ratio: SplitHandles.ratio(
                                forGridColumn: position.column,
                                row: position.row,
                                handle: handle
                            )
                        )
                    }
            )
    }

    static let gridSpace = "herda.pane-grid"
```

并给 `GeometryReader` 里的 `ZStack` 加坐标空间：

```swift
            ZStack(alignment: .topLeading) {
                // ...
            }
            .coordinateSpace(name: Self.gridSpace)
```

- [ ] **Step 7: 编译并手动验证**

Run: `xcodegen generate && Scripts/test.sh 2>&1 | tail -5`

```bash
Scripts/run.sh --reset
```

split 出两个 pane，把光标移到缝上确认变成左右箭头，拖动松手后确认两个 pane 的宽度变了。再从终端 `h pane layout --current` 确认 `ratio` 真的改了 —— UI 与 server 状态必须一致，这是单向数据流的验证。

- [ ] **Step 8: 提交**

```bash
git add Sources/HerdaKit/Layout/SplitHandles.swift Sources/HerdaKit/Runtime/TerminalSession.swift Sources/Herda/PaneGridView.swift Tests/HerdaKitTests/SplitHandlesTests.swift
git commit -m "feat: drag the gap between panes to change the split ratio

Handles are derived from pane geometry, not from split.ratio: reverse-computing
the divider position would mean reproducing herdr's layout arithmetic — integer
division, which side keeps the remainder, minimum sizes — and getting any of that
wrong yields a divider that does not track the cursor. Two panes one cell apart
on one axis and overlapping on the other is a geometric fact instead.

The drag sends nothing until release. The layout's truth is herdr's, so a request
per frame would turn the drag into a series of late jumps; one request on release
plus the layout_updated that follows keeps the single direction of data flow. The
ratio is clamped to 0.05…0.95 because a zero-column side is either rejected or
degenerate."
```

---

## Task 3: 原生滚动条

**Files:**
- Modify: `Sources/HerdaKit/Runtime/TerminalSession.swift`（缓存 `PaneScrollInfo`）
- Modify: `Sources/Herda/PaneGridView.swift`（叠加滚动条）

- [ ] **Step 1: 在状态轮询里捎带滚动信息**

`startStatusPolling`（`TerminalSession.swift:158-178`）已经每 1.5 秒拿一次 `api.snapshot().panes`。滚动信息就在同一份 `PaneInfo` 里（计划二 Task 5 已加 `scroll` 字段），所以只要多存一份：

在 `TerminalSession` 的属性区加：

```swift
    /// 每个 pane 的滚动位置,来自状态轮询捎带的 `PaneInfo.scroll`。
    ///
    /// 不用 `PaneScrollChanged` 事件:那是 per-pane 订阅,而一个连接的订阅集一旦
    /// 开始就不能扩展(同 `SidebarModel.mergeStatuses` 记的限制),跟随 pane 增删
    /// 要重建连接。1.5 秒对滚动条偏慢,滚动时由 view 本地乐观更新,轮询校正。
    @Published public private(set) var paneScroll: [String: PaneScrollInfo] = [:]
```

把轮询循环里的 `mergeStatuses` 调用改为同时更新它：

```swift
                do {
                    let panes = try api.snapshot().panes
                    reportedFailure = false
                    await MainActor.run {
                        self?.sidebar.mergeStatuses(from: panes)
                        self?.mergeScroll(from: panes)
                    }
                } catch {
```

并新增：

```swift
    private func mergeScroll(from panes: [PaneInfo]) {
        var next: [String: PaneScrollInfo] = [:]
        for pane in panes {
            if let scroll = pane.scroll { next[pane.paneId] = scroll }
        }
        paneScroll = next
    }
```

- [ ] **Step 2: 在卡片上叠加滚动条**

在 `PaneGridView.paneCard` 的 `.cardSurface(...)` **之前**插入 overlay：

```swift
        .overlay(alignment: .trailing) {
            scrollbar(for: pane.paneId)
        }
```

并新增：

```swift
    /// 原生滚动条。macOS 的 overlay scroller 惯例:内容不足一屏时不画。
    @ViewBuilder private func scrollbar(for paneId: String) -> some View {
        if let scroll = session.paneScroll[paneId],
           let thumb = ScrollbarGeometry.thumb(
               offsetFromBottom: scroll.offsetFromBottom,
               maxOffsetFromBottom: scroll.maxOffsetFromBottom,
               viewportRows: scroll.viewportRows
           ) {
            GeometryReader { geometry in
                Capsule()
                    .fill(theme.chrome.overlay1.color.opacity(0.55))
                    .frame(width: 3, height: max(24, geometry.size.height * thumb.length))
                    .offset(y: geometry.size.height * thumb.start)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.trailing, 2)
            .allowsHitTesting(false)
        }
    }
```

`allowsHitTesting(false)`：滚轮要落到下面的 `TerminalGridView`（它把滚动转成 mouse 事件发给 server，herdr 按坐标路由到这个 pane）。滚动条只是指示器，不接受拖动 —— 拖动它需要一个「滚到绝对位置」的通道，而 API 只有 `pane.scroll_changed` 事件、没有 scroll 请求方法（spec 数据流一节）。

- [ ] **Step 3: 编译并跑测试**

Run: `xcodegen generate && Scripts/test.sh 2>&1 | tail -5`

Expected: 全部通过。

- [ ] **Step 4: 手动验证**

```bash
Scripts/run.sh --reset
```

在一个 pane 里灌足够多的输出让 scrollback 超过一屏：

```bash
h pane send-text --current 'seq 1 500'
h pane send-keys --current Enter
```

确认：该 pane 右侧出现滚动条；在里面滚轮时 thumb 位置随之变化（最多 1.5 秒延迟）；另一个 pane 内容不足一屏时**没有**滚动条。

- [ ] **Step 5: 提交**

```bash
git add Sources/HerdaKit/Runtime/TerminalSession.swift Sources/Herda/PaneGridView.swift
git commit -m "feat: draw a native scrollbar per pane

The three numbers ride along on the 1.5s status poll, which already fetches
PaneInfo — PaneScrollChanged is a per-pane subscription and following pane
creation with it would mean reconnecting, the limitation
SidebarModel.mergeStatuses already records.

The bar does not accept hit testing: the wheel has to reach the TerminalGridView
underneath, which turns it into a mouse event that herdr routes by coordinate.
Dragging the thumb would need a scroll-to-absolute-position channel and the API
exposes no scroll request method, only the event."
```

---

## Task 4: 更新 design.md

阶段 1 完成，`docs/design.md` 的两条记录必须改（spec 最后一节列的）。

**Files:**
- Modify: `docs/design.md` §3 决策表、§10、§11

- [ ] **Step 1: 改 §10**

删掉「原生 split 布局」这一条，因为它已经实现。在 §3 的决策表里新增一行记录当前做法与被否决的两个方案（spec 的「被否决的方案一/二」两节是素材，但 design.md 只需要各一句 + 指向 spec）。

- [ ] **Step 2: 改 §3 关于 retheme 的记录**

现在写的是「herdr 暴露无 channel 来 retheme 运行中的 server」。改为记录 `server.reload_config` 存在（`src/app/api.rs:921` → `apply_config_from_disk(true)` → `apply_live_config` 里有 `theme_runtime` 赋值），并注明原判断是什么、为什么当时的结论「invisible in practice」仍然成立。同时更正 `TerminalSession.swift:256` 起的注释。

- [ ] **Step 3: 在 §5 补 `ClientMessage` 变体编号**

spec「被否决的方案一」里那份编号（`Hello=0` … `ControlTerminal=9`）来自 herdr `src/protocol/wire.rs:1060` 的 tag 测试。记进 §5,即使当前实现不用 —— 下次考虑 per-pane 连接时不必重查。

- [ ] **Step 4: 写 `docs/plan-m5.md`**

按 `docs/plan-m*.md` 的既有格式（per milestone，以验收结果结束，包含验收中发现的缺陷及其根因）记录这四个计划的执行结果。素材是各计划里的手动验证步骤与实测记录。

- [ ] **Step 5: 提交**

```bash
git add docs/design.md docs/plan-m5.md Sources/HerdaKit/Runtime/TerminalSession.swift
git commit -m "docs: record the native split layout as built

§10 loses 'native split layout' — it exists now. The decision table gains the
chosen approach plus one line each on the two designs that were discarded, with
the reasoning left in the spec.

Two stale claims fixed while here: server.reload_config does retheme a running
server (api.rs:921 reaches apply_live_config, which assigns theme_runtime), so
the old note and TerminalSession's comment were both wrong about the mechanism
even though their practical conclusion held; and §5 now carries the ClientMessage
variant numbers from wire.rs:1060's tag test, so a future look at per-pane
connections does not have to re-derive them."
```

---

## Self-Review 结果

spec 覆盖核查（四个计划合起来）：

| spec 内容 | 落点 |
|---|---|
| 硬约束一（rect == 渲染区域） | 计划一 Task 1 config + Task 6 实测 |
| 硬约束二（cell 8pt == cardGap） | 计划二 Task 2 断言；计划三 Task 4 依赖它 |
| 硬约束三（layout_updated 覆盖键盘） | 计划三 Task 2 订阅 + Task 5 手动双向验证 |
| 硬约束四（滚动走 snapshot） | 计划二 Task 5 + 计划四 Task 3 |
| 硬约束五（ProductAnnouncement） | 计划一 Task 3 |
| 硬约束六（zoomed） | 计划二 Task 2、计划三 Task 3、计划四 Task 2 各有断言 |
| 数据流：启动 | 计划三 Task 3 Step 5 |
| 数据流：布局变化 | 计划三 Task 3 |
| 数据流：输入 | 计划四 Task 1 |
| 数据流：滚动 | 计划四 Task 3 |
| 数据流：pane 生命周期 | 计划三 Task 3 的 `applyLayout` |
| 数据流：跨界 modal | 计划二 Task 4 + 计划三 Task 3 |
| 阶段划分 | 四个计划都属阶段 1；阶段 2 未排计划 |
| design.md 待更正 | 本计划 Task 4 |

类型一致性：`PaneLayoutRect` / `PaneLayoutPane` / `PaneLayoutSnapshot` / `PaneScrollInfo` / `SplitDirection` 在四个计划里的属性名与构造参数一致；`LayoutGeometry.frame(for:cellSize:origin:)` 的签名在计划二定义、计划三与四调用时一致；`session.cellSize` 在计划三 Task 4 Step 2 加入后被计划四三处使用。

一处已知的刻意缺陷交接：计划三结束时鼠标坐标是错的（每个 pane 的 view 发局部坐标），计划四 Task 1 修。这样切是因为计划三要先把画面立起来才能肉眼验证切片对不对，而坐标偏移需要先有多个 view 才有意义。
