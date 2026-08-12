import AppKit
import Foundation

/// One socket, one pane, one view.
///
/// Handshakes as `TerminalAttach` then sends `ControlTerminal`, which puts the
/// connection in `ClientConnectionMode::TerminalAttach`. From there the server
/// renders only this terminal, at the size this connection declares
/// (`render_terminal_virtual`, `render_stream.rs:368`), and a `Resize` here
/// resizes this pane's PTY and returns before touching the shared grid
/// (`headless.rs:2992`).
///
/// **Never send `InputEvents` on this connection.** That variant has no early
/// return for `TerminalAttach` (`headless.rs:2893`), so it reaches
/// `promote_client_to_foreground`, which has no guard (`:1460`), and the server
/// then relays out every pane inside this one's size. Keys go through the API;
/// only raw `Input` and `AttachScroll` belong here.
@MainActor
public final class PaneConnection {
    public let paneId: String
    public let view: TerminalGridView

    private let socketPath: String
    private var connection: ClientProtocolConn?
    private var resizeDebounce: Task<Void, Never>?
    private var lastReportedGrid: (columns: UInt16, rows: UInt16)?

    /// Called when the server ends this stream — the terminal went away, or
    /// another client took the writable slot.
    public var onEnded: (@MainActor (String) -> Void)?

    public init(paneId: String, socketPath: String, font: TerminalFont) {
        self.paneId = paneId
        self.socketPath = socketPath
        self.view = TerminalGridView(terminalFont: font)
    }

    /// Connects and takes writable control of the pane.
    ///
    /// `takeover: true` deliberately: one terminal allows a single writable owner
    /// (`terminal_attach_owners`), and an instance killed with SIGKILL never sent
    /// `Detach`, so a dead owner can outlive it and lock the pane out. herda is
    /// the only GUI, so there is nothing legitimate to displace.
    public func open(columns: UInt16, rows: UInt16, cellSize: CGSize) throws {
        let socket = try UnixSocket(connectingTo: socketPath)
        let connection = ClientProtocolConn(socket: socket)
        try connection.handshake(
            columns: columns,
            rows: rows,
            cellWidth: UInt32(cellSize.width),
            cellHeight: UInt32(cellSize.height),
            launchMode: .terminalAttach
        )
        try connection.send(WireEncoder.controlTerminal(target: paneId, takeover: true))
        self.connection = connection
        lastReportedGrid = (columns, rows)

        connection.startReadLoop(
            onFrame: { [weak self] frame in
                Task { @MainActor in self?.view.update(frame) }
            },
            onShutdown: { [weak self] _ in
                Task { @MainActor in self?.reportEnded() }
            },
            onClipboard: { base64 in
                Task { @MainActor in PaneConnection.copyToPasteboard(base64: base64) }
            },
            onFailure: { [weak self] _ in
                Task { @MainActor in self?.reportEnded() }
            }
        )
    }

    /// Reports a new grid, coalescing a drag's worth of changes.
    ///
    /// Debounced for the same reason the whole-window resize was: a live drag
    /// emits a geometry change per frame and most land on the same grid, and each
    /// one that reaches the server resizes a PTY, which makes the child
    /// application reflow.
    public func resize(columns: UInt16, rows: UInt16, cellSize: CGSize) {
        if let last = lastReportedGrid, last == (columns, rows) { return }
        resizeDebounce?.cancel()
        resizeDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            self?.sendResize(columns: columns, rows: rows, cellSize: cellSize)
        }
    }

    private func sendResize(columns: UInt16, rows: UInt16, cellSize: CGSize) {
        guard let connection else { return }
        lastReportedGrid = (columns, rows)
        try? connection.send(
            WireEncoder.resize(
                columns: columns,
                rows: rows,
                cellWidth: UInt32(cellSize.width),
                cellHeight: UInt32(cellSize.height)
            )
        )
    }

    /// Raw bytes to this pane's PTY. Only for keys herdr's API cannot name.
    public func send(bytes: [UInt8]) {
        try? connection?.send(WireEncoder.input(bytes))
    }

    /// Scroll, on the channel built for attached clients. The server decides per
    /// pane whether this moves host scrollback or goes to the child application.
    public func scroll(up: Bool, lines: UInt16, column: UInt16?, row: UInt16?) {
        try? connection?.send(
            WireEncoder.attachScroll(
                direction: up ? .up : .down,
                lines: lines,
                column: column,
                row: row,
                modifiers: []
            )
        )
    }

    /// A page key, on the scroll channel rather than as raw bytes.
    ///
    /// `AttachScrollSource::PageKey` carries the original key bytes so the server
    /// can decide per pane whether the key moves host scrollback or is forwarded
    /// to the child application (`wire.rs:400`). Sending the bytes as `Input`
    /// would take that decision away from it.
    public func scrollPageKey(up: Bool, lines: UInt16, bytes: [UInt8]) {
        try? connection?.send(
            WireEncoder.attachScroll(
                direction: up ? .up : .down,
                lines: lines,
                column: nil,
                row: nil,
                modifiers: [],
                pageKeyInput: bytes
            )
        )
    }

    public func close() {
        resizeDebounce?.cancel()
        resizeDebounce = nil
        if let connection {
            // Best effort. Detaching explicitly releases the writable slot, which
            // an abrupt close leaves the server to notice on its own.
            try? connection.send(WireEncoder.detach())
            connection.stop()
        }
        connection = nil
    }

    private func reportEnded() {
        guard connection != nil else { return }
        connection = nil
        onEnded?(paneId)
    }

    /// herdr forwards OSC 52 as base64. Applications that copy still reach the
    /// pasteboard this way, which matters while native selection does not exist.
    private static func copyToPasteboard(base64: String) {
        guard let data = Data(base64Encoded: base64),
              let text = String(data: data, encoding: .utf8)
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
