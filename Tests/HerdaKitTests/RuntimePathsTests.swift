import XCTest
@testable import HerdaKit

final class RuntimePathsTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/herda-test", isDirectory: true)

    private var paths: RuntimePaths {
        RuntimePaths(root: root)
    }

    func testDerivesSocketPaths() {
        XCTAssertEqual(paths.apiSocket.path, "/tmp/herda-test/herdr.sock")
        XCTAssertEqual(paths.clientSocket.path, "/tmp/herda-test/herdr-client.sock")
    }

    func testConfigFileLivesUnderHerdrSubdirectoryOfConfigHome() {
        // config_dir() appends "herdr" to XDG_CONFIG_HOME.
        XCTAssertEqual(paths.configHome.path, "/tmp/herda-test/config")
        XCTAssertEqual(paths.configFile.path, "/tmp/herda-test/config/herdr/config.toml")
    }

    func testConfigContentsHidesSidebarFromTheFirstFrame() {
        // Starting collapsed (not a runtime toggle) is what keeps herdr's own
        // sidebar hidden even after workspace operations re-expand it server-side.
        let toml = paths.configContents(themeName: "catppuccin")
        XCTAssertTrue(toml.contains("sidebar_start_collapsed = true"))
        XCTAssertTrue(toml.contains("sidebar_collapsed_mode = \"hidden\""))
        XCTAssertTrue(toml.contains("[ui]"))
    }

    func testConfigContentsHidesTheTabRowForSingleTabWorkspaces() {
        // The native sidebar lists the same workspaces herdr's tab row did.
        XCTAssertTrue(
            paths.configContents(themeName: "catppuccin")
                .contains("hide_tab_bar_when_single_tab = true")
        )
    }

    func testConfigContentsTurnsOffHerdrsPaneChrome() {
        // Three keys, three different consequences if one is missed:
        // pane_borders + pane_scrollbars are what make pane.layout's rect equal
        // the rendered area, and pane_gaps is what leaves the one cell between
        // panes that the native card gap occupies.
        let toml = paths.configContents(themeName: "catppuccin")
        XCTAssertTrue(toml.contains("pane_borders = false"))
        XCTAssertTrue(toml.contains("pane_scrollbars = false"))
        XCTAssertTrue(toml.contains("pane_gaps = true"))
    }

    func testPaneChromeKeysLiveInTheUiSection() throws {
        // They belong to herdr's UiConfig. Placed after [theme] they would be
        // parsed as theme keys and silently ignored — the same trap as
        // onboarding, which the test above this one guards.
        let toml = paths.configContents(themeName: "catppuccin")
        let uiIndex = try XCTUnwrap(toml.range(of: "[ui]")).lowerBound
        let themeIndex = try XCTUnwrap(toml.range(of: "[theme]")).lowerBound
        let bordersIndex = try XCTUnwrap(toml.range(of: "pane_borders = false")).lowerBound
        XCTAssertLessThan(uiIndex, bordersIndex)
        XCTAssertLessThan(bordersIndex, themeIndex)
    }

    func testConfigContentsSuppressesHerdrsOwnModals() {
        // These three appear without a keypress, and a modal is drawn on the whole
        // grid, so once the grid is sliced by pane rect it gets cut by the card
        // gap. The ones a prefix key opens are deliberately left alone: those are
        // user-initiated, and replacing them natively is a later stage.
        let toml = paths.configContents(themeName: "catppuccin")
        XCTAssertTrue(toml.contains("confirm_close = false"))
        XCTAssertTrue(toml.contains("prompt_new_tab_name = false"))
        XCTAssertTrue(toml.contains("prompt_new_workspace_name = false"))
    }

    func testConfigContentsDisablesOnboarding() {
        // Not cosmetic: Mode::Onboarding covers the terminal with a first-run
        // overlay, and it takes over input handling before anything else.
        XCTAssertTrue(paths.configContents(themeName: "catppuccin").contains("onboarding = false"))
    }

    func testOnboardingKeyPrecedesAnyTomlSection() throws {
        // A top-level TOML key placed after a [section] would be parsed as part
        // of that section and silently ignored.
        let toml = paths.configContents(themeName: "catppuccin")
        let onboardingIndex = try XCTUnwrap(toml.range(of: "onboarding = false")).lowerBound
        let firstSectionIndex = try XCTUnwrap(toml.range(of: "[ui]")).lowerBound
        XCTAssertLessThan(onboardingIndex, firstSectionIndex)
    }

    func testConfigContentsIncludesThemeName() {
        let toml = paths.configContents(themeName: "dracula")
        XCTAssertTrue(toml.contains("[theme]"))
        XCTAssertTrue(toml.contains("name = \"dracula\""))
    }

    func testExistingThemeNameReturnsNilWhenFileAbsent() {
        XCTAssertNil(RuntimePaths(root: URL(fileURLWithPath: "/tmp/herda-absent", isDirectory: true)).existingThemeName())
    }

    func testExistingThemeNameReadsPersistedValue() throws {
        let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("herda-theme-\(UUID().uuidString)", isDirectory: true)
        let subject = RuntimePaths(root: temporaryRoot)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try subject.writeConfig(themeName: "nord")
        XCTAssertEqual(subject.existingThemeName(), "nord")
    }

    func testEnvironmentSetsIsolationVariables() {
        let env = paths.environment(basedOn: [:])
        XCTAssertEqual(env["HERDR_SOCKET_PATH"], "/tmp/herda-test/herdr.sock")
        XCTAssertEqual(env["XDG_CONFIG_HOME"], "/tmp/herda-test/config")
        XCTAssertEqual(env["XDG_STATE_HOME"], "/tmp/herda-test/state")
    }

    func testEnvironmentDropsInheritedHerdrVariables() {
        // The app may be launched from inside a real herdr session (directly,
        // or via an Xcode that was). Inherited HERDR_* would point the child
        // at the developer's live server.
        let parent = [
            "HERDR_SOCKET_PATH": "/Users/dev/.config/herdr/herdr.sock",
            "HERDR_CLIENT_SOCKET_PATH": "/Users/dev/.config/herdr/herdr-client.sock",
            "HERDR_SESSION": "default",
            "HERDR_PANE_ID": "w8:p1",
            "HERDR_ENV": "1",
            "PATH": "/usr/bin",
        ]
        let env = paths.environment(basedOn: parent)

        XCTAssertEqual(env["HERDR_SOCKET_PATH"], "/tmp/herda-test/herdr.sock")
        XCTAssertNil(env["HERDR_CLIENT_SOCKET_PATH"])
        XCTAssertNil(env["HERDR_SESSION"])
        XCTAssertNil(env["HERDR_PANE_ID"])
        XCTAssertNil(env["HERDR_ENV"])
        XCTAssertEqual(env["PATH"], "/usr/bin", "unrelated variables must survive")
    }
}
