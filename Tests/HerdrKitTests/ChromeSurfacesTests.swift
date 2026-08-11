import XCTest
@testable import HerdrKit

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

    func testStatusColorsFollowHerdrSemantics() {
        let chrome = ThemeCatalog.catppuccin.chrome
        XCTAssertEqual(chrome.color(for: .working), chrome.yellow)
        XCTAssertEqual(chrome.color(for: .blocked), chrome.red)
        XCTAssertEqual(chrome.color(for: .done), chrome.green)
        XCTAssertEqual(chrome.color(for: .idle), chrome.overlay0)
        XCTAssertEqual(chrome.color(for: .unknown), chrome.overlay0)
    }
}
