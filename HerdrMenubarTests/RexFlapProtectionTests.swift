import XCTest
@testable import HerdrMenubar

final class RexFlapProtectionTests: XCTestCase {
    private typealias L = RexLines

    private func snapshotLines(_ b1: [L.Rec], session: String = "s1") -> [RexWatcherLine] {
        [
            L.session(session, label: "work"),
            L.view(session, label: "work", [L.ViewBlock(b: "b1", windowLabel: "One")]),
            L.block(session, "b1", b1),
            L.line(["t": "snapshot_done"]),
        ]
    }

    private func attention(_ events: [BackendEvent], _ s: String = "s1") -> [AttentionState]? {
        events.lastSnapshot(s)?.attention.map(\.state)
    }

    func testFirstSuccessfulSnapshotSettlesImmediately() {
        var h = RexReducerHarness()
        XCTAssertEqual(attention(h.apply(snapshotLines([L.Rec(state: "blocked", at: 1)]))), [.blocked])
        XCTAssertNil(h.reducer.nextSettleDeadline)
    }

    func testFailedFirstAttemptDoesNotCountAsTheFirstSnapshot() {
        var h = RexReducerHarness()
        h.apply([L.session("s1"), L.line(["t": "snapshot_error", "err": "boom"])])
        h.restart()
        XCTAssertEqual(attention(h.apply(snapshotLines([L.Rec(state: "blocked", at: 1)]))), [.blocked])
    }

    func testLiveTransitionSettlesAfterOnePointFiveSeconds() throws {
        var h = RexReducerHarness()
        h.apply(snapshotLines([L.Rec(state: "working", at: 1)]))

        let changed = h.apply(L.block("s1", "b1", [L.Rec(state: "blocked", at: 2, msg: "Allow?")],
                                      via: L.changed("blocked", at: 2))).events
        XCTAssertEqual(changed.lastSnapshot("s1")?.rows.map(\.state), [.attention(.blocked)], "rows update immediately")
        XCTAssertEqual(attention(changed), [])
        XCTAssertEqual(h.reducer.nextSettleDeadline, h.now + .milliseconds(1500))

        XCTAssertEqual(h.advance(.milliseconds(1499)), [])
        let settled = h.advance(.milliseconds(1))
        XCTAssertEqual(attention(settled), [.blocked])
        XCTAssertEqual(settled.count, 1)
        XCTAssertNil(h.reducer.nextSettleDeadline)
        XCTAssertEqual(h.advance(.seconds(5)), [])
    }

    func testFlappingFasterThanTheSettleDelayNeverReachesAttention() {
        var h = RexReducerHarness()
        h.apply(snapshotLines([L.Rec(state: "working", at: 1)]))
        var events: [BackendEvent] = []
        for i in 0..<6 {
            let state = i.isMultiple(of: 2) ? "blocked" : "working"
            events += h.apply(L.block("s1", "b1", [L.Rec(state: state, at: 2 + i)], via: L.changed(state, at: 2 + i))).events
            events += h.advance(.milliseconds(700))
        }
        XCTAssertFalse(events.compactMap(\.snapshotPayload).contains { !$0.1.attention.isEmpty })

        h.apply(L.block("s1", "b1", [L.Rec(state: "blocked", at: 20)], via: L.changed("blocked", at: 20)))
        XCTAssertEqual(attention(h.advance(.milliseconds(1500))), [.blocked], "one that settles is reported once")
    }

    func testSettledRecordLeavesAttentionImmediatelyWhenItsEpochChanges() {
        var h = RexReducerHarness()
        h.apply(snapshotLines([L.Rec(state: "error", at: 1)]))
        let events = h.apply(L.block("s1", "b1", [L.Rec(state: "error", at: 3)], via: L.changed("working", at: 2))).events
        XCTAssertEqual(attention(events), [], "the new error epoch must settle on its own")
        XCTAssertEqual(attention(h.advance(.milliseconds(1500))), [.error])
    }

    func testDisappearingRecordLeavesAttentionImmediately() {
        var h = RexReducerHarness()
        h.apply(snapshotLines([L.Rec(state: "blocked", at: 1)]))
        XCTAssertEqual(attention(h.apply(L.block("s1", "b1", [], via: L.removed([""]))).events), [])
    }

    func testLiveCreatedSessionIsNotSettledImmediately() {
        var h = RexReducerHarness()
        h.apply(snapshotLines([]))
        h.apply([L.line(["t": "session_created", "s": "s2", "label": "new"]),
                 L.view("s2", label: "new", [L.ViewBlock(b: "c1")])])
        let events = h.apply(L.block("s2", "c1", [L.Rec(state: "blocked", at: 3)], via: L.changed("blocked", at: 3))).events
        XCTAssertEqual(attention(events, "s2"), [])
        XCTAssertEqual(attention(h.advance(.milliseconds(1500)), "s2"), [.blocked])
    }

    func testRestartKeepsSettledEpochsAndOutageTransitionsSettleBeforeNotifying() {
        var h = RexReducerHarness()
        h.apply(snapshotLines([L.Rec(state: "blocked", at: 1)]))
        h.restart()
        h.apply(Array(snapshotLines([L.Rec(state: "blocked", at: 1)]).dropLast()))
        h.apply(Array(snapshotLines([L.Rec(state: "error", at: 9)], session: "s3").dropLast()))
        let restart = h.apply(L.line(["t": "snapshot_done"])).events
        XCTAssertEqual(attention(restart, "s1"), [.blocked], "an unchanged epoch is still settled")
        XCTAssertEqual(attention(restart, "s3"), [.error], "a session created during the outage is a silent baseline")

        h.restart()
        let changed = h.apply(snapshotLines([L.Rec(state: "error", at: 5)]))
        XCTAssertEqual(attention(changed, "s1"), [], "a new epoch in a known session must settle")
        let settled = h.advance(.milliseconds(1500))
        XCTAssertEqual(settled.map(\.snapshotPayload?.0), [rexKey("s1")])
        XCTAssertEqual(attention(settled, "s1"), [.error])
    }

    func testSettleTimerDuringAnOutageEmitsNothingAndCarriesIntoTheNextSnapshot() {
        var h = RexReducerHarness()
        h.apply(snapshotLines([L.Rec(state: "working", at: 1)]))
        h.apply(L.block("s1", "b1", [L.Rec(state: "blocked", at: 2)], via: L.changed("blocked", at: 2)))
        _ = h.advance(.milliseconds(500))
        h.restart()
        XCTAssertNotNil(h.reducer.nextSettleDeadline, "settle timers persist across generations")
        XCTAssertEqual(h.advance(.milliseconds(1000)), [], "the store hears nothing during an outage")
        XCTAssertEqual(attention(h.apply(snapshotLines([L.Rec(state: "blocked", at: 2)]))), [.blocked])
    }

    func testLatePlacedBlockEntersAttentionWithItsSettledStatus() {
        var h = RexReducerHarness()
        h.apply(snapshotLines([]))
        h.apply(L.block("s1", "b9", [L.Rec(state: "blocked", at: 2)], via: L.changed("blocked", at: 2)))
        XCTAssertEqual(h.advance(.milliseconds(1500)), [], "held blocks produce nothing")
        let placed = h.apply(L.view("s1", label: "work", [L.ViewBlock(b: "b1", windowLabel: "One"),
                                                         L.ViewBlock(b: "b9", windowLabel: "Float")])).events
        XCTAssertEqual(attention(placed), [.blocked])
    }

    func testApplyingALineAfterTheDeadlineSettlesWithoutATick() {
        var h = RexReducerHarness()
        h.apply(snapshotLines([L.Rec(state: "working", at: 1)]))
        h.apply(L.block("s1", "b1", [L.Rec(state: "blocked", at: 2)], via: L.changed("blocked", at: 2)))
        h.elapsed += .seconds(2)
        XCTAssertEqual(attention(h.apply(L.line(["t": "heartbeat"])).events), [.blocked])
    }

    func testResetDropsPendingTimersAndSettledStatus() {
        var h = RexReducerHarness()
        h.apply(snapshotLines([L.Rec(state: "working", at: 1)]))
        h.apply(L.block("s1", "b1", [L.Rec(state: "blocked", at: 2)], via: L.changed("blocked", at: 2)))
        h.reducer.reset()
        XCTAssertNil(h.reducer.nextSettleDeadline)
        XCTAssertEqual(h.reducer.tick(now: h.now + .seconds(10)), [])
        h.restart()
        XCTAssertEqual(attention(h.apply(snapshotLines([L.Rec(state: "blocked", at: 2)]))), [.blocked],
                       "the next start is a fresh first snapshot")
    }

    func testOverdueSettleIsEmittedBeforeALineThatReplacesTheRecord() throws {
        var h = RexReducerHarness()
        h.apply(snapshotLines([L.Rec(state: "working", at: 1)]))
        h.apply(L.block("s1", "b1", [L.Rec(state: "blocked", at: 2)], via: L.changed("blocked", at: 2)))
        h.elapsed += .milliseconds(1600)   // the settle timer ran late: no tick

        let events = h.apply(L.block("s1", "b1", [L.Rec(state: "working", at: 4)], via: L.changed("working", at: 4))).events
        let snapshots = events.compactMap(\.snapshotPayload)
        XCTAssertEqual(snapshots.count, 2, "\(events)")
        XCTAssertEqual(snapshots.first?.1.attention.map(\.state), [.blocked], "the settled blocked epoch surfaces first")
        XCTAssertEqual(snapshots.last?.1.attention.map(\.state), [])
        XCTAssertEqual(snapshots.last?.1.rows.map(\.state), [.working])
    }

    func testEndGenerationSuppressesEmissionsUntilTheNextSnapshotDone() {
        var h = RexReducerHarness()
        h.apply(snapshotLines([L.Rec(state: "working", at: 1), L.Rec(id: "c", state: "done", at: 1)]))
        h.apply(L.block("s1", "b1", [L.Rec(state: "blocked", at: 2), L.Rec(id: "c", state: "done", at: 1)],
                        via: L.changed("blocked", at: 2)))
        h.reducer.endGeneration()

        XCTAssertFalse(h.reducer.isSnapshotDone)
        XCTAssertEqual(h.advance(.seconds(2)), [], "tick during backoff emits nothing")
        XCTAssertEqual(h.reducer.clearFinished(), [])
        XCTAssertEqual(h.apply(L.line(["t": "heartbeat"])).events, [], "lines of the ended generation are ignored")

        h.restart()
        let events = h.apply(snapshotLines([L.Rec(state: "blocked", at: 2), L.Rec(id: "c", state: "done", at: 1)]))
        XCTAssertEqual(attention(events), [.blocked, .done], "settled during the gap, reported with the next snapshot")
    }
}
