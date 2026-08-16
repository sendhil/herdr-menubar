import Foundation

struct NotificationSelectionTarget: Equatable, Sendable {
    let sessionID: SessionID
    let paneID: String
}

struct AttentionNotificationEvent: Equatable, Sendable {
    let target: NotificationSelectionTarget
    let sessionName: String
    let visibleLabel: String
    let status: AgentStatus
}

struct NotificationDeliveryPolicy: Equatable, Sendable {
    let notificationsEnabled: Bool
    let soundEnabled: Bool
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
    func responses() async -> AsyncStream<NotificationSelectionTarget>
    func requestAuthorization() async throws -> Bool
    func settings() async -> NotificationSystemSettings
    func deliver(_ event: AttentionNotificationEvent, sound: Bool) async throws
}

protocol AttentionNotificationCoordinating: Sendable {
    func reconcile(
        session: SessionDescriptor,
        items: [AgentMenuItem],
        policy: NotificationDeliveryPolicy
    ) async
    func unavailable(sessionID: SessionID) async
    func remove(sessionID: SessionID) async
    func reset() async
}
