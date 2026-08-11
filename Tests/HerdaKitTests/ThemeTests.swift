import XCTest
@testable import HerdaKit

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

    // MARK: Per-theme terminal palette derived from chrome tokens

    func testDerivedPaletteUsesChromeBackgroundAndText() {
        let chrome = ThemeCatalog.catppuccin.chrome
        let palette = TerminalPalette.derived(from: chrome)
        XCTAssertEqual(palette.defaultBackground, chrome.panelBackground)
        XCTAssertEqual(palette.defaultForeground, chrome.text)
    }

    func testDerivedPaletteMapsVividAnsiColorsToChromeTokens() {
        let chrome = ThemeCatalog.dracula.chrome
        let palette = TerminalPalette.derived(from: chrome)
        XCTAssertEqual(palette.ansi[1], chrome.red)    // ANSI red
        XCTAssertEqual(palette.ansi[2], chrome.green)  // ANSI green
        XCTAssertEqual(palette.ansi[3], chrome.yellow) // ANSI yellow
        XCTAssertEqual(palette.ansi[4], chrome.blue)   // ANSI blue
        XCTAssertEqual(palette.ansi[5], chrome.mauve)  // ANSI magenta
        XCTAssertEqual(palette.ansi[6], chrome.teal)   // ANSI cyan
    }

    func testDerivedPaletteNeutralsFollowChrome() {
        let chrome = ThemeCatalog.catppuccin.chrome
        let palette = TerminalPalette.derived(from: chrome)
        XCTAssertEqual(palette.ansi[7], chrome.subtext0) // white
        XCTAssertEqual(palette.ansi[8], chrome.overlay0) // bright black
    }

    func testDerivedBlackAndWhiteFollowLuminanceForDarkTheme() {
        // catppuccin is dark: background darker than text, so ANSI black is the
        // background and bright white is the text.
        let chrome = ThemeCatalog.catppuccin.chrome
        let palette = TerminalPalette.derived(from: chrome)
        XCTAssertEqual(palette.ansi[0], chrome.panelBackground)
        XCTAssertEqual(palette.ansi[15], chrome.text)
    }

    func testDerivedBlackAndWhiteFlipForLightTheme() {
        // catppuccin-latte is light: text darker than background, so ANSI black
        // is the text and bright white is the background — keeps content legible.
        let chrome = ThemeCatalog.catppuccinLatte.chrome
        let palette = TerminalPalette.derived(from: chrome)
        XCTAssertEqual(palette.ansi[0], chrome.text)
        XCTAssertEqual(palette.ansi[15], chrome.panelBackground)
    }

    func testThemeExposesItsDerivedTerminalPalette() {
        XCTAssertEqual(
            ThemeCatalog.dracula.terminal.defaultBackground,
            ThemeCatalog.dracula.chrome.panelBackground
        )
    }

    // MARK: unpack resolves named/indexed against a supplied palette

    func testUnpackResolvesNamedColorAgainstSuppliedPalette() {
        let palette = ThemeCatalog.dracula.terminal
        // Named Red is wire index 2 -> ansi[1].
        XCTAssertEqual(TerminalColor.unpack(0x00_00_00_02, palette: palette), .rgb(palette.ansi[1].red, palette.ansi[1].green, palette.ansi[1].blue))
    }

    func testUnpackDefaultsToGhosttyPalette() {
        // Without a palette argument the ghostty defaults are used, unchanged.
        XCTAssertEqual(TerminalColor.unpack(0x00_00_00_02), .rgb(0xCC, 0x66, 0x66))
    }
}
