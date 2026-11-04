import Foundation

/// Herdr pane routing stays session-qualified; this boundary focuses its host terminal.
@MainActor
protocol GhosttySessionFocusing: Sendable {
    func focusAttachedClient(sessionID: SessionID) async throws
    func forget(sessionID: SessionID)
}

@MainActor
final class LiveGhosttyFocusAdapter: GhosttySessionFocusing {
    private let supervisor: any SessionSupervising
    private let control: any GhosttyControlling
    private let timing: any FocusTiming
    private let markerGenerator: @Sendable () -> String
    private var pendingCleanup: Set<SessionID> = []
    private var sessionLifecycles: [SessionID: GhosttyFocusSessionLifecycle] = [:]

    init(
        supervisor: any SessionSupervising,
        control: any GhosttyControlling,
        timing: any FocusTiming = LiveFocusTiming(),
        markerGenerator: @escaping @Sendable () -> String = {
            "herdr-menubar-focus:\(UUID().uuidString)"
        }
    ) {
        self.supervisor = supervisor
        self.control = control
        self.timing = timing
        self.markerGenerator = markerGenerator
    }

    func focusAttachedClient(sessionID: SessionID) async throws {
        let lifecycle = lifecycle(for: sessionID)
        if pendingCleanup.contains(sessionID) {
            try await clearMarkerCancellationIndependently(sessionID: sessionID, lifecycle: lifecycle)
        }
        let process: GhosttyProcessIdentity
        do {
            process = try await control.prepareForFocus()
        } catch {
            try ensureCurrent(sessionID: sessionID, lifecycle: lifecycle)
            throw error
        }
        try Task.checkCancellation()
        try ensureCurrent(sessionID: sessionID, lifecycle: lifecycle)
        let marker = markerGenerator()
        let setResult: ClientWindowTitleResult
        do {
            setResult = try await supervisor.setClientWindowTitle(sessionID: sessionID, title: marker)
        } catch let error as HerdrAPIError where error.code == "method_not_found" {
            try ensureCurrent(sessionID: sessionID, lifecycle: lifecycle)
            throw GhosttyFocusError.unsupportedHerdr
        } catch {
            try ensureCurrent(sessionID: sessionID, lifecycle: lifecycle)
            throw error
        }
        try ensureCurrent(sessionID: sessionID, lifecycle: lifecycle)
        guard setResult.hasForegroundClient else { throw GhosttyFocusError.noAttachedClient }
        var cleanupAttempted = false
        do {
            let terminal = try await findExactTerminal(
                marker: marker, process: process, sessionID: sessionID, lifecycle: lifecycle
            )
            try ensureCurrent(sessionID: sessionID, lifecycle: lifecycle)
            cleanupAttempted = true
            try await clearMarkerCancellationIndependently(sessionID: sessionID, lifecycle: lifecycle)
            try Task.checkCancellation()
            try ensureCurrent(sessionID: sessionID, lifecycle: lifecycle)
            try await control.focusTerminal(id: terminal.id, process: process)
        } catch {
            try ensureCurrent(sessionID: sessionID, lifecycle: lifecycle)
            if !cleanupAttempted {
                try await clearMarkerCancellationIndependently(sessionID: sessionID, lifecycle: lifecycle)
            }
            throw error
        }
    }

    private func findExactTerminal(
        marker: String,
        process: GhosttyProcessIdentity,
        sessionID: SessionID,
        lifecycle: GhosttyFocusSessionLifecycle
    ) async throws -> GhosttyTerminal {
        let startedAt = await timing.now()
        let deadline = startedAt.advanced(by: .seconds(1))
        while true {
            let beforeList = await timing.now()
            try ensureCurrent(sessionID: sessionID, lifecycle: lifecycle)
            guard beforeList < deadline else { throw GhosttyFocusError.lookupTimedOut }
            let remaining = beforeList.duration(to: deadline)
            let snapshot = try await control.listTerminals(
                process: process, timeout: min(.milliseconds(500), remaining)
            )
            try Task.checkCancellation()
            try ensureCurrent(sessionID: sessionID, lifecycle: lifecycle)
            guard snapshot.process == process else { throw GhosttyFocusError.targetGone }
            let afterList = await timing.now()
            guard afterList < deadline else { throw GhosttyFocusError.lookupTimedOut }
            let matches = snapshot.terminals.filter { $0.title == marker }
            if matches.count == 1, let terminal = matches.first { return terminal }
            guard matches.isEmpty else { throw GhosttyFocusError.ambiguousMarker }
            let beforeSleep = await timing.now()
            guard beforeSleep < deadline else { throw GhosttyFocusError.lookupTimedOut }
            try await timing.sleep(for: min(.milliseconds(50), beforeSleep.duration(to: deadline)))
        }
    }

    private func clearMarkerCancellationIndependently(
        sessionID: SessionID, lifecycle: GhosttyFocusSessionLifecycle
    ) async throws {
        let cleanup = Task { @MainActor [self] in
            try await clearMarkerWithRetries(sessionID: sessionID, lifecycle: lifecycle)
        }
        try await cleanup.value
    }

    private func clearMarkerWithRetries(
        sessionID: SessionID, lifecycle: GhosttyFocusSessionLifecycle
    ) async throws {
        let startedAt = await timing.now()
        try ensureCurrent(sessionID: sessionID, lifecycle: lifecycle)
        let deadline = startedAt.advanced(by: .milliseconds(500))
        for attempt in 1...3 {
            let beforeAttempt = await timing.now()
            try ensureCurrent(sessionID: sessionID, lifecycle: lifecycle)
            guard beforeAttempt < deadline else { break }
            do {
                let result = try await boundedClear(
                    sessionID: sessionID, timeout: beforeAttempt.duration(to: deadline)
                )
                try ensureCurrent(sessionID: sessionID, lifecycle: lifecycle)
                if result.reason == "cleared" || result.reason == "no_foreground_client" {
                    pendingCleanup.remove(sessionID)
                    return
                }
            } catch {
                // Retry transport failures only while the session lifecycle is still current.
            }
            try ensureCurrent(sessionID: sessionID, lifecycle: lifecycle)
            guard attempt < 3 else { break }
            let beforeSleep = await timing.now()
            try ensureCurrent(sessionID: sessionID, lifecycle: lifecycle)
            guard beforeSleep < deadline else { break }
            try? await timing.sleep(for: min(.milliseconds(100), beforeSleep.duration(to: deadline)))
            try ensureCurrent(sessionID: sessionID, lifecycle: lifecycle)
        }
        try ensureCurrent(sessionID: sessionID, lifecycle: lifecycle)
        pendingCleanup.insert(sessionID)
        throw GhosttyFocusError.markerCleanupFailed
    }

    private func boundedClear(sessionID: SessionID, timeout: Duration) async throws -> ClientWindowTitleResult {
        let operation = GhosttyFocusBoundedOperation<ClientWindowTitleResult>()
        operation.start(timeout: timeout, timing: timing) { [supervisor] in
            try await supervisor.clearClientWindowTitle(sessionID: sessionID, timeout: timeout)
        }
        switch await operation.value() {
        case .success(let result): return result
        case .failure(let error): throw error
        case .timedOut: throw GhosttyFocusError.markerCleanupFailed
        }
    }

    private func lifecycle(for sessionID: SessionID) -> GhosttyFocusSessionLifecycle {
        if let lifecycle = sessionLifecycles[sessionID] { return lifecycle }
        let lifecycle = GhosttyFocusSessionLifecycle()
        sessionLifecycles[sessionID] = lifecycle
        return lifecycle
    }

    private func ensureCurrent(sessionID: SessionID, lifecycle: GhosttyFocusSessionLifecycle) throws {
        guard sessionLifecycles[sessionID] === lifecycle else { throw CancellationError() }
    }

    func forget(sessionID: SessionID) {
        sessionLifecycles.removeValue(forKey: sessionID)
        pendingCleanup.remove(sessionID)
    }
}

private final class GhosttyFocusSessionLifecycle {}

/// First completion wins; a suspended, cancelled RPC cannot overwrite the deadline outcome.
@MainActor
private final class GhosttyFocusBoundedOperation<Value: Sendable> {
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
                    // The RPC won; its result cancelled this deadline task.
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
