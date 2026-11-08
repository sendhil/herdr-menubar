import Foundation

/// Owns one notification-response registration.
///
/// Every consumer must call `cancel()` from `defer`. A consumer whose startup
/// aborts after acquiring a subscription must cancel it before dropping it.
struct NotificationResponseSubscription: AsyncSequence, Sendable {
    typealias Element = SelectionTarget
    typealias AsyncIterator = AsyncStream<Element>.Iterator

    private let stream: AsyncStream<Element>
    let cancellation: NotificationResponseCancellation

    init(
        stream: AsyncStream<Element>,
        cancellation: NotificationResponseCancellation
    ) {
        self.stream = stream
        self.cancellation = cancellation
    }

    func makeAsyncIterator() -> AsyncIterator {
        stream.makeAsyncIterator()
    }

    func cancel() {
        cancellation.cancel()
    }

    static func finished() -> NotificationResponseSubscription {
        NotificationResponseSubscription(
            stream: AsyncStream { continuation in continuation.finish() },
            cancellation: NotificationResponseCancellation(onCancel: {})
        )
    }
}

final class NotificationResponseCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var onCancel: (@Sendable () -> Void)?

    init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { onCancel = nil }
            return onCancel
        }
        action?()
    }

    func withActive<Result>(_ action: () -> Result) -> Result? {
        lock.withLock {
            guard onCancel != nil else { return nil }
            return action()
        }
    }
}

struct AttentionNotificationEvent: Equatable, Sendable {
    let target: SelectionTarget
    let sessionName: String
    let visibleLabel: String
    let status: AttentionState
}

enum NotificationDeliveryResult: Equatable, Sendable {
    case accepted
    case suppressed
}

protocol LatestNotificationTargetRecording: Sendable {
    func record(_ target: SelectionTarget, ordinal: UInt64) async
    func latest() async -> SelectionTarget?
    func reset() async
    func sealAndReset() async
}

struct NotificationDeliveryPolicy: Equatable, Sendable {
    static let defaultNotifyStates: [BackendKind: Set<AttentionState>] = Dictionary(
        uniqueKeysWithValues: BackendKind.allCases.map { ($0, $0.defaultNotifyStates) }
    )

    let notificationsEnabled: Bool
    let soundEnabled: Bool
    let notifyStates: [BackendKind: Set<AttentionState>]

    init(
        notificationsEnabled: Bool,
        soundEnabled: Bool,
        notifyStates: [BackendKind: Set<AttentionState>] = NotificationDeliveryPolicy.defaultNotifyStates
    ) {
        self.notificationsEnabled = notificationsEnabled
        self.soundEnabled = soundEnabled
        self.notifyStates = notifyStates
    }
}

enum NotificationAuthorization: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
}

struct NotificationSystemSettings: Equatable, Sendable {
    let authorization: NotificationAuthorization
    let alertsEnabled: Bool
    let soundsEnabled: Bool

    static let notDetermined = NotificationSystemSettings(
        authorization: .notDetermined,
        alertsEnabled: false,
        soundsEnabled: false
    )
    static let authorized = NotificationSystemSettings(
        authorization: .authorized,
        alertsEnabled: true,
        soundsEnabled: true
    )
    static let denied = NotificationSystemSettings(
        authorization: .denied,
        alertsEnabled: false,
        soundsEnabled: false
    )
}

protocol NativeNotificationServing: Sendable {
    func responses() async -> NotificationResponseSubscription
    func requestAuthorization() async throws -> Bool
    func settings() async -> NotificationSystemSettings
    func deliver(
        _ event: AttentionNotificationEvent,
        sound: Bool
    ) async throws -> NotificationDeliveryResult
}

protocol AttentionNotificationCoordinating: Sendable {
    func reconcile(
        session: AgentSessionDescriptor,
        records: [AttentionRecord],
        policy: NotificationDeliveryPolicy
    ) async
    func unavailable(session: AgentSessionKey) async
    func remove(session: AgentSessionKey) async
    func reset() async
}
