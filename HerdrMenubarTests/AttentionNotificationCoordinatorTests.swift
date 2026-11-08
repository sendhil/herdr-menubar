import XCTest
@testable import HerdrMenubar

final class AttentionNotificationCoordinatorTests: XCTestCase {
    func testOverlappingDeliveriesRecordMonotonicSubmissionOrderAndKeepNewestTarget() async {
        let service = OverlappingNotificationService()
        let recorder = RecordingLatestNotificationTargetRecorder()
        let coordinator = AttentionNotificationCoordinator(
            service: service,
            latestTargetRecorder: recorder
        )
        let a = descriptor("a")
        let b = descriptor("b")
        let policy = enabledPolicy()

        await coordinator.reconcile(
            session: a,
            items: [item(a, "a1", .working), item(a, "a2", .working)],
            policy: policy
        )
        await coordinator.reconcile(
            session: b,
            items: [item(b, "b1", .working)],
            policy: policy
        )

        let aReconcile = Task {
            await coordinator.reconcile(
                session: a,
                items: [item(a, "a1", .blocked), item(a, "a2", .done)],
                policy: policy
            )
        }
        await service.waitForA1Attempt()

        await coordinator.reconcile(
            session: b,
            items: [item(b, "b1", .blocked)],
            policy: policy
        )
        await service.releaseA1()
        await aReconcile.value

        let attemptedPaneIDs = await service.attemptedPaneIDs
        let recorderCalls = await recorder.calls
        let latestTarget = await recorder.latest()
        XCTAssertEqual(attemptedPaneIDs, ["a1", "b1", "a2"])
        XCTAssertEqual(recorderCalls, [
            .init(target: target(b, "b1"), ordinal: 2),
            .init(target: target(a, "a1"), ordinal: 1),
            .init(target: target(a, "a2"), ordinal: 3)
        ])
        XCTAssertEqual(latestTarget, target(a, "a2"))
    }

    func testSuppressedDeliveryDoesNotRecordLatestTarget() async {
        let service = RecordingNotificationService(deliveryResult: .suppressed)
        let recorder = RecordingLatestNotificationTargetRecorder()
        let coordinator = AttentionNotificationCoordinator(
            service: service,
            latestTargetRecorder: recorder
        )
        let session = descriptor("work")

        await coordinator.reconcile(
            session: session,
            items: [item(session, "pane", .working)],
            policy: enabledPolicy()
        )
        await coordinator.reconcile(
            session: session,
            items: [item(session, "pane", .blocked)],
            policy: enabledPolicy()
        )

        let deliveredPaneIDs = await service.deliveries.map(\.event.target.paneID)
        let recorderCalls = await recorder.calls
        let latestTarget = await recorder.latest()
        XCTAssertEqual(deliveredPaneIDs, ["pane"])
        XCTAssertEqual(recorderCalls, [])
        XCTAssertNil(latestTarget)
    }

    func testFirstSnapshotForEverySessionIsSilent() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(
            service: service,
            latestTargetRecorder: RecordingLatestNotificationTargetRecorder()
        )
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
        let coordinator = AttentionNotificationCoordinator(
            service: service,
            latestTargetRecorder: RecordingLatestNotificationTargetRecorder()
        )
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
        let coordinator = AttentionNotificationCoordinator(
            service: service,
            latestTargetRecorder: RecordingLatestNotificationTargetRecorder()
        )
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
        let coordinator = AttentionNotificationCoordinator(
            service: service,
            latestTargetRecorder: RecordingLatestNotificationTargetRecorder()
        )
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
        let coordinator = AttentionNotificationCoordinator(
            service: service,
            latestTargetRecorder: RecordingLatestNotificationTargetRecorder()
        )
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
                target: SelectionTarget.herdr(.named("work"), paneID: "b"),
                sessionName: "work",
                visibleLabel: "Build tests · Pi",
                status: .done
            )
        ])
    }

    func testPaneDisappearanceRemovesHistoryAndAttentionReappearanceDelivers() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(
            service: service,
            latestTargetRecorder: RecordingLatestNotificationTargetRecorder()
        )
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
        let coordinator = AttentionNotificationCoordinator(
            service: service,
            latestTargetRecorder: RecordingLatestNotificationTargetRecorder()
        )
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
        let coordinator = AttentionNotificationCoordinator(
            service: service,
            latestTargetRecorder: RecordingLatestNotificationTargetRecorder()
        )
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

    func testCancellationAfterNoncooperativeFirstDeliverySucceedsStillStopsRemainingDeliveries() async {
        let service = ControlledNotificationService(firstDeliveryBehavior: .suspendUntilReleased)
        let recorder = RecordingLatestNotificationTargetRecorder()
        let coordinator = AttentionNotificationCoordinator(
            service: service,
            latestTargetRecorder: recorder
        )
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

        await service.waitForFirstDeliveryToSuspend()
        reconcileTask.cancel()
        await service.releaseFirstDelivery()
        await reconcileTask.value

        let attempts = await service.attemptedPaneIDs
        let delivered = await service.deliveredPaneIDs
        let recorderCalls = await recorder.calls
        let latestTarget = await recorder.latest()
        XCTAssertEqual(attempts, ["a"])
        XCTAssertEqual(delivered, ["a"])
        XCTAssertEqual(recorderCalls, [
            .init(target: target(session, "a"), ordinal: 1)
        ])
        XCTAssertEqual(latestTarget, target(session, "a"))
    }

    func testShuffledAttentionItemsDeliverInLabelOrderWithPaneIDTieBreaker() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(
            service: service,
            latestTargetRecorder: RecordingLatestNotificationTargetRecorder()
        )
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
        let coordinator = AttentionNotificationCoordinator(
            service: service,
            latestTargetRecorder: RecordingLatestNotificationTargetRecorder()
        )
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
        let coordinator = AttentionNotificationCoordinator(
            service: service,
            latestTargetRecorder: RecordingLatestNotificationTargetRecorder()
        )
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
            SelectionTarget.herdr(.default, paneID: "same"),
            SelectionTarget.herdr(.named("work"), paneID: "same")
        ])
        XCTAssertEqual(deliveries.map(\.event.status), [.done, .blocked])
    }

    func testUnavailableRetainsHistoryAndUnchangedReconnectIsSilent() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(
            service: service,
            latestTargetRecorder: RecordingLatestNotificationTargetRecorder()
        )
        let session = descriptor("work")
        let policy = enabledPolicy()

        await coordinator.reconcile(session: session, items: [item(session, "p", .working)], policy: policy)
        await coordinator.reconcile(session: session, items: [item(session, "p", .blocked)], policy: policy)
        await coordinator.unavailable(session: AgentSessionKey(herdr: session.id))
        await coordinator.reconcile(session: session, items: [item(session, "p", .blocked)], policy: policy)

        let deliveries = await service.deliveries
        XCTAssertEqual(deliveries.map(\.event.status), [.blocked])
    }

    func testRemovalClearsHistoryAndRecreatedSessionPrimesSilently() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(
            service: service,
            latestTargetRecorder: RecordingLatestNotificationTargetRecorder()
        )
        let session = descriptor("work")
        let policy = enabledPolicy()

        await coordinator.reconcile(session: session, items: [item(session, "p", .working)], policy: policy)
        await coordinator.reconcile(session: session, items: [item(session, "p", .blocked)], policy: policy)
        await coordinator.remove(session: AgentSessionKey(herdr: session.id))
        await coordinator.reconcile(session: session, items: [item(session, "p", .done)], policy: policy)

        let deliveries = await service.deliveries
        XCTAssertEqual(deliveries.map(\.event.status), [.blocked])
    }

    func testDisabledDeliveryStillAdvancesStatusHistory() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(
            service: service,
            latestTargetRecorder: RecordingLatestNotificationTargetRecorder()
        )
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
        let coordinator = AttentionNotificationCoordinator(
            service: service,
            latestTargetRecorder: RecordingLatestNotificationTargetRecorder()
        )
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
        let coordinator = AttentionNotificationCoordinator(
            service: service,
            latestTargetRecorder: RecordingLatestNotificationTargetRecorder()
        )
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

    func testEpochChangeRenotifiesEvenWhenStateRepeats() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(
            service: service, latestTargetRecorder: RecordingLatestNotificationTargetRecorder()
        )
        let session = rexSession()
        let policy = rexPolicy([.blocked, .error, .done])

        await coordinator.reconcile(session: session, records: [], policy: policy)
        await coordinator.reconcile(session: session, records: [rexRecord(session, epoch: 1, state: .done)], policy: policy)
        await coordinator.reconcile(session: session, records: [rexRecord(session, epoch: 1, state: .done)], policy: policy)
        await coordinator.reconcile(session: session, records: [rexRecord(session, epoch: 3, state: .done)], policy: policy)

        let deliveries = await service.deliveries
        XCTAssertEqual(deliveries.map(\.event.status), [.done, .done])
    }

    func testStaleErrorThatStaysPresentNeverRenotifies() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(
            service: service, latestTargetRecorder: RecordingLatestNotificationTargetRecorder()
        )
        let session = rexSession()
        let policy = rexPolicy([.blocked, .error])
        let staleError = rexRecord(session, epoch: 1, state: .error)

        await coordinator.reconcile(session: session, records: [], policy: policy)
        await coordinator.reconcile(session: session, records: [staleError], policy: policy)
        await coordinator.reconcile(
            session: session,
            records: [staleError, rexRecord(session, id: "child", epoch: 2, state: .blocked)],
            policy: policy
        )
        await coordinator.reconcile(session: session, records: [staleError], policy: policy)

        let deliveries = await service.deliveries
        XCTAssertEqual(deliveries.map(\.event.status), [.error, .blocked])
    }

    func testDroppedAndRecreatedRecordRenotifies() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(
            service: service, latestTargetRecorder: RecordingLatestNotificationTargetRecorder()
        )
        let session = rexSession()
        let policy = rexPolicy([.error])

        await coordinator.reconcile(session: session, records: [], policy: policy)
        await coordinator.reconcile(session: session, records: [rexRecord(session, epoch: 1, state: .error)], policy: policy)
        await coordinator.reconcile(session: session, records: [], policy: policy)
        await coordinator.reconcile(session: session, records: [rexRecord(session, epoch: 4, state: .error)], policy: policy)
        await coordinator.reconcile(session: session, records: [], policy: policy)
        await coordinator.reconcile(session: session, records: [rexRecord(session, epoch: 4, state: .error)], policy: policy)

        let deliveries = await service.deliveries
        XCTAssertEqual(deliveries.map(\.event.status), [.error, .error, .error])
    }

    func testUncheckedStateUpdatesHistoryWithoutLaterReplay() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(
            service: service, latestTargetRecorder: RecordingLatestNotificationTargetRecorder()
        )
        let session = rexSession()

        await coordinator.reconcile(session: session, records: [], policy: rexPolicy([.blocked]))
        await coordinator.reconcile(
            session: session, records: [rexRecord(session, epoch: 1, state: .error)], policy: rexPolicy([.blocked])
        )
        await coordinator.reconcile(
            session: session, records: [rexRecord(session, epoch: 1, state: .error)], policy: rexPolicy([.blocked, .error])
        )
        await coordinator.reconcile(
            session: session, records: [rexRecord(session, epoch: 2, state: .error)], policy: rexPolicy([.blocked, .error])
        )

        let deliveries = await service.deliveries
        XCTAssertEqual(deliveries.map(\.event.status), [.error])
    }

    func testCandidatesDeliverInGivenOrderNotLabelOrder() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(
            service: service, latestTargetRecorder: RecordingLatestNotificationTargetRecorder()
        )
        let session = rexSession()
        let policy = rexPolicy([.blocked])

        await coordinator.reconcile(session: session, records: [], policy: policy)
        await coordinator.reconcile(session: session, records: [
            rexRecord(session, block: "z", epoch: 1, state: .blocked, label: "Zulu"),
            rexRecord(session, block: "a", epoch: 2, state: .blocked, label: "Alpha")
        ], policy: policy)

        let deliveries = await service.deliveries
        XCTAssertEqual(deliveries.map(\.event.target.paneID), ["z", "a"])
        XCTAssertEqual(deliveries.map(\.event.sessionName), ["fix-playback", "fix-playback"])
        XCTAssertEqual(deliveries.map(\.event.target.sessionDisplayName), ["fix-playback", "fix-playback"])
    }

    func testFirstBlockedAfterEmptyConnectedBaselineNotifies() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(
            service: service, latestTargetRecorder: RecordingLatestNotificationTargetRecorder()
        )
        let session = rexSession()
        let policy = rexPolicy([.blocked, .error])

        await coordinator.reconcile(session: session, records: [], policy: policy)
        await coordinator.reconcile(session: session, records: [rexRecord(session, epoch: 1, state: .blocked)], policy: policy)

        let deliveries = await service.deliveries
        XCTAssertEqual(deliveries.map(\.event.status), [.blocked])
    }

    func testRestartReconciliationNotifiesOnlyChangedRecords() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(
            service: service, latestTargetRecorder: RecordingLatestNotificationTargetRecorder()
        )
        let session = rexSession()
        let policy = rexPolicy([.blocked, .error])

        await coordinator.reconcile(session: session, records: [
            rexRecord(session, block: "b1", epoch: 1, state: .blocked),
            rexRecord(session, block: "b2", epoch: 2, state: .error)
        ], policy: policy)
        await coordinator.unavailable(session: session.key)
        await coordinator.reconcile(session: session, records: [
            rexRecord(session, block: "b1", epoch: 1, state: .blocked),
            rexRecord(session, block: "b2", epoch: 5, state: .error)
        ], policy: policy)

        let deliveries = await service.deliveries
        XCTAssertEqual(deliveries.map(\.event.target.paneID), ["b2"])
    }

    func testHerdrNotifyStatesFilterHerdrDeliveries() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(
            service: service, latestTargetRecorder: RecordingLatestNotificationTargetRecorder()
        )
        let session = descriptor("work")
        let policy = NotificationDeliveryPolicy(
            notificationsEnabled: true,
            soundEnabled: false,
            notifyStates: [.herdr: [.blocked], .rex: [.blocked, .error]]
        )

        await coordinator.reconcile(
            session: session, items: [item(session, "a", .working), item(session, "b", .working)], policy: policy
        )
        await coordinator.reconcile(
            session: session, items: [item(session, "a", .done), item(session, "b", .blocked)], policy: policy
        )

        let deliveries = await service.deliveries
        XCTAssertEqual(deliveries.map(\.event.target.paneID), ["b"])
    }

    func testBackendMissingFromNotifyStatesFallsBackToItsDefaultStates() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(
            service: service, latestTargetRecorder: RecordingLatestNotificationTargetRecorder()
        )
        let herdr = descriptor("work")
        let rex = rexSession()
        let policy = NotificationDeliveryPolicy(notificationsEnabled: true, soundEnabled: false, notifyStates: [:])

        await coordinator.reconcile(
            session: herdr, items: [item(herdr, "a", .working), item(herdr, "b", .working)], policy: policy
        )
        await coordinator.reconcile(
            session: herdr, items: [item(herdr, "a", .done), item(herdr, "b", .blocked)], policy: policy
        )
        await coordinator.reconcile(session: rex, records: [], policy: policy)
        await coordinator.reconcile(session: rex, records: [
            rexRecord(rex, block: "r1", epoch: 1, state: .blocked, label: "A"),
            rexRecord(rex, block: "r2", epoch: 1, state: .error, label: "B"),
            rexRecord(rex, block: "r3", epoch: 1, state: .done, label: "C")
        ], policy: policy)

        let deliveries = await service.deliveries
        XCTAssertEqual(Set(deliveries.prefix(2).map(\.event.target.paneID)), ["a", "b"])
        XCTAssertEqual(deliveries.dropFirst(2).map(\.event.target.paneID), ["r1", "r2"])
    }
}

private actor RecordingNotificationService: NativeNotificationServing {
    struct Delivery: Equatable, Sendable {
        let event: AttentionNotificationEvent
        let sound: Bool
    }

    private(set) var deliveries: [Delivery] = []
    private let deliveryResult: NotificationDeliveryResult

    init(deliveryResult: NotificationDeliveryResult = .accepted) {
        self.deliveryResult = deliveryResult
    }

    func responses() async -> NotificationResponseSubscription {
        .finished()
    }

    func requestAuthorization() async throws -> Bool { true }

    func settings() async -> NotificationSystemSettings { .authorized }

    func deliver(
        _ event: AttentionNotificationEvent,
        sound: Bool
    ) async throws -> NotificationDeliveryResult {
        deliveries.append(Delivery(event: event, sound: sound))
        return deliveryResult
    }
}

private actor OverlappingNotificationService: NativeNotificationServing {
    private let a1Attempted = TestSignal()
    private let a1Gate = NoncooperativeDeliveryGate()
    private(set) var attemptedPaneIDs: [String] = []

    func responses() async -> NotificationResponseSubscription { .finished() }

    func requestAuthorization() async throws -> Bool { true }

    func settings() async -> NotificationSystemSettings { .authorized }

    func deliver(
        _ event: AttentionNotificationEvent,
        sound: Bool
    ) async throws -> NotificationDeliveryResult {
        attemptedPaneIDs.append(event.target.paneID)
        if event.target.paneID == "a1" {
            await a1Attempted.signal()
            await a1Gate.suspend()
        }
        return .accepted
    }

    func waitForA1Attempt() async {
        await a1Attempted.wait()
        await a1Gate.waitUntilSuspended()
    }

    func releaseA1() async {
        await a1Gate.release()
    }
}

private actor RecordingLatestNotificationTargetRecorder: LatestNotificationTargetRecording {
    struct Call: Equatable, Sendable {
        let target: SelectionTarget
        let ordinal: UInt64
    }

    private(set) var calls: [Call] = []
    private var latestEntry: Call?

    func record(_ target: SelectionTarget, ordinal: UInt64) {
        let call = Call(target: target, ordinal: ordinal)
        calls.append(call)
        guard latestEntry == nil || ordinal > latestEntry!.ordinal else { return }
        latestEntry = call
    }

    func latest() -> SelectionTarget? {
        latestEntry?.target
    }

    func reset() {
        latestEntry = nil
    }

    func sealAndReset() {
        latestEntry = nil
    }
}

private actor ControlledNotificationService: NativeNotificationServing {
    enum FirstDeliveryBehavior: Sendable {
        case suspendUntilCancelled
        case suspendUntilReleased
        case throwSchedulingError
    }

    private let firstDeliveryBehavior: FirstDeliveryBehavior
    private let firstAttemptSignal = TestSignal()
    private let noncooperativeGate = NoncooperativeDeliveryGate()
    private(set) var attemptedPaneIDs: [String] = []
    private(set) var deliveredPaneIDs: [String] = []

    init(firstDeliveryBehavior: FirstDeliveryBehavior) {
        self.firstDeliveryBehavior = firstDeliveryBehavior
    }

    func responses() async -> NotificationResponseSubscription {
        .finished()
    }

    func requestAuthorization() async throws -> Bool { true }

    func settings() async -> NotificationSystemSettings { .authorized }

    func deliver(
        _ event: AttentionNotificationEvent,
        sound: Bool
    ) async throws -> NotificationDeliveryResult {
        attemptedPaneIDs.append(event.target.paneID)
        if attemptedPaneIDs.count == 1 {
            await firstAttemptSignal.signal()
            switch firstDeliveryBehavior {
            case .suspendUntilCancelled:
                try await Task.sleep(for: .seconds(30))
            case .suspendUntilReleased:
                await noncooperativeGate.suspend()
            case .throwSchedulingError:
                throw TestDeliveryError.scheduling
            }
        }
        deliveredPaneIDs.append(event.target.paneID)
        return .accepted
    }

    func waitForFirstAttempt() async {
        await firstAttemptSignal.wait()
    }

    func waitForFirstDeliveryToSuspend() async {
        await noncooperativeGate.waitUntilSuspended()
    }

    func releaseFirstDelivery() async {
        await noncooperativeGate.release()
    }
}

private actor NoncooperativeDeliveryGate {
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var isSuspended = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
            isSuspended = true
            let ownedWaiters = suspensionWaiters
            suspensionWaiters.removeAll()
            for waiter in ownedWaiters { waiter.resume() }
        }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { suspensionWaiters.append($0) }
    }

    func release() {
        let continuation = releaseContinuation
        releaseContinuation = nil
        continuation?.resume()
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
) -> PaneInfo {
    PaneInfo(
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
}

private func target(
    _ session: SessionDescriptor,
    _ paneID: String
) -> SelectionTarget {
    SelectionTarget.herdr(session.id, paneID: paneID)
}

private func enabledPolicy(soundEnabled: Bool = false) -> NotificationDeliveryPolicy {
    NotificationDeliveryPolicy(notificationsEnabled: true, soundEnabled: soundEnabled)
}

private func rexSession() -> AgentSessionDescriptor {
    AgentSessionDescriptor(key: AgentSessionKey(backend: .rex, rawID: "s1"), displayName: "fix-playback")
}

private func rexRecord(
    _ session: AgentSessionDescriptor,
    block: String = "b1",
    id: String = "",
    epoch: Int,
    state: AttentionState,
    label: String = "Review · claude-code"
) -> AttentionRecord {
    AttentionRecord(
        target: AgentTarget(session: session.key, paneID: block),
        recordID: id,
        epoch: epoch,
        state: state,
        visibleLabel: label,
        message: nil
    )
}

private func rexPolicy(_ states: Set<AttentionState>) -> NotificationDeliveryPolicy {
    NotificationDeliveryPolicy(
        notificationsEnabled: true,
        soundEnabled: false,
        notifyStates: [.herdr: [.blocked, .done], .rex: states]
    )
}
