import SwiftUI

/// 一张浮起的卡片:底色、圆角、一道描边、一层阴影。
///
/// 描边不是装饰。`terminal` 主题的 `panelBackground` 是纯黑,`windowBackground`
/// 由它往黑走得到、因此与它完全同色 —— 那个主题下把终端卡片托起来的只有描边
/// 和阴影。
///
/// **`over` 是这张卡片浮在哪个面上,描边相对它派生,不能一律用 `hairline`**
/// (后者相对 `panelBackground` 派生)。描边压在卡片与底面的交界上,要跟两边都
/// 拉开;而 `windowBackground` 也是从 `panelBackground` 往黑走来的,两条线会
/// 收敛 —— 实测亮色主题下差只有 0–6(`kanagawa-lotus` 为 0),终端卡片的边界
/// 会与窗口底同色。反过来,浮在终端卡片上的那张提示卡片,底面是
/// `panelBackground`,描边就该相对它派生。
///
/// 不设 `containerShape`:没有消费者(sidebar 行独立取圆角,见
/// `ChromeMetrics.rowRadius`),留着只是死代码。
public struct CardSurface: ViewModifier {
    let fill: ThemeColor
    /// 这张卡片浮在哪个面上。
    let over: ThemeColor
    let theme: Theme

    public init(fill: ThemeColor, over: ThemeColor, theme: Theme) {
        self.fill = fill
        self.over = over
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
            .overlay(shape.strokeBorder(theme.chrome.hairline(on: over).color, lineWidth: 1))
            // 暗色主题的底本身就暗,0.12 的阴影在上面看不出来。
            .shadow(
                color: .black.opacity(theme.isDark ? 0.45 : 0.12),
                radius: ChromeMetrics.cardShadowRadius,
                y: ChromeMetrics.cardShadowY
            )
    }
}

extension View {
    /// 把这个视图变成一张浮在 `over` 上的卡片。
    public func cardSurface(
        fill: ThemeColor,
        over: ThemeColor,
        theme: Theme
    ) -> some View {
        modifier(CardSurface(fill: fill, over: over, theme: theme))
    }
}
