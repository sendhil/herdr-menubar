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
