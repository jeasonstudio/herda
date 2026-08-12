import Foundation

/// Normalised geometry for a pane's native scrollbar thumb.
///
/// The numbers come from `PaneInfo.scroll`, which rides along on the session
/// snapshot, rather than from the `PaneScrollChanged` event. That event is a
/// per-pane subscription, and a connection's subscription set cannot be extended
/// once it has started, so following pane creation would mean tearing the
/// connection down and rebuilding it — the same limitation
/// `SidebarModel.mergeStatuses` records for agent status. The snapshot is already
/// polled, so this rides the same trip.
public enum ScrollbarGeometry {
    /// The thumb's start and length as fractions of the track, where 0 is the top.
    /// Returns nil when the content does not exceed one screen, which is when no
    /// scrollbar should be drawn at all.
    public static func thumb(
        offsetFromBottom: Int,
        maxOffsetFromBottom: Int,
        viewportRows: Int
    ) -> (start: Double, length: Double)? {
        guard viewportRows > 0, maxOffsetFromBottom > 0 else { return nil }

        // Total content height is max + viewport: max alone only says how many
        // further rows are reachable above the current view.
        let total = Double(maxOffsetFromBottom + viewportRows)
        let length = Double(viewportRows) / total

        // Clamp: while scrolling, the view updates optimistically and can briefly
        // report an offset past the maximum before the next poll corrects it.
        let offset = min(max(0, offsetFromBottom), maxOffsetFromBottom)
        // offsetFromBottom counts rows away from the bottom; start is measured
        // from the top.
        let start = Double(maxOffsetFromBottom - offset) / total

        return (start: start, length: length)
    }
}
