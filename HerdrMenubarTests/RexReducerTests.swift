import XCTest
@testable import HerdrMenubar

final class RexReducerTests: XCTestCase {
    private typealias L = RexLines

    private func rk(_ s: String, _ b: String, _ id: String = "") -> RexRecordKey {
        RexRecordKey(sessionID: s, blockID: b, recordID: id)
    }

    /// One session with a named-window block (`b1`) and a default-labeled block (`b2`).
    private func snapshotLines(b1: [L.Rec], b2: [L.Rec] = []) -> [RexWatcherLine] {
        [
            L.session("s1", label: "fix-playback"),
            L.view("s1", label: "fix-playback", [
                L.ViewBlock(b: "b1", windowLabel: "Playback"),
                L.ViewBlock(b: "b2"),
            ]),
            L.block("s1", "b1", b1),
            L.block("s1", "b2", b2),
            L.line(["t": "snapshot_done"]),
        ]
    }

    // MARK: Snapshot

    func testSnapshotEmitsDiscoveryThenConnectedWithRowsAndAttention() {
        var h = RexReducerHarness()
        let events = h.apply(snapshotLines(
            b1: [L.Rec(state: "blocked", at: 1, app: "pi", msg: "Allow rm -rf\nbuild?", kind: "permission")],
            b2: [L.Rec(state: "done", at: 2, app: "claude-code")]
        ))

        let descriptor = rexDescriptor("s1", "fix-playback")
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first, .discovery([descriptor]))
        guard case .connected(let connected, let snapshot) = events.last else { return XCTFail("\(events)") }
        XCTAssertEqual(connected, descriptor)
        XCTAssertEqual(snapshot.rows.map(\.displayLabel), ["fix-playback", "Playback"])
        XCTAssertEqual(snapshot.rows.map(\.state), [.finished, .attention(.blocked)])
        XCTAssertEqual(snapshot.rows.map(\.subtitle), ["done · claude-code", "blocked · Allow rm -rf build?"])
        XCTAssertEqual(snapshot.attention.map(\.state), [.done, .blocked])
        XCTAssertEqual(snapshot.attention.last, AttentionRecord(
            target: AgentTarget(session: rexKey("s1"), paneID: "b1"), recordID: "",
            epoch: h.reducer.epoch(of: rk("s1", "b1"))!, state: .blocked,
            visibleLabel: "Playback", message: "Allow rm -rf build?"))
    }

    func testNoEventsBeforeSnapshotDoneAndEmptyObjectArraysDecode() {
        var h = RexReducerHarness()
        let lines = [
            L.session("s1", label: "empty"),
            L.view("s1", label: "empty", []),
            L.block("s1", "b1", []),
        ]
        XCTAssertEqual(h.apply(lines), [])
        XCTAssertFalse(h.reducer.isSnapshotDone)
        XCTAssertEqual(h.apply(L.line(["t": "snapshot_done"])).events,
                       [.discovery([rexDescriptor("s1", "empty")]), .connected(rexDescriptor("s1", "empty"), .empty)])
        XCTAssertTrue(h.reducer.isSnapshotDone)
    }

    func testDiscoveryOrdersByFoldedLabelThenID() {
        var h = RexReducerHarness()
        let events = h.apply([
            L.session("s3", label: "beta"), L.session("s2", label: "Alpha"), L.session("s1", label: "alpha"),
            L.line(["t": "snapshot_done"]),
        ])
        XCTAssertEqual(events.first, .discovery([rexDescriptor("s1", "alpha"), rexDescriptor("s2", "Alpha"),
                                                 rexDescriptor("s3", "beta")]))
    }

    // MARK: Re-reads and epochs

    func testReReadReplacesRecordsAndReplayIsIdempotent() {
        var h = RexReducerHarness()
        h.apply(snapshotLines(b1: [L.Rec(state: "done", at: 1)]))

        let read = L.block("s1", "b1", [L.Rec(state: "working", at: 5, app: "pi")],
                           via: L.changed("working", at: 5))
        let events = h.apply(read).events
        XCTAssertEqual(events.lastSnapshot("s1")?.rows.map(\.state), [.working])
        XCTAssertEqual(events.lastSnapshot("s1")?.attention, [])

        let epoch = h.reducer.epoch(of: rk("s1", "b1"))
        XCTAssertEqual(h.apply(read).events, [], "an identical replay changes nothing")
        XCTAssertEqual(h.reducer.epoch(of: rk("s1", "b1")), epoch)
    }

    func testViaAdvancesEpochAcrossCollapsedCycleButNotForIdenticalOrStaleReports() throws {
        var h = RexReducerHarness()
        h.apply(snapshotLines(b1: [L.Rec(state: "done", at: 10)]))
        let first = try XCTUnwrap(h.reducer.epoch(of: rk("s1", "b1")))

        // done → working → done; the re-read triggered by `working` already sees `done`.
        h.apply(L.block("s1", "b1", [L.Rec(state: "done", at: 30)], via: L.changed("working", at: 20)))
        let cycled = try XCTUnwrap(h.reducer.epoch(of: rk("s1", "b1")))
        XCTAssertGreaterThan(cycled, first)

        // The `done` event of the same cycle, delivered afterwards, re-reports what we know.
        h.apply(L.block("s1", "b1", [L.Rec(state: "done", at: 30)], via: L.changed("done", at: 30)))
        XCTAssertEqual(h.reducer.epoch(of: rk("s1", "b1")), cycled)

        // A stale event replayed after a snapshot carries an older time and is ignored.
        h.apply(L.block("s1", "b1", [L.Rec(state: "done", at: 30)], via: L.changed("working", at: 25)))
        XCTAssertEqual(h.reducer.epoch(of: rk("s1", "b1")), cycled)
    }

    func testViaComparesParsedTimesNotText() throws {
        var h = RexReducerHarness()
        h.apply([
            L.session("s1"), L.view("s1", [L.ViewBlock(b: "b1")]),
            L.line(["t": "block", "s": "s1", "b": "b1",
                    "records": [["id": "", "state": "done", "at": "2026-11-07T18:00:09.9-08:00"]]]),
            L.line(["t": "snapshot_done"]),
        ])
        let first = try XCTUnwrap(h.reducer.epoch(of: rk("s1", "b1")))
        // "…:10-08:00" sorts before "…:09.9-08:00" as text but is later in time.
        h.apply(L.line(["t": "block", "s": "s1", "b": "b1",
                        "records": [["id": "", "state": "done", "at": "2026-11-07T18:00:11-08:00"]],
                        "via": ["id": "", "state": "working", "at": "2026-11-07T18:00:10-08:00"]]))
        XCTAssertGreaterThan(try XCTUnwrap(h.reducer.epoch(of: rk("s1", "b1"))), first)
    }

    func testViaIsSkippedWhenTheLastKnownTimeIsMissing() throws {
        var h = RexReducerHarness()
        h.apply([
            L.session("s1"), L.view("s1", [L.ViewBlock(b: "b1")]),
            L.line(["t": "block", "s": "s1", "b": "b1", "records": [["id": "", "state": "done"]]]),
            L.line(["t": "snapshot_done"]),
        ])
        let first = try XCTUnwrap(h.reducer.epoch(of: rk("s1", "b1")))
        h.apply(L.block("s1", "b1", [L.Rec(state: "done", at: 30)], via: L.changed("working", at: 20)))
        XCTAssertEqual(h.reducer.epoch(of: rk("s1", "b1")), first, "no known time: cannot tell the event is newer")
    }

    func testEpochsComeFromOneIncreasingCounterAndNeverRepeat() throws {
        var h = RexReducerHarness()
        h.apply(snapshotLines(b1: [L.Rec(state: "blocked", at: 1)], b2: [L.Rec(state: "done", at: 1)]))
        let b1 = try XCTUnwrap(h.reducer.epoch(of: rk("s1", "b1")))
        let b2 = try XCTUnwrap(h.reducer.epoch(of: rk("s1", "b2")))
        XCTAssertNotEqual(b1, b2)

        h.apply(L.block("s1", "b1", [], via: L.removed([""])))
        XCTAssertNil(h.reducer.epoch(of: rk("s1", "b1")))
        h.apply(L.block("s1", "b1", [L.Rec(state: "blocked", at: 3)], via: L.changed("blocked", at: 3)))
        XCTAssertGreaterThan(try XCTUnwrap(h.reducer.epoch(of: rk("s1", "b1"))), max(b1, b2),
                             "a dropped and recreated record gets a fresh epoch")
    }

    func testBlockedRemovedOnExitWhileDoneSurvivesAndGoneReadClears() {
        var h = RexReducerHarness()
        h.apply(snapshotLines(b1: [L.Rec(state: "blocked", at: 1), L.Rec(id: "child", state: "done", at: 1, app: "pi")]))

        let exited = h.apply(L.block("s1", "b1", [L.Rec(id: "child", state: "done", at: 1, app: "pi")],
                                     via: L.removed([""]))).events
        XCTAssertEqual(exited.lastSnapshot("s1")?.rows.map(\.state), [.finished])
        XCTAssertNil(h.reducer.epoch(of: rk("s1", "b1")))
        XCTAssertNotNil(h.reducer.epoch(of: rk("s1", "b1", "child")))

        let gone = h.apply(L.block("s1", "b1", [], gone: true, via: L.removed(["child"]))).events
        XCTAssertEqual(gone.lastSnapshot("s1"), .empty)
        XCTAssertNil(h.reducer.epoch(of: rk("s1", "b1", "child")))
    }

    func testRankingLetsWorkingOutrankStaleTerminalStates() {
        var h = RexReducerHarness()
        let events = h.apply(snapshotLines(b1: [
            L.Rec(state: "error", at: 1, msg: "exit 2"),
            L.Rec(id: "child", state: "working", at: 2, app: "pi"),
            L.Rec(id: "idle", state: "idle", at: 3),
        ]))
        let snapshot = events.lastSnapshot("s1")
        XCTAssertEqual(snapshot?.rows.map(\.state), [.working])
        XCTAssertEqual(snapshot?.attention.map(\.state), [.error], "attention is never hidden by ranking")
    }

    // MARK: Closing and destroying

    func testBlockClosedDropsRecordsThenSessionDestroyedRemovesOnce() {
        var h = RexReducerHarness()
        h.apply(snapshotLines(b1: [L.Rec(state: "done", at: 1)], b2: [L.Rec(state: "blocked", at: 1)]))

        let closed = h.apply(L.line(["t": "block_closed", "s": "s1", "b": "b1"])).events
        XCTAssertEqual(closed.lastSnapshot("s1")?.rows.map(\.target.paneID), ["b2"])
        XCTAssertNil(h.reducer.epoch(of: rk("s1", "b1")))

        h.apply(L.line(["t": "block_closed", "s": "s1", "b": "b2"]))
        XCTAssertEqual(h.apply(L.line(["t": "session_destroyed", "s": "s1"])).events, [.removed(rexKey("s1"))])
        XCTAssertEqual(h.apply(L.line(["t": "session_destroyed", "s": "s1"])).events, [])
        XCTAssertFalse(h.reducer.sessionsKnownToStore.contains("s1"))
    }

    func testSessionDestroyedDropsEverythingForTheSession() {
        var h = RexReducerHarness()
        h.apply(snapshotLines(b1: [L.Rec(state: "blocked", at: 1)]))
        XCTAssertEqual(h.apply(L.line(["t": "session_destroyed", "s": "s1"])).events, [.removed(rexKey("s1"))])
        XCTAssertNil(h.reducer.epoch(of: rk("s1", "b1")))
        XCTAssertEqual(h.apply(L.block("s1", "b1", [L.Rec(state: "blocked", at: 2)])).events, [],
                       "lines for a destroyed session are ignored")
    }

    // MARK: Sessions and views

    func testLiveSessionGetsEmptyConnectedThenViewAndRows() {
        var h = RexReducerHarness()
        h.apply(snapshotLines(b1: []))

        XCTAssertEqual(h.apply(L.line(["t": "session_created", "s": "s2", "label": "new-work"])).events,
                       [.connected(rexDescriptor("s2", "new-work"), .empty)])
        XCTAssertEqual(h.apply(L.view("s2", label: "new-work", [L.ViewBlock(b: "c1")])).events, [])
        let events = h.apply(L.block("s2", "c1", [L.Rec(state: "blocked", at: 4, app: "pi")],
                                     via: L.changed("blocked", at: 4))).events
        XCTAssertEqual(events.lastSnapshot("s2")?.rows.map(\.displayLabel), ["new-work"])
    }

    func testKnownSessionCreatedIsALabelOnlyUpdate() {
        var h = RexReducerHarness()
        h.apply(snapshotLines(b1: [L.Rec(state: "done", at: 1)]))
        let events = h.apply(L.line(["t": "session_created", "s": "s1", "label": "renamed"])).events
        XCTAssertEqual(events.first, .descriptorChanged(rexDescriptor("s1", "renamed")))
        XCTAssertFalse(events.contains { if case .connected = $0 { true } else { false } })
        XCTAssertEqual(h.apply(L.line(["t": "session_created", "s": "s1", "label": "renamed"])).events, [])
    }

    func testRenamesUpdateDescriptorAndRowLabels() {
        var h = RexReducerHarness()
        h.apply(snapshotLines(b1: [], b2: [L.Rec(state: "done", at: 1)]))
        let events = h.apply(L.view("s1", label: "renamed", [
            L.ViewBlock(b: "b1", windowLabel: "Playback"), L.ViewBlock(b: "b2"),
        ])).events
        XCTAssertEqual(events.first, .descriptorChanged(rexDescriptor("s1", "renamed")))
        XCTAssertEqual(events.lastSnapshot("s1")?.rows.map(\.displayLabel), ["renamed"])

        let windowRenamed = h.apply(L.view("s1", label: "renamed", [
            L.ViewBlock(b: "b1", windowLabel: "Playback"), L.ViewBlock(b: "b2", windowLabel: "Review"),
        ])).events
        XCTAssertEqual(windowRenamed, [.snapshot(rexKey("s1"), h.reducer.snapshot(forSession: "s1"))])
        XCTAssertEqual(windowRenamed.lastSnapshot("s1")?.rows.map(\.displayLabel), ["Review"])
    }

    func testUnknownSessionLinesAreIgnored() {
        var h = RexReducerHarness()
        h.apply(snapshotLines(b1: []))
        XCTAssertEqual(h.apply(L.view("s9", label: "ghost", [L.ViewBlock(b: "x")])).events, [])
        XCTAssertEqual(h.apply(L.block("s9", "x", [L.Rec(state: "blocked", at: 1)])).events, [])
        XCTAssertNil(h.reducer.epoch(of: rk("s9", "x")))
        XCTAssertEqual(h.apply(L.line(["t": "block_closed", "s": "s9", "b": "x"])).events, [])
        XCTAssertEqual(h.apply(L.line(["t": "heartbeat"])).events, [])
    }

    func testHeldBlockGetsARowOnlyOnceAViewIncludesIt() {
        var h = RexReducerHarness()
        h.apply(snapshotLines(b1: []))
        XCTAssertEqual(h.apply(L.block("s1", "b3", [L.Rec(state: "blocked", at: 2)],
                                       via: L.changed("blocked", at: 2))).events, [])
        XCTAssertNotNil(h.reducer.epoch(of: rk("s1", "b3")), "held blocks still track records")

        let events = h.apply(L.view("s1", label: "fix-playback", [
            L.ViewBlock(b: "b1", windowLabel: "Playback"), L.ViewBlock(b: "b3", windowLabel: "Float"),
        ])).events
        XCTAssertEqual(events.lastSnapshot("s1")?.rows.map(\.displayLabel), ["Float"])
    }

    // MARK: Generations

    func testRestartResetsGenerationStateButKeepsEpochs() throws {
        var h = RexReducerHarness()
        h.apply(snapshotLines(b1: [L.Rec(state: "blocked", at: 1)], b2: [L.Rec(state: "done", at: 1)]))
        let b1 = try XCTUnwrap(h.reducer.epoch(of: rk("s1", "b1")))
        let b2 = try XCTUnwrap(h.reducer.epoch(of: rk("s1", "b2")))

        h.restart()
        XCTAssertFalse(h.reducer.isSnapshotDone)
        XCTAssertEqual(h.reducer.snapshot(forSession: "s1"), .empty, "views and records are per generation")
        let events = h.apply(snapshotLines(b1: [L.Rec(state: "blocked", at: 1)], b2: [L.Rec(state: "error", at: 9)]))
        XCTAssertEqual(h.reducer.epoch(of: rk("s1", "b1")), b1, "an unchanged record keeps its epoch")
        XCTAssertGreaterThan(try XCTUnwrap(h.reducer.epoch(of: rk("s1", "b2"))), b2)
        XCTAssertEqual(events.lastSnapshot("s1")?.attention.first { $0.target.paneID == "b1" }?.epoch, b1)
    }

    func testRestartRemovesSessionsAbsentFromTheNewSnapshotAndPrunesTheirRecords() throws {
        var h = RexReducerHarness()
        h.apply([
            L.session("s1"), L.view("s1", [L.ViewBlock(b: "b1")]), L.block("s1", "b1", [L.Rec(state: "done", at: 1)]),
            L.session("s2"), L.view("s2", [L.ViewBlock(b: "c1")]), L.block("s2", "c1", [L.Rec(state: "done", at: 1)]),
            L.line(["t": "snapshot_done"]),
        ])
        let c1 = try XCTUnwrap(h.reducer.epoch(of: rk("s2", "c1")))
        h.restart()
        let events = h.apply([
            L.session("s1"), L.view("s1", []),
            L.line(["t": "snapshot_done"]),
        ])
        XCTAssertEqual(events.last, .removed(rexKey("s2")))
        XCTAssertNil(h.reducer.epoch(of: rk("s1", "b1")), "a block absent from the snapshot is pruned")
        XCTAssertNil(h.reducer.epoch(of: rk("s2", "c1")))
        XCTAssertEqual(h.reducer.sessionsKnownToStore, ["s1"])

        h.restart()
        h.apply([L.session("s2"), L.view("s2", [L.ViewBlock(b: "c1")]),
                 L.block("s2", "c1", [L.Rec(state: "done", at: 1)]), L.line(["t": "snapshot_done"])])
        XCTAssertGreaterThan(try XCTUnwrap(h.reducer.epoch(of: rk("s2", "c1"))), c1)
    }

    func testLinesFromAnotherGenerationAreIgnored() {
        var h = RexReducerHarness()
        h.restart()
        let stale = h.reducer.apply(L.session("s1"), generation: 1, now: h.now)
        XCTAssertEqual(stale, RexReducerOutput())
        XCTAssertEqual(h.apply(L.line(["t": "snapshot_done"])).events, [.discovery([])])
    }

    func testSessionDestroyedDuringOutageIsRemovedAtSnapshotDone() {
        var h = RexReducerHarness()
        h.apply(snapshotLines(b1: []))
        h.restart()
        XCTAssertEqual(h.apply(L.line(["t": "session_destroyed", "s": "s1"])).events, [],
                       "before snapshot_done the store hears nothing")
        XCTAssertEqual(h.apply(L.line(["t": "snapshot_done"])).events, [.discovery([]), .removed(rexKey("s1"))])
    }

    // MARK: Errors

    func testStatusAndViewErrorsFailBeforeSnapshotDone() {
        var h = RexReducerHarness()
        h.apply([L.session("s1")])
        let status = h.apply(L.line(["t": "status_error", "s": "s1", "b": "b1", "err": "boom"]))
        XCTAssertEqual(status.failure, .statusError(sessionID: "s1", blockID: "b1", message: "boom"))
        XCTAssertEqual(status.failure?.marksCandidateFailed, false)
        let view = h.apply(L.line(["t": "view_error", "s": "s1", "err": "boom"]))
        XCTAssertEqual(view.failure, .viewError(sessionID: "s1", message: "boom"))
    }

    func testStatusAndViewErrorsAfterSnapshotDoneAreLoggedAndKeepState() {
        var h = RexReducerHarness()
        h.apply(snapshotLines(b1: [L.Rec(state: "blocked", at: 1)]))
        let before = h.reducer.snapshot(forSession: "s1")
        let status = h.apply(L.line(["t": "status_error", "s": "s1", "b": "b1", "err": "boom"]))
        XCTAssertNil(status.failure)
        XCTAssertEqual(status.events, [])
        XCTAssertEqual(status.logMessages.count, 1)
        let view = h.apply(L.line(["t": "view_error", "s": "s1", "err": "boom"]))
        XCTAssertNil(view.failure)
        XCTAssertEqual(view.logMessages.count, 1)
        XCTAssertEqual(h.reducer.snapshot(forSession: "s1"), before)
    }

    func testSnapshotAndEncodeErrorsAlwaysFail() {
        var h = RexReducerHarness()
        let snapshot = h.apply(L.line(["t": "snapshot_error", "err": "session.list: boom"]))
        XCTAssertEqual(snapshot.failure, .snapshotError("session.list: boom"))
        XCTAssertEqual(snapshot.failure?.marksCandidateFailed, true)

        h.apply(snapshotLines(b1: []))
        let encode = h.apply(L.line(["t": "encode_error", "err": "NaN"]))
        XCTAssertEqual(encode.failure, .encodeError("NaN"))
        XCTAssertEqual(encode.failure?.marksCandidateFailed, false)
    }

    func testUnknownLineKindsAreLogged() {
        var h = RexReducerHarness()
        let output = h.apply(L.line(["t": "progress", "s": "s1"]))
        XCTAssertEqual(output.events, [])
        XCTAssertNil(output.failure)
        XCTAssertEqual(output.logMessages.count, 1)
    }

    func testResetForgetsEverything() {
        var h = RexReducerHarness()
        h.apply(snapshotLines(b1: [L.Rec(state: "blocked", at: 1)]))
        h.reducer.reset()
        XCTAssertNil(h.reducer.epoch(of: rk("s1", "b1")))
        XCTAssertEqual(h.reducer.sessionsKnownToStore, [])
        XCTAssertNil(h.reducer.generation)
    }
}
