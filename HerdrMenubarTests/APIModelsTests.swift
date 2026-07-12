import XCTest
@testable import HerdrMenubar

final class APIModelsTests: XCTestCase {
    func testPaneListDecodesStatusesAndIgnoresAdditionalFields() throws {
        let data = Data(#"""
        {"id":"1","result":{"type":"pane_list","panes":[
          {"pane_id":"w1:p1","terminal_id":"t1","workspace_id":"w1","tab_id":"w1:t1",
           "focused":false,"agent":"claude","display_agent":"Claude","title":"API",
           "agent_status":"blocked","revision":7,"future_field":true},
          {"pane_id":"w1:p2","terminal_id":"t2","workspace_id":"w1","tab_id":"w1:t1","focused":false,"agent_status":"done","revision":8},
          {"pane_id":"w1:p3","terminal_id":"t3","workspace_id":"w1","tab_id":"w1:t1","focused":false,"agent_status":"working","revision":9}
        ]}}
        """#.utf8)

        let response = try JSONDecoder().decode(HerdrResponse<PaneListResult>.self, from: data)

        XCTAssertNil(response.error)
        XCTAssertEqual(response.result?.panes.map(\.agentStatus), [.blocked, .done, .working])
        XCTAssertEqual(response.result?.panes.first?.displayLabel, "API")
        XCTAssertEqual(response.result?.panes[1].displayLabel, "w1:p2")
        XCTAssertEqual(response.result?.panes.first?.agentLabel, "Claude")
        XCTAssertEqual(response.result?.panes[1].agentLabel, "Agent")
    }

    func testWorkspaceAndTabListsDecodePublicMetadataFields() throws {
        let workspaceData = Data(#"""
        {"id":"workspace-1","result":{"type":"workspace_list","workspaces":[{
          "workspace_id":"w1","number":1,"label":"Herdr Menubar","focused":true,
          "pane_count":2,"tab_count":2,"active_tab_id":"w1:t1","agent_status":"working"
        }]}}
        """#.utf8)
        let tabData = Data(#"""
        {"id":"tab-1","result":{"type":"tab_list","tabs":[{
          "tab_id":"w1:t2","workspace_id":"w1","number":2,"label":"server",
          "focused":false,"pane_count":1,"agent_status":"done"
        }]}}
        """#.utf8)

        let workspaces = try JSONDecoder().decode(HerdrResponse<WorkspaceListResult>.self, from: workspaceData)
        let tabs = try JSONDecoder().decode(HerdrResponse<TabListResult>.self, from: tabData)

        XCTAssertEqual(workspaces.result?.type, "workspace_list")
        XCTAssertEqual(
            workspaces.result?.workspaces.first,
            WorkspaceInfo(
                workspaceID: "w1", number: 1, label: "Herdr Menubar", focused: true,
                paneCount: 2, tabCount: 2, activeTabID: "w1:t1", agentStatus: .working
            )
        )
        XCTAssertEqual(tabs.result?.type, "tab_list")
        XCTAssertEqual(tabs.result?.tabs.first, TabInfo(tabID: "w1:t2", workspaceID: "w1", number: 2, label: "server", focused: false, paneCount: 1, agentStatus: .done))
    }

    func testUnknownAgentStatusDecodesAsUnknown() throws {
        let data = Data(#"{"pane_id":"p","terminal_id":"t","workspace_id":"w","tab_id":"tab","focused":false,"agent_status":"future","revision":1}"#.utf8)

        let pane = try JSONDecoder().decode(PaneInfo.self, from: data)

        XCTAssertEqual(pane.agentStatus, .unknown)
    }

    func testPaneInfoFocusResponseDecodes() throws {
        let data = Data(#"""
        {"id":"focus-1","result":{"type":"pane_info","pane":{
          "pane_id":"w1:p1","terminal_id":"t1","workspace_id":"w1","tab_id":"w1:t1",
          "focused":true,"label":"server","agent_status":"blocked","revision":10
        }}}
        """#.utf8)

        let response = try JSONDecoder().decode(HerdrResponse<PaneFocusResult>.self, from: data)

        XCTAssertEqual(response.result?.type, "pane_info")
        XCTAssertEqual(response.result?.pane.paneID, "w1:p1")
        XCTAssertEqual(response.result?.pane.displayLabel, "server")
        XCTAssertEqual(response.result?.pane.focused, true)
    }

    func testEventEnvelopeDecodesKnownFieldsAndIgnoresAdditionalFields() throws {
        let data = Data(#"{"event":"pane.agent_status_changed","data":{"pane_id":"w1:p1","workspace_id":"w1","agent_status":"done","future_field":"ignored"},"future_envelope_field":true}"#.utf8)

        let envelope = try JSONDecoder().decode(EventEnvelope.self, from: data)

        XCTAssertEqual(envelope.event, "pane.agent_status_changed")
        XCTAssertEqual(envelope.data.paneID, "w1:p1")
        XCTAssertEqual(envelope.data.workspaceID, "w1")
        XCTAssertEqual(envelope.data.agentStatus, .done)
    }

    func testErrorResponseDecodesWithoutResult() throws {
        let data = Data(#"{"id":"bad-1","error":{"code":"pane_not_found","message":"pane not found"}}"#.utf8)

        let response = try JSONDecoder().decode(HerdrResponse<PaneFocusResult>.self, from: data)

        XCTAssertNil(response.result)
        XCTAssertEqual(response.error, HerdrAPIError(code: "pane_not_found", message: "pane not found"))
    }

    func testRequestsEncodeExpectedWireShape() throws {
        let list = HerdrRequest(id: "list-1", method: "pane.list", params: EmptyParams())
        let focus = HerdrRequest(id: "focus-1", method: "pane.focus", params: PaneTargetParams(paneID: "w1:p1"))
        let tabs = HerdrRequest(id: "tabs-1", method: "tab.list", params: TabListParams(workspaceID: "w1"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        XCTAssertEqual(String(decoding: try encoder.encode(list), as: UTF8.self), #"{"id":"list-1","method":"pane.list","params":{}}"#)
        XCTAssertEqual(String(decoding: try encoder.encode(focus), as: UTF8.self), #"{"id":"focus-1","method":"pane.focus","params":{"pane_id":"w1:p1"}}"#)
        XCTAssertEqual(String(decoding: try encoder.encode(tabs), as: UTF8.self), #"{"id":"tabs-1","method":"tab.list","params":{"workspace_id":"w1"}}"#)
    }
}
