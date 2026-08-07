# M3「原生侧边栏」实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用原生 SwiftUI 侧边栏呈现 workspaces 与 agents 及其实时状态，点击可切换焦点——这是这个 app 相对 herdr TUI 的核心增值。

**Architecture:** 走 JSON API socket，与 M1/M2 的 client protocol socket **完全独立**：渲染卡住不影响侧边栏，反之亦然。初始状态用 `session.snapshot` 一次拿全量，之后用 `events.subscribe` 的长连接做增量更新。请求/响应用短连接（每次新建），订阅用一条常驻长连接。

**Tech Stack:** 承接 M1/M2——Swift 6 / SwiftUI / `JSONDecoder` / XCTest / xcodegen

前置：M1 已验收，M2 已完成（侧边栏点击切焦点后需要键盘继续可用）。设计见 `design.md`。

---

## 前置事实（已实测，勿重新推导）

**传输**：Unix domain socket，newline-delimited JSON。socket 路径 = `RuntimePaths.apiSocket`（M1 已有）。

**请求 / 响应**（短连接即可）：

```
→ {"id":"p","method":"pane.list","params":{}}
← {"id":"p","result":{"type":"pane_list","panes":[...]}}
```

**事件订阅**（必须保持连接开启，否则 server 不再推送）：

```
→ {"id":"e","method":"events.subscribe","params":{"subscriptions":[{"type":"workspace.created"},{"type":"pane.created"}]}}
← {"id":"e","result":{"type":"subscription_started"}}
← {"event":"workspace_created","data":{"type":"workspace_created","workspace":{...}}}
← {"event":"pane_created","data":{"type":"pane_created","pane":{...}}}
```

**区分响应与事件的依据：响应有 `id` 字段，事件有 `event` 字段而无 `id`。** 同一条连接上两者混流。

注意订阅名与事件名的形式不同：订阅用点号（`workspace.created`），推送的 `event` 用下划线（`workspace_created`）。

**`session.snapshot`** 返回 `{"type":"session_snapshot","snapshot":{...}}`，`snapshot` 含 `version`、`protocol`、`focused_workspace_id`、`focused_tab_id`、`focused_pane_id`、`workspaces`、`tabs`、`panes`、`layouts`、`agents`。用它做初始加载，避免多次请求拼装。

**`agent_status`** 取值：`idle`、`working`、`blocked`、`done`、`unknown`（`api/schema/common.rs:151`）。

**真实 JSON 样本**（字段为 snake_case，用 `.convertFromSnakeCase` 解码）：

```json
{"workspace_id":"w2","number":2,"label":"~","focused":false,
 "pane_count":1,"tab_count":1,"active_tab_id":"w2:t1","agent_status":"unknown"}
```

```json
{"pane_id":"w1:p1","terminal_id":"term_65832a8e","workspace_id":"w1","tab_id":"w1:t1",
 "focused":false,"cwd":"/Users/jeason","foreground_cwd":"/Users/jeason",
 "agent":"claude","terminal_title":"✳ 调整 Settings 页面","terminal_title_stripped":"调整 Settings 页面",
 "agent_status":"idle","scroll":{"offset_from_bottom":0,"max_offset_from_bottom":0,"viewport_rows":66},
 "revision":30}
```

`agent`、`terminal_title`、`agent_session` 等字段**可能缺失**（无 agent 的 pane 就没有），必须声明为可选。

**焦点切换方法**：`workspace.focus` / `pane.focus`，params 为 `{"workspace_id":"..."}` / `{"pane_id":"..."}`。

## 文件结构

| 文件 | 职责 |
|---|---|
| `Sources/HerdrKit/Protocol/ApiTypes.swift` | 新建：`WorkspaceInfo` / `PaneInfo` / `AgentStatus` / `SessionSnapshot` / 事件载荷 |
| `Sources/HerdrKit/Protocol/ApiClient.swift` | 新建：请求/响应与订阅长连接 |
| `Sources/HerdrKit/Sidebar/SidebarModel.swift` | 新建：快照加载 + 事件增量更新（纯逻辑，可测） |
| `Sources/HerdrPrototype/SidebarView.swift` | 新建：SwiftUI 列表与点击 |
| `Sources/HerdrPrototype/ContentView.swift` | 改：拆成 侧边栏 \| 终端区 |
| `Sources/HerdrKit/Runtime/TerminalSession.swift` | 改：暴露 `apiSocket` 路径给侧边栏 |
| `Tests/HerdrKitTests/ApiTypesTests.swift` | 新建 |
| `Tests/HerdrKitTests/SidebarModelTests.swift` | 新建 |

---

## Task 1: API 数据类型

**Files:**
- Create: `macos-client/Sources/HerdrKit/Protocol/ApiTypes.swift`
- Create: `macos-client/Tests/HerdrKitTests/ApiTypesTests.swift`

- [ ] **Step 1: 写失败测试**

`Tests/HerdrKitTests/ApiTypesTests.swift`:

```swift
import XCTest
@testable import HerdrKit

final class ApiTypesTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try ApiTypes.decoder.decode(type, from: Data(json.utf8))
    }

    func testDecodesWorkspaceInfo() throws {
        let json = """
        {"workspace_id":"w2","number":2,"label":"~","focused":false,
         "pane_count":1,"tab_count":1,"active_tab_id":"w2:t1","agent_status":"unknown"}
        """
        let workspace = try decode(WorkspaceInfo.self, from: json)
        XCTAssertEqual(workspace.workspaceId, "w2")
        XCTAssertEqual(workspace.number, 2)
        XCTAssertEqual(workspace.label, "~")
        XCTAssertFalse(workspace.focused)
        XCTAssertEqual(workspace.paneCount, 1)
        XCTAssertEqual(workspace.agentStatus, .unknown)
    }

    func testDecodesPaneInfoWithAgent() throws {
        let json = """
        {"pane_id":"w1:p1","terminal_id":"term_65832a8e","workspace_id":"w1","tab_id":"w1:t1",
         "focused":true,"cwd":"/Users/jeason","foreground_cwd":"/Users/jeason",
         "agent":"claude","terminal_title":"✳ 调整","terminal_title_stripped":"调整",
         "agent_status":"idle","revision":30}
        """
        let pane = try decode(PaneInfo.self, from: json)
        XCTAssertEqual(pane.paneId, "w1:p1")
        XCTAssertEqual(pane.workspaceId, "w1")
        XCTAssertEqual(pane.agent, "claude")
        XCTAssertEqual(pane.agentStatus, .idle)
        XCTAssertEqual(pane.terminalTitleStripped, "调整")
        XCTAssertTrue(pane.focused)
    }

    func testDecodesPaneInfoWithoutAgentFields() throws {
        // Panes with no agent omit `agent`, `terminal_title` and friends.
        let json = """
        {"pane_id":"w2:p1","terminal_id":"term_x","workspace_id":"w2","tab_id":"w2:t1",
         "focused":false,"cwd":"/Users/jeason","foreground_cwd":"/Users/jeason",
         "agent_status":"unknown","revision":0}
        """
        let pane = try decode(PaneInfo.self, from: json)
        XCTAssertNil(pane.agent)
        XCTAssertNil(pane.terminalTitleStripped)
        XCTAssertEqual(pane.agentStatus, .unknown)
    }

    func testDecodesAllAgentStatuses() throws {
        for (raw, expected) in [
            ("idle", AgentStatus.idle),
            ("working", .working),
            ("blocked", .blocked),
            ("done", .done),
            ("unknown", .unknown),
        ] {
            let json = "{\"status\":\"\(raw)\"}"
            struct Holder: Decodable { let status: AgentStatus }
            XCTAssertEqual(try decode(Holder.self, from: json).status, expected)
        }
    }

    func testUnrecognisedAgentStatusDecodesToUnknown() throws {
        // Forward compatibility: a new server status must not break the sidebar.
        struct Holder: Decodable { let status: AgentStatus }
        XCTAssertEqual(try decode(Holder.self, from: "{\"status\":\"sleeping\"}").status, .unknown)
    }

    func testDecodesSessionSnapshotEnvelope() throws {
        let json = """
        {"type":"session_snapshot","snapshot":{"version":"0.8.0","protocol":19,
         "focused_workspace_id":"w1","workspaces":[],"tabs":[],"panes":[],
         "layouts":[],"agents":[]}}
        """
        let envelope = try decode(SessionSnapshotEnvelope.self, from: json)
        XCTAssertEqual(envelope.snapshot.focusedWorkspaceId, "w1")
        XCTAssertEqual(envelope.snapshot.protocolVersion, 19)
        XCTAssertTrue(envelope.snapshot.workspaces.isEmpty)
    }

    func testDistinguishesEventFromResponseByPresenceOfId() throws {
        let response = """
        {"id":"p","result":{"type":"pane_list","panes":[]}}
        """
        let event = """
        {"event":"pane_created","data":{"type":"pane_created","pane":{}}}
        """
        XCTAssertEqual(try ApiTypes.classify(line: response), .response(id: "p"))
        XCTAssertEqual(try ApiTypes.classify(line: event), .event(name: "pane_created"))
    }

    func testClassifyRejectsLineWithNeitherField() {
        XCTAssertThrowsError(try ApiTypes.classify(line: "{\"junk\":1}"))
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd macos-client && ./Scripts/test.sh -only-testing:HerdrKitTests/ApiTypesTests
```

Expected: `cannot find 'ApiTypes' in scope`

- [ ] **Step 3: 实现**

`Sources/HerdrKit/Protocol/ApiTypes.swift`:

```swift
import Foundation

/// Agent lifecycle state as reported by the server.
///
/// Decodes unrecognised values to `.unknown` so a newer server cannot break
/// the sidebar.
public enum AgentStatus: String, Decodable, Sendable {
    case idle
    case working
    case blocked
    case done
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentStatus(rawValue: raw) ?? .unknown
    }
}

public struct WorkspaceInfo: Decodable, Identifiable, Sendable {
    public let workspaceId: String
    public let number: Int
    public let label: String
    public let focused: Bool
    public let paneCount: Int
    public let tabCount: Int
    public let agentStatus: AgentStatus

    public var id: String { workspaceId }
}

public struct PaneInfo: Decodable, Identifiable, Sendable {
    public let paneId: String
    public let terminalId: String
    public let workspaceId: String
    public let tabId: String
    public let focused: Bool
    public let cwd: String
    public let agentStatus: AgentStatus
    /// Absent on panes that are not running a recognised agent.
    public let agent: String?
    public let terminalTitleStripped: String?

    public var id: String { paneId }
}

public struct SessionSnapshot: Decodable, Sendable {
    public let version: String
    /// `protocol` is a Swift keyword, so it is renamed on decode.
    public let protocolVersion: UInt32
    public let focusedWorkspaceId: String?
    public let focusedPaneId: String?
    public let workspaces: [WorkspaceInfo]
    public let panes: [PaneInfo]

    private enum CodingKeys: String, CodingKey {
        case version
        case protocolVersion = "protocol"
        case focusedWorkspaceId = "focused_workspace_id"
        case focusedPaneId = "focused_pane_id"
        case workspaces
        case panes
    }
}

public struct SessionSnapshotEnvelope: Decodable, Sendable {
    public let snapshot: SessionSnapshot
}

public enum ApiTypes {
    public enum LineKind: Equatable, Sendable {
        case response(id: String)
        case event(name: String)
    }

    public enum Failure: Error, Equatable {
        case unclassifiableLine(String)
    }

    /// Server responses carry `id`; pushed events carry `event` and no `id`.
    /// Both arrive on the same subscription connection.
    public static func classify(line: String) throws -> LineKind {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw Failure.unclassifiableLine(line)
        }
        if let id = object["id"] as? String {
            return .response(id: id)
        }
        if let event = object["event"] as? String {
            return .event(name: event)
        }
        throw Failure.unclassifiableLine(line)
    }

    /// snake_case is the wire convention; `SessionSnapshot` overrides the two
    /// keys this strategy cannot derive.
    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}
```

注意 `SessionSnapshot` 显式声明 `CodingKeys`：`protocol` 是 Swift 关键字，`.convertFromSnakeCase` 也无法把它映射到 `protocolVersion`。

- [ ] **Step 4: 运行测试确认通过**

```bash
cd macos-client && xcodegen generate && ./Scripts/test.sh -only-testing:HerdrKitTests/ApiTypesTests
```

Expected: 8 个 test case passed

- [ ] **Step 5: 提交**

```bash
cd macos-client && git add -A && git commit -m "feat: add json api data types"
```

---

## Task 2: API 请求与响应

**Files:**
- Create: `macos-client/Sources/HerdrKit/Protocol/ApiClient.swift`
- Create: `macos-client/Tests/HerdrKitTests/ApiClientTests.swift`

- [ ] **Step 1: 写失败测试**

用 `socketpair` 扮演 server，复用 M1 的 `UnixSocket`。

`Tests/HerdrKitTests/ApiClientTests.swift`:

```swift
import Darwin
import XCTest
@testable import HerdrKit

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
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd macos-client && ./Scripts/test.sh -only-testing:HerdrKitTests/ApiClientTests
```

Expected: `cannot find 'ApiClient' in scope`

- [ ] **Step 3: 实现**

`Sources/HerdrKit/Protocol/ApiClient.swift`:

```swift
import Foundation

/// Reads newline-delimited lines from a socket, buffering partial reads.
final class LineReader {
    enum Failure: Error {
        case closedBeforeNewline(partial: String)
    }

    private let socket: UnixSocket
    private var buffer: [UInt8] = []

    init(socket: UnixSocket) {
        self.socket = socket
    }

    func readLine() throws -> String {
        while true {
            if let index = buffer.firstIndex(of: 0x0A) {
                let lineBytes = Array(buffer[..<index])
                buffer.removeSubrange(...index)
                return String(decoding: lineBytes, as: UTF8.self)
            }
            do {
                buffer.append(contentsOf: try socket.readExactly(1))
            } catch {
                throw Failure.closedBeforeNewline(
                    partial: String(decoding: buffer, as: UTF8.self)
                )
            }
        }
    }
}

/// Client for herdr's newline-delimited JSON API.
///
/// Request/response uses a short-lived connection per call — simpler than
/// multiplexing, and these calls are infrequent. The event subscription needs a
/// long-lived connection instead (see `subscribe`).
public final class ApiClient: @unchecked Sendable {
    public enum Failure: Error {
        case requestEncodingFailed
        case errorResponse(String)
        case unexpectedResponse(String)
    }

    private let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    static func requestLine(
        id: String,
        method: String,
        params: [String: Any]
    ) throws -> String {
        let payload: [String: Any] = ["id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw Failure.requestEncodingFailed
        }
        return text + "\n"
    }

    /// Issues one request and returns the raw response line.
    public func request(
        method: String,
        params: [String: Any] = [:],
        id: String = "req"
    ) throws -> String {
        let socket = try UnixSocket(connectingTo: socketPath)
        defer { socket.close() }
        try socket.write(Array(try ApiClient.requestLine(id: id, method: method, params: params).utf8))
        return try LineReader(socket: socket).readLine()
    }

    /// Issues a request and decodes `result` into the given type.
    public func request<T: Decodable>(
        _ type: T.Type,
        method: String,
        params: [String: Any] = [:],
        id: String = "req"
    ) throws -> T {
        let line = try request(method: method, params: params, id: id)
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw Failure.unexpectedResponse(line)
        }
        if let error = object["error"] {
            throw Failure.errorResponse(String(describing: error))
        }
        guard let result = object["result"] else {
            throw Failure.unexpectedResponse(line)
        }
        let resultData = try JSONSerialization.data(withJSONObject: result)
        return try ApiTypes.decoder.decode(type, from: resultData)
    }

    public func snapshot() throws -> SessionSnapshot {
        try request(SessionSnapshotEnvelope.self, method: "session.snapshot", id: "snapshot")
            .snapshot
    }

    public func focusWorkspace(_ workspaceId: String) throws {
        _ = try request(
            method: "workspace.focus",
            params: ["workspace_id": workspaceId],
            id: "focus-workspace"
        )
    }

    public func focusPane(_ paneId: String) throws {
        _ = try request(
            method: "pane.focus",
            params: ["pane_id": paneId],
            id: "focus-pane"
        )
    }
}
```

`readExactly(1)` 逐字节读效率不高，但侧边栏的数据量很小，且它让缓冲逻辑不必处理"读多了"的情况。

- [ ] **Step 4: 运行测试确认通过**

```bash
cd macos-client && xcodegen generate && ./Scripts/test.sh -only-testing:HerdrKitTests/ApiClientTests
```

Expected: 5 个 test case passed

- [ ] **Step 5: 提交**

```bash
cd macos-client && git add -A && git commit -m "feat: add json api request client"
```

---

## Task 3: 事件订阅长连接

**Files:**
- Modify: `macos-client/Sources/HerdrKit/Protocol/ApiClient.swift`
- Modify: `macos-client/Tests/HerdrKitTests/ApiClientTests.swift`

- [ ] **Step 1: 追加失败测试**

```swift
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
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd macos-client && ./Scripts/test.sh -only-testing:HerdrKitTests/ApiClientTests
```

Expected: `type 'ApiClient' has no member 'subscribeLine'`

- [ ] **Step 3: 实现**

在 `ApiClient` 内追加：

```swift
    static func subscribeLine(to eventTypes: [String]) throws -> String {
        try requestLine(
            id: "events",
            method: "events.subscribe",
            params: ["subscriptions": eventTypes.map { ["type": $0] }]
        )
    }

    /// Events the sidebar needs. Subscription names use dots; the pushed
    /// `event` field uses underscores.
    public static let sidebarEventTypes = [
        "workspace.created",
        "workspace.updated",
        "workspace.renamed",
        "workspace.closed",
        "workspace.focused",
        "pane.created",
        "pane.updated",
        "pane.closed",
        "pane.focused",
        "pane.exited",
        "pane.agent_detected",
    ]

    /// Opens a subscription and returns the pump driving it. The connection must
    /// stay open: the server stops pushing once the client half-closes.
    public func subscribe(to eventTypes: [String] = sidebarEventTypes) throws -> EventPump {
        let socket = try UnixSocket(connectingTo: socketPath)
        try socket.write(Array(try ApiClient.subscribeLine(to: eventTypes).utf8))
        return EventPump(socket: socket)
    }

    /// Reads an event subscription on a background thread.
    public final class EventPump: @unchecked Sendable {
        private let socket: UnixSocket
        private let reader: LineReader
        private var thread: Thread?
        private let stopped = Flag()

        init(socket: UnixSocket) {
            self.socket = socket
            self.reader = LineReader(socket: socket)
        }

        public func start(
            onEvent: @escaping @Sendable (String, [String: Any]) -> Void,
            onFailure: @escaping @Sendable (Error) -> Void
        ) {
            let thread = Thread { [weak self] in
                guard let self else { return }
                while !self.stopped.isSet {
                    do {
                        let line = try self.reader.readLine()
                        guard case .event(let name) = try ApiTypes.classify(line: line) else {
                            continue    // the subscription acknowledgement
                        }
                        let data = line.data(using: .utf8) ?? Data()
                        let object = (try? JSONSerialization.jsonObject(with: data))
                            as? [String: Any]
                        let payload = object?["data"] as? [String: Any] ?? [:]
                        onEvent(name, payload)
                    } catch {
                        if !self.stopped.isSet { onFailure(error) }
                        return
                    }
                }
            }
            thread.name = "herdr.api.events"
            self.thread = thread
            thread.start()
        }

        public func stop() {
            stopped.set()
            socket.close()
            thread = nil
        }

        private final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            var isSet: Bool {
                lock.lock(); defer { lock.unlock() }
                return value
            }
            func set() { lock.lock(); value = true; lock.unlock() }
        }
    }
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cd macos-client && xcodegen generate && ./Scripts/test.sh -only-testing:HerdrKitTests/ApiClientTests
```

Expected: 7 个 test case passed

- [ ] **Step 5: 提交**

```bash
cd macos-client && git add -A && git commit -m "feat: subscribe to api events over a long-lived connection"
```

---

## Task 4: 侧边栏状态模型

纯逻辑，M3 唯一值得重点测试的部分：给它快照和事件，检查状态。

**Files:**
- Create: `macos-client/Sources/HerdrKit/Sidebar/SidebarModel.swift`
- Create: `macos-client/Tests/HerdrKitTests/SidebarModelTests.swift`

- [ ] **Step 1: 写失败测试**

`Tests/HerdrKitTests/SidebarModelTests.swift`:

```swift
import XCTest
@testable import HerdrKit

@MainActor
final class SidebarModelTests: XCTestCase {
    private func snapshot(
        workspaces: [(String, Int)] = [("w1", 1)],
        panes: [(String, String, String?, AgentStatus)] = []
    ) throws -> SessionSnapshot {
        let workspaceJSON = workspaces.map { id, number in
            """
            {"workspace_id":"\(id)","number":\(number),"label":"~","focused":false,
             "pane_count":1,"tab_count":1,"active_tab_id":"\(id):t1","agent_status":"unknown"}
            """
        }.joined(separator: ",")
        let paneJSON = panes.map { paneId, workspaceId, agent, status in
            let agentField = agent.map { "\"agent\":\"\($0)\"," } ?? ""
            return """
            {"pane_id":"\(paneId)","terminal_id":"t","workspace_id":"\(workspaceId)",
             "tab_id":"\(workspaceId):t1","focused":false,"cwd":"/","foreground_cwd":"/",
             \(agentField)"agent_status":"\(status.rawValue)","revision":0}
            """
        }.joined(separator: ",")
        let json = """
        {"version":"0.8.0","protocol":19,"workspaces":[\(workspaceJSON)],
         "tabs":[],"panes":[\(paneJSON)],"layouts":[],"agents":[]}
        """
        return try ApiTypes.decoder.decode(SessionSnapshot.self, from: Data(json.utf8))
    }

    func testApplyingSnapshotPopulatesWorkspacesAndPanes() throws {
        let model = SidebarModel()
        model.apply(try snapshot(
            workspaces: [("w1", 1), ("w2", 2)],
            panes: [("w1:p1", "w1", "claude", .working)]
        ))
        XCTAssertEqual(model.workspaces.map(\.workspaceId), ["w1", "w2"])
        XCTAssertEqual(model.panes(inWorkspace: "w1").map(\.paneId), ["w1:p1"])
        XCTAssertTrue(model.panes(inWorkspace: "w2").isEmpty)
    }

    func testWorkspacesAreOrderedByNumber() throws {
        let model = SidebarModel()
        model.apply(try snapshot(workspaces: [("w3", 3), ("w1", 1), ("w2", 2)]))
        XCTAssertEqual(model.workspaces.map(\.number), [1, 2, 3])
    }

    func testOnlyPanesWithAnAgentAreListedAsAgents() throws {
        let model = SidebarModel()
        model.apply(try snapshot(
            workspaces: [("w1", 1)],
            panes: [
                ("w1:p1", "w1", "claude", .working),
                ("w1:p2", "w1", nil, .unknown),
            ]
        ))
        XCTAssertEqual(model.agents(inWorkspace: "w1").map(\.paneId), ["w1:p1"])
    }

    func testPaneUpdatedEventReplacesTheStoredPane() throws {
        let model = SidebarModel()
        model.apply(try snapshot(
            workspaces: [("w1", 1)],
            panes: [("w1:p1", "w1", "claude", .idle)]
        ))
        XCTAssertEqual(model.panes(inWorkspace: "w1").first?.agentStatus, .idle)

        model.handle(event: "pane_updated", data: [
            "pane": [
                "pane_id": "w1:p1", "terminal_id": "t", "workspace_id": "w1",
                "tab_id": "w1:t1", "focused": false, "cwd": "/", "foreground_cwd": "/",
                "agent": "claude", "agent_status": "working", "revision": 1,
            ],
        ])
        XCTAssertEqual(model.panes(inWorkspace: "w1").first?.agentStatus, .working)
    }

    func testPaneCreatedEventAppends() throws {
        let model = SidebarModel()
        model.apply(try snapshot(workspaces: [("w1", 1)]))
        model.handle(event: "pane_created", data: [
            "pane": [
                "pane_id": "w1:p9", "terminal_id": "t", "workspace_id": "w1",
                "tab_id": "w1:t1", "focused": false, "cwd": "/", "foreground_cwd": "/",
                "agent_status": "unknown", "revision": 0,
            ],
        ])
        XCTAssertEqual(model.panes(inWorkspace: "w1").map(\.paneId), ["w1:p9"])
    }

    func testPaneClosedEventRemoves() throws {
        let model = SidebarModel()
        model.apply(try snapshot(
            workspaces: [("w1", 1)],
            panes: [("w1:p1", "w1", "claude", .idle)]
        ))
        model.handle(event: "pane_closed", data: ["pane_id": "w1:p1"])
        XCTAssertTrue(model.panes(inWorkspace: "w1").isEmpty)
    }

    func testWorkspaceFocusedEventUpdatesFocus() throws {
        let model = SidebarModel()
        model.apply(try snapshot(workspaces: [("w1", 1), ("w2", 2)]))
        model.handle(event: "workspace_focused", data: ["workspace_id": "w2"])
        XCTAssertEqual(model.focusedWorkspaceId, "w2")
    }

    func testWorkspaceClosedEventRemovesItAndItsPanes() throws {
        let model = SidebarModel()
        model.apply(try snapshot(
            workspaces: [("w1", 1), ("w2", 2)],
            panes: [("w2:p1", "w2", "claude", .idle)]
        ))
        model.handle(event: "workspace_closed", data: ["workspace_id": "w2"])
        XCTAssertEqual(model.workspaces.map(\.workspaceId), ["w1"])
        XCTAssertTrue(model.panes(inWorkspace: "w2").isEmpty)
    }

    func testMalformedEventPayloadIsIgnored() throws {
        let model = SidebarModel()
        model.apply(try snapshot(workspaces: [("w1", 1)]))
        model.handle(event: "pane_updated", data: ["pane": "not an object"])
        model.handle(event: "totally_unknown_event", data: [:])
        XCTAssertEqual(model.workspaces.count, 1, "state must survive junk")
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd macos-client && ./Scripts/test.sh -only-testing:HerdrKitTests/SidebarModelTests
```

Expected: `cannot find 'SidebarModel' in scope`

- [ ] **Step 3: 实现**

`Sources/HerdrKit/Sidebar/SidebarModel.swift`:

```swift
import Foundation

/// Sidebar state: seeded from `session.snapshot`, then updated incrementally
/// from pushed events.
///
/// Malformed or unknown payloads are ignored rather than raised. A sidebar that
/// silently misses one update is far better than one that tears down the view.
@MainActor
public final class SidebarModel: ObservableObject {
    @Published public private(set) var workspaces: [WorkspaceInfo] = []
    @Published public private(set) var focusedWorkspaceId: String?
    @Published public private(set) var focusedPaneId: String?

    private var panesById: [String: PaneInfo] = [:]

    public init() {}

    public func apply(_ snapshot: SessionSnapshot) {
        workspaces = snapshot.workspaces.sorted { $0.number < $1.number }
        panesById = Dictionary(
            uniqueKeysWithValues: snapshot.panes.map { ($0.paneId, $0) }
        )
        focusedWorkspaceId = snapshot.focusedWorkspaceId
        focusedPaneId = snapshot.focusedPaneId
    }

    public func panes(inWorkspace workspaceId: String) -> [PaneInfo] {
        panesById.values
            .filter { $0.workspaceId == workspaceId }
            .sorted { $0.paneId < $1.paneId }
    }

    /// Panes running a recognised agent — the sidebar's primary content.
    public func agents(inWorkspace workspaceId: String) -> [PaneInfo] {
        panes(inWorkspace: workspaceId).filter { $0.agent != nil }
    }

    public func handle(event: String, data: [String: Any]) {
        switch event {
        case "pane_created", "pane_updated", "pane_focused", "pane_agent_detected":
            guard let pane = decodePane(from: data) else { return }
            panesById[pane.paneId] = pane
            if pane.focused { focusedPaneId = pane.paneId }

        case "pane_closed", "pane_exited":
            guard let paneId = data["pane_id"] as? String else { return }
            panesById.removeValue(forKey: paneId)

        case "workspace_created", "workspace_updated", "workspace_renamed":
            guard let workspace = decodeWorkspace(from: data) else { return }
            if let index = workspaces.firstIndex(where: {
                $0.workspaceId == workspace.workspaceId
            }) {
                workspaces[index] = workspace
            } else {
                workspaces.append(workspace)
            }
            workspaces.sort { $0.number < $1.number }

        case "workspace_focused":
            guard let workspaceId = data["workspace_id"] as? String else { return }
            focusedWorkspaceId = workspaceId

        case "workspace_closed":
            guard let workspaceId = data["workspace_id"] as? String else { return }
            workspaces.removeAll { $0.workspaceId == workspaceId }
            for (paneId, pane) in panesById where pane.workspaceId == workspaceId {
                panesById.removeValue(forKey: paneId)
            }

        default:
            break
        }
    }

    private func decodePane(from data: [String: Any]) -> PaneInfo? {
        decode(PaneInfo.self, from: data["pane"])
    }

    private func decodeWorkspace(from data: [String: Any]) -> WorkspaceInfo? {
        decode(WorkspaceInfo.self, from: data["workspace"])
    }

    private func decode<T: Decodable>(_ type: T.Type, from value: Any?) -> T? {
        guard let object = value,
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object)
        else { return nil }
        return try? ApiTypes.decoder.decode(type, from: data)
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cd macos-client && xcodegen generate && ./Scripts/test.sh -only-testing:HerdrKitTests/SidebarModelTests
```

Expected: 9 个 test case passed

- [ ] **Step 5: 提交**

```bash
cd macos-client && git add -A && git commit -m "feat: track sidebar state from snapshot and events"
```

---

## Task 5: 侧边栏视图

**Files:**
- Create: `macos-client/Sources/HerdrPrototype/SidebarView.swift`

- [ ] **Step 1: 实现视图**

`Sources/HerdrPrototype/SidebarView.swift`:

```swift
import HerdrKit
import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: SidebarModel
    let onSelectWorkspace: (String) -> Void
    let onSelectPane: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(model.workspaces) { workspace in
                    workspaceRow(workspace)
                    ForEach(model.agents(inWorkspace: workspace.workspaceId)) { pane in
                        agentRow(pane)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func workspaceRow(_ workspace: WorkspaceInfo) -> some View {
        HStack(spacing: 6) {
            StatusDot(status: workspace.agentStatus)
            Text("\(workspace.number)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(workspace.label)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            workspace.workspaceId == model.focusedWorkspaceId
                ? Color.accentColor.opacity(0.18)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelectWorkspace(workspace.workspaceId) }
    }

    private func agentRow(_ pane: PaneInfo) -> some View {
        HStack(spacing: 6) {
            StatusDot(status: pane.agentStatus)
            VStack(alignment: .leading, spacing: 1) {
                Text(pane.agent ?? "agent")
                    .font(.system(.caption, design: .monospaced))
                Text(pane.terminalTitleStripped ?? pane.cwd)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 26)
        .padding(.trailing, 10)
        .padding(.vertical, 3)
        .background(
            pane.paneId == model.focusedPaneId
                ? Color.accentColor.opacity(0.12)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 4)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelectPane(pane.paneId) }
    }
}

/// Agent status as a colored dot — the whole point of the native sidebar is
/// that this is visible at a glance.
private struct StatusDot: View {
    let status: AgentStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
    }

    private var color: Color {
        switch status {
        case .working: return .green
        case .blocked: return .orange
        case .done: return .blue
        case .idle: return .secondary
        case .unknown: return .secondary.opacity(0.4)
        }
    }
}
```

- [ ] **Step 2: 构建确认无错**

```bash
cd macos-client && xcodegen generate && xcodebuild -project macos-client.xcodeproj -scheme HerdrPrototype -configuration Debug -derivedDataPath build build 2>&1 | grep -E "error:|\*\* BUILD" | head -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: 提交**

```bash
cd macos-client && git add -A && git commit -m "feat: add native sidebar view"
```

---

## Task 6: 接线侧边栏

**Files:**
- Modify: `macos-client/Sources/HerdrKit/Runtime/TerminalSession.swift`
- Modify: `macos-client/Sources/HerdrPrototype/ContentView.swift`

- [ ] **Step 1: 在 session 里驱动 API 通道**

`TerminalSession` 内追加：

```swift
    public let sidebar = SidebarModel()

    private var api: ApiClient?
    private var eventPump: ApiClient.EventPump?

    /// Starts the API channel. Deliberately independent of the render channel:
    /// a stalled sidebar must not affect the terminal, and vice versa.
    private func startApiChannel() {
        let api = ApiClient(socketPath: paths.apiSocket.path)
        self.api = api

        Task.detached { [weak self] in
            do {
                let snapshot = try api.snapshot()
                await MainActor.run { self?.sidebar.apply(snapshot) }
                let pump = try api.subscribe()
                await MainActor.run { self?.eventPump = pump }
                pump.start(
                    onEvent: { name, data in
                        Task { @MainActor in self?.sidebar.handle(event: name, data: data) }
                    },
                    onFailure: { error in
                        Task { @MainActor in self?.log("event pump stopped: \(error)") }
                    }
                )
            } catch {
                await MainActor.run { self?.log("api channel failed: \(error)") }
            }
        }
    }

    public func focusWorkspace(_ workspaceId: String) {
        guard let api else { return }
        Task.detached { [weak self] in
            do {
                try api.focusWorkspace(workspaceId)
            } catch {
                await MainActor.run { self?.log("focus workspace failed: \(error)") }
            }
        }
    }

    public func focusPane(_ paneId: String) {
        guard let api else { return }
        Task.detached { [weak self] in
            do {
                try api.focusPane(paneId)
            } catch {
                await MainActor.run { self?.log("focus pane failed: \(error)") }
            }
        }
    }
```

在 `attach(_:)` 末尾调用 `startApiChannel()`，并在 `shutdown()` 中加入：

```swift
        eventPump?.stop()
        eventPump = nil
        api = nil
```

`ApiClient` 与 `EventPump` 已标 `@unchecked Sendable`，可在 detached task 中捕获。

- [ ] **Step 2: 改 ContentView 为 侧边栏 | 终端区**

把 `ContentView.body` 改为：

```swift
    var body: some View {
        HStack(spacing: 0) {
            SidebarView(
                model: session.sidebar,
                onSelectWorkspace: { session.focusWorkspace($0) },
                onSelectPane: { session.focusPane($0) }
            )
            .frame(width: 220)
            .background(.thinMaterial)

            Divider()

            terminalArea
        }
        .onDisappear { session.shutdown() }
    }

    /// The M1/M2 terminal surface, unchanged apart from being nested.
    private var terminalArea: some View {
        GeometryReader { geometry in
            ZStack {
                GridViewRepresentable(view: session.view)
                    .onAppear { session.start(viewportSize: geometry.size) }
                    .onChange(of: geometry.size) { _, size in session.resize(to: size) }
                    .onReceive(
                        NotificationCenter.default.publisher(
                            for: NSWindow.didBecomeKeyNotification
                        )
                    ) { _ in session.reportFocus(gained: true) }
                    .onReceive(
                        NotificationCenter.default.publisher(
                            for: NSWindow.didResignKeyNotification
                        )
                    ) { _ in session.reportFocus(gained: false) }

                switch session.state {
                case .idle, .starting:
                    ProgressView(statusText)
                        .padding()
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                case .failed(let message), .disconnected(let message):
                    ScrollView {
                        Text(message)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding()
                    }
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(40)
                case .running:
                    EmptyView()
                }
            }
        }
    }
```

注意终端区的 `cols`/`rows` 现在由**扣除侧边栏后**的宽度算出，`GeometryReader` 已自动处理。

- [ ] **Step 3: 构建并跑全部测试**

```bash
cd macos-client && xcodegen generate && ./Scripts/test.sh
```

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 4: 提交**

```bash
cd macos-client && git add -A && git commit -m "feat: wire the sidebar into the window"
```

---

## Task 7: M3 验收

- [ ] **Step 1: 启动并造出可观察的状态**

```bash
cd macos-client && xcodebuild -project macos-client.xcodeproj -scheme HerdrPrototype -configuration Debug -derivedDataPath build build 2>&1 | tail -2 && open build/Build/Products/Debug/HerdrPrototype.app
```

等窗口出现后，用 API 造出多个 workspace 和一个真实 agent：

```bash
export HERDR_SOCKET_PATH=~/Library/Application\ Support/dev.herdr.macos-client-prototype/runtime/herdr.sock
printf '{"id":"w","method":"workspace.create","params":{}}\n' | nc -U "$HERDR_SOCKET_PATH" >/dev/null
printf '{"id":"w","method":"workspace.create","params":{}}\n' | nc -U "$HERDR_SOCKET_PATH" >/dev/null
herdr pane list
```

在某个 pane 里启动一个真实 agent，以便观察状态变化：

```bash
herdr pane send-text <pane-id> 'claude'
herdr pane send-keys <pane-id> Enter
```

- [ ] **Step 2: 逐项验收**

- [ ] 侧边栏列出所有 workspace，按编号排序
- [ ] 运行 agent 的 pane 在侧边栏显示为 agent 行，含名称与标题
- [ ] `agent_status` 的颜色点随 agent 忙碌/空闲**实时变化**（不需要重启 app）
- [ ] 新建 workspace 后侧边栏**自动出现**该项
- [ ] 关闭 workspace 后侧边栏自动移除该项
- [ ] 点击 workspace 能切换终端区显示的内容
- [ ] 点击 agent 行能切到对应 pane
- [ ] 当前 focus 的项有高亮
- [ ] 侧边栏卡顿或报错时终端仍可打字（两条通道独立）
- [ ] 终端区宽度已扣除侧边栏，内容不被裁切

- [ ] **Step 3: 验证通道独立性**

杀掉事件订阅连接不应影响终端。观察 `prototype.log` 是否记录 `event pump stopped`，同时确认窗口里仍能打字。

- [ ] **Step 4: 记录验收结果并清理**

把结果写入本文件末尾。未达成项写明现象与已排除的可能。若是 UI 层异常且无法从数据侧定位，**尽早请人描述所见**。

```bash
pkill -x HerdrPrototype; sleep 2; pkill -f "herdr server" 2>/dev/null; echo cleaned
```

- [ ] **Step 5: 提交**

```bash
cd macos-client && git add -A && git commit -m "docs: record M3 acceptance results"
```

---

## 自检结果

**Spec 覆盖对照**（design.md §7 的 M3 条目）

| 设计要求 | 对应 task |
|---|---|
| `ApiClient` + `events.subscribe` | Task 2、3 |
| 侧边栏显示 workspace / agent | Task 4、5 |
| 显示 `agent_status` | Task 4（模型）、Task 5（颜色点） |
| 点击切换焦点 | Task 2（focus 方法）、Task 5（点击）、Task 6（接线） |
| 两条通道独立 | Task 6 的独立 detached task；Task 7 Step 3 验证 |
| 初始状态加载 | Task 2 的 `snapshot()`，用实测的 `session.snapshot` |

**范围外（有意不做）**：tab 层级展示（`tabs` 已在 snapshot 里但侧边栏只做 workspace → agent 两层）、侧边栏宽度拖拽、右键菜单、workspace 重命名/新建等写操作（除 focus）、`layouts` 与 `agents` 数组（agent 信息已能从 `panes` 的 `agent` 字段得到）。

**类型一致性**：`WorkspaceInfo` / `PaneInfo` / `AgentStatus` / `SessionSnapshot` / `SessionSnapshotEnvelope` / `ApiTypes.decoder` / `ApiTypes.classify` / `LineReader` / `ApiClient.EventPump` / `SidebarModel.apply` / `handle(event:data:)` / `agents(inWorkspace:)` 在各 task 间命名一致。Task 6 依赖 M2 的 `log` 与 `reportFocus`——若 M2 未先完成，`reportFocus` 与 `.onReceive` 两处需一并从 Task 6 移除。
