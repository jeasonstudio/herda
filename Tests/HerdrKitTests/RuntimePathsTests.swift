import XCTest
@testable import HerdrKit

final class RuntimePathsTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/herdr-proto-test", isDirectory: true)

    private var paths: RuntimePaths {
        RuntimePaths(root: root)
    }

    func testDerivesSocketPaths() {
        XCTAssertEqual(paths.apiSocket.path, "/tmp/herdr-proto-test/herdr.sock")
        XCTAssertEqual(paths.clientSocket.path, "/tmp/herdr-proto-test/herdr-client.sock")
    }

    func testConfigFileLivesUnderHerdrSubdirectoryOfConfigHome() {
        // config_dir() appends "herdr" to XDG_CONFIG_HOME.
        XCTAssertEqual(paths.configHome.path, "/tmp/herdr-proto-test/config")
        XCTAssertEqual(paths.configFile.path, "/tmp/herdr-proto-test/config/herdr/config.toml")
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
        XCTAssertNil(RuntimePaths(root: URL(fileURLWithPath: "/tmp/herdr-proto-absent", isDirectory: true)).existingThemeName())
    }

    func testExistingThemeNameReadsPersistedValue() throws {
        let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("herdr-proto-theme-\(UUID().uuidString)", isDirectory: true)
        let subject = RuntimePaths(root: temporaryRoot)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try subject.writeConfig(themeName: "nord")
        XCTAssertEqual(subject.existingThemeName(), "nord")
    }

    func testEnvironmentSetsIsolationVariables() {
        let env = paths.environment(basedOn: [:])
        XCTAssertEqual(env["HERDR_SOCKET_PATH"], "/tmp/herdr-proto-test/herdr.sock")
        XCTAssertEqual(env["XDG_CONFIG_HOME"], "/tmp/herdr-proto-test/config")
        XCTAssertEqual(env["XDG_STATE_HOME"], "/tmp/herdr-proto-test/state")
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

        XCTAssertEqual(env["HERDR_SOCKET_PATH"], "/tmp/herdr-proto-test/herdr.sock")
        XCTAssertNil(env["HERDR_CLIENT_SOCKET_PATH"])
        XCTAssertNil(env["HERDR_SESSION"])
        XCTAssertNil(env["HERDR_PANE_ID"])
        XCTAssertNil(env["HERDR_ENV"])
        XCTAssertEqual(env["PATH"], "/usr/bin", "unrelated variables must survive")
    }
}
