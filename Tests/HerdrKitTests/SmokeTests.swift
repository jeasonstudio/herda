import XCTest
@testable import HerdrKit

final class SmokeTests: XCTestCase {
    func testProtocolVersionIsPinnedTo19() {
        XCTAssertEqual(HerdrKit.protocolVersion, 19)
    }
}
