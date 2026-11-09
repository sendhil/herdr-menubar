import XCTest
@testable import HerdrMenubar

/// Spec "Rex rows, ranking, and seen-state" → persisted dismissals (r6.6): seen and cleared Rex
/// records stay hidden across launches, keyed by server identity (session, block, record id,
/// state, `updated_at`), never by the in-memory epoch.
final class RexDismissalPersistenceTests: XCTestCase {
    private typealias L = RexLines

    private func lines(_ b1: [L.Rec], _ b2: [L.Rec] = [L.Rec(state: "blocked", at: 1)],
                       extra: [RexWatcherLine] = []) -> [RexWatcherLine] {
        [
            L.session("s1", label: "work"),
            L.view("s1", label: "work", [L.ViewBlock(b: "b1", windowLabel: "One"), L.ViewBlock(b: "b2", windowLabel: "Two")]),
            L.block("s1", "b1", b1),
            L.block("s1", "b2", b2),
        ] + extra + [L.line(["t": "snapshot_done"])]
    }

    /// A fresh reducer (a new launch) that loaded `dismissals` before its first line.
    private func launch(_ dismissals: [RexDismissal], _ lines: [RexWatcherLine]) -> (RexReducerHarness, [BackendEvent]) {
        var h = RexReducerHarness()
        h.reducer.loadDismissals(dismissals)
        let events = h.apply(lines)
        return (h, events)
    }

    private func row(_ h: RexReducerHarness, _ b: String) -> AgentRow? {
        h.reducer.snapshot(forSession: "s1").rows.first { $0.target.paneID == b }
    }

    private func dismissal(_ b: String = "b1", id: String = "", _ state: String = "done", at: Int = 1) -> RexDismissal {
        RexDismissal(sessionID: "s1", blockID: b, recordID: id, state: state, updatedAt: L.micros(at))
    }

    func testMarkSeenRecordsAServerIdentityDismissal() throws {
        var (h, _) = launch([], lines([L.Rec(state: "done", at: 1)]))
        let revision = h.reducer.dismissalsRevision
        h.reducer.markSeen(try XCTUnwrap(row(h, "b1")?.seenToken))

        XCTAssertEqual(h.reducer.dismissals, [dismissal()])
        XCTAssertGreaterThan(h.reducer.dismissalsRevision, revision)
    }

    func testDismissedRecordStaysHiddenAfterRelaunchWithoutFlashingOrNotifying() {
        let (h, events) = launch([dismissal()], lines([L.Rec(state: "done", at: 1)]))

        XCTAssertNil(row(h, "b1"))
        XCTAssertNotNil(row(h, "b2"))
        guard case .connected(_, let first)? = events.first(where: { if case .connected = $0 { true } else { false } }) else {
            return XCTFail("\(events)")
        }
        XCTAssertEqual(first.rows.map(\.target.paneID), ["b2"], "hidden already in the first .connected")
        // The first `.connected` is the coordinator's silent baseline, so nothing in it notifies.
        XCTAssertEqual(Set(first.attention.map(\.target.paneID)), ["b1", "b2"], "attention is never seen-filtered")
        XCTAssertEqual(h.reducer.dismissals, [dismissal()], "a matching dismissal is kept")
    }

    func testNewEmissionWithANewTimestampShowsAgainAndDropsTheDismissal() {
        let (h, _) = launch([dismissal()], lines([L.Rec(state: "done", at: 2)]))

        XCTAssertEqual(row(h, "b1")?.state, .attention(.done))
        XCTAssertEqual(h.reducer.dismissals, [])
    }

    func testDifferentStateWithTheSameTimestampShows() {
        let (h, _) = launch([dismissal()], lines([L.Rec(state: "error", at: 1)]))

        XCTAssertEqual(row(h, "b1")?.state, .attention(.error))
        XCTAssertEqual(h.reducer.dismissals, [])
    }

    func testClearFinishedPersistsDoneAndSettledErrorAcrossRelaunch() {
        let recs = [L.Rec(state: "done", at: 1)]
        let others = [L.Rec(state: "error", at: 1, msg: "exit 1")]
        var (h, _) = launch([], lines(recs, others))
        h.reducer.clearFinished()

        XCTAssertEqual(Set(h.reducer.dismissals), [dismissal(), dismissal("b2", "error")])
        let (relaunched, _) = launch(h.reducer.dismissals, lines(recs, others))
        XCTAssertEqual(relaunched.reducer.snapshot(forSession: "s1").rows, [])
    }

    func testRecordWithoutTimestampIsHiddenInMemoryOnly() throws {
        var (h, _) = launch([], lines([L.Rec(state: "done", at: nil)]))
        h.reducer.markSeen(try XCTUnwrap(row(h, "b1")?.seenToken))

        XCTAssertNil(row(h, "b1"), "still hidden for this run")
        XCTAssertEqual(h.reducer.dismissals, [])
    }

    func testSameStateTimestampChangeWhileRunningStaysHiddenAndUpdatesTheDismissal() throws {
        var (h, _) = launch([], lines([L.Rec(state: "done", at: 1)]))
        h.reducer.markSeen(try XCTUnwrap(row(h, "b1")?.seenToken))

        h.apply(L.block("s1", "b1", [L.Rec(state: "done", at: 3)]))

        XCTAssertNil(row(h, "b1"), "same epoch, so the in-memory mark still applies")
        XCTAssertEqual(h.reducer.dismissals, [dismissal(at: 3)])
    }

    func testRealCycleWhileRunningDropsTheDismissal() throws {
        var (h, _) = launch([], lines([L.Rec(state: "done", at: 1)]))
        h.reducer.markSeen(try XCTUnwrap(row(h, "b1")?.seenToken))

        h.apply(L.block("s1", "b1", [L.Rec(state: "working", at: 2)]))
        XCTAssertEqual(h.reducer.dismissals, [])
    }

    /// Absence from a snapshot proves nothing (a restarting server may list only some sessions),
    /// so only a successful read of the block that lacks the record removes its dismissal.
    func testSnapshotKeepsDismissalsOfAbsentBlocksAndSessionsButDropsRecordsMissingFromARead() {
        let gone = dismissal("b1", id: "child")          // block read, record absent
        let absent = dismissal("b9")                       // block absent from the snapshot
        let unread = dismissal("b3")                       // block whose status read failed
        let otherSession = RexDismissal(sessionID: "s2", blockID: "b1", recordID: "", state: "done", updatedAt: 1)
        let (h, _) = launch([gone, absent, unread, otherSession, dismissal()], lines(
            [L.Rec(state: "done", at: 1)],
            extra: [L.line(["t": "status_error", "s": "s1", "b": "b3", "err": "boom"])]
        ))

        XCTAssertEqual(Set(h.reducer.dismissals), [absent, unread, otherSession, dismissal()])
    }

    func testBlockClosedAndSessionDestroyedRemoveDismissals() {
        let other = RexDismissal(sessionID: "s2", blockID: "b1", recordID: "", state: "done", updatedAt: 1)
        var (h, _) = launch([dismissal(), dismissal("b9"), other], lines([L.Rec(state: "done", at: 1)]))

        h.apply(L.line(["t": "block_closed", "s": "s1", "b": "b9"]))
        XCTAssertEqual(Set(h.reducer.dismissals), [dismissal(), other])
        h.apply(L.line(["t": "session_destroyed", "s": "s2"]))
        XCTAssertEqual(h.reducer.dismissals, [dismissal()])
        h.apply(L.line(["t": "block_closed", "s": "s1", "b": "b1"]))
        XCTAssertEqual(h.reducer.dismissals, [])
    }

    func testGoneReadDoesNotRemoveTheDismissal() {
        var (h, _) = launch([dismissal()], lines([L.Rec(state: "done", at: 1)]))
        h.apply(L.block("s1", "b1", [], gone: true))
        XCTAssertEqual(h.reducer.dismissals, [dismissal()], "block_closed decides; a 404 can be transient")
    }

    func testServerRestartWithAPartialSessionListKeepsTheDismissal() throws {
        var (h, _) = launch([], lines([L.Rec(state: "done", at: 1)]))
        h.reducer.markSeen(try XCTUnwrap(row(h, "b1")?.seenToken))

        // The server restarts and its first snapshot lists no sessions yet.
        h.restart()
        h.apply(L.line(["t": "snapshot_done"]))
        XCTAssertEqual(h.reducer.dismissals, [dismissal()])

        // The session comes back with the same done record: still hidden.
        h.restart()
        h.apply(lines([L.Rec(state: "done", at: 1)]))
        XCTAssertNil(row(h, "b1"))
        XCTAssertEqual(h.reducer.dismissals, [dismissal()])
    }

    func testDismissalsBeforeAnySnapshotAreNotPruned() {
        var h = RexReducerHarness()
        h.reducer.loadDismissals([dismissal("b9")])
        h.apply([L.session("s1", label: "work"), L.block("s1", "b1", [L.Rec(state: "done", at: 1)])])
        XCTAssertEqual(h.reducer.dismissals, [dismissal("b9")])
    }

    func testDismissalsAreCappedToTheNewest() throws {
        let many = (0..<(RexReducer.dismissalCap + 20)).map { dismissal("old\($0)") }
        var (h, _) = launch([], lines([L.Rec(state: "done", at: 1)]))
        h.reducer.loadDismissals(many)
        XCTAssertEqual(h.reducer.dismissals, Array(many.suffix(RexReducer.dismissalCap)))

        h.reducer.markSeen(try XCTUnwrap(row(h, "b1")?.seenToken))
        XCTAssertEqual(h.reducer.dismissals.count, RexReducer.dismissalCap)
        XCTAssertEqual(h.reducer.dismissals.last, dismissal(), "the newest dismissal is kept")
        XCTAssertFalse(h.reducer.dismissals.contains(dismissal("old20")), "the oldest is evicted")
    }

    func testResetForgetsLoadedDismissals() {
        var h = RexReducerHarness()
        h.reducer.loadDismissals([dismissal()])
        h.reducer.reset()
        XCTAssertEqual(h.reducer.dismissals, [], "stop() resets; start() reloads from the store")
    }

    // MARK: Store

    func testUserDefaultsStoreRoundTripsAndIgnoresMalformedData() throws {
        let suite = "dev.herdr.menubar.tests.dismissals.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsRexDismissalStore(defaults: defaults)

        XCTAssertEqual(store.load(), [])
        store.save([dismissal(), dismissal("b2", "error", at: 4)])
        XCTAssertNotNil(defaults.data(forKey: UserDefaultsRexDismissalStore.key))
        XCTAssertEqual(UserDefaultsRexDismissalStore(defaults: defaults).load(), [dismissal(), dismissal("b2", "error", at: 4)])

        defaults.set("garbage", forKey: UserDefaultsRexDismissalStore.key)
        XCTAssertEqual(store.load(), [])
        XCTAssertEqual(UserDefaultsRexDismissalStore.key, "rexDismissedRecords")
    }
}
