import Foundation
import UserNotifications

protocol UserNotificationCenterBacking: Sendable {
    func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?)
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func settings() async -> NotificationSystemSettings
    func add(_ request: UNNotificationRequest) async throws
}

final class LiveUserNotificationCenterBackend: UserNotificationCenterBacking, @unchecked Sendable {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?) {
        center.delegate = delegate
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await center.requestAuthorization(options: options)
    }

    func settings() async -> NotificationSystemSettings {
        let settings = await center.notificationSettings()
        return Self.mapSettings(
            authorizationStatus: settings.authorizationStatus,
            alertSetting: settings.alertSetting,
            soundSetting: settings.soundSetting
        )
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await center.add(request)
    }

    static func mapSettings(
        authorizationStatus: UNAuthorizationStatus,
        alertSetting: UNNotificationSetting,
        soundSetting: UNNotificationSetting
    ) -> NotificationSystemSettings {
        let authorization: NotificationAuthorization
        switch authorizationStatus {
        case .notDetermined:
            authorization = .notDetermined
        case .authorized, .provisional, .ephemeral:
            authorization = .authorized
        case .denied:
            authorization = .denied
        @unknown default:
            authorization = .denied
        }
        return NotificationSystemSettings(
            authorization: authorization,
            alertsEnabled: alertSetting == .enabled,
            soundsEnabled: soundSetting == .enabled
        )
    }
}

final class NativeNotificationService: NSObject, NativeNotificationServing,
    UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let foregroundPresentationOptions: UNNotificationPresentationOptions = [.list]

    private static let payloadVersion = 1
    private static let responseBufferLimit = 8

    private let backend: any UserNotificationCenterBacking
    private let responseStream: AsyncStream<NotificationSelectionTarget>
    private let responseContinuation: AsyncStream<NotificationSelectionTarget>.Continuation

    init(backend: any UserNotificationCenterBacking = LiveUserNotificationCenterBackend()) {
        self.backend = backend
        (responseStream, responseContinuation) = AsyncStream.makeStream(
            bufferingPolicy: .bufferingNewest(Self.responseBufferLimit)
        )
        super.init()
        backend.setDelegate(self)
    }

    deinit {
        responseContinuation.finish()
    }

    func responses() async -> AsyncStream<NotificationSelectionTarget> {
        responseStream
    }

    func requestAuthorization() async throws -> Bool {
        try await backend.requestAuthorization(options: [.alert, .sound])
    }

    func settings() async -> NotificationSystemSettings {
        await backend.settings()
    }

    func deliver(_ event: AttentionNotificationEvent, sound: Bool) async throws {
        let settings = await backend.settings()
        guard settings.authorization == .authorized, settings.alertsEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = event.status == .blocked ? "Agent blocked" : "Agent finished"
        content.body = "\(event.visibleLabel) — \(event.sessionName)"
        if sound && settings.soundsEnabled {
            content.sound = .default
        }
        content.userInfo = Self.payload(for: event.target)

        try await backend.add(
            UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
        )
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        Self.foregroundPresentationOptions
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        handleResponse(
            actionIdentifier: response.actionIdentifier,
            userInfo: response.notification.request.content.userInfo
        )
    }

    func handleResponse(actionIdentifier: String, userInfo: [AnyHashable: Any]) {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier,
              let target = Self.decodeTarget(userInfo) else { return }
        responseContinuation.yield(target)
    }

    static func payload(for target: NotificationSelectionTarget) -> [AnyHashable: Any] {
        var payload: [AnyHashable: Any] = [
            "version": payloadVersion,
            "pane_id": target.paneID
        ]
        switch target.sessionID {
        case .default:
            payload["session_kind"] = "default"
        case .named(let name):
            payload["session_kind"] = "named"
            payload["session_name"] = name
        }
        return payload
    }

    static func decodeTarget(_ userInfo: [AnyHashable: Any]) -> NotificationSelectionTarget? {
        guard userInfo["version"] as? Int == payloadVersion,
              let sessionKind = userInfo["session_kind"] as? String,
              let paneID = userInfo["pane_id"] as? String,
              !paneID.isEmpty else { return nil }

        let sessionID: SessionID
        switch sessionKind {
        case "default":
            sessionID = .default
        case "named":
            guard let sessionName = userInfo["session_name"] as? String,
                  !sessionName.isEmpty else { return nil }
            sessionID = .named(sessionName)
        default:
            return nil
        }
        return NotificationSelectionTarget(sessionID: sessionID, paneID: paneID)
    }
}
