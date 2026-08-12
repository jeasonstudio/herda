import XCTest
@testable import HerdaKit

final class LayoutSnapshotTests: XCTestCase {
    /// A hand-written two-pane horizontal split with rects already shrunk by
    /// `pane_gaps`: the left pane covers 0..<39 (40 minus one cell) and the right
    /// one starts at 40, leaving column 39 as the gap.
    private let handWritten = """
    {
      "workspace_id": "w1",
      "tab_id": "w1:t1",
      "zoomed": false,
      "area": { "x": 0, "y": 0, "width": 80, "height": 24 },
      "focused_pane_id": "w1:p1",
      "panes": [
        { "pane_id": "w1:p1", "focused": true,  "rect": { "x": 0,  "y": 0, "width": 39, "height": 24 } },
        { "pane_id": "w1:p2", "focused": false, "rect": { "x": 40, "y": 0, "width": 40, "height": 24 } }
      ],
      "splits": [
        { "id": "s0", "direction": "right", "ratio": 0.5,
          "rect": { "x": 0, "y": 0, "width": 80, "height": 24 } }
      ]
    }
    """

    /// A `pane.layout` response captured verbatim from a real server: three
    /// panes, two levels of split. Re-capture with
    ///
    ///     herdr pane layout --current
    ///
    /// against herda's own runtime (see docs/superpowers/plans for the isolation
    /// environment). Per CLAUDE.md the contents come from bytes on the wire rather
    /// than from inferring a layout off the schema — which is exactly what exposed
    /// the `layout` wrapper inside `result`, and the containment relationship
    /// between nested split rects.
    private let realServerResponse = """
    {"id":"cli:pane:layout","result":{"layout":{\
    "area":{"height":40,"width":114,"x":0,"y":0},\
    "focused_pane_id":"w1:p1",\
    "panes":[\
    {"focused":true,"pane_id":"w1:p1","rect":{"height":40,"width":34,"x":0,"y":0}},\
    {"focused":false,"pane_id":"w1:p3","rect":{"height":40,"width":33,"x":35,"y":0}},\
    {"focused":false,"pane_id":"w1:p2","rect":{"height":40,"width":45,"x":69,"y":0}}],\
    "splits":[\
    {"direction":"right","id":"split_0_root","ratio":0.6052632,\
    "rect":{"height":40,"width":114,"x":0,"y":0}},\
    {"direction":"right","id":"split_1_0","ratio":0.5,\
    "rect":{"height":40,"width":69,"x":0,"y":0}}],\
    "tab_id":"w1:t1","workspace_id":"w1","zoomed":false\
    },"type":"pane_layout"}}
    """

    // MARK: Hand-written shape

    func testDecodesPanesAndSplits() throws {
        let snapshot = try ApiTypes.decoder.decode(
            PaneLayoutSnapshot.self,
            from: try XCTUnwrap(handWritten.data(using: .utf8))
        )

        XCTAssertEqual(snapshot.workspaceId, "w1")
        XCTAssertEqual(snapshot.tabId, "w1:t1")
        XCTAssertFalse(snapshot.zoomed)
        XCTAssertEqual(snapshot.focusedPaneId, "w1:p1")
        XCTAssertEqual(snapshot.area, PaneLayoutRect(x: 0, y: 0, width: 80, height: 24))

        XCTAssertEqual(snapshot.panes.count, 2)
        XCTAssertEqual(snapshot.panes[0].paneId, "w1:p1")
        XCTAssertTrue(snapshot.panes[0].focused)
        XCTAssertEqual(snapshot.panes[0].rect, PaneLayoutRect(x: 0, y: 0, width: 39, height: 24))
        XCTAssertEqual(snapshot.panes[1].rect, PaneLayoutRect(x: 40, y: 0, width: 40, height: 24))

        XCTAssertEqual(snapshot.splits.count, 1)
        XCTAssertEqual(snapshot.splits[0].id, "s0")
        XCTAssertEqual(snapshot.splits[0].direction, .right)
        XCTAssertEqual(snapshot.splits[0].ratio, 0.5, accuracy: 0.0001)
    }

    func testGapBetweenPanesIsExactlyOneCell() throws {
        // pane_gaps shrinks each pane with a neighbour by one cell. This pins the
        // premise that a gap exists at all — the native card border is drawn in
        // it, so losing the gap would leave nowhere to draw.
        let snapshot = try ApiTypes.decoder.decode(
            PaneLayoutSnapshot.self,
            from: try XCTUnwrap(handWritten.data(using: .utf8))
        )
        let left = snapshot.panes[0].rect
        let right = snapshot.panes[1].rect
        XCTAssertEqual(Int(right.x) - (Int(left.x) + Int(left.width)), 1)
    }

    // MARK: Captured response

    /// Pulls the snapshot out of the raw response. This path is itself under
    /// test: `result`'s keys are `["layout", "type"]`, with the snapshot one
    /// level down.
    private func decodeRealServerSnapshot() throws -> PaneLayoutSnapshot {
        let response = try JSONSerialization.jsonObject(
            with: try XCTUnwrap(realServerResponse.data(using: .utf8))
        )
        let result = try XCTUnwrap((response as? [String: Any])?["result"] as? [String: Any])
        let layout = try XCTUnwrap(result["layout"])
        return try ApiTypes.decoder.decode(
            PaneLayoutSnapshot.self,
            from: try JSONSerialization.data(withJSONObject: layout)
        )
    }

    func testDecodesRealServerOutput() throws {
        let snapshot = try decodeRealServerSnapshot()

        XCTAssertEqual(snapshot.panes.count, 3)
        XCTAssertEqual(snapshot.panes.filter(\.focused).count, 1, "exactly one focused pane")
        XCTAssertEqual(snapshot.area, PaneLayoutRect(x: 0, y: 0, width: 114, height: 40))
        XCTAssertFalse(snapshot.zoomed)

        // Two nested splits. The outer rect is the whole area, the inner one
        // covers only the two left panes — that containment is what makes
        // matching a gap to its split non-trivial (see SplitHandles).
        XCTAssertEqual(snapshot.splits.count, 2)
        let byId = Dictionary(uniqueKeysWithValues: snapshot.splits.map { ($0.id, $0) })
        XCTAssertEqual(byId["split_0_root"]?.rect.width, 114)
        XCTAssertEqual(byId["split_1_0"]?.rect.width, 69)
    }

    func testRealServerOutputHasOneCellGapsBetweenAllNeighbours() throws {
        // Measured: p1 covers 0..33, p3 covers 35..67, p2 covers 69..113, so the
        // gaps land on columns 34 and 68.
        let snapshot = try decodeRealServerSnapshot()

        let ordered = snapshot.panes.sorted { $0.rect.x < $1.rect.x }
        for (left, right) in zip(ordered, ordered.dropFirst()) {
            let gap = Int(right.rect.x) - (Int(left.rect.x) + Int(left.rect.width))
            XCTAssertEqual(gap, 1, "\(left.paneId)|\(right.paneId) must be one cell apart")
        }
    }

    func testEnvelopeDecodesTheWrappedSnapshot() throws {
        // The envelope is the path ApiClient.paneLayout() takes. Decoding `result`
        // straight into PaneLayoutSnapshot fails.
        let response = try JSONSerialization.jsonObject(
            with: try XCTUnwrap(realServerResponse.data(using: .utf8))
        )
        let result = try XCTUnwrap((response as? [String: Any])?["result"])
        let envelope = try ApiTypes.decoder.decode(
            PaneLayoutEnvelope.self,
            from: try JSONSerialization.data(withJSONObject: result)
        )
        XCTAssertEqual(envelope.layout.panes.count, 3)
        XCTAssertEqual(envelope.layout.focusedPaneId, "w1:p1")
    }
}
