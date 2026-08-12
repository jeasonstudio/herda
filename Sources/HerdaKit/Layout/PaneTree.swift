import Foundation

/// The split topology herda owns.
///
/// herdr owns which panes exist — their PTYs, session persistence, agent
/// detection, `herdr pane read` interop. This owns where they are. The two
/// deliberately disagree: nothing renders herdr's rects, and once a pane is
/// attached herdr's layout engine will not resize it either
/// (`direct_attach_resize_locks`, `headless.rs:2660`).
///
/// A binary tree, with splits addressed by **path** rather than by id. Paths need
/// no bookkeeping as panes come and go, and a divider already knows its path from
/// the layout pass — an id would have to be minted, stored and garbage-collected
/// to say the same thing.
public struct PaneTree: Equatable, Sendable {
    public indirect enum Node: Equatable, Sendable {
        case pane(String)
        case split(Split)
    }

    public struct Split: Equatable, Sendable {
        /// `.horizontal` divides left from right; `.vertical` top from bottom.
        public var orientation: Orientation
        /// The first child's share of the available length.
        public var ratio: Double
        public var first: Node
        public var second: Node
    }

    public enum Orientation: Equatable, Sendable {
        case horizontal
        case vertical
    }

    /// Which child a path step descends into.
    public enum Step: Equatable, Sendable {
        case first
        case second
    }

    public enum Direction: Equatable, Sendable {
        case left, right, up, down

        var orientation: Orientation {
            switch self {
            case .left, .right: return .horizontal
            case .up, .down: return .vertical
            }
        }

        /// Which child of a matching split this direction moves toward.
        var towards: Step {
            switch self {
            case .left, .up: return .first
            case .right, .down: return .second
            }
        }
    }

    /// A ratio of 0 would ask its pane for zero columns, and herdr sizes the PTY
    /// from whatever the client declares.
    public static let ratioBounds = 0.1 ... 0.9

    public private(set) var root: Node?
    public private(set) var focusedPaneId: String?
    public private(set) var zoomedPaneId: String?

    public init() {}

    // MARK: - Reading

    /// Every pane, left to right then top to bottom.
    public var paneIds: [String] { root.map(Self.leaves) ?? [] }

    /// The panes to render. Zoom collapses to one without changing the tree, so
    /// leaving zoom restores the previous arrangement exactly.
    public var visiblePaneIds: [String] {
        if let zoomedPaneId { return [zoomedPaneId] }
        return paneIds
    }

    public func ratio(at path: [Step]) -> Double? {
        guard case .split(let split)? = Self.node(at: path, in: root) else { return nil }
        return split.ratio
    }

    // MARK: - Mutating

    /// Takes the first pane. Ignored once a root exists — later panes arrive
    /// through `split`.
    public mutating func adopt(paneId: String) {
        guard root == nil else { return }
        root = .pane(paneId)
        focusedPaneId = paneId
    }

    /// Replaces `paneId`'s leaf with a split holding it and `newPaneId`.
    ///
    /// The new pane goes second so that a split right puts it on the right and a
    /// split down puts it below, which is what the menu items promise. Focus
    /// follows it, matching every other terminal multiplexer.
    public mutating func split(
        paneId: String,
        with newPaneId: String,
        orientation: Orientation,
        ratio: Double = 0.5
    ) {
        guard let root, Self.leaves(root).contains(paneId) else { return }
        // Pane ids are unique, so a second insertion of the same one is a bug
        // upstream — and it would put the pane on screen twice with two
        // connections fighting over one PTY.
        guard !Self.leaves(root).contains(newPaneId) else { return }
        self.root = Self.replacing(paneId, in: root) { existing in
            .split(Split(
                orientation: orientation,
                ratio: ratio.clamped(to: Self.ratioBounds),
                first: existing,
                second: .pane(newPaneId)
            ))
        }
        focusedPaneId = newPaneId
    }

    /// Removes a pane, collapsing its parent split into the sibling.
    ///
    /// Collapsing matters: a split left holding one child would keep taking a
    /// gap's worth of space and offering a divider that cannot move.
    public mutating func close(paneId: String) {
        guard let root, Self.leaves(root).contains(paneId) else { return }

        // Cleared before the tree changes, since afterwards there is no sibling
        // to look up.
        if zoomedPaneId == paneId { zoomedPaneId = nil }
        let successor = Self.sibling(of: paneId, in: root).flatMap { Self.leaves($0).first }

        self.root = Self.removing(paneId, from: root)
        if focusedPaneId == paneId || focusedPaneId == nil {
            focusedPaneId = successor ?? self.root.flatMap { Self.leaves($0).first }
        }
        if self.root == nil { focusedPaneId = nil }
    }

    public mutating func focus(paneId: String) {
        guard paneIds.contains(paneId) else { return }
        focusedPaneId = paneId
    }

    public mutating func toggleZoom(paneId: String) {
        guard paneIds.contains(paneId) else { return }
        zoomedPaneId = zoomedPaneId == paneId ? nil : paneId
    }

    public mutating func setRatio(_ ratio: Double, at path: [Step]) {
        guard let root else { return }
        self.root = Self.updatingSplit(at: path, in: root) { split in
            split.ratio = ratio.clamped(to: Self.ratioBounds)
        }
    }

    // MARK: - Navigation

    /// The pane in that direction, resolved on the tree rather than on geometry.
    ///
    /// Walks up to the nearest ancestor that splits along the right axis and
    /// whose subtree the move is heading out of, then takes the first leaf on the
    /// other side. Geometry would need a hit test and would disagree with the
    /// tree whenever a gap fell under the probe point.
    public func neighbour(of paneId: String, _ direction: Direction) -> String? {
        guard let root, let path = Self.path(to: paneId, in: root) else { return nil }

        var depth = path.count
        while depth > 0 {
            let ancestorPath = Array(path.prefix(depth - 1))
            let step = path[depth - 1]
            if case .split(let split)? = Self.node(at: ancestorPath, in: root),
               split.orientation == direction.orientation,
               step != direction.towards
            {
                let target = direction.towards == .first ? split.first : split.second
                // The leaf nearest the boundary being crossed: moving right or
                // down lands on the other side's first leaf, moving left or up
                // on its last.
                let leaves = Self.leaves(target)
                return direction.towards == .first ? leaves.last : leaves.first
            }
            depth -= 1
        }
        return nil
    }

    // MARK: - Node helpers

    private static func leaves(_ node: Node) -> [String] {
        switch node {
        case .pane(let id): return [id]
        case .split(let split): return leaves(split.first) + leaves(split.second)
        }
    }

    private static func node(at path: [Step], in node: Node?) -> Node? {
        guard let node else { return nil }
        guard let step = path.first else { return node }
        guard case .split(let split) = node else { return nil }
        return self.node(
            at: Array(path.dropFirst()),
            in: step == .first ? split.first : split.second
        )
    }

    private static func path(to paneId: String, in node: Node) -> [Step]? {
        switch node {
        case .pane(let id):
            return id == paneId ? [] : nil
        case .split(let split):
            if let found = path(to: paneId, in: split.first) { return [.first] + found }
            if let found = path(to: paneId, in: split.second) { return [.second] + found }
            return nil
        }
    }

    private static func replacing(
        _ paneId: String,
        in node: Node,
        with transform: (Node) -> Node
    ) -> Node {
        switch node {
        case .pane(let id):
            return id == paneId ? transform(node) : node
        case .split(var split):
            split.first = replacing(paneId, in: split.first, with: transform)
            split.second = replacing(paneId, in: split.second, with: transform)
            return .split(split)
        }
    }

    private static func removing(_ paneId: String, from node: Node) -> Node? {
        switch node {
        case .pane(let id):
            return id == paneId ? nil : node
        case .split(var split):
            if let first = removing(paneId, from: split.first) {
                guard let second = removing(paneId, from: split.second) else { return first }
                split.first = first
                split.second = second
                return .split(split)
            }
            return removing(paneId, from: split.second)
        }
    }

    /// The subtree on the other side of `paneId`'s parent split.
    private static func sibling(of paneId: String, in node: Node) -> Node? {
        guard case .split(let split) = node else { return nil }
        if case .pane(let id) = split.first, id == paneId { return split.second }
        if case .pane(let id) = split.second, id == paneId { return split.first }
        return sibling(of: paneId, in: split.first) ?? sibling(of: paneId, in: split.second)
    }

    private static func updatingSplit(
        at path: [Step],
        in node: Node,
        _ edit: (inout Split) -> Void
    ) -> Node {
        guard case .split(var split) = node else { return node }
        guard let step = path.first else {
            edit(&split)
            return .split(split)
        }
        let rest = Array(path.dropFirst())
        if step == .first {
            split.first = updatingSplit(at: rest, in: split.first, edit)
        } else {
            split.second = updatingSplit(at: rest, in: split.second, edit)
        }
        return .split(split)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
