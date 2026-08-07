import XCTest
@testable import HerdrKit

@MainActor
final class SidebarModelTests: XCTestCase {
    private func snapshot(
        workspaces: [(String, Int)] = [("w1", 1)],
        panes: [(String, String, String?, AgentStatus)] = []
    ) throws -> SessionSnapshot {
        let workspaceJSON = workspaces.map { id, number in
            """
            {"workspace_id":"\(id)","number":\(number),"label":"~","focused":false,
             "pane_count":1,"tab_count":1,"active_tab_id":"\(id):t1","agent_status":"unknown"}
            """
        }.joined(separator: ",")
        let paneJSON = panes.map { paneId, workspaceId, agent, status in
            let agentField = agent.map { "\"agent\":\"\($0)\"," } ?? ""
            return """
            {"pane_id":"\(paneId)","terminal_id":"t","workspace_id":"\(workspaceId)",
             "tab_id":"\(workspaceId):t1","focused":false,"cwd":"/","foreground_cwd":"/",
             \(agentField)"agent_status":"\(status.rawValue)","revision":0}
            """
        }.joined(separator: ",")
        let json = """
        {"version":"0.8.0","protocol":19,"workspaces":[\(workspaceJSON)],
         "tabs":[],"panes":[\(paneJSON)],"layouts":[],"agents":[]}
        """
        return try ApiTypes.decoder.decode(SessionSnapshot.self, from: Data(json.utf8))
    }

    func testApplyingSnapshotPopulatesWorkspacesAndPanes() throws {
        let model = SidebarModel()
        model.apply(try snapshot(
            workspaces: [("w1", 1), ("w2", 2)],
            panes: [("w1:p1", "w1", "claude", .working)]
        ))
        XCTAssertEqual(model.workspaces.map(\.workspaceId), ["w1", "w2"])
        XCTAssertEqual(model.panes(inWorkspace: "w1").map(\.paneId), ["w1:p1"])
        XCTAssertTrue(model.panes(inWorkspace: "w2").isEmpty)
    }

    func testWorkspacesAreOrderedByNumber() throws {
        let model = SidebarModel()
        model.apply(try snapshot(workspaces: [("w3", 3), ("w1", 1), ("w2", 2)]))
        XCTAssertEqual(model.workspaces.map(\.number), [1, 2, 3])
    }

    func testOnlyPanesWithAnAgentAreListedAsAgents() throws {
        let model = SidebarModel()
        model.apply(try snapshot(
            workspaces: [("w1", 1)],
            panes: [
                ("w1:p1", "w1", "claude", .working),
                ("w1:p2", "w1", nil, .unknown),
            ]
        ))
        XCTAssertEqual(model.agents(inWorkspace: "w1").map(\.paneId), ["w1:p1"])
    }

    func testPaneUpdatedEventReplacesTheStoredPane() throws {
        let model = SidebarModel()
        model.apply(try snapshot(
            workspaces: [("w1", 1)],
            panes: [("w1:p1", "w1", "claude", .idle)]
        ))
        XCTAssertEqual(model.panes(inWorkspace: "w1").first?.agentStatus, .idle)

        model.handle(event: "pane_updated", data: [
            "pane": [
                "pane_id": "w1:p1", "terminal_id": "t", "workspace_id": "w1",
                "tab_id": "w1:t1", "focused": false, "cwd": "/", "foreground_cwd": "/",
                "agent": "claude", "agent_status": "working", "revision": 1,
            ],
        ])
        XCTAssertEqual(model.panes(inWorkspace: "w1").first?.agentStatus, .working)
    }

    func testPaneCreatedEventAppends() throws {
        let model = SidebarModel()
        model.apply(try snapshot(workspaces: [("w1", 1)]))
        model.handle(event: "pane_created", data: [
            "pane": [
                "pane_id": "w1:p9", "terminal_id": "t", "workspace_id": "w1",
                "tab_id": "w1:t1", "focused": false, "cwd": "/", "foreground_cwd": "/",
                "agent_status": "unknown", "revision": 0,
            ],
        ])
        XCTAssertEqual(model.panes(inWorkspace: "w1").map(\.paneId), ["w1:p9"])
    }

    func testPaneClosedEventRemoves() throws {
        let model = SidebarModel()
        model.apply(try snapshot(
            workspaces: [("w1", 1)],
            panes: [("w1:p1", "w1", "claude", .idle)]
        ))
        model.handle(event: "pane_closed", data: ["pane_id": "w1:p1"])
        XCTAssertTrue(model.panes(inWorkspace: "w1").isEmpty)
    }

    func testWorkspaceFocusedEventUpdatesFocus() throws {
        let model = SidebarModel()
        model.apply(try snapshot(workspaces: [("w1", 1), ("w2", 2)]))
        model.handle(event: "workspace_focused", data: ["workspace_id": "w2"])
        XCTAssertEqual(model.focusedWorkspaceId, "w2")
    }

    func testWorkspaceClosedEventRemovesItAndItsPanes() throws {
        let model = SidebarModel()
        model.apply(try snapshot(
            workspaces: [("w1", 1), ("w2", 2)],
            panes: [("w2:p1", "w2", "claude", .idle)]
        ))
        model.handle(event: "workspace_closed", data: ["workspace_id": "w2"])
        XCTAssertEqual(model.workspaces.map(\.workspaceId), ["w1"])
        XCTAssertTrue(model.panes(inWorkspace: "w2").isEmpty)
    }

    func testPaneAgentDetectedEventUsesFlatFieldsAndListsTheAgent() throws {
        // The real event is `{agent, pane_id, workspace_id}` with no `pane`
        // object; the pane already exists from the snapshot without an agent.
        let model = SidebarModel()
        model.apply(try snapshot(
            workspaces: [("w1", 1)],
            panes: [("w1:p1", "w1", nil, .unknown)]
        ))
        XCTAssertTrue(model.agents(inWorkspace: "w1").isEmpty)

        model.handle(event: "pane_agent_detected", data: [
            "agent": "claude", "pane_id": "w1:p1", "workspace_id": "w1",
        ])
        XCTAssertEqual(model.agents(inWorkspace: "w1").map(\.paneId), ["w1:p1"])
        XCTAssertEqual(model.agentName(forPane: "w1:p1"), "claude")
    }

    func testDetectedAgentSurvivesAPaneUpdateWithoutAnAgentField() throws {
        // A later `pane_updated` whose pane snapshot omits `agent` must not
        // erase a detection — the pane keeps showing as an agent row.
        let model = SidebarModel()
        model.apply(try snapshot(
            workspaces: [("w1", 1)],
            panes: [("w1:p1", "w1", nil, .unknown)]
        ))
        model.handle(event: "pane_agent_detected", data: [
            "agent": "claude", "pane_id": "w1:p1", "workspace_id": "w1",
        ])
        model.handle(event: "pane_updated", data: [
            "pane": [
                "pane_id": "w1:p1", "terminal_id": "t", "workspace_id": "w1",
                "tab_id": "w1:t1", "focused": false, "cwd": "/", "foreground_cwd": "/",
                "agent_status": "working", "revision": 2,
            ],
        ])
        XCTAssertEqual(model.agents(inWorkspace: "w1").map(\.paneId), ["w1:p1"])
        XCTAssertEqual(model.agentName(forPane: "w1:p1"), "claude")
    }

    func testPaneFocusedEventUsesFlatPaneId() throws {
        // The real event is `{pane_id, workspace_id}` with no `pane` object.
        let model = SidebarModel()
        model.apply(try snapshot(
            workspaces: [("w1", 1)],
            panes: [("w1:p1", "w1", "claude", .idle)]
        ))
        model.handle(event: "pane_focused", data: [
            "pane_id": "w1:p1", "workspace_id": "w1",
        ])
        XCTAssertEqual(model.focusedPaneId, "w1:p1")
    }

    func testClosingAPaneClearsItsDetectedAgent() throws {
        let model = SidebarModel()
        model.apply(try snapshot(workspaces: [("w1", 1)], panes: [("w1:p1", "w1", nil, .unknown)]))
        model.handle(event: "pane_agent_detected", data: [
            "agent": "claude", "pane_id": "w1:p1", "workspace_id": "w1",
        ])
        model.handle(event: "pane_closed", data: ["pane_id": "w1:p1"])
        XCTAssertNil(model.agentName(forPane: "w1:p1"))
        XCTAssertTrue(model.agents(inWorkspace: "w1").isEmpty)
    }

    func testMalformedEventPayloadIsIgnored() throws {
        let model = SidebarModel()
        model.apply(try snapshot(workspaces: [("w1", 1)]))
        model.handle(event: "pane_updated", data: ["pane": "not an object"])
        model.handle(event: "totally_unknown_event", data: [:])
        XCTAssertEqual(model.workspaces.count, 1, "state must survive junk")
    }
}
