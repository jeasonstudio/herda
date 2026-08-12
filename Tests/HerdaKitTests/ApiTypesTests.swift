import XCTest
@testable import HerdaKit

final class ApiTypesTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try ApiTypes.decoder.decode(type, from: Data(json.utf8))
    }

    func testDecodesWorkspaceInfo() throws {
        let json = """
        {"workspace_id":"w2","number":2,"label":"~","focused":false,
         "pane_count":1,"tab_count":1,"active_tab_id":"w2:t1","agent_status":"unknown"}
        """
        let workspace = try decode(WorkspaceInfo.self, from: json)
        XCTAssertEqual(workspace.workspaceId, "w2")
        XCTAssertEqual(workspace.number, 2)
        XCTAssertEqual(workspace.label, "~")
        XCTAssertFalse(workspace.focused)
        XCTAssertEqual(workspace.paneCount, 1)
        XCTAssertEqual(workspace.agentStatus, .unknown)
    }

    func testDecodesPaneInfoWithAgent() throws {
        let json = """
        {"pane_id":"w1:p1","terminal_id":"term_65832a8e","workspace_id":"w1","tab_id":"w1:t1",
         "focused":true,"cwd":"/Users/jeason","foreground_cwd":"/Users/jeason",
         "agent":"claude","terminal_title":"✳ 调整","terminal_title_stripped":"调整",
         "agent_status":"idle","revision":30}
        """
        let pane = try decode(PaneInfo.self, from: json)
        XCTAssertEqual(pane.paneId, "w1:p1")
        XCTAssertEqual(pane.workspaceId, "w1")
        XCTAssertEqual(pane.agent, "claude")
        XCTAssertEqual(pane.agentStatus, .idle)
        XCTAssertEqual(pane.terminalTitleStripped, "调整")
        XCTAssertTrue(pane.focused)
    }

    func testDecodesPaneInfoWithoutAgentFields() throws {
        // Panes with no agent omit `agent`, `terminal_title` and friends.
        let json = """
        {"pane_id":"w2:p1","terminal_id":"term_x","workspace_id":"w2","tab_id":"w2:t1",
         "focused":false,"cwd":"/Users/jeason","foreground_cwd":"/Users/jeason",
         "agent_status":"unknown","revision":0}
        """
        let pane = try decode(PaneInfo.self, from: json)
        XCTAssertNil(pane.agent)
        XCTAssertNil(pane.terminalTitleStripped)
        XCTAssertEqual(pane.agentStatus, .unknown)
    }

    func testDecodesPaneInfoScroll() throws {
        // The native scrollbar reads its three numbers from here rather than from
        // the PaneScrollChanged event: that event is a per-pane subscription, and a
        // connection's subscription set cannot be extended once started, so
        // following pane creation would mean reconnecting — the same limitation
        // SidebarModel.mergeStatuses already records. The snapshot is polled
        // anyway. Values below are as observed on a live server.
        let json = """
        {"pane_id":"w1:p1","terminal_id":"term_x","workspace_id":"w1","tab_id":"w1:t1",
         "focused":true,"cwd":"/Users/jeason","foreground_cwd":"/Users/jeason",
         "agent_status":"unknown","revision":1,
         "scroll":{"max_offset_from_bottom":0,"offset_from_bottom":0,"viewport_rows":40}}
        """
        let pane = try decode(PaneInfo.self, from: json)
        XCTAssertEqual(pane.scroll?.offsetFromBottom, 0)
        XCTAssertEqual(pane.scroll?.maxOffsetFromBottom, 0)
        XCTAssertEqual(pane.scroll?.viewportRows, 40)
    }

    func testDecodesPaneInfoWithoutScroll() throws {
        // The field is Option<PaneScrollInfo> on the wire, so its absence has to
        // be tolerated.
        let json = """
        {"pane_id":"w2:p1","terminal_id":"term_x","workspace_id":"w2","tab_id":"w2:t1",
         "focused":false,"cwd":"/Users/jeason","foreground_cwd":"/Users/jeason",
         "agent_status":"unknown","revision":0}
        """
        XCTAssertNil(try decode(PaneInfo.self, from: json).scroll)
    }

    func testDecodesAllAgentStatuses() throws {
        for (raw, expected) in [
            ("idle", AgentStatus.idle),
            ("working", .working),
            ("blocked", .blocked),
            ("done", .done),
            ("unknown", .unknown),
        ] {
            let json = "{\"status\":\"\(raw)\"}"
            struct Holder: Decodable { let status: AgentStatus }
            XCTAssertEqual(try decode(Holder.self, from: json).status, expected)
        }
    }

    func testUnrecognisedAgentStatusDecodesToUnknown() throws {
        // Forward compatibility: a new server status must not break the sidebar.
        struct Holder: Decodable { let status: AgentStatus }
        XCTAssertEqual(try decode(Holder.self, from: "{\"status\":\"sleeping\"}").status, .unknown)
    }

    func testDecodesSessionSnapshotEnvelope() throws {
        let json = """
        {"type":"session_snapshot","snapshot":{"version":"0.8.0","protocol":19,
         "focused_workspace_id":"w1","workspaces":[],"tabs":[],"panes":[],
         "layouts":[],"agents":[]}}
        """
        let envelope = try decode(SessionSnapshotEnvelope.self, from: json)
        XCTAssertEqual(envelope.snapshot.focusedWorkspaceId, "w1")
        XCTAssertEqual(envelope.snapshot.protocolVersion, 19)
        XCTAssertTrue(envelope.snapshot.workspaces.isEmpty)
    }

    func testDistinguishesEventFromResponseByPresenceOfId() throws {
        let response = """
        {"id":"p","result":{"type":"pane_list","panes":[]}}
        """
        let event = """
        {"event":"pane_created","data":{"type":"pane_created","pane":{}}}
        """
        XCTAssertEqual(try ApiTypes.classify(line: response), .response(id: "p"))
        XCTAssertEqual(try ApiTypes.classify(line: event), .event(name: "pane_created"))
    }

    func testClassifyRejectsLineWithNeitherField() {
        XCTAssertThrowsError(try ApiTypes.classify(line: "{\"junk\":1}"))
    }
}
