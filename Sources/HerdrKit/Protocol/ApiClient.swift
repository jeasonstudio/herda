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
