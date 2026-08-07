import Darwin
import XCTest
@testable import HerdrKit

final class ClientProtocolConnTests: XCTestCase {
    private func makePair() throws -> (client: UnixSocket, server: UnixSocket) {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        return (UnixSocket(adopting: fds[0]), UnixSocket(adopting: fds[1]))
    }

    private func welcomePayload(version: UInt32, error: String?) -> [UInt8] {
        var out: [UInt8] = [0x00]
        out += Varint.encode(UInt64(version))
        out += Varint.encode(UInt64(0))
        if let error {
            out.append(1)
            out += Varint.encode(UInt64(error.utf8.count))
            out += Array(error.utf8)
        } else {
            out.append(0)
        }
        return out
    }

    func testHandshakeSendsHelloAndAcceptsMatchingVersion() throws {
        let (client, server) = try makePair()
        defer { client.close(); server.close() }

        try server.write(Framing.frame(welcomePayload(version: 19, error: nil)))

        let conn = ClientProtocolConn(socket: client)
        XCTAssertNoThrow(
            try conn.handshake(columns: 100, rows: 30, cellWidth: 8, cellHeight: 16)
        )

        let prefix = try server.readExactly(4)
        let length = try Framing.payloadLength(from: prefix)
        let payload = try server.readExactly(length)
        XCTAssertEqual(
            payload,
            WireEncoder.hello(columns: 100, rows: 30, cellWidth: 8, cellHeight: 16)
        )
    }

    func testHandshakeRejectsVersionMismatch() throws {
        let (client, server) = try makePair()
        defer { client.close(); server.close() }
        try server.write(Framing.frame(welcomePayload(version: 18, error: nil)))

        let conn = ClientProtocolConn(socket: client)
        XCTAssertThrowsError(
            try conn.handshake(columns: 80, rows: 24, cellWidth: 8, cellHeight: 16)
        ) { error in
            guard case .protocolVersionMismatch(let serverVersion, let clientVersion) =
                error as? ClientProtocolConn.Failure
            else {
                return XCTFail("expected protocolVersionMismatch, got \(error)")
            }
            XCTAssertEqual(serverVersion, 18)
            XCTAssertEqual(clientVersion, 19)
        }
    }

    func testHandshakeSurfacesServerError() throws {
        let (client, server) = try makePair()
        defer { client.close(); server.close() }
        try server.write(Framing.frame(welcomePayload(version: 19, error: "no room")))

        let conn = ClientProtocolConn(socket: client)
        XCTAssertThrowsError(
            try conn.handshake(columns: 80, rows: 24, cellWidth: 8, cellHeight: 16)
        ) { error in
            XCTAssertEqual(
                error as? ClientProtocolConn.Failure,
                .handshakeRejected("no room")
            )
        }
    }

    func testHandshakeRejectsNonWelcomeFirstMessage() throws {
        let (client, server) = try makePair()
        defer { client.close(); server.close() }
        try server.write(Framing.frame([0x08]))  // ReloadSoundConfig

        let conn = ClientProtocolConn(socket: client)
        XCTAssertThrowsError(
            try conn.handshake(columns: 80, rows: 24, cellWidth: 8, cellHeight: 16)
        ) { error in
            guard case .unexpectedFirstMessage = error as? ClientProtocolConn.Failure else {
                return XCTFail("expected unexpectedFirstMessage, got \(error)")
            }
        }
    }

    func testReadLoopDeliversFramesAndIgnoresOtherVariants() throws {
        let (client, server) = try makePair()
        defer { client.close(); server.close() }

        var framePayload: [UInt8] = [0x01]
        framePayload += Varint.encode(UInt64(1))     // one cell
        framePayload += Varint.encode(UInt64(1))
        framePayload += [0x41]                       // "A"
        framePayload += Varint.encode(UInt64(0))
        framePayload += Varint.encode(UInt64(0))
        framePayload += Varint.encode(UInt64(0))
        framePayload.append(0)
        framePayload.append(0)
        framePayload += Varint.encode(UInt64(1))     // width
        framePayload += Varint.encode(UInt64(1))     // height
        framePayload.append(0)                       // cursor None
        framePayload += Varint.encode(UInt64(0))
        framePayload += Varint.encode(UInt64(0))

        try server.write(Framing.frame([0x09, 0x01]))   // MouseCapture, must be ignored
        try server.write(Framing.frame(framePayload))

        let received = expectation(description: "frame delivered")
        let box = FrameBox()
        let conn = ClientProtocolConn(socket: client)
        conn.startReadLoop(
            onFrame: { frame in
                box.frame = frame
                received.fulfill()
            },
            onShutdown: { _ in },
            onClipboard: { _ in },
            onFailure: { XCTFail("unexpected failure: \($0)") }
        )
        wait(for: [received], timeout: 5)
        conn.stop()

        XCTAssertEqual(box.frame?.cells.first?.symbol, "A")
    }

    func testReadLoopReportsShutdown() throws {
        let (client, server) = try makePair()
        defer { client.close(); server.close() }

        var payload: [UInt8] = [0x04, 0x01]
        payload += Varint.encode(UInt64(5))
        payload += Array("adieu".utf8)
        try server.write(Framing.frame(payload))

        let notified = expectation(description: "shutdown reported")
        let box = ReasonBox()
        let conn = ClientProtocolConn(socket: client)
        conn.startReadLoop(
            onFrame: { _ in },
            onShutdown: { reason in
                box.reason = reason
                notified.fulfill()
            },
            onClipboard: { _ in },
            onFailure: { _ in }
        )
        wait(for: [notified], timeout: 5)
        conn.stop()

        XCTAssertEqual(box.reason, "adieu")
    }

    private final class FrameBox: @unchecked Sendable {
        var frame: GridFrame?
    }

    private final class ReasonBox: @unchecked Sendable {
        var reason: String?
    }
}
