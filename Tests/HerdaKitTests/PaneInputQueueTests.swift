import XCTest
@testable import HerdaKit

final class PaneInputQueueTests: XCTestCase {
    /// Records what it was asked to send, and how many sends overlapped.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var inFlight = 0
        private var maxSeen = 0
        private var sent: [String] = []

        var maxInFlight: Int {
            lock.lock(); defer { lock.unlock() }
            return maxSeen
        }

        var order: [String] {
            lock.lock(); defer { lock.unlock() }
            return sent
        }

        func send(_ label: String) {
            lock.lock()
            inFlight += 1
            maxSeen = max(maxSeen, inFlight)
            sent.append(label)
            lock.unlock()
            // Long enough that an unserialized queue would overlap.
            Thread.sleep(forTimeInterval: 0.002)
            lock.lock()
            inFlight -= 1
            lock.unlock()
        }
    }

    func testSendsInSubmissionOrder() async {
        let recorder = Recorder()
        let queue = PaneInputQueue { recorder.send($0) }
        for index in 0 ..< 50 { queue.submit("k\(index)") }
        await queue.drain()

        XCTAssertEqual(recorder.order, (0 ..< 50).map { "k\($0)" })
    }

    func testNeverOverlapsTwoSends() async {
        // The reason this type exists. herdr's API is one request per connection
        // (api/server.rs:139) and concurrent connections reach the app event
        // queue in any order, so overlapping sends can reorder keys — and a
        // scrambled character stream leaves almost nothing to debug from.
        let recorder = Recorder()
        let queue = PaneInputQueue { recorder.send($0) }
        for index in 0 ..< 30 { queue.submit("k\(index)") }
        await queue.drain()

        XCTAssertEqual(recorder.maxInFlight, 1)
    }

    func testKeepsGoingAfterASendThrows() async {
        // A rejected keypress must not wedge the queue: one invalid_key would
        // otherwise take every later key in the session with it.
        let recorder = Recorder()
        let queue = PaneInputQueue { label in
            if label == "k1" { throw ApiClient.Failure.errorResponse("invalid_key") }
            recorder.send(label)
        }
        for index in 0 ..< 4 { queue.submit("k\(index)") }
        await queue.drain()

        XCTAssertEqual(recorder.order, ["k0", "k2", "k3"])
    }

    func testReportsAFailureWithThePayloadThatCausedIt() async {
        // Logging the payload is the whole diagnostic value: "input failed" with
        // no key name gives nothing to act on.
        let failures = FailureLog()
        let queue = PaneInputQueue(
            onFailure: { payload, _ in failures.append(payload) },
            send: { label in
                if label == "home" { throw ApiClient.Failure.errorResponse("invalid_key") }
            }
        )
        queue.submit("enter")
        queue.submit("home")
        await queue.drain()

        XCTAssertEqual(failures.all, ["home"])
    }

    private final class FailureLog: @unchecked Sendable {
        private let lock = NSLock()
        private var payloads: [String] = []

        var all: [String] {
            lock.lock(); defer { lock.unlock() }
            return payloads
        }

        func append(_ payload: String) {
            lock.lock(); payloads.append(payload); lock.unlock()
        }
    }
}
