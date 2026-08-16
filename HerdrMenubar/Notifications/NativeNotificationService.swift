import CoreFoundation
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

    private let backend: any UserNotificationCenterBacking
    private let responseBroker: NotificationResponseBroker

    init(backend: any UserNotificationCenterBacking = LiveUserNotificationCenterBackend()) {
        self.backend = backend
        responseBroker = NotificationResponseBroker(preSubscriptionBufferLimit: 8)
        super.init()
        backend.setDelegate(self)
    }

    deinit {
        responseBroker.finish()
    }

    func responses() async -> AsyncStream<NotificationSelectionTarget> {
        responseBroker.stream()
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
        responseBroker.yield(target)
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
        guard isSupportedPayloadVersion(userInfo["version"]),
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

    private static func isSupportedPayloadVersion(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number) else { return false }
        return number.intValue == payloadVersion
    }
}

private final class NotificationResponseBroker: @unchecked Sendable {
    typealias Target = NotificationSelectionTarget
    typealias Continuation = AsyncStream<Target>.Continuation

    private enum Action {
        case yield(UUID, Continuation, Target)
        case finish(Continuation)
    }

    private let lock = NSLock()
    private let preSubscriptionBufferLimit: Int
    private var subscribers: [UUID: Continuation] = [:]
    private var pendingTargets: [Target] = []
    private var actions: [Action] = []
    private var isDraining = false
    private var isFinished = false

    init(preSubscriptionBufferLimit: Int) {
        self.preSubscriptionBufferLimit = preSubscriptionBufferLimit
    }

    func stream() -> AsyncStream<Target> {
        let subscriptionID = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: Target.self,
            bufferingPolicy: .unbounded
        )
        continuation.onTermination = { [weak self] _ in
            self?.removeSubscriber(subscriptionID)
        }

        let shouldDrain = lock.withLock {
            if isFinished {
                actions.append(.finish(continuation))
            } else {
                let isFirstSubscriber = subscribers.isEmpty
                subscribers[subscriptionID] = continuation
                if isFirstSubscriber {
                    for target in pendingTargets {
                        actions.append(.yield(subscriptionID, continuation, target))
                    }
                    pendingTargets.removeAll(keepingCapacity: true)
                }
            }
            return claimDrainerIfNeeded()
        }
        if shouldDrain {
            drainActions()
        }
        return stream
    }

    func yield(_ target: Target) {
        let shouldDrain = lock.withLock {
            guard !isFinished else { return false }
            guard !subscribers.isEmpty else {
                pendingTargets.append(target)
                if pendingTargets.count > preSubscriptionBufferLimit {
                    pendingTargets.removeFirst(pendingTargets.count - preSubscriptionBufferLimit)
                }
                return false
            }
            for (subscriptionID, continuation) in subscribers {
                actions.append(.yield(subscriptionID, continuation, target))
            }
            return claimDrainerIfNeeded()
        }
        if shouldDrain {
            drainActions()
        }
    }

    func finish() {
        let shouldDrain = lock.withLock {
            guard !isFinished else { return false }
            isFinished = true
            pendingTargets.removeAll(keepingCapacity: false)
            for continuation in subscribers.values {
                actions.append(.finish(continuation))
            }
            subscribers.removeAll(keepingCapacity: false)
            return claimDrainerIfNeeded()
        }
        if shouldDrain {
            drainActions()
        }
    }

    private func removeSubscriber(_ subscriptionID: UUID) {
        _ = lock.withLock {
            subscribers.removeValue(forKey: subscriptionID)
        }
    }

    private func claimDrainerIfNeeded() -> Bool {
        guard !isDraining, !actions.isEmpty else { return false }
        isDraining = true
        return true
    }

    private func drainActions() {
        while true {
            let action = lock.withLock { () -> Action? in
                guard !actions.isEmpty else {
                    isDraining = false
                    return nil
                }
                return actions.removeFirst()
            }
            guard let action else { return }
            switch action {
            case .yield(let subscriptionID, let continuation, let target):
                if case .terminated = continuation.yield(target) {
                    removeSubscriber(subscriptionID)
                }
            case .finish(let continuation):
                continuation.finish()
            }
        }
    }
}
