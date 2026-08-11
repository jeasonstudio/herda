import XCTest
@testable import HerdrKit

@MainActor
final class SidebarModelTests: XCTestCase {
    private func snapshot(
        workspaces: [(String, Int)] = [("w1", 1)],
        workspaceStatus: AgentStatus = .unknown,
        tabCount: Int = 1,
        panes: [(String, String, String?, AgentStatus)] = []
    ) throws -> SessionSnapshot {
        let workspaceJSON = workspaces.map { id, number in
            """
            {"workspace_id":"\(id)","number":\(number),"label":"\(id)-label","focused":false,
             "pane_count":1,"tab_count":\(tabCount),"active_tab_id":"\(id):t1",
             "agent_status":"\(workspaceStatus.rawValue)"}
            """
        }.joined(separator: ",")
        let paneJSON = panes.map { paneId, workspaceId, agent, status in
            let agentField = agent.map { "\"agent\":\"\($0)\"," } ?? ""
            // Tab id derived from the pane so a two-tab workspace can be posed.
            let tab = paneId.hasSuffix("p2") ? "t2" : "t1"
            return """
            {"pane_id":"\(paneId)","terminal_id":"t","workspace_id":"\(workspaceId)",
             "tab_id":"\(workspaceId):\(tab)","focused":false,"cwd":"/","foreground_cwd":"/",
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

    // MARK: Attention priority (shared by the spaces roll-up and priority order)

    /// Mirrors herdr's `pane_attention_priority`. The ordering that is easy to
    /// get wrong is `done` above `working`.
    func testAttentionPriorityFollowsHerdr() {
        let ordered: [AgentStatus] = [.blocked, .done, .working, .idle, .unknown]
        XCTAssertEqual(
            ordered.sorted { $0.attentionPriority > $1.attentionPriority },
            ordered
        )
    }

    func testRollUpPutsAFinishedAgentAboveABusyOne() throws {
        let model = SidebarModel()
        model.apply(try snapshot(
            workspaces: [("w1", 1)],
            panes: [("w1:p1", "w1", "claude", .working), ("w1:p2", "w1", "codex", .done)]
        ))
        XCTAssertEqual(
            model.rollUpStatus(forWorkspace: try XCTUnwrap(model.workspaces.first)),
            .done
        )
    }

    // MARK: Agent entries (the agents section's flat list)

    func testGroupedOrderFollowsSpaceThenPaneOrder() throws {
        let model = SidebarModel()
        model.apply(try snapshot(
            workspaces: [("w2", 2), ("w1", 1)],
            panes: [
                ("w2:p1", "w2", "claude", .idle),
                ("w1:p2", "w1", "codex", .idle),
                ("w1:p1", "w1", "claude", .blocked),
            ]
        ))
        XCTAssertEqual(
            model.agentEntries(sortedBy: .spaces).map(\.id),
            ["w1:p1", "w1:p2", "w2:p1"]
        )
    }

    func testPriorityOrderPutsWhatNeedsYouFirst() throws {
        let model = SidebarModel()
        model.apply(try snapshot(
            workspaces: [("w1", 1), ("w2", 2)],
            panes: [
                ("w1:p1", "w1", "claude", .idle),
                ("w1:p2", "w1", "codex", .working),
                ("w2:p1", "w2", "claude", .blocked),
                ("w2:p2", "w2", "codex", .done),
            ]
        ))
        XCTAssertEqual(
            model.agentEntries(sortedBy: .priority).map(\.id),
            ["w2:p1", "w2:p2", "w1:p2", "w1:p1"]
        )
    }

    /// Rows that reshuffle between equal states are unreadable, so ties resolve
    /// to space order and then pane order.
    func testPriorityOrderBreaksTiesDeterministically() throws {
        let model = SidebarModel()
        model.apply(try snapshot(
            workspaces: [("w1", 1), ("w2", 2)],
            panes: [
                ("w2:p1", "w2", "claude", .working),
                ("w1:p2", "w1", "claude", .working),
                ("w1:p1", "w1", "claude", .working),
            ]
        ))
        XCTAssertEqual(
            model.agentEntries(sortedBy: .priority).map(\.id),
            ["w1:p1", "w1:p2", "w2:p1"]
        )
    }

    func testAgentEntryCarriesItsSpaceAndAgentName() throws {
        let model = SidebarModel()
        model.apply(try snapshot(
            workspaces: [("w1", 4)],
            panes: [("w1:p1", "w1", "claude", .working)]
        ))
        let entry = try XCTUnwrap(model.agentEntries(sortedBy: .spaces).first)
        XCTAssertEqual(entry.workspaceNumber, 4)
        XCTAssertEqual(entry.workspaceLabel, "w1-label")
        XCTAssertEqual(entry.agentName, "claude")
    }

    func testTabHintOnlyAppearsWhenASpaceHasMoreThanOneTab() throws {
        let single = SidebarModel()
        single.apply(try snapshot(
            workspaces: [("w1", 1)],
            panes: [("w1:p1", "w1", "claude", .idle)]
        ))
        XCTAssertNil(single.agentEntries(sortedBy: .spaces).first?.tabHint)

        let multi = SidebarModel()
        multi.apply(try snapshot(
            workspaces: [("w1", 1)],
            tabCount: 2,
            panes: [("w1:p1", "w1", "claude", .idle), ("w1:p2", "w1", "codex", .idle)]
        ))
        XCTAssertEqual(multi.agentEntries(sortedBy: .spaces).map(\.tabHint), ["1", "2"])
    }

    /// A tab id that is not the usual `t<number>` still shows something true
    /// rather than being mangled into a number.
    func testTabHintKeepsAnUnusualTabIdIntact() {
        XCTAssertEqual(AgentEntry.tabSuffix("w1:review"), "review")
        XCTAssertEqual(AgentEntry.tabSuffix("w1:t12"), "12")
        XCTAssertEqual(AgentEntry.tabSuffix("w1:t"), "t")
    }

    func testAgentCountPerSpaceSkipsPanesWithoutAnAgent() throws {
        let model = SidebarModel()
        model.apply(try snapshot(
            workspaces: [("w1", 1)],
            panes: [("w1:p1", "w1", "claude", .idle), ("w1:p2", "w1", nil, .idle)]
        ))
        XCTAssertEqual(model.agentCount(inWorkspace: "w1"), 1)
    }

    // MARK: Status merge (the polled refresh)

    func testMergeStatusesUpdatesAKnownPane() throws {
        let model = SidebarModel()
        model.apply(try snapshot(
            workspaces: [("w1", 1)],
            panes: [("w1:p1", "w1", "claude", .idle)]
        ))
        let fresh = try snapshot(
            workspaces: [("w1", 1)],
            panes: [("w1:p1", "w1", "claude", .blocked)]
        )
        model.mergeStatuses(from: fresh.panes)
        XCTAssertEqual(model.agents(inWorkspace: "w1").first?.agentStatus, .blocked)
    }

    /// The rail and the header counts both read from the roll-up, so a merge has
    /// to move them.
    func testMergeStatusesMovesTheRollUpAndCounts() throws {
        let model = SidebarModel()
        model.apply(try snapshot(
            workspaces: [("w1", 1)],
            panes: [("w1:p1", "w1", "claude", .idle)]
        ))
        model.mergeStatuses(from: try snapshot(
            workspaces: [("w1", 1)],
            panes: [("w1:p1", "w1", "claude", .working)]
        ).panes)
        XCTAssertEqual(
            model.rollUpStatus(forWorkspace: try XCTUnwrap(model.workspaces.first)),
            .working
        )
        XCTAssertEqual(model.agentCount(withStatus: .working), 1)
    }

    /// Structure belongs to the event stream: a pane the model has not been told
    /// about must not appear because a poll mentioned it.
    func testMergeStatusesDoesNotAddPanes() throws {
        let model = SidebarModel()
        model.apply(try snapshot(workspaces: [("w1", 1)]))
        model.mergeStatuses(from: try snapshot(
            workspaces: [("w1", 1)],
            panes: [("w1:p1", "w1", "claude", .blocked)]
        ).panes)
        XCTAssertTrue(model.panes(inWorkspace: "w1").isEmpty)
    }

    /// A pane whose agent was learned from an event keeps it when a poll reports
    /// the same pane with no agent field.
    func testMergeStatusesKeepsADetectedAgentName() throws {
        let model = SidebarModel()
        model.apply(try snapshot(workspaces: [("w1", 1)], panes: [("w1:p1", "w1", nil, .unknown)]))
        model.handle(event: "pane_agent_detected", data: [
            "agent": "codex", "pane_id": "w1:p1", "workspace_id": "w1",
        ])
        model.mergeStatuses(from: try snapshot(
            workspaces: [("w1", 1)],
            panes: [("w1:p1", "w1", nil, .working)]
        ).panes)
        XCTAssertEqual(model.agentName(forPane: "w1:p1"), "codex")
        XCTAssertEqual(model.agents(inWorkspace: "w1").first?.agentStatus, .working)
    }

    // MARK: Status roll-up (the sidebar's status rail and header counts)

    func testRollUpPrefersTheMostUrgentAgentStatus() throws {
        let model = SidebarModel()
        model.apply(try snapshot(
            workspaces: [("w1", 1)],
            panes: [
                ("w1:p1", "w1", "claude", .done),
                ("w1:p2", "w1", "codex", .working),
                ("w1:p3", "w1", "cursor", .blocked),
            ]
        ))
        let workspace = try XCTUnwrap(model.workspaces.first)
        XCTAssertEqual(model.rollUpStatus(forWorkspace: workspace), .blocked)
    }

    func testRollUpPutsABusyAgentAboveAnIdleOne() throws {
        let model = SidebarModel()
        model.apply(try snapshot(
            workspaces: [("w1", 1)],
            panes: [("w1:p1", "w1", "claude", .idle), ("w1:p2", "w1", "codex", .working)]
        ))
        XCTAssertEqual(
            model.rollUpStatus(forWorkspace: try XCTUnwrap(model.workspaces.first)),
            .working
        )
    }

    /// Panes with no recognised agent must not colour the rail: a workspace
    /// holding only a shell has nothing waiting on the user, whatever status the
    /// shell pane happens to report.
    func testRollUpIgnoresPanesWithoutAnAgent() throws {
        let model = SidebarModel()
        model.apply(try snapshot(
            workspaces: [("w1", 1)],
            workspaceStatus: .idle,
            panes: [("w1:p1", "w1", nil, .blocked)]
        ))
        XCTAssertEqual(model.rollUpStatus(forWorkspace: try XCTUnwrap(model.workspaces.first)), .idle)
    }

    func testRollUpIsIdleWhenEveryAgentIsIdle() throws {
        let model = SidebarModel()
        model.apply(try snapshot(
            workspaces: [("w1", 1)],
            workspaceStatus: .working,
            panes: [("w1:p1", "w1", "claude", .idle), ("w1:p2", "w1", "codex", .unknown)]
        ))
        XCTAssertEqual(
            model.rollUpStatus(forWorkspace: try XCTUnwrap(model.workspaces.first)),
            .idle,
            "known agents outrank the server's workspace status"
        )
    }

    func testRollUpUsesTheServerStatusWhenNoAgentIsKnownYet() throws {
        let model = SidebarModel()
        model.apply(try snapshot(workspaces: [("w1", 1)], workspaceStatus: .working))
        XCTAssertEqual(
            model.rollUpStatus(forWorkspace: try XCTUnwrap(model.workspaces.first)),
            .working
        )
    }

    func testAgentCountsSpanEveryWorkspaceAndSkipNonAgents() throws {
        let model = SidebarModel()
        model.apply(try snapshot(
            workspaces: [("w1", 1), ("w2", 2)],
            panes: [
                ("w1:p1", "w1", "claude", .blocked),
                ("w2:p1", "w2", "codex", .blocked),
                ("w2:p2", "w2", "cursor", .working),
                ("w2:p3", "w2", nil, .working),
            ]
        ))
        XCTAssertEqual(model.agentCount(withStatus: .blocked), 2)
        XCTAssertEqual(model.agentCount(withStatus: .working), 1)
        XCTAssertEqual(model.agentCount(withStatus: .done), 0)
    }
}
