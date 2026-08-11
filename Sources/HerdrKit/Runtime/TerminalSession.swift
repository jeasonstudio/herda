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
    @Published public private(set) var theme: Theme = ThemeCatalog.default

    public let view: TerminalGridView

    public let sidebar = SidebarModel()

    private let paths: RuntimePaths
    private var runtime: HerdrRuntime?
    private var connection: ClientProtocolConn?
    private var api: ApiClient?
    private var eventPump: ApiClient.EventPump?

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

        Task.detached { [weak self, paths] in
            do {
                // "Combine both" theme sync: continue with the theme persisted
                // by a previous launch, falling back to the default.
                let resolvedTheme = ThemeCatalog.resolve(name: paths.existingThemeName() ?? "")
                    ?? ThemeCatalog.default
                await MainActor.run {
                    self?.theme = resolvedTheme
                    self?.view.applyTheme(resolvedTheme)
                }

                try runtime.start(themeName: resolvedTheme.configName)
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
        view.onPayload = { [weak self] payload in
            Task { @MainActor in self?.send(payload) }
        }
        log("handshake ok, read loop starting")
        connection.startReadLoop(
            onFrame: { [weak self] frame in
                Task { @MainActor in self?.view.update(frame) }
            },
            onShutdown: { [weak self] reason in
                Task { @MainActor in
                    self?.state = .disconnected(reason ?? "server shut down")
                }
            },
            onClipboard: { [weak self] base64 in
                Task { @MainActor in self?.copyToPasteboard(base64: base64) }
            },
            onFailure: { [weak self] error in
                Task { @MainActor in
                    self?.state = .disconnected(String(describing: error))
                }
            }
        )
        startApiChannel()
    }

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
                        // `[String: Any]` is not Sendable, but the pump reads
                        // events serially on one thread and each `data` is a
                        // fresh, unshared dictionary — safe to hand to the main
                        // actor. The box carries it across the boundary.
                        let box = EventBox(name: name, data: data)
                        Task { @MainActor in self?.sidebar.handle(event: box.name, data: box.data) }
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

    /// herdr forwards OSC 52 as base64. Decode failures are ignored — a bad
    /// clipboard payload is not worth interrupting the session for.
    private func copyToPasteboard(base64: String) {
        guard let data = Data(base64Encoded: base64),
              let text = String(data: data, encoding: .utf8)
        else {
            log("clipboard payload was not valid base64 utf8")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Sends an already-encoded payload. Input failures are logged rather than
    /// surfaced: a dropped keypress must not tear down the session.
    private func send(_ payload: [UInt8]) {
        guard let connection else { return }
        do {
            try connection.send(payload)
        } catch {
            log("input send failed: \(error)")
        }
    }

    public func reportFocus(gained: Bool) {
        guard case .running = state else { return }
        send(WireEncoder.focus(gained: gained))
    }

    /// Switches the active theme: applied to this client's own terminal/sidebar
    /// UI immediately, and persisted into config.toml so herdr's own chrome
    /// matches on its next launch. herdr exposes no channel to retheme a
    /// running server, so an already-spawned embedded process keeps its current
    /// chrome for this session — invisible in practice, since herdr's own
    /// sidebar stays hidden throughout (see `RuntimePaths.configContents`).
    public func setTheme(_ newTheme: Theme) {
        theme = newTheme
        view.applyTheme(newTheme)
        Task.detached { [paths] in
            try? paths.writeConfig(themeName: newTheme.configName)
        }
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
        eventPump?.stop()
        eventPump = nil
        api = nil
        runtime?.stop()
        connection = nil
        runtime = nil
        state = .idle
    }

    /// Carries a non-Sendable event payload across the actor boundary. Safe
    /// because the event pump produces each payload on one thread and never
    /// shares it; see the use site in `startApiChannel`.
    private struct EventBox: @unchecked Sendable {
        let name: String
        let data: [String: Any]
    }
}
