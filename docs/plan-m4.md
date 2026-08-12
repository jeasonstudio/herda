# M4「macOS 26 窗口 chrome」实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把窗口从「侧栏实色贴边 + 1pt hairline + 终端贴边」改成 macOS 26 的分层形态——侧栏与终端各是一张浮在窗口底色上的大圆角卡片，各自带阴影，间距取代分隔线。

**Architecture:** 表面全部保留 theme 实色，不用 Liquid Glass。新增两个 `HerdaKit/Theme/` 文件承载几何常量与卡片容器，`ChromePalette` 加一个 `windowBackground` 令牌；`ContentView` 套两层卡片，`SidebarView` 交出自己的背景。`TerminalGridView` 一行不改。

**Tech Stack:** Swift 6 严格并发 / SwiftUI（macOS 26 的 `ConcentricRectangle` + `containerShape`）/ XCTest / xcodegen

设计见 `docs/superpowers/specs/2026-08-11-macos26-chrome-design.md`。前置：M1–M3 已验收。

---

## 前置事实（已实测，勿重新推导）

**环境**：Xcode 26.6（17F113）、macOS 26.5 SDK、本机 macOS 26.3。

**API 位置**（`MacOSX26.5.sdk/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface`）。注意这些都在 **SwiftUICore** 而非 SwiftUI，`import SwiftUI` 即可拿到：

| API | 行 | 可用性 |
| --- | --- | --- |
| `ConcentricRectangle` | 13235 | macOS 26.0+ |
| `ConcentricRectangle(corners:isUniform:)` | 13237 | 同上 |
| `Edge.Corner.Style.concentric` | 19199 | 同上 |
| `containerShape(_: some RoundedRectangularShape)` | 13382 | 同上 |
| `RoundedRectangle: RoundedRectangularShape` | 13322 | 同上 |
| `glassEffect(_:in:)` | 2529 | 可用，**本次不用** |

**构建命令**（`Scripts/test.sh` 是权威；CLAUDE.md 里的 `macos-client.xcodeproj` / `HerdrPrototype` 已随重命名过时，见文末）：

```bash
xcodegen generate                    # 新增文件后必须重跑
Scripts/test.sh                      # 单测
xcodebuild -project herda.xcodeproj -scheme Herda \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath build build
```

**18 个主题的明度实测**：见 spec 的「实测数据」表。要点只有两条——`windowBackground` 的比例必须按明暗分档（暗 0.34 / 亮 0.10），且 `terminal` 主题的 `panelBackground` 是纯黑，往黑走不动，是唯一靠描边而非色差分离的主题。

**硬约束**（三条，spec 有完整推导，实现时不可绕过）：

1. 终端卡片底色必须 `== panelBackground`，否则网格默认背景与卡片边缘之间出现色带（`Theme.swift:92`）。
2. 卡片顶边不能切进那条仍持有窗口拖动手势的 titlebar 带，否则终端顶部几行的点击变成拖窗口（`ContentView.swift:8` 的注释记录了这件事）。
3. 卡片描边不可省——`terminal` 主题下它是唯一的分离手段。

## 文件结构

| 文件 | 职责 |
| --- | --- |
| `Sources/HerdaKit/Theme/ChromeMetrics.swift`（新建） | 窗口 chrome 的几何常量，仅此。互相推导的值集中一处，防止各自漂移 |
| `Sources/HerdaKit/Theme/CardSurface.swift`（新建） | 一张浮起卡片的全部外观：底色、圆角、描边、阴影、`containerShape` |
| `Sources/HerdaKit/Theme/ChromeSurfaces.swift`（改） | 加 `windowBackground` 派生令牌 |
| `Sources/Herda/ContentView.swift`（改） | 窗口底色 + inset；两张卡片；删中间的 hairline |
| `Sources/Herda/SidebarView.swift`（改） | 交出背景；删 `trafficLightClearance`；行圆角改 concentric |
| `Tests/HerdaKitTests/ChromeMetricsTests.swift`（新建） | 把 `cardTopInset` 锚定到系统报告的红绿灯位置 |
| `Tests/HerdaKitTests/ChromeSurfacesTests.swift`（改） | 加三个 `windowBackground` 测试 |
| `docs/design.md`（改） | §3 决策两行 + §7 加 M4 + §5 目录树补 `Theme/` |

`ChromeMetrics` 和 `CardSurface` 分开而不并成一个文件：前者是纯数据、无 SwiftUI 依赖，后者是 view 层。分开后 `ChromeMetricsTests` 不必为读一个常量拖进 SwiftUI。

---

## Task 1: deployment target 提到 macOS 26

**Files:**
- Modify: `project.yml:5-7`

- [ ] **Step 1: 改 deployment target**

`project.yml` 当前：

```yaml
options:
  bundleIdPrefix: app.herda
  deploymentTarget:
    macOS: "14.0"
```

改为：

```yaml
options:
  bundleIdPrefix: app.herda
  deploymentTarget:
    macOS: "26.0"
```

- [ ] **Step 2: 重新生成工程**

Run: `xcodegen generate`
Expected: `Created project at herda.xcodeproj`

- [ ] **Step 3: 确认现有代码在新 target 下仍然编译**

Run:
```bash
xcodebuild -project herda.xcodeproj -scheme Herda \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath build build
```
Expected: `** BUILD SUCCEEDED **`

若出现 deprecation 警告，本任务内**不处理**——那不是这次改造的范围。

- [ ] **Step 4: 确认单测仍然通过**

Run: `Scripts/test.sh`
Expected: 末行 `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add project.yml
git commit -m "build: raise the deployment target to macOS 26

The chrome rework needs ConcentricRectangle and containerShape, both
macOS 26.0+. Gating them behind if #available would split the view
bodies' return types and leave two appearances to maintain, so the
target moves instead. herda ships its own herdr binary and is pinned to
one protocol version, so it was never installable across a wide range of
systems anyway."
```

---

## Task 2: ChromeMetrics，并把 cardTopInset 锚定到红绿灯的实际位置

`cardTopInset = 28` 沿用的是改造前 `ContentView.titlebarStrip` 的值，而那个值的来源是 macOS 15 及更早的标准 titlebar。这个任务用测试把它锚定到系统实际报告的按钮位置——项目里那条「cell metrics 来自字体自己的表，绝不硬编码」的规矩，同类问题（一个硬编码的 `8x16` 曾经错了一年）。

**Files:**
- Create: `Sources/HerdaKit/Theme/ChromeMetrics.swift`
- Test: `Tests/HerdaKitTests/ChromeMetricsTests.swift`

- [ ] **Step 1: 写失败测试**

创建 `Tests/HerdaKitTests/ChromeMetricsTests.swift`：

```swift
import AppKit
import XCTest
@testable import HerdaKit

final class ChromeMetricsTests: XCTestCase {
    /// `cardTopInset` 不是审美选择。窗口是 `.hiddenTitleBar`,红绿灯浮在
    /// 内容顶部,且那条 titlebar 带仍然持有窗口拖动手势 —— 卡片顶边落进
    /// 带内,终端顶部几行的点击就会变成拖窗口。
    ///
    /// 断言的是净空关系而不是「等于 28」:后者只是把硬编码换个地方,
    /// 系统改了按钮位置照样错。
    func testCardTopInsetClearsTheTrafficLights() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        let content = try XCTUnwrap(window.contentView)
        let close = try XCTUnwrap(
            window.standardWindowButton(.closeButton),
            "a .titled window should have a close button"
        )

        // AppKit 的 y 轴向上,`.fullSizeContentView` 让 contentView 铺满
        // 窗口,所以按钮底边到内容顶边的距离是 height - minY。
        let inContent = close.convert(close.bounds, to: content)
        let clearanceNeeded = content.bounds.height - inContent.minY

        XCTAssertGreaterThanOrEqual(
            ChromeMetrics.cardTopInset,
            clearanceNeeded,
            "卡片顶边会压在红绿灯上,或落进仍持有拖动手势的 titlebar 带内"
        )
    }

    /// 网格不贴到圆角是「不必对 TerminalGridView 做 layer 裁剪」的前提:
    /// 圆角矩形的内接矩形在 r(1 - 1/√2) 处才脱离圆角。
    func testGridInsetClearsTheCardCorner() {
        // 显式标注 CGFloat:XCTAssertGreaterThan 是泛型,CGFloat 与 Double
        // 的隐式转换在泛型上下文里不生效,不标注会编译失败。
        let clearance: CGFloat = ChromeMetrics.cardRadius * (1 - 1 / 2.0.squareRoot())
        XCTAssertGreaterThan(ChromeMetrics.gridInset, clearance)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `Scripts/test.sh -only-testing:HerdaKitTests/ChromeMetricsTests`
Expected: 编译失败，`cannot find 'ChromeMetrics' in scope`

- [ ] **Step 3: 创建 ChromeMetrics**

创建 `Sources/HerdaKit/Theme/ChromeMetrics.swift`：

```swift
import CoreGraphics

/// 窗口 chrome 的几何。集中在这里而不是散在 view 里:这几个值互相
/// 推导(行圆角由卡片圆角和行内缩决定,网格内缩的下限由卡片圆角决定),
/// 分开写会各自漂移。
public enum ChromeMetrics {
    /// 卡片到窗口左/右/下边。
    public static let cardInset: CGFloat = 12

    /// 卡片到窗口顶边。比其余三边大不是为了视觉平衡:窗口是
    /// `.hiddenTitleBar`,但那条 titlebar 带仍然存在并仍然持有窗口拖动
    /// 手势,卡片顶边切进去,落在带内的终端行点击会被解释成拖窗口。
    /// 红绿灯也正好落在这条带上,浮在窗口底色而非卡片上。
    /// 由 `ChromeMetricsTests` 锚定到系统报告的按钮位置。
    public static let cardTopInset: CGFloat = 28

    /// 两张卡片之间。取代改造前的 1pt hairline —— 双卡片形态里分隔靠的
    /// 是面之间的间距,不是线。
    public static let cardGap: CGFloat = 10

    /// 卡片圆角。
    public static let cardRadius: CGFloat = 14

    /// 阴影。不透明度不在这里:它取决于主题明暗,由 `CardSurface` 从
    /// `Theme.isDark` 取。
    public static let cardShadowRadius: CGFloat = 14
    public static let cardShadowY: CGFloat = 3

    /// 终端网格到终端卡片边缘。下限由圆角决定:圆角矩形的内接矩形在
    /// r(1 - 1/√2) ≈ 0.293r 处脱离圆角,r = 14 时为 4.1pt。取 6pt 留
    /// 余量 —— 网格的任何单元格都不会被圆角切到,这是不必对
    /// `TerminalGridView` 做 layer 裁剪的前提(那会在渲染最热的路径上
    /// 多一层 mask 合成)。
    public static let gridInset: CGFloat = 6

    /// 侧栏行到侧栏卡片边缘。行圆角不在这里:由 `ConcentricRectangle`
    /// 从 `cardRadius` 和这个值推导。
    public static let rowInset: CGFloat = 8
}
```

- [ ] **Step 4: 重新生成工程并跑测试**

Run:
```bash
xcodegen generate
Scripts/test.sh -only-testing:HerdaKitTests/ChromeMetricsTests
```
Expected: `** TEST SUCCEEDED **`

**若 `testCardTopInsetClearsTheTrafficLights` 失败**：说明 macOS 26 的红绿灯位置与 28pt 不符。把测试打印出的 `clearanceNeeded` 向上取整后加 2pt 余量，改 `cardTopInset`，并在该常量的注释里记下实测值和日期。**不要**放宽断言。

**若该测试在 CI 上不稳定**（无头环境拿不到 `standardWindowButton`）：把它标记为需要窗口服务器的测试并在本机运行，把实测数字写进注释。判断依据是 `XCTUnwrap` 是否失败，而不是断言不成立——后者是真的净空不够。

- [ ] **Step 5: Commit**

```bash
git add Sources/HerdaKit/Theme/ChromeMetrics.swift \
        Tests/HerdaKitTests/ChromeMetricsTests.swift herda.xcodeproj
git commit -m "feat: add the chrome geometry, anchored to the traffic lights

The card insets, radius and grid inset derive from each other, so they
live in one place rather than scattered across the views.

Two of the numbers are constrained rather than chosen. The top inset
must clear the traffic lights because the hidden titlebar strip still
owns the window drag gesture — a card edge inside it turns terminal
clicks into window drags — so the test reads the close button's actual
frame instead of asserting the old hardcoded 28. The grid inset must
exceed r(1 - 1/sqrt(2)) = 4.1pt, where a rounded rect's inscribed
rectangle leaves the corner; clearing it is what makes layer clipping on
TerminalGridView unnecessary."
```

---

## Task 3: windowBackground 令牌

**Files:**
- Modify: `Sources/HerdaKit/Theme/ChromeSurfaces.swift:29-36`
- Test: `Tests/HerdaKitTests/ChromeSurfacesTests.swift`

- [ ] **Step 1: 写失败测试**

在 `Tests/HerdaKitTests/ChromeSurfacesTests.swift` 的 `testStatusColorsFollowHerdrSemantics` 之前插入：

```swift
    // MARK: windowBackground

    /// 明度差的可辨下界。Rec. 601 的 0–255 尺度上,3 是肉眼能分出来的
    /// 最小差;取更严会让本就低对比的深色主题误报。
    private func separated(_ a: ThemeColor, _ b: ThemeColor) -> Bool {
        abs(a.luminance - b.luminance) >= 3
    }

    /// 双卡片形态要求两张卡片都能从窗口底上分出来。分离可以来自色差,
    /// 也可以来自描边 —— `terminal` 主题的 `panelBackground` 是纯黑,
    /// 往黑走不动,只有描边这一条路。所以断言的是两条至少成立一条。
    func testEveryThemeFloatsBothCardsOffTheWindow() {
        for theme in ThemeCatalog.all {
            let chrome = theme.chrome
            let byColor =
                separated(chrome.windowBackground, chrome.panelBackground)
                && separated(chrome.windowBackground, chrome.sidebarBackground)
            let byBorder =
                separated(chrome.hairline, chrome.panelBackground)
                && separated(chrome.hairline, chrome.sidebarBackground)
            XCTAssertTrue(
                byColor || byBorder,
                "\(theme.configName): 卡片既无色差也无描边可辨,会看不见"
            )
        }
    }

    /// `terminal` 的 `panelBackground` 是 `TerminalPalette.ghostty
    /// .defaultBackground`,即纯黑;往黑走任何比例都不动,所以它的窗口底
    /// 与终端卡片完全同色。这是「描边不可省」的唯一真实用例 —— 写下来,
    /// 以免将来有人给 `windowBackground` 换算法时顺手「修好」这个主题,
    /// 静默移走描边存在的理由。
    func testTerminalThemeSeparatesByBorderAlone() {
        let chrome = ThemeCatalog.terminal.chrome
        XCTAssertEqual(chrome.windowBackground, chrome.panelBackground)
        XCTAssertTrue(separated(chrome.hairline, chrome.panelBackground))
        XCTAssertTrue(separated(chrome.hairline, chrome.sidebarBackground))
    }

    /// 亮色主题里 `sidebarBackground` 往暗走、`windowBackground` 也往暗
    /// 走,比例太小两者就撞:实测 0.05 时 one-light 的两者只差 0.5。
    func testWindowBackgroundStaysBelowTheSidebarInLightThemes() {
        for theme in ThemeCatalog.all where !theme.isDark {
            XCTAssertLessThan(
                theme.chrome.windowBackground.luminance,
                theme.chrome.sidebarBackground.luminance,
                theme.configName
            )
            XCTAssertTrue(
                separated(theme.chrome.windowBackground, theme.chrome.sidebarBackground),
                "\(theme.configName): 窗口底与侧栏卡片撞色"
            )
        }
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `Scripts/test.sh -only-testing:HerdaKitTests/ChromeSurfacesTests`
Expected: 编译失败，`value of type 'ChromePalette' has no member 'windowBackground'`

- [ ] **Step 3: 加令牌**

在 `Sources/HerdaKit/Theme/ChromeSurfaces.swift` 的 `sidebarBackground` 之后、`hairline` 之前插入：

```swift
    /// 两张卡片浮起来的那个面。往黑走而不是往 `text` 走:明暗主题的窗口
    /// 底都该比卡片沉,这是 macOS 自己的层次(亮色浅灰底 + 白卡片,暗色
    /// 近黑底 + 深灰卡片)。往 `text` 走会让亮色主题的底比卡片亮,卡片
    /// 就沉进去了。
    ///
    /// 比例按明暗分档,不是一个值。实测 18 个主题:单一 0.34 在暗色上给出
    /// 9–18 的明度差(合适),在亮色上给出 69–85 —— 那是从 #FAFAFA 掉到
    /// 中灰,而 macOS 亮色自己只差约 13。亮色还有个结构冲突:
    /// `sidebarBackground` 往暗走、这个也往暗走,比例太小两者会撞
    /// (0.05 时 one-light 的两者只差 0.5)。0.10 让亮色的 window-panel
    /// 差落在 23–25、window-sidebar 差 13–17,两边都成立。
    public var windowBackground: ThemeColor {
        // ChromePalette 自己就能判断明暗,不必绕道 Theme.isDark。
        let isDark = panelBackground.luminance < text.luminance
        return panelBackground.mixed(with: ThemeColor(0, 0, 0), isDark ? 0.34 : 0.10)
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `Scripts/test.sh -only-testing:HerdaKitTests/ChromeSurfacesTests`
Expected: `** TEST SUCCEEDED **`，三个新测试全过

- [ ] **Step 5: Commit**

```bash
git add Sources/HerdaKit/Theme/ChromeSurfaces.swift \
        Tests/HerdaKitTests/ChromeSurfacesTests.swift
git commit -m "feat: derive windowBackground, the surface the cards float on

Ratio is split by lightness rather than fixed. Measured across all 18
themes, a single 0.34 gives a 9-18 luminance delta on dark themes, which
is right, but 69-85 on light ones - that drops #FAFAFA to mid grey,
where macOS itself separates by about 13. Light themes also have a
structural conflict: sidebarBackground darkens and windowBackground
darkens too, so too small a ratio collides them (at 0.05 one-light's
window and sidebar differ by 0.5). 0.10 lands light themes at 23-25
against the panel and 13-17 against the sidebar.

The terminal theme's panelBackground is ghostty's default background,
pure black, so no ratio moves it and its window matches its terminal
card exactly. That is the one real case for the card border, and the
second test pins it down so a later algorithm change cannot quietly
remove the reason the border exists."
```

---

## Task 4: CardSurface

**Files:**
- Create: `Sources/HerdaKit/Theme/CardSurface.swift`

这个任务没有单测：它的正确性是「圆角裁到位、阴影不过重」，那是 Task 7 目视验收的事，写离屏断言不划算（`TerminalGridViewTests` 那种离屏渲染留给会算错的几何，不是留给一层 modifier）。

- [ ] **Step 1: 创建 CardSurface**

创建 `Sources/HerdaKit/Theme/CardSurface.swift`：

```swift
import SwiftUI

/// 一张浮在 `windowBackground` 上的卡片:底色、圆角、一道描边、一层阴影。
///
/// 描边不是装饰。`windowBackground` 是 `panelBackground` 往黑走得到的,
/// `terminal` 主题的 `panelBackground` 是纯黑,往黑走不动 —— 那个主题下
/// 窗口底与终端卡片完全同色,把卡片托起来的只有描边和阴影。
///
/// `containerShape` 是给后代读的:侧栏的行用 `ConcentricRectangle` 从这个
/// 形状和自己的内缩推导圆角,不再手写数字。
public struct CardSurface: ViewModifier {
    let fill: ThemeColor
    let theme: Theme

    public init(fill: ThemeColor, theme: Theme) {
        self.fill = fill
        self.theme = theme
    }

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: ChromeMetrics.cardRadius,
            style: .continuous
        )
        return content
            .background(fill.color)
            .clipShape(shape)
            .containerShape(shape)
            .overlay(shape.strokeBorder(theme.chrome.hairline.color, lineWidth: 1))
            // 暗色主题的底本身就暗,0.12 的阴影在上面看不出来。
            .shadow(
                color: .black.opacity(theme.isDark ? 0.45 : 0.12),
                radius: ChromeMetrics.cardShadowRadius,
                y: ChromeMetrics.cardShadowY
            )
    }
}

extension View {
    /// 把这个视图变成一张浮起的卡片。
    public func cardSurface(fill: ThemeColor, theme: Theme) -> some View {
        modifier(CardSurface(fill: fill, theme: theme))
    }
}
```

- [ ] **Step 2: 重新生成工程并确认编译**

Run:
```bash
xcodegen generate
xcodebuild -project herda.xcodeproj -scheme Herda \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath build build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: 确认既有单测未被打断**

Run: `Scripts/test.sh`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Sources/HerdaKit/Theme/CardSurface.swift herda.xcodeproj
git commit -m "feat: add the floating card surface

Carries the border unconditionally rather than only when the fill and
the window background differ: under the terminal theme they are the same
colour, and the border plus the shadow are the only things holding the
card off the background.

Sets containerShape so descendants can derive their own radii — the
sidebar rows read it through ConcentricRectangle instead of repeating a
hand-computed 6."
```

---

## Task 5: ContentView 接成双卡片

**Files:**
- Modify: `Sources/Herda/ContentView.swift:5-78`

- [ ] **Step 1: 替换 body**

`ContentView.swift` 当前 `body`（第 13–50 行）与其上方的 `titlebarStrip` 常量（第 8–11 行）整体替换。

删除这段：

```swift
    /// The window draws no titlebar, but the strip is still there and still owns
    /// the drag gesture, so the terminal starts below it. Anything placed inside
    /// the strip would take the drag instead of the click.
    private let titlebarStrip: CGFloat = 28
```

`body` 从：

```swift
    var body: some View {
        HStack(spacing: 0) {
```

到

```swift
            Rectangle()
                .fill(session.theme.chrome.hairline.color)
                .frame(width: 1)

            terminalArea
        }
        .background(session.theme.chrome.panelBackground.color)
        .ignoresSafeArea(.container, edges: .top)
```

替换为：

```swift
    var body: some View {
        // 两张卡片,间距而不是分隔线。顶边比其余三边深:那条 titlebar 带
        // 仍然持有窗口拖动手势(见 ChromeMetrics.cardTopInset),红绿灯也
        // 落在带内,浮在窗口底色而非卡片上。
        HStack(spacing: ChromeMetrics.cardGap) {
            SidebarView(
                model: session.sidebar,
                theme: session.theme,
                onSelectWorkspace: {
                    session.focusWorkspace($0)
                    session.focusTerminal()
                },
                onSelectPane: {
                    session.focusPane($0)
                    session.focusTerminal()
                },
                onSelectTheme: {
                    session.setTheme($0)
                    session.focusTerminal()
                }
            )
            .frame(width: 224)
            .cardSurface(fill: session.theme.chrome.sidebarBackground, theme: session.theme)

            terminalArea
                .cardSurface(fill: session.theme.chrome.panelBackground, theme: session.theme)
        }
        .padding(.top, ChromeMetrics.cardTopInset)
        .padding(.horizontal, ChromeMetrics.cardInset)
        .padding(.bottom, ChromeMetrics.cardInset)
        .background(session.theme.chrome.windowBackground.color)
        .ignoresSafeArea(.container, edges: .top)
```

注意原来 `SidebarView(...)` 那段调用**内容不变**，只是在 `.frame(width: 224)` 后多了 `.cardSurface(...)`；`Rectangle()` 那条 hairline 整条删除。`.onChange` 与 `.onDisappear` 两个修饰保持原样接在后面。

- [ ] **Step 2: 改 terminalArea 的 padding**

`terminalArea`（第 52–78 行）的末尾从：

```swift
        // Content is inset from the window edges rather than butting against
        // them. The grid derives its own columns and rows from what is left.
        .padding(.top, titlebarStrip)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.bottom, 8)
```

改为：

```swift
        // 窗口边距由 body 给,这里只让网格退出卡片的圆角:内缩超过
        // r(1 - 1/√2) 后任何单元格都不会被圆角切到,所以不必对
        // TerminalGridView 做 layer 裁剪。GeometryReader 拿到的是内缩后
        // 的尺寸,session.resize 因此仍收到正确的网格大小。
        .padding(ChromeMetrics.gridInset)
```

`GeometryReader`、`GridViewRepresentable`、两个 `onReceive`、`overlay` 全部不动。

- [ ] **Step 3: 编译**

Run:
```bash
xcodebuild -project herda.xcodeproj -scheme Herda \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath build build
```
Expected: `** BUILD SUCCEEDED **`

若报 `cannot find 'titlebarStrip' in scope`，说明 Step 2 漏改了 `terminalArea` 的 padding。

- [ ] **Step 4: 单测**

Run: `Scripts/test.sh`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sources/Herda/ContentView.swift
git commit -m "feat: float the sidebar and terminal as separate cards

Spacing replaces the 1pt hairline between them, and the window's own
background becomes the surface both cards sit on.

The top inset stays at the titlebar strip's height rather than dropping
to 12 with the other three edges. That strip still owns the window drag
gesture, so a card edge inside it would turn the terminal's top rows
into a drag handle. It also puts the traffic lights on the window
background rather than on the sidebar card, which is what lets the
sidebar drop its own 28pt clearance."
```

---

## Task 6: SidebarView 交出背景，行圆角改 concentric

**Files:**
- Modify: `Sources/Herda/SidebarView.swift:28-31, 36-49, 93-109, 138-143, 247-250, 374-392`

- [ ] **Step 1: 删掉自身背景与红绿灯预留**

删除常量（第 28–30 行）：

```swift
    /// The window has no titlebar of its own, so the traffic lights float over
    /// the top of the sidebar. Nothing may be drawn under them.
    private let trafficLightClearance: CGFloat = 28
```

`body`（第 36–49 行）末尾从：

```swift
        }
        .background(theme.chrome.sidebarBackground.color)
    }
```

改为：

```swift
        }
    }
```

底色现在由 `CardSurface` 提供——留着这一行会在卡片内再糊一层同色，`clipShape` 之外的圆角处还会露出方角。

- [ ] **Step 2: 收掉 spacesSection 的顶部预留**

`spacesSection`（第 96 行）从：

```swift
                .padding(.top, trafficLightClearance + 12)
```

改为：

```swift
                // 红绿灯现在落在窗口底色上,侧栏不再为它让位。
                .padding(.top, 12)
```

- [ ] **Step 3: 行内缩改用共享常量**

`spacesSection`（第 105 行）与 `agentsSection`（第 167 行）各有一处：

```swift
                .padding(.horizontal, 8)
```

两处都改为：

```swift
                .padding(.horizontal, ChromeMetrics.rowInset)
```

这不是为了消除魔法数字本身，而是因为下一步的 `ConcentricRectangle` 要用这个内缩推导圆角——两个值必须是同一个。

- [ ] **Step 4: RowFill 改用 ConcentricRectangle**

`RowFill.body`（第 380–385 行）从：

```swift
    func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
```

改为：

```swift
    func body(content: Content) -> some View {
        content
            // 圆角由卡片的 containerShape 和这一行的内缩推导,不再手写。
            // cardRadius 14 减 rowInset 8 正好还是改造前硬编码的 6 —— 换成
            // concentric 是为了以后调卡片圆角时不必再手算这个差。
            .background(fill, in: ConcentricRectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
```

- [ ] **Step 5: 确认两条 hairline 都保留**

不要改动这两处：

- `divider(in:)`（第 60–89 行）的 `Rectangle().fill(theme.chrome.hairline.color)` —— 双区之间的分区线，同时是拖动把手
- `footer`（第 278–281 行）的 `Rectangle().fill(theme.chrome.hairline.color)` —— footer 上方的分区线

规则是「卡片之间用间距，卡片内部用线」。本次删掉的 hairline 只有 `ContentView` 里侧栏与终端之间那一条。

- [ ] **Step 6: 编译并跑测试**

Run:
```bash
xcodebuild -project herda.xcodeproj -scheme Herda \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath build build
Scripts/test.sh
```
Expected: 两者都成功

若报 `cannot find 'trafficLightClearance' in scope`，说明 Step 2 漏改。

- [ ] **Step 7: Commit**

```bash
git add Sources/Herda/SidebarView.swift
git commit -m "feat: let the sidebar card own the sidebar's background

Drops the view's own fill — CardSurface provides it now, and keeping
both would smear a second copy inside the card and show square corners
outside the clip.

Also drops the 28pt traffic light clearance. The lights sit on the
window background now, below the card's top edge, so the sidebar no
longer has to leave room for them.

Row corners move to ConcentricRectangle, derived from the card's
containerShape and the row inset. That currently evaluates to the same 6
the code hardcoded, so this changes nothing on screen; it means the next
change to the card radius does not need the difference recomputed by
hand."
```

---

## Task 7: 目视验收

自动化测试覆盖不到的部分——圆角、阴影、层次在 18 个主题下是否都成立。

**Files:** 无改动（发现问题则回到对应 Task）

- [ ] **Step 1: 跑起来**

Run:
```bash
xcodebuild -project herda.xcodeproj -scheme Herda \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath build build
open build/Build/Products/Debug/Herda.app
```

- [ ] **Step 2: 逐项确认**

- [ ] 两张卡片各有可见圆角与阴影，间距分隔，中间没有残留的竖线
- [ ] 红绿灯浮在窗口底色上、卡片顶边之上，不压任何内容
- [ ] **点击终端最上面两行能正常输入，不会拖动窗口**（硬约束二，这是本次最容易回归的一点）
- [ ] 拖动卡片上方的空白带能移动窗口
- [ ] 侧栏选中行的圆角看起来与卡片圆角协调，没有变成直角或过圆
- [ ] 侧栏双区之间的拖动分隔线仍在，仍可拖动
- [ ] footer 上方的分隔线仍在
- [ ] 终端网格四角没有被圆角切掉字符

- [ ] **Step 3: 切主题确认三个边界**

用 footer 的主题菜单切到这三个，它们各自代表一类：

- [ ] `Terminal` —— 窗口底与终端卡片同色，卡片必须仍能靠描边和阴影看出来（这是 `terminal` 主题的实测结论）
- [ ] `One Light` —— 亮色主题里 window/sidebar 最接近的一个（实测差 13），两者不能糊成一片
- [ ] `Catppuccin` —— 暗色主题里 window/panel 差最小的一档（实测差 9）

- [ ] **Step 4: 记录结果**

把结果写进本文件末尾的「M4 验收结果」一节，格式照 `plan-m3.md`：逐项结论，发现的缺陷连同根因一起记。

---

## Task 8: 同步 design.md

**Files:**
- Modify: `docs/design.md:49-62`（§3 表格）、`docs/design.md:138-160`（§5 目录树）、`docs/design.md:245-251`（§7 M3 之后）

- [ ] **Step 1: §3 加两行决策**

在 `## 3. 关键决策记录` 的表格里，`渲染技术` 那行之后插入：

```markdown
| 窗口 chrome | **双卡片浮起 + theme 实色** | 侧栏与终端各是一张大圆角卡片,间距取代 hairline。表面不用 Liquid Glass:终端正文要长时间阅读,半透明会让对比度随桌面壁纸浮动,且 18 个实色主题会降格成一层 tint |
| deployment target | macOS 26 | `ConcentricRectangle` / `containerShape` 都是 26.0+。用 `if #available` 会让 view body 的返回类型分裂并留下两套外观要维护;app 自带 herdr binary 且 pin 单一协议版本,本来就不跨系统分发 |
```

- [ ] **Step 2: §5 目录树补 Theme/**

`## 5. 组件划分` 的目录树里，`Sidebar/     SidebarViewModel` 那行之后插入：

```
      Theme/       Theme · ThemeCatalog · ChromeSurfaces
                   ChromeMetrics · CardSurface
```

只补这一处。同一棵树里 `SidebarViewModel` 实际叫 `SidebarModel`、`InputTranslator` 实际叫 `KeyMap`，那是本次之前就有的漂移，**不在这个任务里修**。

- [ ] **Step 3: §7 加 M4**

在 `### M3 — 原生侧边栏` 一节末尾（"M1 + M2 + M3 合起来构成…"那句之后）插入：

```markdown
### M4 — macOS 26 窗口 chrome

侧栏与终端改为两张浮在 `windowBackground` 上的大圆角卡片,间距取代 hairline;行圆角由 `ConcentricRectangle` 从卡片推导。deployment target 提到 macOS 26。表面保留 theme 实色,不用 Liquid Glass。

验收：两卡片圆角与阴影可见 · 终端顶部两行点击不触发窗口拖动 · `Terminal` / `One Light` / `Catppuccin` 三个边界主题下卡片仍可辨

设计见 `superpowers/specs/2026-08-11-macos26-chrome-design.md`,实现见 `plan-m4.md`。
```

- [ ] **Step 4: Commit**

```bash
git add docs/design.md docs/plan-m4.md
git commit -m "docs: record the macOS 26 chrome in the design of record

design.md had no window chrome section at all — titlebar, hairline and
hiddenTitleBar were absent from it — so this adds the decision rows and
an M4 entry rather than replacing anything.

The component tree gains the Theme/ directory it never listed. Two
stale entries in that same tree (SidebarViewModel is SidebarModel,
InputTranslator is KeyMap) predate this work and are left alone."
```

---

## 自检结果

**Spec 覆盖**：逐节对照 `2026-08-11-macos26-chrome-design.md`——

| Spec 小节 | 落在 |
| --- | --- |
| 决策表 · deployment target | Task 1 |
| 硬约束一（终端底色 = panelBackground） | Task 5 Step 1，`cardSurface(fill: panelBackground)` |
| 硬约束二（卡片不进拖动带） | Task 2（常量 + 测试）、Task 5 Step 1、Task 7 Step 2 第三项 |
| 硬约束三（描边不可省） | Task 4（无条件描边）、Task 3 的 `testTerminalThemeSeparatesByBorderAlone` |
| 度量 | Task 2 |
| 颜色令牌 | Task 3 |
| 实测数据 | Task 3 的注释与三个测试，Task 7 Step 3 的三个边界主题 |
| 卡片容器 | Task 4 |
| 终端卡片的圆角（不做 layer 裁剪） | Task 2 的 `testGridInsetClearsTheCardCorner`、Task 5 Step 2 |
| 行圆角 concentric | Task 6 Step 3–4 |
| 文件改动表 | Task 1–6、Task 8 |
| 测试（三个） | Task 3 Step 1 |
| 需要实测的量（titlebar strip） | Task 2 Step 1 + Step 4 的失败处置 |
| 代价 | 无需实现，Task 7 目视确认列数损失可接受 |
| 收尾（design.md） | Task 8 |

无遗漏。

**占位符扫描**：无 TBD / TODO / 「类似 Task N」/ 「加上适当的错误处理」。每个改代码的步骤都给了完整代码块与替换前后的原文。

**类型一致性**：`ChromeMetrics` 的成员名（`cardInset` / `cardTopInset` / `cardGap` / `cardRadius` / `cardShadowRadius` / `cardShadowY` / `gridInset` / `rowInset`）在 Task 2 定义，Task 5、Task 6 的引用与之逐一对应。`CardSurface(fill:theme:)` 与便利方法 `cardSurface(fill:theme:)` 在 Task 4 定义、Task 5 使用，签名一致。`windowBackground` 在 Task 3 定义、Task 5 使用。测试里的 `separated(_:_:)` 是 `ChromeSurfacesTests` 的私有方法，三个测试都在同一个类内。

**一处需要执行时注意**：Task 2 的红绿灯测试依赖能创建带 titlebar 的 `NSWindow`。既有 `TerminalGridInputTests` 会构造 `NSEvent` 并调 `keyDown`，说明测试环境的 AppKit 可用，但 `standardWindowButton` 比 `NSEvent` 多要求一层 titlebar view。Step 4 给了处置办法，区分「拿不到按钮」（环境问题）和「净空不够」（真缺陷）。

---

## 发现的既有问题（不在本次范围）

记录但不修：

1. **CLAUDE.md 的构建命令已过时。** 「Build and test」一节写的是 `xcodebuild -project macos-client.xcodeproj -scheme HerdrPrototype`，重命名成 `herda.xcodeproj` / scheme `Herda` 之后没跟上。`Scripts/test.sh` 是对的。同一节的 `Sources/HerdrPrototype/` 与正文多处 `HerdrKit` 也都还是旧名。
2. **design.md §5 目录树的两处漂移**：`SidebarViewModel` 实际是 `SidebarModel`，`InputTranslator` 实际是 `KeyMap`。
3. **CLAUDE.md 自述的两处已知过时**（`sidebar_start_collapsed`、§11 的 per-cell 绘制性能结论）依然存在。

前两条都是重命名的残留，值得单独一个 `docs:` 提交清一遍，与本次改造无关。

---

## M4 验收结果（2026-08-11）

全部 8 个 task 完成，`Scripts/test.sh` 通过，新增 8 个测试（`ChromeMetricsTests` 3 · `ChromeSurfacesTests` +3 · `CardSurfaceTests` 2）。

### 发现的缺陷

**`cardTopInset` 28 → 34：终端顶部 4pt 的点击一直被吞成拖窗口。** 这不是调参，是改造前就存在的缺陷。

28 沿用 `ContentView.titlebarStrip`，那个值的来源是 macOS 15 及更早的标准 titlebar 高度。macOS 26.3 实测拖动带是 **32pt**（`contentView.bounds.height` 减 `contentLayoutRect.height`），所以改造前终端区从 y=28 起、带到 y=32，中间 4pt 的点击归窗口拖动而非终端。

值得记的是**先写的那个测试没抓到它**：红绿灯净空只需 23pt（close 按钮实测 `(9, 577, 14, 14)`，内容高 600），`testCardTopInsetClearsTheTrafficLights` 在 28 下是通过的。是后补的 `testCardTopInsetClearsTheTitlebarDragStrip` 失败才暴露出来——红绿灯是视觉，拖动带才是会坏功能的那个，净空不是约束的全部。34 = 32 下限 + 2pt 防 Retina 半像素舍入。

顺带一个 macOS 26 的变化：红绿灯是 14×14，不再是旧系统的 12×12。

### 与计划的偏离

**一｜行圆角没用 `ConcentricRectangle`，计划要求用它。** 离屏探针（`ImageRenderer`，200×200 容器 / 圆角 14 / 行内缩 8 / 行落在容器垂直中部）实测它在那个位置算出 **0** 圆角，渲染结果与 `Rectangle()` 逐像素相同——侧栏每一行都会变直角。`.concentric(minimum: .fixed(6))` 能救回来，但那时 concentric 部分永远算 0、minimum 永远接管，等于用一个不会触发的机制包装一个常量，而且**不跟随** `cardRadius`——而"以后调卡片圆角不必手算行圆角"正是 spec 采用它的唯一理由。改为 `ChromeMetrics.rowRadius = cardRadius - rowInset`，减法反而真的跟随。

连带后果：`CardSurface` 的 `containerShape` 失去唯一消费者，一并删除。

**二｜deployment target 26 的理由变了。** `ConcentricRectangle` 和 `containerShape` 都不用之后，代码里没有 26-only API 了；实测把 target 降到 14.0 编译通过。保留 26 因此是产品决策而非技术必需，更正后的理由已写进 `design.md` §3。

**三｜三主题目视 → 18 主题离屏断言。** 计划的 Task 7 Step 3 要求切三个边界主题目视。实做时 `Terminal` 与 `Catppuccin Latte` 完成了目视，随后改为 `CardSurfaceTests` 的离屏渲染断言覆盖全部 18 个。

改的原因是截屏这条路不可靠：切主题重启后窗口位置漂移，固定坐标采样落到窗口外（一次采到桌面壁纸的蓝色，另一次 `open` 后 Herda 没到前台、截到的是前台 Ghostty 里的 herdr session 而不是 Herda）。离屏渲染没有这些问题，覆盖面还从 3 个扩到 18 个，也不会把无关的工作内容截进来。

**四｜`git add herda.xcodeproj`（计划 Task 2/4 步骤里）是错的**，`.gitignore` 忽略 `*.xcodeproj`，`git add` 对 ignored 路径直接报错。执行时已去掉。

### 逐项结论

| 验收项 | 结论 | 依据 |
| --- | --- | --- |
| 两卡片圆角与阴影可见 | 通过 | 目视（Catppuccin Latte、Terminal） |
| 红绿灯浮在窗口底色上、不压内容 | 通过 | 目视 + `testCardTopInsetClearsTheTrafficLights` |
| 终端顶部点击不触发窗口拖动 | 通过 | `testCardTopInsetClearsTheTitlebarDragStrip`；未用 GUI 点击 |
| 卡片之间无残留竖线 | 通过 | 目视，间隙是窗口底色 |
| 选中行圆角与卡片协调、非直角 | 通过 | 目视两主题 + concentric 探针数据 |
| 双区拖动线与 footer 线仍在 | 通过 | 代码确认两处 `hairline` 保留 + 目视 footer |
| 18 主题卡片均可辨 | 通过 | `testEveryThemeRendersTheCardDistinctFromTheWindow` |
| `terminal` 主题靠描边托起 | 通过 | 目视 + `testTerminalThemeCardIsHeldUpByTheBorderAlone` |
| 终端网格四角未被切字符 | **部分** | 数学保证（`gridInset` 6 > 4.1，有测试）+ 空终端目视；**未在满屏内容下目视** |

### 未做

- 满屏内容下终端四角的目视确认（上表最后一项）。**已在后续修订中补验，见下节。**
- 文末「发现的既有问题」三条仍未修，与本次改造无关。

---

## 后续修订：退回单卡片（2026-08-12）

双卡片形态跑起来之后，判定观感把窗口切得太碎，改为**只有终端浮起**：sidebar 与窗口底同层同色、贴左边缘、铺满整个高度。这是 spec 当初列为备选的「只终端浮起」那个方案。

### 这次暴露的第二个既有缺陷

**分隔线与卡片描边一律取 `hairline`，在亮色主题下不可见。**

`hairline` 相对 `panelBackground` 派生，而 `windowBackground` 也相对它派生、往同一方向（黑）走 —— 两条线收敛。离屏实测（`ImageRenderer` 走真实 `CardSurface` 绘制）卡片描边与窗口底的明度差：`kanagawa-lotus` **0**、`catppuccin-latte` 1、`tokyo-night-day` 与 `rose-pine-dawn` 各 2。**双卡片版本里卡片就已经没有可见边界了**，我当时在截图里注意到「描边看不见」，误判为「阴影太淡」。

原有测试没抓到，因为它断言的是「面色差 **或** 描边差至少成立一条」——亮色主题靠面色差就通过了，描边失效被掩盖。

修法是把隐含假设显式化：`hairline(on: surface)`，相对实际绘制所在的面派生，18 主题最小差 17。断言同时收紧为逐项独立（描边对窗口底、描边对卡片填充各断言一次）。收紧后回插旧实现验证过测试真的会失败——精确报出上面那 4 个主题。

### 度量重上 8pt 网格

`macos-design-guidelines` skill 的 Rule 9.6 与检查清单都要求 8pt 网格，而原值 `12 / 10 / 14 / 6 / 34` 一个都不在网格上，间距读不出节奏。现为 `cardInset 16 / cardGap 8 / cardRadius 12 / gridInset 8 / contentTopInset 40`。`contentTopInset` 顺带从比 32pt 拖动带只多 2pt 的余量变成多 8pt。

### 行圆角不再从卡片推导

`rowRadius = cardRadius - rowInset` 的前提是「行在一张圆角卡片里」。sidebar 不再是卡片之后，行不在任何圆角容器里，「同心」没有了对象，改为独立取 6（HIG 的 hover 行示例用的也是 6）。

### 目视验收（单卡片）

只截 Herda 自己的窗口（`System Events` 取窗口 geometry + `screencapture -R`），不再截全屏——上一轮截全屏时两次截错窗口，还会把无关工作内容拍进去。

| 验收项 | 结论 |
| --- | --- |
| 只有终端浮起，sidebar 与窗口底无缝 | 通过，放大后看不出 sidebar 与间隙的边界 |
| 卡片描边在亮色主题下可见 | 通过（这正是修复的验证点） |
| sidebar 双区分隔线可见 | 通过 |
| 红绿灯落在 sidebar 上方空白、不压内容 | 通过 |
| sidebar 铺满窗口高度、footer 贴底 | 通过 |
| 选中行 6pt 圆角与卡片 12pt 协调 | 通过 |
| **满屏内容下终端四角未切字符** | **通过** —— 这次终端里有真实 session，顶部 logo 与底部状态行都没有被圆角切到（补上了上一轮欠的那项） |

### 代价

相对改造前少 36pt 高、17pt 宽（约 2 行 2 列），比双卡片版本宽度上少损失 6pt（sidebar 贴边省掉了一侧 inset），高度上多损失（顶部 40 与底部 16 都比原来大）。
