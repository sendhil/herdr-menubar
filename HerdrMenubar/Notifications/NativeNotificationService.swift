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

    private static let payloadVersion = 2
    private static let supportedPayloadVersions: Set<Int> = [1, 2]

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

    func responses() async -> NotificationResponseSubscription {
        responseBroker.subscription()
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

    /// Herdr: `<visible label> — <session>` (unchanged). Other backends: the message's first
    /// line when present, then `<primary label> — <Backend> · <session label>`, so the source
    /// pane is always named.
    static func body(for event: AttentionNotificationEvent) -> String {
        let backend = event.target.target.session.backend
        guard backend != .herdr else {
            return "\(event.visibleLabel) — \(event.sessionName)"
        }
        let source = "\(event.visibleLabel) — \(backend.displayName) · \(event.sessionName)"
        let firstLine = event.message?
            .split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let firstLine, !firstLine.isEmpty else { return source }
        return "\(firstLine)\n\(source)"
    }

    func deliver(
        _ event: AttentionNotificationEvent,
        sound: Bool
    ) async throws -> NotificationDeliveryResult {
        let settings = await backend.settings()
        guard settings.authorization == .authorized, settings.alertsEnabled else {
            return .suppressed
        }

        let content = UNMutableNotificationContent()
        content.title = switch event.status {
        case .blocked: "Agent blocked"
        case .error: "Agent failed"
        case .done: "Agent finished"
        }
        content.body = Self.body(for: event)
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
        return .accepted
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

    static func payload(for target: SelectionTarget) -> [AnyHashable: Any] {
        let session = target.target.session
        var payload: [AnyHashable: Any] = [
            "version": payloadVersion,
            "backend": session.backend.rawValue,
            "session_display_name": target.sessionDisplayName,
            "pane_id": target.target.paneID
        ]
        switch session.backend {
        case .herdr:
            switch session.herdrSessionID {
            case .default?:
                payload["session_kind"] = "default"
            case .named(let name)?:
                payload["session_kind"] = "named"
                payload["session_name"] = name
            case nil:
                break
            }
        case .rex:
            payload["rex_session_id"] = session.rawID
        }
        return payload
    }

    static func decodeTarget(_ userInfo: [AnyHashable: Any]) -> SelectionTarget? {
        guard let version = supportedPayloadVersion(userInfo["version"]),
              let paneID = userInfo["pane_id"] as? String,
              !paneID.isEmpty else { return nil }
        guard version >= 2 else {
            return decodeHerdrTarget(userInfo, paneID: paneID, displayName: nil)
        }
        guard let backend = (userInfo["backend"] as? String).flatMap(BackendKind.init(rawValue:)) else {
            return nil
        }
        let displayName = (userInfo["session_display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        switch backend {
        case .herdr:
            return decodeHerdrTarget(userInfo, paneID: paneID, displayName: displayName)
        case .rex:
            guard let sessionID = userInfo["rex_session_id"] as? String, !sessionID.isEmpty else { return nil }
            return SelectionTarget(
                target: AgentTarget(session: AgentSessionKey(backend: .rex, rawID: sessionID), paneID: paneID),
                sessionDisplayName: displayName ?? sessionID
            )
        }
    }

    private static func decodeHerdrTarget(
        _ userInfo: [AnyHashable: Any],
        paneID: String,
        displayName: String?
    ) -> SelectionTarget? {
        guard let sessionKind = userInfo["session_kind"] as? String else { return nil }
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
        let target = SelectionTarget.herdr(sessionID, paneID: paneID)
        guard let displayName else { return target }
        return SelectionTarget(target: target.target, sessionDisplayName: displayName)
    }

    /// The payload version when it is an integer (not Bool or floating point) in `supportedPayloadVersions`.
    private static func supportedPayloadVersion(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number),
              supportedPayloadVersions.contains(number.intValue) else { return nil }
        return number.intValue
    }
}

private final class NotificationResponseBroker: @unchecked Sendable {
    typealias Target = SelectionTarget
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

    func subscription() -> NotificationResponseSubscription {
        let subscriptionID = UUID()
        let cancellation = NotificationResponseCancellation { [weak self] in
            self?.cancel(subscriptionID: subscriptionID)
        }
        let stream = AsyncStream<Target>(
            unfolding: { [weak self] in
                guard let self else { return nil }
                return await self.next(
                    subscriptionID: subscriptionID,
                    cancellation: cancellation
                )
            },
            onCancel: {
                cancellation.cancel()
            }
        )
        return NotificationResponseSubscription(stream: stream, cancellation: cancellation)
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

    private func next(
        subscriptionID: UUID,
        cancellation: NotificationResponseCancellation
    ) async -> Target? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enum Action {
                    case suspend
                    case resume(Target?)
                    case terminateDuplicate(Waiter)
                }

                let action = cancellation.withActive {
                    lock.withLock { () -> Action in
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

                        if let existingWaiter = subscriber.waiter {
                            subscribers.removeValue(forKey: subscriptionID)
                            return .terminateDuplicate(existingWaiter)
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
                } ?? .resume(nil)

                switch action {
                case .suspend:
                    break
                case .resume(let target):
                    continuation.resume(returning: target)
                case .terminateDuplicate(let existingWaiter):
                    cancellation.cancel()
                    existingWaiter.resume(returning: nil)
                    continuation.resume(returning: nil)
                }
            }
        } onCancel: {
            cancellation.cancel()
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
