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

    private var panesById: [String: PaneInfo] = [:]

    public init() {}

    public func apply(_ snapshot: SessionSnapshot) {
        workspaces = snapshot.workspaces.sorted { $0.number < $1.number }
        panesById = Dictionary(
            uniqueKeysWithValues: snapshot.panes.map { ($0.paneId, $0) }
        )
        focusedWorkspaceId = snapshot.focusedWorkspaceId
        focusedPaneId = snapshot.focusedPaneId
    }

    public func panes(inWorkspace workspaceId: String) -> [PaneInfo] {
        panesById.values
            .filter { $0.workspaceId == workspaceId }
            .sorted { $0.paneId < $1.paneId }
    }

    /// Panes running a recognised agent — the sidebar's primary content.
    public func agents(inWorkspace workspaceId: String) -> [PaneInfo] {
        panes(inWorkspace: workspaceId).filter { $0.agent != nil }
    }

    public func handle(event: String, data: [String: Any]) {
        switch event {
        case "pane_created", "pane_updated", "pane_focused", "pane_agent_detected":
            guard let pane = decodePane(from: data) else { return }
            panesById[pane.paneId] = pane
            if pane.focused { focusedPaneId = pane.paneId }

        case "pane_closed", "pane_exited":
            guard let paneId = data["pane_id"] as? String else { return }
            panesById.removeValue(forKey: paneId)

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
