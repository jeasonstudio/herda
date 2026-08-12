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
    ///
    /// Throws on an `error` response. This used to return the line unexamined,
    /// which meant every caller that ignored the result — focus, split, close,
    /// zoom, send — treated a rejection as success. It was caught by a live test
    /// asserting herdr rejects the key name `home`: herdr did reject it, and the
    /// client reported success anyway. For input that failure is silent and
    /// load-bearing, since a key wrongly believed to have been delivered never
    /// reaches its raw-bytes fallback.
    public func request(
        method: String,
        params: [String: Any] = [:],
        id: String = "req"
    ) throws -> String {
        let socket = try UnixSocket(connectingTo: socketPath)
        defer { socket.close() }
        try socket.write(Array(try ApiClient.requestLine(id: id, method: method, params: params).utf8))
        let line = try LineReader(socket: socket).readLine()
        try ApiClient.throwIfError(in: line)
        return line
    }

    /// Raises when a response line carries an `error` object.
    ///
    /// A line that does not parse as JSON is left alone: the typed decoder path
    /// reports that more precisely, and the untyped path has callers that only
    /// want the text back.
    static func throwIfError(in line: String) throws {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"]
        else { return }
        throw Failure.errorResponse(String(describing: error))
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

    /// Creates a workspace and returns its first pane.
    ///
    /// herda has to call this on an empty session: herdr only creates a default
    /// workspace when a full app client is connected (`headless.rs:3658`), and
    /// herda has none.
    public func createWorkspace() throws -> PaneInfo {
        try request(
            WorkspaceCreateEnvelope.self,
            method: "workspace.create",
            params: ["focus": true],
            id: "create-workspace"
        ).rootPane
    }

    public func splitPane(_ paneId: String, direction: SplitDirection) throws {
        _ = try request(
            method: "pane.split",
            params: ["target_pane_id": paneId, "direction": direction.rawValue, "focus": true],
            id: "split-pane"
        )
    }

    public func zoomPane(_ paneId: String) throws {
        _ = try request(method: "pane.zoom", params: ["pane_id": paneId], id: "zoom-pane")
    }

    public func closePane(_ paneId: String) throws {
        _ = try request(method: "pane.close", params: ["pane_id": paneId], id: "close-pane")
    }

    /// Sends key presses to one pane, by herdr's key names.
    ///
    /// The preferred input channel: herdr encodes each name with that
    /// terminal's own modes (`encode_api_keys` -> `runtime.encode_terminal_key`,
    /// `app/api_helpers.rs:37`), so application cursor mode and bracketed paste
    /// — neither observable from a client — stay on the side that knows them.
    /// Names come from `HerdrKeyName`; the six keys it cannot name go out as raw
    /// bytes instead, see `TerminalKeyBytes`.
    ///
    /// Must be called from a serial queue. herdr's API is one request per
    /// connection (`api/server.rs:139`), and concurrent connections reach the
    /// app event queue in any order — see `PaneInputQueue`.
    public func sendKeys(_ paneId: String, keys: [String]) throws {
        _ = try request(
            method: "pane.send_keys",
            params: ["pane_id": paneId, "keys": keys],
            id: "send-keys"
        )
    }

    /// Sends literal text to one pane. herdr wraps it for bracketed paste when
    /// the pane has that enabled (`app/api_helpers.rs:25`).
    ///
    /// Serial like `sendKeys`, and for the same reason.
    public func sendText(_ paneId: String, text: String) throws {
        _ = try request(
            method: "pane.send_text",
            params: ["pane_id": paneId, "text": text],
            id: "send-text"
        )
    }

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
        // Load-bearing for the native split layout: keyboard split and JSON API
        // split both go through the server's one mutation dispatcher, so this
        // event always fires. Without the subscription the UI would sit on a
        // stale layout after every prefix-key split.
        "layout.updated",
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
}
