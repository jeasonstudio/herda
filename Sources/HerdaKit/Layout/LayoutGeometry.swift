import CoreGraphics

/// Conversions between herdr's cell coordinates and view pixels, plus the rule
/// that governs zoom.
///
/// All pure functions: the layout's truth belongs to herdr, and this only maps
/// coordinates. Keeping it out of the view is what makes the arithmetic testable
/// without a window — an off-by-one here shifts a whole pane's contents and is
/// very hard to localise once there is a picture on screen.
public enum LayoutGeometry {
    /// A cell rect as a pixel frame.
    ///
    /// `origin` is where the terminal area starts in its container's coordinate
    /// space; the card insets themselves come from `ChromeMetrics`.
    public static func frame(
        for rect: PaneLayoutRect,
        cellSize: CGSize,
        origin: CGPoint = .zero
    ) -> CGRect {
        CGRect(
            x: origin.x + CGFloat(rect.x) * cellSize.width,
            y: origin.y + CGFloat(rect.y) * cellSize.height,
            width: CGFloat(rect.width) * cellSize.width,
            height: CGFloat(rect.height) * cellSize.height
        )
    }

    /// The panes actually being rendered.
    ///
    /// **`snapshot.panes` cannot be used directly when `zoomed` is set.** That
    /// array comes from `tab.layout.panes(area)`, which ignores zoom, so it still
    /// describes the unzoomed layout; herdr meanwhile renders only the focused
    /// pane, filling the whole `area`. Slicing the grid by the reported rects
    /// under zoom would cut a single pane's content into several misplaced
    /// pieces. Measured against a live server: with three panes zoomed, all three
    /// rects were still reported unchanged.
    public static func visiblePanes(in snapshot: PaneLayoutSnapshot) -> [PaneLayoutPane] {
        guard snapshot.zoomed else { return snapshot.panes }
        guard let focused = snapshot.panes.first(where: { $0.paneId == snapshot.focusedPaneId })
        else {
            // The snapshot contradicts itself. Returning it as given beats
            // returning nothing: misplacement is visible, a blank window is not
            // diagnosable.
            return snapshot.panes
        }
        return [PaneLayoutPane(paneId: focused.paneId, focused: true, rect: snapshot.area)]
    }

    /// A pane-local pixel point as whole-grid cell coordinates. The inverse of
    /// `frame(for:)`.
    ///
    /// This offset is not optional: herdr decides which pane a mouse event
    /// belongs to with `pane_at(col, row)` over the whole grid, so a point
    /// measured inside one pane's view has to be shifted by that pane's rect
    /// origin before it goes on the wire.
    public static func gridPosition(
        forPointInPane point: CGPoint,
        paneRect: PaneLayoutRect,
        cellSize: CGSize
    ) -> (column: UInt16, row: UInt16) {
        guard cellSize.width > 0, cellSize.height > 0 else {
            return (paneRect.x, paneRect.y)
        }
        // Clamp before converting: a drag leaving the view hands back negative
        // coordinates, and those would trap on the way into UInt16.
        let localColumn = max(0, Int((point.x / cellSize.width).rounded(.down)))
        let localRow = max(0, Int((point.y / cellSize.height).rounded(.down)))
        let column = min(Int(UInt16.max), Int(paneRect.x) + localColumn)
        let row = min(Int(UInt16.max), Int(paneRect.y) + localRow)
        return (UInt16(column), UInt16(row))
    }
}
