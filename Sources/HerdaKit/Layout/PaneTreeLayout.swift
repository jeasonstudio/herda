import CoreGraphics

/// Turns a `PaneTree` into point frames, and a point frame into a cell grid.
///
/// The order matters and is the opposite of the first design's. Points come from
/// the window; cells come from the points and the font. Going the other way —
/// letting a character grid decide the layout — is what quantised the gap to one
/// cell, made the corner radius fight the gap for the same 8 points, and moved
/// the whole arrangement whenever the font size changed.
public enum PaneTreeLayout {
    public struct Divider: Equatable, Sendable {
        /// Which split this divides, for `PaneTree.setRatio(_:at:)`.
        public let path: [PaneTree.Step]
        public let orientation: PaneTree.Orientation
        /// What gets drawn: exactly the gap.
        public let rect: CGRect
        /// What accepts a drag. An 8pt strip is hard to grab, so this is widened
        /// on the thin axis only.
        public let hitRect: CGRect
    }

    /// How far past the drawn gap a drag is still accepted, per side.
    private static let hitSlop: CGFloat = 3

    /// One frame per visible pane. Zoom gives the zoomed pane the whole area.
    public static func frames(
        for tree: PaneTree,
        in area: CGRect,
        gap: CGFloat
    ) -> [String: CGRect] {
        guard let root = tree.root else { return [:] }
        if let zoomed = tree.zoomedPaneId { return [zoomed: area] }
        var result: [String: CGRect] = [:]
        walk(root, in: area, gap: gap, path: []) { node, rect, _ in
            if case .pane(let id) = node { result[id] = rect }
        }
        return result
    }

    /// One divider per split. Empty while zoomed — there is nothing to divide.
    public static func dividers(
        for tree: PaneTree,
        in area: CGRect,
        gap: CGFloat
    ) -> [Divider] {
        guard let root = tree.root, tree.zoomedPaneId == nil else { return [] }
        var result: [Divider] = []
        walk(root, in: area, gap: gap, path: []) { node, rect, path in
            guard case .split(let split) = node else { return }
            let (first, _) = halves(of: rect, split: split, gap: gap)
            let strip: CGRect
            switch split.orientation {
            case .horizontal:
                strip = CGRect(x: first.maxX, y: rect.minY, width: gap, height: rect.height)
            case .vertical:
                strip = CGRect(x: rect.minX, y: first.maxY, width: rect.width, height: gap)
            }
            result.append(Divider(
                path: path,
                orientation: split.orientation,
                rect: strip,
                hitRect: split.orientation == .horizontal
                    ? strip.insetBy(dx: -hitSlop, dy: 0)
                    : strip.insetBy(dx: 0, dy: -hitSlop)
            ))
        }
        return result
    }

    /// The cell grid a pane of this size can show.
    ///
    /// Floored: a partial column cannot hold a character, and the remainder is
    /// absorbed by the card's own padding. Never zero — herdr sizes the PTY from
    /// what the client declares, and a zero would propagate into the pane.
    public static func gridSize(
        for rect: CGRect,
        cellSize: CGSize
    ) -> (columns: UInt16, rows: UInt16) {
        let columns = max(1, Int((rect.width / cellSize.width).rounded(.down)))
        let rows = max(1, Int((rect.height / cellSize.height).rounded(.down)))
        return (
            UInt16(min(columns, Int(UInt16.max))),
            UInt16(min(rows, Int(UInt16.max)))
        )
    }

    // MARK: - Recursion

    /// Visits every node with the rect it occupies and the path that reaches it.
    private static func walk(
        _ node: PaneTree.Node,
        in rect: CGRect,
        gap: CGFloat,
        path: [PaneTree.Step],
        _ visit: (PaneTree.Node, CGRect, [PaneTree.Step]) -> Void
    ) {
        visit(node, rect, path)
        guard case .split(let split) = node else { return }
        let (first, second) = halves(of: rect, split: split, gap: gap)
        walk(split.first, in: first, gap: gap, path: path + [.first], visit)
        walk(split.second, in: second, gap: gap, path: path + [.second], visit)
    }

    /// Divides a rect by a split's ratio, spending `gap` between the halves.
    ///
    /// The available length is clamped at zero first. A window can be dragged
    /// narrower than the gap, and a negative width becomes a NaN frame and an
    /// empty screen rather than something merely ugly.
    private static func halves(
        of rect: CGRect,
        split: PaneTree.Split,
        gap: CGFloat
    ) -> (CGRect, CGRect) {
        switch split.orientation {
        case .horizontal:
            let usable = max(0, rect.width - gap)
            let firstWidth = (usable * split.ratio).rounded()
            return (
                CGRect(x: rect.minX, y: rect.minY, width: firstWidth, height: rect.height),
                CGRect(
                    x: rect.minX + firstWidth + gap, y: rect.minY,
                    width: usable - firstWidth, height: rect.height
                )
            )
        case .vertical:
            let usable = max(0, rect.height - gap)
            let firstHeight = (usable * split.ratio).rounded()
            return (
                CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstHeight),
                CGRect(
                    x: rect.minX, y: rect.minY + firstHeight + gap,
                    width: rect.width, height: usable - firstHeight
                )
            )
        }
    }
}
