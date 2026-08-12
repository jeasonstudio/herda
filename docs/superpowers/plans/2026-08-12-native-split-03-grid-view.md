# 原生 split 布局 — 计划三：原生卡片网格

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 终端区显示为每个 pane 一张独立原生卡片，内容由计划二的切片函数从单块 grid 切出，焦点由卡片描边表达，布局跟随 `layout_updated` 事件。

**Architecture:** `TerminalSession` 从「持有一个 `TerminalGridView`」变成协调者：持有一份 `PaneLayoutSnapshot` 和一个 `paneId → TerminalGridView` 字典，每收到一帧就按 `LayoutGeometry.visiblePanes` 给每个 view 切片喂帧。仍然只有一条 render 连接和一条 API 连接。单向数据流：布局改动都发给 herdr，UI 等 `layout_updated` 回来才变。

**Tech Stack:** Swift 6 严格并发 / SwiftUI + AppKit（`NSViewRepresentable`）/ XCTest

**前置：** 计划一、计划二完成，且计划一的实测记录确认了 rect 与内容逐格对齐。

**完成后的可见变化：** Split Right / Split Down 之后是并排的原生圆角卡片，8pt 间距，焦点卡片描边更亮。这是用户最初要的东西。拖分隔线与原生滚动条在计划四。

---

## File Structure

| 文件 | 责任 | 改动 |
|---|---|---|
| `Sources/HerdaKit/Terminal/TerminalFont.swift` | 字体度量 | `gridSize(for:)` 提上来（`TerminalGridView` 委托给它） |
| `Sources/HerdaKit/Protocol/ApiClient.swift` | JSON API | 新增 `paneLayout()`、`splitPane`、`zoomPane`、`closePane`；事件类型加 `layout.updated` |
| `Sources/HerdaKit/Runtime/TerminalSession.swift` | 启动序列与通道 | 从单 view 变协调者：layout 快照 + per-pane view 字典 |
| `Sources/Herda/PaneGridView.swift` | **新增** — 按 rect 摆 pane 卡片 | |
| `Sources/Herda/ContentView.swift` | 窗口结构 | `terminalArea` 换成 `PaneGridView` |
| `Tests/HerdaKitTests/TerminalSessionLayoutTests.swift` | **新增** — 协调逻辑 | |

`TerminalGridView` 不改（计划四才加 `cellOrigin`）。

---

## Task 1: `TerminalFont.gridSize(for:)`

`TerminalSession` 之后不再拥有单个 view，但仍要为 app 连接上报整个终端区的 cols/rows。把这段度量放到已经拥有 `cellSize` 的类型上，而不是在 session 里复制一份。

**Files:**
- Modify: `Sources/HerdaKit/Terminal/TerminalFont.swift`
- Modify: `Sources/HerdaKit/Terminal/TerminalGridView.swift:77-81`
- Test: `Tests/HerdaKitTests/TerminalFontTests.swift`

- [ ] **Step 1: 写失败的测试**

追加到 `TerminalFontTests.swift`：

```swift
func testGridSizeDividesBySizeOfACell() {
    let font = TerminalFont(size: 13)
    let cell = font.cellSize
    let grid = font.gridSize(for: CGSize(width: cell.width * 80, height: cell.height * 24))
    XCTAssertEqual(grid.columns, 80)
    XCTAssertEqual(grid.rows, 24)
}

func testGridSizeNeverReportsZero() {
    // 启动或 resize 的中间态会给出 .zero,而 0 列的 handshake 会被 server 拒绝。
    let grid = TerminalFont(size: 13).gridSize(for: .zero)
    XCTAssertEqual(grid.columns, 1)
    XCTAssertEqual(grid.rows, 1)
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `Scripts/test.sh 2>&1 | grep -E "gridSize|error:" | head -5`

Expected: `value of type 'TerminalFont' has no member 'gridSize'`。

- [ ] **Step 3: 实现**

在 `TerminalFont` 里新增（放在 `cellSize` 的定义之后）：

```swift
    /// 一块给定像素尺寸能放下多少 cell。
    ///
    /// 放在这里而不是 view 上:`TerminalSession` 要为 app 连接上报整个终端区的
    /// cols/rows,而它不再拥有单个 view(每个 pane 一个)。度量属于字体。
    public func gridSize(for size: CGSize) -> (columns: UInt16, rows: UInt16) {
        let columns = max(1, Int(size.width / cellSize.width))
        let rows = max(1, Int(size.height / cellSize.height))
        return (UInt16(min(columns, Int(UInt16.max))), UInt16(min(rows, Int(UInt16.max))))
    }
```

把 `TerminalGridView.gridSize(for:)`（`:77-81`）改为委托：

```swift
    public func gridSize(for size: CGSize) -> (columns: UInt16, rows: UInt16) {
        terminalFont.gridSize(for: size)
    }
```

- [ ] **Step 4: 运行测试确认通过**

Run: `Scripts/test.sh 2>&1 | tail -5`

Expected: 全部通过（`TerminalGridViewTests` 里已有的 gridSize 测试也应继续通过）。

- [ ] **Step 5: 提交**

```bash
git add Sources/HerdaKit/Terminal/TerminalFont.swift Sources/HerdaKit/Terminal/TerminalGridView.swift Tests/HerdaKitTests/TerminalFontTests.swift
git commit -m "refactor: move grid sizing onto TerminalFont

TerminalSession still reports the whole terminal area's cols/rows for the app
connection, but it no longer owns a single view — there is one per pane now. The
measurement belongs to the type that already owns cellSize, and the view
delegates to it rather than keeping a second copy."
```

---

## Task 2: `ApiClient` 的 layout 方法与事件

**Files:**
- Modify: `Sources/HerdaKit/Protocol/ApiClient.swift:100-151`
- Test: `Tests/HerdaKitTests/ApiClientTests.swift`

- [ ] **Step 1: 写失败的测试**

`ApiClient` 的请求要走 socket，所以只测请求行的构造（既有测试已经是这个路子 —— 见 `ApiClientTests` 里对 `requestLine` / `subscribeLine` 的用法）。追加：

```swift
func testPaneLayoutRequestLine() throws {
    let line = try ApiClient.requestLine(id: "layout", method: "pane.layout", params: [:])
    XCTAssertTrue(line.contains("\"method\":\"pane.layout\""))
    XCTAssertTrue(line.hasSuffix("\n"))
}

func testSplitPaneRequestCarriesDirectionAndTargetPane() throws {
    let line = try ApiClient.requestLine(
        id: "split",
        method: "pane.split",
        params: ["target_pane_id": "w1:p1", "direction": "right", "focus": true]
    )
    XCTAssertTrue(line.contains("\"method\":\"pane.split\""))
    XCTAssertTrue(line.contains("\"direction\":\"right\""))
    XCTAssertTrue(line.contains("\"target_pane_id\":\"w1:p1\""))
}

func testSetSplitRatioRequestLine() throws {
    let line = try ApiClient.requestLine(
        id: "ratio",
        method: "layout.set_split_ratio",
        params: ["split_id": "s0", "ratio": 0.42]
    )
    XCTAssertTrue(line.contains("\"method\":\"layout.set_split_ratio\""))
    XCTAssertTrue(line.contains("\"split_id\":\"s0\""))
}

func testLayoutEventTypesAreSubscribed() throws {
    // 布局的真相在 herdr,UI 只跟事件走。少订阅这一项会让 UI 在键盘 split 之后
    // 停在旧布局上 —— 而键盘 split 走的是同一个 API 派发器,所以事件一定会来
    // (spec 硬约束三)。
    XCTAssertTrue(ApiClient.sidebarEventTypes.contains("layout.updated"))
    let line = try ApiClient.subscribeLine(to: ApiClient.sidebarEventTypes)
    XCTAssertTrue(line.contains("layout.updated"))
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `Scripts/test.sh 2>&1 | grep -E "layout.updated|failed" | head -5`

Expected: `testLayoutEventTypesAreSubscribed` FAIL（其余三个只用现成的 `requestLine`，会直接通过 —— 它们是回归保护）。

- [ ] **Step 3: 实现**

在 `sidebarEventTypes`（`:131-143`）的数组末尾加一项：

```swift
        "pane.agent_detected",
        // 布局的真相在 herdr:键盘 split 与 JSON API split 走同一个派发器
        // (herdr runtime_mutations.rs 的 dispatch_runtime_mutation),两者都会
        // 发这个事件。不订阅它,键盘 split 之后 UI 会停在旧布局。
        "layout.updated",
    ]
```

在 `focusPane`（`:113-119`）之后追加：

```swift
    /// 实测:`result` 的键是 `["layout", "type"]`,snapshot 在 `layout` 下面,所以
    /// 走 envelope 而不是直接解 `result`。
    public func paneLayout() throws -> PaneLayoutSnapshot {
        try request(PaneLayoutEnvelope.self, method: "pane.layout", id: "pane-layout").layout
    }

    public func splitPane(_ paneId: String, direction: SplitDirection) throws {
        _ = try request(
            method: "pane.split",
            params: ["target_pane_id": paneId, "direction": direction.rawValue, "focus": true],
            id: "split-pane"
        )
    }

    public func zoomPane(_ paneId: String) throws {
        _ = try request(method: "pane.zoom", params: ["pane_id": paneId], id: "zoom-pane")
    }

    public func closePane(_ paneId: String) throws {
        _ = try request(method: "pane.close", params: ["pane_id": paneId], id: "close-pane")
    }

    public func setSplitRatio(_ splitId: String, ratio: Double) throws {
        _ = try request(
            method: "layout.set_split_ratio",
            params: ["split_id": splitId, "ratio": ratio],
            id: "set-split-ratio"
        )
    }
```

- [ ] **Step 4: 运行测试确认通过**

Run: `Scripts/test.sh 2>&1 | tail -5`

Expected: 全部通过。

- [ ] **Step 5: 用真实 server 核对参数名**

请求参数名不能靠猜。起 app 后（公共前置见计划一）逐个打一遍：

```bash
printf '{"id":"1","method":"pane.layout","params":{}}\n' | nc -U "$R/herdr.sock"
h pane list --format json 2>/dev/null | head -5
```

若 `pane.layout` 返回 error 说缺参数，或 `pane.split` 的字段名不是 `target_pane_id`，按实际报错修正并在这一步的注释里记下来。schema 里 `PaneSplitParams` 的字段名是权威：

```bash
python3 - <<'EOF'
import json
d=json.load(open('/tmp/herdr-schema.json'))
def find(o):
    if isinstance(o,dict):
        if o.get('properties',{}).get('direction') and 'ratio' in o.get('properties',{}):
            print(json.dumps(sorted(o['properties'].keys())))
        for v in o.values(): find(v)
    elif isinstance(o,list):
        for v in o: find(v)
find(d['schemas']['request'])
EOF
```

（`/tmp/herdr-schema.json` 用 `herdr api schema --json > /tmp/herdr-schema.json` 重新生成。）

- [ ] **Step 6: 提交**

```bash
git add Sources/HerdaKit/Protocol/ApiClient.swift Tests/HerdaKitTests/ApiClientTests.swift
git commit -m "feat: add the layout API surface

pane.layout plus the four mutations the native grid needs, and layout.updated
added to the subscription set. That last one is load-bearing: keyboard split and
JSON API split both go through dispatch_runtime_mutation, so the event always
fires — but without the subscription the UI would sit on a stale layout after
every prefix-key split.

Parameter names were checked against a live server and the bundled schema rather
than guessed."
```

---

## Task 3: `TerminalSession` 变协调者

**Files:**
- Modify: `Sources/HerdaKit/Runtime/TerminalSession.swift`
- Create: `Tests/HerdaKitTests/TerminalSessionLayoutTests.swift`

- [ ] **Step 1: 写失败的测试**

协调逻辑要在没有 server 的情况下可测，所以把「快照 + 帧 → 每个 pane 该显示什么」抽成一个不碰网络的类型 `PaneFrameRouter`，`TerminalSession` 持有它。

创建 `Tests/HerdaKitTests/TerminalSessionLayoutTests.swift`：

```swift
import XCTest
@testable import HerdaKit

final class PaneFrameRouterTests: XCTestCase {
    private func frame(width: UInt16, height: UInt16, fill: String = "x") -> GridFrame {
        GridFrame(
            cells: Array(
                repeating: GridCell(
                    symbol: fill, foreground: 0, background: 0,
                    modifier: 0, skip: false, hyperlink: nil
                ),
                count: Int(width) * Int(height)
            ),
            width: width, height: height, cursor: nil, hyperlinks: [], graphics: []
        )
    }

    private let twoPanes = PaneLayoutSnapshot(
        workspaceId: "w1", tabId: "w1:t1", zoomed: false,
        area: PaneLayoutRect(x: 0, y: 0, width: 5, height: 2),
        focusedPaneId: "w1:p1",
        panes: [
            PaneLayoutPane(paneId: "w1:p1", focused: true,
                           rect: PaneLayoutRect(x: 0, y: 0, width: 2, height: 2)),
            PaneLayoutPane(paneId: "w1:p2", focused: false,
                           rect: PaneLayoutRect(x: 3, y: 0, width: 2, height: 2)),
        ],
        splits: []
    )

    func testRoutesOneSliceToEachPane() {
        var router = PaneFrameRouter()
        router.apply(twoPanes)
        let slices = router.slices(for: frame(width: 5, height: 2))

        XCTAssertEqual(slices.count, 2)
        XCTAssertEqual(slices["w1:p1"]?.width, 2)
        XCTAssertEqual(slices["w1:p2"]?.width, 2)
    }

    func testFallsBackToTheWholeGridWhenContentCrossesPanes() {
        // prefix key 按出来的 modal 会横跨 pane。此时按 rect 切会切碎它,所以整块
        // 渲染 —— 用一个特殊 key 表示「不要分卡片」。
        var router = PaneFrameRouter()
        router.apply(twoPanes)

        var cells = frame(width: 5, height: 2).cells
        cells[2] = GridCell(symbol: "─", foreground: 0, background: 0,
                            modifier: 0, skip: false, hyperlink: nil)
        let crossing = GridFrame(
            cells: cells, width: 5, height: 2,
            cursor: nil, hyperlinks: [], graphics: []
        )

        XCTAssertTrue(router.shouldRenderWholeGrid(crossing))
    }

    func testDoesNotFallBackWhenTheGapIsBlank() {
        var router = PaneFrameRouter()
        router.apply(twoPanes)
        XCTAssertFalse(router.shouldRenderWholeGrid(frame(width: 5, height: 2, fill: " ")))
    }

    func testZoomedRoutesEverythingToTheFocusedPane() {
        // spec 硬约束六。
        var router = PaneFrameRouter()
        router.apply(PaneLayoutSnapshot(
            workspaceId: "w1", tabId: "w1:t1", zoomed: true,
            area: PaneLayoutRect(x: 0, y: 0, width: 5, height: 2),
            focusedPaneId: "w1:p1",
            panes: twoPanes.panes, splits: []
        ))
        let slices = router.slices(for: frame(width: 5, height: 2))
        XCTAssertEqual(Array(slices.keys), ["w1:p1"])
        XCTAssertEqual(slices["w1:p1"]?.width, 5, "焦点 pane 铺满整个 area")
    }

    func testNoLayoutYetRoutesNothing() {
        // 启动时第一帧可能早于 pane.layout 的响应。此时不该猜。
        let router = PaneFrameRouter()
        XCTAssertTrue(router.slices(for: frame(width: 5, height: 2)).isEmpty)
        XCTAssertTrue(router.shouldRenderWholeGrid(frame(width: 5, height: 2)))
    }

    func testTracksTheFocusedPane() {
        var router = PaneFrameRouter()
        router.apply(twoPanes)
        XCTAssertEqual(router.focusedPaneId, "w1:p1")
        XCTAssertEqual(router.paneIds, ["w1:p1", "w1:p2"])
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `Scripts/test.sh 2>&1 | grep -E "PaneFrameRouter|error:" | head -5`

Expected: `cannot find 'PaneFrameRouter' in scope`。

- [ ] **Step 3: 实现 router**

创建 `Sources/HerdaKit/Layout/PaneFrameRouter.swift`：

```swift
import Foundation

/// 把一帧整块 grid 分派给各个 pane。
///
/// 独立于 `TerminalSession` 是为了可测:分派规则(zoom 退化、跨界回退、还没拿到
/// 布局时不猜)全是纯逻辑,不需要 server 或窗口。
public struct PaneFrameRouter: Sendable {
    private var snapshot: PaneLayoutSnapshot?

    public init() {}

    public mutating func apply(_ snapshot: PaneLayoutSnapshot) {
        self.snapshot = snapshot
    }

    public var focusedPaneId: String? { snapshot?.focusedPaneId }

    /// 该显示的 pane,顺序与 herdr 给的一致。
    public var visiblePanes: [PaneLayoutPane] {
        guard let snapshot else { return [] }
        return LayoutGeometry.visiblePanes(in: snapshot)
    }

    public var paneIds: [String] { visiblePanes.map(\.paneId) }

    /// 每个 pane 的子帧。还没拿到布局时返回空 —— 启动时第一帧可能早于
    /// `pane.layout` 的响应,此时猜一个布局会闪一下错的画面。
    public func slices(for frame: GridFrame) -> [String: GridFrame] {
        var result: [String: GridFrame] = [:]
        for pane in visiblePanes {
            result[pane.paneId] = FrameSlice.slice(frame, to: pane.rect)
        }
        return result
    }

    /// 是否该放弃分卡片、整块渲染。
    ///
    /// 两种情况:还没有布局(不猜),以及有内容跨越了 pane 边界(prefix key 按出来的
    /// modal —— 按 rect 切会把它切碎,落在间隙格上的部分会丢失)。
    public func shouldRenderWholeGrid(_ frame: GridFrame) -> Bool {
        guard !visiblePanes.isEmpty else { return true }
        return GapProbe.hasContentOutsidePanes(frame, panes: visiblePanes.map(\.rect))
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `Scripts/test.sh 2>&1 | tail -5`

Expected: 全部通过。

- [ ] **Step 5: 接进 `TerminalSession`**

改动四处。

其一，替换 `view` 属性（`TerminalSession.swift:21`）与新增状态：

```swift
    /// 每个 pane 一个 view。key 是 pane id。
    @Published public private(set) var paneViews: [String: TerminalGridView] = [:]
    /// 分派规则。`@Published` 让 view 层跟着布局变化重排。
    @Published public private(set) var router = PaneFrameRouter()
    /// 有内容跨越 pane 边界时,整块 grid 画在这个 view 上(见 `PaneFrameRouter`)。
    public let wholeGridView: TerminalGridView
    /// 当前是否处于整块渲染回退态。
    @Published public private(set) var isWholeGridFallback = true

    private let font: TerminalFont
```

其二，`init`（`:34-40`）改为：

```swift
    public init(
        paths: RuntimePaths = .defaultLocation(),
        font: TerminalFont = TerminalFont()
    ) {
        self.paths = paths
        self.font = font
        self.wholeGridView = TerminalGridView(terminalFont: font)
    }
```

其三，`start`（`:56-58`）里用 font 算 grid：

```swift
        let grid = font.gridSize(for: viewportSize)
        let cell = font.cellSize
        lastReportedGrid = grid
```

同样 `resize`（`:273`）与 `sendResize`（`:288`）里的 `view.gridSize` / `view.cellSize` 换成 `font.`。`applyTheme` 的调用点（`:68`）改为遍历所有 view：

```swift
                await MainActor.run {
                    self?.theme = resolvedTheme
                    self?.applyThemeToAllViews(resolvedTheme)
                }
```

并新增：

```swift
    private func applyThemeToAllViews(_ theme: Theme) {
        wholeGridView.applyTheme(theme)
        for view in paneViews.values { view.applyTheme(theme) }
    }
```

`setTheme`（`:261-267`）里的 `view.applyTheme(newTheme)` 也换成 `applyThemeToAllViews(newTheme)`。

其四，帧分派。`attach`（`:95-101`）改为：

```swift
        wholeGridView.onPayload = { [weak self] payload in
            Task { @MainActor in self?.send(payload) }
        }
        log("handshake ok, read loop starting")
        connection.startReadLoop(
            onFrame: { [weak self] frame in
                Task { @MainActor in self?.distribute(frame) }
            },
```

新增分派方法：

```swift
    /// 把一帧分给各个 pane,或在跨界时整块渲染。
    private func distribute(_ frame: GridFrame) {
        let fallback = router.shouldRenderWholeGrid(frame)
        if fallback != isWholeGridFallback { isWholeGridFallback = fallback }

        if fallback {
            wholeGridView.update(frame)
            return
        }
        for (paneId, slice) in router.slices(for: frame) {
            viewForPane(paneId).update(slice)
        }
    }

    /// 取或建一个 pane 的 view。建时立刻套上当前主题与输入出口 —— 漏掉任何一样
    /// 都会得到一个配色错误或打字无反应的 pane。
    private func viewForPane(_ paneId: String) -> TerminalGridView {
        if let existing = paneViews[paneId] { return existing }
        let view = TerminalGridView(terminalFont: font)
        view.applyTheme(theme)
        view.onPayload = { [weak self] payload in
            Task { @MainActor in self?.send(payload) }
        }
        paneViews[paneId] = view
        return view
    }

    /// 应用一份新布局,并丢掉已消失 pane 的 view。
    private func applyLayout(_ snapshot: PaneLayoutSnapshot) {
        router.apply(snapshot)
        let live = Set(snapshot.panes.map(\.paneId))
        for paneId in paneViews.keys where !live.contains(paneId) {
            paneViews.removeValue(forKey: paneId)
        }
        for paneId in live { _ = viewForPane(paneId) }
    }
```

其五，API 通道里取快照并订阅事件。`startApiChannel`（`:126-148`）的 `do` 块开头补一次 layout 请求：

```swift
            do {
                let snapshot = try api.snapshot()
                await MainActor.run { self?.sidebar.apply(snapshot) }
                // 布局快照必须在 app 连接 hello 之后取 —— 那时 effective_size 才是
                // 声明的尺寸(herdr headless.rs:2818 在注册时就设 foreground)。本方法
                // 由 attach() 调用,已经在 handshake 之后。
                if let layout = try? api.paneLayout() {
                    await MainActor.run { self?.applyLayout(layout) }
                }
                let pump = try api.subscribe()
```

并在 `pump.start` 的 `onEvent` 里分流 layout 事件：

```swift
                    onEvent: { name, data in
                        let box = EventBox(name: name, data: data)
                        Task { @MainActor in
                            self?.handle(event: box.name, data: box.data)
                        }
                    },
```

新增：

```swift
    /// 事件分流。`layout_updated` 自己处理,其余交给 sidebar。
    ///
    /// 订阅名用点、推送的 `event` 字段用下划线,所以这里匹配的是下划线形式。
    private func handle(event name: String, data: [String: Any]) {
        guard name == "layout_updated" else {
            sidebar.handle(event: name, data: data)
            return
        }
        guard let payload = data["layout"],
              let bytes = try? JSONSerialization.data(withJSONObject: payload),
              let snapshot = try? ApiTypes.decoder.decode(PaneLayoutSnapshot.self, from: bytes)
        else {
            log("layout_updated payload did not decode")
            return
        }
        applyLayout(snapshot)
    }
```

`focusTerminal`（`:301-303`）改为把焦点交给焦点 pane 的 view：

```swift
    /// 返回键盘焦点。sidebar 的 SwiftUI 控件点一下就拿走 first responder 且不还。
    public func focusTerminal() {
        let target = router.focusedPaneId.flatMap { paneViews[$0] } ?? wholeGridView
        target.window?.makeFirstResponder(target)
    }
```

- [ ] **Step 6: 编译并跑测试**

Run: `Scripts/test.sh 2>&1 | tail -20`

Expected: 全部通过。若 `ContentView.swift` 因为 `session.view` 不存在而编译失败，这是预期的 —— Task 5 会改它。此时先只跑 HerdaKit 的测试确认库本身正确：

Run: `xcodebuild -project herda.xcodeproj -scheme Herda -destination 'platform=macOS' -derivedDataPath build build 2>&1 | grep -E "error:" | head -10`

- [ ] **Step 7: 提交**

```bash
git add Sources/HerdaKit/Layout/PaneFrameRouter.swift Sources/HerdaKit/Runtime/TerminalSession.swift Tests/HerdaKitTests/TerminalSessionLayoutTests.swift
git commit -m "feat: route one grid frame to per-pane views

TerminalSession stops owning a single view and becomes a coordinator: one
PaneLayoutSnapshot plus a paneId->view dictionary, still over one render
connection. The routing rules live in PaneFrameRouter so they can be tested
without a server — zoom collapsing to the focused pane, falling back to
whole-grid rendering when something crosses a pane boundary, and refusing to
guess a layout before pane.layout answers.

The layout snapshot is fetched from inside the API channel, which attach()
starts after the handshake — that ordering matters because effective_size is
only the declared size once the app connection is registered."
```

---

## Task 4: `PaneGridView`

**Files:**
- Create: `Sources/Herda/PaneGridView.swift`

- [ ] **Step 1: 实现**

这一层没有单元测试（是 view 布局，按 design.md §9 的取舍靠手动跑）。几何全部来自计划二的纯函数，已经测过。

创建 `Sources/Herda/PaneGridView.swift`：

```swift
import HerdaKit
import SwiftUI

/// 终端区:每个 pane 一张原生卡片,位置由 herdr 的 layout rect 决定。
///
/// 卡片之间那 8pt 间距不是这里编出来的 —— herdr 在 `pane_gaps` 下让相邻 pane 各
/// 收缩一格,而一格在 13pt 下正好 8pt(等于 `ChromeMetrics.cardGap`)。所以按 rect
/// 换算出的 frame 之间天然就有那道缝,这里只负责把卡片放进去。
struct PaneGridView: View {
    @ObservedObject var session: TerminalSession
    let theme: Theme

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if session.isWholeGridFallback {
                    // 有内容跨越 pane 边界(prefix key 按出来的 modal),或者还没拿到
                    // 布局。整块画,不分卡片 —— 切开它会丢掉落在间隙上的部分。
                    GridViewRepresentable(view: session.wholeGridView)
                        .cardSurface(
                            fill: theme.chrome.panelBackground,
                            over: theme.chrome.windowBackground,
                            theme: theme
                        )
                } else {
                    ForEach(session.router.visiblePanes) { pane in
                        paneCard(pane)
                    }
                }
            }
            .onAppear { session.start(viewportSize: geometry.size) }
            .onChange(of: geometry.size) { _, size in session.resize(to: size) }
        }
    }

    @ViewBuilder private func paneCard(_ pane: PaneLayoutPane) -> some View {
        let frame = LayoutGeometry.frame(for: pane.rect, cellSize: session.cellSize)

        Group {
            if let view = session.paneViews[pane.paneId] {
                GridViewRepresentable(view: view)
            } else {
                Color.clear
            }
        }
        .frame(width: frame.width, height: frame.height)
        .cardSurface(
            fill: theme.chrome.panelBackground,
            over: theme.chrome.windowBackground,
            theme: theme
        )
        // 焦点由描边亮度表达:herdr 原来画的焦点边框随 pane_borders 一起关掉了,
        // 非焦点卡片压暗描边而不是换色 —— 18 个主题里换色很难都好看。
        .opacity(pane.focused ? 1 : 0.85)
        .offset(x: frame.minX, y: frame.minY)
        .onTapGesture {
            session.focusPane(pane.paneId)
            session.focusTerminal()
        }
    }
}

private struct GridViewRepresentable: NSViewRepresentable {
    let view: TerminalGridView

    func makeNSView(context: Context) -> TerminalGridView { view }
    func updateNSView(_ nsView: TerminalGridView, context: Context) {}
}
```

- [ ] **Step 2: 暴露 `cellSize`**

`PaneGridView` 需要 `session.cellSize`。在 `TerminalSession` 里加：

```swift
    /// 一个 cell 的像素尺寸。view 层按它把 layout 的 cell rect 换算成 frame。
    public var cellSize: CGSize { font.cellSize }
```

- [ ] **Step 3: 生成工程并编译**

Run: `xcodegen generate && xcodebuild -project herda.xcodeproj -scheme Herda -configuration Debug -destination 'platform=macOS' -derivedDataPath build build 2>&1 | grep -E "error:" | head -10`

Expected: 只剩 `ContentView.swift` 关于 `session.view` 的错误（Task 5 修）。

- [ ] **Step 4: 提交**

```bash
git add Sources/Herda/PaneGridView.swift Sources/HerdaKit/Runtime/TerminalSession.swift
git commit -m "feat: lay out pane cards from herdr's layout rects

The 8pt gap between cards is not invented here: herdr shrinks neighbouring panes
by one cell under pane_gaps, and one cell is exactly 8pt at 13pt — the same value
as ChromeMetrics.cardGap. Converting rects to frames therefore leaves the gap
already there.

Focus is expressed by dimming unfocused cards rather than recolouring their
border, because herdr's own focus border went away with pane_borders and a colour
change that reads well across all 18 themes is a harder problem than opacity."
```

---

## Task 5: 接进 `ContentView`

**Files:**
- Modify: `Sources/Herda/ContentView.swift:55-80`（`terminalArea`）与 `:149-154`（旧的 representable）

- [ ] **Step 1: 替换 `terminalArea`**

把 `terminalArea`（`:55-80`）整段替换为：

```swift
    private var terminalArea: some View {
        ZStack {
            PaneGridView(session: session, theme: session.theme)
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

            overlay
        }
        // 窗口边距由 body 给,这里只让网格退出卡片的圆角:内缩超过
        // r(1 - 1/√2) 后任何单元格都不会被圆角切到,所以不必对
        // TerminalGridView 做 layer 裁剪。GeometryReader 拿到的是内缩后
        // 的尺寸,session.resize 因此仍收到正确的网格大小。
        .padding(ChromeMetrics.gridInset)
    }
```

- [ ] **Step 2: 卡片表面从 body 移到 pane**

`body` 里现在给 `terminalArea` 套了 `.cardSurface(...)`（`:35-39`）。卡片已经由 `PaneGridView` 逐个 pane 画，这里要去掉，否则会套两层描边。把 `:34-43` 改成：

```swift
            terminalArea
                .padding(.leading, ChromeMetrics.cardGap)
                .padding(.top, ChromeMetrics.contentTopInset)
                .padding(.trailing, ChromeMetrics.cardInset)
                .padding(.bottom, ChromeMetrics.cardInset)
```

- [ ] **Step 3: 删掉文件末尾的 `GridViewRepresentable`**

`PaneGridView.swift` 里已经有一个同名私有类型。删除 `ContentView.swift:149-154`。

- [ ] **Step 4: 编译**

Run: `xcodegen generate && xcodebuild -project herda.xcodeproj -scheme Herda -configuration Debug -destination 'platform=macOS' -derivedDataPath build build 2>&1 | grep -E "error:|warning: .*unused" | head -10`

Expected: 无 error。

- [ ] **Step 5: 跑测试**

Run: `Scripts/test.sh 2>&1 | tail -5`

Expected: 全部通过。

- [ ] **Step 6: 手动验证**

```bash
Scripts/run.sh --reset
```

在另一个终端（公共前置见计划一）：

```bash
h pane split --direction right
h pane split --direction down
```

肉眼确认：三张独立圆角卡片、8pt 间距、焦点卡片更亮；每个 pane 里的内容不错位（在每个 pane 里 `echo` 一个标记，确认它出现在正确的卡片里）。

再试 zoom 与 modal 回退：

```bash
h pane zoom --current      # 应变成单张卡片铺满
h pane zoom --current      # 恢复三张
```

窗口里按 prefix key 打开 herdr 的 Navigator，确认画面退回整块 grid（一张大卡片）而不是被切碎。

- [ ] **Step 7: 提交**

```bash
git add Sources/Herda/ContentView.swift
git commit -m "feat: put the pane card grid in the window

The card surface moves from the terminal area as a whole onto each pane, so the
window-level cardSurface call goes away — leaving it would draw a second border
around the grid of cards. The padding stays: it positions the area, and
GeometryReader still reports the inset size so resize reporting is unchanged."
```

---

## Self-Review 结果

spec 覆盖核查：

- 硬约束三（layout_updated 覆盖键盘操作）→ Task 2 的订阅 + Task 5 Step 6 用 `h pane split` 与窗口内 prefix key 双向验证
- 硬约束六（zoomed）→ Task 3 的 `PaneFrameRouter` 测试 + Task 5 Step 6 的手动验证
- 跨界 modal 回退 → Task 3 的 `shouldRenderWholeGrid` 测试 + Task 5 Step 6 打开 Navigator 验证
- 数据流「布局变化」→ Task 3 的 `applyLayout` 与事件分流
- 数据流「pane 生命周期」→ `applyLayout` 里移除消失 pane 的 view；`ServerShutdown` 语义未改（本方案没有 attach/observe 连接）
- 视觉「每个 pane 一张独立卡片、8pt 间距、焦点描边」→ Task 4

类型一致性：`PaneFrameRouter.visiblePanes` 返回 `[PaneLayoutPane]`，`PaneGridView` 的 `ForEach` 依赖它的 `Identifiable`（`id == paneId`，计划二已声明）；`session.cellSize` 与 `LayoutGeometry.frame(for:cellSize:)` 的参数类型一致。

留给计划四：鼠标坐标偏移（现在每个 pane 的 view 会把局部坐标当全局坐标发出去，点击与滚轮会打到错的 pane —— 这是已知的、计划四第一个任务要修的缺陷）、拖分隔线、原生滚动条。
