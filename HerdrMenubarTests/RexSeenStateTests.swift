import XCTest
@testable import HerdrMenubar

final class RexSeenStateTests: XCTestCase {
    private typealias L = RexLines

    private func started(_ b1: [L.Rec], _ b2: [L.Rec] = []) -> RexReducerHarness {
        var h = RexReducerHarness()
        h.apply([
            L.session("s1", label: "work"),
            L.view("s1", label: "work", [L.ViewBlock(b: "b1", windowLabel: "One"), L.ViewBlock(b: "b2", windowLabel: "Two")]),
            L.block("s1", "b1", b1),
            L.block("s1", "b2", b2),
            L.line(["t": "snapshot_done"]),
        ])
        return h
    }

    private func row(_ h: RexReducerHarness, _ b: String) -> AgentRow? {
        h.reducer.snapshot(forSession: "s1").rows.first { $0.target.paneID == b }
    }

    func testTokenCoversEveryDoneAndErrorRecordOfTheBlockBeforeHiding() throws {
        let h = started([L.Rec(state: "working", at: 1), L.Rec(id: "c", state: "done", at: 1),
                         L.Rec(id: "e", state: "error", at: 1)],
                        [L.Rec(state: "blocked", at: 1)])
        let token = try XCTUnwrap(row(h, "b1")?.seenToken)
        XCTAssertEqual(token.marks.count, 2)
        XCTAssertNil(row(h, "b2")?.seenToken, "a block without done/error records has no token")
    }

    func testMarkSeenHidesTheCurrentEpochAndEmitsASnapshotButKeepsAttention() throws {
        var h = started([L.Rec(state: "done", at: 1, app: "claude-code")], [L.Rec(state: "error", at: 1)])
        let token = try XCTUnwrap(row(h, "b1")?.seenToken)

        let events = h.reducer.markSeen(token)
        let snapshot = try XCTUnwrap(events.lastSnapshot("s1"))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(snapshot.rows.map(\.target.paneID), ["b2"])
        XCTAssertEqual(Set(snapshot.attention.map(\.target.paneID)), ["b1", "b2"], "attention is never seen-filtered")
        XCTAssertEqual(h.reducer.markSeen(token), [], "marking again changes nothing")
    }

    func testSeenTerminalRecordRevealsTheNextRankedRecord() throws {
        var h = started([L.Rec(state: "error", at: 1, msg: "exit 2"), L.Rec(id: "c", state: "done", at: 1, app: "pi")])
        XCTAssertEqual(row(h, "b1")?.state, .attention(.error))
        let token = try XCTUnwrap(row(h, "b1")?.seenToken)
        h.reducer.markSeen(token)
        XCTAssertNil(row(h, "b1"), "the token covered both records")

        var h2 = started([L.Rec(state: "error", at: 1, msg: "exit 2")])
        let errorOnly = try XCTUnwrap(row(h2, "b1")?.seenToken)
        h2.apply(L.block("s1", "b1", [L.Rec(state: "error", at: 1, msg: "exit 2"), L.Rec(id: "c", state: "done", at: 2)],
                         via: L.changed(id: "c", "done", at: 2)))
        h2.reducer.markSeen(errorOnly)
        XCTAssertEqual(row(h2, "b1")?.state, .attention(.done))
        XCTAssertEqual(row(h2, "b1")?.seenToken?.marks.count, 2, "the token still lists hidden records")
    }

    func testRecordThatChangedDuringFocusStaysVisible() throws {
        var h = started([L.Rec(state: "done", at: 1)])
        let token = try XCTUnwrap(row(h, "b1")?.seenToken)
        h.apply(L.block("s1", "b1", [L.Rec(state: "done", at: 3)], via: L.changed("working", at: 2)))
        XCTAssertEqual(h.reducer.markSeen(token), [])
        XCTAssertEqual(row(h, "b1")?.state, .attention(.done))
    }

    func testNewEpochShowsAgainAndPrunesTheMark() throws {
        var h = started([L.Rec(state: "done", at: 1)])
        h.reducer.markSeen(try XCTUnwrap(row(h, "b1")?.seenToken))
        XCTAssertNil(row(h, "b1"))

        let events = h.apply(L.block("s1", "b1", [L.Rec(state: "done", at: 3)], via: L.changed("working", at: 2))).events
        XCTAssertEqual(events.lastSnapshot("s1")?.rows.map(\.state), [.attention(.done)])
        XCTAssertEqual(h.reducer.seenMarkCount, 0)
    }

    func testMarksArePrunedWhenRecordsDisappear() throws {
        var h = started([L.Rec(state: "done", at: 1)], [L.Rec(state: "done", at: 1)])
        h.reducer.markSeen(try XCTUnwrap(row(h, "b1")?.seenToken))
        h.reducer.markSeen(try XCTUnwrap(row(h, "b2")?.seenToken))
        XCTAssertEqual(h.reducer.seenMarkCount, 2)

        h.apply(L.block("s1", "b1", [], gone: true))
        h.apply(L.line(["t": "block_closed", "s": "s1", "b": "b2"]))
        XCTAssertEqual(h.reducer.seenMarkCount, 0)

        h.apply(L.block("s1", "b1", [L.Rec(state: "done", at: 1)]))
        XCTAssertEqual(row(h, "b1")?.state, .attention(.done), "a recreated record has a new epoch and shows")
    }

    func testClearFinishedMarksVisibleDoneAndSettledErrorRecords() {
        var h = started([L.Rec(state: "done", at: 1)],
                        [L.Rec(state: "error", at: 1), L.Rec(id: "d", state: "done", at: 1)])
        h.apply(L.block("s1", "b3", [L.Rec(state: "done", at: 1)]))   // held: not in the view

        let events = h.reducer.clearFinished()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.lastSnapshot("s1")?.rows.map(\.target.paneID), [])
        XCTAssertEqual(h.reducer.seenMarkCount, 3, "both placed done records and the settled error, not the held block")
        XCTAssertNil(row(h, "b1"))
        XCTAssertNil(row(h, "b2"), "the settled error is cleared too")
        XCTAssertEqual(h.reducer.clearFinished(), [])
    }

    func testClearFinishedDismissesASettledErrorAndDropsTheAttentionRow() throws {
        var h = started([L.Rec(state: "working", at: 1)])
        h.apply(L.block("s1", "b1", [L.Rec(state: "error", at: 2, app: "pi-subagents", title: "workflow", msg: "Failed")],
                        via: L.changed("error", at: 2)))
        h.advance(.seconds(2))
        XCTAssertEqual(row(h, "b1")?.state, .attention(.error))

        let snapshot = try XCTUnwrap(h.reducer.clearFinished().lastSnapshot("s1"))
        XCTAssertFalse(snapshot.rows.contains { if case .attention = $0.state { true } else { false } },
                       "no attention row is left to hold the badge up")
        XCTAssertNil(row(h, "b1"))
    }

    func testClearFinishedLeavesAnUnsettledErrorVisible() {
        var h = started([L.Rec(state: "working", at: 1)])
        h.apply(L.block("s1", "b1", [L.Rec(state: "error", at: 2)], via: L.changed("error", at: 2)))

        XCTAssertEqual(h.reducer.clearFinished(), [])
        XCTAssertEqual(h.reducer.seenMarkCount, 0, "an error still inside flap protection is not cleared")
        h.advance(.seconds(2))
        XCTAssertEqual(row(h, "b1")?.state, .attention(.error))
    }

    func testErrorReportedAgainAfterClearFinishedShowsAgain() {
        var h = started([L.Rec(state: "error", at: 1)])
        h.reducer.clearFinished()
        XCTAssertNil(row(h, "b1"))

        h.apply(L.block("s1", "b1", [L.Rec(state: "working", at: 2)], via: L.changed("working", at: 2)))
        let events = h.apply(L.block("s1", "b1", [L.Rec(state: "error", at: 3)], via: L.changed("error", at: 3))).events
            + h.advance(.seconds(2))
        XCTAssertEqual(row(h, "b1")?.state, .attention(.error), "a new epoch shows again")
        XCTAssertEqual(events.lastSnapshot("s1")?.attention.map(\.state), [.error], "and is reported for notification again")
    }

    func testMarksPersistAcrossGenerationsAndResetClearsThem() throws {
        var h = started([L.Rec(state: "done", at: 1)])
        h.reducer.markSeen(try XCTUnwrap(row(h, "b1")?.seenToken))

        h.restart()
        let lines = [
            L.session("s1", label: "work"),
            L.view("s1", label: "work", [L.ViewBlock(b: "b1", windowLabel: "One")]),
            L.block("s1", "b1", [L.Rec(state: "done", at: 1)]),
            L.line(["t": "snapshot_done"]),
        ]
        XCTAssertEqual(h.apply(lines).lastSnapshot("s1")?.rows, [])

        h.reducer.reset()
        h.restart()
        XCTAssertEqual(h.apply(lines).lastSnapshot("s1")?.rows.map(\.state), [.attention(.done)])
    }

    func testMarkSeenBeforeSnapshotDoneEmitsNothing() throws {
        var h = started([L.Rec(state: "done", at: 1)])
        let token = try XCTUnwrap(row(h, "b1")?.seenToken)
        h.restart()
        h.apply([L.session("s1"), L.view("s1", [L.ViewBlock(b: "b1")]), L.block("s1", "b1", [L.Rec(state: "done", at: 1)])])
        XCTAssertEqual(h.reducer.markSeen(token), [])
        XCTAssertEqual(h.reducer.seenMarkCount, 1)
    }
}
