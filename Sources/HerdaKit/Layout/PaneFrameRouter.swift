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

    /// Whether a layout event describes what is currently on screen.
    ///
    /// `layout_updated` is emitted per (workspace, tab), and the server emits for
    /// tabs that are not showing. Adopting every event paints another tab's layout
    /// onto the current terminal area: observed on a live server as one workspace
    /// interleaving a 2-pane and a 3-pane layout many times a second, each with
    /// its own rects. That thrashing also desynchronised the rects from the frame,
    /// which made `GapProbe` see pane content sitting in a gap column and pinned
    /// the view to its whole-grid fallback.
    ///
    /// The tab id is what is compared, because nothing coarser works. Comparing
    /// workspaces lets a second tab of the same workspace through. Checking that
    /// the layout contains the focused pane also lets it through, since the focused
    /// pane lives in exactly one of the tabs and the other tab's events keep
    /// arriving on their own. Both were tried against a live server and both still
    /// thrashed.
    ///
    /// A nil tab means the session snapshot has not landed yet; accept anything
    /// then, or startup would sit on the fallback indefinitely.
    public static func belongsToCurrentView(
        _ snapshot: PaneLayoutSnapshot,
        activeTabId: String?
    ) -> Bool {
        guard let activeTabId else { return true }
        return snapshot.tabId == activeTabId
    }

    /// Adopts a snapshot. Returns false when it is identical to the current one.
    ///
    /// Observed against a live server: herdr re-emits `layout_updated` roughly
    /// every 100ms even when nothing about the layout changed. Acting on each one
    /// would re-slice every frame and republish the state — redrawing the entire
    /// card grid — for no result, so callers use the return value to skip that.
    @discardableResult
    public mutating func apply(_ snapshot: PaneLayoutSnapshot) -> Bool {
        guard snapshot != self.snapshot else { return false }
        self.snapshot = snapshot
        return true
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
