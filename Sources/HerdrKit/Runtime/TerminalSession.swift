import AppKit
import Foundation

/// Drives the full startup sequence and feeds frames to a view.
///
/// Sequence: locate binary, write config, spawn server, wait for sockets,
/// connect, handshake, hide herdr's own sidebar, then stream frames.
@MainActor
public final class TerminalSession: ObservableObject {
    public enum State: Equatable {
        case idle
        case starting(String)
        case running
        case failed(String)
        case disconnected(String)
    }

    @Published public private(set) var state: State = .idle

    public let view: TerminalGridView

    private let paths: RuntimePaths
    private var runtime: HerdrRuntime?
    private var connection: ClientProtocolConn?
    private var needsSidebarToggle = true

    public init(
        paths: RuntimePaths = .defaultLocation(),
        font: NSFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    ) {
        self.paths = paths
        self.view = TerminalGridView(font: font)
    }

    public func start(viewportSize: CGSize) {
        guard case .idle = state else { return }

        guard let binary = HerdrRuntime.locateBinary() else {
            state = .failed(
                "herdr binary not found. Searched bundle Resources, PATH and ~/.local/bin."
            )
            return
        }
        state = .starting("using \(binary.path)")

        let runtime = HerdrRuntime(paths: paths, binary: binary)
        self.runtime = runtime

        let grid = view.gridSize(for: viewportSize)

        Task.detached { [weak self] in
            do {
                try runtime.start()
                try runtime.waitForSockets(timeout: 10)
                let socket = try UnixSocket(connectingTo: runtime.paths.clientSocket.path)
                let connection = ClientProtocolConn(socket: socket)
                try connection.handshake(
                    columns: grid.columns,
                    rows: grid.rows,
                    cellWidth: 8,
                    cellHeight: 16
                )
                await self?.attach(connection)
            } catch {
                let stderr = runtime.capturedStderr
                await self?.fail(error, stderr: stderr)
            }
        }
    }

    private func attach(_ connection: ClientProtocolConn) {
        self.connection = connection
        state = .running
        log("handshake ok, read loop starting")
        connection.startReadLoop(
            onFrame: { [weak self] frame in
                Task { @MainActor in
                    self?.view.update(frame)
                    self?.hideServerSidebarIfNeeded()
                }
            },
            onShutdown: { [weak self] reason in
                Task { @MainActor in
                    self?.state = .disconnected(reason ?? "server shut down")
                }
            },
            onFailure: { [weak self] error in
                Task { @MainActor in
                    self?.state = .disconnected(String(describing: error))
                }
            }
        )
    }

    /// Hides herdr's own sidebar, since the native UI replaces it.
    ///
    /// Deliberately sent after the first frame rather than right after the
    /// handshake. The server writes `Welcome` *before* registering the client
    /// (see `client_transport.rs`), so input sent immediately on handshake can
    /// reach the main loop before the client exists and be dropped. Receiving a
    /// frame proves registration completed.
    private func hideServerSidebarIfNeeded() {
        guard needsSidebarToggle, let connection else { return }
        needsSidebarToggle = false
        let payload = WireEncoder.functionKey(20, modifiers: [.control, .option])
        let hex = payload.map { String(format: "%02x", $0) }.joined(separator: " ")
        do {
            try connection.send(payload)
            log("sent sidebar toggle: \(hex)")
        } catch {
            log("sidebar toggle FAILED: \(error) bytes=\(hex)")
        }
    }

    /// Appends a line to `<runtime>/prototype.log`. The prototype does not
    /// recover from failures, so being able to see what it actually did is the
    /// only debugging affordance it has.
    private func log(_ message: String) {
        let line = "\(Date().timeIntervalSince1970) \(message)\n"
        let url = paths.root.appendingPathComponent("prototype.log")
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private func fail(_ error: Error, stderr: String) {
        var message = String(describing: error)
        if !stderr.isEmpty {
            message += "\n\nserver stderr:\n" + stderr
        }
        state = .failed(message)
    }

    public func resize(to size: CGSize) {
        guard case .running = state, let connection else { return }
        let grid = view.gridSize(for: size)
        try? connection.send(
            WireEncoder.resize(
                columns: grid.columns,
                rows: grid.rows,
                cellWidth: 8,
                cellHeight: 16
            )
        )
    }

    public func shutdown() {
        if let connection {
            // Best effort: the server also handles an abrupt socket close.
            try? connection.send(WireEncoder.detach())
            connection.stop()
        }
        runtime?.stop()
        connection = nil
        runtime = nil
        state = .idle
    }
}
