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
        try await resolvePendingCleanupIfNeeded(sessionID: sessionID)
        try Task.checkCancellation()

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

        guard setResult.hasForegroundClient else {
            throw WezTermFocusError.noAttachedClient
        }

        var markerInstalled = true
        do {
            let pane = try await findExactPane(marker: marker)
            try await clearMarkerCancellationIndependently(sessionID: sessionID)
            markerInstalled = false
            try Task.checkCancellation()
            try await cli.activatePane(id: pane.paneID)
        } catch {
            let operationError = error
            if markerInstalled, !pendingCleanup.contains(sessionID) {
                do {
                    try await clearMarkerCancellationIndependently(sessionID: sessionID)
                } catch {
                    throw mapped(error)
                }
            }
            throw mapped(operationError)
        }
    }

    func forget(sessionID: SessionID) {
        pendingCleanup.remove(sessionID)
    }

    private func findExactPane(marker: String) async throws -> WezTermPane {
        let startedAt = await timing.now()
        let deadline = startedAt.advanced(by: .seconds(1))

        while true {
            try Task.checkCancellation()
            let panes = try await cli.listPanes()
            try Task.checkCancellation()

            let matches = panes.filter { $0.title == marker }
            if matches.count > 1 {
                throw WezTermFocusError.ambiguousMarker
            }
            if let match = matches.first {
                return match
            }

            let current = await timing.now()
            guard current < deadline else {
                throw WezTermFocusError.lookupTimedOut
            }
            let remaining = current.duration(to: deadline)
            try await timing.sleep(for: min(.milliseconds(50), remaining))
        }
    }

    private func resolvePendingCleanupIfNeeded(sessionID: SessionID) async throws {
        guard pendingCleanup.contains(sessionID) else { return }
        try await clearMarkerCancellationIndependently(sessionID: sessionID)
    }

    private func clearMarkerCancellationIndependently(
        sessionID: SessionID
    ) async throws {
        let task = Task { @MainActor [self] in
            try await clearMarkerWithRetries(sessionID: sessionID)
        }
        try await task.value
    }

    private func clearMarkerWithRetries(sessionID: SessionID) async throws {
        let startedAt = await timing.now()
        let deadline = startedAt.advanced(by: .milliseconds(500))

        for attempt in 1...3 {
            do {
                let result = try await supervisor.clearClientWindowTitle(sessionID: sessionID)
                if result.reason == "cleared" || result.reason == "no_foreground_client" {
                    pendingCleanup.remove(sessionID)
                    return
                }
            } catch {
                // Retry boundedly; the public result deliberately does not expose transport detail.
            }

            guard attempt < 3 else { break }
            let current = await timing.now()
            guard current < deadline else { break }
            let remaining = current.duration(to: deadline)
            try? await timing.sleep(for: min(.milliseconds(100), remaining))
        }

        pendingCleanup.insert(sessionID)
        throw WezTermFocusError.markerCleanupFailed
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
