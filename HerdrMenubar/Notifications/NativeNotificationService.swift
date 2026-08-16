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

    var responseSubscriberCount: Int {
        responseBroker.subscriberCount
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
    typealias Waiter = CheckedContinuation<Target?, Never>

    private struct Subscriber {
        var mailbox: [Target]
        var waiter: Waiter?
    }

    private let lock = NSLock()
    private let preSubscriptionBufferLimit: Int
    private var subscribers: [UUID: Subscriber] = [:]
    private var pendingTargets: [Target] = []
    private var isFinished = false

    init(preSubscriptionBufferLimit: Int) {
        self.preSubscriptionBufferLimit = preSubscriptionBufferLimit
    }

    var subscriberCount: Int {
        lock.withLock { subscribers.count }
    }

    func stream() -> AsyncStream<Target> {
        let subscriptionID = UUID()
        return AsyncStream(
            unfolding: { [weak self] in
                guard let self else { return nil }
                return await self.next(subscriptionID: subscriptionID)
            },
            onCancel: { [weak self] in
                self?.cancel(subscriptionID: subscriptionID)
            }
        )
    }

    func yield(_ target: Target) {
        let waiters = lock.withLock { () -> [Waiter] in
            guard !isFinished else { return [] }
            guard !subscribers.isEmpty else {
                appendNewest(target, to: &pendingTargets)
                return []
            }
            var waiters: [Waiter] = []
            let subscriptionIDs = Array(subscribers.keys)
            for subscriptionID in subscriptionIDs {
                guard var subscriber = subscribers[subscriptionID] else { continue }
                if let waiter = subscriber.waiter {
                    subscriber.waiter = nil
                    waiters.append(waiter)
                } else {
                    appendNewest(target, to: &subscriber.mailbox)
                }
                subscribers[subscriptionID] = subscriber
            }
            return waiters
        }
        for waiter in waiters {
            waiter.resume(returning: target)
        }
    }

    func finish() {
        let waiters = lock.withLock { () -> [Waiter] in
            guard !isFinished else { return [] }
            isFinished = true
            pendingTargets.removeAll(keepingCapacity: false)
            let waiters = subscribers.values.compactMap(\.waiter)
            subscribers.removeAll(keepingCapacity: false)
            return waiters
        }
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    private func next(subscriptionID: UUID) async -> Target? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enum Action {
                    case suspend
                    case resume(Target?)
                }

                let action = lock.withLock { () -> Action in
                    guard !isFinished, !Task.isCancelled else { return .resume(nil) }

                    var subscriber: Subscriber
                    if let existing = subscribers[subscriptionID] {
                        subscriber = existing
                    } else {
                        let initialMailbox: [Target]
                        if subscribers.isEmpty {
                            initialMailbox = pendingTargets
                            pendingTargets.removeAll(keepingCapacity: true)
                        } else {
                            initialMailbox = []
                        }
                        subscriber = Subscriber(mailbox: initialMailbox, waiter: nil)
                    }

                    guard subscriber.waiter == nil else {
                        subscribers[subscriptionID] = subscriber
                        return .resume(nil)
                    }
                    if !subscriber.mailbox.isEmpty {
                        let target = subscriber.mailbox.removeFirst()
                        subscribers[subscriptionID] = subscriber
                        return .resume(target)
                    }
                    subscriber.waiter = continuation
                    subscribers[subscriptionID] = subscriber
                    return .suspend
                }

                if case .resume(let target) = action {
                    continuation.resume(returning: target)
                }
            }
        } onCancel: {
            cancel(subscriptionID: subscriptionID)
        }
    }

    private func cancel(subscriptionID: UUID) {
        let waiter = lock.withLock {
            subscribers.removeValue(forKey: subscriptionID)?.waiter
        }
        waiter?.resume(returning: nil)
    }

    private func appendNewest(_ target: Target, to buffer: inout [Target]) {
        buffer.append(target)
        if buffer.count > preSubscriptionBufferLimit {
            buffer.removeFirst(buffer.count - preSubscriptionBufferLimit)
        }
    }
}
