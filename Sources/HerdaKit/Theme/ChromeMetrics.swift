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
    ///
    /// 28 是净空 + 余量,不是抄来的 titlebar 高度。macOS 26.3 实测
    /// (`ChromeMetricsTests.testCardTopInsetClearsTheTrafficLights`):
    /// close 按钮在内容坐标里是 (9, 577, 14, 14),内容高 600,即按钮底边
    /// 距内容顶边 23pt —— 28 留 5pt 余量。注意按钮是 14×14,不是旧系统的
    /// 12×12,所以照抄旧的 titlebar 常量会贴得比看起来更紧。
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

    /// 侧栏行到侧栏卡片边缘。
    public static let rowInset: CGFloat = 8

    /// 行圆角,与卡片圆角同心 —— 即卡片圆角减去行的内缩。
    ///
    /// 不用 `ConcentricRectangle`,尽管它看起来正是为此存在的。实测
    /// (`ImageRenderer` 离屏,200×200 容器 / 圆角 14 / 行内缩 8 / 行落在
    /// 容器垂直中部):它对垂直方向不贴容器边的元素算出 **0** 圆角,渲染
    /// 结果与 `Rectangle()` 逐像素相同,侧栏每一行都会变直角。
    /// `.concentric(minimum: .fixed(6))` 能救回来,但那时 concentric 部分
    /// 永远算 0、minimum 永远接管,等于用一个在此场景失效的机制包装一个
    /// 固定值,而且不会随 `cardRadius` 变化 —— 采用它的唯一理由正好落空。
    /// 减法反而真的跟随。
    public static let rowRadius: CGFloat = cardRadius - rowInset
}
