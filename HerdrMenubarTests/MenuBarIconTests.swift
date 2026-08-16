import XCTest
@testable import HerdrMenubar

@MainActor
final class MenuBarIconTests: XCTestCase {
    func testSearchingPresentationIsDimmedHollowAndAccessible() {
        assertDisconnected(.searching, accessibility: "Searching for Herdr sessions")
    }

    func testNoSessionsPresentationIsDimmedHollowAndAccessible() {
        assertDisconnected(.noSessions, accessibility: "No Herdr sessions running")
    }

    func testConnectingPresentationIsDimmedHollowAndAccessible() {
        assertDisconnected(.connecting, accessibility: "Connecting to Herdr sessions")
    }

    func testConnectedClearPresentationUsesSolidLightAndAccessibleNoAttentionText() {
        let presentation = MenuBarIconPresentation(connectionState: .connected, attentionCount: 0)
        XCTAssertEqual(presentation.mode, .clear)
        XCTAssertEqual(presentation.lightStyle, .solid)
        XCTAssertEqual(presentation.opacity, 1)
        XCTAssertFalse(presentation.showsAttentionCount)
        XCTAssertEqual(
            MenuBarIcon.accessibilityValue(connectionState: .connected, attentionCount: 0),
            "Connected, no agents need attention"
        )
    }

    func testConnectedAttentionPresentationEmphasizesLightAndUsesSingularAccessibilityText() {
        let presentation = MenuBarIconPresentation(connectionState: .connected, attentionCount: 1)
        XCTAssertEqual(presentation.mode, .attention)
        XCTAssertEqual(presentation.lightStyle, .emphasizedSolid)
        XCTAssertEqual(presentation.opacity, 1)
        XCTAssertTrue(presentation.showsAttentionCount)
        XCTAssertEqual(
            MenuBarIcon.accessibilityValue(connectionState: .connected, attentionCount: 1),
            "Connected, 1 agent needs attention"
        )
    }

    func testConnectedAttentionAccessibilityUsesPluralCount() {
        XCTAssertEqual(
            MenuBarIcon.accessibilityValue(connectionState: .connected, attentionCount: 4),
            "Connected, 4 agents need attention"
        )
    }

    private func assertDisconnected(_ state: ConnectionState, accessibility: String) {
        let presentation = MenuBarIconPresentation(connectionState: state, attentionCount: 4)
        XCTAssertEqual(presentation.mode, .disconnected)
        XCTAssertEqual(presentation.lightStyle, .hollow)
        XCTAssertEqual(presentation.opacity, 0.55)
        XCTAssertFalse(presentation.showsAttentionCount)
        XCTAssertEqual(
            MenuBarIcon.accessibilityValue(connectionState: state, attentionCount: 4),
            accessibility
        )
    }
}
