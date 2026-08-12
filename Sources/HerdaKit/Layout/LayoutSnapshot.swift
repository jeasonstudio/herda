import Foundation

/// herdr's pane layout for one tab: the result of `pane.layout` and the payload
/// of the `layout_updated` event.
///
/// **This is flat, not a tree.** Each entry in `panes` carries its own rect,
/// which is all the card grid needs, and each entry in `splits` carries an id,
/// direction and ratio, which is all the divider drag needs. The recursive form
/// exists only in `layout.export`'s `LayoutDescription.root` and is unused here.
///
/// Rects are in cells, the same coordinate system as `GridFrame` — that is what
/// makes slicing the single grid by rect possible. They are already the content
/// area after herdr's `apply_pane_chrome`, but that equality only holds while
/// `pane_borders` and `pane_scrollbars` are both off: with borders on the rects
/// are not shrunk, and with scrollbars on the rendered area is one column
/// narrower than the rect. `RuntimePaths.configContents` sets all three keys.
public struct PaneLayoutSnapshot: Decodable, Equatable, Sendable {
    public let workspaceId: String
    public let tabId: String
    /// When true, `panes` does **not** describe what is rendered. herdr draws
    /// only the focused pane, filling `area`, while this array still holds the
    /// unzoomed layout. See `LayoutGeometry.visiblePanes`.
    public let zoomed: Bool
    public let area: PaneLayoutRect
    public let focusedPaneId: String
    public let panes: [PaneLayoutPane]
    public let splits: [PaneLayoutSplit]

    public init(
        workspaceId: String,
        tabId: String,
        zoomed: Bool,
        area: PaneLayoutRect,
        focusedPaneId: String,
        panes: [PaneLayoutPane],
        splits: [PaneLayoutSplit]
    ) {
        self.workspaceId = workspaceId
        self.tabId = tabId
        self.zoomed = zoomed
        self.area = area
        self.focusedPaneId = focusedPaneId
        self.panes = panes
        self.splits = splits
    }
}

/// A rectangle in cell coordinates.
public struct PaneLayoutRect: Decodable, Equatable, Sendable {
    public let x: UInt16
    public let y: UInt16
    public let width: UInt16
    public let height: UInt16

    public init(x: UInt16, y: UInt16, width: UInt16, height: UInt16) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct PaneLayoutPane: Decodable, Equatable, Sendable, Identifiable {
    public let paneId: String
    public let focused: Bool
    public let rect: PaneLayoutRect

    public var id: String { paneId }

    public init(paneId: String, focused: Bool, rect: PaneLayoutRect) {
        self.paneId = paneId
        self.focused = focused
        self.rect = rect
    }
}

public struct PaneLayoutSplit: Decodable, Equatable, Sendable, Identifiable {
    public let id: String
    public let direction: SplitDirection
    public let ratio: Double
    /// The whole region this split governs: both children plus the gap between
    /// them. Nested splits nest their rects, so an outer split's rect contains
    /// every inner one — which is why a gap cannot be matched to its split by
    /// containment alone (see `SplitHandles`).
    public let rect: PaneLayoutRect

    public init(id: String, direction: SplitDirection, ratio: Double, rect: PaneLayoutRect) {
        self.id = id
        self.direction = direction
        self.ratio = ratio
        self.rect = rect
    }
}

/// herdr's `SplitDirection`. The name says which side the new pane goes on, not
/// which way the divider runs: `right` is a side-by-side split, `down` is
/// stacked.
public enum SplitDirection: String, Decodable, Sendable {
    case right
    case down
}

/// The envelope `pane.layout` returns.
///
/// Measured against a real server: `result`'s keys are `["layout", "type"]`, so
/// the snapshot sits one level down — decoding `result` straight into
/// `PaneLayoutSnapshot` fails. Same shape as `SessionSnapshotEnvelope`. The
/// `layout_updated` event's `data` is also `{"layout": ...}`, so both paths can
/// share this type.
public struct PaneLayoutEnvelope: Decodable, Sendable {
    public let layout: PaneLayoutSnapshot

    public init(layout: PaneLayoutSnapshot) {
        self.layout = layout
    }
}
