import Foundation

extension ThemeColor {
    /// Blends toward `other`: 0 returns self, 1 returns `other`.
    func mixed(with other: ThemeColor, _ fraction: Double) -> ThemeColor {
        let ratio = min(max(fraction, 0), 1)
        func blend(_ from: UInt8, _ to: UInt8) -> UInt8 {
            let value = Double(from) + (Double(to) - Double(from)) * ratio
            return UInt8(min(max(value.rounded(), 0), 255))
        }
        return ThemeColor(
            blend(red, other.red),
            blend(green, other.green),
            blend(blue, other.blue)
        )
    }
}

/// Chrome surfaces the native window needs but herdr's own `Palette` does not
/// define, derived from each theme's tokens so all 18 get them for free.
///
/// herdr draws its whole UI as character cells on one background, so it never
/// needed a second surface. A native window does: the roster and the terminal
/// are separate planes and have to read as such. Deriving them beats
/// hand-authoring 18 more values, and lands close to what the theme authors
/// picked anyway — for both Catppuccin variants the derived sidebar is within a
/// few points of their own `surfaceDim` — while still separating the planes for
/// the themes that set `surfaceDim` equal to `panelBackground`.
extension ChromePalette {
    /// The roster's plane, lifted off `panelBackground` toward the text color so
    /// it separates from the terminal in light and dark themes alike.
    public var sidebarBackground: ThemeColor { panelBackground.mixed(with: text, 0.06) }

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

    /// 画在 `surface` 上的分隔线 / 描边。
    ///
    /// **必须相对它所在的那个面派生,不能一律用 `panelBackground` 的那条。**
    /// `windowBackground` 也是从 `panelBackground` 派生、往同一方向(黑)走的,
    /// 于是两条线会收敛:实测把 sidebar 的底色换成 `windowBackground` 之后,
    /// catppuccin-latte / tokyo-night-day / kanagawa-lotus 三个亮色主题的
    /// `hairline` 与它明度差只剩 1–2,分区线直接消失,另外 4 个亮色主题差
    /// 3–6,勉强可见。改成相对所在面派生后,18 个主题的最小差是 17。
    ///
    /// 同一个坑也影响过卡片描边:它压在卡片与窗口底的交界上,用
    /// `panelBackground` 派生的那条线时,亮色主题下卡片边界一直与窗口底同色。
    public func hairline(on surface: ThemeColor) -> ThemeColor {
        surface.mixed(with: text, 0.16)
    }

    /// 画在 `panelBackground` 上的分隔线 —— 终端平面自己的那条。
    /// 别的面上请用 `hairline(on:)`。
    public var hairline: ThemeColor { hairline(on: panelBackground) }

    /// The color that stands for an agent state. Follows herdr's own semantics
    /// for these tokens (the `Palette` doc comments in src/app/state.rs): yellow
    /// is running, red needs a person, green has finished.
    public func color(for status: AgentStatus) -> ThemeColor {
        switch status {
        case .working: return yellow
        case .blocked: return red
        case .done: return green
        case .idle, .unknown: return overlay0
        }
    }
}

extension Theme {
    /// Whether this theme wants dark system chrome.
    ///
    /// The window is painted from the theme, not from the system appearance, so
    /// the two can disagree: a dark theme under a light system leaves every
    /// system-drawn control — menu text, scrollers, spinners, focus rings —
    /// dark-on-dark. The app matches `NSAppearance` to this instead.
    public var isDark: Bool {
        chrome.panelBackground.luminance < chrome.text.luminance
    }
}
