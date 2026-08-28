import XCTest
@testable import HerdrMenubar

final class LatestNotificationTargetStoreTests: XCTestCase {
    func testStoreRejectsOlderAcceptedOrdinalAndResetClearsMemory() async {
        let store = LatestNotificationTargetStore()
        let old = NotificationSelectionTarget(sessionID: .default, paneID: "old")
        let newest = NotificationSelectionTarget(sessionID: .named("work"), paneID: "new")

        await store.record(old, ordinal: 1)
        await store.record(newest, ordinal: 3)
        await store.record(old, ordinal: 2)
        let latest = await store.latest()
        XCTAssertEqual(latest, newest)

        await store.reset()
        let resetLatest = await store.latest()
        XCTAssertNil(resetLatest)
    }
}
