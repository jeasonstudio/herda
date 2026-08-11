# macOS 26 窗口 chrome 改造设计

2026-08-11。改造对象：窗口 chrome、侧边栏、终端区的容器形态。不改渲染引擎、不改协议、不改侧边栏的信息结构。

## 目标

把窗口从「侧栏实色贴边 + 1pt hairline + 终端贴边」改成 macOS 26 的分层形态：侧栏和终端各是一张浮在窗口底色上的大圆角卡片，各自带阴影，间距取代分隔线。

## 非目标

- **不用 Liquid Glass 半透明材质。** `glassEffect` 在 macOS 26.5 SDK 里可用（`SwiftUICore` interface 2529 行），但终端正文是要长时间阅读的内容，半透明背景会让对比度随桌面壁纸浮动；且 18 个主题的实色调色板是这个 app 的设计资产，玻璃化会把它降格成一层 tint。表面全部保留 theme 实色。
- **不换 `NavigationSplitView`。** 它的 sidebar 是单列，会拆掉 `SidebarView` 的双区可拖分割和 `splitRatio` 的 `AppStorage` 逻辑，换来的只是少写几十行 padding。
- **不建 Radius/Elevation/Spacing 三层令牌体系。** 使用点只有两处卡片，三层抽象是给单一使用点造的。

## 决策

| 项 | 决定 |
| --- | --- |
| deployment target | `macOS 14.0` → `26.0`，无 `#available` 分支 |
| 表面材质 | theme 实色，不用玻璃 |
| 层次形态 | 双卡片浮起，间距取代 hairline |
| 圆角推导 | 卡片手写 14pt，行圆角由 `ConcentricRectangle` 从容器推导 |

deployment target 直接提到 26 而不做双轨：SwiftUI 里 `if #available` 分支会让 view body 的返回类型分裂，两套外观要各自维护。herda 是自用原型且与 herdr 协议版本强绑定，放弃 macOS 14/15 的代价可以接受。

## 硬约束

这三条不是偏好，是代码和系统行为推出来的，改设计时不能绕过。

**一｜终端卡片底色必须等于 `panelBackground`。** `TerminalPalette.derived` 把 `defaultBackground` 设成了 `chrome.panelBackground`（`Theme.swift:92`）。卡片底色一旦偏离，网格里默认背景的单元格和卡片边缘之间会出现一道色带。

**二｜卡片顶边不能切进 titlebar strip。** 窗口是 `.hiddenTitleBar`，但那条 28pt 的 strip 仍然存在并**仍然占着窗口拖动手势**（`ContentView.swift:8` 的注释记录了这件事）。卡片顶边若进入这条带子，落在带子里的终端行点击会被解释成拖窗口而不是送进终端。

因此顶边 inset 取 28、其余三边取 12。红绿灯正好落在这条带子上，浮在窗口底色而非卡片上，拖动手势落在纯底色的空白带上——语义正确。

这个决定顺带**删掉** `SidebarView.trafficLightClearance`（28pt）以及 `spacesSection` 里的 `.padding(.top, trafficLightClearance + 12)`：红绿灯不再压在侧栏上，侧栏内部不需要为它预留。

**三｜卡片描边不是装饰。** `windowBackground` 由 `panelBackground` 往黑走得到，`panelBackground` 已接近纯黑的主题下这个色差会趋近于零。那种情况下把卡片从底上托起来的是描边和阴影。所以描边不可省。

## 度量

新增 `Sources/HerdaKit/Theme/ChromeMetrics.swift`。集中而不散在 view 里：这几个值互相推导，分开写会各自漂移。

```swift
import CoreGraphics

public enum ChromeMetrics {
    /// 卡片到窗口左/右/下边。
    public static let cardInset: CGFloat = 12

    /// 卡片到窗口顶边。比其余三边大不是为了视觉平衡,见 spec 硬约束二:
    /// 顶部 28pt 仍被 titlebar 的拖动手势占着。
    public static let cardTopInset: CGFloat = 28

    /// 两张卡片之间。取代改造前的 1pt hairline —— 双卡片形态里分隔
    /// 靠的是面之间的间距,不是线。
    public static let cardGap: CGFloat = 10

    /// 卡片圆角。
    public static let cardRadius: CGFloat = 14

    /// 阴影。不透明度不在这里:它取决于主题明暗,由 CardSurface 从
    /// Theme.isDark 取。
    public static let cardShadowRadius: CGFloat = 14
    public static let cardShadowY: CGFloat = 3

    /// 终端网格到终端卡片边缘。下限由圆角决定:圆角矩形内接矩形的
    /// 角距外边缘 r(1 - 1/√2) ≈ 0.293r,r = 14 时为 4.1pt。取 6pt
    /// 留余量,网格的任何单元格都不会被圆角切到 —— 这是不必对
    /// TerminalGridView 做 layer 裁剪的前提,见「终端卡片的圆角」。
    public static let gridInset: CGFloat = 6

    /// 侧栏行到侧栏卡片边缘。行圆角不在这里:由 ConcentricRectangle
    /// 从 cardRadius 和这个值推导。
    public static let rowInset: CGFloat = 8
}
```

## 颜色令牌

`ChromeSurfaces.swift` 只加一个：

```swift
/// 两张卡片浮起来的那个面。往黑走而不是往 text 走:明暗主题的窗口底
/// 都该比卡片沉,这是 macOS 自己的层次(亮色浅灰底 + 白卡片,暗色近黑底
/// + 深灰卡片)。往 text 走会让亮色主题的底比卡片亮,卡片就沉进去了。
public var windowBackground: ThemeColor {
    panelBackground.mixed(with: ThemeColor(0, 0, 0), 0.34)
}
```

卡片描边**复用现成的 `hairline`**，不加新 token。`hairline = panelBackground.mixed(with: text, 0.16)`，暗色主题下比卡片亮、亮色主题下比卡片暗，两边都能勾出边缘。

`sidebarBackground` 和 `panelBackground` 保持原样：前者是侧栏卡片底色，后者是终端卡片底色（硬约束一）。

## 卡片容器

新增 `Sources/HerdaKit/Theme/CardSurface.swift`：

```swift
public struct CardSurface: ViewModifier {
    let fill: ThemeColor
    let theme: Theme

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: ChromeMetrics.cardRadius, style: .continuous
        )
        return content
            .background(fill.color)
            .clipShape(shape)
            // 行圆角从这里推导 —— RowFill 用 ConcentricRectangle 读它。
            .containerShape(shape)
            .overlay(shape.strokeBorder(theme.chrome.hairline.color, lineWidth: 1))
            .shadow(
                color: .black.opacity(theme.isDark ? 0.45 : 0.12),
                radius: ChromeMetrics.cardShadowRadius,
                y: ChromeMetrics.cardShadowY
            )
    }
}
```

阴影不透明度随明暗分档：暗色主题的底本身就暗，0.12 的阴影看不出来。

## 终端卡片的圆角

**不对 `TerminalGridView` 做 layer 裁剪。** 它用 Core Text 直绘，加 `layer.cornerRadius + masksToBounds` 会在渲染最热的路径上引入一层 mask 合成。

改为靠 `gridInset` 让网格退出圆角区域：卡片底色 = `panelBackground` = 网格默认背景色，所以内缩出来的 6pt 边和网格是**同色连续**的，看不出接缝；而圆角只需要 4.1pt 就不会切到内接矩形，6pt 有余量。

`clipShape` 仍然留在 `CardSurface` 上作为兜底（防止彩色单元格的背景在极端字号下溢出），但正确性不依赖它对 `NSViewRepresentable` 生效。

## 行圆角

`RowFill` 现在硬编码 `RoundedRectangle(cornerRadius: 6)`。改为 `ConcentricRectangle()`，由系统从 `containerShape` 的 14pt 和行的实际内缩推导。这是这次改造里 macOS 26 API 落到实处的一处，也让以后调卡片圆角不必再手算行圆角。

## 文件改动

| 文件 | 改动 |
| --- | --- |
| `project.yml` | `deploymentTarget.macOS` → `"26.0"` |
| `Sources/HerdaKit/Theme/ChromeMetrics.swift` | 新增 |
| `Sources/HerdaKit/Theme/CardSurface.swift` | 新增 |
| `Sources/HerdaKit/Theme/ChromeSurfaces.swift` | 加 `windowBackground` |
| `Sources/Herda/ContentView.swift` | 窗口底色 + inset；两张卡片；删掉中间的 hairline `Rectangle`；`titlebarStrip` 常量并入 `ChromeMetrics.cardTopInset` |
| `Sources/Herda/SidebarView.swift` | 删自身 `.background`；删 `trafficLightClearance`；`RowFill` 改 `ConcentricRectangle` |
| `Tests/HerdaKitTests/` | 新增 `windowBackground` 色差测试 |

`SidebarView` 内部的两条 hairline **都保留**：双区之间的 `divider`（它同时是拖动把手）和 footer 上方的分隔线。规则是「卡片之间用间距，卡片内部用线」——它们是一张卡片内部的分区，不是两个面之间的分隔。这次删掉的 hairline 只有一条：`ContentView` 里侧栏与终端之间那条。

`xcodegen generate` 必须重跑（新增两个文件），随后 `Scripts/test.sh`。

## 测试

只加一个纯逻辑测试：遍历 `ThemeCatalog.all` 全部 18 个主题，断言每个主题下

- `windowBackground` 与 `panelBackground` 之间、与 `sidebarBackground` 之间存在可辨色差；
- 若某主题的色差不足（`panelBackground` 接近纯黑的退化情况），则 `hairline` 与两个卡片底色之间的色差达标——即描边接管了托起卡片的职责。

**判据用 `ThemeColor.luminance` 之差 ≥ 3**（该值已有，Rec. 601，0–255 尺度）。3 是这个尺度上肉眼可辨的下界；取更严的阈值会让本来就低对比的深色主题误报。测试断言的是「两条路径至少有一条达标」，不是两条都达标。

防的是「某个主题下卡片彻底看不见」。这是可以在没有窗口的情况下断言的，符合既有测试的取向。

圆角是否真的裁到位、阴影是否过重，跑一次 app 看比写离屏断言快，不写。

## 需要实测的量

**titlebar strip 高度与红绿灯 frame 在 macOS 26 上是否仍是 28pt / 12pt 直径。** `cardTopInset = 28` 沿用的是改造前代码里的值，那个值的来源是 macOS 15 及更早的标准 titlebar。实现时读 `window.standardWindowButton(.closeButton)?.frame` 与 `window.contentLayoutRect` 实测确认，不照抄。这是 CLAUDE.md 那条「cell metrics 来自字体自己的表，绝不硬编码」的同类问题——一个硬编码的 `8x16` 曾经错了一年。

## 已核实的 API

实现时不必重查（macOS 26.5 SDK，`SwiftUICore.framework` 的 `arm64e-apple-macos.swiftinterface`）：

| API | 位置 | 可用性 |
| --- | --- | --- |
| `ConcentricRectangle` | 13235 | `macOS 26.0+` |
| `ConcentricRectangle(corners:isUniform:)` | 13237 | 同上 |
| `Edge.Corner.Style.concentric` | 19199 | 同上 |
| `containerShape(_: some RoundedRectangularShape)` | 13382 | 同上 |
| `RoundedRectangle: RoundedRectangularShape` | 13322 | 同上 |
| `glassEffect(_:in:)` | 2529 | 可用，本次不用 |

## 代价

终端网格的可用面积两个方向都缩小。设窗口内容区为 `W × H`，侧栏固定 224pt：

```
宽  改造前  W − 224 − 1(hairline) − 14 − 8          = W − 247
    改造后  W − 12 − 224 − 10 − 12 − 6 − 6          = W − 270   少 23pt
高  改造前  H − 28(titlebarStrip) − 8               = H − 36
    改造后  H − 28 − 6 − 12 − 6                     = H − 52    少 16pt
```

13pt 字号下 cell 约 8×17pt，即约少 3 列、1 行。高度这 16pt 不能靠减小 `cardTopInset` 找回——那条 28pt 是硬约束二。要找回只能减 `cardInset` 或 `gridInset`，两者都会削弱刚建立的层次，本次不做。

## 收尾

`docs/design.md` 是设计的记录，其中描述窗口 chrome 的部分会被这次改造取代。实现完成后同步该节。CLAUDE.md 记录的另两处已知过时（`sidebar_start_collapsed`、§11 的 per-cell 绘制性能结论）本次不涉及，不动。
