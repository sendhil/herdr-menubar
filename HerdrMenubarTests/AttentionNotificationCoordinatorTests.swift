import XCTest
@testable import HerdrMenubar

final class AttentionNotificationCoordinatorTests: XCTestCase {
    func testFirstSnapshotForEverySessionIsSilent() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(service: service)
        let work = descriptor("work")
        let personal = descriptor("personal")
        let policy = enabledPolicy()

        await coordinator.reconcile(
            session: work,
            items: [item(work, "blocked", .blocked), item(work, "done", .done)],
            policy: policy
        )
        await coordinator.reconcile(
            session: personal,
            items: [item(personal, "done", .done)],
            policy: policy
        )

        let deliveries = await service.deliveries
        XCTAssertEqual(deliveries, [])
    }

    func testIdleWorkingAndUnknownTransitionsToBlockedOrDoneDeliverOnce() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(service: service)
        let session = descriptor("work")
        let policy = enabledPolicy()

        await coordinator.reconcile(
            session: session,
            items: [
                item(session, "idle-blocked", .idle),
                item(session, "idle-done", .idle),
                item(session, "unknown-blocked", .unknown),
                item(session, "unknown-done", .unknown),
                item(session, "working-blocked", .working),
                item(session, "working-done", .working)
            ],
            policy: policy
        )
        await coordinator.reconcile(
            session: session,
            items: [
                item(session, "idle-blocked", .blocked),
                item(session, "idle-done", .done),
                item(session, "unknown-blocked", .blocked),
                item(session, "unknown-done", .done),
                item(session, "working-blocked", .blocked),
                item(session, "working-done", .done)
            ],
            policy: policy
        )

        let deliveries = await service.deliveries
        XCTAssertEqual(deliveries.map(\.event.target.paneID), [
            "idle-blocked", "idle-done", "unknown-blocked",
            "unknown-done", "working-blocked", "working-done"
        ])
        XCTAssertEqual(deliveries.map(\.event.status), [
            .blocked, .done, .blocked, .done, .blocked, .done
        ])
    }

    func testBlockedAndDoneTransitionsBothDeliverWhileRepeatedStatusesStaySilent() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(service: service)
        let session = descriptor("work")
        let policy = enabledPolicy()

        await coordinator.reconcile(session: session, items: [item(session, "p", .working)], policy: policy)
        await coordinator.reconcile(session: session, items: [item(session, "p", .blocked)], policy: policy)
        await coordinator.reconcile(session: session, items: [item(session, "p", .blocked)], policy: policy)
        await coordinator.reconcile(session: session, items: [item(session, "p", .done)], policy: policy)
        await coordinator.reconcile(session: session, items: [item(session, "p", .done)], policy: policy)
        await coordinator.reconcile(session: session, items: [item(session, "p", .blocked)], policy: policy)

        let deliveries = await service.deliveries
        XCTAssertEqual(deliveries.map(\.event.status), [.blocked, .done, .blocked])
    }

    func testReturningToNonAttentionAllowsLaterAttentionTransitionToDeliver() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(service: service)
        let session = descriptor("work")
        let policy = enabledPolicy()

        await coordinator.reconcile(session: session, items: [item(session, "p", .working)], policy: policy)
        await coordinator.reconcile(session: session, items: [item(session, "p", .blocked)], policy: policy)
        await coordinator.reconcile(session: session, items: [item(session, "p", .idle)], policy: policy)
        await coordinator.reconcile(session: session, items: [item(session, "p", .done)], policy: policy)

        let deliveries = await service.deliveries
        XCTAssertEqual(deliveries.map(\.event.status), [.blocked, .done])
    }

    func testNewAttentionPaneInBaselinedSessionDeliversWithCompleteEvent() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(service: service)
        let session = descriptor("work")
        let policy = enabledPolicy()

        await coordinator.reconcile(session: session, items: [item(session, "a", .working)], policy: policy)
        await coordinator.reconcile(
            session: session,
            items: [item(session, "a", .working), item(session, "b", .done, title: "Build tests")],
            policy: policy
        )

        let deliveries = await service.deliveries
        XCTAssertEqual(deliveries.map(\.event), [
            AttentionNotificationEvent(
                target: NotificationSelectionTarget(sessionID: .named("work"), paneID: "b"),
                sessionName: "work",
                visibleLabel: "Build tests · Pi",
                status: .done
            )
        ])
    }

    func testPaneDisappearanceRemovesHistoryAndAttentionReappearanceDelivers() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(service: service)
        let session = descriptor("work")
        let policy = enabledPolicy()

        await coordinator.reconcile(session: session, items: [item(session, "p", .blocked)], policy: policy)
        await coordinator.reconcile(session: session, items: [], policy: policy)
        await coordinator.reconcile(session: session, items: [item(session, "p", .blocked)], policy: policy)
        await coordinator.reconcile(session: session, items: [item(session, "p", .blocked)], policy: policy)

        let deliveries = await service.deliveries
        XCTAssertEqual(deliveries.map(\.event.target.paneID), ["p"])
        XCTAssertEqual(deliveries.map(\.event.status), [.blocked])
    }

    func testDuplicatePaneIDsUseLastAuthoritativeOccurrenceForHistoryAndDeliverAtMostOnce() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(service: service)
        let session = descriptor("work")
        let policy = enabledPolicy()

        await coordinator.reconcile(
            session: session,
            items: [
                item(session, "p", .blocked, title: "Stale baseline"),
                item(session, "p", .working, title: "Canonical baseline")
            ],
            policy: policy
        )
        await coordinator.reconcile(
            session: session,
            items: [
                item(session, "p", .blocked, title: "Stale update"),
                item(session, "p", .done, title: "Canonical update")
            ],
            policy: policy
        )
        await coordinator.reconcile(
            session: session,
            items: [item(session, "p", .done, title: "Later snapshot")],
            policy: policy
        )

        let deliveries = await service.deliveries
        XCTAssertEqual(deliveries.map(\.event.target.paneID), ["p"])
        XCTAssertEqual(deliveries.map(\.event.status), [.done])
        XCTAssertEqual(deliveries.map(\.event.visibleLabel), ["Canonical update · Pi"])
    }

    func testCancellationDuringFirstDeliveryReturnsWithoutAttemptingRemainingDeliveries() async {
        let service = ControlledNotificationService(firstDeliveryBehavior: .suspendUntilCancelled)
        let coordinator = AttentionNotificationCoordinator(service: service)
        let session = descriptor("work")
        let policy = enabledPolicy()

        await coordinator.reconcile(
            session: session,
            items: [item(session, "a", .working), item(session, "b", .working)],
            policy: policy
        )
        let reconcileTask = Task {
            await coordinator.reconcile(
                session: session,
                items: [item(session, "a", .blocked), item(session, "b", .done)],
                policy: policy
            )
        }

        await service.waitForFirstAttempt()
        reconcileTask.cancel()
        await reconcileTask.value

        let attempts = await service.attemptedPaneIDs
        XCTAssertEqual(attempts, ["a"])
    }

    func testShuffledAttentionItemsDeliverInLabelOrderWithPaneIDTieBreaker() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(service: service)
        let session = descriptor("work")
        let policy = enabledPolicy()

        await coordinator.reconcile(
            session: session,
            items: [
                item(session, "z", .working, title: "Zulu"),
                item(session, "b", .working, title: "Alpha"),
                item(session, "a", .working, title: "alpha")
            ],
            policy: policy
        )
        await coordinator.reconcile(
            session: session,
            items: [
                item(session, "z", .blocked, title: "Zulu"),
                item(session, "b", .done, title: "Alpha"),
                item(session, "a", .blocked, title: "alpha")
            ],
            policy: policy
        )

        let deliveries = await service.deliveries
        XCTAssertEqual(deliveries.map(\.event.target.paneID), ["a", "b", "z"])
    }

    func testGenuineDeliveryErrorIsIsolatedAndLaterDeliveryStillSucceeds() async {
        let service = ControlledNotificationService(firstDeliveryBehavior: .throwSchedulingError)
        let coordinator = AttentionNotificationCoordinator(service: service)
        let session = descriptor("work")
        let policy = enabledPolicy()

        await coordinator.reconcile(
            session: session,
            items: [item(session, "a", .working), item(session, "b", .working)],
            policy: policy
        )
        await coordinator.reconcile(
            session: session,
            items: [item(session, "b", .done), item(session, "a", .blocked)],
            policy: policy
        )

        let attempts = await service.attemptedPaneIDs
        let delivered = await service.deliveredPaneIDs
        XCTAssertEqual(attempts, ["a", "b"])
        XCTAssertEqual(delivered, ["b"])
    }

    func testDuplicatePaneIDsAreIndependentAcrossSessions() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(service: service)
        let defaultSession = SessionDescriptor(
            id: .default,
            socketURL: URL(fileURLWithPath: "/tmp/default.sock")
        )
        let work = descriptor("work")
        let policy = enabledPolicy()

        await coordinator.reconcile(
            session: defaultSession,
            items: [item(defaultSession, "same", .working)],
            policy: policy
        )
        await coordinator.reconcile(session: work, items: [item(work, "same", .working)], policy: policy)
        await coordinator.reconcile(
            session: defaultSession,
            items: [item(defaultSession, "same", .done)],
            policy: policy
        )
        await coordinator.reconcile(session: work, items: [item(work, "same", .blocked)], policy: policy)

        let deliveries = await service.deliveries
        XCTAssertEqual(deliveries.map(\.event.target), [
            NotificationSelectionTarget(sessionID: .default, paneID: "same"),
            NotificationSelectionTarget(sessionID: .named("work"), paneID: "same")
        ])
        XCTAssertEqual(deliveries.map(\.event.status), [.done, .blocked])
    }

    func testUnavailableRetainsHistoryAndUnchangedReconnectIsSilent() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(service: service)
        let session = descriptor("work")
        let policy = enabledPolicy()

        await coordinator.reconcile(session: session, items: [item(session, "p", .working)], policy: policy)
        await coordinator.reconcile(session: session, items: [item(session, "p", .blocked)], policy: policy)
        await coordinator.unavailable(sessionID: session.id)
        await coordinator.reconcile(session: session, items: [item(session, "p", .blocked)], policy: policy)

        let deliveries = await service.deliveries
        XCTAssertEqual(deliveries.map(\.event.status), [.blocked])
    }

    func testRemovalClearsHistoryAndRecreatedSessionPrimesSilently() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(service: service)
        let session = descriptor("work")
        let policy = enabledPolicy()

        await coordinator.reconcile(session: session, items: [item(session, "p", .working)], policy: policy)
        await coordinator.reconcile(session: session, items: [item(session, "p", .blocked)], policy: policy)
        await coordinator.remove(sessionID: session.id)
        await coordinator.reconcile(session: session, items: [item(session, "p", .done)], policy: policy)

        let deliveries = await service.deliveries
        XCTAssertEqual(deliveries.map(\.event.status), [.blocked])
    }

    func testDisabledDeliveryStillAdvancesStatusHistory() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(service: service)
        let session = descriptor("work")
        let off = NotificationDeliveryPolicy(notificationsEnabled: false, soundEnabled: true)
        let on = enabledPolicy(soundEnabled: true)

        await coordinator.reconcile(session: session, items: [item(session, "p", .working)], policy: off)
        await coordinator.reconcile(session: session, items: [item(session, "p", .blocked)], policy: off)
        await coordinator.reconcile(session: session, items: [item(session, "p", .blocked)], policy: on)
        await coordinator.reconcile(session: session, items: [item(session, "p", .done)], policy: on)

        let deliveries = await service.deliveries
        XCTAssertEqual(deliveries.map(\.event.status), [.done])
        XCTAssertEqual(deliveries.map(\.sound), [true])
    }

    func testSoundPolicyIsForwardedForEachDelivery() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(service: service)
        let session = descriptor("work")

        await coordinator.reconcile(
            session: session,
            items: [item(session, "silent", .working), item(session, "audible", .working)],
            policy: enabledPolicy()
        )
        await coordinator.reconcile(
            session: session,
            items: [item(session, "silent", .blocked), item(session, "audible", .working)],
            policy: enabledPolicy(soundEnabled: false)
        )
        await coordinator.reconcile(
            session: session,
            items: [item(session, "silent", .blocked), item(session, "audible", .done)],
            policy: enabledPolicy(soundEnabled: true)
        )

        let deliveries = await service.deliveries
        XCTAssertEqual(deliveries.map(\.event.target.paneID), ["silent", "audible"])
        XCTAssertEqual(deliveries.map(\.sound), [false, true])
    }

    func testResetClearsEverySessionBaselineAndMakesNextSnapshotsSilent() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(service: service)
        let work = descriptor("work")
        let personal = descriptor("personal")
        let policy = enabledPolicy()

        await coordinator.reconcile(session: work, items: [item(work, "p", .working)], policy: policy)
        await coordinator.reconcile(session: personal, items: [item(personal, "p", .working)], policy: policy)
        await coordinator.reconcile(session: work, items: [item(work, "p", .blocked)], policy: policy)
        await coordinator.reconcile(session: personal, items: [item(personal, "p", .done)], policy: policy)
        await coordinator.reset()
        await coordinator.reconcile(session: work, items: [item(work, "p", .done)], policy: policy)
        await coordinator.reconcile(session: personal, items: [item(personal, "p", .blocked)], policy: policy)

        let deliveries = await service.deliveries
        XCTAssertEqual(deliveries.map(\.event.status), [.blocked, .done])
    }
}

private actor RecordingNotificationService: NativeNotificationServing {
    struct Delivery: Equatable, Sendable {
        let event: AttentionNotificationEvent
        let sound: Bool
    }

    private(set) var deliveries: [Delivery] = []

    func responses() async -> AsyncStream<NotificationSelectionTarget> {
        AsyncStream { $0.finish() }
    }

    func requestAuthorization() async throws -> Bool { true }

    func settings() async -> NotificationSystemSettings { .authorized }

    func deliver(_ event: AttentionNotificationEvent, sound: Bool) async throws {
        deliveries.append(Delivery(event: event, sound: sound))
    }
}

private actor ControlledNotificationService: NativeNotificationServing {
    enum FirstDeliveryBehavior: Sendable {
        case suspendUntilCancelled
        case throwSchedulingError
    }

    private let firstDeliveryBehavior: FirstDeliveryBehavior
    private let firstAttemptSignal = TestSignal()
    private(set) var attemptedPaneIDs: [String] = []
    private(set) var deliveredPaneIDs: [String] = []

    init(firstDeliveryBehavior: FirstDeliveryBehavior) {
        self.firstDeliveryBehavior = firstDeliveryBehavior
    }

    func responses() async -> AsyncStream<NotificationSelectionTarget> {
        AsyncStream { $0.finish() }
    }

    func requestAuthorization() async throws -> Bool { true }

    func settings() async -> NotificationSystemSettings { .authorized }

    func deliver(_ event: AttentionNotificationEvent, sound: Bool) async throws {
        attemptedPaneIDs.append(event.target.paneID)
        if attemptedPaneIDs.count == 1 {
            await firstAttemptSignal.signal()
            switch firstDeliveryBehavior {
            case .suspendUntilCancelled:
                try await Task.sleep(for: .seconds(30))
            case .throwSchedulingError:
                throw TestDeliveryError.scheduling
            }
        }
        deliveredPaneIDs.append(event.target.paneID)
    }

    func waitForFirstAttempt() async {
        await firstAttemptSignal.wait()
    }
}

private actor TestSignal {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isSignaled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        isSignaled = true
        let ownedWaiters = waiters
        waiters.removeAll()
        for waiter in ownedWaiters { waiter.resume() }
    }
}

private enum TestDeliveryError: Error {
    case scheduling
}

private func descriptor(_ name: String) -> SessionDescriptor {
    SessionDescriptor(
        id: .named(name),
        socketURL: URL(fileURLWithPath: "/tmp/\(name).sock")
    )
}

private func item(
    _ session: SessionDescriptor,
    _ paneID: String,
    _ status: AgentStatus,
    title: String? = nil
) -> AgentMenuItem {
    AgentMenuItem(
        session: session,
        pane: PaneInfo(
            paneID: paneID,
            terminalID: "terminal-\(paneID)",
            workspaceID: "workspace-\(paneID)",
            tabID: "tab-\(paneID)",
            focused: false,
            label: "Pi",
            agent: "pi",
            title: title ?? paneID,
            displayAgent: "Pi",
            agentStatus: status,
            revision: 1
        )
    )
}

private func enabledPolicy(soundEnabled: Bool = false) -> NotificationDeliveryPolicy {
    NotificationDeliveryPolicy(notificationsEnabled: true, soundEnabled: soundEnabled)
}
