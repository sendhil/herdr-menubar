import Foundation

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
