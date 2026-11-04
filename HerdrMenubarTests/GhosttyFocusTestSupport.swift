import Foundation
@testable import HerdrMenubar

@MainActor
final class GhosttyFocusActionRecorder {
    private(set) var actions: [String] = []

    func append(_ action: String) {
        actions.append(action)
    }
}

@MainActor
final class GhosttyFocusSupervisorFake: SessionSupervising {
    private let recorder: GhosttyFocusActionRecorder
    private var setResults: [Result<ClientWindowTitleResult, Error>]
    private var clearResults: [Result<ClientWindowTitleResult, Error>]
    private var setGate: GhosttyFocusListGate?
    private var clearGate: GhosttyFocusListGate?
    private(set) var setTitles: [String] = []
    private(set) var clearSessionIDs: [SessionID] = []
    private(set) var requestedClearTimeouts: [Duration] = []
    private(set) var clearObservedCancellation: [Bool] = []
    private(set) var clearCompletionCount = 0

    init(
        recorder: GhosttyFocusActionRecorder,
        setResults: [Result<ClientWindowTitleResult, Error>] = [],
        clearResults: [Result<ClientWindowTitleResult, Error>] = [],
        setGate: GhosttyFocusListGate? = nil,
        clearGate: GhosttyFocusListGate? = nil
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
final class FocusGhosttyControlFake: GhosttyControlling {
    private let recorder: GhosttyFocusActionRecorder
    private var listResults: [Result<[GhosttyTerminal], Error>]
    private let defaultPanes: [GhosttyTerminal]
    private var activationResults: [Result<Void, Error>]
    private var prepareResults: [Result<GhosttyProcessIdentity, Error>]
    private var listGate: GhosttyFocusListGate?
    private var prepareGate: GhosttyFocusListGate?
    private let snapshotProcess: GhosttyProcessIdentity?
    private(set) var focusedTerminalIDs: [String] = []
    private(set) var requestedListTimeouts: [Duration] = []

    init(
        recorder: GhosttyFocusActionRecorder,
        listResults: [Result<[GhosttyTerminal], Error>] = [],
        defaultPanes: [GhosttyTerminal] = [],
        activationResults: [Result<Void, Error>] = [],
        listGate: GhosttyFocusListGate? = nil,
        prepareGate: GhosttyFocusListGate? = nil,
        snapshotProcess: GhosttyProcessIdentity? = nil,
        prepareResults: [Result<GhosttyProcessIdentity, Error>] = []
    ) {
        self.recorder = recorder
        self.listResults = listResults
        self.defaultPanes = defaultPanes
        self.activationResults = activationResults
        self.listGate = listGate
        self.prepareGate = prepareGate
        self.snapshotProcess = snapshotProcess
        self.prepareResults = prepareResults
    }

    func prepareForFocus() async throws -> GhosttyProcessIdentity {
        let gate = prepareGate
        prepareGate = nil
        await gate?.wait()
        guard !prepareResults.isEmpty else {
            return GhosttyProcessIdentity(pid: 451, launchDate: Date(timeIntervalSince1970: 100))
        }
        return try prepareResults.removeFirst().get()
    }

    func listTerminals(process: GhosttyProcessIdentity, timeout: Duration) async throws -> GhosttyTerminalSnapshot {
        recorder.append("list")
        requestedListTimeouts.append(timeout)
        let gate = listGate
        listGate = nil
        await gate?.wait()
        let terminals = try listResults.isEmpty ? defaultPanes : listResults.removeFirst().get()
        return GhosttyTerminalSnapshot(process: snapshotProcess ?? process, terminals: terminals)
    }

    func focusTerminal(id: String, process: GhosttyProcessIdentity) async throws {
        recorder.append("activate:\(id)")
        focusedTerminalIDs.append(id)
        guard !activationResults.isEmpty else { return }
        try activationResults.removeFirst().get()
    }
}

@MainActor
final class GhosttyFocusTimingFake: FocusTiming {
    private let recorder: GhosttyFocusActionRecorder
    private var instant = ContinuousClock().now
    private var blockedSleeps: Set<Duration> = []
    private(set) var recordedSleeps: [Duration] = []

    init(recorder: GhosttyFocusActionRecorder) {
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
final class GhosttyFocusCompletionProbe {
    private(set) var isFinished = false
    private(set) var error: (any Error)?

    func finish(_ error: (any Error)?) {
        self.error = error
        isFinished = true
    }
}

@MainActor
final class GhosttyFocusListGate {
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
