import XCTest
@testable import HerdaKit

final class ChromeSurfacesTests: XCTestCase {
    func testMixReturnsTheEndpointsUnchanged() {
        let black = ThemeColor(0, 0, 0)
        let white = ThemeColor(255, 255, 255)
        XCTAssertEqual(black.mixed(with: white, 0), black)
        XCTAssertEqual(black.mixed(with: white, 1), white)
    }

    func testMixIsProportional() {
        let mixed = ThemeColor(0, 0, 0).mixed(with: ThemeColor(200, 100, 50), 0.5)
        XCTAssertEqual(mixed, ThemeColor(100, 50, 25))
    }

    func testMixClampsFractionsOutsideTheRange() {
        let black = ThemeColor(0, 0, 0)
        let white = ThemeColor(255, 255, 255)
        XCTAssertEqual(black.mixed(with: white, -1), black)
        XCTAssertEqual(black.mixed(with: white, 4), white)
    }

    /// The point of deriving these: the roster and the terminal must be separate
    /// planes in every theme, including the ones whose `surfaceDim` equals
    /// `panelBackground` and so could not have provided the separation.
    func testEveryThemeSeparatesTheSidebarFromTheTerminal() {
        for theme in ThemeCatalog.all {
            XCTAssertNotEqual(
                theme.chrome.sidebarBackground,
                theme.chrome.panelBackground,
                "\(theme.configName) sidebar is indistinguishable from its terminal"
            )
        }
    }

    func testEveryThemeHairlineIsVisibleAgainstBothPlanes() {
        for theme in ThemeCatalog.all {
            XCTAssertNotEqual(theme.chrome.hairline, theme.chrome.panelBackground, theme.configName)
            XCTAssertNotEqual(theme.chrome.hairline, theme.chrome.sidebarBackground, theme.configName)
        }
    }

    /// A light theme's sidebar has to darken and a dark theme's has to lighten;
    /// both directions are "toward the text color".
    func testSidebarMovesTowardTextInEitherDirection() {
        XCTAssertLessThan(
            ThemeCatalog.catppuccinLatte.chrome.sidebarBackground.luminance,
            ThemeCatalog.catppuccinLatte.chrome.panelBackground.luminance
        )
        XCTAssertGreaterThan(
            ThemeCatalog.catppuccin.chrome.sidebarBackground.luminance,
            ThemeCatalog.catppuccin.chrome.panelBackground.luminance
        )
    }

    // MARK: windowBackground

    /// 明度差的可辨下界。Rec. 601 的 0–255 尺度上,3 是肉眼能分出来的
    /// 最小差;取更严会让本就低对比的深色主题误报。
    private func separated(_ a: ThemeColor, _ b: ThemeColor) -> Bool {
        abs(a.luminance - b.luminance) >= 3
    }

    /// 终端卡片要能从窗口底上分出来。分离可以来自面色差,也可以来自描边
    /// —— `terminal` 主题的 `panelBackground` 是纯黑,往黑走不动,只有描边
    /// 这一条路。所以断言的是两条至少成立一条。
    func testEveryThemeFloatsTheTerminalCardOffTheWindow() {
        for theme in ThemeCatalog.all {
            let chrome = theme.chrome
            let byColor = separated(chrome.windowBackground, chrome.panelBackground)
            let byBorder = separated(
                chrome.hairline(on: chrome.windowBackground),
                chrome.windowBackground
            )
            XCTAssertTrue(
                byColor || byBorder,
                "\(theme.configName): 卡片既无面色差也无描边可辨,会看不见"
            )
        }
    }

    /// 分隔线必须相对**它所在的那个表面**派生。`hairline` 是从
    /// `panelBackground` 来的,画在别的表面上会撞色:`windowBackground` 也从
    /// `panelBackground` 派生、往同一方向走,两者收敛。实测 sidebar 的背景
    /// 改成 `windowBackground` 之后,catppuccin-latte / tokyo-night-day /
    /// kanagawa-lotus 三个亮色主题的 `hairline` 与它明度差只有 1–2,sidebar
    /// 内部的分区线直接消失;另外 4 个亮色主题差 3–6,勉强可见。
    ///
    /// 这不只影响 sidebar:终端卡片的描边原先也用 `hairline`,所以亮色主题下
    /// 卡片边界一直在与窗口底同色。
    func testHairlineIsVisibleOnWhicheverSurfaceItIsDrawnOn() {
        for theme in ThemeCatalog.all {
            let chrome = theme.chrome
            for (name, surface) in [
                ("panelBackground", chrome.panelBackground),
                ("windowBackground", chrome.windowBackground),
                ("sidebarBackground", chrome.sidebarBackground),
            ] {
                XCTAssertTrue(
                    separated(chrome.hairline(on: surface), surface),
                    "\(theme.configName): 分隔线在 \(name) 上看不见"
                )
            }
        }
    }

    /// 卡片描边同时压在两个面的交界上,得跟两边都拉开:与卡片自己的填充
    /// (`panelBackground`),也与它浮在上面的窗口底。
    func testCardBorderIsVisibleAgainstBothTheCardAndTheWindow() {
        for theme in ThemeCatalog.all {
            let chrome = theme.chrome
            let border = chrome.hairline(on: chrome.windowBackground)
            XCTAssertTrue(
                separated(border, chrome.panelBackground),
                "\(theme.configName): 描边与卡片填充同色"
            )
            XCTAssertTrue(
                separated(border, chrome.windowBackground),
                "\(theme.configName): 描边与窗口底同色"
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
        let border = chrome.hairline(on: chrome.windowBackground)
        XCTAssertEqual(chrome.windowBackground, chrome.panelBackground)
        XCTAssertTrue(separated(border, chrome.panelBackground))
        XCTAssertTrue(separated(border, chrome.windowBackground))
    }

    func testStatusColorsFollowHerdrSemantics() {
        let chrome = ThemeCatalog.catppuccin.chrome
        XCTAssertEqual(chrome.color(for: .working), chrome.yellow)
        XCTAssertEqual(chrome.color(for: .blocked), chrome.red)
        XCTAssertEqual(chrome.color(for: .done), chrome.green)
        XCTAssertEqual(chrome.color(for: .idle), chrome.overlay0)
        XCTAssertEqual(chrome.color(for: .unknown), chrome.overlay0)
    }
}
