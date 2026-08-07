import Darwin
import XCTest
@testable import HerdrKit

final class UnixSocketTests: XCTestCase {
    func testWritesAndReadsExactCounts() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let a = UnixSocket(adopting: fds[0])
        let b = UnixSocket(adopting: fds[1])
        defer { a.close(); b.close() }

        try a.write([1, 2, 3, 4, 5])
        XCTAssertEqual(try b.readExactly(2), [1, 2])
        XCTAssertEqual(try b.readExactly(3), [3, 4, 5])
    }

    func testReadExactlyReassemblesAcrossWrites() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let a = UnixSocket(adopting: fds[0])
        let b = UnixSocket(adopting: fds[1])
        defer { a.close(); b.close() }

        // Three writes accumulate in the socket buffer; one readExactly must
        // reassemble them. No concurrency needed, so no flakiness.
        try a.write([9])
        try a.write([8, 7])
        try a.write([6])
        XCTAssertEqual(try b.readExactly(4), [9, 8, 7, 6])
    }

    func testReadingAfterPeerCloseThrowsClosed() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let a = UnixSocket(adopting: fds[0])
        let b = UnixSocket(adopting: fds[1])
        a.close()
        defer { b.close() }

        XCTAssertThrowsError(try b.readExactly(1)) { error in
            XCTAssertEqual(error as? UnixSocket.Failure, .closed)
        }
    }

    func testZeroLengthReadReturnsEmpty() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let a = UnixSocket(adopting: fds[0])
        defer { a.close(); close(fds[1]) }
        XCTAssertEqual(try a.readExactly(0), [])
    }

    func testConnectingToMissingPathThrows() {
        XCTAssertThrowsError(try UnixSocket(connectingTo: "/tmp/herdr-proto-does-not-exist.sock"))
    }

    func testRejectsOverlongPath() {
        let long = "/tmp/" + String(repeating: "x", count: 200) + ".sock"
        XCTAssertThrowsError(try UnixSocket(connectingTo: long)) { error in
            guard case .pathTooLong = error as? UnixSocket.Failure else {
                return XCTFail("expected pathTooLong, got \(error)")
            }
        }
    }
}
