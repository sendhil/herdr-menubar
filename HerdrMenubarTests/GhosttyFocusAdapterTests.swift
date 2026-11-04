import Foundation
import XCTest
@testable import HerdrMenubar

@MainActor
final class GhosttyFocusAdapterTests: XCTestCase {
    private let marker = "herdr-menubar-focus:test-token"
    private let session = SessionID.named("work")

    func testMismatchedSnapshotProcessIdentityFailsAndClearsMarker() async {
        let identities = [
            GhosttyProcessIdentity(pid: 452, launchDate: Date(timeIntervalSince1970: 100)),
            GhosttyProcessIdentity(pid: 451, launchDate: Date(timeIntervalSince1970: 101))
        ]
        for identity in identities {
            let recorder = GhosttyFocusActionRecorder()
            let supervisor = GhosttyFocusSupervisorFake(recorder: recorder)
            let cli = FocusGhosttyControlFake(
                recorder: recorder, listResults: [.success([pane(id: 17, title: marker)])],
                snapshotProcess: identity
            )
            let adapter = makeAdapter(supervisor: supervisor, cli: cli, recorder: recorder)

            await assertFocusError(.targetGone) {
                try await adapter.focusAttachedClient(sessionID: session)
            }
            XCTAssertEqual(recorder.actions, ["set:work:\(marker)", "list", "clear:work"])
            XCTAssertTrue(cli.focusedTerminalIDs.isEmpty)
        }
    }

    func testSetsMarkerFindsExactPaneClearsThenActivates() async throws {
        let recorder = GhosttyFocusActionRecorder()
        let supervisor = GhosttyFocusSupervisorFake(
            recorder: recorder,
            setResults: [.success(ClientWindowTitleResult(
                type: "client_window_title",
                changed: true,
                reason: "future_success_reason"
            ))]
        )
        let cli = FocusGhosttyControlFake(
            recorder: recorder,
            listResults: [.success([
                pane(id: 11, title: "unrelated"),
                pane(id: 22, title: marker),
                pane(id: 33, title: "another client")
            ])]
        )
        let adapter = makeAdapter(supervisor: supervisor, cli: cli, recorder: recorder)

        try await adapter.focusAttachedClient(sessionID: session)

        XCTAssertEqual(recorder.actions, [
            "set:work:\(marker)", "list", "clear:work", "activate:22"
        ])
        XCTAssertEqual(cli.focusedTerminalIDs, ["22"])
    }

    func testDelayedMarkerPropagationPollsAtFiftyMilliseconds() async throws {
        let recorder = GhosttyFocusActionRecorder()
        let supervisor = GhosttyFocusSupervisorFake(recorder: recorder)
        let cli = FocusGhosttyControlFake(
            recorder: recorder,
            listResults: [
                .success([pane(id: 4, title: "old")]),
                .success([pane(id: 4, title: marker)])
            ]
        )
        let adapter = makeAdapter(supervisor: supervisor, cli: cli, recorder: recorder)

        try await adapter.focusAttachedClient(sessionID: session)

        XCTAssertEqual(recorder.actions, [
            "set:work:\(marker)", "list", "sleep:50ms", "list", "clear:work", "activate:4"
        ])
        XCTAssertEqual(cli.focusedTerminalIDs, ["4"])
    }

    func testDuplicateExactMarkersFailClosedAndClear() async {
        let recorder = GhosttyFocusActionRecorder()
        let supervisor = GhosttyFocusSupervisorFake(recorder: recorder)
        let cli = FocusGhosttyControlFake(
            recorder: recorder,
            listResults: [.success([
                pane(id: 1, title: marker), pane(id: 2, title: marker)
            ])]
        )
        let adapter = makeAdapter(supervisor: supervisor, cli: cli, recorder: recorder)

        await assertFocusError(.ambiguousMarker) {
            try await adapter.focusAttachedClient(sessionID: session)
        }

        XCTAssertEqual(recorder.actions, [
            "set:work:\(marker)", "list", "clear:work"
        ])
        XCTAssertTrue(cli.focusedTerminalIDs.isEmpty)
    }

    func testNearMatchDoesNotSelectAndTimesOutAfterOneSecond() async {
        let recorder = GhosttyFocusActionRecorder()
        let supervisor = GhosttyFocusSupervisorFake(recorder: recorder)
        let cli = FocusGhosttyControlFake(
            recorder: recorder, defaultPanes: [pane(id: 8, title: "\(marker)-near")]
        )
        let timing = GhosttyFocusTimingFake(recorder: recorder)
        let adapter = makeAdapter(supervisor: supervisor, cli: cli, timing: timing, recorder: recorder)

        await assertFocusError(.lookupTimedOut) {
            try await adapter.focusAttachedClient(sessionID: session)
        }

        var expected = ["set:work:\(marker)"]
        for _ in 0..<20 {
            expected.append("list")
            expected.append("sleep:50ms")
        }
        expected.append("clear:work")
        XCTAssertEqual(recorder.actions, expected)
        XCTAssertEqual(timing.recordedSleeps, Array(repeating: .milliseconds(50), count: 20))
        XCTAssertEqual(cli.requestedListTimeouts.count, 20)
        XCTAssertEqual(cli.requestedListTimeouts.first, .milliseconds(500))
        XCTAssertEqual(cli.requestedListTimeouts.last, .milliseconds(50))
        XCTAssertTrue(cli.focusedTerminalIDs.isEmpty)
    }

    func testLateMarkerAfterLookupDeadlineIsRejectedAndCleared() async {
        let recorder = GhosttyFocusActionRecorder()
        let supervisor = GhosttyFocusSupervisorFake(recorder: recorder)
        let listGate = GhosttyFocusListGate()
        let cli = FocusGhosttyControlFake(
            recorder: recorder,
            listResults: [.success([pane(id: 91, title: marker)])],
            listGate: listGate
        )
        let timing = GhosttyFocusTimingFake(recorder: recorder)
        let adapter = makeAdapter(supervisor: supervisor, cli: cli, timing: timing, recorder: recorder)
        let operation = Task {
            await capturedError { try await adapter.focusAttachedClient(sessionID: session) }
        }
        await listGate.waitUntilEntered()
        timing.advance(by: .seconds(1))
        listGate.release()
        let error = await operation.value

        XCTAssertEqual(error as? GhosttyFocusError, .lookupTimedOut)
        XCTAssertEqual(supervisor.clearSessionIDs, [session])
        XCTAssertTrue(cli.focusedTerminalIDs.isEmpty)
    }

    func testNoForegroundClientDoesNotListActivateOrClear() async {
        let recorder = GhosttyFocusActionRecorder()
        let supervisor = GhosttyFocusSupervisorFake(
            recorder: recorder, setResults: [.success(noForegroundResult)]
        )
        let cli = FocusGhosttyControlFake(
            recorder: recorder, defaultPanes: [pane(id: 8, title: marker)]
        )
        let adapter = makeAdapter(supervisor: supervisor, cli: cli, recorder: recorder)

        await assertFocusError(.noAttachedClient) {
            try await adapter.focusAttachedClient(sessionID: session)
        }

        XCTAssertEqual(recorder.actions, ["set:work:\(marker)"])
        XCTAssertTrue(supervisor.clearSessionIDs.isEmpty)
        XCTAssertTrue(cli.focusedTerminalIDs.isEmpty)
    }

    func testMethodNotFoundReportsUnsupportedHerdrAndDoesNotList() async {
        let recorder = GhosttyFocusActionRecorder()
        let supervisor = GhosttyFocusSupervisorFake(
            recorder: recorder,
            setResults: [.failure(HerdrAPIError(code: "method_not_found", message: "private"))]
        )
        let cli = FocusGhosttyControlFake(recorder: recorder)
        let adapter = makeAdapter(supervisor: supervisor, cli: cli, recorder: recorder)

        await assertFocusError(.unsupportedHerdr) {
            try await adapter.focusAttachedClient(sessionID: session)
        }

        XCTAssertEqual(recorder.actions, ["set:work:\(marker)"])
        XCTAssertTrue(supervisor.clearSessionIDs.isEmpty)
        XCTAssertTrue(cli.focusedTerminalIDs.isEmpty)
    }

    func testClearRetriesThreeTimesWithinFiveHundredMilliseconds() async {
        let recorder = GhosttyFocusActionRecorder()
        let supervisor = GhosttyFocusSupervisorFake(
            recorder: recorder, clearResults: threeClearFailures
        )
        let cli = FocusGhosttyControlFake(
            recorder: recorder,
            listResults: [.success([pane(id: 5, title: marker)])]
        )
        let timing = GhosttyFocusTimingFake(recorder: recorder)
        let adapter = makeAdapter(supervisor: supervisor, cli: cli, timing: timing, recorder: recorder)

        await assertFocusError(.markerCleanupFailed) {
            try await adapter.focusAttachedClient(sessionID: session)
        }

        XCTAssertEqual(recorder.actions, [
            "set:work:\(marker)", "list", "clear:work", "sleep:100ms",
            "clear:work", "sleep:100ms", "clear:work"
        ])
        XCTAssertEqual(timing.recordedSleeps, [.milliseconds(100), .milliseconds(100)])
        XCTAssertEqual(supervisor.requestedClearTimeouts, [
            .milliseconds(500), .milliseconds(400), .milliseconds(300)
        ])
        XCTAssertTrue(cli.focusedTerminalIDs.isEmpty)
    }

    private func makeAdapter(
        supervisor: GhosttyFocusSupervisorFake,
        cli: FocusGhosttyControlFake,
        timing: GhosttyFocusTimingFake? = nil,
        recorder: GhosttyFocusActionRecorder
    ) -> LiveGhosttyFocusAdapter {
        LiveGhosttyFocusAdapter(
            supervisor: supervisor,
            control: cli,
            timing: timing ?? GhosttyFocusTimingFake(recorder: recorder),
            markerGenerator: { "herdr-menubar-focus:test-token" }
        )
    }

    private func pane(id: Int, title: String) -> GhosttyTerminal {
        GhosttyTerminal(id: String(id), title: title)
    }

    private var setResult: ClientWindowTitleResult {
        ClientWindowTitleResult(type: "client_window_title", changed: true, reason: "set")
    }

    private var clearedResult: ClientWindowTitleResult {
        ClientWindowTitleResult(type: "client_window_title", changed: true, reason: "cleared")
    }

    private var noForegroundResult: ClientWindowTitleResult {
        ClientWindowTitleResult(
            type: "client_window_title",
            changed: false,
            reason: "no_foreground_client"
        )
    }

    private var threeClearFailures: [Result<ClientWindowTitleResult, Error>] {
        [
            .failure(SessionSupervisorError.sessionUnavailable("work")),
            .failure(SessionSupervisorError.sessionUnavailable("work")),
            .failure(SessionSupervisorError.sessionUnavailable("work"))
        ]
    }

    private func assertFocusError(
        _ expected: GhosttyFocusError,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let error = await capturedError(operation: operation)
        XCTAssertEqual(error as? GhosttyFocusError, expected, file: file, line: line)
    }

    private func capturedError(
        operation: () async throws -> Void
    ) async -> Error? {
        do {
            try await operation()
            return nil
        } catch {
            return error
        }
    }

    private func assertForgetInvalidatesSuspendedCleanup(
        _ clearResult: Result<ClientWindowTitleResult, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let recorder = GhosttyFocusActionRecorder()
        let clearGate = GhosttyFocusListGate()
        let supervisor = GhosttyFocusSupervisorFake(
            recorder: recorder,
            setResults: [.success(setResult), .success(noForegroundResult)],
            clearResults: [clearResult],
            clearGate: clearGate
        )
        let cli = FocusGhosttyControlFake(
            recorder: recorder,
            listResults: [.success([pane(id: 63, title: marker)])]
        )
        let timing = GhosttyFocusTimingFake(recorder: recorder)
        timing.blockSleep(for: .milliseconds(500))
        let adapter = makeAdapter(
            supervisor: supervisor,
            cli: cli,
            timing: timing,
            recorder: recorder
        )

        let oldOperation = Task {
            await capturedError {
                try await adapter.focusAttachedClient(sessionID: session)
            }
        }
        await clearGate.waitUntilEntered()
        adapter.forget(sessionID: session)
        clearGate.release()
        let oldError = await oldOperation.value
        timing.unblockSleep(for: .milliseconds(500))

        XCTAssertTrue(oldError is CancellationError, file: file, line: line)
        XCTAssertTrue(cli.focusedTerminalIDs.isEmpty, file: file, line: line)
        let recreatedError = await capturedError {
            try await adapter.focusAttachedClient(sessionID: session)
        }
        XCTAssertEqual(
            recreatedError as? GhosttyFocusError,
            .noAttachedClient,
            file: file,
            line: line
        )
        XCTAssertEqual(
            recorder.actions,
            [
                "set:work:\(marker)", "list", "clear:work", "sleep:500ms",
                "set:work:\(marker)"
            ],
            file: file,
            line: line
        )
        XCTAssertTrue(cli.focusedTerminalIDs.isEmpty, file: file, line: line)
    }

    private func assertForgetInvalidatesSuspendedSet(
        _ setError: any Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let recorder = GhosttyFocusActionRecorder()
        let setGate = GhosttyFocusListGate()
        let supervisor = GhosttyFocusSupervisorFake(
            recorder: recorder,
            setResults: [.failure(setError), .success(noForegroundResult)],
            setGate: setGate
        )
        let cli = FocusGhosttyControlFake(recorder: recorder)
        let adapter = makeAdapter(supervisor: supervisor, cli: cli, recorder: recorder)

        let oldOperation = Task {
            await capturedError {
                try await adapter.focusAttachedClient(sessionID: session)
            }
        }
        await setGate.waitUntilEntered()
        adapter.forget(sessionID: session)
        setGate.release()
        let oldError = await oldOperation.value

        XCTAssertTrue(oldError is CancellationError, file: file, line: line)
        let recreatedError = await capturedError {
            try await adapter.focusAttachedClient(sessionID: session)
        }
        XCTAssertEqual(
            recreatedError as? GhosttyFocusError,
            .noAttachedClient,
            file: file,
            line: line
        )
        XCTAssertEqual(
            recorder.actions,
            ["set:work:\(marker)", "set:work:\(marker)"],
            file: file,
            line: line
        )
        XCTAssertTrue(cli.focusedTerminalIDs.isEmpty, file: file, line: line)
    }
}

extension GhosttyFocusAdapterTests {
    func testInvalidationDuringPreparationDoesNotSetAnyMarker() async {
        for forgetSession in [false, true] {
            let recorder = GhosttyFocusActionRecorder()
            let gate = GhosttyFocusListGate()
            let supervisor = GhosttyFocusSupervisorFake(recorder: recorder)
            let cli = FocusGhosttyControlFake(
                recorder: recorder, defaultPanes: [pane(id: 63, title: marker)], prepareGate: gate
            )
            let adapter = makeAdapter(supervisor: supervisor, cli: cli, recorder: recorder)
            let operation = Task {
                await capturedError { try await adapter.focusAttachedClient(sessionID: session) }
            }
            await gate.waitUntilEntered()
            if forgetSession {
                adapter.forget(sessionID: session)
            } else {
                operation.cancel()
            }
            gate.release()
            let error = await operation.value

            XCTAssertTrue(error is CancellationError)
            XCTAssertTrue(recorder.actions.isEmpty, "Invalid preparation must not reach Herdr title control")
            XCTAssertTrue(supervisor.setTitles.isEmpty)
            XCTAssertTrue(supervisor.clearSessionIDs.isEmpty)
            XCTAssertTrue(cli.focusedTerminalIDs.isEmpty)
        }
    }

    func testForgetInvalidatesSuccessfulTitleRepliesBeforeListing() async {
        for reply in [setResult, noForegroundResult] {
            let recorder = GhosttyFocusActionRecorder()
            let gate = GhosttyFocusListGate()
            let supervisor = GhosttyFocusSupervisorFake(
                recorder: recorder,
                setResults: [.success(reply), .success(noForegroundResult)],
                setGate: gate
            )
            let cli = FocusGhosttyControlFake(
                recorder: recorder, defaultPanes: [pane(id: 63, title: marker)]
            )
            let adapter = makeAdapter(supervisor: supervisor, cli: cli, recorder: recorder)
            let oldOperation = Task {
                await capturedError { try await adapter.focusAttachedClient(sessionID: session) }
            }
            await gate.waitUntilEntered()
            adapter.forget(sessionID: session)
            gate.release()
            let error = await oldOperation.value

            XCTAssertTrue(error is CancellationError)
            XCTAssertEqual(recorder.actions, ["set:work:\(marker)"])
            XCTAssertTrue(supervisor.clearSessionIDs.isEmpty)
            XCTAssertTrue(cli.focusedTerminalIDs.isEmpty)
            await assertFocusError(.noAttachedClient) {
                try await adapter.focusAttachedClient(sessionID: session)
            }
            XCTAssertEqual(recorder.actions, ["set:work:\(marker)", "set:work:\(marker)"])
        }
    }

    func testForgetInvalidatesSuspendedCleanupAndRecreatedSessionStartsClean() async {
        await assertForgetInvalidatesSuspendedCleanup(.success(clearedResult))
        await assertForgetInvalidatesSuspendedCleanup(
            .failure(SessionSupervisorError.sessionUnavailable("work"))
        )
    }

    func testForgetInvalidatesSuspendedSetErrorsAndRecreatedSessionStartsClean() async {
        await assertForgetInvalidatesSuspendedSet(
            HerdrAPIError(code: "method_not_found", message: "private")
        )
        await assertForgetInvalidatesSuspendedSet(
            SessionSupervisorError.sessionUnavailable("work")
        )
    }

    func testForgetDropsPendingStateForRemovedSession() async {
        let recorder = GhosttyFocusActionRecorder()
        let supervisor = GhosttyFocusSupervisorFake(
            recorder: recorder,
            setResults: [.success(setResult), .success(noForegroundResult)],
            clearResults: threeClearFailures
        )
        let cli = FocusGhosttyControlFake(
            recorder: recorder,
            listResults: [.success([pane(id: 6, title: marker)])]
        )
        let adapter = makeAdapter(supervisor: supervisor, cli: cli, recorder: recorder)

        await assertFocusError(.markerCleanupFailed) {
            try await adapter.focusAttachedClient(sessionID: session)
        }
        adapter.forget(sessionID: session)
        await assertFocusError(.noAttachedClient) {
            try await adapter.focusAttachedClient(sessionID: session)
        }

        XCTAssertEqual(recorder.actions, [
            "set:work:\(marker)", "list", "clear:work", "sleep:100ms",
            "clear:work", "sleep:100ms", "clear:work", "set:work:\(marker)"
        ])
        XCTAssertTrue(cli.focusedTerminalIDs.isEmpty)
    }

    func testPendingCleanupMustSucceedBeforeNewMarkerForSameSession() async {
        let recorder = GhosttyFocusActionRecorder()
        let supervisor = GhosttyFocusSupervisorFake(
            recorder: recorder,
            clearResults: threeClearFailures + [.success(clearedResult), .success(clearedResult)]
        )
        let cli = FocusGhosttyControlFake(
            recorder: recorder,
            listResults: [
                .success([pane(id: 6, title: marker)]),
                .success([pane(id: 7, title: marker)])
            ]
        )
        let adapter = makeAdapter(supervisor: supervisor, cli: cli, recorder: recorder)

        await assertFocusError(.markerCleanupFailed) {
            try await adapter.focusAttachedClient(sessionID: session)
        }
        let retryError = await capturedError {
            try await adapter.focusAttachedClient(sessionID: session)
        }

        XCTAssertNil(retryError)
        XCTAssertEqual(recorder.actions, [
            "set:work:\(marker)", "list", "clear:work", "sleep:100ms",
            "clear:work", "sleep:100ms", "clear:work",
            "clear:work", "set:work:\(marker)", "list", "clear:work", "activate:7"
        ])
        XCTAssertEqual(cli.focusedTerminalIDs, ["7"])
    }

    func testCancellationAfterSetRunsCancellationIndependentCleanup() async {
        let recorder = GhosttyFocusActionRecorder()
        let supervisor = GhosttyFocusSupervisorFake(
            recorder: recorder,
            clearResults: [
                .failure(SessionSupervisorError.sessionUnavailable("work")),
                .success(clearedResult)
            ]
        )
        let gate = GhosttyFocusListGate()
        let cli = FocusGhosttyControlFake(
            recorder: recorder,
            listResults: [.success([pane(id: 42, title: marker)])],
            listGate: gate
        )
        let adapter = makeAdapter(supervisor: supervisor, cli: cli, recorder: recorder)

        let operation = Task {
            try await adapter.focusAttachedClient(sessionID: session)
        }
        await gate.waitUntilEntered()
        operation.cancel()
        gate.release()
        let error = await capturedError { try await operation.value }

        XCTAssertTrue(error is CancellationError)
        XCTAssertEqual(recorder.actions, [
            "set:work:\(marker)", "list", "clear:work", "sleep:100ms", "clear:work"
        ])
        XCTAssertEqual(supervisor.clearObservedCancellation, [false, false])
        XCTAssertTrue(cli.focusedTerminalIDs.isEmpty)
    }

    func testSuspendedClearIsBoundedByOverallCleanupDeadlineAndLateSuccessIsIgnored() async {
        let recorder = GhosttyFocusActionRecorder()
        let clearGate = GhosttyFocusListGate()
        let supervisor = GhosttyFocusSupervisorFake(
            recorder: recorder,
            clearResults: [.success(clearedResult)],
            clearGate: clearGate
        )
        let cli = FocusGhosttyControlFake(
            recorder: recorder,
            listResults: [.success([pane(id: 62, title: marker)])]
        )
        let timing = GhosttyFocusTimingFake(recorder: recorder)
        let adapter = makeAdapter(supervisor: supervisor, cli: cli, timing: timing, recorder: recorder)
        let completion = GhosttyFocusCompletionProbe()

        let operation = Task {
            let error = await capturedError {
                try await adapter.focusAttachedClient(sessionID: session)
            }
            completion.finish(error)
        }
        await clearGate.waitUntilEntered()
        for _ in 0..<100 { await Task.yield() }
        let completedBeforeLateRPC = completion.isFinished
        clearGate.release()
        await operation.value
        await supervisor.waitForClearCompletion(count: 1)

        XCTAssertTrue(completedBeforeLateRPC, "Cleanup must finish without waiting for the suspended RPC")
        XCTAssertEqual(completion.error as? GhosttyFocusError, .markerCleanupFailed)
        XCTAssertEqual(supervisor.requestedClearTimeouts, [.milliseconds(500)])
        XCTAssertEqual(supervisor.clearObservedCancellation, [true])
        XCTAssertEqual(recorder.actions, [
            "set:work:\(marker)", "list", "clear:work", "sleep:500ms"
        ])
        XCTAssertTrue(cli.focusedTerminalIDs.isEmpty)
    }
}

// Invalidated preparation and lookups must stop at each suspension boundary.
extension GhosttyFocusAdapterTests {
    func testForgetInvalidatesPreparationErrorsAndRecreatedSessionStartsClean() async {
        for preparationError: GhosttyFocusError in [.automationDenied, .ghosttyUnavailable] {
            let recorder = GhosttyFocusActionRecorder()
            let supervisor = GhosttyFocusSupervisorFake(recorder: recorder)
            let gate = GhosttyFocusListGate()
            let cli = FocusGhosttyControlFake(
                recorder: recorder, listResults: [.success([pane(id: 7, title: marker)])],
                prepareGate: gate, prepareResults: [.failure(preparationError)]
            )
            let adapter = makeAdapter(supervisor: supervisor, cli: cli, recorder: recorder)
            let operation = Task { try await adapter.focusAttachedClient(sessionID: session) }
            await gate.waitUntilEntered()
            adapter.forget(sessionID: session)
            gate.release()
            let error = await capturedError { try await operation.value }

            XCTAssertTrue(error is CancellationError, "Obsolete preparation errors must not escape invalidation")
            XCTAssertTrue(recorder.actions.isEmpty, "Invalid preparation cannot set, list, clear, or focus")
            let recreatedError = await capturedError {
                try await adapter.focusAttachedClient(sessionID: session)
            }
            XCTAssertNil(recreatedError)
            XCTAssertEqual(recorder.actions, ["set:work:\(marker)", "list", "clear:work", "activate:7"])
            XCTAssertEqual(cli.focusedTerminalIDs, ["7"])
        }
    }

    func testForgetDuringLookupStopsBeforeAnyFurtherPollingOrCleanup() async {
        for duringList in [true, false] {
            let recorder = GhosttyFocusActionRecorder()
            let supervisor = GhosttyFocusSupervisorFake(recorder: recorder)
            let gate = GhosttyFocusListGate()
            let timing = GhosttyFocusTimingFake(recorder: recorder)
            if !duringList { timing.blockSleep(for: .milliseconds(50)) }
            let cli = FocusGhosttyControlFake(
                recorder: recorder, listResults: [.success([]), .success([pane(id: 7, title: marker)])],
                listGate: duringList ? gate : nil
            )
            let adapter = makeAdapter(supervisor: supervisor, cli: cli, timing: timing, recorder: recorder)
            let operation = Task { try await adapter.focusAttachedClient(sessionID: session) }
            if duringList {
                await gate.waitUntilEntered()
            } else {
                while timing.recordedSleeps.isEmpty { await Task.yield() }
            }
            adapter.forget(sessionID: session)
            if duringList {
                gate.release()
            } else {
                timing.unblockSleep(for: .milliseconds(50))
            }
            let error = await capturedError { try await operation.value }

            XCTAssertTrue(error is CancellationError)
            var expected = ["set:work:\(marker)", "list"]
            if !duringList { expected.append("sleep:50ms") }
            XCTAssertEqual(recorder.actions, expected, "An invalidated lookup must stop before another list or clear")
            XCTAssertTrue(cli.focusedTerminalIDs.isEmpty)
        }
    }
}

// Preserved behavioral regressions from the replaced terminal backend.
extension GhosttyFocusAdapterTests {
    func testListFailuresClearMarkerBeforeReturningError() async {
        for listError: GhosttyFocusError in [.ghosttyControlFailed, .targetGone] {
            let recorder = GhosttyFocusActionRecorder()
            let supervisor = GhosttyFocusSupervisorFake(recorder: recorder)
            let cli = FocusGhosttyControlFake(recorder: recorder, listResults: [.failure(listError)])
            let adapter = makeAdapter(supervisor: supervisor, cli: cli, recorder: recorder)

            await assertFocusError(listError) {
                try await adapter.focusAttachedClient(sessionID: session)
            }
            XCTAssertEqual(recorder.actions, ["set:work:\(marker)", "list", "clear:work"])
            XCTAssertTrue(cli.focusedTerminalIDs.isEmpty)
        }
    }

    func testFocusFailureOccursOnlyAfterSuccessfulClear() async {
        let recorder = GhosttyFocusActionRecorder()
        let supervisor = GhosttyFocusSupervisorFake(recorder: recorder)
        let cli = FocusGhosttyControlFake(
            recorder: recorder, listResults: [.success([pane(id: 19, title: marker)])],
            activationResults: [.failure(GhosttyFocusError.ghosttyControlFailed)]
        )
        let adapter = makeAdapter(supervisor: supervisor, cli: cli, recorder: recorder)

        await assertFocusError(.ghosttyControlFailed) {
            try await adapter.focusAttachedClient(sessionID: session)
        }
        XCTAssertEqual(recorder.actions, ["set:work:\(marker)", "list", "clear:work", "activate:19"])
        XCTAssertEqual(cli.focusedTerminalIDs, ["19"])
    }

    func testClearFailureRecordsPendingAndDoesNotFocus() async {
        let recorder = GhosttyFocusActionRecorder()
        let supervisor = GhosttyFocusSupervisorFake(recorder: recorder, clearResults: threeClearFailures)
        let cli = FocusGhosttyControlFake(recorder: recorder, listResults: [.success([pane(id: 6, title: marker)])])
        let adapter = makeAdapter(supervisor: supervisor, cli: cli, recorder: recorder)

        await assertFocusError(.markerCleanupFailed) {
            try await adapter.focusAttachedClient(sessionID: session)
        }
        XCTAssertEqual(supervisor.clearSessionIDs, [session, session, session])
        XCTAssertEqual(recorder.actions, [
            "set:work:\(marker)", "list", "clear:work", "sleep:100ms",
            "clear:work", "sleep:100ms", "clear:work"
        ])
        XCTAssertTrue(cli.focusedTerminalIDs.isEmpty)
    }

    func testNoForegroundClientDuringPendingCleanupResolvesPendingState() async {
        let recorder = GhosttyFocusActionRecorder()
        let supervisor = GhosttyFocusSupervisorFake(
            recorder: recorder,
            setResults: [.success(setResult), .success(noForegroundResult), .success(noForegroundResult)],
            clearResults: threeClearFailures + [.success(noForegroundResult)]
        )
        let cli = FocusGhosttyControlFake(recorder: recorder, listResults: [.success([pane(id: 6, title: marker)])])
        let adapter = makeAdapter(supervisor: supervisor, cli: cli, recorder: recorder)

        await assertFocusError(.markerCleanupFailed) {
            try await adapter.focusAttachedClient(sessionID: session)
        }
        await assertFocusError(.noAttachedClient) {
            try await adapter.focusAttachedClient(sessionID: session)
        }
        await assertFocusError(.noAttachedClient) {
            try await adapter.focusAttachedClient(sessionID: session)
        }
        XCTAssertEqual(recorder.actions, [
            "set:work:\(marker)", "list", "clear:work", "sleep:100ms",
            "clear:work", "sleep:100ms", "clear:work",
            "clear:work", "set:work:\(marker)", "set:work:\(marker)"
        ])
        XCTAssertTrue(cli.focusedTerminalIDs.isEmpty)
    }

    func testDifferentSessionCanProceedAfterPriorPendingCleanupFailure() async {
        let recorder = GhosttyFocusActionRecorder()
        let supervisor = GhosttyFocusSupervisorFake(
            recorder: recorder, clearResults: threeClearFailures + [.success(clearedResult)]
        )
        let cli = FocusGhosttyControlFake(recorder: recorder, listResults: [
            .success([pane(id: 6, title: marker)]), .success([pane(id: 77, title: marker)])
        ])
        let adapter = makeAdapter(supervisor: supervisor, cli: cli, recorder: recorder)
        let other = SessionID.named("other")

        await assertFocusError(.markerCleanupFailed) {
            try await adapter.focusAttachedClient(sessionID: session)
        }
        let otherError = await capturedError { try await adapter.focusAttachedClient(sessionID: other) }

        XCTAssertNil(otherError)
        XCTAssertEqual(recorder.actions, [
            "set:work:\(marker)", "list", "clear:work", "sleep:100ms",
            "clear:work", "sleep:100ms", "clear:work",
            "set:other:\(marker)", "list", "clear:other", "activate:77"
        ])
        XCTAssertEqual(cli.focusedTerminalIDs, ["77"])
    }

    func testOpaqueMarkerContainsNoSessionPaneSocketOrAgentText() async throws {
        let recorder = GhosttyFocusActionRecorder()
        let supervisor = GhosttyFocusSupervisorFake(recorder: recorder, setResults: [.success(noForegroundResult)])
        let cli = FocusGhosttyControlFake(recorder: recorder)
        let adapter = LiveGhosttyFocusAdapter(
            supervisor: supervisor, control: cli, timing: GhosttyFocusTimingFake(recorder: recorder)
        )
        let privateSession = SessionID.named("secret-session")

        _ = await capturedError { try await adapter.focusAttachedClient(sessionID: privateSession) }
        let generated = try XCTUnwrap(supervisor.setTitles.only)
        XCTAssertTrue(generated.hasPrefix("herdr-menubar-focus:"))
        XCTAssertFalse(generated.contains("secret-session"))
        XCTAssertFalse(generated.contains("pane-77"))
        XCTAssertFalse(generated.contains("/private/socket"))
        XCTAssertFalse(generated.contains("Claude"))
        XCTAssertEqual(recorder.actions, ["set:secret-session:\(generated)"])
        XCTAssertTrue(cli.focusedTerminalIDs.isEmpty)
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
