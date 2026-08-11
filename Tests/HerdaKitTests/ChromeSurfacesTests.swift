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

    func testStatusColorsFollowHerdrSemantics() {
        let chrome = ThemeCatalog.catppuccin.chrome
        XCTAssertEqual(chrome.color(for: .working), chrome.yellow)
        XCTAssertEqual(chrome.color(for: .blocked), chrome.red)
        XCTAssertEqual(chrome.color(for: .done), chrome.green)
        XCTAssertEqual(chrome.color(for: .idle), chrome.overlay0)
        XCTAssertEqual(chrome.color(for: .unknown), chrome.overlay0)
    }
}
