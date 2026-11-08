import XCTest
@testable import HerdrMenubar

final class LatestNotificationTargetStoreTests: XCTestCase {
    func testStoreRejectsOlderAcceptedOrdinalAndResetClearsMemory() async {
        let store = LatestNotificationTargetStore()
        let old = SelectionTarget.herdr(.default, paneID: "old")
        let newest = SelectionTarget.herdr(.named("work"), paneID: "new")

        await store.record(old, ordinal: 1)
        await store.record(newest, ordinal: 3)
        await store.record(old, ordinal: 2)
        let latest = await store.latest()
        XCTAssertEqual(latest, newest)

        await store.reset()
        let resetLatest = await store.latest()
        XCTAssertNil(resetLatest)
    }

    func testSealAndResetPermanentlyRejectsLaterRecordsAndIsIdempotent() async {
        let store = LatestNotificationTargetStore()
        let beforeSeal = SelectionTarget.herdr(.default, paneID: "before")
        let acceptedLate = SelectionTarget.herdr(.named("work"),
            paneID: "accepted-late"
        )
        await store.record(beforeSeal, ordinal: 1)

        await store.sealAndReset()
        await store.record(acceptedLate, ordinal: .max)
        await store.reset()
        await store.sealAndReset()

        let latest = await store.latest()
        XCTAssertNil(latest)
    }
}
