import XCTest
@testable import HerdaKit

final class PathLabelTests: XCTestCase {
    private let home = "/Users/jo"

    func testHomeItselfBecomesTilde() {
        XCTAssertEqual(PathLabel.abbreviate(home, home: home), "~")
    }

    func testPathInsideHomeGetsATilde() {
        XCTAssertEqual(PathLabel.abbreviate("/Users/jo/herdr", home: home), "~/herdr")
    }

    func testDeepPathKeepsTheLastTwoComponents() {
        XCTAssertEqual(
            PathLabel.abbreviate("/Users/jo/Projects/github.com/herdrdev/herdr", home: home),
            "~/…/herdrdev/herdr"
        )
    }

    func testAbsolutePathOutsideHomeKeepsItsRoot() {
        XCTAssertEqual(
            PathLabel.abbreviate("/opt/homebrew/Cellar/zig/0.15.2", home: home),
            "/…/zig/0.15.2"
        )
    }

    /// Eliding has to earn its ellipsis: `/…/local/bin` is no easier to read
    /// than the path it replaces.
    func testShortPathIsLeftAlone() {
        XCTAssertEqual(PathLabel.abbreviate("/usr/local/bin", home: home), "/usr/local/bin")
    }

    func testTrailingSlashIsIgnored() {
        XCTAssertEqual(PathLabel.abbreviate("/Users/jo/herdr/", home: home), "~/herdr")
    }

    func testRootAndEmptyPathSurvive() {
        XCTAssertEqual(PathLabel.abbreviate("/", home: home), "/")
        XCTAssertEqual(PathLabel.abbreviate("", home: home), "")
    }

    /// A path that merely starts with the same characters as the home directory
    /// is a different directory.
    func testHomePrefixMustBeAWholeComponent() {
        XCTAssertEqual(PathLabel.abbreviate("/Users/jonathan", home: home), "/Users/jonathan")
    }
}
