import Darwin
import XCTest
@testable import HerdaKit

final class ApiClientTests: XCTestCase {
    private func makePair() -> (client: UnixSocket, server: UnixSocket) {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        return (UnixSocket(adopting: fds[0]), UnixSocket(adopting: fds[1]))
    }

    func testEncodesRequestAsSingleJSONLine() throws {
        let line = try ApiClient.requestLine(id: "p", method: "pane.list", params: [:])
        XCTAssertTrue(line.hasSuffix("\n"), "the API is newline-delimited")

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["id"] as? String, "p")
        XCTAssertEqual(object["method"] as? String, "pane.list")
        XCTAssertNotNil(object["params"])
    }

    func testEncodesRequestParams() throws {
        let line = try ApiClient.requestLine(
            id: "f",
            method: "workspace.focus",
            params: ["workspace_id": "w2"]
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        XCTAssertEqual(params["workspace_id"] as? String, "w2")
    }

    func testReadsOneLineFromSocket() throws {
        let (client, server) = makePair()
        defer { client.close(); server.close() }

        try server.write(Array("{\"id\":\"a\"}\n{\"id\":\"b\"}\n".utf8))
        let reader = LineReader(socket: client)
        XCTAssertEqual(try reader.readLine(), "{\"id\":\"a\"}")
        XCTAssertEqual(try reader.readLine(), "{\"id\":\"b\"}")
    }

    func testLineReaderReassemblesSplitWrites() throws {
        let (client, server) = makePair()
        defer { client.close(); server.close() }

        try server.write(Array("{\"id\"".utf8))
        try server.write(Array(":\"a\"}\n".utf8))
        let reader = LineReader(socket: client)
        XCTAssertEqual(try reader.readLine(), "{\"id\":\"a\"}")
    }

    func testLineReaderThrowsOnCloseBeforeNewline() throws {
        let (client, server) = makePair()
        try server.write(Array("partial".utf8))
        server.close()
        defer { client.close() }

        let reader = LineReader(socket: client)
        XCTAssertThrowsError(try reader.readLine())
    }

    func testSubscriptionRequestListsSubscriptionsWithDottedNames() throws {
        let line = try ApiClient.subscribeLine(to: ["workspace.created", "pane.updated"])
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["method"] as? String, "events.subscribe")
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        let subscriptions = try XCTUnwrap(params["subscriptions"] as? [[String: Any]])
        XCTAssertEqual(subscriptions.count, 2)
        XCTAssertEqual(subscriptions[0]["type"] as? String, "workspace.created")
    }

    func testSubscriptionDeliversEventsAndSkipsTheAcknowledgement() throws {
        let (client, server) = makePair()
        defer { client.close(); server.close() }

        // Acknowledgement first, then two pushed events.
        try server.write(Array("{\"id\":\"e\",\"result\":{\"type\":\"subscription_started\"}}\n".utf8))
        try server.write(Array("{\"event\":\"pane_created\",\"data\":{\"type\":\"pane_created\"}}\n".utf8))
        try server.write(Array("{\"event\":\"workspace_focused\",\"data\":{\"type\":\"workspace_focused\"}}\n".utf8))

        let received = expectation(description: "two events")
        received.expectedFulfillmentCount = 2
        let box = NameBox()

        let pump = ApiClient.EventPump(socket: client)
        pump.start(
            onEvent: { name, _ in
                box.append(name)
                received.fulfill()
            },
            onFailure: { _ in }
        )
        wait(for: [received], timeout: 5)
        pump.stop()

        XCTAssertEqual(box.names, ["pane_created", "workspace_focused"])
    }

    private final class NameBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        var names: [String] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        func append(_ name: String) {
            lock.lock(); storage.append(name); lock.unlock()
        }
    }
}
