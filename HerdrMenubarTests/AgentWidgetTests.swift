import Foundation
import XCTest
@testable import HerdrMenubar

final class AgentWidgetTests: XCTestCase {
    private func row(_ date: Date? = nil) -> WidgetAgent {
        WidgetAgent(session: "default", workspaceID: "w1", workspace: "Luna Escalation", tabID: "t1", tab: "New Session", paneID: "p1", agentName: "", agentType: "pi", status: "idle", lastMessageAt: date)
    }
    func testPiSessionReferenceDecodesAlongsideExistingPaneFields() throws {
        let data = Data(#"{"pane_id":"p1","terminal_id":"term1","workspace_id":"w1","tab_id":"t1","focused":false,"agent":"pi","agent_status":"working","revision":1,"agent_session":{"agent":"pi","kind":"path","source":"herdr:pi","value":"/tmp/session.jsonl"}}"#.utf8)
        let pane = try JSONDecoder().decode(PaneInfo.self, from: data)
        XCTAssertEqual(pane.agentSession?.value, "/tmp/session.jsonl")
        XCTAssertEqual(pane.agentSession?.agent, "pi")
    }
    func testNamedTabAndAgentAreRecognizableWithoutRepeatingWorkspace() {
        var agent = row()
        XCTAssertEqual(agent.title, "New Session")
        XCTAssertEqual(agent.detail, "pi")
        agent.agentName = "Migration review"
        XCTAssertEqual(agent.title, "New Session · Migration review")
        agent.tab = "1"
        XCTAssertEqual(agent.title, "Migration review")
    }
    func testRollingWindowExcludesUnknownExpiredAndFutureMessages() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertFalse(row().matches(.hours, amount: 2, now: now))
        XCTAssertTrue(row(now.addingTimeInterval(-7199)).matches(.hours, amount: 2, now: now))
        XCTAssertFalse(row(now.addingTimeInterval(-7200)).matches(.hours, amount: 2, now: now))
        XCTAssertFalse(row(now.addingTimeInterval(1)).matches(.hours, amount: 2, now: now))
        XCTAssertTrue(row().matches(.all, amount: 2, now: now))
    }
    func testTodayUsesCalendarMidnightAndPreservesIdleAgents() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -25200)!
        let now = Date(timeIntervalSince1970: 1789342000)
        let midnight = calendar.startOfDay(for: now)
        XCTAssertTrue(row(midnight).matches(.today, amount: 2, now: now, calendar: calendar))
        XCTAssertFalse(row(midnight.addingTimeInterval(-1)).matches(.today, amount: 2, now: now, calendar: calendar))
    }
    func testLinkRoundTripsExactIdentityAndRejectsWrongScheme() throws {
        let agent = row()
        XCTAssertEqual(WidgetAgentTarget(url: agent.url)?.paneID, "p1")
        XCTAssertEqual(WidgetAgentTarget(url: agent.url)?.session, "default")
        XCTAssertNil(WidgetAgentTarget(url: URL(string: "https://focus?session=default&pane=p1")!))
    }
    func testSourceHealthDoesNotDependOnFilteredEligibility() {
        let now = Date(timeIntervalSince1970: 100_000)
        let oldAgent = row(now.addingTimeInterval(-7200))
        var snapshot = AgentWidgetSnapshot(version: 1, writtenAt: now, agents: [oldAgent], unavailableSessions: 0)
        snapshot.sourceVerifiedAt = now.addingTimeInterval(-181)
        XCTAssertFalse(oldAgent.matches(.hours, amount: 1, now: now))
        XCTAssertTrue(snapshot.isSourceUnverified(at: now))
        XCTAssertFalse(snapshot.isPublicationStale(at: now))
        let empty = AgentWidgetSnapshot(version: 1, writtenAt: now, agents: [], unavailableSessions: 0)
        XCTAssertFalse(empty.isSourceUnverified(at: now))
    }
    func testFutureHealthTimestampsAreUnverified() {
        let now = Date(timeIntervalSince1970: 100_000)
        var snapshot = AgentWidgetSnapshot(version: 1, writtenAt: now.addingTimeInterval(60), agents: [row()], unavailableSessions: 0)
        snapshot.sourceVerifiedAt = now.addingTimeInterval(60)
        XCTAssertTrue(snapshot.isPublicationStale(at: now))
        XCTAssertTrue(snapshot.isSourceUnverified(at: now))
    }
    func testFutureMessageCannotBecomeEligibleInLaterEntriesOfSameTimeline() {
        let observed = Date(timeIntervalSince1970: 100_000)
        let futureAgent = row(observed.addingTimeInterval(60))
        XCTAssertFalse(futureAgent.matches(.hours, amount: 1, now: observed.addingTimeInterval(180), recordedBy: observed))
        XCTAssertTrue(futureAgent.matches(.all, amount: 1, now: observed.addingTimeInterval(180), recordedBy: observed))
        XCTAssertTrue(futureAgent.matches(.hours, amount: 1, now: observed.addingTimeInterval(180), recordedBy: observed.addingTimeInterval(180)))
    }

}
