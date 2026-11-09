import XCTest
@testable import HerdrMenubar

@MainActor
final class RexBackendTests: XCTestCase {
    private let cli = RexCLI(path: "/rex/Current/rex", version: "0.0.1", apiRevision: 10)
    private var clock: ManualRexClock!
    private var watchers: FakeWatcherFactory!
    private var resolver: FakeRexResolver!
    private var backend: RexBackend!
    private var recorder: BackendEventRecorder!

    override func setUp() {
        super.setUp()
        clock = ManualRexClock()
        watchers = FakeWatcherFactory()
        resolver = FakeRexResolver([.ready(cli)])
    }

    override func tearDown() async throws {
        await backend?.stop()
        backend = nil
        try await super.tearDown()
    }

    private func makeBackend(enabled: Bool = true, scriptURL: URL? = URL(fileURLWithPath: "/app/RexWatcher.lua")) -> RexBackend {
        RexBackend(
            resolver: resolver,
            scriptURL: scriptURL,
            makeWatcher: watchers.factory,
            runner: ScriptedProcessRunner(),
            app: FakeRexApp(),
            clock: clock,
            hostName: { "Mac" },
            isEnabled: { enabled }
        )
    }

    /// Subscribes, then starts (the store's order).
    private func start(enabled: Bool = true) async {
        backend = makeBackend(enabled: enabled)
        recorder = BackendEventRecorder(await backend.events())
        await backend.start()
    }

    private func waitForProcess(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        await rexWaitUntil("\(count) watcher processes", file: file, line: line) {
            watchers.processes.count >= count && watchers.processes[count - 1].started
        }
    }

    private func waitForEvent(file: StaticString = #filePath, line: UInt = #line,
                              _ predicate: @escaping (BackendEvent) -> Bool) async {
        await rexWaitUntil("event", file: file, line: line) { recorder.events.contains(where: predicate) }
    }

    /// Waits until the backend sleeps for exactly `delay` from now (a backoff or recheck wait).
    private func waitForSleep(_ delay: Duration, file: StaticString = #filePath, line: UInt = #line) async {
        await rexWaitUntil("a \(delay) sleep", file: file, line: line) {
            clock.pendingOffsets.contains(clock.elapsed + delay)
        }
    }

    private func unavailableReasons() -> [String] {
        recorder.events.compactMap { if case .backendUnavailable(let r) = $0 { r } else { nil } }
    }

    private func isConnected(_ event: BackendEvent) -> Bool {
        if case .connected = event { true } else { false }
    }

    /// Starts and completes the first snapshot with one blocked/working session.
    private func startHealthy(state: String = "working") async {
        await start()
        await waitForProcess(1)
        watchers.last!.send(RexJSON.snapshot(state: state))
        await waitForEvent(isConnected)
    }

    // MARK: Start and visibility

    func testDisabledBackendEmitsHiddenAndSpawnsNothing() async {
        await start(enabled: false)
        await waitForEvent { $0 == .backendHidden }
        await settleTasks()
        XCTAssertEqual(resolver.resolveCount, 0)
        XCTAssertTrue(watchers.processes.isEmpty)
        await backend.retryUnavailable()
        await settleTasks()
        XCTAssertEqual(resolver.resolveCount, 0)
    }

    func testStartReturnsBeforeResolutionCompletes() async {
        let gate = RexTestGate()
        let blocking = BlockingResolver(gate: gate, result: .ready(cli))
        backend = RexBackend(resolver: blocking, scriptURL: URL(fileURLWithPath: "/x.lua"), makeWatcher: watchers.factory,
                             runner: ScriptedProcessRunner(), app: FakeRexApp(), clock: clock, hostName: { nil },
                             isEnabled: { true })
        recorder = BackendEventRecorder(await backend.events())
        await backend.start()   // must not wait for the resolver
        XCTAssertTrue(watchers.processes.isEmpty)
        gate.open()
        await waitForProcess(1)
    }

    func testHiddenResolutionEmitsHiddenOnceAndRechecksEveryFiveMinutes() async {
        resolver.set([.hidden])
        await start()
        await waitForEvent { $0 == .backendHidden }
        await waitForSleep(.seconds(300))
        clock.advance(.seconds(299))
        await settleTasks()
        XCTAssertEqual(resolver.resolveCount, 1)
        clock.advance(.seconds(1))
        await rexWaitUntil { resolver.resolveCount == 2 }
        await waitForSleep(.seconds(300))
        XCTAssertEqual(recorder.events, [.backendHidden])
    }

    func testRetryWhileHiddenReResolvesNow() async {
        resolver.set([.hidden, .ready(cli)])
        await start()
        await waitForEvent { $0 == .backendHidden }
        await waitForSleep(.seconds(300))
        await backend.retryUnavailable()
        await waitForProcess(1)
        XCTAssertEqual(resolver.resolveCount, 2)
    }

    func testUnavailableResolutionUsesBackoff() async {
        resolver.set([.unavailable("Rex command-line tool not found")])
        await start()
        await waitForEvent { $0 == .backendUnavailable("Rex command-line tool not found") }
        await waitForSleep(.seconds(1))
        clock.advance(.seconds(1))
        await rexWaitUntil { resolver.resolveCount == 2 }
        XCTAssertEqual(unavailableReasons(), ["Rex command-line tool not found"], "the same reason is reported once")
    }

    func testServerUnreachableResolutionRetriesAfterSixtySeconds() async {
        resolver.set([.serverUnreachable(cli), .ready(cli)])
        await start()
        await waitForEvent { $0 == .backendUnavailable("Rex is not running") }
        await waitForSleep(.seconds(60))
        clock.advance(.seconds(59))
        await settleTasks()
        XCTAssertTrue(watchers.processes.isEmpty)
        clock.advance(.seconds(1))
        await waitForProcess(1)
        let resolved = await backend.hasResolvedCLIThisRun
        XCTAssertTrue(resolved)
    }

    // MARK: Snapshot and lines

    func testSnapshotEmitsDiscoveryThenConnected() async {
        await startHealthy(state: "blocked")
        let descriptor = rexDescriptor("s1", "work")
        XCTAssertEqual(recorder.events.first, .discovery([descriptor]))
        guard case .connected(let connected, let snapshot) = recorder.events.last else {
            return XCTFail("\(recorder.events)")
        }
        XCTAssertEqual(connected, descriptor)
        XCTAssertEqual(snapshot.attention.map(\.state), [.blocked], "the first snapshot is a settled baseline")
        XCTAssertEqual(watchers.last?.generation, 1)
    }

    func testUndecodableLinesAreIgnored() async {
        await start()
        await waitForProcess(1)
        watchers.last!.sendRaw(Data("not json".utf8))
        watchers.last!.send(RexJSON.snapshot())
        await waitForEvent(isConnected)
        XCTAssertTrue(unavailableReasons().isEmpty)
    }

    func testSettleTimerEmitsSnapshotAfterOnePointFiveSeconds() async {
        await startHealthy()
        recorder.clear()
        watchers.last!.send(RexJSON.block("s1", "b1", state: "blocked", at: 5, via: "blocked"))
        await waitForEvent { if case .snapshot(_, let s) = $0 { s.rows.first?.state == .attention(.blocked) } else { false } }
        XCTAssertEqual(recorder.events.lastSnapshot("s1")?.attention, [])

        clock.advance(.milliseconds(1499))
        await settleTasks()
        XCTAssertEqual(recorder.events.lastSnapshot("s1")?.attention, [])
        clock.advance(.milliseconds(1))
        await rexWaitUntil { recorder.events.lastSnapshot("s1")?.attention.map(\.state) == [.blocked] }
    }

    func testMarkSeenAndClearFinishedEmitSnapshots() async {
        await startHealthy(state: "done")
        guard case .connected(_, let snapshot) = recorder.events.last, let token = snapshot.rows.first?.seenToken else {
            return XCTFail("\(recorder.events)")
        }
        XCTAssertEqual(snapshot.rows.map(\.state), [.attention(.done)])
        await backend.markSeen(token)
        // The recorder drains the stream on its own task, so wait for the emitted snapshot.
        await rexWaitUntil { recorder.events.lastSnapshot("s1")?.rows == [] }

        watchers.last!.send(RexJSON.block("s1", "b1", state: "done", at: 9, via: "working"))
        await rexWaitUntil { recorder.events.lastSnapshot("s1")?.rows.map(\.state) == [.attention(.done)] }
        await backend.clearFinished()
        await rexWaitUntil { recorder.events.lastSnapshot("s1")?.rows == [] }
    }

    // MARK: Supervision

    func testSnapshotTimeoutFailsAfterTwentySecondsWithoutMarkingTheCandidate() async {
        await start()
        await waitForProcess(1)
        await waitForSleep(.seconds(20))
        clock.advance(.milliseconds(19_999))
        await settleTasks()
        XCTAssertEqual(watchers.last?.terminateCount, 0)
        clock.advance(.milliseconds(1))
        await waitForEvent { $0 == .backendUnavailable("Rex did not finish its snapshot in time") }
        XCTAssertGreaterThan(watchers.processes[0].terminateCount, 0)
        XCTAssertEqual(resolver.failedPaths, [])
        clock.advance(.seconds(1))
        await waitForProcess(2)
        XCTAssertEqual(watchers.last?.generation, 2)
    }

    func testHeartbeatSupervisionStartsAtSnapshotDone() async {
        await start()
        await waitForProcess(1)
        await waitForSleep(.seconds(20))
        clock.advance(.seconds(19))   // a slow snapshot is fine
        watchers.last!.send(RexJSON.snapshot())
        await waitForEvent(isConnected)
        await waitForSleep(.seconds(15))

        clock.advance(.seconds(14))
        watchers.last!.send(RexJSON.heartbeat)
        await rexWaitUntil { clock.pendingOffsets.contains(.seconds(48)) }
        clock.advance(.seconds(14))
        await settleTasks()
        XCTAssertTrue(unavailableReasons().isEmpty)
        clock.advance(.seconds(1))
        await waitForEvent { $0 == .backendUnavailable("The Rex watcher stopped responding") }
        XCTAssertGreaterThan(watchers.processes[0].terminateCount, 0)
    }

    func testHeartbeatDeadlineFiringLateAfterSleepReArmsAFreshGraceWindow() async {
        await startHealthy()
        await waitForSleep(.seconds(15))
        clock.advance(.seconds(600))   // the Mac slept; the deadline fires ~585 s late on wake
        await rexWaitUntil { clock.pendingOffsets.contains(.seconds(615)) }
        XCTAssertTrue(unavailableReasons().isEmpty, "\(unavailableReasons())")
        XCTAssertEqual(watchers.processes[0].terminateCount, 0)

        clock.advance(.seconds(14))
        watchers.last!.send(RexJSON.heartbeat)   // the watcher resumes: healthy again
        await rexWaitUntil { clock.pendingOffsets.contains(.seconds(629)) }
        clock.advance(.seconds(15))               // and no heartbeat within the next window fails
        await waitForEvent { $0 == .backendUnavailable("The Rex watcher stopped responding") }
    }

    func testSnapshotDeadlineFiringLateAfterSleepReArmsAFreshGraceWindow() async {
        await start()
        await waitForProcess(1)
        await waitForSleep(.seconds(20))
        clock.advance(.seconds(300))
        await rexWaitUntil { clock.pendingOffsets.contains(.seconds(320)) }
        XCTAssertTrue(unavailableReasons().isEmpty, "\(unavailableReasons())")
        clock.advance(.seconds(20))
        await waitForEvent { $0 == .backendUnavailable("Rex did not finish its snapshot in time") }
    }

    func testSecondLateFireWithoutAnyWatcherLineFails() async {
        await startHealthy()
        await waitForSleep(.seconds(15))
        clock.advance(.seconds(600))   // first late fire: fresh window
        await rexWaitUntil { clock.pendingOffsets.contains(.seconds(615)) }
        XCTAssertTrue(unavailableReasons().isEmpty)
        clock.advance(.seconds(600))   // late again, and the watcher said nothing: a hung watcher
        await waitForEvent { $0 == .backendUnavailable("The Rex watcher stopped responding") }
    }

    func testAWatcherLineBetweenLateFiresAllowsAnotherReArm() async {
        await startHealthy()
        await waitForSleep(.seconds(15))
        clock.advance(.seconds(600))
        await rexWaitUntil { clock.pendingOffsets.contains(.seconds(615)) }
        clock.advance(.seconds(5))
        watchers.last!.send(RexJSON.heartbeat)
        await rexWaitUntil { clock.pendingOffsets.contains(.seconds(620)) }
        clock.advance(.seconds(600))   // late again, but the watcher spoke in between
        await rexWaitUntil { clock.pendingOffsets.contains(.seconds(1220)) }
        XCTAssertTrue(unavailableReasons().isEmpty, "\(unavailableReasons())")
    }

    func testSlightlyLateDeadlineStillFails() async {
        await startHealthy()
        await waitForSleep(.seconds(15))
        clock.advance(.seconds(17))   // within the lateness tolerance: a real stall
        await waitForEvent { $0 == .backendUnavailable("The Rex watcher stopped responding") }
    }

    func testWakeObservationIsRemovedWhenTheBackendIsReleasedWithoutStop() async {
        let wake = FakeRexWakeSignal()
        var released: RexBackend? = RexBackend(
            resolver: ThrowingResolver(), scriptURL: URL(fileURLWithPath: "/x.lua"), makeWatcher: watchers.factory,
            runner: ScriptedProcessRunner(), app: FakeRexApp(), clock: clock, hostName: { nil },
            observeWake: wake.subscribe, isEnabled: { true })
        await released?.start()
        XCTAssertEqual(wake.subscriberCount, 1)
        weak var weakBackend = released
        released = nil
        await rexWaitUntil("backend released") { weakBackend == nil }
        XCTAssertEqual(wake.subscriberCount, 0)
    }

    func testSystemWakeExtendsTheSupervisionDeadline() async {
        let wake = FakeRexWakeSignal()
        backend = RexBackend(resolver: resolver, scriptURL: URL(fileURLWithPath: "/x.lua"), makeWatcher: watchers.factory,
                             runner: ScriptedProcessRunner(), app: FakeRexApp(), clock: clock, hostName: { nil },
                             observeWake: wake.subscribe, isEnabled: { true })
        recorder = BackendEventRecorder(await backend.events())
        await backend.start()
        await waitForProcess(1)
        watchers.last!.send(RexJSON.snapshot())
        await waitForEvent(isConnected)
        await waitForSleep(.seconds(15))
        XCTAssertEqual(wake.subscriberCount, 1)

        clock.advance(.seconds(14))
        wake.fire()
        await rexWaitUntil { clock.pendingOffsets.contains(.seconds(29)) }
        clock.advance(.seconds(1))
        await settleTasks()
        XCTAssertTrue(unavailableReasons().isEmpty, "\(unavailableReasons())")
        clock.advance(.seconds(14))
        await waitForEvent { $0 == .backendUnavailable("The Rex watcher stopped responding") }

        await backend.stop()
        XCTAssertEqual(wake.subscriberCount, 0, "stop() unsubscribes")
    }

    func testBackoffIsOneTwoFiveFifteenThenSixtySeconds() async {
        await start()
        var expected = 1
        for delay in [1, 2, 5, 15, 60, 60] {
            await waitForProcess(expected)
            watchers.last!.exit(1)
            await waitForSleep(.seconds(delay))
            clock.advance(.milliseconds(delay * 1000 - 1))
            await settleTasks()
            XCTAssertEqual(watchers.processes.count, expected, "no restart before \(delay) s")
            clock.advance(.milliseconds(1))
            expected += 1
        }
        await waitForProcess(expected)
    }

    func testHealthySnapshotResetsBackoff() async {
        await start()
        await waitForProcess(1)
        watchers.last!.exit(1)
        await waitForSleep(.seconds(1))
        clock.advance(.seconds(1))
        await waitForProcess(2)
        watchers.last!.send(RexJSON.snapshot())
        await waitForEvent(isConnected)
        watchers.last!.exit(1)
        await waitForSleep(.seconds(1))
        clock.advance(.seconds(1))
        await waitForProcess(3)
    }

    func testExitFourJumpsToSixtySecondsAndDoesNotMarkTheCandidate() async {
        await start()
        await waitForProcess(1)
        watchers.last!.exit(4)
        await waitForEvent { $0 == .backendUnavailable("Rex is not running") }
        await waitForSleep(.seconds(60))
        clock.advance(.seconds(59))
        await settleTasks()
        XCTAssertEqual(watchers.processes.count, 1)
        clock.advance(.seconds(1))
        await waitForProcess(2)
        XCTAssertEqual(resolver.failedPaths, [])
    }

    func testOwnExitBeforeSnapshotMarksTheCandidateFailedButNotAfter() async {
        await start()
        await waitForProcess(1)
        watchers.last!.stderrLine = "Error: boom"
        watchers.last!.exit(1)
        await waitForEvent { $0 == .backendUnavailable("The Rex watcher exited: Error: boom") }
        await rexWaitUntil { resolver.failedPaths == [cli.path] }

        await waitForSleep(.seconds(1))
        clock.advance(.seconds(1))
        await waitForProcess(2)
        watchers.last!.send(RexJSON.snapshot())
        await waitForEvent(isConnected)
        watchers.last!.exit(1)
        await waitForEvent { $0 == .backendUnavailable("The Rex watcher exited with status 1") }
        await settleTasks()
        XCTAssertEqual(resolver.failedPaths, [cli.path])
    }

    func testOutageReasonIgnoresTheBannerAndInterruptedStderrLines() async {
        await start()
        await waitForProcess(1)
        watchers.last!.stderrLine = "listening: session=all"
        watchers.last!.exit(1)
        await waitForEvent { $0 == .backendUnavailable("The Rex watcher exited with status 1") }

        await waitForSleep(.seconds(1))
        clock.advance(.seconds(1))
        await waitForProcess(2)
        watchers.last!.stderrLine = "Error: interrupted"
        watchers.last!.exit(130)
        await waitForEvent { $0 == .backendUnavailable("The Rex watcher exited with status 130") }
        XCTAssertFalse(unavailableReasons().contains { $0.contains("listening") || $0.contains("interrupted") },
                       "\(unavailableReasons())")
    }

    func testPerBlockAndPerSessionErrorsDuringTheSnapshotNeitherFailNorMarkTheCandidate() async {
        await start()
        await waitForProcess(1)
        watchers.last!.send([
            RexJSON.session("s1", label: "work"),
            RexJSON.view("s1", label: "work", blocks: [("b1", "One"), ("b2", "Two")]),
            ["t": "status_error", "s": "s1", "b": "b1", "err": "code=internal"],
            RexJSON.block("s1", "b2", state: "working", at: 1),
            RexJSON.session("s2", label: "other"),
            ["t": "list_blocks_error", "s": "s2", "err": "code=internal"],
            ["t": "view_error", "s": "s2", "err": "code=internal"],
            RexJSON.snapshotDone,
        ])
        await waitForEvent(isConnected)
        await settleTasks()
        XCTAssertTrue(unavailableReasons().isEmpty, "\(unavailableReasons())")
        XCTAssertEqual(resolver.failedPaths, [])
        XCTAssertEqual(watchers.processes[0].terminateCount, 0)
        XCTAssertTrue(recorder.events.contains(.connected(AgentSessionDescriptor(key: rexKey("s2"), displayName: "other"), .empty)))
    }

    func testSnapshotErrorMarksTheCandidateFailedAndTerminates() async {
        await start()
        await waitForProcess(1)
        watchers.last!.send(["t": "snapshot_error", "err": "session.list: nope"])
        await waitForEvent { $0 == .backendUnavailable("Rex watcher snapshot failed: session.list: nope") }
        await rexWaitUntil { resolver.failedPaths == [cli.path] }
        XCTAssertGreaterThan(watchers.processes[0].terminateCount, 0)
    }

    func testFramingErrorFailsTheGeneration() async {
        await startHealthy()
        watchers.last!.sendFramingError()
        await rexWaitUntil { unavailableReasons().count == 1 }
        XCTAssertGreaterThan(watchers.processes[0].terminateCount, 0)
        XCTAssertEqual(resolver.failedPaths, [])
    }

    func testWatcherStartFailureBacksOff() async {
        watchers.failStarts = true
        await start()
        await rexWaitUntil { unavailableReasons().count == 1 }
        await waitForSleep(.seconds(1))
        clock.advance(.seconds(1))
        await waitForProcess(2)
    }

    func testStaleGenerationLinesAreIgnoredAfterRestart() async {
        await startHealthy()
        let first = watchers.last!
        first.exit(1)
        await rexWaitUntil { unavailableReasons().count == 1 }
        await waitForSleep(.seconds(1))
        clock.advance(.seconds(1))
        await waitForProcess(2)
        recorder.clear()
        first.send(RexJSON.block("s1", "b1", state: "blocked", at: 7, via: "blocked"))
        first.send(RexJSON.snapshotDone)
        await settleTasks()
        XCTAssertEqual(recorder.events, [])
    }

    func testTicksDuringBackoffEmitNothing() async {
        await startHealthy()
        watchers.last!.send(RexJSON.block("s1", "b1", state: "blocked", at: 5, via: "blocked"))
        await rexWaitUntil { recorder.events.lastSnapshot("s1")?.rows.first?.state == .attention(.blocked) }
        watchers.last!.exit(1)
        await rexWaitUntil { unavailableReasons().count == 1 }
        recorder.clear()
        clock.advance(.milliseconds(900))
        clock.advance(.milliseconds(600))   // settle deadline passes during the gap
        await settleTasks()
        XCTAssertFalse(recorder.events.contains { $0.snapshotPayload != nil }, "\(recorder.events)")
    }

    func testRestartReconnectsSessionsAndRemovesVanishedOnes() async {
        await start()
        await waitForProcess(1)
        watchers.last!.send([RexJSON.session("s1", label: "work"), RexJSON.session("s2", label: "other"),
                             RexJSON.snapshotDone])
        await waitForEvent(isConnected)
        watchers.last!.exit(1)
        await rexWaitUntil { unavailableReasons().count == 1 }
        await waitForSleep(.seconds(1))
        clock.advance(.seconds(1))
        await waitForProcess(2)
        recorder.clear()
        watchers.last!.send([RexJSON.session("s1", label: "work"), RexJSON.snapshotDone])
        await waitForEvent { $0 == .removed(rexKey("s2")) }
        XCTAssertEqual(recorder.events, [
            .discovery([rexDescriptor("s1", "work")]),
            .connected(rexDescriptor("s1", "work"), .empty),
            .removed(rexKey("s2")),
        ])
    }

    func testQueuedHeartbeatIsAppliedBeforeTheSupervisionDeadlineIsChecked() async {
        await startHealthy()
        await waitForSleep(.seconds(15))
        await backend.setAutomaticDrainForTesting(false)
        watchers.last!.send(RexJSON.heartbeat)
        await rexWaitUntil { await self.backend.pendingProcessEventCountForTesting == 1 }
        clock.advance(.seconds(15))   // the deadline fires while the heartbeat is still queued
        await rexWaitUntil { await self.backend.pendingProcessEventCountForTesting == 0 }
        await settleTasks()
        XCTAssertTrue(unavailableReasons().isEmpty, "\(recorder.events)")
        XCTAssertEqual(watchers.processes[0].terminateCount, 0)
    }

    func testBackendUnavailableIsEmittedBeforeTheWatcherIsTerminated() async {
        let slow = SlowTerminatingWatcherFactory()
        backend = RexBackend(resolver: resolver, scriptURL: URL(fileURLWithPath: "/x.lua"), makeWatcher: slow.factory,
                             runner: ScriptedProcessRunner(), app: FakeRexApp(), clock: clock, hostName: { nil },
                             isEnabled: { true })
        recorder = BackendEventRecorder(await backend.events())
        await backend.start()
        await rexWaitUntil { slow.process?.started == true }
        slow.process!.send(RexJSON.snapshot())
        await waitForEvent(isConnected)
        slow.process!.sendFramingError()
        await rexWaitUntil { slow.process!.terminateCount == 1 }
        // terminate() is still blocked, yet the store already knows the watcher is down.
        await rexWaitUntil { self.unavailableReasons().count == 1 }
        slow.gate.open()
    }

    func testResolverLosingTheCLIClearsItForFocus() async {
        resolver.set([.ready(cli), .unavailable("Rex command-line tool not found")])
        let runner = ScriptedProcessRunner { _ in ProcessResult(outcome: .exited(0), stdout: Data(#"{"focus":"ok"}"#.utf8)) }
        backend = RexBackend(resolver: resolver, scriptURL: URL(fileURLWithPath: "/x.lua"), makeWatcher: watchers.factory,
                             runner: runner, app: FakeRexApp(), clock: clock, hostName: { nil }, isEnabled: { true })
        recorder = BackendEventRecorder(await backend.events())
        await backend.start()
        await waitForProcess(1)
        watchers.last!.exit(1)
        await waitForSleep(.seconds(1))
        clock.advance(.seconds(1))
        await waitForEvent { $0 == .backendUnavailable("Rex command-line tool not found") }
        do {
            try await backend.focusServer(AgentTarget(session: rexKey("s1"), paneID: "b1"))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? FocusError, .unavailable("Rex is not running"))
        }
        XCTAssertTrue(runner.requests.isEmpty, "the missing binary is never launched")
    }

    func testResolvedThisRunSurvivesStopForTheAppLaunch() async {
        await startHealthy()
        await backend.stop()
        let resolved = await backend.hasResolvedCLIThisRun
        XCTAssertTrue(resolved)
    }

    // MARK: Retry

    func testRetryInBackoffRestartsNowAndResetsTheBackoff() async {
        await start()
        for (count, delay) in [(1, 1), (2, 2)] {
            await waitForProcess(count)
            watchers.last!.exit(1)
            await waitForSleep(.seconds(delay))
            clock.advance(.seconds(delay))
        }
        await waitForProcess(3)
        watchers.last!.exit(1)               // next delay would be 5 s
        await waitForSleep(.seconds(5))
        await backend.retryUnavailable()
        await waitForProcess(4)
        watchers.last!.exit(1)
        await waitForSleep(.seconds(1))
        clock.advance(.seconds(1))           // reset: back to 1 s
        await waitForProcess(5)
    }

    func testRetryWhileHealthyIsANoOp() async {
        await startHealthy()
        await backend.retryUnavailable()
        await settleTasks()
        XCTAssertEqual(watchers.processes.count, 1)
        XCTAssertEqual(watchers.processes[0].terminateCount, 0)
        XCTAssertEqual(resolver.resolveCount, 1)
    }

    // MARK: Stop

    func testStopTerminatesTheChildFinishesTheStreamAndResetsKnownSessions() async {
        await startHealthy(state: "blocked")
        await backend.stop()
        XCTAssertGreaterThan(watchers.processes[0].terminateCount, 0)
        await rexWaitUntil { recorder.finished }
        XCTAssertEqual(clock.sleeperCount, 0, "timers are cancelled")

        // A fresh run: the first snapshot settles again and no `.removed` is emitted for sessions
        // the previous run knew.
        recorder = BackendEventRecorder(await backend.events())
        await backend.start()
        await waitForProcess(2)
        watchers.last!.send(RexJSON.snapshot(state: "blocked", session: "s9", label: "nine"))
        await waitForEvent(isConnected)
        XCTAssertFalse(recorder.events.contains { if case .removed = $0 { true } else { false } })
        XCTAssertEqual(recorder.events.lastSnapshot("s9")?.attention.map(\.state), [.blocked])
    }

    func testStopDuringBackoffCancelsTheRestart() async {
        await start()
        await waitForProcess(1)
        watchers.last!.exit(1)
        await waitForSleep(.seconds(1))
        await backend.stop()
        clock.advance(.seconds(60))
        await settleTasks()
        XCTAssertEqual(watchers.processes.count, 1)
    }
}

// MARK: Coalescing

final class RexEventCoalescerTests: XCTestCase {
    private func row(_ b: String, _ state: RowState) -> AgentRow {
        AgentRow(target: AgentTarget(session: rexKey("s1"), paneID: b), displayLabel: b, agentLabel: nil,
                 state: state, subtitle: "", seenToken: nil)
    }

    private func record(_ state: AttentionState, epoch: Int) -> AttentionRecord {
        AttentionRecord(target: AgentTarget(session: rexKey("s1"), paneID: "b1"), recordID: "", epoch: epoch,
                        state: state, visibleLabel: "b1", message: nil)
    }

    func testMergesConsecutiveSnapshotsWithEqualAttention() {
        let a = BackendSnapshot(rows: [row("b1", .working)], attention: [])
        let b = BackendSnapshot(rows: [row("b1", .attention(.blocked))], attention: [])
        let other = BackendSnapshot(rows: [row("x", .working)], attention: [])
        let events: [BackendEvent] = [.snapshot(rexKey("s1"), a), .snapshot(rexKey("s2"), other), .snapshot(rexKey("s1"), b)]
        XCTAssertEqual(RexEventCoalescer.coalesce(events), [.snapshot(rexKey("s2"), other), .snapshot(rexKey("s1"), b)])
    }

    func testKeepsSnapshotsWhoseAttentionDiffers() {
        let settled = BackendSnapshot(rows: [row("b1", .attention(.blocked))], attention: [record(.blocked, epoch: 3)])
        let replaced = BackendSnapshot(rows: [row("b1", .working)], attention: [])
        let events: [BackendEvent] = [.snapshot(rexKey("s1"), settled), .snapshot(rexKey("s1"), replaced)]
        XCTAssertEqual(RexEventCoalescer.coalesce(events), events)
    }

    func testNeverMergesConnectedWithAFollowingSnapshot() {
        let empty = BackendSnapshot.empty
        let later = BackendSnapshot(rows: [row("b1", .working)], attention: [])
        let events: [BackendEvent] = [.connected(rexDescriptor("s1", "work"), empty), .snapshot(rexKey("s1"), later)]
        XCTAssertEqual(RexEventCoalescer.coalesce(events), events)
    }

    func testOtherEventsForTheSessionAreBarriers() {
        let a = BackendSnapshot(rows: [row("b1", .working)], attention: [])
        let b = BackendSnapshot(rows: [row("b2", .working)], attention: [])
        let events: [BackendEvent] = [
            .snapshot(rexKey("s1"), a), .descriptorChanged(rexDescriptor("s1", "renamed")), .snapshot(rexKey("s1"), b),
        ]
        XCTAssertEqual(RexEventCoalescer.coalesce(events), events)
    }
}

// MARK: Helpers

final class RexTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if resume { continuation.resume() }
        }
    }

    func open() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { self.waiters = [] }
            return self.waiters
        }
        waiters.forEach { $0.resume() }
    }
}

/// Resolution fails at once, so the supervision loop ends and holds no reference to the backend.
final class ThrowingResolver: RexCLIResolving, @unchecked Sendable {
    func resolve() async throws -> RexCLIResolution { throw CancellationError() }
    func markFailed(path: String) async {}
}

final class BlockingResolver: RexCLIResolving, @unchecked Sendable {
    let gate: RexTestGate
    let result: RexCLIResolution

    init(gate: RexTestGate, result: RexCLIResolution) {
        self.gate = gate
        self.result = result
    }

    func resolve() async throws -> RexCLIResolution {
        await gate.wait()
        return result
    }

    func markFailed(path: String) async {}
}

/// A watcher whose terminate() blocks until the gate opens.
final class SlowTerminatingWatcherFactory: @unchecked Sendable {
    let gate = RexTestGate()
    private let lock = NSLock()
    private var _process: SlowTerminatingWatcher?
    var process: SlowTerminatingWatcher? { lock.withLock { _process } }

    var factory: RexWatcherFactory {
        { [self] cli, _, generation in
            lock.withLock {
                let process = SlowTerminatingWatcher(cli: cli, generation: generation, gate: gate)
                if _process == nil { _process = process }
                return process
            }
        }
    }
}

final class SlowTerminatingWatcher: RexWatcherProcess, @unchecked Sendable {
    let inner: FakeWatcherProcess
    let gate: RexTestGate

    init(cli: RexCLI, generation: Int, gate: RexTestGate) {
        inner = FakeWatcherProcess(cli: cli, generation: generation)
        self.gate = gate
    }

    var started: Bool { inner.started }
    var terminateCount: Int { inner.terminateCount }
    var lastStderrLine: String? { nil }
    func start() throws(ManagedProcessError) -> AsyncStream<ManagedProcessEvent> { try inner.start() }
    func send(_ objects: [[String: Any]]) { inner.send(objects) }
    func sendFramingError() { inner.sendFramingError() }

    func terminate() async {
        await inner.terminate()
        await gate.wait()
    }
}
