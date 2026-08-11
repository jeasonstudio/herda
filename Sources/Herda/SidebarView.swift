import HerdaKit
import SwiftUI

/// The roster, split the way herdr's own sidebar splits it: spaces on top,
/// agents underneath, a draggable divider between them, each list scrolling on
/// its own.
///
/// The two lists answer different questions and so are kept apart rather than
/// nested. Spaces answers "where am I working"; agents answers "who needs me",
/// spans every space, and can be reordered by urgency — which only works if it
/// is one flat list. That is why an agent row leads with its space rather than
/// its own name.
struct SidebarView: View {
    @ObservedObject var model: SidebarModel
    let theme: Theme
    let onSelectWorkspace: (String) -> Void
    let onSelectPane: (String) -> Void
    let onSelectTheme: (Theme) -> Void

    @AppStorage("sidebar.agentSort") private var storedSort = AgentSort.spaces.rawValue
    @AppStorage("sidebar.splitRatio") private var splitRatio = 0.5
    /// The ratio the current drag started from; nil when no drag is in progress.
    @State private var dragOrigin: Double?
    /// Whether the resize cursor is currently pushed. `NSCursor`'s stack is
    /// global, so an unpaired push would leave the whole window in resize.
    @State private var showingResizeCursor = false

    /// The window has no titlebar of its own, so the traffic lights float over
    /// the top of the sidebar. Nothing may be drawn under them.
    private let trafficLightClearance: CGFloat = 28
    /// Neither section may be squeezed below this; herdr keeps three rows.
    private let minimumSectionHeight: CGFloat = 108

    private var sort: AgentSort { AgentSort(rawValue: storedSort) ?? .spaces }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    spacesSection
                        .frame(height: spacesHeight(in: geometry.size.height))
                    divider(in: geometry.size.height)
                    agentsSection
                }
            }
            footer
        }
        .background(theme.chrome.sidebarBackground.color)
    }

    // MARK: Split

    private func spacesHeight(in total: CGFloat) -> CGFloat {
        guard total > minimumSectionHeight * 2 else { return total / 2 }
        return min(max(total * splitRatio, minimumSectionHeight), total - minimumSectionHeight)
    }

    /// A hairline with a grabbable band around it. The band is real layout rather
    /// than an overlay so the drag target is as tall as it looks clickable.
    private func divider(in total: CGFloat) -> some View {
        Rectangle()
            .fill(theme.chrome.hairline.color)
            .frame(height: 1)
            .frame(height: 9)
            .contentShape(Rectangle())
            .onHover { inside in
                guard inside != showingResizeCursor else { return }
                showingResizeCursor = inside
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .onDisappear {
                guard showingResizeCursor else { return }
                showingResizeCursor = false
                NSCursor.pop()
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let origin = dragOrigin ?? splitRatio
                        dragOrigin = origin
                        guard total > 0 else { return }
                        splitRatio = min(
                            max(origin + value.translation.height / total, 0.1),
                            0.9
                        )
                    }
                    .onEnded { _ in dragOrigin = nil }
            )
    }

    // MARK: Spaces

    private var spacesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("SPACES") { EmptyView() }
                .padding(.top, trafficLightClearance + 12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.workspaces) { workspace in
                        spaceRow(workspace)
                    }
                }
                // Rows are inset from the sidebar edges so a selected row's
                // rounded corners read as a shape, not a clipped band.
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
    }

    private func spaceRow(_ workspace: WorkspaceInfo) -> some View {
        let focused = workspace.workspaceId == model.focusedWorkspaceId
        let agents = model.agentCount(inWorkspace: workspace.workspaceId)
        return HStack(spacing: 8) {
            StatusDot(
                status: model.rollUpStatus(forWorkspace: workspace),
                chrome: theme.chrome
            )
            // Monospaced and right-aligned: this is the number you press to
            // switch, not prose, and it stays in column as it reaches two digits.
            Text("\(workspace.number)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle((focused ? theme.chrome.accent : theme.chrome.overlay1).color)
                .frame(width: 13, alignment: .trailing)
            Text(workspace.label)
                .font(.system(size: 13, weight: focused ? .semibold : .regular))
                .foregroundStyle((focused ? theme.chrome.text : theme.chrome.subtext0).color)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            // The count is what the old nesting used to say: something runs here.
            if agents > 0 {
                Text("\(agents)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.chrome.overlay0.color)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .rowFill(selected: focused, strong: false, chrome: theme.chrome)
        .contentShape(Rectangle())
        .onTapGesture { onSelectWorkspace(workspace.workspaceId) }
    }

    // MARK: Agents

    private var agentsSection: some View {
        let entries = model.agentEntries(sortedBy: sort)
        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader("AGENTS") { agentsControls }
                .padding(.top, 8)
            if entries.isEmpty {
                Text("Nothing running yet. Start an agent in a space.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.chrome.overlay0.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 15)
                    .padding(.top, 2)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(entries) { entry in
                            agentRow(entry)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    /// Live totals, then the order control — herdr's own toggle, under its own
    /// labels. Order is presentation, so it switches here without asking the
    /// server for anything.
    private var agentsControls: some View {
        let waiting = model.agentCount(withStatus: .blocked)
        let working = model.agentCount(withStatus: .working)
        return HStack(spacing: 9) {
            if waiting > 0 { countBadge(waiting, status: .blocked) }
            if working > 0 { countBadge(working, status: .working) }
            Button { storedSort = sort.next.rawValue } label: {
                Text(sort.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(
                        (sort == .priority ? theme.chrome.accent : theme.chrome.overlay0).color
                    )
            }
            .buttonStyle(.plain)
            .help(sort == .priority
                ? "Ordered by what needs you first. Click to group by space."
                : "Grouped by space. Click to order by what needs you first.")
        }
    }

    private func countBadge(_ count: Int, status: AgentStatus) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(theme.chrome.color(for: status).color)
                .frame(width: 5, height: 5)
            Text("\(count)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.chrome.subtext0.color)
        }
        .help(status == .blocked ? "\(count) waiting for you" : "\(count) working")
    }

    private func agentRow(_ entry: AgentEntry) -> some View {
        let selected = entry.pane.paneId == model.focusedPaneId
        return HStack(alignment: .top, spacing: 7) {
            StatusDot(status: entry.pane.agentStatus, chrome: theme.chrome)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                // Where it is, first: this list crosses every space and reorders.
                HStack(spacing: 5) {
                    // Same width and alignment as the spaces list above, so both
                    // lists put their numbers in one column.
                    Text("\(entry.workspaceNumber)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.chrome.overlay0.color)
                        .frame(width: 13, alignment: .trailing)
                    Text(entry.workspaceLabel)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(
                            (selected ? theme.chrome.text : theme.chrome.subtext0).color
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let tab = entry.tabHint {
                        Text("· \(tab)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(theme.chrome.overlay0.color)
                    }
                }
                // Then what it is. Monospaced: it is the command that runs.
                // Indented past the number column so it sits under the label,
                // the way herdr indents its own second agent row.
                Text(entry.agentName)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(theme.chrome.overlay0.color)
                    .lineLimit(1)
                    .padding(.leading, 18)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .rowFill(selected: selected, strong: true, chrome: theme.chrome)
        .contentShape(Rectangle())
        .onTapGesture { onSelectPane(entry.pane.paneId) }
        .help(PathLabel.abbreviate(entry.pane.cwd))
    }

    // MARK: Chrome

    private func sectionHeader<Trailing: View>(
        _ title: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(theme.chrome.overlay0.color)
            Spacer(minLength: 4)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    /// The theme lives here rather than in a toolbar: the window has no titlebar
    /// to put it in, and the sidebar is where the rest of the session's own
    /// settings would go.
    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(theme.chrome.hairline.color)
                .frame(height: 1)

            // The swatch sits outside the menu: a borderless menu draws its own
            // label and indicator, and anything else handed to it as a label is
            // laid out on the menu's terms rather than the sidebar's.
            HStack(spacing: 8) {
                swatch
                Menu {
                    ForEach(ThemeCatalog.all, id: \.self) { candidate in
                        Button { onSelectTheme(candidate) } label: {
                            if candidate == theme {
                                Label(candidate.displayName, systemImage: "checkmark")
                            } else {
                                Text(candidate.displayName)
                            }
                        }
                    }
                } label: {
                    Text(theme.displayName)
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    /// Three of the theme's own colors, in the order the roster uses them:
    /// accent for selection, then the two states that matter most.
    private var swatch: some View {
        HStack(spacing: 2) {
            ForEach([theme.chrome.accent, theme.chrome.yellow, theme.chrome.red], id: \.self) {
                color in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(color.color)
                    .frame(width: 5, height: 11)
            }
        }
    }
}

/// Agent status as a dot: filled while something is happening, hollow when
/// nothing is. `blocked` — the one state that needs a person — also gets a halo,
/// so the eye lands on it before reading the roster.
private struct StatusDot: View {
    let status: AgentStatus
    let chrome: ChromePalette

    var body: some View {
        base
            .frame(width: 7, height: 7)
            .overlay(halo)
            .animation(.easeOut(duration: 0.2), value: status)
    }

    @ViewBuilder private var base: some View {
        switch status {
        case .idle, .unknown:
            Circle().strokeBorder(color, lineWidth: 1.5)
        case .working, .blocked, .done:
            Circle().fill(color)
        }
    }

    @ViewBuilder private var halo: some View {
        if status == .blocked {
            Circle()
                .strokeBorder(color.opacity(0.3), lineWidth: 2.5)
                .frame(width: 13, height: 13)
        }
    }

    private var color: Color {
        let token = chrome.color(for: status)
        return status == .unknown ? token.color.opacity(0.5) : token.color
    }
}

private extension View {
    func rowFill(selected: Bool, strong: Bool, chrome: ChromePalette) -> some View {
        modifier(RowFill(selected: selected, strong: strong, chrome: chrome))
    }
}

/// A row's own surface: accent-tinted when it is the focused one, faintly lit
/// under the pointer, otherwise nothing. Inset from the sidebar edges so the
/// rounded corners read as a shape rather than a clipped band.
///
/// A focused agent gets the strong fill and its space the quiet one: focusing an
/// agent focuses its space too, and two equal fills would read as one selection
/// spanning both lists.
private struct RowFill: ViewModifier {
    let selected: Bool
    let strong: Bool
    let chrome: ChromePalette
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var fill: Color {
        if selected { return chrome.accent.color.opacity(strong ? 0.18 : 0.09) }
        if hovering { return chrome.text.color.opacity(0.06) }
        return .clear
    }
}
