# 原生 split 布局 — 计划二：解码与几何（纯函数）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `pane.layout` 的响应解码成 Swift 类型，并写出四个纯函数：cell rect → 像素 frame、`GridFrame` 按 rect 切片、间隙格内容探测、滚动条 thumb 几何。全部可在没有 PTY、窗口或 server 的情况下测试。

**Architecture:** 一律无状态、无副作用。这一层不碰 view 也不碰连接 —— 它把「herdr 说布局是什么样」翻译成「每块内容和每个矩形是什么」，计划三的 view 层只消费它的输出。按 design.md §9 的既有路子，高风险逻辑做成纯函数并在这里测掉。

**Tech Stack:** Swift 6 / XCTest / `JSONDecoder`（复用 `ApiTypes.decoder`）/ CoreGraphics

**前置：** 计划一必须完成，且 Task 6 的「`pane layout` 原始输出」已填入实测记录 —— 本计划的解码器要对着真实输出写，不是对着 JSON Schema 猜。

**完成后的可见变化：** 无。产出是一层带测试的纯函数。这是有意的：切片和几何一旦有 off-by-one，计划三的画面会整体错位而且极难定位，所以先在这里锁死。

---

## File Structure

| 文件 | 责任 |
|---|---|
| `Sources/HerdaKit/Layout/LayoutSnapshot.swift` | `pane.layout` / `layout_updated` 的解码结果。平坦快照，不是递归树 |
| `Sources/HerdaKit/Layout/LayoutGeometry.swift` | cell 坐标 ↔ 像素坐标的双向映射；`zoomed` 的退化规则 |
| `Sources/HerdaKit/Layout/FrameSlice.swift` | `GridFrame` + rect → 子 `GridFrame` |
| `Sources/HerdaKit/Layout/GapProbe.swift` | 间隙格是否有内容（跨界 modal 启发式） |
| `Sources/HerdaKit/Terminal/ScrollbarGeometry.swift` | `PaneScrollInfo` → thumb 归一化位置与长度 |
| `Sources/HerdaKit/Protocol/ApiTypes.swift` | 补 `PaneInfo.scroll` |
| `Tests/HerdaKitTests/Layout*Tests.swift` | 上述各自的测试 |

为什么分五个文件而不是一个 `Layout.swift`：它们的输入完全不同（JSON / rect / GridFrame / GridFrame+rects / 三个整数），互不依赖，各自的测试也互不相干。合成一个文件只会让每次改动都要在四百行里定位。

---

## Task 1: `PaneLayoutSnapshot` 解码

**Files:**
- Create: `Sources/HerdaKit/Layout/LayoutSnapshot.swift`
- Create: `Tests/HerdaKitTests/LayoutSnapshotTests.swift`
- Fixture: `Tests/HerdaKitTests/Fixtures/pane-layout-two-panes.json`（计划一 Task 6 Step 2 已抓取）

- [ ] **Step 1: 写失败的测试**

创建 `Tests/HerdaKitTests/LayoutSnapshotTests.swift`：

```swift
import XCTest
@testable import HerdaKit

final class LayoutSnapshotTests: XCTestCase {
    /// 手写的两 pane 左右分割,rect 已按 pane_gaps 收缩:总宽 80,左 pane 占
    /// 0..<39(40 减一格),右 pane 从 40 开始占 40 列。中间第 39 列是间隙。
    private let json = """
    {
      "workspace_id": "w1",
      "tab_id": "w1:t1",
      "zoomed": false,
      "area": { "x": 0, "y": 0, "width": 80, "height": 24 },
      "focused_pane_id": "w1:p1",
      "panes": [
        { "pane_id": "w1:p1", "focused": true,  "rect": { "x": 0,  "y": 0, "width": 39, "height": 24 } },
        { "pane_id": "w1:p2", "focused": false, "rect": { "x": 40, "y": 0, "width": 40, "height": 24 } }
      ],
      "splits": [
        { "id": "s0", "direction": "right", "ratio": 0.5,
          "rect": { "x": 0, "y": 0, "width": 80, "height": 24 } }
      ]
    }
    """

    func testDecodesPanesAndSplits() throws {
        let snapshot = try ApiTypes.decoder.decode(
            PaneLayoutSnapshot.self,
            from: XCTUnwrap(json.data(using: .utf8))
        )

        XCTAssertEqual(snapshot.workspaceId, "w1")
        XCTAssertEqual(snapshot.tabId, "w1:t1")
        XCTAssertFalse(snapshot.zoomed)
        XCTAssertEqual(snapshot.focusedPaneId, "w1:p1")
        XCTAssertEqual(snapshot.area, PaneLayoutRect(x: 0, y: 0, width: 80, height: 24))

        XCTAssertEqual(snapshot.panes.count, 2)
        XCTAssertEqual(snapshot.panes[0].paneId, "w1:p1")
        XCTAssertTrue(snapshot.panes[0].focused)
        XCTAssertEqual(snapshot.panes[0].rect, PaneLayoutRect(x: 0, y: 0, width: 39, height: 24))
        XCTAssertEqual(snapshot.panes[1].rect, PaneLayoutRect(x: 40, y: 0, width: 40, height: 24))

        XCTAssertEqual(snapshot.splits.count, 1)
        XCTAssertEqual(snapshot.splits[0].id, "s0")
        XCTAssertEqual(snapshot.splits[0].direction, .right)
        XCTAssertEqual(snapshot.splits[0].ratio, 0.5, accuracy: 0.0001)
    }

    func testGapBetweenPanesIsExactlyOneCell() throws {
        // pane_gaps 让相邻 pane 各收缩一格(herdr shrink_for_one_cell_gap)。
        // 这个断言守的是「rect 之间确实有一格」这个前提 —— 原生卡片间距就落在
        // 那一格上,没有它就没有地方画描边。
        let snapshot = try ApiTypes.decoder.decode(
            PaneLayoutSnapshot.self,
            from: XCTUnwrap(json.data(using: .utf8))
        )
        let left = snapshot.panes[0].rect
        let right = snapshot.panes[1].rect
        XCTAssertEqual(Int(right.x) - (Int(left.x) + Int(left.width)), 1)
    }

    func testDecodesRealServerOutput() throws {
        // 计划一 Task 6 从真实 server 抓的响应。按 CLAUDE.md 的规矩,fixture 来自
        // 线上字节而不是照 schema 推断的结构。
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "pane-layout-two-panes",
            withExtension: "json"
        ))
        let envelope = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        let result = try XCTUnwrap((envelope as? [String: Any])?["result"])
        let snapshot = try ApiTypes.decoder.decode(
            PaneLayoutSnapshot.self,
            from: try JSONSerialization.data(withJSONObject: result)
        )
        XCTAssertFalse(snapshot.panes.isEmpty)
        XCTAssertEqual(snapshot.panes.filter(\.focused).count, 1, "恰好一个焦点 pane")
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `Scripts/test.sh 2>&1 | grep -E "PaneLayoutSnapshot|error:" | head -5`

Expected: 编译失败 —— `cannot find 'PaneLayoutSnapshot' in scope`。

- [ ] **Step 3: 实现**

创建 `Sources/HerdaKit/Layout/LayoutSnapshot.swift`：

```swift
import Foundation

/// herdr 的 pane 布局快照(`pane.layout` 的结果与 `layout_updated` 的负载)。
///
/// **这是平坦结构,不是递归树。** `panes` 每项直接带 rect,够摆卡片;`splits`
/// 每项带 id / direction / ratio / rect,够定位可拖区域并作为
/// `layout.set_split_ratio` 的目标。真正的递归结构只在 `layout.export` 返回的
/// `LayoutDescription.root` 里,本项目用不到。
///
/// rect 的单位是 cell,与 `GridFrame` 同一个坐标系 —— 这是按 rect 切割整块 grid
/// 的前提。它已经是 herdr `apply_pane_chrome` 收缩之后的内容区,但这个等式只在
/// `pane_borders = false` 且 `pane_scrollbars = false` 时成立(见 spec 硬约束一)。
public struct PaneLayoutSnapshot: Decodable, Equatable, Sendable {
    public let workspaceId: String
    public let tabId: String
    /// 为 true 时 `panes` **不反映实际渲染** —— 见 `LayoutGeometry.visiblePanes`。
    public let zoomed: Bool
    public let area: PaneLayoutRect
    public let focusedPaneId: String
    public let panes: [PaneLayoutPane]
    public let splits: [PaneLayoutSplit]

    public init(
        workspaceId: String,
        tabId: String,
        zoomed: Bool,
        area: PaneLayoutRect,
        focusedPaneId: String,
        panes: [PaneLayoutPane],
        splits: [PaneLayoutSplit]
    ) {
        self.workspaceId = workspaceId
        self.tabId = tabId
        self.zoomed = zoomed
        self.area = area
        self.focusedPaneId = focusedPaneId
        self.panes = panes
        self.splits = splits
    }
}

/// cell 坐标系里的矩形。
public struct PaneLayoutRect: Decodable, Equatable, Sendable {
    public let x: UInt16
    public let y: UInt16
    public let width: UInt16
    public let height: UInt16

    public init(x: UInt16, y: UInt16, width: UInt16, height: UInt16) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct PaneLayoutPane: Decodable, Equatable, Sendable, Identifiable {
    public let paneId: String
    public let focused: Bool
    public let rect: PaneLayoutRect

    public var id: String { paneId }

    public init(paneId: String, focused: Bool, rect: PaneLayoutRect) {
        self.paneId = paneId
        self.focused = focused
        self.rect = rect
    }
}

public struct PaneLayoutSplit: Decodable, Equatable, Sendable, Identifiable {
    public let id: String
    public let direction: SplitDirection
    public let ratio: Double
    /// 这条 split 覆盖的整个区域(两个子节点加中间的间隙)。
    public let rect: PaneLayoutRect

    public init(id: String, direction: SplitDirection, ratio: Double, rect: PaneLayoutRect) {
        self.id = id
        self.direction = direction
        self.ratio = ratio
        self.rect = rect
    }
}

/// herdr 的 `SplitDirection`。`right` 是左右分割,`down` 是上下分割 —— 名字说的
/// 是「新 pane 放在哪一侧」,不是分隔线的方向。
public enum SplitDirection: String, Decodable, Sendable {
    case right
    case down
}
```

- [ ] **Step 4: 确认 fixture 能被测试 target 找到**

`Bundle.module` 要求 fixture 被声明为资源。检查 `project.yml` 里测试 target 是否已包含 `Tests/HerdaKitTests/Fixtures`：

Run: `grep -n -A 12 "HerdaKitTests" project.yml`

若没有资源声明，在测试 target 下加：

```yaml
    sources:
      - path: Tests/HerdaKitTests
      - path: Tests/HerdaKitTests/Fixtures
        buildPhase: resources
```

然后 `xcodegen generate`。

若项目已有其它 fixture（`WireDecoderTests` 的 golden fixture）采用了别的加载方式，**跟随那个方式**，不要引入第二种：

Run: `grep -rn "Bundle\|fixture\|Fixtures" Tests/HerdaKitTests/WireDecoderTests.swift | head -5`

- [ ] **Step 5: 运行测试确认通过**

Run: `Scripts/test.sh 2>&1 | tail -5`

Expected: 全部通过。

- [ ] **Step 6: 提交**

```bash
xcodegen generate
git add Sources/HerdaKit/Layout/LayoutSnapshot.swift Tests/HerdaKitTests/LayoutSnapshotTests.swift Tests/HerdaKitTests/Fixtures project.yml
git commit -m "feat: decode herdr's pane layout snapshot

The payload is flat, not a tree: panes[] carries a rect each and splits[] carries
id/direction/ratio, which is everything the card grid and the divider drag need.
The recursive form only exists in layout.export's LayoutDescription.root and is
unused here.

The fixture is a response captured from herda's own server, per CLAUDE.md's rule
that golden fixtures come from observed bytes rather than from reading a struct
definition. One assertion pins the one-cell gap between neighbouring rects — that
gap is where the native card border goes, so losing it would be silent."
```

---

## Task 2: `LayoutGeometry` — cell ↔ 像素，以及 zoomed 的退化

**Files:**
- Create: `Sources/HerdaKit/Layout/LayoutGeometry.swift`
- Create: `Tests/HerdaKitTests/LayoutGeometryTests.swift`

- [ ] **Step 1: 写失败的测试**

```swift
import CoreGraphics
import XCTest
@testable import HerdaKit

final class LayoutGeometryTests: XCTestCase {
    /// 实测值:MapleMono-NF-CN 13pt 的 cell 是 8×17(advance 7.8 取整为 8)。
    private let cell = CGSize(width: 8, height: 17)

    func testMapsCellRectToPixelFrame() {
        let rect = PaneLayoutRect(x: 40, y: 2, width: 40, height: 22)
        let frame = LayoutGeometry.frame(for: rect, cellSize: cell)
        XCTAssertEqual(frame, CGRect(x: 320, y: 34, width: 320, height: 374))
    }

    func testAppliesOrigin() {
        // 终端区不在窗口原点:卡片内缩由 ChromeMetrics 决定,几何函数只接受它。
        let rect = PaneLayoutRect(x: 0, y: 0, width: 10, height: 1)
        let frame = LayoutGeometry.frame(
            for: rect,
            cellSize: cell,
            origin: CGPoint(x: 8, y: 40)
        )
        XCTAssertEqual(frame, CGRect(x: 8, y: 40, width: 80, height: 17))
    }

    func testGapBetweenAdjacentFramesIsOneCellWide() {
        // 一格 = 8pt,正好是 ChromeMetrics.cardGap。卡片间距不需要任何换算。
        let left = LayoutGeometry.frame(
            for: PaneLayoutRect(x: 0, y: 0, width: 39, height: 24), cellSize: cell
        )
        let right = LayoutGeometry.frame(
            for: PaneLayoutRect(x: 40, y: 0, width: 40, height: 24), cellSize: cell
        )
        XCTAssertEqual(right.minX - left.maxX, cell.width)
        XCTAssertEqual(right.minX - left.maxX, ChromeMetrics.cardGap)
    }

    func testVisiblePanesPassesThroughWhenNotZoomed() {
        let snapshot = Self.twoPanes(zoomed: false)
        XCTAssertEqual(LayoutGeometry.visiblePanes(in: snapshot).map(\.paneId), ["w1:p1", "w1:p2"])
    }

    func testZoomedCollapsesToTheFocusedPaneFillingTheArea() {
        // spec 硬约束六:zoomed 时 snapshot.panes 仍是未 zoom 的布局,而 herdr 只
        // 渲染焦点 pane 并让它占满整个 area。照 panes 的 rect 切会整体错位。
        let snapshot = Self.twoPanes(zoomed: true)
        let visible = LayoutGeometry.visiblePanes(in: snapshot)
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible[0].paneId, "w1:p1")
        XCTAssertTrue(visible[0].focused)
        XCTAssertEqual(visible[0].rect, snapshot.area, "焦点 pane 必须铺满整个 area")
    }

    func testZoomedFallsBackWhenFocusedPaneIsMissing() {
        // 快照自相矛盾时(focusedPaneId 不在 panes 里)不要崩,也不要返回空 —— 返回
        // 原样比黑屏好定位。
        let snapshot = PaneLayoutSnapshot(
            workspaceId: "w1", tabId: "w1:t1", zoomed: true,
            area: PaneLayoutRect(x: 0, y: 0, width: 80, height: 24),
            focusedPaneId: "w1:pX",
            panes: [PaneLayoutPane(
                paneId: "w1:p1", focused: true,
                rect: PaneLayoutRect(x: 0, y: 0, width: 80, height: 24)
            )],
            splits: []
        )
        XCTAssertEqual(LayoutGeometry.visiblePanes(in: snapshot).map(\.paneId), ["w1:p1"])
    }

    func testConvertsPaneLocalPointBackToGridCoordinates() {
        // 与 frame(for:) 互逆。herdr 用 pane_at(col,row) 命中 pane,所以鼠标事件
        // 必须带全局 grid 坐标,不是 pane 局部坐标。
        let rect = PaneLayoutRect(x: 40, y: 2, width: 40, height: 22)
        let position = LayoutGeometry.gridPosition(
            forPointInPane: CGPoint(x: 12, y: 20),
            paneRect: rect,
            cellSize: cell
        )
        XCTAssertEqual(position.column, 41)   // 40 + floor(12/8)
        XCTAssertEqual(position.row, 3)       // 2 + floor(20/17)
    }

    func testGridPositionClampsNegativePoints() {
        // 拖动出界时 AppKit 会给负坐标,UInt16 转换必须先夹紧否则会陷阱。
        let position = LayoutGeometry.gridPosition(
            forPointInPane: CGPoint(x: -30, y: -5),
            paneRect: PaneLayoutRect(x: 0, y: 0, width: 10, height: 10),
            cellSize: cell
        )
        XCTAssertEqual(position.column, 0)
        XCTAssertEqual(position.row, 0)
    }

    private static func twoPanes(zoomed: Bool) -> PaneLayoutSnapshot {
        PaneLayoutSnapshot(
            workspaceId: "w1", tabId: "w1:t1", zoomed: zoomed,
            area: PaneLayoutRect(x: 0, y: 0, width: 80, height: 24),
            focusedPaneId: "w1:p1",
            panes: [
                PaneLayoutPane(
                    paneId: "w1:p1", focused: true,
                    rect: PaneLayoutRect(x: 0, y: 0, width: 39, height: 24)
                ),
                PaneLayoutPane(
                    paneId: "w1:p2", focused: false,
                    rect: PaneLayoutRect(x: 40, y: 0, width: 40, height: 24)
                ),
            ],
            splits: []
        )
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `Scripts/test.sh 2>&1 | grep -E "LayoutGeometry|error:" | head -5`

Expected: `cannot find 'LayoutGeometry' in scope`。

- [ ] **Step 3: 实现**

创建 `Sources/HerdaKit/Layout/LayoutGeometry.swift`：

```swift
import CoreGraphics

/// cell 坐标与像素坐标之间的映射,以及 `zoomed` 的退化规则。
///
/// 全部是纯函数:布局的真相在 herdr 那边,这里只做坐标换算。
public enum LayoutGeometry {
    /// cell 坐标的 rect → 像素 frame。
    ///
    /// `origin` 是终端区在容纳它的 view 坐标系里的原点(卡片内缩由
    /// `ChromeMetrics` 决定,这里只接受结果)。
    public static func frame(
        for rect: PaneLayoutRect,
        cellSize: CGSize,
        origin: CGPoint = .zero
    ) -> CGRect {
        CGRect(
            x: origin.x + CGFloat(rect.x) * cellSize.width,
            y: origin.y + CGFloat(rect.y) * cellSize.height,
            width: CGFloat(rect.width) * cellSize.width,
            height: CGFloat(rect.height) * cellSize.height
        )
    }

    /// 实际该渲染的 pane 列表。
    ///
    /// **`zoomed` 时不能直接用 `snapshot.panes`。** 那份数组来自
    /// `tab.layout.panes(area)`,不考虑 zoom(herdr `src/app/api/panes.rs:1684`),
    /// 给的仍是未 zoom 的多 pane 布局;而实际渲染是 `src/ui/panes.rs:179` 只取
    /// 焦点 pane 并让它占据整个 `area`。照 `panes` 的 rect 切割会拿多 pane 的
    /// 矩形去切一块只有单 pane 内容的 grid,画面整体错位。
    public static func visiblePanes(in snapshot: PaneLayoutSnapshot) -> [PaneLayoutPane] {
        guard snapshot.zoomed else { return snapshot.panes }
        guard let focused = snapshot.panes.first(where: { $0.paneId == snapshot.focusedPaneId })
        else {
            // 快照自相矛盾。返回原样比返回空好:错位可见,黑屏不可诊断。
            return snapshot.panes
        }
        return [PaneLayoutPane(paneId: focused.paneId, focused: true, rect: snapshot.area)]
    }

    /// pane 局部像素坐标 → 全局 grid cell 坐标。`frame(for:)` 的逆运算。
    ///
    /// 必须做这一步换算:herdr 按 `pane_at(col, row)`(`src/app/input/mouse.rs:1426`)
    /// 决定鼠标事件属于哪个 pane,所以事件里带的必须是整块 grid 的坐标。
    public static func gridPosition(
        forPointInPane point: CGPoint,
        paneRect: PaneLayoutRect,
        cellSize: CGSize
    ) -> (column: UInt16, row: UInt16) {
        guard cellSize.width > 0, cellSize.height > 0 else {
            return (paneRect.x, paneRect.y)
        }
        // 夹紧再转换:出界拖动会给负坐标,直接转 UInt16 会陷阱。
        let localColumn = max(0, Int((point.x / cellSize.width).rounded(.down)))
        let localRow = max(0, Int((point.y / cellSize.height).rounded(.down)))
        let column = min(Int(UInt16.max), Int(paneRect.x) + localColumn)
        let row = min(Int(UInt16.max), Int(paneRect.y) + localRow)
        return (UInt16(column), UInt16(row))
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `Scripts/test.sh 2>&1 | tail -5`

Expected: 全部通过。

- [ ] **Step 5: 提交**

```bash
git add Sources/HerdaKit/Layout/LayoutGeometry.swift Tests/HerdaKitTests/LayoutGeometryTests.swift
git commit -m "feat: map layout cell rects to pixel frames

One cell is 8pt wide at 13pt (advance 7.8 rounded), which is exactly
ChromeMetrics.cardGap — so the gap herdr leaves between panes needs no
conversion to become the native card gap, and a test pins that equality.

visiblePanes carries the zoom rule: snapshot.panes comes from
tab.layout.panes(area) and ignores zoom, while ui/panes.rs:179 renders only the
focused pane filling the whole area. Slicing by the reported rects under zoom
would misplace everything, so zoom collapses to one pane covering area.

gridPosition is the inverse, needed because herdr routes mouse events by
pane_at(col,row) on whole-grid coordinates. It clamps before converting to
UInt16 — out-of-bounds drags hand AppKit negative points."
```

---

## Task 3: `FrameSlice` — 按 rect 切出子帧

**Files:**
- Create: `Sources/HerdaKit/Layout/FrameSlice.swift`
- Create: `Tests/HerdaKitTests/FrameSliceTests.swift`

- [ ] **Step 1: 写失败的测试**

```swift
import XCTest
@testable import HerdaKit

final class FrameSliceTests: XCTestCase {
    /// 4×3 的 grid,每格填一个可辨认字符:
    ///   a b c d
    ///   e f g h
    ///   i j k l
    private func grid(cursor: GridCursor? = nil) -> GridFrame {
        let symbols = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"]
        return GridFrame(
            cells: symbols.map {
                GridCell(symbol: $0, foreground: 1, background: 2, modifier: 0, skip: false, hyperlink: nil)
            },
            width: 4,
            height: 3,
            cursor: cursor,
            hyperlinks: ["https://example.com"],
            graphics: [0x01, 0x02]
        )
    }

    func testSlicesTheRequestedRectangle() {
        let slice = FrameSlice.slice(
            grid(),
            to: PaneLayoutRect(x: 1, y: 1, width: 2, height: 2)
        )
        XCTAssertEqual(slice.width, 2)
        XCTAssertEqual(slice.height, 2)
        XCTAssertEqual(slice.cells.map(\.symbol), ["f", "g", "j", "k"])
    }

    func testPreservesCellAttributes() {
        let slice = FrameSlice.slice(grid(), to: PaneLayoutRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(slice.cells[0].foreground, 1)
        XCTAssertEqual(slice.cells[0].background, 2)
    }

    func testKeepsTheHyperlinkTableWhole() {
        // cell.hyperlink 是这张表的下标,重新编号会让链接指向错的 URL。整表原样
        // 带过去,浪费几个字节换取下标不必重映射。
        let slice = FrameSlice.slice(grid(), to: PaneLayoutRect(x: 0, y: 0, width: 2, height: 2))
        XCTAssertEqual(slice.hyperlinks, ["https://example.com"])
    }

    func testDropsGraphics() {
        // 没有渲染路径消费它,而按 rect 切 kitty 图像负载是没有意义的操作。
        let slice = FrameSlice.slice(grid(), to: PaneLayoutRect(x: 0, y: 0, width: 2, height: 2))
        XCTAssertTrue(slice.graphics.isEmpty)
    }

    func testCursorInsideTheRectIsTranslatedToLocalCoordinates() {
        let source = grid(cursor: GridCursor(column: 2, row: 1, isVisible: true, shape: 2))
        let slice = FrameSlice.slice(source, to: PaneLayoutRect(x: 1, y: 1, width: 3, height: 2))
        XCTAssertEqual(slice.cursor?.column, 1)
        XCTAssertEqual(slice.cursor?.row, 0)
        XCTAssertEqual(slice.cursor?.isVisible, true)
        XCTAssertEqual(slice.cursor?.shape, 2)
    }

    func testCursorOutsideTheRectIsDropped() {
        // 整块 grid 只有一个 cursor,它属于焦点 pane。非焦点 pane 的子帧不能带
        // cursor,否则每个 pane 都会画一个闪烁光标。
        let source = grid(cursor: GridCursor(column: 0, row: 0, isVisible: true, shape: 2))
        let slice = FrameSlice.slice(source, to: PaneLayoutRect(x: 2, y: 1, width: 2, height: 2))
        XCTAssertNil(slice.cursor)
    }

    func testClampsRectToTheFrameBounds() {
        // 窗口 resize 与 layout_updated 之间有一帧的窗口期,此时 rect 可能比
        // 当前 frame 大。裁剪而不是崩。
        let slice = FrameSlice.slice(grid(), to: PaneLayoutRect(x: 2, y: 2, width: 10, height: 10))
        XCTAssertEqual(slice.width, 2)
        XCTAssertEqual(slice.height, 1)
        XCTAssertEqual(slice.cells.map(\.symbol), ["k", "l"])
    }

    func testFullyOutOfBoundsRectYieldsAnEmptyFrame() {
        let slice = FrameSlice.slice(grid(), to: PaneLayoutRect(x: 9, y: 9, width: 2, height: 2))
        XCTAssertEqual(slice.width, 0)
        XCTAssertEqual(slice.height, 0)
        XCTAssertTrue(slice.cells.isEmpty)
        XCTAssertNil(slice.cursor)
    }

    func testToleratesATruncatedCellArray() {
        // 手写的防御:cells 比 width*height 短时不要越界。
        let truncated = GridFrame(
            cells: [GridCell(symbol: "a", foreground: 0, background: 0, modifier: 0, skip: false, hyperlink: nil)],
            width: 4, height: 3, cursor: nil, hyperlinks: [], graphics: []
        )
        let slice = FrameSlice.slice(truncated, to: PaneLayoutRect(x: 0, y: 0, width: 4, height: 3))
        XCTAssertEqual(slice.cells.count, Int(slice.width) * Int(slice.height))
    }

    func testWideCharacterFillerSurvivesSlicing() {
        // 宽字符后面跟一个无标记的空格占位(design.md §2)。切片必须原样保留它,
        // 否则后面每一列都会左移。
        let cells = ["更", " ", "x", "y"].map {
            GridCell(symbol: $0, foreground: 0, background: 0, modifier: 0, skip: false, hyperlink: nil)
        }
        let source = GridFrame(
            cells: cells, width: 4, height: 1, cursor: nil, hyperlinks: [], graphics: []
        )
        let slice = FrameSlice.slice(source, to: PaneLayoutRect(x: 0, y: 0, width: 3, height: 1))
        XCTAssertEqual(slice.cells.map(\.symbol), ["更", " ", "x"])
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `Scripts/test.sh 2>&1 | grep -E "FrameSlice|error:" | head -5`

Expected: `cannot find 'FrameSlice' in scope`。

- [ ] **Step 3: 实现**

创建 `Sources/HerdaKit/Layout/FrameSlice.swift`：

```swift
import Foundation

/// 从整块 grid 里切出一个 pane 的子帧。
///
/// 只有一条 render 连接,server 送来的是整个终端区的一块 `GridFrame`;每个 pane
/// 的 view 拿到的是这里切出来的那一份。纯函数 —— 切片的正确性是整个原生布局的
/// 地基,off-by-one 会让画面整体平移且极难定位,所以它在没有窗口的情况下被测。
public enum FrameSlice {
    /// 切出 `rect` 覆盖的区域。`rect` 超出 `frame` 时按边界裁剪。
    public static func slice(_ frame: GridFrame, to rect: PaneLayoutRect) -> GridFrame {
        let frameWidth = Int(frame.width)
        let frameHeight = Int(frame.height)
        let originX = Int(rect.x)
        let originY = Int(rect.y)

        // 裁剪到 frame 边界:窗口 resize 与 layout_updated 之间有一帧窗口期,
        // 此时 rect 可能描述的是上一个尺寸。
        let width = max(0, min(Int(rect.width), frameWidth - originX))
        let height = max(0, min(Int(rect.height), frameHeight - originY))

        guard originX >= 0, originY >= 0, width > 0, height > 0 else {
            return GridFrame(
                cells: [], width: 0, height: 0, cursor: nil,
                hyperlinks: frame.hyperlinks, graphics: []
            )
        }

        let blank = GridCell(
            symbol: " ", foreground: 0, background: 0,
            modifier: 0, skip: false, hyperlink: nil
        )

        var cells: [GridCell] = []
        cells.reserveCapacity(width * height)
        for row in originY..<(originY + height) {
            let rowStart = row * frameWidth
            for column in originX..<(originX + width) {
                let index = rowStart + column
                // 手写解码器的下游,cells 短于 width*height 时不要越界。
                cells.append(index < frame.cells.count ? frame.cells[index] : blank)
            }
        }

        // 整块 grid 只有一个 cursor,它属于焦点 pane。只有包含它的那个 rect 才
        // 带上它,否则每个 pane 都会画一个闪烁光标。
        var cursor: GridCursor?
        if let source = frame.cursor {
            let column = Int(source.column)
            let row = Int(source.row)
            if column >= originX, column < originX + width,
               row >= originY, row < originY + height {
                cursor = GridCursor(
                    column: UInt16(column - originX),
                    row: UInt16(row - originY),
                    isVisible: source.isVisible,
                    shape: source.shape
                )
            }
        }

        return GridFrame(
            cells: cells,
            width: UInt16(width),
            height: UInt16(height),
            cursor: cursor,
            // 整表原样带过去:`cell.hyperlink` 是它的下标,重新编号就要重映射每个
            // cell,而这张表只有几个字符串。
            hyperlinks: frame.hyperlinks,
            // 没有渲染路径消费它,按 rect 切 kitty 负载也没有意义。
            graphics: []
        )
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `Scripts/test.sh 2>&1 | tail -5`

Expected: 全部通过。

- [ ] **Step 5: 提交**

```bash
git add Sources/HerdaKit/Layout/FrameSlice.swift Tests/HerdaKitTests/FrameSliceTests.swift
git commit -m "feat: slice a pane's subframe out of the whole grid

There is still one render connection, so each pane view renders a slice of the
single GridFrame. Two details are not obvious and both have tests: the whole grid
carries exactly one cursor and it belongs to the focused pane, so only the rect
containing it keeps it — otherwise every pane blinks a caret; and the hyperlink
table travels whole because cell.hyperlink indexes into it, so renumbering would
mean remapping every cell to save a few strings.

Rects are clamped rather than trusted: between a window resize and the following
layout_updated there is a frame where the rect describes the previous size."
```

---

## Task 4: `GapProbe` — 跨界 modal 的启发式

**Files:**
- Create: `Sources/HerdaKit/Layout/GapProbe.swift`
- Create: `Tests/HerdaKitTests/GapProbeTests.swift`

计划一已经用 config 关掉了 herdr 主动弹出的 modal，但 prefix key 主动按出来的（Navigator / GlobalMenu / KeybindHelp）仍会画在整块 grid 上并跨越 pane 边界。切割后它会被卡片间距切开，落在间隙格上的内容会丢失。这个函数给 view 层一个信号：此时退回整块渲染。

- [ ] **Step 1: 写失败的测试**

```swift
import XCTest
@testable import HerdaKit

final class GapProbeTests: XCTestCase {
    private func frame(_ rows: [String]) -> GridFrame {
        let width = rows.map(\.count).max() ?? 0
        var cells: [GridCell] = []
        for row in rows {
            let padded = row.padding(toLength: width, withPad: " ", startingAt: 0)
            for character in padded {
                cells.append(GridCell(
                    symbol: String(character), foreground: 0, background: 0,
                    modifier: 0, skip: false, hyperlink: nil
                ))
            }
        }
        return GridFrame(
            cells: cells, width: UInt16(width), height: UInt16(rows.count),
            cursor: nil, hyperlinks: [], graphics: []
        )
    }

    /// 左 pane 占 0..<2,间隙是第 2 列,右 pane 占 3..<5。
    private let panes = [
        PaneLayoutRect(x: 0, y: 0, width: 2, height: 2),
        PaneLayoutRect(x: 3, y: 0, width: 2, height: 2),
    ]

    func testEmptyGapReportsNoOverflow() {
        // pane_borders=false 时那一列本该是空白。
        let grid = frame(["ab cd",
                          "ef gh"])
        XCTAssertFalse(GapProbe.hasContentOutsidePanes(grid, panes: panes))
    }

    func testContentInTheGapReportsOverflow() {
        // modal 横跨两个 pane 时会占住间隙列。
        let grid = frame(["ab─cd",
                          "ef│gh"])
        XCTAssertTrue(GapProbe.hasContentOutsidePanes(grid, panes: panes))
    }

    func testTreatsNonBreakingWhitespaceAsEmpty() {
        // ratatui 用普通空格填充,但换行/制表若出现也不该算内容。
        let grid = frame(["ab\tcd",
                          "ef gh"])
        XCTAssertFalse(GapProbe.hasContentOutsidePanes(grid, panes: panes))
    }

    func testRowsBelowEveryPaneCountAsOutside() {
        // 底部多出来的行不属于任何 pane。herdr 的 tab row 回来时会占住它们,
        // 那同样是「有东西不在 pane 里」,应当退回整块渲染。
        let grid = frame(["ab cd",
                          "ef gh",
                          "tab1 "])
        XCTAssertTrue(GapProbe.hasContentOutsidePanes(grid, panes: panes))
    }

    func testSinglePaneCoveringEverythingReportsNoOverflow() {
        let grid = frame(["abcde",
                          "fghij"])
        XCTAssertFalse(GapProbe.hasContentOutsidePanes(
            grid,
            panes: [PaneLayoutRect(x: 0, y: 0, width: 5, height: 2)]
        ))
    }

    func testToleratesRectsLargerThanTheFrame() {
        let grid = frame(["ab"])
        XCTAssertFalse(GapProbe.hasContentOutsidePanes(
            grid,
            panes: [PaneLayoutRect(x: 0, y: 0, width: 99, height: 99)]
        ))
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `Scripts/test.sh 2>&1 | grep -E "GapProbe|error:" | head -5`

Expected: `cannot find 'GapProbe' in scope`。

- [ ] **Step 3: 实现**

创建 `Sources/HerdaKit/Layout/GapProbe.swift`：

```swift
import Foundation

/// 检测有没有内容落在所有 pane rect 之外。
///
/// 计划一用 config 关掉了 herdr 主动弹出的 modal,但 prefix key 按出来的
/// (Navigator / GlobalMenu / KeybindHelp)仍然画在整块 grid 上,并且会跨越 pane
/// 边界。按 rect 切割会让它被卡片间距切开一条缝,落在间隙格上的部分直接丢失。
///
/// `pane_borders = false` 时 pane 之间那一格本该是空白,所以「间隙里有内容」是
/// 一个可靠且不需要额外 API 的信号:出现时退回整块 grid 渲染。
public enum GapProbe {
    public static func hasContentOutsidePanes(
        _ frame: GridFrame,
        panes: [PaneLayoutRect]
    ) -> Bool {
        let width = Int(frame.width)
        let height = Int(frame.height)
        guard width > 0, height > 0 else { return false }

        var covered = [Bool](repeating: false, count: width * height)
        for rect in panes {
            let rowRange = Int(rect.y)..<min(Int(rect.y) + Int(rect.height), height)
            let columnRange = Int(rect.x)..<min(Int(rect.x) + Int(rect.width), width)
            guard rowRange.lowerBound < rowRange.upperBound,
                  columnRange.lowerBound < columnRange.upperBound
            else { continue }
            for row in rowRange {
                let rowStart = row * width
                for column in columnRange {
                    covered[rowStart + column] = true
                }
            }
        }

        for index in 0..<min(covered.count, frame.cells.count) where !covered[index] {
            if !isBlank(frame.cells[index].symbol) { return true }
        }
        return false
    }

    /// ratatui 用普通空格填充空白区域。制表与换行不该被当成内容。
    private static func isBlank(_ symbol: String) -> Bool {
        symbol.isEmpty || symbol.allSatisfy(\.isWhitespace)
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `Scripts/test.sh 2>&1 | tail -5`

Expected: 全部通过。

- [ ] **Step 5: 提交**

```bash
git add Sources/HerdaKit/Layout/GapProbe.swift Tests/HerdaKitTests/GapProbeTests.swift
git commit -m "feat: detect content that crosses pane boundaries

Config silences herdr's self-initiated modals, but the ones a prefix key opens
still draw on the whole grid and cross pane rects, so slicing would cut them at
the card gap and drop whatever sits in the gap column. With pane_borders=false
that column is blank by construction, which makes 'something is in the gap' a
reliable signal to fall back to whole-grid rendering — no extra API needed.

Rows below every pane count as outside too: that is where the tab row reappears
when a workspace gets a second tab, and it deserves the same fallback."
```

---

## Task 5: `ScrollbarGeometry` 与 `PaneInfo.scroll`

**Files:**
- Create: `Sources/HerdaKit/Terminal/ScrollbarGeometry.swift`
- Modify: `Sources/HerdaKit/Protocol/ApiTypes.swift:49-64`
- Create: `Tests/HerdaKitTests/ScrollbarGeometryTests.swift`
- Modify: `Tests/HerdaKitTests/ApiTypesTests.swift`

- [ ] **Step 1: 写失败的测试**

创建 `Tests/HerdaKitTests/ScrollbarGeometryTests.swift`：

```swift
import XCTest
@testable import HerdaKit

final class ScrollbarGeometryTests: XCTestCase {
    func testNoThumbWhenNothingToScroll() {
        // maxOffsetFromBottom 为 0 表示 scrollback 还没超过一屏。
        XCTAssertNil(ScrollbarGeometry.thumb(
            offsetFromBottom: 0, maxOffsetFromBottom: 0, viewportRows: 24
        ))
    }

    func testThumbAtBottomWhenNotScrolledBack() {
        // offsetFromBottom 是「距底部多少行」,0 就是贴底。
        let thumb = ScrollbarGeometry.thumb(
            offsetFromBottom: 0, maxOffsetFromBottom: 76, viewportRows: 24
        )
        let unwrapped = try! XCTUnwrap(thumb)
        XCTAssertEqual(unwrapped.length, 24.0 / 100.0, accuracy: 0.0001)
        XCTAssertEqual(unwrapped.start, 76.0 / 100.0, accuracy: 0.0001)
        XCTAssertEqual(unwrapped.start + unwrapped.length, 1.0, accuracy: 0.0001)
    }

    func testThumbAtTopWhenScrolledAllTheWayBack() {
        let thumb = try! XCTUnwrap(ScrollbarGeometry.thumb(
            offsetFromBottom: 76, maxOffsetFromBottom: 76, viewportRows: 24
        ))
        XCTAssertEqual(thumb.start, 0, accuracy: 0.0001)
    }

    func testThumbLengthIsViewportShareOfTotalContent() {
        // 总内容高度是 max + viewport,不是 max。
        let thumb = try! XCTUnwrap(ScrollbarGeometry.thumb(
            offsetFromBottom: 0, maxOffsetFromBottom: 30, viewportRows: 10
        ))
        XCTAssertEqual(thumb.length, 0.25, accuracy: 0.0001)
    }

    func testGuardsAgainstAZeroViewport() {
        // resize 的中间态可能给出 0 行。
        XCTAssertNil(ScrollbarGeometry.thumb(
            offsetFromBottom: 0, maxOffsetFromBottom: 10, viewportRows: 0
        ))
    }

    func testClampsAnOffsetBeyondTheMaximum() {
        // 本地乐观更新会短暂越过 max,轮询回来才校正 —— 不能算出负的 start。
        let thumb = try! XCTUnwrap(ScrollbarGeometry.thumb(
            offsetFromBottom: 999, maxOffsetFromBottom: 76, viewportRows: 24
        ))
        XCTAssertEqual(thumb.start, 0, accuracy: 0.0001)
    }
}
```

追加到 `Tests/HerdaKitTests/ApiTypesTests.swift`：

```swift
    func testPaneInfoDecodesScrollWhenPresent() throws {
        // 滚动位置走 snapshot 而不是 per-pane 订阅:PaneScrollChanged 是按 pane
        // 订阅的,而订阅集一旦开始就不能扩展(见 SidebarModel.mergeStatuses)。
        let json = """
        {
          "pane_id": "w1:p1", "terminal_id": "t1", "workspace_id": "w1", "tab_id": "w1:t1",
          "focused": true, "cwd": "/tmp", "agent_status": "idle",
          "agent": null, "terminal_title_stripped": null,
          "scroll": { "offset_from_bottom": 12, "max_offset_from_bottom": 76, "viewport_rows": 24 }
        }
        """
        let pane = try ApiTypes.decoder.decode(
            PaneInfo.self,
            from: XCTUnwrap(json.data(using: .utf8))
        )
        XCTAssertEqual(pane.scroll?.offsetFromBottom, 12)
        XCTAssertEqual(pane.scroll?.maxOffsetFromBottom, 76)
        XCTAssertEqual(pane.scroll?.viewportRows, 24)
    }

    func testPaneInfoDecodesWithoutScroll() throws {
        // 字段是 Option<PaneScrollInfo>,缺失必须容忍。
        let json = """
        {
          "pane_id": "w1:p1", "terminal_id": "t1", "workspace_id": "w1", "tab_id": "w1:t1",
          "focused": true, "cwd": "/tmp", "agent_status": "idle",
          "agent": null, "terminal_title_stripped": null
        }
        """
        let pane = try ApiTypes.decoder.decode(
            PaneInfo.self,
            from: XCTUnwrap(json.data(using: .utf8))
        )
        XCTAssertNil(pane.scroll)
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `Scripts/test.sh 2>&1 | grep -E "ScrollbarGeometry|scroll|error:" | head -5`

Expected: `cannot find 'ScrollbarGeometry' in scope` 以及 `PaneInfo has no member 'scroll'`。

- [ ] **Step 3: 实现**

创建 `Sources/HerdaKit/Terminal/ScrollbarGeometry.swift`：

```swift
import Foundation

/// 原生滚动条 thumb 的归一化几何。
///
/// 数据来自 `PaneInfo.scroll`(在 `session.snapshot` 的响应里),而不是
/// `PaneScrollChanged` 事件 —— 后者是按 pane 订阅的,而一个连接的订阅集一旦开始
/// 就不能扩展,pane 增删时要重建连接(同 `SidebarModel.mergeStatuses` 记录的
/// 限制)。快照本来就在被轮询,滚动信息搭同一趟车。
public enum ScrollbarGeometry {
    /// 返回 thumb 的起点与长度,都是 0…1 的比例(0 是顶部)。
    /// 内容不足一屏时返回 nil —— 此时不该画滚动条。
    public static func thumb(
        offsetFromBottom: Int,
        maxOffsetFromBottom: Int,
        viewportRows: Int
    ) -> (start: Double, length: Double)? {
        guard viewportRows > 0, maxOffsetFromBottom > 0 else { return nil }

        // 总内容高度是 max + viewport:max 只是「还能往上滚多少行」。
        let total = Double(maxOffsetFromBottom + viewportRows)
        let length = Double(viewportRows) / total

        // 夹紧:滚动时本地乐观更新会短暂越过 max,轮询回来才校正。
        let offset = min(max(0, offsetFromBottom), maxOffsetFromBottom)
        // offsetFromBottom 是距底部的行数,thumb 的 start 是距顶部的比例。
        let start = Double(maxOffsetFromBottom - offset) / total

        return (start: start, length: length)
    }
}
```

在 `ApiTypes.swift` 的 `PaneInfo` 里（`:61` 的 `terminalTitleStripped` 之后）追加：

```swift
    /// 滚动位置。`nil` 表示 server 没有报告(字段是 `Option<PaneScrollInfo>`)。
    /// 原生滚动条从这里取值 —— 见 `ScrollbarGeometry` 头部关于为什么不用
    /// per-pane 订阅的说明。
    public let scroll: PaneScrollInfo?
```

并在 `PaneInfo` 之后新增：

```swift
public struct PaneScrollInfo: Decodable, Equatable, Sendable {
    /// 距底部的行数。0 表示贴底。
    public let offsetFromBottom: Int
    /// 还能往上滚多少行。0 表示内容不足一屏。
    public let maxOffsetFromBottom: Int
    public let viewportRows: Int

    public init(offsetFromBottom: Int, maxOffsetFromBottom: Int, viewportRows: Int) {
        self.offsetFromBottom = offsetFromBottom
        self.maxOffsetFromBottom = maxOffsetFromBottom
        self.viewportRows = viewportRows
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `Scripts/test.sh 2>&1 | tail -5`

Expected: 全部通过。若 `PaneInfo` 的其它构造点报错（`SidebarModel` 里可能有测试用的构造），补上 `scroll: nil`。

Run: `Scripts/test.sh 2>&1 | grep -E "missing argument|error:" | head -5`

- [ ] **Step 5: 提交**

```bash
git add Sources/HerdaKit/Terminal/ScrollbarGeometry.swift Sources/HerdaKit/Protocol/ApiTypes.swift Tests/HerdaKitTests/ScrollbarGeometryTests.swift Tests/HerdaKitTests/ApiTypesTests.swift
git commit -m "feat: derive native scrollbar geometry from snapshot scroll info

The three numbers come from PaneInfo.scroll in session.snapshot, not from the
PaneScrollChanged event: that event is a per-pane subscription and a connection's
subscription set cannot be extended once started, so following pane creation
would mean reconnecting — the same limitation SidebarModel.mergeStatuses records.
The snapshot is already polled, so this rides along.

Total content height is max + viewport, not max, and the offset is clamped
because optimistic local updates during a scroll briefly exceed the reported
maximum before the next poll corrects them."
```

---

## Self-Review 结果

对照 spec 逐项核过：

- 硬约束一（rect == 内容区）→ 计划一 Task 1 的 config + Task 6 的实测；本计划 `LayoutSnapshot` 的类型注释记录了这个前提
- 硬约束二（cell 8pt == cardGap）→ Task 2 的 `testGapBetweenAdjacentFramesIsOneCellWide` 直接断言这个等式
- 硬约束三（layout_updated 覆盖键盘操作）→ 计划三接入事件时验证
- 硬约束四（滚动走 snapshot）→ Task 5
- 硬约束五（ProductAnnouncement）→ 计划一 Task 3
- 硬约束六（zoomed）→ Task 2 的 `visiblePanes` 与两个测试
- 跨界 modal 启发式 → Task 4
- 坐标换算 → Task 2 的 `gridPosition`，与 `frame(for:)` 互逆，同一个文件同一批测试

类型一致性：`PaneLayoutRect` 在 `FrameSlice.slice`、`LayoutGeometry.frame`、`GapProbe.hasContentOutsidePanes` 三处的参数名与类型一致；`PaneScrollInfo` 的三个属性名与 `ScrollbarGeometry.thumb` 的三个参数名一一对应。

未覆盖（有意留给后续计划）：`ApiClient` 的新方法与 `layout_updated` 订阅在计划三，因为它们要和 `TerminalSession` 的接线一起测；拖分隔线与滚动条 view 在计划四。
