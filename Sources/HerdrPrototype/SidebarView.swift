import HerdrKit
import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: SidebarModel
    let theme: Theme
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
            StatusDot(status: workspace.agentStatus, chrome: theme.chrome)
            Text("\(workspace.number)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(theme.chrome.subtext0.color)
            Text(workspace.label)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(theme.chrome.text.color)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            workspace.workspaceId == model.focusedWorkspaceId
                ? theme.chrome.accent.color.opacity(0.18)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelectWorkspace(workspace.workspaceId) }
    }

    private func agentRow(_ pane: PaneInfo) -> some View {
        HStack(spacing: 6) {
            StatusDot(status: pane.agentStatus, chrome: theme.chrome)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.agentName(forPane: pane.paneId) ?? "agent")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(theme.chrome.text.color)
                Text(pane.terminalTitleStripped ?? pane.cwd)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.chrome.subtext0.color)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 26)
        .padding(.trailing, 10)
        .padding(.vertical, 3)
        .background(
            pane.paneId == model.focusedPaneId
                ? theme.chrome.accent.color.opacity(0.12)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 4)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelectPane(pane.paneId) }
    }
}

/// Agent status as a colored dot. Colors mirror herdr's own semantics for
/// these chrome tokens (doc comments on `Palette` in src/app/state.rs):
/// yellow is "working/running", red is "needs attention/blocked", green is
/// "done/idle".
private struct StatusDot: View {
    let status: AgentStatus
    let chrome: ChromePalette

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
    }

    private var color: Color {
        switch status {
        case .working: return chrome.yellow.color
        case .blocked: return chrome.red.color
        case .done: return chrome.green.color
        case .idle: return chrome.overlay0.color
        case .unknown: return chrome.overlay0.color.opacity(0.4)
        }
    }
}
