import HerdrKit
import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: SidebarModel
    let onSelectWorkspace: (String) -> Void
    let onSelectPane: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(model.workspaces) { workspace in
                    workspaceRow(workspace)
                    ForEach(model.agents(inWorkspace: workspace.workspaceId)) { pane in
                        agentRow(pane)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func workspaceRow(_ workspace: WorkspaceInfo) -> some View {
        HStack(spacing: 6) {
            StatusDot(status: workspace.agentStatus)
            Text("\(workspace.number)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(workspace.label)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            workspace.workspaceId == model.focusedWorkspaceId
                ? Color.accentColor.opacity(0.18)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelectWorkspace(workspace.workspaceId) }
    }

    private func agentRow(_ pane: PaneInfo) -> some View {
        HStack(spacing: 6) {
            StatusDot(status: pane.agentStatus)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.agentName(forPane: pane.paneId) ?? "agent")
                    .font(.system(.caption, design: .monospaced))
                Text(pane.terminalTitleStripped ?? pane.cwd)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 26)
        .padding(.trailing, 10)
        .padding(.vertical, 3)
        .background(
            pane.paneId == model.focusedPaneId
                ? Color.accentColor.opacity(0.12)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 4)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelectPane(pane.paneId) }
    }
}

/// Agent status as a colored dot — the whole point of the native sidebar is
/// that this is visible at a glance.
private struct StatusDot: View {
    let status: AgentStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
    }

    private var color: Color {
        switch status {
        case .working: return .green
        case .blocked: return .orange
        case .done: return .blue
        case .idle: return .secondary
        case .unknown: return .secondary.opacity(0.4)
        }
    }
}
