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
        for iteration in 0...20 {
            expected.append("list")
            if iteration < 20 { expected.append("sleep:50ms") }
        }
        expected.append("clear:work")
        XCTAssertEqual(recorder.actions, expected)
        XCTAssertEqual(timing.recordedSleeps, Array(repeating: .milliseconds(50), count: 20))
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
    private(set) var setTitles: [String] = []
    private(set) var clearSessionIDs: [SessionID] = []

    init(
        recorder: FocusActionRecorder,
        setResults: [Result<ClientWindowTitleResult, Error>] = [],
        clearResults: [Result<ClientWindowTitleResult, Error>] = []
    ) {
        self.recorder = recorder
        self.setResults = setResults
        self.clearResults = clearResults
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
        recorder.append("clear:\(sessionID.displayName)")
        clearSessionIDs.append(sessionID)
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
}

@MainActor
private final class FocusCLIFake: WezTermCLIControlling {
    private let recorder: FocusActionRecorder
    private var listResults: [Result<[WezTermPane], Error>]
    private let defaultPanes: [WezTermPane]
    private var activationResults: [Result<Void, Error>]
    private let listGate: FocusListGate?
    private(set) var activatedPaneIDs: [Int] = []

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

    func listPanes() async throws -> [WezTermPane] {
        recorder.append("list")
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
        } else {
            recorder.append("sleep:\(duration)")
        }
        instant = instant.advanced(by: duration)
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
