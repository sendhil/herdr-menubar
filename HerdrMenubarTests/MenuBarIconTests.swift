import XCTest
@testable import HerdrMenubar

final class MenuBarIconTests: XCTestCase {
    func testDisconnectedPresentationIsDimmedWithHollowLightAndNoCount() {
        let presentation = MenuBarIconPresentation(
            connectionState: .disconnected("Herdr unavailable"),
            attentionCount: 3
        )

        XCTAssertEqual(presentation.mode, .disconnected)
        XCTAssertEqual(presentation.lightStyle, .hollow)
        XCTAssertEqual(presentation.opacity, 0.55)
        XCTAssertFalse(presentation.showsAttentionCount)
    }

    func testConnectedClearPresentationUsesNormalTerminalAndSolidLight() {
        let presentation = MenuBarIconPresentation(
            connectionState: .connected,
            attentionCount: 0
        )

        XCTAssertEqual(presentation.mode, .clear)
        XCTAssertEqual(presentation.lightStyle, .solid)
        XCTAssertEqual(presentation.opacity, 1)
        XCTAssertFalse(presentation.showsAttentionCount)
    }

    func testAttentionPresentationEmphasizesSolidLightAndShowsCount() {
        let presentation = MenuBarIconPresentation(
            connectionState: .connected,
            attentionCount: 4
        )

        XCTAssertEqual(presentation.mode, .attention)
        XCTAssertEqual(presentation.lightStyle, .emphasizedSolid)
        XCTAssertEqual(presentation.opacity, 1)
        XCTAssertTrue(presentation.showsAttentionCount)
    }
}
