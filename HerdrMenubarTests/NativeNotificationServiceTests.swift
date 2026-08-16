import UserNotifications
import XCTest
@testable import HerdrMenubar

final class NativeNotificationServiceTests: XCTestCase {
    func testAuthorizationRequestsAlertsAndSoundExactly() async throws {
        let backend = FakeNotificationCenterBackend(authorizationResult: true)
        let service = NativeNotificationService(backend: backend)

        let authorized = try await service.requestAuthorization()
        XCTAssertTrue(authorized)
        XCTAssertEqual(backend.requestedOptions, [.alert, .sound])
    }

    func testSettingsReflectNotDeterminedAuthorizedDeniedAndExternalRevocation() async {
        let backend = FakeNotificationCenterBackend(settings: .notDetermined)
        let service = NativeNotificationService(backend: backend)

        var settings = await service.settings()
        XCTAssertEqual(settings, .notDetermined)

        backend.settingsValue = .authorized
        settings = await service.settings()
        XCTAssertEqual(settings, .authorized)

        backend.settingsValue = .denied
        settings = await service.settings()
        XCTAssertEqual(settings, .denied)

        let revoked = NotificationSystemSettings(
            authorization: .authorized,
            alertsEnabled: false,
            soundsEnabled: true
        )
        backend.settingsValue = revoked
        settings = await service.settings()
        XCTAssertEqual(settings, revoked)
    }

    func testNativeSettingsMappingPreservesAuthorizationAlertAndSoundState() {
        XCTAssertEqual(
            LiveUserNotificationCenterBackend.mapSettings(
                authorizationStatus: .notDetermined,
                alertSetting: .disabled,
                soundSetting: .disabled
            ),
            .notDetermined
        )
        XCTAssertEqual(
            LiveUserNotificationCenterBackend.mapSettings(
                authorizationStatus: .authorized,
                alertSetting: .enabled,
                soundSetting: .enabled
            ),
            .authorized
        )
        XCTAssertEqual(
            LiveUserNotificationCenterBackend.mapSettings(
                authorizationStatus: .denied,
                alertSetting: .enabled,
                soundSetting: .enabled
            ),
            NotificationSystemSettings(
                authorization: .denied,
                alertsEnabled: true,
                soundsEnabled: true
            )
        )
        XCTAssertEqual(
            LiveUserNotificationCenterBackend.mapSettings(
                authorizationStatus: .authorized,
                alertSetting: .disabled,
                soundSetting: .enabled
            ),
            NotificationSystemSettings(
                authorization: .authorized,
                alertsEnabled: false,
                soundsEnabled: true
            )
        )
    }

    func testDeliveryBuildsUniqueSilentRequestsWithVersionedNamedTarget() async throws {
        let backend = FakeNotificationCenterBackend(settings: .authorized)
        let service = NativeNotificationService(backend: backend)
        let event = AttentionNotificationEvent(
            target: NotificationSelectionTarget(sessionID: .named("work"), paneID: "pane-1"),
            sessionName: "work",
            visibleLabel: "Herdr Menubar · server",
            status: .done
        )

        try await service.deliver(event, sound: false)
        try await service.deliver(event, sound: false)

        let requests = backend.addedRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertNotEqual(requests[0].identifier, requests[1].identifier)
        XCTAssertEqual(requests[0].content.title, "Agent finished")
        XCTAssertEqual(requests[0].content.body, "Herdr Menubar · server — work")
        XCTAssertNil(requests[0].content.sound)
        XCTAssertNil(requests[0].trigger)
        XCTAssertEqual(requests[0].content.userInfo["version"] as? Int, 1)
        XCTAssertEqual(requests[0].content.userInfo["session_kind"] as? String, "named")
        XCTAssertEqual(requests[0].content.userInfo["session_name"] as? String, "work")
        XCTAssertEqual(requests[0].content.userInfo["pane_id"] as? String, "pane-1")
    }

    func testBlockedDeliveryUsesBlockedContent() async throws {
        let backend = FakeNotificationCenterBackend(settings: .authorized)
        let service = NativeNotificationService(backend: backend)

        try await service.deliver(blockedEvent(), sound: false)

        let request = try XCTUnwrap(backend.addedRequests.first)
        XCTAssertEqual(request.content.title, "Agent blocked")
        XCTAssertEqual(request.content.body, "Herdr Menubar · worker — Default")
    }

    func testSoundRequiresRequestedSoundAndEnabledSystemSound() async throws {
        let backend = FakeNotificationCenterBackend(settings: .authorized)
        let service = NativeNotificationService(backend: backend)
        let event = blockedEvent()

        try await service.deliver(event, sound: false)
        XCTAssertNil(backend.addedRequests[0].content.sound)

        try await service.deliver(event, sound: true)
        XCTAssertNotNil(backend.addedRequests[1].content.sound)

        backend.settingsValue = NotificationSystemSettings(
            authorization: .authorized,
            alertsEnabled: true,
            soundsEnabled: false
        )
        try await service.deliver(event, sound: true)
        XCTAssertNil(backend.addedRequests[2].content.sound)
    }

    func testUnauthorizedOrAlertDisabledDeliveryAddsNothing() async throws {
        let unavailableSettings = [
            NotificationSystemSettings(
                authorization: .notDetermined,
                alertsEnabled: true,
                soundsEnabled: true
            ),
            NotificationSystemSettings(
                authorization: .denied,
                alertsEnabled: true,
                soundsEnabled: true
            ),
            NotificationSystemSettings(
                authorization: .authorized,
                alertsEnabled: false,
                soundsEnabled: true
            )
        ]

        for settings in unavailableSettings {
            let backend = FakeNotificationCenterBackend(settings: settings)
            let service = NativeNotificationService(backend: backend)
            try await service.deliver(blockedEvent(), sound: true)
            XCTAssertEqual(backend.addedRequests, [])
        }
    }

    func testDefaultAndNamedPayloadsRoundTripExactly() {
        let targets = [
            NotificationSelectionTarget(sessionID: .default, paneID: "default-pane"),
            NotificationSelectionTarget(sessionID: .named("work"), paneID: "named-pane")
        ]

        for target in targets {
            let payload = NativeNotificationService.payload(for: target)
            XCTAssertEqual(payload["version"] as? Int, 1)
            XCTAssertEqual(NativeNotificationService.decodeTarget(payload), target)
        }

        let defaultPayload = NativeNotificationService.payload(for: targets[0])
        XCTAssertEqual(defaultPayload["session_kind"] as? String, "default")
        XCTAssertNil(defaultPayload["session_name"])
    }

    func testResponseProducedBeforeSubscriptionIsBuffered() async {
        let backend = FakeNotificationCenterBackend(settings: .authorized)
        let service = NativeNotificationService(backend: backend)
        service.handleResponse(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: validPayload(paneID: "early")
        )

        var iterator = await service.responses().makeAsyncIterator()
        let target = await iterator.next()

        XCTAssertEqual(
            target,
            NotificationSelectionTarget(sessionID: .default, paneID: "early")
        )
    }

    func testResponseBufferIsBoundedAndKeepsNewestTargets() async {
        let backend = FakeNotificationCenterBackend(settings: .authorized)
        let service = NativeNotificationService(backend: backend)
        for index in 0..<12 {
            service.handleResponse(
                actionIdentifier: UNNotificationDefaultActionIdentifier,
                userInfo: validPayload(paneID: "pane-\(index)")
            )
        }

        var iterator = await service.responses().makeAsyncIterator()
        var paneIDs: [String] = []
        for _ in 0..<8 {
            paneIDs.append(await iterator.next()?.paneID ?? "missing")
        }

        XCTAssertEqual(paneIDs, (4..<12).map { "pane-\($0)" })
    }

    func testAbandonedResponseStreamDoesNotCapturePreSubscriptionBuffer() async {
        let backend = FakeNotificationCenterBackend(settings: .authorized)
        let service = NativeNotificationService(backend: backend)
        do {
            let abandoned = await service.responses()
            XCTAssertEqual(service.responseSubscriberCount, 0)
            _ = abandoned
        }
        XCTAssertEqual(service.responseSubscriberCount, 0)
        for index in 0..<12 {
            service.handleResponse(
                actionIdentifier: UNNotificationDefaultActionIdentifier,
                userInfo: validPayload(paneID: "pane-\(index)")
            )
        }

        let realStream = await service.responses()
        let receivedEight = expectation(description: "newest eight received")
        receivedEight.expectedFulfillmentCount = 8
        let realSubscriber = Task { () -> [String] in
            var iterator = realStream.makeAsyncIterator()
            var paneIDs: [String] = []
            for _ in 0..<8 {
                guard let target = await iterator.next() else { break }
                paneIDs.append(target.paneID)
                receivedEight.fulfill()
            }
            return paneIDs
        }
        await fulfillment(of: [receivedEight], timeout: 0.5)
        realSubscriber.cancel()
        let paneIDs = await realSubscriber.value

        XCTAssertEqual(paneIDs, (4..<12).map { "pane-\($0)" })
    }

    func testSlowResponseSubscriberKeepsOnlyNewestEight() async {
        let backend = FakeNotificationCenterBackend(settings: .authorized)
        let service = NativeNotificationService(backend: backend)
        service.handleResponse(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: validPayload(paneID: "prime")
        )
        var iterator = await service.responses().makeAsyncIterator()
        let prime = await iterator.next()
        XCTAssertEqual(prime?.paneID, "prime")

        for index in 0..<12 {
            service.handleResponse(
                actionIdentifier: UNNotificationDefaultActionIdentifier,
                userInfo: validPayload(paneID: "pane-\(index)")
            )
        }

        var paneIDs: [String] = []
        for _ in 0..<8 {
            paneIDs.append(await iterator.next()?.paneID ?? "missing")
        }
        XCTAssertEqual(paneIDs, (4..<12).map { "pane-\($0)" })
    }

    func testCancellingOldResponseSubscriberAllowsLaterSubscriberToReceive() async {
        let backend = FakeNotificationCenterBackend(settings: .authorized)
        let service = NativeNotificationService(backend: backend)
        let oldStream = await service.responses()
        let oldSubscriberStarted = expectation(description: "old subscriber started")
        let oldSubscriber = Task { () -> NotificationSelectionTarget? in
            var iterator = oldStream.makeAsyncIterator()
            oldSubscriberStarted.fulfill()
            return await iterator.next()
        }
        await fulfillment(of: [oldSubscriberStarted], timeout: 1)
        await assertSubscriberCount(1, service: service)

        oldSubscriber.cancel()
        let cancelledResult = await oldSubscriber.value
        XCTAssertNil(cancelledResult)

        var newIterator = await service.responses().makeAsyncIterator()
        service.handleResponse(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: validPayload(paneID: "after-resubscribe")
        )
        let newResult = await newIterator.next()
        XCTAssertEqual(
            newResult,
            NotificationSelectionTarget(sessionID: .default, paneID: "after-resubscribe")
        )
    }

    func testActiveResponseSubscribersEachReceiveEveryClick() async {
        let backend = FakeNotificationCenterBackend(settings: .authorized)
        let service = NativeNotificationService(backend: backend)
        let firstStream = await service.responses()
        let secondStream = await service.responses()
        let subscribersStarted = expectation(description: "subscribers started")
        subscribersStarted.expectedFulfillmentCount = 2
        let subscribersReceived = expectation(description: "subscribers received")
        subscribersReceived.expectedFulfillmentCount = 2
        let firstSubscriber = Task { () -> NotificationSelectionTarget? in
            var iterator = firstStream.makeAsyncIterator()
            subscribersStarted.fulfill()
            let target = await iterator.next()
            subscribersReceived.fulfill()
            return target
        }
        let secondSubscriber = Task { () -> NotificationSelectionTarget? in
            var iterator = secondStream.makeAsyncIterator()
            subscribersStarted.fulfill()
            let target = await iterator.next()
            subscribersReceived.fulfill()
            return target
        }
        await fulfillment(of: [subscribersStarted], timeout: 1)
        await assertSubscriberCount(2, service: service)

        service.handleResponse(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: validPayload(paneID: "broadcast")
        )
        await fulfillment(of: [subscribersReceived], timeout: 0.5)
        firstSubscriber.cancel()
        secondSubscriber.cancel()
        let firstResult = await firstSubscriber.value
        let secondResult = await secondSubscriber.value
        let expected = NotificationSelectionTarget(sessionID: .default, paneID: "broadcast")
        XCTAssertEqual(firstResult, expected)
        XCTAssertEqual(secondResult, expected)
    }

    func testCancellingOneResponseSubscriberLeavesOtherSubscriberActive() async {
        let backend = FakeNotificationCenterBackend(settings: .authorized)
        let service = NativeNotificationService(backend: backend)
        let cancelledStream = await service.responses()
        let retainedStream = await service.responses()
        let subscribersStarted = expectation(description: "subscribers started")
        subscribersStarted.expectedFulfillmentCount = 2
        let cancelledSubscriber = Task { () -> NotificationSelectionTarget? in
            var iterator = cancelledStream.makeAsyncIterator()
            subscribersStarted.fulfill()
            return await iterator.next()
        }
        let retainedSubscriber = Task { () -> NotificationSelectionTarget? in
            var iterator = retainedStream.makeAsyncIterator()
            subscribersStarted.fulfill()
            return await iterator.next()
        }
        await fulfillment(of: [subscribersStarted], timeout: 1)
        await assertSubscriberCount(2, service: service)

        cancelledSubscriber.cancel()
        let cancelledResult = await cancelledSubscriber.value
        XCTAssertNil(cancelledResult)
        service.handleResponse(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: validPayload(paneID: "retained")
        )

        let retainedResult = await retainedSubscriber.value
        XCTAssertEqual(
            retainedResult,
            NotificationSelectionTarget(sessionID: .default, paneID: "retained")
        )
    }

    func testPreSubscriptionBufferIsDeliveredOnlyToFirstSubscriber() async {
        let backend = FakeNotificationCenterBackend(settings: .authorized)
        let service = NativeNotificationService(backend: backend)
        service.handleResponse(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: validPayload(paneID: "buffered")
        )

        var firstIterator = await service.responses().makeAsyncIterator()
        let secondStream = await service.responses()
        let bufferedResult = await firstIterator.next()
        XCTAssertEqual(
            bufferedResult,
            NotificationSelectionTarget(sessionID: .default, paneID: "buffered")
        )

        let secondSubscriberStarted = expectation(description: "second subscriber started")
        let secondSubscriber = Task { () -> NotificationSelectionTarget? in
            var iterator = secondStream.makeAsyncIterator()
            secondSubscriberStarted.fulfill()
            return await iterator.next()
        }
        await fulfillment(of: [secondSubscriberStarted], timeout: 1)
        await assertSubscriberCount(2, service: service)
        service.handleResponse(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: validPayload(paneID: "live")
        )
        let secondResult = await secondSubscriber.value
        XCTAssertEqual(
            secondResult,
            NotificationSelectionTarget(sessionID: .default, paneID: "live")
        )
    }

    func testServiceDeinitFinishesAllActiveResponseSubscribers() async {
        let backend = FakeNotificationCenterBackend(settings: .authorized)
        var service: NativeNotificationService? = NativeNotificationService(backend: backend)
        let firstStream = await service?.responses()
        let secondStream = await service?.responses()
        let subscribersStarted = expectation(description: "subscribers started")
        subscribersStarted.expectedFulfillmentCount = 2
        let firstSubscriber = Task { () -> NotificationSelectionTarget? in
            var iterator = firstStream!.makeAsyncIterator()
            subscribersStarted.fulfill()
            return await iterator.next()
        }
        let secondSubscriber = Task { () -> NotificationSelectionTarget? in
            var iterator = secondStream!.makeAsyncIterator()
            subscribersStarted.fulfill()
            return await iterator.next()
        }
        await fulfillment(of: [subscribersStarted], timeout: 1)
        await assertSubscriberCount(2, service: service!)

        service = nil

        let firstResult = await firstSubscriber.value
        let secondResult = await secondSubscriber.value
        XCTAssertNil(firstResult)
        XCTAssertNil(secondResult)
    }

    func testDismissCustomMalformedEmptyAndFutureActionsAreIgnored() async {
        let backend = FakeNotificationCenterBackend(settings: .authorized)
        let service = NativeNotificationService(backend: backend)
        let ignored: [(String, [AnyHashable: Any])] = [
            (UNNotificationDismissActionIdentifier, validPayload(paneID: "dismissed")),
            ("custom", validPayload(paneID: "custom")),
            (UNNotificationDefaultActionIdentifier, [:]),
            (UNNotificationDefaultActionIdentifier, [
                "version": "1", "session_kind": "default", "pane_id": "wrong-version-type"
            ]),
            (UNNotificationDefaultActionIdentifier, [
                "version": 2, "session_kind": "default", "pane_id": "future"
            ]),
            (UNNotificationDefaultActionIdentifier, [
                "version": 1, "session_kind": "unknown", "pane_id": "unknown-kind"
            ]),
            (UNNotificationDefaultActionIdentifier, [
                "version": 1, "session_kind": "default", "pane_id": ""
            ]),
            (UNNotificationDefaultActionIdentifier, [
                "version": 1, "session_kind": "named", "session_name": "", "pane_id": "pane"
            ]),
            (UNNotificationDefaultActionIdentifier, [
                "version": 1, "session_kind": "named", "pane_id": "missing-name"
            ])
        ]

        for (actionIdentifier, userInfo) in ignored {
            service.handleResponse(actionIdentifier: actionIdentifier, userInfo: userInfo)
        }
        service.handleResponse(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: validPayload(paneID: "accepted")
        )

        var iterator = await service.responses().makeAsyncIterator()
        let firstTarget = await iterator.next()
        XCTAssertEqual(
            firstTarget,
            NotificationSelectionTarget(sessionID: .default, paneID: "accepted")
        )
    }

    func testPayloadVersionAcceptsOnlyIntegerOne() {
        let acceptedVersions: [Any] = [1, NSNumber(value: 1)]
        for version in acceptedVersions {
            var payload = validPayload(paneID: "accepted-integer")
            payload["version"] = version
            XCTAssertEqual(
                NativeNotificationService.decodeTarget(payload),
                NotificationSelectionTarget(sessionID: .default, paneID: "accepted-integer")
            )
        }

        let rejectedVersions: [Any] = [NSNumber(value: true), NSNumber(value: 1.0)]
        for version in rejectedVersions {
            var payload = validPayload(paneID: "rejected-number")
            payload["version"] = version
            XCTAssertNil(NativeNotificationService.decodeTarget(payload))
        }
    }

    func testForegroundPresentationIsListOnly() {
        XCTAssertEqual(NativeNotificationService.foregroundPresentationOptions, [.list])
        XCTAssertFalse(NativeNotificationService.foregroundPresentationOptions.contains(.banner))
        XCTAssertFalse(NativeNotificationService.foregroundPresentationOptions.contains(.sound))
    }

    func testDelegateIsInstalledExactlyOnce() {
        let backend = FakeNotificationCenterBackend(settings: .authorized)
        let service = NativeNotificationService(backend: backend)

        XCTAssertEqual(backend.delegateInstallCount, 1)
        XCTAssertTrue(backend.installedDelegate === service)
    }
}

private final class FakeNotificationCenterBackend: UserNotificationCenterBacking, @unchecked Sendable {
    private let lock = NSLock()
    private var authorizationResultValue: Bool
    private var requestedOptionsValue: UNAuthorizationOptions?
    private var settingsStorage: NotificationSystemSettings
    private var addedRequestsStorage: [UNNotificationRequest] = []
    private var delegateInstallCountStorage = 0
    private weak var installedDelegateStorage: (any UNUserNotificationCenterDelegate)?

    init(
        authorizationResult: Bool = false,
        settings: NotificationSystemSettings = .notDetermined
    ) {
        authorizationResultValue = authorizationResult
        settingsStorage = settings
    }

    var requestedOptions: UNAuthorizationOptions? {
        lock.withLock { requestedOptionsValue }
    }

    var settingsValue: NotificationSystemSettings {
        get { lock.withLock { settingsStorage } }
        set { lock.withLock { settingsStorage = newValue } }
    }

    var addedRequests: [UNNotificationRequest] {
        lock.withLock { addedRequestsStorage }
    }

    var delegateInstallCount: Int {
        lock.withLock { delegateInstallCountStorage }
    }

    var installedDelegate: (any UNUserNotificationCenterDelegate)? {
        lock.withLock { installedDelegateStorage }
    }

    func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?) {
        lock.withLock {
            delegateInstallCountStorage += 1
            installedDelegateStorage = delegate
        }
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        lock.withLock { requestedOptionsValue = options }
        return lock.withLock { authorizationResultValue }
    }

    func settings() async -> NotificationSystemSettings {
        lock.withLock { settingsStorage }
    }

    func add(_ request: UNNotificationRequest) async throws {
        lock.withLock { addedRequestsStorage.append(request) }
    }
}

private func blockedEvent() -> AttentionNotificationEvent {
    AttentionNotificationEvent(
        target: NotificationSelectionTarget(sessionID: .default, paneID: "pane-blocked"),
        sessionName: "Default",
        visibleLabel: "Herdr Menubar · worker",
        status: .blocked
    )
}

private func validPayload(paneID: String) -> [AnyHashable: Any] {
    [
        "version": 1,
        "session_kind": "default",
        "pane_id": paneID
    ]
}

private func assertSubscriberCount(
    _ expectedCount: Int,
    service: NativeNotificationService,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    for _ in 0..<1_000 {
        if service.responseSubscriberCount == expectedCount {
            return
        }
        await Task.yield()
    }
    XCTFail(
        "Expected \(expectedCount) response subscribers, got \(service.responseSubscriberCount)",
        file: file,
        line: line
    )
}
