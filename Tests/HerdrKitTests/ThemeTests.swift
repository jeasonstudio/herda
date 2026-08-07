import XCTest
@testable import HerdrKit

final class ThemeTests: XCTestCase {
    // MARK: Theme.name(fromConfig:) — pure TOML line-scan

    func testNameExtractsQuotedValueFromThemeSection() {
        let toml = """
        onboarding = false

        [ui]
        sidebar_start_collapsed = true

        [theme]
        name = "dracula"
        """
        XCTAssertEqual(Theme.name(fromConfig: toml), "dracula")
    }

    func testNameReturnsNilWhenThemeSectionAbsent() {
        let toml = "onboarding = false\n\n[ui]\nsidebar_start_collapsed = true"
        XCTAssertNil(Theme.name(fromConfig: toml))
    }

    func testNameIgnoresNameKeyOutsideThemeSection() {
        let toml = "[ui]\nname = \"not-a-theme\"\n\n[theme]\nname = \"nord\""
        XCTAssertEqual(Theme.name(fromConfig: toml), "nord")
    }

    func testNameStopsAtNextSectionHeader() {
        let toml = "[theme]\n\n[ui]\nname = \"wrong-section\""
        XCTAssertNil(Theme.name(fromConfig: toml))
    }

    func testNameReturnsNilWhenValueIsEmpty() {
        XCTAssertNil(Theme.name(fromConfig: "[theme]\nname = \"\""))
    }

    // MARK: ThemeCatalog.resolve(name:) — mirrors Palette::from_name aliases

    func testResolveMatchesCanonicalNames() {
        XCTAssertEqual(ThemeCatalog.resolve(name: "catppuccin"), ThemeCatalog.catppuccin)
        XCTAssertEqual(ThemeCatalog.resolve(name: "dracula"), ThemeCatalog.dracula)
        XCTAssertEqual(ThemeCatalog.resolve(name: "vesper"), ThemeCatalog.vesper)
    }

    func testResolveMatchesAliases() {
        XCTAssertEqual(ThemeCatalog.resolve(name: "catppuccin-mocha"), ThemeCatalog.catppuccin)
        XCTAssertEqual(ThemeCatalog.resolve(name: "latte"), ThemeCatalog.catppuccinLatte)
        XCTAssertEqual(ThemeCatalog.resolve(name: "tokyonight"), ThemeCatalog.tokyoNight)
        XCTAssertEqual(ThemeCatalog.resolve(name: "dawn"), ThemeCatalog.rosePineDawn)
        XCTAssertEqual(ThemeCatalog.resolve(name: "lotus"), ThemeCatalog.kanagawaLotus)
        XCTAssertEqual(ThemeCatalog.resolve(name: "onedark"), ThemeCatalog.oneDark)
    }

    func testResolveNormalizesCaseSpacesAndUnderscores() {
        XCTAssertEqual(ThemeCatalog.resolve(name: "Tokyo Night"), ThemeCatalog.tokyoNight)
        XCTAssertEqual(ThemeCatalog.resolve(name: "ONE_DARK"), ThemeCatalog.oneDark)
    }

    func testResolveReturnsNilForUnknownName() {
        XCTAssertNil(ThemeCatalog.resolve(name: "not-a-real-theme"))
    }

    func testCatalogContainsAllEighteenThemes() {
        XCTAssertEqual(ThemeCatalog.all.count, 18)
    }

    func testDefaultThemeIsCatppuccin() {
        XCTAssertEqual(ThemeCatalog.default, ThemeCatalog.catppuccin)
    }

    // MARK: Spot-check ported token values against src/app/state.rs

    func testCatppuccinAccentMatchesSource() {
        // src/app/state.rs:148
        XCTAssertEqual(ThemeCatalog.catppuccin.chrome.accent, ThemeColor(137, 180, 250))
    }

    func testDraculaAccentMatchesSource() {
        // src/app/state.rs:263
        XCTAssertEqual(ThemeCatalog.dracula.chrome.accent, ThemeColor(189, 147, 249))
    }

    func testNordBlueMatchesSource() {
        // src/app/state.rs:300
        XCTAssertEqual(ThemeCatalog.nord.chrome.blue, ThemeColor(129, 161, 193))
    }

    func testVesperTextIsPureWhite() {
        // src/app/state.rs:547
        XCTAssertEqual(ThemeCatalog.vesper.chrome.text, ThemeColor(255, 255, 255))
    }

    // MARK: `terminal` theme — resolved from named ANSI colors + Color::Reset

    func testTerminalThemeResolvesResetToGhosttyDefaults() {
        // src/app/state.rs:192-211: panel_bg/surface0 are Color::Reset (background),
        // text is Color::Reset (foreground).
        XCTAssertEqual(ThemeCatalog.terminal.chrome.panelBackground, TerminalPalette.ghostty.defaultBackground)
        XCTAssertEqual(ThemeCatalog.terminal.chrome.surface0, TerminalPalette.ghostty.defaultBackground)
        XCTAssertEqual(ThemeCatalog.terminal.chrome.text, TerminalPalette.ghostty.defaultForeground)
    }

    func testTerminalThemeResolvesNamedAnsiColors() {
        // accent/blue: Color::Blue -> ANSI 4; green: Color::Green -> ANSI 2.
        XCTAssertEqual(ThemeCatalog.terminal.chrome.accent, TerminalPalette.ghostty.ansi[4])
        XCTAssertEqual(ThemeCatalog.terminal.chrome.green, TerminalPalette.ghostty.ansi[2])
    }
}
