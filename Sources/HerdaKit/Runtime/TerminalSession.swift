import AppKit
import Foundation

/// Owns the session: the server process, the pane tree, one connection per
/// visible pane, and the commands that change the layout.
///
/// There is no app render connection. herda holds geometry; herdr holds pane
/// lifecycle. Nothing here reads herdr's rects, and `layout_updated` is ignored
/// on purpose — see the spec's "拓扑归 herdr，几何归 herda".
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

    /// The split arrangement. `@Published` so the container re-lays out on any
    /// split, close, focus or zoom.
    @Published public private(set) var tree = PaneTree()

    /// One live connection per visible pane, keyed by pane id.
    @Published public private(set) var connections: [String: PaneConnection] = [:]

    public let sidebar = SidebarModel()

    private let font: TerminalFont
    private let paths: RuntimePaths
    private var runtime: HerdrRuntime?
    private var api: ApiClient?
    private var inputQueue = PaneInputQueue()
    private var eventPump: ApiClient.EventPump?
    private var statusPoll: Task<Void, Never>?
    /// The terminal area in points, as last laid out. Connections are sized from
    /// this, so it has to be recorded before any of them open.
    private var area: CGRect = .zero
    /// Where and how the next new pane should land, when herda asked for it.
    ///
    /// Adoption happens in one place — the `pane_created` event — because that
    /// event can arrive before `pane.split` returns. Adopting in both would insert
    /// the pane twice. This carries the requested orientation across, so a split
    /// initiated here still lands the way the menu item said.
    private var pendingSplit: (anchor: String, orientation: PaneTree.Orientation)?

    public init(
        paths: RuntimePaths = .defaultLocation(),
        font: TerminalFont = TerminalFont()
    ) {
        self.paths = paths
        self.font = font
    }

    public var cellSize: CGSize { font.cellSize }

    /// Point frames for the visible panes, and the dividers between them.
    public func frames(in rect: CGRect) -> [String: CGRect] {
        PaneTreeLayout.frames(for: tree, in: rect, gap: ChromeMetrics.paneGap)
    }

    public func dividers(in rect: CGRect) -> [PaneTreeLayout.Divider] {
        PaneTreeLayout.dividers(for: tree, in: rect, gap: ChromeMetrics.paneGap)
    }

    /// The grid a card's frame can actually show.
    ///
    /// Inset by `panePadding` first, because that is what the card takes before
    /// the grid view gets any space. Measuring the card frame instead over-reports
    /// by two columns and one row at the current metrics, and the server sizes the
    /// PTY from what is declared — so the pane would render columns the view has
    /// no room to draw and the right edge would be silently cut.
    private func grid(for frame: CGRect) -> (columns: UInt16, rows: UInt16) {
        PaneTreeLayout.gridSize(
            for: frame.insetBy(
                dx: ChromeMetrics.panePadding,
                dy: ChromeMetrics.panePadding
            ),
            cellSize: font.cellSize
        )
    }

    /// Reports every open connection's grid from the current tree and area.
    private func resizeAll() {
        let frames = frames(in: area)
        for (paneId, connection) in connections {
            let size = grid(for: frames[paneId] ?? area)
            connection.resize(
                columns: size.columns,
                rows: size.rows,
                cellSize: font.cellSize
            )
        }
    }

    // MARK: - Startup

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
        area = CGRect(origin: .zero, size: viewportSize)

        Task.detached { [weak self, paths] in
            do {
                // "Combine both" theme sync: continue with the theme persisted by
                // a previous launch, falling back to the default.
                let resolvedTheme = ThemeCatalog.resolve(name: paths.existingThemeName() ?? "")
                    ?? ThemeCatalog.default
                await MainActor.run { self?.theme = resolvedTheme }

                try runtime.start(themeName: resolvedTheme.configName)
                try runtime.waitForSockets(timeout: 10)
                await MainActor.run { self?.serverIsUp() }
            } catch {
                let stderr = runtime.capturedStderr
                await self?.fail(error, stderr: stderr)
            }
        }
    }

    private func serverIsUp() {
        let api = ApiClient(socketPath: paths.apiSocket.path)
        self.api = api
        inputQueue = PaneInputQueue { [weak self] label, error in
            Task { @MainActor in self?.log("input \(label) failed: \(error)") }
        }
        state = .running
        log("server up, seeding the pane tree")
        startApiChannel(api)
        seedTree(api)
    }

    /// Builds the initial tree from the panes herdr already has.
    ///
    /// A restored session can come back with several panes, so the tree is seeded
    /// with all of them rather than only the focused one — otherwise a restart
    /// would silently drop the arrangement. Their nesting is not recoverable from
    /// `pane.list`, and herdr's own rects are deliberately not read, so they come
    /// back as an even row; the alternative is showing one pane and pretending the
    /// rest are gone.
    private func seedTree(_ api: ApiClient) {
        Task.detached { [weak self] in
            do {
                let snapshot = try api.snapshot()
                // Only the tab on screen. `SessionSnapshot` has no focused tab of
                // its own, so it comes from the focused workspace.
                let activeTab = snapshot.workspaces
                    .first { $0.workspaceId == snapshot.focusedWorkspaceId }?
                    .activeTabId
                var panes = snapshot.panes
                    .filter { activeTab == nil || $0.tabId == activeTab }
                    .sorted { $0.paneId < $1.paneId }
                var focused = snapshot.focusedPaneId

                // An empty session has to be bootstrapped here. herdr creates its
                // default workspace only when a full app client is connected
                // (`headless.rs:3658`), and every herda connection is an attach
                // connection, so on a fresh server there is no workspace and no
                // pane at all until this asks for one.
                if panes.isEmpty {
                    let rootPane = try api.createWorkspace()
                    panes = [rootPane]
                    focused = rootPane.paneId
                }
                await MainActor.run { self?.adopt(panes, focused: focused) }
            } catch {
                await MainActor.run { self?.log("seeding the tree failed: \(error)") }
            }
        }
    }

    private func adopt(_ panes: [PaneInfo], focused: String?) {
        guard let first = panes.first else {
            log("no panes to adopt")
            return
        }
        var tree = PaneTree()
        tree.adopt(paneId: first.paneId)
        for pane in panes.dropFirst() {
            // Split the last adopted pane so the row stays even rather than
            // halving repeatedly off one side.
            tree.split(
                paneId: tree.paneIds.last ?? first.paneId,
                with: pane.paneId,
                orientation: .horizontal,
                ratio: 0.5
            )
        }
        if let focused { tree.focus(paneId: focused) }
        self.tree = tree
        log("adopted \(panes.count) pane(s): \(tree.paneIds.joined(separator: ", "))")
        reconcile()
    }

    // MARK: - Connections

    /// Opens, closes and resizes connections to match the visible panes.
    public func reconcile() {
        let visible = tree.visiblePaneIds
        let frames = frames(in: area)

        for paneId in connections.keys where !visible.contains(paneId) {
            connections[paneId]?.close()
            connections.removeValue(forKey: paneId)
        }

        for paneId in visible {
            let size = grid(for: frames[paneId] ?? area)
            if let existing = connections[paneId] {
                existing.resize(
                    columns: size.columns,
                    rows: size.rows,
                    cellSize: font.cellSize
                )
                continue
            }
            let connection = PaneConnection(
                paneId: paneId,
                socketPath: paths.clientSocket.path,
                font: font
            )
            connection.view.applyTheme(theme)
            connection.view.onInput = { [weak self] input in
                Task { @MainActor in self?.handle(input, from: paneId) }
            }
            connection.onEnded = { [weak self] endedPaneId in
                self?.connectionDropped(endedPaneId)
            }
            do {
                try connection.open(
                    columns: size.columns,
                    rows: size.rows,
                    cellSize: font.cellSize
                )
                connections[paneId] = connection
                log("attached \(paneId) at \(size.columns)x\(size.rows)")
            } catch {
                log("attaching \(paneId) failed: \(error)")
            }
        }
    }

    /// The terminal area changed. Resizes every pane; does not reopen anything.
    public func areaChanged(to rect: CGRect) {
        guard rect != area else { return }
        area = rect
        resizeAll()
    }

    /// A connection ended. The pane is **not** assumed to be gone.
    ///
    /// The two are different events and conflating them was a real bug: a
    /// connection also ends when another client takes the terminal's single
    /// writable slot (`terminal_attach_owners` with `takeover`), and treating that
    /// as a dead pane deleted a card whose process was still running, after which
    /// nothing resized its PTY and it sat at herdr's default 80x24.
    ///
    /// So the pane is asked about rather than assumed either way. Inferring it
    /// from a failed reattach does not work and produced a tight loop: opening a
    /// connection to a dead terminal *succeeds*, and the server only rejects it
    /// afterwards with an asynchronous `ServerShutdown`, which drops the
    /// connection, which reattaches. Observed spinning through six panes that no
    /// longer existed, several times a second.
    private func connectionDropped(_ paneId: String) {
        guard connections.removeValue(forKey: paneId) != nil else { return }
        guard let api else { return }
        Task.detached { [weak self] in
            // Delayed so a pane that keeps refusing the connection retries slowly
            // instead of spinning. Invisible for a genuine reconnect.
            try? await Task.sleep(for: .milliseconds(250))
            let exists = api.paneExists(paneId)
            await MainActor.run {
                guard let self else { return }
                guard exists else {
                    self.log("connection to \(paneId) dropped and the pane is gone")
                    self.paneRemoved(paneId)
                    return
                }
                guard self.tree.paneIds.contains(paneId) else { return }
                self.log("connection to \(paneId) dropped; reattaching")
                self.reconcile()
            }
        }
    }

    /// The pane itself is gone, per herdr.
    private func paneRemoved(_ paneId: String) {
        log("pane \(paneId) removed")
        connections[paneId]?.close()
        connections.removeValue(forKey: paneId)
        tree.close(paneId: paneId)
        if tree.root == nil {
            state = .disconnected("the last pane closed")
            return
        }
        reconcile()
    }

    // MARK: - Input

    private func handle(_ input: TerminalInput, from paneId: String) {
        // Clicking a pane focuses it. Done here rather than in the view so the
        // tree and herdr's own focus stay in step, and done before routing so the
        // click that focuses also lands in the right pane.
        if case .mouse(let kind, _, _, _) = input, case .down = kind {
            focus(paneId: paneId)
        }

        guard let api else { return }
        let route = PaneInputRouter.route(input)
        let connection = connections[paneId]

        switch route {
        case .keys(let names):
            inputQueue.submit("keys \(names.joined(separator: " ")) -> \(paneId)") {
                try api.sendKeys(paneId, keys: names)
            }
        case .text(let text):
            inputQueue.submit("text \(text.count) chars -> \(paneId)") {
                try api.sendText(paneId, text: text)
            }
        case .bytes(let bytes):
            // Through the same queue as the API sends, even though this is a
            // different socket: two independent streams would let Home overtake
            // the "abc" typed before it.
            inputQueue.submit("bytes \(bytes.count) -> \(paneId)") {
                Task { @MainActor in connection?.send(bytes: bytes) }
            }
        case .scroll(let up, let lines, let pageKeyInput):
            let column = scrollColumn(of: input)
            inputQueue.submit("scroll \(up ? "up" : "down") -> \(paneId)") {
                Task { @MainActor in
                    if let pageKeyInput {
                        connection?.scrollPageKey(
                            up: up, lines: lines, bytes: pageKeyInput
                        )
                    } else {
                        connection?.scroll(
                            up: up, lines: lines,
                            column: column?.column, row: column?.row
                        )
                    }
                }
            }
        case .drop:
            break
        }
    }

    private func scrollColumn(of input: TerminalInput) -> (column: UInt16, row: UInt16)? {
        guard case .mouse(_, let column, let row, _) = input else { return nil }
        return (column, row)
    }

    // MARK: - Commands

    public func splitFocused(_ direction: SplitDirection) {
        guard let api, let focused = tree.focusedPaneId else { return }
        pendingSplit = (focused, direction == .right ? .horizontal : .vertical)
        Task.detached { [weak self] in
            do {
                try api.splitPane(focused, direction: direction)
            } catch {
                await MainActor.run {
                    self?.pendingSplit = nil
                    self?.log("split failed: \(error)")
                }
            }
        }
    }

    public func closeFocused() {
        guard let api, let focused = tree.focusedPaneId else { return }
        // The tree is updated when herdr confirms, not optimistically: a close
        // that fails would otherwise leave a pane on screen that the tree thinks
        // is gone, with no connection behind it.
        Task.detached { [weak self] in
            do {
                try api.closePane(focused)
            } catch {
                await MainActor.run { self?.log("close failed: \(error)") }
            }
        }
    }

    public func focus(paneId: String) {
        guard tree.focusedPaneId != paneId else { return }
        tree.focus(paneId: paneId)
        connections[paneId]?.view.window?.makeFirstResponder(connections[paneId]?.view)
        guard let api else { return }
        // Mirrored to herdr so the sidebar and agent tracking agree with the
        // window. herdr's own focus does not drive anything here.
        Task.detached { [weak self] in
            do {
                try api.focusPane(paneId)
            } catch {
                await MainActor.run { self?.log("focus pane failed: \(error)") }
            }
        }
    }

    public func focusNeighbour(_ direction: PaneTree.Direction) {
        guard let focused = tree.focusedPaneId,
              let neighbour = tree.neighbour(of: focused, direction)
        else { return }
        focus(paneId: neighbour)
    }

    /// Copies the focused pane's selection. Nil-safe: with nothing selected this
    /// does nothing, which is what Copy does everywhere else on the platform.
    public func copySelection() {
        guard let focused = tree.focusedPaneId,
              let text = connections[focused]?.view.selectedText
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Pastes into the focused pane.
    public func pasteIntoFocused() {
        guard let focused = tree.focusedPaneId else { return }
        connections[focused]?.view.paste()
    }

    public func selectAllInFocused() {
        guard let focused = tree.focusedPaneId else { return }
        connections[focused]?.view.selectAll()
    }

    /// Whether the focused pane has something to copy, for menu validation.
    public var hasSelection: Bool {
        guard let focused = tree.focusedPaneId else { return false }
        return connections[focused]?.view.selectedText != nil
    }

    public func toggleZoomFocused() {
        guard let focused = tree.focusedPaneId else { return }
        tree.toggleZoom(paneId: focused)
        reconcile()
    }

    public func setRatio(_ ratio: Double, at path: [PaneTree.Step]) {
        tree.setRatio(ratio, at: path)
        resizeAll()
    }

    /// Returns keyboard focus to the focused pane. The sidebar's SwiftUI controls
    /// take first responder when clicked and never hand it back.
    public func focusTerminal() {
        guard let focused = tree.focusedPaneId, let view = connections[focused]?.view else {
            return
        }
        view.window?.makeFirstResponder(view)
    }

    // MARK: - API channel

    /// Deliberately independent of the pane connections: a stalled sidebar must
    /// not affect the terminals, and vice versa.
    private func startApiChannel(_ api: ApiClient) {
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
                        Task { @MainActor in self?.handle(event: box.name, data: box.data) }
                    },
                    onFailure: { error in
                        Task { @MainActor in self?.log("event pump stopped: \(error)") }
                    }
                )
            } catch {
                await MainActor.run { self?.log("api channel failed: \(error)") }
            }
        }
        startStatusPolling(api)
    }

    /// `layout_updated` is ignored: herda owns geometry, and adopting herdr's
    /// rects is exactly what the first design did.
    private func handle(event name: String, data: [String: Any]) {
        switch name {
        case "pane_closed", "pane_exited":
            if let paneId = data["pane_id"] as? String, tree.paneIds.contains(paneId) {
                paneRemoved(paneId)
            }
        case "pane_created":
            adoptIfUnknown(data)
        case "layout_updated":
            return
        default:
            break
        }
        sidebar.handle(event: name, data: data)
    }

    /// Takes in a pane herda did not create.
    ///
    /// herdr is built to let something inside a pane split it — an agent calling
    /// `pane.split` over the API is a normal thing to do. Since `layout_updated`
    /// is ignored here, this event is the only notice herda gets, and without it
    /// such a pane exists in the session with no card and no connection: invisible
    /// and unreachable.
    private func adoptIfUnknown(_ data: [String: Any]) {
        guard let pane = data["pane"] as? [String: Any],
              let paneId = pane["pane_id"] as? String,
              !tree.paneIds.contains(paneId)
        else { return }
        // Only the tab on screen; another tab's panes are not ours to show.
        if let tabId = pane["tab_id"] as? String, let active = sidebar.activeTabId,
           tabId != active
        {
            return
        }
        let requested = pendingSplit
        pendingSplit = nil

        guard let anchor = requested?.anchor ?? tree.focusedPaneId else {
            tree.adopt(paneId: paneId)
            log("adopted \(paneId) as the first pane")
            reconcile()
            return
        }
        // Without a request to honour — a pane something else created — split the
        // anchor's long way, so a wide card divides into columns.
        let orientation = requested?.orientation ?? {
            let frame = frames(in: area)[anchor] ?? area
            return frame.width >= frame.height ? .horizontal : .vertical
        }()
        tree.split(paneId: anchor, with: paneId, orientation: orientation)
        log("adopted \(paneId) (\(requested == nil ? "external" : "requested"))")
        reconcile()
    }

    /// Keeps agent status current. Deliberately a poll: the API has no
    /// session-wide agent-status event, only a per-pane subscription that cannot
    /// be extended once a connection's subscription set has started (see
    /// `SidebarModel.mergeStatuses`).
    private func startStatusPolling(_ api: ApiClient) {
        statusPoll?.cancel()
        statusPoll = Task.detached { [weak self] in
            var reportedFailure = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1500))
                guard !Task.isCancelled else { return }
                do {
                    let panes = try api.snapshot().panes
                    reportedFailure = false
                    await MainActor.run { self?.sidebar.mergeStatuses(from: panes) }
                } catch {
                    // Logged once per outage: at this interval, logging every
                    // failure would bury everything else in the file.
                    guard !reportedFailure else { continue }
                    reportedFailure = true
                    await MainActor.run { self?.log("status poll failed: \(error)") }
                }
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

    // MARK: - Theme, logging, teardown

    public func setTheme(_ newTheme: Theme) {
        theme = newTheme
        for connection in connections.values { connection.view.applyTheme(newTheme) }
        Task.detached { [paths] in
            try? paths.writeConfig(themeName: newTheme.configName)
        }
    }

    /// Appends a line to `<runtime>/herda.log`. The prototype does not recover
    /// from failures, so being able to see what it actually did is the only
    /// debugging affordance it has.
    private func log(_ message: String) {
        let line = "\(Date().timeIntervalSince1970) \(message)\n"
        let url = paths.root.appendingPathComponent("herda.log")
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

    public func shutdown() {
        for connection in connections.values { connection.close() }
        connections.removeAll()
        statusPoll?.cancel()
        statusPoll = nil
        eventPump?.stop()
        eventPump = nil
        api = nil
        runtime?.stop()
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
