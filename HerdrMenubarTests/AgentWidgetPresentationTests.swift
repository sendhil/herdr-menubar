import XCTest
@testable import HerdrMenubar

final class AgentWidgetPresentationTests: XCTestCase {
    func testLargeBudgetIncludesWorkspaceHeadingsAndPreservesInputOrder() {
        let agents = (0..<8).map { agent($0, workspace: "w\($0)") }
        let result = AgentWidgetPresentation(agents: agents, large: true, availableHeight: 300)
        XCTAssertEqual(result.shown.map(\.id), Array(agents.prefix(5)).map(\.id))
        XCTAssertEqual(result.overflow, 3)
    }

    func testSharedWorkspaceFitsMoreRowsThanSeparateHeadings() {
        let agents = (0..<8).map { agent($0, workspace: "same") }
        let result = AgentWidgetPresentation(agents: agents, large: true, availableHeight: 300)
        XCTAssertEqual(result.shown.count, 7)
        XCTAssertEqual(result.overflow, 1)
    }

    func testSummaryCountsEntireFilteredInputIncludingOverflow() {
        let agents = [agent(0, status: "idle"), agent(1, status: "blocked"), agent(2, status: "working"), agent(3, status: "done")]
        let result = AgentWidgetPresentation(agents: agents, large: false, availableHeight: 120)
        XCTAssertEqual(result.shown.count, 2)
        XCTAssertEqual(result.blockedCount, 1)
        XCTAssertEqual(result.workingCount, 1)
        XCTAssertEqual(result.otherCount, 2)
        XCTAssertEqual(result.overflow, 2)
    }

    func testSmallBudgetNeverProducesOrphanWorkspaceHeading() {
        let result = AgentWidgetPresentation(agents: [agent(0)], large: true, availableHeight: 90)
        XCTAssertTrue(result.shown.isEmpty)
        XCTAssertEqual(result.overflow, 1)
    }

    private func agent(_ index: Int, workspace: String = "workspace", status: String = "idle") -> WidgetAgent {
        WidgetAgent(session: "default", workspaceID: workspace, workspace: workspace, tabID: "\(index)", tab: "Agent \(index)", paneID: "\(index)", agentName: "", agentType: "pi", status: status, lastMessageAt: nil)
    }
}
