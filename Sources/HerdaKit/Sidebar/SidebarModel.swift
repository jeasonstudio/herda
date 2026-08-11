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
    // Must be @Published: the agent rows read from it, and a pane event that
    // only mutated a plain property would not repaint the sidebar.
    @Published private var panesById: [String: PaneInfo] = [:]

    /// Agent names learned from `pane_agent_detected`, keyed by pane. Kept apart
    /// from `PaneInfo.agent` because a later `pane_updated` may carry a pane
    /// snapshot with no `agent` field and would otherwise erase the detection.
    @Published private var agentByPaneId: [String: String] = [:]

    public init() {}

    public func apply(_ snapshot: SessionSnapshot) {
        workspaces = snapshot.workspaces.sorted { $0.number < $1.number }
        panesById = Dictionary(
            uniqueKeysWithValues: snapshot.panes.map { ($0.paneId, $0) }
        )
        agentByPaneId = Dictionary(
            uniqueKeysWithValues: snapshot.panes.compactMap { pane in
                pane.agent.map { (pane.paneId, $0) }
            }
        )
        focusedWorkspaceId = snapshot.focusedWorkspaceId
        focusedPaneId = snapshot.focusedPaneId
    }

    /// Refreshes agent status and any newly detected agent name from a fresh
    /// snapshot, leaving structure and focus to the event stream.
    ///
    /// Polled rather than pushed, because status has no session-wide event.
    /// `pane.agent_status_changed` is a per-pane subscription: it takes a
    /// `pane_id` up front, a connection's subscription set is fixed once it
    /// starts — a second `events.subscribe` on the same connection is dropped —
    /// and panes come and go while the app runs. `pane_updated` does carry a
    /// status field, but it only fires when the pane object changes for some
    /// other reason, so a status transition on its own never arrives through it.
    public func mergeStatuses(from panes: [PaneInfo]) {
        for pane in panes {
            if let agent = pane.agent, agentByPaneId[pane.paneId] != agent {
                agentByPaneId[pane.paneId] = agent
            }
            // Only assign on a real change: an unconditional write would
            // republish and repaint the whole roster on every poll.
            guard var known = panesById[pane.paneId],
                  known.agentStatus != pane.agentStatus
            else { continue }
            known.agentStatus = pane.agentStatus
            panesById[pane.paneId] = known
        }
    }

    public func panes(inWorkspace workspaceId: String) -> [PaneInfo] {
        panesById.values
            .filter { $0.workspaceId == workspaceId }
            .sorted { $0.paneId < $1.paneId }
    }

    /// Panes running a recognised agent — the sidebar's primary content. A pane
    /// counts as an agent if either its own snapshot names one or a
    /// `pane_agent_detected` event has been seen for it.
    public func agents(inWorkspace workspaceId: String) -> [PaneInfo] {
        panes(inWorkspace: workspaceId).filter(isAgent)
    }

    /// The one status that stands for a whole workspace: the state among its
    /// agents that most needs a person, the same roll-up herdr's own spaces list
    /// does (`Workspace::aggregate_state`).
    ///
    /// Rolled up here rather than taken from `WorkspaceInfo.agentStatus` so a
    /// space and the agents listed under it can never disagree. The server's own
    /// workspace status is the fallback while a workspace has no known agent.
    public func rollUpStatus(forWorkspace workspace: WorkspaceInfo) -> AgentStatus {
        let statuses = agents(inWorkspace: workspace.workspaceId).map(\.agentStatus)
        return statuses.max { $0.attentionPriority < $1.attentionPriority }
            ?? workspace.agentStatus
    }

    /// How many recognised agents a space holds. The spaces list shows this
    /// because the agents no longer sit under it.
    public func agentCount(inWorkspace workspaceId: String) -> Int {
        agents(inWorkspace: workspaceId).count
    }

    /// Every agent in the session as one flat list, which is what the agents
    /// section shows — see `AgentSort` for the two orders.
    public func agentEntries(sortedBy sort: AgentSort) -> [AgentEntry] {
        // `workspaces` is kept in number order and `agents(inWorkspace:)` in
        // pane order, so building in this order already gives `.spaces`.
        let entries = workspaces.flatMap { workspace in
            agents(inWorkspace: workspace.workspaceId).map { pane in
                AgentEntry(
                    pane: pane,
                    workspaceNumber: workspace.number,
                    workspaceLabel: workspace.label,
                    agentName: agentName(forPane: pane.paneId) ?? "agent",
                    // herdr hides a tab that cannot be ambiguous.
                    tabHint: workspace.tabCount > 1 ? AgentEntry.tabSuffix(pane.tabId) : nil
                )
            }
        }
        guard sort == .priority else { return entries }
        return entries.sorted { left, right in
            let byAttention = (
                left.pane.agentStatus.attentionPriority,
                right.pane.agentStatus.attentionPriority
            )
            if byAttention.0 != byAttention.1 { return byAttention.0 > byAttention.1 }
            // Explicit tie-breaks: `sorted(by:)` makes no stability promise, and
            // rows that reshuffle between identical states are unreadable.
            if left.workspaceNumber != right.workspaceNumber {
                return left.workspaceNumber < right.workspaceNumber
            }
            return left.pane.paneId < right.pane.paneId
        }
    }

    /// Agents in that state across every workspace — what the sidebar header
    /// reports, so a workspace needing attention is visible while scrolled away.
    public func agentCount(withStatus status: AgentStatus) -> Int {
        panesById.values.filter { isAgent($0) && $0.agentStatus == status }.count
    }

    private func isAgent(_ pane: PaneInfo) -> Bool {
        pane.agent != nil || agentByPaneId[pane.paneId] != nil
    }

    /// The agent name for a pane, preferring a detection event over the pane's
    /// own field. `nil` when the pane runs no recognised agent.
    public func agentName(forPane paneId: String) -> String? {
        agentByPaneId[paneId] ?? panesById[paneId]?.agent
    }

    public func handle(event: String, data: [String: Any]) {
        switch event {
        // These carry a full `pane` object.
        case "pane_created", "pane_updated":
            guard let pane = decodePane(from: data) else { return }
            panesById[pane.paneId] = pane
            if let agent = pane.agent { agentByPaneId[pane.paneId] = agent }
            if pane.focused { focusedPaneId = pane.paneId }

        // Flat payload: `{pane_id, workspace_id}`, no `pane` object.
        case "pane_focused":
            guard let paneId = data["pane_id"] as? String else { return }
            focusedPaneId = paneId

        // Flat payload: `{agent, pane_id, workspace_id}`. Records the agent so
        // the pane shows up as an agent row even before a fuller pane update.
        case "pane_agent_detected":
            guard let paneId = data["pane_id"] as? String,
                  let agent = data["agent"] as? String else { return }
            agentByPaneId[paneId] = agent


        case "pane_closed", "pane_exited":
            guard let paneId = data["pane_id"] as? String else { return }
            panesById.removeValue(forKey: paneId)
            agentByPaneId.removeValue(forKey: paneId)

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
                agentByPaneId.removeValue(forKey: paneId)
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
