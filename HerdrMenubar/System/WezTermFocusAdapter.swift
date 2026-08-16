import Foundation

@MainActor
protocol WezTermSessionFocusing: Sendable {
    func focusAttachedClient(sessionID: SessionID) async throws
    func forget(sessionID: SessionID)
}

enum WezTermFocusError: Error, Equatable, Sendable {
    case noAttachedClient
    case unsupportedHerdr
    case wezTermUnavailable
    case wezTermControlFailed
    case lookupTimedOut
    case ambiguousMarker
    case markerCleanupFailed
}

protocol FocusTiming: Sendable {
    func now() async -> ContinuousClock.Instant
    func sleep(for duration: Duration) async throws
}

struct LiveFocusTiming: FocusTiming {
    func now() async -> ContinuousClock.Instant {
        ContinuousClock().now
    }

    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

@MainActor
final class LiveWezTermFocusAdapter: WezTermSessionFocusing {
    private let supervisor: any SessionSupervising
    private let cli: any WezTermCLIControlling
    private let timing: any FocusTiming
    private let markerGenerator: @Sendable () -> String
    private var pendingCleanup: Set<SessionID> = []
    private var sessionEpochs: [SessionID: UInt64] = [:]

    init(
        supervisor: any SessionSupervising,
        cli: any WezTermCLIControlling,
        timing: any FocusTiming = LiveFocusTiming(),
        markerGenerator: @escaping @Sendable () -> String = {
            "herdr-menubar-focus:\(UUID().uuidString)"
        }
    ) {
        self.supervisor = supervisor
        self.cli = cli
        self.timing = timing
        self.markerGenerator = markerGenerator
    }

    func focusAttachedClient(sessionID: SessionID) async throws {
        let epoch = sessionEpoch(for: sessionID)
        try await resolvePendingCleanupIfNeeded(sessionID: sessionID, epoch: epoch)
        try Task.checkCancellation()
        try ensureCurrent(sessionID: sessionID, epoch: epoch)

        let marker = markerGenerator()
        let setResult: ClientWindowTitleResult
        do {
            setResult = try await supervisor.setClientWindowTitle(
                sessionID: sessionID,
                title: marker
            )
        } catch let error as HerdrAPIError where error.code == "method_not_found" {
            throw WezTermFocusError.unsupportedHerdr
        } catch {
            throw mapped(error)
        }
        try ensureCurrent(sessionID: sessionID, epoch: epoch)

        guard setResult.hasForegroundClient else {
            throw WezTermFocusError.noAttachedClient
        }

        var markerInstalled = true
        do {
            let pane = try await findExactPane(marker: marker)
            try ensureCurrent(sessionID: sessionID, epoch: epoch)
            try await clearMarkerCancellationIndependently(
                sessionID: sessionID,
                epoch: epoch
            )
            markerInstalled = false
            try Task.checkCancellation()
            try ensureCurrent(sessionID: sessionID, epoch: epoch)
            try await cli.activatePane(id: pane.paneID)
        } catch {
            let operationError = error
            guard isCurrent(sessionID: sessionID, epoch: epoch) else {
                throw CancellationError()
            }
            if markerInstalled, !pendingCleanup.contains(sessionID) {
                do {
                    try await clearMarkerCancellationIndependently(
                        sessionID: sessionID,
                        epoch: epoch
                    )
                } catch {
                    throw mapped(error)
                }
            }
            throw mapped(operationError)
        }
    }

    func forget(sessionID: SessionID) {
        sessionEpochs[sessionID] = sessionEpoch(for: sessionID) &+ 1
        pendingCleanup.remove(sessionID)
    }

    private func findExactPane(marker: String) async throws -> WezTermPane {
        let startedAt = await timing.now()
        let deadline = startedAt.advanced(by: .seconds(1))

        while true {
            try Task.checkCancellation()
            let beforeList = await timing.now()
            guard beforeList < deadline else {
                throw WezTermFocusError.lookupTimedOut
            }
            let remaining = beforeList.duration(to: deadline)
            let panes: [WezTermPane]
            do {
                panes = try await cli.listPanes(
                    timeout: min(.milliseconds(500), remaining)
                )
            } catch {
                let afterFailure = await timing.now()
                if afterFailure >= deadline {
                    throw WezTermFocusError.lookupTimedOut
                }
                throw error
            }
            try Task.checkCancellation()
            let afterList = await timing.now()
            guard afterList < deadline else {
                throw WezTermFocusError.lookupTimedOut
            }

            let matches = panes.filter { $0.title == marker }
            if matches.count > 1 {
                throw WezTermFocusError.ambiguousMarker
            }
            if let match = matches.first {
                return match
            }

            let sleepBudget = afterList.duration(to: deadline)
            try await timing.sleep(for: min(.milliseconds(50), sleepBudget))
        }
    }

    private func resolvePendingCleanupIfNeeded(
        sessionID: SessionID,
        epoch: UInt64
    ) async throws {
        guard pendingCleanup.contains(sessionID) else { return }
        try await clearMarkerCancellationIndependently(sessionID: sessionID, epoch: epoch)
    }

    private func clearMarkerCancellationIndependently(
        sessionID: SessionID,
        epoch: UInt64
    ) async throws {
        let task = Task { @MainActor [self] in
            try await clearMarkerWithRetries(sessionID: sessionID, epoch: epoch)
        }
        try await task.value
    }

    private func clearMarkerWithRetries(
        sessionID: SessionID,
        epoch: UInt64
    ) async throws {
        let startedAt = await timing.now()
        try ensureCurrent(sessionID: sessionID, epoch: epoch)
        let deadline = startedAt.advanced(by: .milliseconds(500))

        for attempt in 1...3 {
            let beforeAttempt = await timing.now()
            try ensureCurrent(sessionID: sessionID, epoch: epoch)
            guard beforeAttempt < deadline else { break }
            let attemptBudget = beforeAttempt.duration(to: deadline)
            do {
                let result = try await boundedClear(
                    sessionID: sessionID,
                    timeout: attemptBudget
                )
                try ensureCurrent(sessionID: sessionID, epoch: epoch)
                if result.reason == "cleared" || result.reason == "no_foreground_client" {
                    pendingCleanup.remove(sessionID)
                    return
                }
            } catch {
                // Retry boundedly; the public result deliberately does not expose transport detail.
            }
            try ensureCurrent(sessionID: sessionID, epoch: epoch)

            guard attempt < 3 else { break }
            let current = await timing.now()
            try ensureCurrent(sessionID: sessionID, epoch: epoch)
            guard current < deadline else { break }
            let remaining = current.duration(to: deadline)
            try? await timing.sleep(for: min(.milliseconds(100), remaining))
            try ensureCurrent(sessionID: sessionID, epoch: epoch)
        }

        try ensureCurrent(sessionID: sessionID, epoch: epoch)
        pendingCleanup.insert(sessionID)
        throw WezTermFocusError.markerCleanupFailed
    }

    private func boundedClear(
        sessionID: SessionID,
        timeout: Duration
    ) async throws -> ClientWindowTitleResult {
        let operation = FocusBoundedOperation<ClientWindowTitleResult>()
        operation.start(timeout: timeout, timing: timing) { [supervisor] in
            try await supervisor.clearClientWindowTitle(
                sessionID: sessionID,
                timeout: timeout
            )
        }
        switch await operation.value() {
        case .success(let result): return result
        case .failure(let error): throw error
        case .timedOut: throw FocusAttemptError.timedOut
        }
    }

    private func sessionEpoch(for sessionID: SessionID) -> UInt64 {
        sessionEpochs[sessionID] ?? 0
    }

    private func isCurrent(sessionID: SessionID, epoch: UInt64) -> Bool {
        sessionEpoch(for: sessionID) == epoch
    }

    private func ensureCurrent(sessionID: SessionID, epoch: UInt64) throws {
        guard isCurrent(sessionID: sessionID, epoch: epoch) else {
            throw CancellationError()
        }
    }

    private func mapped(_ error: any Error) -> any Error {
        if let error = error as? WezTermFocusError {
            return error
        }
        if error is CancellationError {
            return CancellationError()
        }
        if let error = error as? WezTermCLIError {
            switch error {
            case .unavailable:
                return WezTermFocusError.wezTermUnavailable
            case .controlFailed, .malformedOutput:
                return WezTermFocusError.wezTermControlFailed
            }
        }
        return WezTermFocusError.wezTermControlFailed
    }
}

private enum FocusAttemptError: Error {
    case timedOut
}

@MainActor
private final class FocusBoundedOperation<Value: Sendable> {
    enum Outcome {
        case success(Value)
        case failure(any Error)
        case timedOut
    }

    private var outcome: Outcome?
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func start(
        timeout: Duration,
        timing: any FocusTiming,
        operation: @escaping @MainActor @Sendable () async throws -> Value
    ) {
        precondition(operationTask == nil && outcome == nil)
        operationTask = Task { @MainActor [self] in
            timeoutTask = Task { @MainActor [self] in
                do {
                    try await timing.sleep(for: max(.zero, timeout))
                    try Task.checkCancellation()
                    complete(.timedOut, winner: .timeout)
                } catch {
                    // The operation won or the owning focus operation was invalidated.
                }
            }

            do {
                complete(.success(try await operation()), winner: .operation)
            } catch {
                complete(.failure(error), winner: .operation)
            }
        }
    }

    func value() async -> Outcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation in
            if let outcome {
                continuation.resume(returning: outcome)
            } else {
                self.continuation = continuation
            }
        }
    }

    private enum Winner {
        case operation
        case timeout
    }

    private func complete(_ outcome: Outcome, winner: Winner) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        let continuation = continuation
        self.continuation = nil
        let operationTask = operationTask
        let timeoutTask = timeoutTask
        self.operationTask = nil
        self.timeoutTask = nil

        switch winner {
        case .operation: timeoutTask?.cancel()
        case .timeout: operationTask?.cancel()
        }
        continuation?.resume(returning: outcome)
    }
}
