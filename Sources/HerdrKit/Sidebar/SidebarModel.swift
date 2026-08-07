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

    public func panes(inWorkspace workspaceId: String) -> [PaneInfo] {
        panesById.values
            .filter { $0.workspaceId == workspaceId }
            .sorted { $0.paneId < $1.paneId }
    }

    /// Panes running a recognised agent — the sidebar's primary content. A pane
    /// counts as an agent if either its own snapshot names one or a
    /// `pane_agent_detected` event has been seen for it.
    public func agents(inWorkspace workspaceId: String) -> [PaneInfo] {
        panes(inWorkspace: workspaceId).filter {
            $0.agent != nil || agentByPaneId[$0.paneId] != nil
        }
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
