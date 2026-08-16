import Foundation
import XCTest
@testable import HerdrMenubar

@MainActor
final class WezTermFocusAdapterTests: XCTestCase {
    private let marker = "herdr-menubar-focus:test-token"
    private let session = SessionID.named("work")

    func testSetsMarkerFindsExactPaneClearsThenActivates() async throws {
        let recorder = FocusActionRecorder()
        let supervisor = FocusSupervisorFake(
            recorder: recorder,
            setResults: [.success(ClientWindowTitleResult(
                type: "client_window_title",
                changed: true,
                reason: "future_success_reason"
            ))]
        )
        let cli = FocusCLIFake(
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
        XCTAssertEqual(cli.activatedPaneIDs, [22])
    }

    func testDelayedMarkerPropagationPollsAtFiftyMilliseconds() async throws {
        let recorder = FocusActionRecorder()
        let supervisor = FocusSupervisorFake(recorder: recorder)
        let cli = FocusCLIFake(
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
        XCTAssertEqual(cli.activatedPaneIDs, [4])
    }

    func testDuplicateExactMarkersFailClosedAndClear() async {
        let recorder = FocusActionRecorder()
        let supervisor = FocusSupervisorFake(recorder: recorder)
        let cli = FocusCLIFake(
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
        XCTAssertTrue(cli.activatedPaneIDs.isEmpty)
    }

    func testNearMatchDoesNotSelectAndTimesOutAfterOneSecond() async {
        let recorder = FocusActionRecorder()
        let supervisor = FocusSupervisorFake(recorder: recorder)
        let cli = FocusCLIFake(
            recorder: recorder,
            defaultPanes: [pane(id: 8, title: "\(marker)-near")]
        )
        let timing = FocusTimingFake(recorder: recorder)
        let adapter = makeAdapter(
            supervisor: supervisor,
            cli: cli,
            timing: timing,
            recorder: recorder
        )

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
        XCTAssertTrue(cli.requestedListTimeouts.allSatisfy { $0 <= .milliseconds(500) })
        XCTAssertTrue(cli.activatedPaneIDs.isEmpty)
    }

    func testLateMarkerAfterLookupDeadlineIsRejectedAndCleared() async {
        let recorder = FocusActionRecorder()
        let supervisor = FocusSupervisorFake(recorder: recorder)
        let listGate = FocusListGate()
        let cli = FocusCLIFake(
            recorder: recorder,
            listResults: [.success([pane(id: 91, title: marker)])],
            listGate: listGate
        )
        let timing = FocusTimingFake(recorder: recorder)
        let adapter = makeAdapter(
            supervisor: supervisor,
            cli: cli,
            timing: timing,
            recorder: recorder
        )

        let operation = Task {
            await capturedError {
                try await adapter.focusAttachedClient(sessionID: session)
            }
        }
        await listGate.waitUntilEntered()
        timing.advance(by: .seconds(1))
        listGate.release()
        let error = await operation.value

        XCTAssertEqual(error as? WezTermFocusError, .lookupTimedOut)
        XCTAssertEqual(cli.requestedListTimeouts, [.milliseconds(500)])
        XCTAssertEqual(recorder.actions, [
            "set:work:\(marker)", "list", "clear:work"
        ])
        XCTAssertTrue(cli.activatedPaneIDs.isEmpty)
    }

    func testNoForegroundClientDoesNotListActivateOrClear() async {
        let recorder = FocusActionRecorder()
        let supervisor = FocusSupervisorFake(
            recorder: recorder,
            setResults: [.success(noForegroundResult)]
        )
        let cli = FocusCLIFake(recorder: recorder)
        let adapter = makeAdapter(supervisor: supervisor, cli: cli, recorder: recorder)

        await assertFocusError(.noAttachedClient) {
            try await adapter.focusAttachedClient(sessionID: session)
        }

        XCTAssertEqual(recorder.actions, ["set:work:\(marker)"])
        XCTAssertTrue(cli.activatedPaneIDs.isEmpty)
    }

    func testMethodNotFoundReportsUnsupportedHerdrAndDoesNotList() async {
        let recorder = FocusActionRecorder()
        let supervisor = FocusSupervisorFake(
            recorder: recorder,
            setResults: [.failure(HerdrAPIError(code: "method_not_found", message: "private"))]
        )
        let cli = FocusCLIFake(recorder: recorder)
        let adapter = makeAdapter(supervisor: supervisor, cli: cli, recorder: recorder)

        await assertFocusError(.unsupportedHerdr) {
            try await adapter.focusAttachedClient(sessionID: session)
        }

        XCTAssertEqual(recorder.actions, ["set:work:\(marker)"])
        XCTAssertTrue(cli.activatedPaneIDs.isEmpty)
    }

    func testForgetWhileSetIsSuspendedInvalidatesMethodNotFoundAndRecreatedSessionStartsClean() async {
        await assertForgetInvalidatesSuspendedSet(
            HerdrAPIError(code: "method_not_found", message: "private")
        )
    }

    func testForgetWhileSetIsSuspendedInvalidatesTransportFailureAndRecreatedSessionStartsClean() async {
        await assertForgetInvalidatesSuspendedSet(
            SessionSupervisorError.sessionUnavailable("work")
        )
    }

    func testMalformedListOutputClearsMarkerBeforeReturningError() async {
        let recorder = FocusActionRecorder()
        let supervisor = FocusSupervisorFake(recorder: recorder)
        let cli = FocusCLIFake(
            recorder: recorder,
            listResults: [.failure(WezTermCLIError.malformedOutput)]
        )
        let adapter = makeAdapter(supervisor: supervisor, cli: cli, recorder: recorder)

        await assertFocusError(.wezTermControlFailed) {
            try await adapter.focusAttachedClient(sessionID: session)
        }

        XCTAssertEqual(recorder.actions, [
            "set:work:\(marker)", "list", "clear:work"
        ])
        XCTAssertTrue(cli.activatedPaneIDs.isEmpty)

        let unavailableRecorder = FocusActionRecorder()
        let unavailableSupervisor = FocusSupervisorFake(recorder: unavailableRecorder)
        let unavailableCLI = FocusCLIFake(
            recorder: unavailableRecorder,
            listResults: [.failure(WezTermCLIError.unavailable)]
        )
        let unavailableAdapter = makeAdapter(
            supervisor: unavailableSupervisor,
            cli: unavailableCLI,
            recorder: unavailableRecorder
        )
        await assertFocusError(.wezTermUnavailable) {
            try await unavailableAdapter.focusAttachedClient(sessionID: session)
        }
        XCTAssertEqual(unavailableRecorder.actions, [
            "set:work:\(marker)", "list", "clear:work"
        ])
        XCTAssertTrue(unavailableCLI.activatedPaneIDs.isEmpty)
    }

    func testActivationFailureOccursOnlyAfterSuccessfulClear() async {
        let recorder = FocusActionRecorder()
        let supervisor = FocusSupervisorFake(recorder: recorder)
        let cli = FocusCLIFake(
            recorder: recorder,
            listResults: [.success([pane(id: 19, title: marker)])],
            activationResults: [.failure(WezTermCLIError.controlFailed)]
        )
        let adapter = makeAdapter(supervisor: supervisor, cli: cli, recorder: recorder)

        await assertFocusError(.wezTermControlFailed) {
            try await adapter.focusAttachedClient(sessionID: session)
        }

        XCTAssertEqual(recorder.actions, [
            "set:work:\(marker)", "list", "clear:work", "activate:19"
        ])
        XCTAssertEqual(cli.activatedPaneIDs, [19])
    }

    func testCancellationAfterSetRunsCancellationIndependentCleanup() async {
        let recorder = FocusActionRecorder()
        let supervisor = FocusSupervisorFake(
            recorder: recorder,
            clearResults: [
                .failure(SessionSupervisorError.sessionUnavailable("work")),
                .success(clearedResult)
            ]
        )
        let gate = FocusListGate()
        let cli = FocusCLIFake(
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
        XCTAssertTrue(cli.activatedPaneIDs.isEmpty)
    }

    func testSuspendedClearIsBoundedByOverallCleanupDeadlineAndLateSuccessIsIgnored() async {
        let recorder = FocusActionRecorder()
        let clearGate = FocusListGate()
        let supervisor = FocusSupervisorFake(
            recorder: recorder,
            setResults: [.success(setResult), .success(noForegroundResult)],
            clearResults: [.success(clearedResult), .success(noForegroundResult)],
            clearGate: clearGate
        )
        let cli = FocusCLIFake(
            recorder: recorder,
            listResults: [.success([pane(id: 62, title: marker)])]
        )
        let timing = FocusTimingFake(recorder: recorder)
        let adapter = makeAdapter(
            supervisor: supervisor,
            cli: cli,
            timing: timing,
            recorder: recorder
        )
        let completion = FocusCompletionProbe()

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

        XCTAssertTrue(completedBeforeLateRPC, "Cleanup must not inherit Herdr's five-second timeout")
        XCTAssertEqual(completion.error as? WezTermFocusError, .markerCleanupFailed)
        XCTAssertEqual(supervisor.requestedClearTimeouts.first, .milliseconds(500))
        XCTAssertEqual(supervisor.clearObservedCancellation.first, true)
        XCTAssertTrue(cli.activatedPaneIDs.isEmpty)

        await assertFocusError(.noAttachedClient) {
            try await adapter.focusAttachedClient(sessionID: session)
        }
        XCTAssertEqual(recorder.actions, [
            "set:work:\(marker)", "list", "clear:work", "sleep:500ms",
            "clear:work", "set:work:\(marker)"
        ])
        XCTAssertTrue(cli.activatedPaneIDs.isEmpty)
    }

    func testForgetInvalidatesSuspendedSuccessfulCleanupAndRecreatedSessionStartsClean() async {
        await assertForgetInvalidatesSuspendedCleanup(.success(clearedResult))
    }

    func testForgetInvalidatesSuspendedFailedCleanupAndRecreatedSessionStartsClean() async {
        await assertForgetInvalidatesSuspendedCleanup(
            .failure(SessionSupervisorError.sessionUnavailable("work"))
        )
    }

    func testClearRetriesThreeTimesWithinFiveHundredMilliseconds() async {
        let recorder = FocusActionRecorder()
        let supervisor = FocusSupervisorFake(
            recorder: recorder,
            clearResults: threeClearFailures
        )
        let cli = FocusCLIFake(
            recorder: recorder,
            listResults: [.success([pane(id: 5, title: marker)])]
        )
        let timing = FocusTimingFake(recorder: recorder)
        let adapter = makeAdapter(
            supervisor: supervisor,
            cli: cli,
            timing: timing,
            recorder: recorder
        )

        await assertFocusError(.markerCleanupFailed) {
            try await adapter.focusAttachedClient(sessionID: session)
        }

        XCTAssertEqual(recorder.actions, [
            "set:work:\(marker)", "list", "clear:work", "sleep:100ms",
            "clear:work", "sleep:100ms", "clear:work"
        ])
        XCTAssertEqual(timing.recordedSleeps, [.milliseconds(100), .milliseconds(100)])
        XCTAssertTrue(cli.activatedPaneIDs.isEmpty)
    }

    func testClearFailureRecordsPendingAndDoesNotActivate() async {
        let recorder = FocusActionRecorder()
        let supervisor = FocusSupervisorFake(
            recorder: recorder,
            clearResults: threeClearFailures
        )
        let cli = FocusCLIFake(
            recorder: recorder,
            listResults: [.success([pane(id: 6, title: marker)])]
        )
        let adapter = makeAdapter(supervisor: supervisor, cli: cli, recorder: recorder)

        await assertFocusError(.markerCleanupFailed) {
            try await adapter.focusAttachedClient(sessionID: session)
        }

        XCTAssertEqual(supervisor.clearSessionIDs, [session, session, session])
        XCTAssertEqual(recorder.actions, [
            "set:work:\(marker)", "list", "clear:work", "sleep:100ms",
            "clear:work", "sleep:100ms", "clear:work"
        ])
        XCTAssertTrue(cli.activatedPaneIDs.isEmpty)
    }

    func testPendingCleanupMustSucceedBeforeNewMarkerForSameSession() async {
        let recorder = FocusActionRecorder()
        let supervisor = FocusSupervisorFake(
            recorder: recorder,
            clearResults: threeClearFailures + [.success(clearedResult), .success(clearedResult)]
        )
        let cli = FocusCLIFake(
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
        XCTAssertEqual(cli.activatedPaneIDs, [7])
    }

    func testNoForegroundClientDuringPendingCleanupResolvesPendingState() async {
        let recorder = FocusActionRecorder()
        let supervisor = FocusSupervisorFake(
            recorder: recorder,
            setResults: [
                .success(setResult), .success(noForegroundResult), .success(noForegroundResult)
            ],
            clearResults: threeClearFailures + [.success(noForegroundResult)]
        )
        let cli = FocusCLIFake(
            recorder: recorder,
            listResults: [.success([pane(id: 6, title: marker)])]
        )
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
        XCTAssertTrue(cli.activatedPaneIDs.isEmpty)
    }

    func testForgetDropsPendingStateForRemovedSession() async {
        let recorder = FocusActionRecorder()
        let supervisor = FocusSupervisorFake(
            recorder: recorder,
            setResults: [.success(setResult), .success(noForegroundResult)],
            clearResults: threeClearFailures
        )
        let cli = FocusCLIFake(
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
        XCTAssertTrue(cli.activatedPaneIDs.isEmpty)
    }

    func testDifferentSessionCanProceedAfterPriorPendingCleanupFailure() async {
        let recorder = FocusActionRecorder()
        let supervisor = FocusSupervisorFake(
            recorder: recorder,
            clearResults: threeClearFailures + [.success(clearedResult)]
        )
        let cli = FocusCLIFake(
            recorder: recorder,
            listResults: [
                .success([pane(id: 6, title: marker)]),
                .success([pane(id: 77, title: marker)])
            ]
        )
        let adapter = makeAdapter(supervisor: supervisor, cli: cli, recorder: recorder)
        let other = SessionID.named("other")

        await assertFocusError(.markerCleanupFailed) {
            try await adapter.focusAttachedClient(sessionID: session)
        }
        let otherSessionError = await capturedError {
            try await adapter.focusAttachedClient(sessionID: other)
        }

        XCTAssertNil(otherSessionError)
        XCTAssertEqual(recorder.actions, [
            "set:work:\(marker)", "list", "clear:work", "sleep:100ms",
            "clear:work", "sleep:100ms", "clear:work",
            "set:other:\(marker)", "list", "clear:other", "activate:77"
        ])
        XCTAssertEqual(cli.activatedPaneIDs, [77])
    }

    func testOpaqueMarkerContainsNoSessionPaneSocketOrAgentText() async throws {
        let recorder = FocusActionRecorder()
        let supervisor = FocusSupervisorFake(
            recorder: recorder,
            setResults: [.success(noForegroundResult)]
        )
        let cli = FocusCLIFake(recorder: recorder)
        let timing = FocusTimingFake(recorder: recorder)
        let adapter = LiveWezTermFocusAdapter(
            supervisor: supervisor,
            cli: cli,
            timing: timing
        )
        let privateSession = SessionID.named("secret-session")

        _ = await capturedError {
            try await adapter.focusAttachedClient(sessionID: privateSession)
        }

        let generated = try XCTUnwrap(supervisor.setTitles.only)
        XCTAssertTrue(generated.hasPrefix("herdr-menubar-focus:"))
        XCTAssertFalse(generated.contains("secret-session"))
        XCTAssertFalse(generated.contains("pane-77"))
        XCTAssertFalse(generated.contains("/private/socket"))
        XCTAssertFalse(generated.contains("Claude"))
        XCTAssertEqual(recorder.actions, ["set:secret-session:\(generated)"])
        XCTAssertTrue(cli.activatedPaneIDs.isEmpty)
    }

    private func makeAdapter(
        supervisor: FocusSupervisorFake,
        cli: FocusCLIFake,
        timing: FocusTimingFake? = nil,
        recorder: FocusActionRecorder
    ) -> LiveWezTermFocusAdapter {
        LiveWezTermFocusAdapter(
            supervisor: supervisor,
            cli: cli,
            timing: timing ?? FocusTimingFake(recorder: recorder),
            markerGenerator: { "herdr-menubar-focus:test-token" }
        )
    }

    private func pane(id: Int, title: String) -> WezTermPane {
        WezTermPane(windowID: 1, tabID: id, paneID: id, title: title)
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
        _ expected: WezTermFocusError,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let error = await capturedError(operation: operation)
        XCTAssertEqual(error as? WezTermFocusError, expected, file: file, line: line)
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
        let recorder = FocusActionRecorder()
        let clearGate = FocusListGate()
        let supervisor = FocusSupervisorFake(
            recorder: recorder,
            setResults: [.success(setResult), .success(noForegroundResult)],
            clearResults: [clearResult],
            clearGate: clearGate
        )
        let cli = FocusCLIFake(
            recorder: recorder,
            listResults: [.success([pane(id: 63, title: marker)])]
        )
        let timing = FocusTimingFake(recorder: recorder)
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
        XCTAssertTrue(cli.activatedPaneIDs.isEmpty, file: file, line: line)
        let recreatedError = await capturedError {
            try await adapter.focusAttachedClient(sessionID: session)
        }
        XCTAssertEqual(
            recreatedError as? WezTermFocusError,
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
        XCTAssertTrue(cli.activatedPaneIDs.isEmpty, file: file, line: line)
    }

    private func assertForgetInvalidatesSuspendedSet(
        _ setError: any Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let recorder = FocusActionRecorder()
        let setGate = FocusListGate()
        let supervisor = FocusSupervisorFake(
            recorder: recorder,
            setResults: [.failure(setError), .success(noForegroundResult)],
            setGate: setGate
        )
        let cli = FocusCLIFake(recorder: recorder)
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
            recreatedError as? WezTermFocusError,
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
        XCTAssertTrue(cli.activatedPaneIDs.isEmpty, file: file, line: line)
    }
}

@MainActor
private final class FocusActionRecorder {
    private(set) var actions: [String] = []

    func append(_ action: String) {
        actions.append(action)
    }
}

@MainActor
private final class FocusSupervisorFake: SessionSupervising {
    private let recorder: FocusActionRecorder
    private var setResults: [Result<ClientWindowTitleResult, Error>]
    private var clearResults: [Result<ClientWindowTitleResult, Error>]
    private var setGate: FocusListGate?
    private var clearGate: FocusListGate?
    private(set) var setTitles: [String] = []
    private(set) var clearSessionIDs: [SessionID] = []
    private(set) var requestedClearTimeouts: [Duration] = []
    private(set) var clearObservedCancellation: [Bool] = []
    private(set) var clearCompletionCount = 0

    init(
        recorder: FocusActionRecorder,
        setResults: [Result<ClientWindowTitleResult, Error>] = [],
        clearResults: [Result<ClientWindowTitleResult, Error>] = [],
        setGate: FocusListGate? = nil,
        clearGate: FocusListGate? = nil
    ) {
        self.recorder = recorder
        self.setResults = setResults
        self.clearResults = clearResults
        self.setGate = setGate
        self.clearGate = clearGate
    }

    func events() async -> AsyncStream<SessionSupervisorEvent> {
        AsyncStream { $0.finish() }
    }

    func start() async {}
    func stop() async {}
    func retryUnavailable() async {}

    func focus(sessionID: SessionID, paneID: String) async throws -> PaneInfo {
        throw SessionSupervisorError.sessionUnavailable(sessionID.displayName)
    }

    func setClientWindowTitle(
        sessionID: SessionID,
        title: String
    ) async throws -> ClientWindowTitleResult {
        recorder.append("set:\(sessionID.displayName):\(title)")
        setTitles.append(title)
        let gate = setGate
        setGate = nil
        await gate?.wait()
        guard !setResults.isEmpty else {
            return ClientWindowTitleResult(
                type: "client_window_title",
                changed: true,
                reason: "set"
            )
        }
        return try setResults.removeFirst().get()
    }

    func clearClientWindowTitle(
        sessionID: SessionID
    ) async throws -> ClientWindowTitleResult {
        try await clearClientWindowTitle(sessionID: sessionID, timeout: .seconds(5))
    }

    func clearClientWindowTitle(
        sessionID: SessionID,
        timeout: Duration
    ) async throws -> ClientWindowTitleResult {
        recorder.append("clear:\(sessionID.displayName)")
        clearSessionIDs.append(sessionID)
        requestedClearTimeouts.append(timeout)
        let gate = clearGate
        clearGate = nil
        await gate?.wait()
        clearObservedCancellation.append(Task.isCancelled)
        clearCompletionCount += 1
        guard !clearResults.isEmpty else {
            return ClientWindowTitleResult(
                type: "client_window_title",
                changed: true,
                reason: "cleared"
            )
        }
        return try clearResults.removeFirst().get()
    }

    func refresh(sessionID: SessionID) async {}

    func waitForClearCompletion(count: Int) async {
        while clearCompletionCount < count { await Task.yield() }
    }
}

@MainActor
private final class FocusCLIFake: WezTermCLIControlling {
    private let recorder: FocusActionRecorder
    private var listResults: [Result<[WezTermPane], Error>]
    private let defaultPanes: [WezTermPane]
    private var activationResults: [Result<Void, Error>]
    private let listGate: FocusListGate?
    private(set) var activatedPaneIDs: [Int] = []
    private(set) var requestedListTimeouts: [Duration] = []

    init(
        recorder: FocusActionRecorder,
        listResults: [Result<[WezTermPane], Error>] = [],
        defaultPanes: [WezTermPane] = [],
        activationResults: [Result<Void, Error>] = [],
        listGate: FocusListGate? = nil
    ) {
        self.recorder = recorder
        self.listResults = listResults
        self.defaultPanes = defaultPanes
        self.activationResults = activationResults
        self.listGate = listGate
    }

    func listPanes(timeout: Duration) async throws -> [WezTermPane] {
        recorder.append("list")
        requestedListTimeouts.append(timeout)
        await listGate?.wait()
        guard !listResults.isEmpty else { return defaultPanes }
        return try listResults.removeFirst().get()
    }

    func activatePane(id: Int) async throws {
        recorder.append("activate:\(id)")
        activatedPaneIDs.append(id)
        guard !activationResults.isEmpty else { return }
        try activationResults.removeFirst().get()
    }
}

@MainActor
private final class FocusTimingFake: FocusTiming {
    private let recorder: FocusActionRecorder
    private var instant = ContinuousClock().now
    private var blockedSleeps: Set<Duration> = []
    private(set) var recordedSleeps: [Duration] = []

    init(recorder: FocusActionRecorder) {
        self.recorder = recorder
    }

    func now() async -> ContinuousClock.Instant {
        instant
    }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        recordedSleeps.append(duration)
        if duration == .milliseconds(50) {
            recorder.append("sleep:50ms")
        } else if duration == .milliseconds(100) {
            recorder.append("sleep:100ms")
        } else if duration == .milliseconds(500) {
            recorder.append("sleep:500ms")
        } else {
            recorder.append("sleep:\(duration)")
        }
        while blockedSleeps.contains(duration) {
            try Task.checkCancellation()
            await Task.yield()
        }
        instant = instant.advanced(by: duration)
    }

    func advance(by duration: Duration) {
        instant = instant.advanced(by: duration)
    }

    func blockSleep(for duration: Duration) {
        blockedSleeps.insert(duration)
    }

    func unblockSleep(for duration: Duration) {
        blockedSleeps.remove(duration)
    }
}

@MainActor
private final class FocusCompletionProbe {
    private(set) var isFinished = false
    private(set) var error: (any Error)?

    func finish(_ error: (any Error)?) {
        self.error = error
        isFinished = true
    }
}

@MainActor
private final class FocusListGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
