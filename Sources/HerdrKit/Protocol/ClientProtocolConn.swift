import Foundation

/// One connection on herdr's client protocol socket.
public final class ClientProtocolConn: @unchecked Sendable {
    public enum Failure: Error, Equatable {
        case handshakeRejected(String)
        case protocolVersionMismatch(server: UInt32, client: UInt32)
        case unexpectedFirstMessage(variantDescription: String)
    }

    private let socket: UnixSocket
    private var readThread: Thread?
    private let stopFlag = StopFlag()

    public init(socket: UnixSocket) {
        self.socket = socket
    }

    /// Sends `Hello` and validates `Welcome`.
    ///
    /// A version mismatch is fatal by design: the bundled binary and this app
    /// are versioned together, so a mismatch means the install is broken
    /// rather than something to negotiate around.
    public func handshake(
        columns: UInt16,
        rows: UInt16,
        cellWidth: UInt32,
        cellHeight: UInt32
    ) throws {
        try send(
            WireEncoder.hello(
                columns: columns,
                rows: rows,
                cellWidth: cellWidth,
                cellHeight: cellHeight
            )
        )

        let message = try readMessage()
        guard case .welcome(let version, _, let error) = message else {
            throw Failure.unexpectedFirstMessage(variantDescription: String(describing: message))
        }
        if let error {
            throw Failure.handshakeRejected(error)
        }
        guard version == HerdrKit.protocolVersion else {
            throw Failure.protocolVersionMismatch(
                server: version,
                client: HerdrKit.protocolVersion
            )
        }
    }

    public func send(_ payload: [UInt8]) throws {
        try socket.write(Framing.frame(payload))
    }

    public func startReadLoop(
        onFrame: @escaping @Sendable (GridFrame) -> Void,
        onShutdown: @escaping @Sendable (String?) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        let thread = Thread { [weak self] in
            guard let self else { return }
            while !self.stopFlag.isSet {
                do {
                    switch try self.readMessage() {
                    case .frame(let frame):
                        onFrame(frame)
                    case .shutdown(let reason):
                        onShutdown(reason)
                        return
                    case .welcome, .ignored:
                        continue
                    }
                } catch {
                    if !self.stopFlag.isSet {
                        onFailure(error)
                    }
                    return
                }
            }
        }
        thread.name = "herdr.client-protocol.read"
        thread.stackSize = 1 << 20
        readThread = thread
        thread.start()
    }

    public func stop() {
        stopFlag.set()
        socket.close()
        readThread = nil
    }

    private func readMessage() throws -> ServerMessage {
        let prefix = try socket.readExactly(Framing.prefixSize)
        let length = try Framing.payloadLength(from: prefix)
        let payload = try socket.readExactly(length)
        return try WireDecoder.serverMessage(from: payload)
    }

    private final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
    }
}
