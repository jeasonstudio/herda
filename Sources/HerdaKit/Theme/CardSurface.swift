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
