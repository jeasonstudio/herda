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

    // MARK: Layout surface

    func testPaneLayoutRequestLine() throws {
        let line = try ApiClient.requestLine(id: "layout", method: "pane.layout", params: [:])
        XCTAssertTrue(line.contains("\"method\":\"pane.layout\""))
        XCTAssertTrue(line.hasSuffix("\n"))
    }

    func testSplitPaneRequestCarriesDirectionAndTargetPane() throws {
        let line = try ApiClient.requestLine(
            id: "split",
            method: "pane.split",
            params: ["target_pane_id": "w1:p1", "direction": "right", "focus": true]
        )
        XCTAssertTrue(line.contains("\"method\":\"pane.split\""))
        XCTAssertTrue(line.contains("\"direction\":\"right\""))
        XCTAssertTrue(line.contains("\"target_pane_id\":\"w1:p1\""))
    }

    func testSetSplitRatioRequestLine() throws {
        let line = try ApiClient.requestLine(
            id: "ratio",
            method: "layout.set_split_ratio",
            params: ["split_id": "s0", "ratio": 0.42]
        )
        XCTAssertTrue(line.contains("\"method\":\"layout.set_split_ratio\""))
        XCTAssertTrue(line.contains("\"split_id\":\"s0\""))
    }

    func testLayoutEventTypeIsSubscribed() throws {
        // Load-bearing: keyboard split and JSON API split both go through the same
        // dispatcher on the server, so the event always fires — but without this
        // subscription the UI would sit on a stale layout after every prefix-key
        // split.
        XCTAssertTrue(ApiClient.sidebarEventTypes.contains("layout.updated"))
        let line = try ApiClient.subscribeLine(to: ApiClient.sidebarEventTypes)
        XCTAssertTrue(line.contains("layout.updated"))
    }

    func testEncodesSendKeysAsAKeyNameList() throws {
        let line = try ApiClient.requestLine(
            id: "k",
            method: "pane.send_keys",
            params: ["pane_id": "w1:p2", "keys": ["ctrl+c"]]
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["method"] as? String, "pane.send_keys")
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        XCTAssertEqual(params["pane_id"] as? String, "w1:p2")
        XCTAssertEqual(params["keys"] as? [String], ["ctrl+c"])
    }

    func testEncodesSendTextWithTheLiteralPayload() throws {
        // Text goes as text, not as a key list: herdr wraps it for bracketed
        // paste when the pane has it enabled (app/api_helpers.rs:25), which a
        // client cannot know.
        let line = try ApiClient.requestLine(
            id: "t",
            method: "pane.send_text",
            params: ["pane_id": "w1:p2", "text": "héllo 世界"]
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        XCTAssertEqual(params["text"] as? String, "héllo 世界")
    }

    func testRequestLineIsASingleLineEvenWithNewlinesInText() throws {
        // The API is newline-delimited, so an embedded newline in a paste has to
        // be escaped by the JSON encoder rather than splitting the request into
        // two — the second of which would fail to parse.
        let line = try ApiClient.requestLine(
            id: "t",
            method: "pane.send_text",
            params: ["pane_id": "w1:p2", "text": "a\nb"]
        )
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1, "only the terminator")
    }
}
