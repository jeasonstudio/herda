import XCTest
@testable import HerdrKit

final class HerdrRuntimeTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("herdr-runtime-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testPrefersBundledBinaryOverPathCandidates() throws {
        let bundled = scratch.appendingPathComponent("herdr")
        let fallback = scratch.appendingPathComponent("fallback-herdr")
        try Data().write(to: bundled)
        try Data().write(to: fallback)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fallback.path)

        let located = HerdrRuntime.locateBinary(candidates: [bundled, fallback])
        XCTAssertEqual(located, bundled)
    }

    func testSkipsMissingAndNonExecutableCandidates() throws {
        let missing = scratch.appendingPathComponent("nope")
        let notExecutable = scratch.appendingPathComponent("data")
        let usable = scratch.appendingPathComponent("herdr")
        try Data().write(to: notExecutable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: notExecutable.path
        )
        try Data().write(to: usable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: usable.path)

        XCTAssertEqual(HerdrRuntime.locateBinary(candidates: [missing, notExecutable, usable]), usable)
    }

    func testReturnsNilWhenNoCandidateIsUsable() {
        XCTAssertNil(HerdrRuntime.locateBinary(candidates: [scratch.appendingPathComponent("absent")]))
    }

    func testWaitForSocketsTimesOutWithBothPaths() {
        let paths = RuntimePaths(root: scratch)
        let runtime = HerdrRuntime(paths: paths, binary: scratch.appendingPathComponent("herdr"))
        XCTAssertThrowsError(try runtime.waitForSockets(timeout: 0.2)) { error in
            guard case .socketTimeout(let missing, _) = error as? HerdrRuntime.Failure else {
                return XCTFail("expected socketTimeout, got \(error)")
            }
            XCTAssertEqual(missing.count, 2)
        }
    }

    func testWaitForSocketsSucceedsOnceBothExist() throws {
        let paths = RuntimePaths(root: scratch)
        try Data().write(to: paths.apiSocket)
        try Data().write(to: paths.clientSocket)
        let runtime = HerdrRuntime(paths: paths, binary: scratch.appendingPathComponent("herdr"))
        XCTAssertNoThrow(try runtime.waitForSockets(timeout: 1))
    }
}
