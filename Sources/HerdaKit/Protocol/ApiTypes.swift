import Foundation

/// Agent lifecycle state as reported by the server.
///
/// Decodes unrecognised values to `.unknown` so a newer server cannot break
/// the sidebar.
public enum AgentStatus: String, Decodable, Sendable {
    case idle
    case working
    case blocked
    case done
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentStatus(rawValue: raw) ?? .unknown
    }

    /// How much this state needs a person, mirroring herdr's own
    /// `pane_attention_priority` (src/workspace/aggregate.rs).
    ///
    /// `done` outranking `working` is the part worth stating: an agent that has
    /// finished and is waiting to be read is holding up the user, while one that
    /// is still working is not. herdr splits the server's single idle state into
    /// these two on a `seen` flag, which the API surfaces as `done` and `idle`.
    public var attentionPriority: Int {
        switch self {
        case .blocked: return 4
        case .done: return 3
        case .working: return 2
        case .idle: return 1
        case .unknown: return 0
        }
    }
}

public struct WorkspaceInfo: Decodable, Identifiable, Sendable {
    public let workspaceId: String
    public let number: Int
    public let label: String
    public let focused: Bool
    public let paneCount: Int
    public let tabCount: Int
    public let agentStatus: AgentStatus

    public var id: String { workspaceId }
}

public struct PaneInfo: Decodable, Identifiable, Sendable {
    public let paneId: String
    public let terminalId: String
    public let workspaceId: String
    public let tabId: String
    public let focused: Bool
    public let cwd: String
    /// Mutable because `pane_agent_status_changed` reports a new status on its
    /// own, without a pane object to replace this one with.
    public var agentStatus: AgentStatus
    /// Absent on panes that are not running a recognised agent.
    public let agent: String?
    public let terminalTitleStripped: String?
    /// Scroll position, absent when the server does not report one. The native
    /// scrollbar reads it from here instead of subscribing per pane — see
    /// `ScrollbarGeometry` for why.
    public let scroll: PaneScrollInfo?

    public var id: String { paneId }
}

/// A pane's scrollback position, as carried on `PaneInfo`.
public struct PaneScrollInfo: Decodable, Equatable, Sendable {
    /// Rows away from the bottom. 0 means pinned to the newest output.
    public let offsetFromBottom: Int
    /// How many further rows are reachable above the current view. 0 means the
    /// content has not exceeded one screen.
    public let maxOffsetFromBottom: Int
    public let viewportRows: Int

    public init(offsetFromBottom: Int, maxOffsetFromBottom: Int, viewportRows: Int) {
        self.offsetFromBottom = offsetFromBottom
        self.maxOffsetFromBottom = maxOffsetFromBottom
        self.viewportRows = viewportRows
    }
}

public struct SessionSnapshot: Decodable, Sendable {
    public let version: String
    /// `protocol` is a Swift keyword, so it is renamed on decode.
    public let protocolVersion: UInt32
    public let focusedWorkspaceId: String?
    public let focusedPaneId: String?
    public let workspaces: [WorkspaceInfo]
    public let panes: [PaneInfo]

    // `.convertFromSnakeCase` runs BEFORE these keys are matched, so the raw
    // values must be the already-camelCased forms — not the snake_case wire
    // names. Only `protocol` needs an override: it is a Swift keyword, and
    // having no underscore the conversion leaves it untouched.
    private enum CodingKeys: String, CodingKey {
        case version
        case protocolVersion = "protocol"
        case focusedWorkspaceId
        case focusedPaneId
        case workspaces
        case panes
    }
}

public struct SessionSnapshotEnvelope: Decodable, Sendable {
    public let snapshot: SessionSnapshot
}

public enum ApiTypes {
    public enum LineKind: Equatable, Sendable {
        case response(id: String)
        case event(name: String)
    }

    public enum Failure: Error, Equatable {
        case unclassifiableLine(String)
    }

    /// Server responses carry `id`; pushed events carry `event` and no `id`.
    /// Both arrive on the same subscription connection.
    public static func classify(line: String) throws -> LineKind {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw Failure.unclassifiableLine(line)
        }
        if let id = object["id"] as? String {
            return .response(id: id)
        }
        if let event = object["event"] as? String {
            return .event(name: event)
        }
        throw Failure.unclassifiableLine(line)
    }

    /// snake_case is the wire convention; `SessionSnapshot` overrides the two
    /// keys this strategy cannot derive.
    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}
