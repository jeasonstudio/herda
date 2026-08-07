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

    func testConfigContentsHidesSidebarAndBindsToggle() {
        let toml = paths.configContents
        XCTAssertTrue(toml.contains("sidebar_collapsed_mode = \"hidden\""))
        XCTAssertTrue(toml.contains("toggle_sidebar = \"ctrl+alt+f20\""))
        XCTAssertTrue(toml.contains("[ui]"))
        XCTAssertTrue(toml.contains("[keys]"))
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
