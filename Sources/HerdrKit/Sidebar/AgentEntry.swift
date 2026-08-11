import Foundation

/// One row of the agents section: an agent pane plus the space it belongs to.
///
/// The agents list spans every space, so each row has to say where it is. herdr
/// leads its own agent rows with the workspace for the same reason, and puts the
/// agent's own name underneath (`AgentsSidebarConfig::default`).
public struct AgentEntry: Identifiable, Sendable {
    public let pane: PaneInfo
    public let workspaceNumber: Int
    public let workspaceLabel: String
    /// The agent herdr detected — its kind, such as `claude` or `codex`.
    public let agentName: String
    /// Set only when the space has more than one tab, so an unambiguous tab adds
    /// no noise.
    public let tabHint: String?

    public var id: String { pane.paneId }

    public init(
        pane: PaneInfo,
        workspaceNumber: Int,
        workspaceLabel: String,
        agentName: String,
        tabHint: String?
    ) {
        self.pane = pane
        self.workspaceNumber = workspaceNumber
        self.workspaceLabel = workspaceLabel
        self.agentName = agentName
        self.tabHint = tabHint
    }

    /// `w4:t2` -> `2`. The space is already named on the same row, and herdr
    /// labels an auto-named tab by its number alone. The `t` prefix is dropped
    /// only when what follows is a plain number, so an id shaped some other way
    /// still shows something true.
    static func tabSuffix(_ tabId: String) -> String {
        let scoped = tabId.lastIndex(of: ":").map { String(tabId[tabId.index(after: $0)...])
        } ?? tabId
        guard scoped.hasPrefix("t") else { return scoped }
        let number = scoped.dropFirst()
        return !number.isEmpty && number.allSatisfy(\.isNumber) ? String(number) : scoped
    }
}

/// The two orders herdr offers for its agents panel, under herdr's own names for
/// them: the toggle in its header reads `grouped` or `priority`.
public enum AgentSort: String, Sendable, CaseIterable {
    /// Space order, so one space's agents stay together.
    case spaces
    /// Whatever needs a person soonest, first.
    case priority

    public var label: String {
        switch self {
        case .spaces: return "grouped"
        case .priority: return "priority"
        }
    }

    /// What clicking the header control switches to.
    public var next: AgentSort {
        self == .spaces ? .priority : .spaces
    }
}
