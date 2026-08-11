import XCTest
@testable import HerdaKit

final class SmokeTests: XCTestCase {
    func testProtocolVersionIsPinnedTo19() {
        XCTAssertEqual(HerdaKit.protocolVersion, 19)
    }
}
