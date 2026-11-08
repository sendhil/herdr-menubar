import Foundation
import XCTest
@testable import HerdrMenubar

final class AgentBackendTypesTests: XCTestCase {
    func testHerdrSessionKeysEncodeDefaultAndNamedDefaultDistinctly() {
        let defaultKey = AgentSessionKey(herdr: .default)
        let namedDefaultKey = AgentSessionKey(herdr: .named("default"))

        XCTAssertEqual(defaultKey, AgentSessionKey(backend: .herdr, rawID: "default"))
        XCTAssertEqual(namedDefaultKey, AgentSessionKey(backend: .herdr, rawID: "named:default"))
        XCTAssertNotEqual(defaultKey, namedDefaultKey)
        XCTAssertEqual(defaultKey.herdrSessionID, .default)
        XCTAssertEqual(namedDefaultKey.herdrSessionID, .named("default"))
        XCTAssertEqual(AgentSessionKey(herdr: .named("a:b")).rawID, "named:a:b")
        XCTAssertEqual(AgentSessionKey(herdr: .named("a:b")).herdrSessionID, .named("a:b"))
    }

    func testOnlyWellFormedHerdrKeysBridgeBackToSessionID() {
        XCTAssertNil(AgentSessionKey(backend: .rex, rawID: "default").herdrSessionID)
        XCTAssertNil(AgentSessionKey(backend: .herdr, rawID: "work").herdrSessionID)
        XCTAssertNil(AgentSessionKey(backend: .herdr, rawID: "named:").herdrSessionID)
    }

    func testBackendKindOrderNamesAndDefaultNotifyStates() {
        XCTAssertEqual(BackendKind.allCases, [.herdr, .rex])
        XCTAssertLessThan(BackendKind.herdr.sortIndex, BackendKind.rex.sortIndex)
        XCTAssertEqual(BackendKind.herdr.displayName, "Herdr")
        XCTAssertEqual(BackendKind.rex.displayName, "Rex")
        XCTAssertEqual(BackendKind.herdr.defaultNotifyStates, [.blocked, .done])
        XCTAssertEqual(BackendKind.rex.defaultNotifyStates, [.blocked, .error])
    }

    func testHerdrDescriptorBridgeKeepsDisplayName() {
        let descriptor = SessionDescriptor(id: .named("work"), socketURL: URL(fileURLWithPath: "/tmp/work.sock"))
        XCTAssertEqual(
            AgentSessionDescriptor(herdr: descriptor),
            AgentSessionDescriptor(key: AgentSessionKey(backend: .herdr, rawID: "named:work"), displayName: "work")
        )
        XCTAssertEqual(
            AgentSessionDescriptor(
                herdr: SessionDescriptor(id: .default, socketURL: URL(fileURLWithPath: "/tmp/default.sock"))
            ).displayName,
            "Default"
        )
    }

    func testSelectionTargetEqualityAndHashIgnoreDisplayName() {
        let target = AgentTarget(session: AgentSessionKey(herdr: .named("work")), paneID: "p1")
        let first = SelectionTarget(target: target, sessionDisplayName: "work")
        let renamed = SelectionTarget(target: target, sessionDisplayName: "Renamed")
        let otherPane = SelectionTarget(
            target: AgentTarget(session: target.session, paneID: "p2"),
            sessionDisplayName: "work"
        )

        XCTAssertEqual(first, renamed)
        XCTAssertEqual(Set([first, renamed]).count, 1)
        XCTAssertNotEqual(first, otherPane)
    }

    func testHerdrSelectionTargetUsesSessionIDDisplayName() {
        let target = SelectionTarget.herdr(.default, paneID: "p")
        XCTAssertEqual(target.target, AgentTarget(session: AgentSessionKey(herdr: .default), paneID: "p"))
        XCTAssertEqual(target.sessionDisplayName, "Default")
        XCTAssertEqual(SelectionTarget.herdr(.named("work"), paneID: "p").sessionDisplayName, "work")
    }

    func testVisibleLabelOmitsMissingOrDuplicateAgentLabel() {
        XCTAssertEqual(row("p", label: "api", agent: "claude", state: .working).visibleLabel, "api · claude")
        XCTAssertEqual(row("p", label: "claude", agent: "claude", state: .working).visibleLabel, "claude")
        XCTAssertEqual(row("p", label: "Review", agent: nil, state: .finished).visibleLabel, "Review")
    }

    func testAttentionOrderRanksBlockedErrorDoneThenFoldedLabelThenPaneID() {
        let rows = [
            row("d", label: "a", agent: nil, state: .attention(.done)),
            row("e", label: "z", agent: nil, state: .attention(.error)),
            row("b2", label: "Beta", agent: nil, state: .attention(.blocked)),
            row("b1", label: "beta", agent: nil, state: .attention(.blocked)),
            row("b0", label: "alpha", agent: nil, state: .attention(.blocked))
        ]
        XCTAssertEqual(rows.sorted(by: AgentRow.attentionOrder).map(\.target.paneID), ["b0", "b1", "b2", "e", "d"])
        XCTAssertEqual(rows.sorted(by: AgentRow.labelOrder).map(\.target.paneID), ["d", "b0", "b1", "b2", "e"])
    }

    func testFocusErrorDescriptionIsTheFinalMessage() {
        XCTAssertEqual(FocusError.failed("Could not focus pane in work: gone").localizedDescription,
                       "Could not focus pane in work: gone")
        XCTAssertEqual(FocusError.unavailable("Rex is not running").localizedDescription, "Rex is not running")
    }

    private func row(_ paneID: String, label: String, agent: String?, state: RowState) -> AgentRow {
        AgentRow(
            target: AgentTarget(session: AgentSessionKey(herdr: .default), paneID: paneID),
            displayLabel: label,
            agentLabel: agent,
            state: state,
            subtitle: "",
            seenToken: nil
        )
    }
}
