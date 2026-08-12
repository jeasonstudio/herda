import CoreGraphics

/// 窗口 chrome 的几何。集中在这里而不是散在 view 里:其中几个值互相约束
/// (网格内缩的下限由卡片圆角决定,内容顶线的下限由 titlebar 拖动带决定),
/// 分开写会各自漂移。
///
/// **除阴影外全部落在 8pt 网格上**,这是 HIG 对间距的要求(「consistent
/// spacing on 8pt grid」)。上一版的 12 / 10 / 14 / 6 / 34 没有一个在网格上,
/// 间距读不出节奏。阴影是视觉效果而非布局,不受这条约束。
public enum ChromeMetrics {
    /// 终端卡片到窗口右/下边。sidebar 不参与 —— 它与窗口底同层同色,直接
    /// 贴到窗口左边缘。
    ///
    /// 16 = 8×2,落在 HIG 说的 margin 区间(16–20)内且仍在 8pt 网格上;20 本身
    /// 不是 8 的倍数。
    public static let cardInset: CGFloat = 16

    /// 内容顶线:终端卡片的顶边,同时也是 sidebar 第一行内容的起始线。
    ///
    /// 这两处的约束其实不同,取更严的那个再对齐网格。macOS 26.3 实测:
    ///
    /// - **终端卡片顶边**受拖动带约束,带占 **32pt**(`contentView.bounds
    ///   .height` 减 `contentLayoutRect.height`)。这是硬的:带内的点击归窗口
    ///   拖动,不归终端。
    /// - **sidebar 内容顶线**只受红绿灯约束,23pt 就够(close 按钮在内容坐标
    ///   里是 (9, 577, 14, 14),内容高 600)。sidebar 顶部那片空白被拖动手势
    ///   覆盖是无害的 —— 拖那里移动窗口很自然。
    ///
    /// 两处用同一个值是视觉选择:sidebar 的第一行与卡片顶边落在同一水平线。
    ///
    /// 40 = 8×5,比 32 下限多 8pt 余量。取 32 会正好压在下限上,Retina 的半
    /// 像素舍入就没有退路了。改造前这里写的是 28,来自 macOS 15 及更早的
    /// titlebar 高度 —— 在 macOS 26 上它比拖动带矮 4pt,也就是终端顶部 4pt 的
    /// 点击一直在被吞成拖窗口。另注:红绿灯是 14×14,不是旧系统的 12×12。
    public static let contentTopInset: CGFloat = 40

    /// sidebar 右边缘到终端卡片左边缘。取代改造前那条 1pt hairline —— 卡片
    /// 有自己的描边,平面之间用间距分隔而不是画线。
    public static let cardGap: CGFloat = 8

    /// 终端卡片圆角。
    public static let cardRadius: CGFloat = 12

    /// 阴影。不在 8pt 网格上:它是视觉效果,不是布局。不透明度也不在这里 ——
    /// 它取决于主题明暗,由 `CardSurface` 从 `Theme.isDark` 取。
    public static let cardShadowRadius: CGFloat = 12
    public static let cardShadowY: CGFloat = 2

    /// 终端网格到卡片边缘。下限由圆角决定:圆角矩形的内接矩形在
    /// r(1 - 1/√2) ≈ 0.293r 处脱离圆角,r = 12 时为 3.5pt。取 8pt(网格最小
    /// 一格)留出充足余量 —— 网格的任何单元格都不会被圆角切到,这是不必对
    /// `TerminalGridView` 做 layer 裁剪的前提(那会在渲染最热的路径上多一层
    /// mask 合成)。
    public static let gridInset: CGFloat = 8

    /// sidebar 行到 sidebar 边缘。
    public static let rowInset: CGFloat = 8

    /// sidebar 行的圆角。
    ///
    /// 独立取值,不再从 `cardRadius` 减 `rowInset` 推导:sidebar 已经不是卡片,
    /// 行不在任何圆角容器里,「与容器同心」没有了前提。6 也是 HIG 里 hover
    /// 行示例用的值。
    ///
    /// 顺带记下为什么不是 `ConcentricRectangle` —— 即便当初 sidebar 还是卡片
    /// 时它也不成立:实测(`ImageRenderer` 离屏,200×200 容器 / 圆角 14 / 行内缩
    /// 8 / 行落在容器垂直中部)它对垂直方向不贴容器边的元素算出 **0** 圆角,
    /// 渲染结果与 `Rectangle()` 逐像素相同,每一行都会变直角。
    public static let rowRadius: CGFloat = 6
}
