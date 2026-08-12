import Foundation

/// Distributes one whole-grid frame across the panes.
///
/// Kept separate from `TerminalSession` so the routing rules are testable without
/// a server or a window: zoom collapsing to the focused pane, falling back to
/// whole-grid rendering when something crosses a pane boundary, and refusing to
/// guess a layout before `pane.layout` has answered.
public struct PaneFrameRouter: Sendable {
    private var snapshot: PaneLayoutSnapshot?

    public init() {}

    public mutating func apply(_ snapshot: PaneLayoutSnapshot) {
        self.snapshot = snapshot
    }

    public var focusedPaneId: String? { snapshot?.focusedPaneId }

    /// The panes to show, in the order herdr reported them.
    public var visiblePanes: [PaneLayoutPane] {
        guard let snapshot else { return [] }
        return LayoutGeometry.visiblePanes(in: snapshot)
    }

    public var paneIds: [String] { visiblePanes.map(\.paneId) }

    /// Each pane's subframe. Empty until a layout arrives — the first frame can
    /// come in before `pane.layout` answers, and guessing a layout there would
    /// flash a wrong picture before correcting itself.
    public func slices(for frame: GridFrame) -> [String: GridFrame] {
        var result: [String: GridFrame] = [:]
        for pane in visiblePanes {
            result[pane.paneId] = FrameSlice.slice(frame, to: pane.rect)
        }
        return result
    }

    /// Whether to abandon the card grid and draw the whole frame instead.
    ///
    /// Two cases: no layout yet (do not guess), and content crossing a pane
    /// boundary — a modal opened with a prefix key, which slicing would cut at the
    /// card gap, losing whatever sits in the gap column.
    public func shouldRenderWholeGrid(_ frame: GridFrame) -> Bool {
        let panes = visiblePanes
        guard !panes.isEmpty else { return true }
        return GapProbe.hasContentOutsidePanes(frame, panes: panes.map(\.rect))
    }
}
