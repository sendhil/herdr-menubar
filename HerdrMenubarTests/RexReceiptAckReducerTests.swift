import XCTest
@testable import HerdrMenubar

/// Passive acknowledgement: a Rex "viewed" receipt exactly matching a root Done/Error result's
/// current `updated_at` (millisecond truncation) hides that result once, through the seen marks.
final class RexReceiptAckReducerTests: XCTestCase {
    private typealias L = RexLines

    private func started(_ b1: [L.Rec], _ b2: [L.Rec] = [L.Rec(state: "blocked", at: 1)]) -> RexReducerHarness {
        var h = RexReducerHarness()
        h.apply(snapshotLines(b1, b2))
        return h
    }

    private func snapshotLines(_ b1: [L.Rec], _ b2: [L.Rec]) -> [RexWatcherLine] {
        [
            L.session("s1", label: "work"),
            L.view("s1", label: "work", [L.ViewBlock(b: "b1", windowLabel: "One"), L.ViewBlock(b: "b2", windowLabel: "Two")]),
            L.block("s1", "b1", b1),
            L.block("s1", "b2", b2),
            L.line(["t": "snapshot_done"]),
        ]
    }

    private func receipt(_ b: String = "b1", record: String = "", at: Int = 1, plusMillis: Int64 = 0) -> RexViewReceipt {
        RexViewReceipt(blockID: b, recordID: record, millis: L.micros(at) / 1000 + plusMillis)
    }

    private func visible(_ h: RexReducerHarness, _ b: String = "b1") -> Bool {
        h.reducer.snapshot(forSession: "s1").rows.contains { $0.target.paneID == b }
    }

    func testExactMillisecondReceiptHidesRootDoneAndEmitsSnapshot() {
        var h = started([L.Rec(state: "done", at: 1)])
        let events = h.reducer.acknowledgeViewedReceipts([receipt()])
        XCTAssertFalse(visible(h))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(h.reducer.dismissals.count, 1, "persisted by server identity")
    }

    func testExactMillisecondReceiptHidesRootError() {
        var h = started([L.Rec(state: "error", at: 1)])
        h.reducer.acknowledgeViewedReceipts([receipt()])
        XCTAssertFalse(visible(h))
    }

    func testMillisecondOffByOneDoesNotHide() {
        var h = started([L.Rec(state: "done", at: 1)])
        XCTAssertTrue(h.reducer.acknowledgeViewedReceipts([receipt(plusMillis: 1)]).isEmpty)
        XCTAssertTrue(h.reducer.acknowledgeViewedReceipts([receipt(plusMillis: -1)]).isEmpty)
        XCTAssertTrue(visible(h))
    }

    func testReceiptIsTruncatedFromMicroseconds() {
        // A record with microseconds below the ms boundary matches the truncated millisecond.
        XCTAssertEqual(RexViewReceipt.millis(fromMicroseconds: 1_794_340_072_177_061), 1_794_340_072_177)
    }

    func testNewerResultAfterReceiptStaysVisible() {
        var h = started([L.Rec(state: "done", at: 1)])
        h.reducer.acknowledgeViewedReceipts([receipt(at: 1)])
        h.apply(L.block("s1", "b1", [L.Rec(state: "working", at: 2)]))
        h.apply(L.block("s1", "b1", [L.Rec(state: "done", at: 3)]))
        XCTAssertTrue(h.reducer.acknowledgeViewedReceipts([receipt(at: 1)]).isEmpty, "old receipt never matches")
        XCTAssertTrue(visible(h))
    }

    func testChildRecordsAndChildReceiptsNeverAcknowledgeRoot() {
        var h = started([L.Rec(id: "c", state: "done", at: 1)])
        XCTAssertTrue(h.reducer.acknowledgeViewedReceipts([receipt(record: "c")]).isEmpty)
        XCTAssertTrue(visible(h))
        var h2 = started([L.Rec(state: "done", at: 1)])
        XCTAssertTrue(h2.reducer.acknowledgeViewedReceipts([receipt(record: "c")]).isEmpty)
        XCTAssertTrue(visible(h2))
    }

    func testBlockedAndWorkingNeverHide() {
        var h = started([L.Rec(state: "blocked", at: 1)], [L.Rec(state: "working", at: 1)])
        XCTAssertTrue(h.reducer.acknowledgeViewedReceipts([receipt("b1"), receipt("b2")]).isEmpty)
        XCTAssertTrue(visible(h, "b1"))
        XCTAssertTrue(visible(h, "b2"))
    }

    func testOtherBlockReceiptDoesNothing() {
        var h = started([L.Rec(state: "done", at: 1)], [L.Rec(state: "done", at: 2)])
        h.reducer.acknowledgeViewedReceipts([receipt("b2", at: 2)])
        XCTAssertTrue(visible(h, "b1"))
        XCTAssertFalse(visible(h, "b2"))
    }

    func testUnavailableReceiptsChangeNothing() {
        var h = started([L.Rec(state: "done", at: 1)])
        XCTAssertTrue(h.reducer.acknowledgeViewedReceipts(nil).isEmpty)
        XCTAssertTrue(visible(h))
    }

    func testConsumedOnceAcrossSameResultReReportAndLaterResult() {
        var h = started([L.Rec(state: "done", at: 1)])
        h.reducer.acknowledgeViewedReceipts([receipt(at: 1)])
        h.apply(L.block("s1", "b1", [L.Rec(state: "done", at: 1)]))
        XCTAssertFalse(visible(h), "same result re-reported stays seen")
        // A later result at a different time shows again even while the old receipt persists.
        h.apply(L.block("s1", "b1", [L.Rec(state: "working", at: 2)]))
        h.apply(L.block("s1", "b1", [L.Rec(state: "done", at: 3)]))
        h.reducer.acknowledgeViewedReceipts([receipt(at: 1)])
        XCTAssertTrue(visible(h))
    }

    func testStartupExistingDoneIsClearedByAnExactReceipt() {
        var h = RexReducerHarness()
        h.reducer.loadDismissals(nil)   // first run: seeding dismisses it already; use stored []
        h = RexReducerHarness()
        h.reducer.loadDismissals([])
        h.apply(snapshotLines([L.Rec(state: "done", at: 1)], [L.Rec(state: "blocked", at: 1)]))
        XCTAssertTrue(visible(h))
        h.reducer.acknowledgeViewedReceipts([receipt()])
        XCTAssertFalse(visible(h))
    }

    func testSameMillisecondDifferentResultsAreAmbiguousAndNotAcknowledged() {
        var h = started([L.Rec(state: "done", at: 1)])
        h.apply(L.block("s1", "b1", [L.Rec(state: "working", at: 1)]))
        h.apply(L.block("s1", "b1", [L.Rec(state: "done", at: 1)]))
        XCTAssertTrue(h.reducer.acknowledgeViewedReceipts([receipt()]).isEmpty)
        XCTAssertTrue(visible(h))
    }

    func testClearFinishedStillWorksAndNoEventsBeforeSnapshotDone() {
        var h = started([L.Rec(state: "done", at: 1)])
        XCTAssertFalse(h.reducer.clearFinished().isEmpty)
        XCTAssertFalse(visible(h))

        var fresh = RexReducerHarness()
        XCTAssertTrue(fresh.reducer.acknowledgeViewedReceipts([receipt()]).isEmpty)
    }

    func testUnsettledErrorIsNotAcknowledged() {
        var h = started([L.Rec(state: "working", at: 1)])
        h.apply(L.block("s1", "b1", [L.Rec(state: "error", at: 2)]))
        XCTAssertTrue(h.reducer.acknowledgeViewedReceipts([receipt(at: 2)]).isEmpty)
        XCTAssertTrue(visible(h))
    }
}
