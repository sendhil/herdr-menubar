import Foundation
import XCTest
@testable import HerdrMenubar

@MainActor
final class AgentStoreTests: XCTestCase {
    func testIdenticalPaneIDsInTwoSessionsProduceDistinctCompositeIDs() async {
        let supervisor = FakeSessionSupervisor()
        let store = makeStore(supervisor: supervisor)
        await store.start()

        await supervisor.send(.connected(defaultDescriptor, snapshot([pane("same", .done)])))
        await supervisor.send(.connected(workDescriptor, snapshot([pane("same", .working)])))
        await eventually { store.attentionCount == 1 && store.workingSections.count == 1 }

        let items = store.attentionSections.flatMap(\.items) + store.workingSections.flatMap(\.items)
        XCTAssertEqual(Set(items.map(\.id)), [
            AgentMenuItemID(sessionID: .default, paneID: "same"),
            AgentMenuItemID(sessionID: .named("work"), paneID: "same")
        ])
        await store.stop()
    }

    func testAggregatesAttentionAndGroupsStatusThenSession() async {
        let supervisor = FakeSessionSupervisor()
        let store = makeStore(supervisor: supervisor)
        await store.start()
        await supervisor.send(.connected(workDescriptor, snapshot([
            pane("work-done", .done), pane("work-active", .working)
        ])))
        await supervisor.send(.connected(defaultDescriptor, snapshot([
            pane("default-blocked", .blocked), pane("default-active", .working)
        ])))
        await eventually { store.attentionCount == 2 && store.workingSections.count == 2 }

        XCTAssertEqual(store.attentionSections.map(\.id), [.default, .named("work")])
        XCTAssertEqual(store.attentionSections.map { $0.items.map(\.paneID) }, [["default-blocked"], ["work-done"]])
        XCTAssertEqual(store.workingSections.map(\.id), [.default, .named("work")])
        XCTAssertEqual(store.attentionCount, 2)
        await store.stop()
    }

    func testSortsDefaultBeforeNamedSessionsAndRowsWithinSession() async {
        let alpha = descriptor("alpha")
        let zulu = descriptor("Zulu")
        let supervisor = FakeSessionSupervisor()
        let store = makeStore(supervisor: supervisor)
        await store.start()
        await supervisor.send(.connected(zulu, snapshot([pane("done", .done, title: "A")])))
        await supervisor.send(.connected(alpha, snapshot([
            pane("done-z", .done, title: "Zulu"),
            pane("blocked-z", .blocked, title: "zulu"),
            pane("blocked-a2", .blocked, title: "Alpha"),
            pane("blocked-a1", .blocked, title: "alpha")
        ])))
        await supervisor.send(.connected(defaultDescriptor, snapshot([pane("default", .done)])))
        await eventually { store.attentionCount == 6 }

        XCTAssertEqual(store.attentionSections.map(\.id), [.default, .named("alpha"), .named("Zulu")])
        XCTAssertEqual(
            store.attentionSections.first { $0.id == .named("alpha") }?.items.map(\.paneID),
            ["blocked-a1", "blocked-a2", "blocked-z", "done-z"]
        )
        await store.stop()
    }

    func testCaseFoldEquivalentSessionNamesUseStableSessionIDTieBreaker() async {
        let upper = descriptor("Alpha")
        let lower = descriptor("alpha")
        let supervisor = FakeSessionSupervisor()
        let store = makeStore(supervisor: supervisor)
        await store.start()
        await supervisor.send(.connected(lower, snapshot([pane("lower", .done)])))
        await supervisor.send(.connected(upper, snapshot([pane("upper", .done)])))
        await eventually { store.attentionCount == 2 }

        XCTAssertEqual(store.attentionSections.map(\.id), [.named("Alpha"), .named("alpha")])
        await store.stop()
    }

    func testUnavailableClearsOnlyOwningSessionAndKeepsAggregateConnected() async {
        let supervisor = FakeSessionSupervisor()
        let store = makeStore(supervisor: supervisor)
        await store.start()
        await supervisor.send(.connected(defaultDescriptor, snapshot([pane("default", .done)])))
        await supervisor.send(.connected(workDescriptor, snapshot([pane("work", .done)])))
        await eventually { store.attentionCount == 2 }

        await supervisor.send(.unavailable(.named("work"), "socket unavailable"))
        await eventually { store.attentionCount == 1 && store.unavailableSessions.count == 1 }

        XCTAssertEqual(store.connectionState, .connected)
        XCTAssertEqual(store.attentionSections.map(\.id), [.default])
        XCTAssertEqual(store.unavailableSessions, [UnavailableSession(session: workDescriptor, message: "socket unavailable")])
        await store.stop()
    }

    func testEmptyDiscoveryAndConnectingStatesAreDistinct() async {
        let supervisor = FakeSessionSupervisor()
        let store = makeStore(supervisor: supervisor)
        XCTAssertEqual(store.connectionState, .searching)
        await store.start()

        await supervisor.send(.discoverySnapshot([]))
        await eventually { store.connectionState == .noSessions }
        await supervisor.send(.discoverySnapshot([workDescriptor]))
        await eventually { store.connectionState == .connecting }
        await store.stop()
    }

    func testGraceEntryRemainsUntilRemovedEvent() async {
        let supervisor = FakeSessionSupervisor()
        let store = makeStore(supervisor: supervisor)
        await store.start()
        await supervisor.send(.connected(workDescriptor, snapshot([pane("work", .done)])))
        await eventually { store.attentionCount == 1 }
        await supervisor.send(.unavailable(.named("work"), "Session socket unavailable"))
        await eventually { store.unavailableSessions.count == 1 }

        await supervisor.send(.discoverySnapshot([]))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(store.unavailableSessions.map(\.id), [.named("work")])

        await supervisor.send(.removed(.named("work")))
        await eventually { store.unavailableSessions.isEmpty && store.connectionState == .noSessions }
        await store.stop()
    }

    func testOnlyAcceptedFullSnapshotsReachNotificationCoordinatorInAuthoritativeOrder() async {
        let supervisor = FakeSessionSupervisor()
        let coordinator = RecordingAttentionCoordinator()
        let notifications = RecordingNotificationService()
        let preferences = testPreferences()
        preferences.notificationsEnabled = true
        let store = makeStore(
            supervisor: supervisor,
            attentionCoordinator: coordinator,
            notificationService: notifications,
            preferences: preferences
        )
        await store.start()

        await supervisor.send(.connected(workDescriptor, snapshot([
            pane("idle", .idle), pane("unknown", .unknown), pane("blocked", .blocked)
        ])))
        await supervisor.send(.snapshot(.named("work"), snapshot([
            pane("working", .working), pane("done", .done)
        ])))
        await waitUntil { await coordinator.reconciliations.count == 2 }

        let calls = await coordinator.reconciliations
        XCTAssertEqual(calls.map { $0.items.map(\.paneID) }, [
            ["idle", "unknown", "blocked"], ["working", "done"]
        ])
        XCTAssertEqual(calls.map(\.policy), [
            NotificationDeliveryPolicy(notificationsEnabled: true, soundEnabled: false),
            NotificationDeliveryPolicy(notificationsEnabled: true, soundEnabled: false)
        ])
        XCTAssertEqual(store.attentionSections.flatMap(\.items).map(\.paneID), ["done"])
        XCTAssertEqual(store.workingSections.flatMap(\.items).map(\.paneID), ["working"])

        await supervisor.send(.snapshot(.default, snapshot([pane("stale", .done)])))
        for _ in 0..<20 { await Task.yield() }
        var reconciliationCount = await coordinator.reconciliations.count
        XCTAssertEqual(reconciliationCount, 2)
        await store.stop()
        await supervisor.send(.snapshot(.named("work"), snapshot([pane("late", .done)])))
        for _ in 0..<20 { await Task.yield() }
        reconciliationCount = await coordinator.reconciliations.count
        let resetCount = await coordinator.resetCount
        XCTAssertEqual(reconciliationCount, 2)
        XCTAssertEqual(resetCount, 1)
    }

    func testUnavailablePreservesCoordinatorHistoryAndRemovedForgetsExactlyOnce() async {
        let supervisor = FakeSessionSupervisor()
        let coordinator = RecordingAttentionCoordinator()
        let focuser = RecordingWezTermFocuser()
        let store = makeStore(
            supervisor: supervisor,
            wezTermFocuser: focuser,
            attentionCoordinator: coordinator
        )
        await store.start()
        await supervisor.send(.connected(workDescriptor, snapshot([pane("p", .blocked)])))
        await supervisor.send(.unavailable(.named("work"), "temporarily unavailable"))
        await waitUntil { await coordinator.unavailableSessionIDs == [.named("work")] }

        let removedBeforeRemoval = await coordinator.removedSessionIDs
        XCTAssertTrue(removedBeforeRemoval.isEmpty)
        XCTAssertTrue(focuser.forgottenSessionIDs.isEmpty)

        await supervisor.send(.removed(.named("work")))
        await waitUntil { await coordinator.removedSessionIDs == [.named("work")] }
        await eventually { focuser.forgottenSessionIDs == [.named("work")] }
        await supervisor.send(.removed(.named("work")))
        for _ in 0..<20 { await Task.yield() }
        let removedCount = await coordinator.removedSessionIDs.count
        XCTAssertEqual(removedCount, 1)
        XCTAssertEqual(focuser.forgottenSessionIDs.count, 1)
        await store.stop()
    }

    func testWezTermSelectionFocusesHerdrThenTabThenAppThenRefreshes() async {
        let sequence = ActionSequence()
        let supervisor = FakeSessionSupervisor(sequence: sequence)
        let focuser = RecordingWezTermFocuser(sequence: sequence)
        let activator = RecordingActivator(sequence: sequence)
        let store = makeStore(
            supervisor: supervisor,
            terminalActivator: activator,
            wezTermFocuser: focuser,
            preferences: testPreferences()
        )
        let item = AgentMenuItem(session: workDescriptor, pane: pane("p", .blocked))

        await store.select(item)

        let actions = await sequence.values
        let focusRequests = await supervisor.focusRequests
        let refreshRequests = await supervisor.refreshRequests
        XCTAssertEqual(actions, [
            "focus:work:p", "wezterm:work", "activate:com.github.wez.wezterm", "refresh:work"
        ])
        XCTAssertEqual(focusRequests, [FocusRequest(sessionID: .named("work"), paneID: "p")])
        XCTAssertEqual(focuser.focusedSessionIDs, [.named("work")])
        XCTAssertEqual(refreshRequests, [.named("work")])
    }

    func testNonWezTermSelectionSkipsAdapterAndPreservesGenericActivation() async {
        let sequence = ActionSequence()
        let supervisor = FakeSessionSupervisor(sequence: sequence)
        let focuser = RecordingWezTermFocuser(sequence: sequence)
        let activator = RecordingActivator(sequence: sequence)
        let store = makeStore(
            supervisor: supervisor,
            terminalActivator: activator,
            wezTermFocuser: focuser,
            preferences: testPreferences(bundleIdentifier: "com.mitchellh.ghostty")
        )

        await store.select(AgentMenuItem(session: workDescriptor, pane: pane("p", .working)))

        let actions = await sequence.values
        let refreshRequests = await supervisor.refreshRequests
        XCTAssertEqual(actions, [
            "focus:work:p", "activate:com.mitchellh.ghostty", "refresh:work"
        ])
        XCTAssertTrue(focuser.focusedSessionIDs.isEmpty)
        XCTAssertEqual(refreshRequests, [.named("work")])
    }

    func testHerdrFocusFailureSkipsAdapterActivationAndRefresh() async {
        let supervisor = FakeSessionSupervisor(
            focusError: HerdrAPIError(code: "pane_not_found", message: "Pane no longer exists")
        )
        let focuser = RecordingWezTermFocuser()
        let activator = RecordingActivator()
        let store = makeStore(
            supervisor: supervisor,
            terminalActivator: activator,
            wezTermFocuser: focuser,
            preferences: testPreferences()
        )

        await store.select(AgentMenuItem(session: workDescriptor, pane: pane("p", .blocked)))

        XCTAssertEqual(activator.activationCount, 0)
        XCTAssertTrue(focuser.focusedSessionIDs.isEmpty)
        let refreshRequests = await supervisor.refreshRequests
        XCTAssertEqual(refreshRequests, [])
        XCTAssertEqual(store.transientError, "Could not focus pane in work: Pane no longer exists")
    }

    func testNoAttachedTabShowsPartialErrorAndStillRefreshesOwningSession() async {
        for error in [WezTermFocusError.noAttachedClient, .lookupTimedOut] {
            await assertAdapterFailure(
                error,
                expectedMessage: "Focused the pane in work, but no attached WezTerm tab was found."
            )
        }
    }

    func testUnsupportedHerdrShowsUpdateErrorAndStillRefreshes() async {
        await assertAdapterFailure(
            .unsupportedHerdr,
            expectedMessage: "Focused the pane in work, but this Herdr session must be updated for WezTerm tab focus."
        )
    }

    func testWezTermControlFailureStillRefreshesOnce() async {
        for error in [
            WezTermFocusError.wezTermUnavailable,
            .wezTermControlFailed,
            .ambiguousMarker
        ] {
            await assertAdapterFailure(
                error,
                expectedMessage: "Focused the pane in work, but WezTerm could not be controlled."
            )
        }
        await assertAdapterFailure(
            .markerCleanupFailed,
            expectedMessage: "Focused the pane in work, but the temporary WezTerm focus marker could not be cleared."
        )
    }

    func testMacOSActivationFailureStillRefreshesOnce() async {
        let sequence = ActionSequence()
        let supervisor = FakeSessionSupervisor(sequence: sequence)
        let focuser = RecordingWezTermFocuser(sequence: sequence)
        let activator = RecordingActivator(error: TestFailure.activation, sequence: sequence)
        let store = makeStore(
            supervisor: supervisor,
            terminalActivator: activator,
            wezTermFocuser: focuser,
            preferences: testPreferences()
        )

        await store.select(AgentMenuItem(session: workDescriptor, pane: pane("p", .done)))

        let actions = await sequence.values
        let refreshRequests = await supervisor.refreshRequests
        XCTAssertEqual(actions, [
            "focus:work:p", "wezterm:work", "activate:com.github.wez.wezterm", "refresh:work"
        ])
        XCTAssertEqual(refreshRequests, [.named("work")])
        XCTAssertNotNil(store.transientError)
    }

    func testBufferedNotificationClickWaitsForConnectionThenUsesExactSelectionFlow() async {
        let sequence = ActionSequence()
        let supervisor = FakeSessionSupervisor(sequence: sequence)
        let notifications = RecordingNotificationService()
        let store = makeStore(
            supervisor: supervisor,
            terminalActivator: RecordingActivator(sequence: sequence),
            wezTermFocuser: RecordingWezTermFocuser(sequence: sequence),
            notificationService: notifications
        )
        await notifications.send(NotificationSelectionTarget(
            sessionID: .named("work"), paneID: "p"
        ))
        await store.start()
        await supervisor.send(.discoverySnapshot([workDescriptor]))
        for _ in 0..<20 { await Task.yield() }
        var focusRequests = await supervisor.focusRequests
        XCTAssertEqual(focusRequests, [])

        await supervisor.send(.connected(workDescriptor, snapshot([pane("p", .done)])))
        await waitUntil { await supervisor.refreshRequests.count == 1 }
        focusRequests = await supervisor.focusRequests
        let actions = await sequence.values
        XCTAssertEqual(focusRequests, [
            FocusRequest(sessionID: .named("work"), paneID: "p")
        ])
        XCTAssertEqual(actions, [
            "focus:work:p", "wezterm:work", "activate:com.github.wez.wezterm", "refresh:work"
        ])
        await store.stop()
    }

    func testNotificationTargetWaitsAcrossUnavailableAndSelectsOnReconnect() async {
        let supervisor = FakeSessionSupervisor()
        let notifications = RecordingNotificationService()
        let store = makeStore(supervisor: supervisor, notificationService: notifications)
        await store.start()
        await supervisor.send(.discoverySnapshot([workDescriptor]))
        await supervisor.send(.unavailable(.named("work"), "temporarily unavailable"))
        await notifications.send(NotificationSelectionTarget(
            sessionID: .named("work"), paneID: "stale-pane"
        ))
        for _ in 0..<20 { await Task.yield() }
        var focusRequests = await supervisor.focusRequests
        XCTAssertEqual(focusRequests, [])

        await supervisor.send(.connected(workDescriptor, snapshot([pane("different", .working)])))
        await waitUntil { await supervisor.focusRequests.count == 1 }
        focusRequests = await supervisor.focusRequests
        XCTAssertEqual(focusRequests, [
            FocusRequest(sessionID: .named("work"), paneID: "stale-pane")
        ])
        await store.stop()
    }

    func testNotificationTargetIsAbandonedWhenCompletedDiscoveryOmitsSession() async {
        let supervisor = FakeSessionSupervisor()
        let notifications = RecordingNotificationService()
        let store = makeStore(supervisor: supervisor, notificationService: notifications)
        await notifications.send(NotificationSelectionTarget(
            sessionID: .named("work"), paneID: "p"
        ))
        await store.start()
        await supervisor.send(.discoverySnapshot([]))
        await eventually { store.transientError == "work is unavailable" }

        await supervisor.send(.connected(workDescriptor, snapshot([pane("p", .done)])))
        for _ in 0..<20 { await Task.yield() }
        let focusRequests = await supervisor.focusRequests
        XCTAssertEqual(focusRequests, [])
        await store.stop()
    }

    func testMatchingRemovalAbandonsPendingNotificationTarget() async {
        let supervisor = FakeSessionSupervisor()
        let notifications = RecordingNotificationService()
        let store = makeStore(supervisor: supervisor, notificationService: notifications)
        await store.start()
        await supervisor.send(.discoverySnapshot([workDescriptor]))
        await notifications.send(NotificationSelectionTarget(
            sessionID: .named("work"), paneID: "p"
        ))
        await supervisor.send(.removed(.named("work")))
        await supervisor.send(.connected(workDescriptor, snapshot([pane("p", .done)])))
        for _ in 0..<50 { await Task.yield() }

        let focusRequests = await supervisor.focusRequests
        XCTAssertEqual(focusRequests, [])
        await store.stop()
    }

    func testMenuSelectionClearsOlderPendingNotificationTarget() async {
        let supervisor = FakeSessionSupervisor()
        let notifications = RecordingNotificationService()
        let store = makeStore(supervisor: supervisor, notificationService: notifications)
        await store.start()
        await notifications.send(NotificationSelectionTarget(
            sessionID: .named("work"), paneID: "old"
        ))
        await waitUntil { await notifications.deliveredResponseCount == 1 }
        await store.select(AgentMenuItem(
            session: defaultDescriptor, pane: pane("new", .working)
        ))
        await supervisor.send(.connected(workDescriptor, snapshot([pane("old", .done)])))
        for _ in 0..<50 { await Task.yield() }

        let focusRequests = await supervisor.focusRequests
        XCTAssertEqual(focusRequests, [
            FocusRequest(sessionID: .default, paneID: "new")
        ])
        await store.stop()
    }

    func testNewerNotificationSelectionSupersedesBlockedMenuSelection() async {
        let sequence = ActionSequence()
        let supervisor = FakeSessionSupervisor(sequence: sequence)
        let focuser = RecordingWezTermFocuser(
            sequence: sequence, blockedCalls: [1], checksCancellationAfterGate: false
        )
        let activator = RecordingActivator(sequence: sequence)
        let notifications = RecordingNotificationService()
        let store = makeStore(
            supervisor: supervisor,
            terminalActivator: activator,
            wezTermFocuser: focuser,
            notificationService: notifications
        )
        await store.start()
        await supervisor.send(.connected(defaultDescriptor, snapshot([pane("new", .done)])))
        let oldSelection = Task {
            await store.select(AgentMenuItem(session: workDescriptor, pane: pane("old", .working)))
        }
        await eventually { focuser.focusedSessionIDs.count == 1 }

        await notifications.send(NotificationSelectionTarget(sessionID: .default, paneID: "new"))
        await waitUntil { await notifications.deliveredResponseCount == 1 }
        await focuser.releaseBlockedCalls()
        await oldSelection.value
        await waitUntil { await supervisor.refreshRequests.count == 2 }

        let refreshRequests = await supervisor.refreshRequests
        XCTAssertEqual(activator.activatedBundleIdentifiers, [WezTermCLIConstants.bundleIdentifier])
        XCTAssertEqual(refreshRequests, [.named("work"), .default])
        XCTAssertNil(store.transientError)
        await store.stop()
    }

    func testStaleNotificationPaneUsesExactTargetAndSurfacesHerdrFailure() async {
        let supervisor = FakeSessionSupervisor(
            focusError: HerdrAPIError(code: "pane_not_found", message: "Pane no longer exists")
        )
        let notifications = RecordingNotificationService()
        let activator = RecordingActivator()
        let store = makeStore(
            supervisor: supervisor,
            terminalActivator: activator,
            notificationService: notifications
        )
        await store.start()
        await supervisor.send(.connected(workDescriptor, snapshot([pane("current", .done)])))
        await notifications.send(NotificationSelectionTarget(
            sessionID: .named("work"), paneID: "stale"
        ))
        await waitUntil { await supervisor.focusRequests.count == 1 }

        let focusRequests = await supervisor.focusRequests
        XCTAssertEqual(focusRequests, [
            FocusRequest(sessionID: .named("work"), paneID: "stale")
        ])
        XCTAssertEqual(activator.activationCount, 0)
        XCTAssertEqual(store.transientError, "Could not focus pane in work: Pane no longer exists")
        await store.stop()
    }

    func testMenuSelectionSupersedesInFlightNotificationWithoutStaleActivationOrError() async {
        let sequence = ActionSequence()
        let supervisor = FakeSessionSupervisor(sequence: sequence)
        let coordinator = RecordingAttentionCoordinator()
        let notifications = RecordingNotificationService()
        let focuser = RecordingWezTermFocuser(
            sequence: sequence,
            results: [.failure(WezTermFocusError.noAttachedClient), .success(())],
            blockedCalls: [1],
            checksCancellationAfterGate: false
        )
        let activator = RecordingActivator(sequence: sequence)
        let store = makeStore(
            supervisor: supervisor,
            terminalActivator: activator,
            wezTermFocuser: focuser,
            attentionCoordinator: coordinator,
            notificationService: notifications
        )
        await store.start()
        await supervisor.send(.connected(workDescriptor, snapshot([pane("p1", .done)])))
        await supervisor.send(.connected(defaultDescriptor, snapshot([pane("p2", .done)])))
        await coordinator.waitForReconciliations(2)

        await notifications.send(NotificationSelectionTarget(
            sessionID: .named("work"), paneID: "p1"
        ))
        await focuser.waitForCalls(1)

        let menuSelection = Task {
            await store.select(AgentMenuItem(
                session: defaultDescriptor, pane: pane("p2", .done)
            ))
        }
        await focuser.waitForCancellations(1)
        XCTAssertTrue(activator.activatedBundleIdentifiers.isEmpty)

        await focuser.releaseBlockedCalls()
        await menuSelection.value
        await supervisor.waitForRefreshRequests(2)

        let focusRequests = await supervisor.focusRequests
        let refreshRequests = await supervisor.refreshRequests
        let actions = await sequence.values
        XCTAssertEqual(focusRequests, [
            FocusRequest(sessionID: .named("work"), paneID: "p1"),
            FocusRequest(sessionID: .default, paneID: "p2")
        ])
        XCTAssertEqual(refreshRequests, [.named("work"), .default])
        XCTAssertEqual(actions, [
            "focus:work:p1", "wezterm:work", "refresh:work",
            "focus:Default:p2", "wezterm:Default",
            "activate:com.github.wez.wezterm", "refresh:Default"
        ])
        XCTAssertEqual(activator.activatedBundleIdentifiers, [
            WezTermCLIConstants.bundleIdentifier
        ])
        XCTAssertEqual(focuser.cancellationObservedSessionIDs, [.named("work")])
        XCTAssertNil(store.transientError)
        await store.stop()
    }

    func testStopAndRestartClearsPendingNotificationWhileFreshResponseStillSelects() async {
        let sequence = ActionSequence()
        let supervisor = FakeSessionSupervisor(sequence: sequence)
        let coordinator = RecordingAttentionCoordinator()
        let notifications = RecordingNotificationService()
        let focuser = RecordingWezTermFocuser(
            sequence: sequence,
            blockedCalls: [1],
            checksCancellationAfterGate: false
        )
        let activator = RecordingActivator(sequence: sequence)
        let store = makeStore(
            supervisor: supervisor,
            terminalActivator: activator,
            wezTermFocuser: focuser,
            attentionCoordinator: coordinator,
            notificationService: notifications
        )
        await store.start()

        let precedingSelection = Task {
            await store.select(AgentMenuItem(
                session: defaultDescriptor, pane: pane("pre", .working)
            ))
        }
        await focuser.waitForCalls(1)
        await notifications.send(NotificationSelectionTarget(
            sessionID: .named("work"), paneID: "p1"
        ))
        await focuser.waitForCancellations(1)
        await focuser.releaseBlockedCalls()
        await precedingSelection.value
        await supervisor.waitForRefreshRequests(1)
        var focusRequests = await supervisor.focusRequests
        XCTAssertEqual(focusRequests, [
            FocusRequest(sessionID: .default, paneID: "pre")
        ])

        await store.stop()
        await notifications.waitForCancellations(1)
        await store.start()
        await notifications.waitForResponseCalls(2)

        await supervisor.send(.discoverySnapshot([workDescriptor]))
        await supervisor.send(.connected(workDescriptor, snapshot([
            pane("p1", .done), pane("p2", .working)
        ])))
        await coordinator.waitForReconciliations(1)
        await coordinator.barrier()
        focusRequests = await supervisor.focusRequests
        XCTAssertEqual(focusRequests, [
            FocusRequest(sessionID: .default, paneID: "pre")
        ])
        XCTAssertTrue(activator.activatedBundleIdentifiers.isEmpty)

        await notifications.send(NotificationSelectionTarget(
            sessionID: .named("work"), paneID: "p2"
        ))
        await supervisor.waitForRefreshRequests(2)

        focusRequests = await supervisor.focusRequests
        let refreshRequests = await supervisor.refreshRequests
        XCTAssertEqual(focusRequests, [
            FocusRequest(sessionID: .default, paneID: "pre"),
            FocusRequest(sessionID: .named("work"), paneID: "p2")
        ])
        XCTAssertEqual(refreshRequests, [.default, .named("work")])
        XCTAssertEqual(activator.activatedBundleIdentifiers, [
            WezTermCLIConstants.bundleIdentifier
        ])
        XCTAssertNil(store.transientError)
        await store.stop()
        await notifications.waitForCancellations(2)
    }

    func testRapidSecondSelectionCancelsAndAwaitsFirstFinalization() async {
        let sequence = ActionSequence()
        let supervisor = FakeSessionSupervisor(sequence: sequence)
        let focuser = RecordingWezTermFocuser(sequence: sequence, blockedCalls: [1])
        let activator = RecordingActivator(sequence: sequence)
        let store = makeStore(
            supervisor: supervisor,
            terminalActivator: activator,
            wezTermFocuser: focuser,
            preferences: testPreferences()
        )
        let first = Task {
            await store.select(AgentMenuItem(session: workDescriptor, pane: pane("first", .working)))
        }
        await eventually { focuser.focusedSessionIDs.count == 1 }

        let second = Task {
            await store.select(AgentMenuItem(session: defaultDescriptor, pane: pane("second", .blocked)))
        }
        for _ in 0..<20 { await Task.yield() }
        let firstFocusRequests = await supervisor.focusRequests
        XCTAssertEqual(firstFocusRequests, [
            FocusRequest(sessionID: .named("work"), paneID: "first")
        ])

        await focuser.releaseBlockedCalls()
        await first.value
        await second.value

        let actions = await sequence.values
        XCTAssertEqual(actions, [
            "focus:work:first", "wezterm:work", "refresh:work",
            "focus:Default:second", "wezterm:Default",
            "activate:com.github.wez.wezterm", "refresh:Default"
        ])
        XCTAssertNil(store.transientError)
    }

    func testSupersededSuccessfulSelectionCannotActivateAndStillRefreshes() async {
        let sequence = ActionSequence()
        let supervisor = FakeSessionSupervisor(sequence: sequence)
        let focuser = RecordingWezTermFocuser(
            sequence: sequence,
            results: [.success(()), .success(())],
            blockedCalls: [1],
            checksCancellationAfterGate: false
        )
        let activator = RecordingActivator(sequence: sequence)
        let store = makeStore(
            supervisor: supervisor,
            terminalActivator: activator,
            wezTermFocuser: focuser,
            preferences: testPreferences()
        )
        let first = Task {
            await store.select(AgentMenuItem(session: workDescriptor, pane: pane("first", .working)))
        }
        await eventually { focuser.focusedSessionIDs.count == 1 }
        let second = Task {
            await store.select(AgentMenuItem(session: defaultDescriptor, pane: pane("second", .blocked)))
        }
        for _ in 0..<20 { await Task.yield() }
        await focuser.releaseBlockedCalls()
        await first.value
        await second.value

        let actions = await sequence.values
        let refreshRequests = await supervisor.refreshRequests
        XCTAssertEqual(actions, [
            "focus:work:first", "wezterm:work", "refresh:work",
            "focus:Default:second", "wezterm:Default",
            "activate:com.github.wez.wezterm", "refresh:Default"
        ])
        XCTAssertEqual(focuser.cancellationObservedSessionIDs, [.named("work")])
        XCTAssertEqual(activator.activatedBundleIdentifiers, [WezTermCLIConstants.bundleIdentifier])
        XCTAssertEqual(refreshRequests, [.named("work"), .default])
        XCTAssertNil(store.transientError)
    }

    func testSupersededFailedSelectionCannotActivateOrPublishError() async {
        let sequence = ActionSequence()
        let supervisor = FakeSessionSupervisor(sequence: sequence)
        let focuser = RecordingWezTermFocuser(
            sequence: sequence,
            results: [.failure(WezTermFocusError.noAttachedClient), .success(())],
            blockedCalls: [1],
            checksCancellationAfterGate: false
        )
        let activator = RecordingActivator(sequence: sequence)
        let store = makeStore(
            supervisor: supervisor,
            terminalActivator: activator,
            wezTermFocuser: focuser,
            preferences: testPreferences()
        )
        let first = Task {
            await store.select(AgentMenuItem(session: workDescriptor, pane: pane("first", .working)))
        }
        await eventually { focuser.focusedSessionIDs.count == 1 }
        let second = Task {
            await store.select(AgentMenuItem(session: defaultDescriptor, pane: pane("second", .blocked)))
        }
        for _ in 0..<20 { await Task.yield() }
        await focuser.releaseBlockedCalls()
        await first.value
        await second.value

        XCTAssertEqual(activator.activatedBundleIdentifiers, [WezTermCLIConstants.bundleIdentifier])
        let refreshRequests = await supervisor.refreshRequests
        XCTAssertEqual(refreshRequests, [.named("work"), .default])
        XCTAssertNil(store.transientError)
    }

    func testStopCancelsAndAwaitsSelectionBeforeSupervisorStop() async {
        let sequence = ActionSequence()
        let supervisor = FakeSessionSupervisor(sequence: sequence)
        let focuser = RecordingWezTermFocuser(sequence: sequence, blockedCalls: [1])
        let store = makeStore(
            supervisor: supervisor,
            terminalActivator: RecordingActivator(sequence: sequence),
            wezTermFocuser: focuser,
            preferences: testPreferences()
        )
        await store.start()
        let selection = Task {
            await store.select(AgentMenuItem(session: workDescriptor, pane: pane("p", .working)))
        }
        await eventually { focuser.focusedSessionIDs.count == 1 }
        let stop = Task { await store.stop() }
        for _ in 0..<20 { await Task.yield() }
        let stopCountBeforeRelease = await supervisor.stopCount
        XCTAssertEqual(stopCountBeforeRelease, 0)

        await focuser.releaseBlockedCalls()
        await selection.value
        await stop.value

        let actions = await sequence.values
        let finalStopCount = await supervisor.stopCount
        XCTAssertEqual(actions, [
            "focus:work:p", "wezterm:work", "refresh:work", "stop"
        ])
        XCTAssertEqual(finalStopCount, 1)
    }

    func testRemovedSessionForgetsPendingWezTermCleanup() async {
        let supervisor = FakeSessionSupervisor()
        let focuser = RecordingWezTermFocuser()
        let store = makeStore(supervisor: supervisor, wezTermFocuser: focuser)
        await store.start()
        await supervisor.send(.discoverySnapshot([workDescriptor]))
        await supervisor.send(.unavailable(.named("work"), "temporarily unavailable"))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(focuser.forgottenSessionIDs.isEmpty)

        await supervisor.send(.removed(.named("work")))
        await eventually { focuser.forgottenSessionIDs == [.named("work")] }
        await store.stop()
    }

    func testRetryDelegatesToUnavailableSessions() async {
        let supervisor = FakeSessionSupervisor()
        let store = makeStore(supervisor: supervisor)
        await store.start()
        await supervisor.send(.discoverySnapshot([workDescriptor]))
        await supervisor.send(.unavailable(.named("work"), "socket unavailable"))
        await eventually { store.unavailableSessions.count == 1 }

        await store.retry()

        let retryCount = await supervisor.retryCount
        XCTAssertEqual(retryCount, 1)
        XCTAssertNil(store.transientError)
        await store.stop()
    }

    func testStopCancelsConsumerAndRejectsLateEvents() async {
        let supervisor = FakeSessionSupervisor()
        let store = makeStore(supervisor: supervisor)
        await store.start()
        await store.stop()
        for _ in 0..<10 {
            if await supervisor.streamTerminated { break }
            await Task.yield()
        }
        let streamTerminated = await supervisor.streamTerminated
        XCTAssertTrue(streamTerminated)
        let stopObservedTerminatedStream = await supervisor.stopObservedTerminatedStream
        XCTAssertTrue(stopObservedTerminatedStream)

        await supervisor.send(.connected(defaultDescriptor, snapshot([pane("stale", .blocked)])))
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(store.connectionState, .searching)
        XCTAssertTrue(store.attentionSections.isEmpty)
        let stopCount = await supervisor.stopCount
        XCTAssertEqual(stopCount, 1)
    }

    func testStoreSubscribesToSupervisorEventsBeforeStartingIt() async {
        let supervisor = FakeSessionSupervisor()
        let store = makeStore(supervisor: supervisor)

        await store.start()

        let actions = await supervisor.lifecycleActions
        XCTAssertEqual(actions, ["events", "start"])
        await store.stop()
    }

    func testStartAndStopRemainIdempotent() async {
        let supervisor = FakeSessionSupervisor()
        let store = makeStore(supervisor: supervisor)

        await store.start()
        await store.start()
        await store.stop()
        await store.stop()

        let eventsCallCount = await supervisor.eventsCallCount
        let startCount = await supervisor.startCount
        let stopCount = await supervisor.stopCount
        XCTAssertEqual(eventsCallCount, 1)
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 1)
    }

    func testStopWhileEventAcquisitionIsBlockedPreventsStaleStartAndLateEvents() async {
        let supervisor = FakeSessionSupervisor(blockEvents: true)
        let store = makeStore(supervisor: supervisor)
        let start = Task { await store.start() }
        await waitUntil { await supervisor.eventsCallCount == 1 }

        let stopped = AsyncFlag()
        let stop = Task {
            await store.stop()
            await stopped.set()
        }
        await waitUntil { await stopped.value }
        var startCount = await supervisor.startCount
        let stopCount = await supervisor.stopCount
        XCTAssertEqual(startCount, 0)
        XCTAssertEqual(stopCount, 1)

        await supervisor.releaseEvents()
        await start.value
        await stop.value
        await supervisor.send(.connected(defaultDescriptor, snapshot([pane("late", .done)])))
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(store.connectionState, .searching)
        XCTAssertTrue(store.attentionSections.isEmpty)
        startCount = await supervisor.startCount
        XCTAssertEqual(startCount, 0)
    }

    func testRestartWaitsForInFlightStopThenOwnsNewLifecycle() async {
        let supervisor = FakeSessionSupervisor(blockStop: true)
        let store = makeStore(supervisor: supervisor)
        await store.start()
        var startCount = await supervisor.startCount
        XCTAssertEqual(startCount, 1)

        let stop = Task { await store.stop() }
        await waitUntil { await supervisor.stopCount == 1 }
        let restartEntered = AsyncFlag()
        let restart = Task {
            await restartEntered.set()
            await store.start()
        }
        await waitUntil { await restartEntered.value }
        for _ in 0..<10 { await Task.yield() }

        var eventsCallCount = await supervisor.eventsCallCount
        startCount = await supervisor.startCount
        XCTAssertEqual(eventsCallCount, 1)
        XCTAssertEqual(startCount, 1)

        await supervisor.releaseStop()
        await stop.value
        await restart.value
        eventsCallCount = await supervisor.eventsCallCount
        startCount = await supervisor.startCount
        XCTAssertEqual(eventsCallCount, 2)
        XCTAssertEqual(startCount, 2)

        await supervisor.send(.connected(workDescriptor, snapshot([pane("new", .done)])))
        await eventually { store.connectionState == .connected && store.attentionCount == 1 }
        await store.stop()
    }

    func testStopCancelsActiveNotificationSubscriptionBeforeStoppingSupervisor() async {
        let supervisor = FakeSessionSupervisor()
        let notifications = RecordingNotificationService()
        let store = makeStore(supervisor: supervisor, notificationService: notifications)
        await store.start()
        await waitUntil { await notifications.activeSubscriberCount == 1 }

        await store.stop()

        await waitUntil {
            let active = await notifications.activeSubscriberCount
            let cancellations = await notifications.cancellationCount
            return active == 0 && cancellations == 1
        }
        let stopCount = await supervisor.stopCount
        XCTAssertEqual(stopCount, 1)
    }

    func testNaturallyFinishedNotificationConsumerCancelsItsSubscription() async {
        let notifications = RecordingNotificationService()
        let store = makeStore(
            supervisor: FakeSessionSupervisor(), notificationService: notifications
        )
        await store.start()
        await waitUntil { await notifications.activeSubscriberCount == 1 }

        await notifications.finishResponses()

        await waitUntil { await notifications.cancellationCount == 1 }
        await store.stop()
        let cancellationCount = await notifications.cancellationCount
        XCTAssertEqual(cancellationCount, 1)
    }

    func testStopWhileNotificationResponseAcquisitionIsBlockedCancelsLateSubscription() async {
        let supervisor = FakeSessionSupervisor()
        let notifications = RecordingNotificationService(blockResponses: true)
        let store = makeStore(supervisor: supervisor, notificationService: notifications)
        let start = Task { await store.start() }
        await waitUntil { await notifications.responsesCallCount == 1 }

        let stopped = AsyncFlag()
        let stop = Task {
            await store.stop()
            await stopped.set()
        }
        await waitUntil { await stopped.value }
        var startCount = await supervisor.startCount
        let stopCount = await supervisor.stopCount
        XCTAssertEqual(startCount, 0)
        XCTAssertEqual(stopCount, 1)

        await notifications.releaseResponses()
        await start.value
        await stop.value
        await waitUntil { await notifications.cancellationCount == 1 }
        let activeSubscriberCount = await notifications.activeSubscriberCount
        startCount = await supervisor.startCount
        XCTAssertEqual(activeSubscriberCount, 0)
        XCTAssertEqual(startCount, 0)
    }

    func testRestartReplacesNotificationSubscriptionWithoutLeakingOldResponses() async {
        let supervisor = FakeSessionSupervisor(blockStop: true)
        let notifications = RecordingNotificationService()
        let store = makeStore(supervisor: supervisor, notificationService: notifications)
        await store.start()
        await waitUntil { await notifications.activeSubscriberCount == 1 }

        let stop = Task { await store.stop() }
        await waitUntil {
            let active = await notifications.activeSubscriberCount
            let stops = await supervisor.stopCount
            return active == 0 && stops == 1
        }
        let restart = Task { await store.start() }
        for _ in 0..<20 { await Task.yield() }
        var responsesCallCount = await notifications.responsesCallCount
        XCTAssertEqual(responsesCallCount, 1)

        await supervisor.releaseStop()
        await stop.value
        await restart.value
        await waitUntil { await notifications.activeSubscriberCount == 1 }
        responsesCallCount = await notifications.responsesCallCount
        var cancellationCount = await notifications.cancellationCount
        XCTAssertEqual(responsesCallCount, 2)
        XCTAssertEqual(cancellationCount, 1)

        await notifications.send(NotificationSelectionTarget(
            sessionID: .named("old"), paneID: "late"
        ), toSubscriptionAt: 0)
        await supervisor.send(.connected(workDescriptor, snapshot([pane("p", .done)])))
        for _ in 0..<30 { await Task.yield() }
        let focusRequests = await supervisor.focusRequests
        XCTAssertEqual(focusRequests, [])
        await store.stop()
        cancellationCount = await notifications.cancellationCount
        XCTAssertEqual(cancellationCount, 2)
    }

    func testJoinedLabelsMatchHerdrForSingleAndMultiTabWorkspaces() async {
        let supervisor = FakeSessionSupervisor()
        let store = makeStore(supervisor: supervisor)
        await store.start()
        let panes = [
            pane("single", .done, workspaceID: "dotfiles", tabID: "dotfiles:tab"),
            pane("multi", .done, workspaceID: "menubar", tabID: "menubar:server")
        ]
        let workspaces = [
            workspace("dotfiles", label: "dotfiles-mac", tabCount: 1),
            workspace("menubar", label: "Herdr Menubar", tabCount: 2)
        ]
        let tabs = [
            tab("dotfiles:tab", workspaceID: "dotfiles", label: "shell"),
            tab("menubar:server", workspaceID: "menubar", label: "server")
        ]
        await supervisor.send(.connected(defaultDescriptor, PresentationSnapshot(
            panes: panes, workspaces: workspaces, tabs: tabs
        )))
        await eventually { store.attentionCount == 2 }

        XCTAssertEqual(store.attentionSections[0].items.map(\.displayLabel), ["dotfiles-mac", "Herdr Menubar · server"])
        XCTAssertEqual(store.attentionSections[0].items.map(\.secondaryLabel), ["done · Claude", "done · Claude"])
        await store.stop()
    }

    func testVisibleLabelsIncludeAgentContextWithoutDuplicateSuffixes() {
        let labeledAgentPane = PaneInfo(
            paneID: "bin:pane", terminalID: "terminal", workspaceID: "bin", tabID: "bin:tab",
            focused: false, label: "test-agent", agent: "pi", title: nil, displayAgent: nil,
            agentStatus: .idle, revision: 1
        )
        let singleTabItem = AgentMenuItem(
            session: defaultDescriptor, pane: labeledAgentPane,
            workspace: workspace("bin", label: "bin", tabCount: 1),
            tab: tab("bin:tab", workspaceID: "bin", label: "shell")
        )
        let multiTabItem = AgentMenuItem(
            session: defaultDescriptor, pane: labeledAgentPane,
            workspace: workspace("workspace", label: "workspace", tabCount: 2),
            tab: tab("workspace:test", workspaceID: "workspace", label: "tab"),
            workspaceIsMultiTab: true
        )
        let duplicateItem = AgentMenuItem(
            session: defaultDescriptor, pane: labeledAgentPane,
            workspace: workspace("bin", label: "test-agent", tabCount: 1)
        )
        let fallbackPane = PaneInfo(
            paneID: "pane-42", terminalID: "terminal", workspaceID: "missing", tabID: "missing:tab",
            focused: false, label: nil, agent: "pi", title: nil, displayAgent: "test-agent",
            agentStatus: .idle, revision: 1
        )

        XCTAssertEqual(singleTabItem.visibleLabel, "bin · test-agent")
        XCTAssertEqual(multiTabItem.visibleLabel, "workspace · tab · test-agent")
        XCTAssertEqual(duplicateItem.visibleLabel, "test-agent")
        XCTAssertEqual(AgentMenuItem(session: defaultDescriptor, pane: fallbackPane).visibleLabel, "pane-42 · test-agent")
    }

    func testSecondaryLabelsPreservePaneAndDisplayAgentPreference() {
        let paneLabel = PaneInfo(
            paneID: "p1", terminalID: "t", workspaceID: "w", tabID: "tab", focused: false,
            label: "test-agent", agent: "pi", title: nil, displayAgent: nil, agentStatus: .idle, revision: 1
        )
        let displayAgent = PaneInfo(
            paneID: "p2", terminalID: "t", workspaceID: "w", tabID: "tab", focused: false,
            label: "test-agent", agent: "pi", title: nil, displayAgent: "Pi Display", agentStatus: .idle, revision: 1
        )
        XCTAssertEqual(AgentMenuItem(session: defaultDescriptor, pane: paneLabel).secondaryLabel, "idle · test-agent")
        XCTAssertEqual(AgentMenuItem(session: defaultDescriptor, pane: displayAgent).secondaryLabel, "idle · Pi Display")
    }

    func testJoinedLabelFallsBackThroughPaneTitleLabelAndID() async {
        let supervisor = FakeSessionSupervisor()
        let store = makeStore(supervisor: supervisor)
        await store.start()
        await supervisor.send(.connected(defaultDescriptor, PresentationSnapshot(panes: [
            pane("title", .done, title: "Pane title", workspaceID: "missing", tabID: "missing:tab"),
            pane("label", .done, label: "Pane label", workspaceID: "missing", tabID: "missing:tab"),
            pane("final-id", .done, workspaceID: "missing", tabID: "missing:tab")
        ], workspaces: [], tabs: [])))
        await eventually { store.attentionCount == 3 }
        XCTAssertEqual(store.attentionSections[0].items.map(\.displayLabel), ["final-id", "Pane label", "Pane title"])
        await store.stop()
    }

    func testDistinctSnapshotTabsMakeWorkspaceMultiTabWhenCountIsStale() async {
        let supervisor = FakeSessionSupervisor()
        let store = makeStore(supervisor: supervisor)
        await store.start()
        let value = PresentationSnapshot(
            panes: [pane("server", .working, workspaceID: "w", tabID: "t2")],
            workspaces: [workspace("w", label: "Herdr Menubar", tabCount: 1)],
            tabs: [tab("t1", workspaceID: "w", label: "shell"), tab("t2", workspaceID: "w", label: "server")]
        )
        await supervisor.send(.connected(defaultDescriptor, value))
        await eventually { store.workingSections.first?.items.first?.displayLabel == "Herdr Menubar · server" }
        await store.stop()
    }

    func testSelectionReadsCurrentTerminalPreferenceAfterFocusSucceeds() async {
        let suiteName = "dev.herdr.menubar.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = Preferences(defaults: defaults)
        let supervisor = FakeSessionSupervisor(focusAction: {
            await MainActor.run { preferences.selectedTerminalBundleIdentifier = "com.mitchellh.ghostty" }
        })
        let activator = RecordingActivator()
        let focuser = RecordingWezTermFocuser()
        let store = makeStore(
            supervisor: supervisor,
            terminalActivator: activator,
            wezTermFocuser: focuser,
            preferences: preferences
        )

        await store.select(AgentMenuItem(session: defaultDescriptor, pane: pane("p", .blocked)))

        XCTAssertEqual(activator.activatedBundleIdentifiers, ["com.mitchellh.ghostty"])
        XCTAssertTrue(focuser.focusedSessionIDs.isEmpty)
    }

    func testHostedXCTestEnvironmentDisablesProductionSynchronization() {
        XCTAssertFalse(HerdrMenubarApp.shouldStartSynchronization(environment: [
            "XCTestConfigurationFilePath": "/tmp/HerdrMenubarTests.xctestconfiguration"
        ]))
        XCTAssertTrue(HerdrMenubarApp.shouldStartSynchronization(environment: [:]))
    }

    private func assertAdapterFailure(
        _ error: WezTermFocusError,
        expectedMessage: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let sequence = ActionSequence()
        let supervisor = FakeSessionSupervisor(sequence: sequence)
        let focuser = RecordingWezTermFocuser(
            sequence: sequence,
            results: [.failure(error)]
        )
        let activator = RecordingActivator(sequence: sequence)
        let store = makeStore(
            supervisor: supervisor,
            terminalActivator: activator,
            wezTermFocuser: focuser,
            preferences: testPreferences()
        )

        await store.select(AgentMenuItem(session: workDescriptor, pane: pane("p", .blocked)))

        let actions = await sequence.values
        let refreshRequests = await supervisor.refreshRequests
        XCTAssertEqual(actions, ["focus:work:p", "wezterm:work", "refresh:work"], file: file, line: line)
        XCTAssertEqual(refreshRequests, [.named("work")], file: file, line: line)
        XCTAssertEqual(activator.activationCount, 0, file: file, line: line)
        XCTAssertEqual(store.transientError, expectedMessage, file: file, line: line)
    }

    private func makeStore(
        supervisor: any SessionSupervising,
        terminalActivator: any TerminalActivating = RecordingActivator(),
        wezTermFocuser: any WezTermSessionFocusing = RecordingWezTermFocuser(),
        attentionCoordinator: any AttentionNotificationCoordinating = RecordingAttentionCoordinator(),
        notificationService: any NativeNotificationServing = RecordingNotificationService(),
        preferences: Preferences = testPreferences()
    ) -> AgentStore {
        AgentStore(
            supervisor: supervisor,
            terminalActivator: terminalActivator,
            wezTermFocuser: wezTermFocuser,
            attentionCoordinator: attentionCoordinator,
            notificationService: notificationService,
            preferences: preferences
        )
    }

    private func eventually(
        timeout: Duration = .seconds(1),
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline { await Task.yield() }
        XCTAssertTrue(condition())
    }

    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async {
        for _ in 0..<1_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Condition did not become true")
    }
}

private struct FocusRequest: Equatable, Sendable {
    let sessionID: SessionID
    let paneID: String
}

private enum TestFailure: Error { case activation }

private actor ActionSequence {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private actor AsyncFlag {
    private(set) var value = false
    func set() { value = true }
}

private actor AsyncCountSignal {
    private struct Waiter {
        let target: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var count = 0
    private var waiters: [Waiter] = []

    func record() {
        count += 1
        let ready = waiters.filter { $0.target <= count }
        waiters.removeAll { $0.target <= count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    func wait(for target: Int) async {
        guard count < target else { return }
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(target: target, continuation: continuation))
        }
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isOpen = true
        let ownedWaiters = waiters
        waiters.removeAll()
        for waiter in ownedWaiters { waiter.resume() }
    }
}

private final class StreamTerminationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var terminated = false

    func markTerminated() {
        lock.lock()
        terminated = true
        lock.unlock()
    }

    var isTerminated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminated
    }
}

private actor FakeSessionSupervisor: SessionSupervising {
    private var continuation: AsyncStream<SessionSupervisorEvent>.Continuation?
    private(set) var lifecycleActions: [String] = []
    private(set) var eventsCallCount = 0
    private(set) var startCount = 0
    private(set) var retryCount = 0
    private(set) var stopCount = 0
    private(set) var refreshRequests: [SessionID] = []
    private(set) var focusRequests: [FocusRequest] = []
    private(set) var setWindowTitleCount = 0
    private(set) var clearWindowTitleCount = 0
    private(set) var setWindowTitleSessionIDs: [SessionID] = []
    private(set) var setWindowTitles: [String] = []
    private(set) var clearWindowTitleSessionIDs: [SessionID] = []
    private var setWindowTitleResults: [Result<ClientWindowTitleResult, HerdrAPIError>] = []
    private var clearWindowTitleResults: [Result<ClientWindowTitleResult, HerdrAPIError>] = []
    private(set) var streamTerminated = false
    private(set) var stopObservedTerminatedStream = false
    private let focusError: (any Error)?
    private let sequence: ActionSequence?
    private let focusAction: (@Sendable () async -> Void)?
    private let eventsGate: AsyncGate?
    private let stopGate: AsyncGate?
    private let terminationProbe = StreamTerminationProbe()
    private let refreshSignal = AsyncCountSignal()

    init(
        focusError: (any Error)? = nil,
        sequence: ActionSequence? = nil,
        focusAction: (@Sendable () async -> Void)? = nil,
        blockEvents: Bool = false,
        blockStop: Bool = false
    ) {
        self.focusError = focusError
        self.sequence = sequence
        self.focusAction = focusAction
        eventsGate = blockEvents ? AsyncGate() : nil
        stopGate = blockStop ? AsyncGate() : nil
    }

    func events() async -> AsyncStream<SessionSupervisorEvent> {
        lifecycleActions.append("events")
        eventsCallCount += 1
        await eventsGate?.wait()
        let (stream, continuation) = AsyncStream<SessionSupervisorEvent>.makeStream()
        let terminationProbe = self.terminationProbe
        continuation.onTermination = { [weak self] _ in
            terminationProbe.markTerminated()
            Task { await self?.recordTermination() }
        }
        self.continuation = continuation
        return stream
    }

    func start() { lifecycleActions.append("start"); startCount += 1 }
    func stop() async {
        stopCount += 1
        stopObservedTerminatedStream = terminationProbe.isTerminated
        continuation?.finish()
        await stopGate?.wait()
        await sequence?.append("stop")
    }
    func retryUnavailable() { retryCount += 1 }

    func focus(sessionID: SessionID, paneID: String) async throws -> PaneInfo {
        focusRequests.append(FocusRequest(sessionID: sessionID, paneID: paneID))
        await sequence?.append("focus:\(sessionID.displayName):\(paneID)")
        if let focusError { throw focusError }
        await focusAction?()
        return pane(paneID, .idle)
    }

    func setClientWindowTitle(
        sessionID: SessionID,
        title: String
    ) throws -> ClientWindowTitleResult {
        setWindowTitleCount += 1
        setWindowTitleSessionIDs.append(sessionID)
        setWindowTitles.append(title)
        guard !setWindowTitleResults.isEmpty else {
            return ClientWindowTitleResult(
                type: "client_window_title",
                changed: true,
                reason: "set"
            )
        }
        return try setWindowTitleResults.removeFirst().get()
    }

    func clearClientWindowTitle(
        sessionID: SessionID,
        timeout: Duration
    ) throws -> ClientWindowTitleResult {
        clearWindowTitleCount += 1
        clearWindowTitleSessionIDs.append(sessionID)
        guard !clearWindowTitleResults.isEmpty else {
            return ClientWindowTitleResult(
                type: "client_window_title",
                changed: true,
                reason: "cleared"
            )
        }
        return try clearWindowTitleResults.removeFirst().get()
    }

    func enqueueSetWindowTitleResult(
        _ result: Result<ClientWindowTitleResult, HerdrAPIError>
    ) {
        setWindowTitleResults.append(result)
    }

    func enqueueClearWindowTitleResult(
        _ result: Result<ClientWindowTitleResult, HerdrAPIError>
    ) {
        clearWindowTitleResults.append(result)
    }

    func refresh(sessionID: SessionID) async {
        refreshRequests.append(sessionID)
        await sequence?.append("refresh:\(sessionID.displayName)")
        await refreshSignal.record()
    }

    func send(_ event: SessionSupervisorEvent) { continuation?.yield(event) }
    func waitForRefreshRequests(_ count: Int) async { await refreshSignal.wait(for: count) }
    func releaseEvents() async { await eventsGate?.release() }
    func releaseStop() async { await stopGate?.release() }
    private func recordTermination() { streamTerminated = true }
}

private actor RecordingAttentionCoordinator: AttentionNotificationCoordinating {
    struct Reconciliation: Sendable {
        let session: SessionDescriptor
        let items: [AgentMenuItem]
        let policy: NotificationDeliveryPolicy
    }

    private(set) var reconciliations: [Reconciliation] = []
    private(set) var unavailableSessionIDs: [SessionID] = []
    private(set) var removedSessionIDs: [SessionID] = []
    private(set) var resetCount = 0
    private let reconciliationSignal = AsyncCountSignal()

    func reconcile(
        session: SessionDescriptor,
        items: [AgentMenuItem],
        policy: NotificationDeliveryPolicy
    ) async {
        reconciliations.append(Reconciliation(session: session, items: items, policy: policy))
        await reconciliationSignal.record()
    }

    func unavailable(sessionID: SessionID) {
        unavailableSessionIDs.append(sessionID)
    }

    func remove(sessionID: SessionID) {
        removedSessionIDs.append(sessionID)
    }

    func reset() {
        resetCount += 1
    }

    func waitForReconciliations(_ count: Int) async {
        await reconciliationSignal.wait(for: count)
    }

    func barrier() {}
}

private actor RecordingNotificationService: NativeNotificationServing {
    private struct Subscriber {
        let id: UUID
        let continuation: AsyncStream<NotificationSelectionTarget>.Continuation
    }

    private var subscribers: [Subscriber] = []
    private var historicalContinuations: [AsyncStream<NotificationSelectionTarget>.Continuation] = []
    private var bufferedTargets: [NotificationSelectionTarget] = []
    private let responsesGate: AsyncGate?
    private(set) var responsesCallCount = 0
    private(set) var cancellationCount = 0
    private(set) var deliveredResponseCount = 0
    private let responsesSignal = AsyncCountSignal()
    private let cancellationSignal = AsyncCountSignal()

    init(blockResponses: Bool = false) {
        responsesGate = blockResponses ? AsyncGate() : nil
    }

    var activeSubscriberCount: Int { subscribers.count }

    func responses() async -> NotificationResponseSubscription {
        responsesCallCount += 1
        await responsesSignal.record()
        await responsesGate?.wait()
        let id = UUID()
        let (stream, continuation) = AsyncStream<NotificationSelectionTarget>.makeStream()
        subscribers.append(Subscriber(id: id, continuation: continuation))
        historicalContinuations.append(continuation)
        for target in bufferedTargets {
            continuation.yield(target)
        }
        bufferedTargets.removeAll()
        return NotificationResponseSubscription(
            stream: stream,
            cancellation: NotificationResponseCancellation { [weak self] in
                continuation.finish()
                Task { await self?.cancel(id: id) }
            }
        )
    }

    func requestAuthorization() async throws -> Bool { true }
    func settings() async -> NotificationSystemSettings { .authorized }
    func deliver(_ event: AttentionNotificationEvent, sound: Bool) async throws {}

    func send(
        _ target: NotificationSelectionTarget,
        toSubscriptionAt historicalIndex: Int? = nil
    ) {
        if let historicalIndex {
            guard historicalContinuations.indices.contains(historicalIndex) else { return }
            historicalContinuations[historicalIndex].yield(target)
            return
        }
        guard !subscribers.isEmpty else {
            bufferedTargets.append(target)
            return
        }
        deliveredResponseCount += 1
        for subscriber in subscribers {
            subscriber.continuation.yield(target)
        }
    }

    func finishResponses() {
        for subscriber in subscribers {
            subscriber.continuation.finish()
        }
    }

    func releaseResponses() async {
        await responsesGate?.release()
    }

    func waitForResponseCalls(_ count: Int) async {
        await responsesSignal.wait(for: count)
    }

    func waitForCancellations(_ count: Int) async {
        await cancellationSignal.wait(for: count)
    }

    private func cancel(id: UUID) async {
        guard let index = subscribers.firstIndex(where: { $0.id == id }) else { return }
        subscribers.remove(at: index)
        cancellationCount += 1
        await cancellationSignal.record()
    }
}

@MainActor
private final class RecordingActivator: TerminalActivating {
    private(set) var activationCount = 0
    private(set) var activatedBundleIdentifiers: [String] = []
    private let error: (any Error)?
    private let sequence: ActionSequence?

    init(error: (any Error)? = nil, sequence: ActionSequence? = nil) {
        self.error = error
        self.sequence = sequence
    }

    func activate(bundleIdentifier: String) async throws {
        activationCount += 1
        activatedBundleIdentifiers.append(bundleIdentifier)
        await sequence?.append("activate:\(bundleIdentifier)")
        if let error { throw error }
    }
}

@MainActor
private final class RecordingWezTermFocuser: WezTermSessionFocusing {
    private(set) var focusedSessionIDs: [SessionID] = []
    private(set) var forgottenSessionIDs: [SessionID] = []
    private(set) var cancellationObservedSessionIDs: [SessionID] = []
    private var results: [Result<Void, WezTermFocusError>]
    private let sequence: ActionSequence?
    private let blockedCalls: Set<Int>
    private let checksCancellationAfterGate: Bool
    private let gate = AsyncGate()
    private let callSignal = AsyncCountSignal()
    private let cancellationSignal = AsyncCountSignal()

    init(
        sequence: ActionSequence? = nil,
        results: [Result<Void, WezTermFocusError>] = [],
        blockedCalls: Set<Int> = [],
        checksCancellationAfterGate: Bool = true
    ) {
        self.sequence = sequence
        self.results = results
        self.blockedCalls = blockedCalls
        self.checksCancellationAfterGate = checksCancellationAfterGate
    }

    func focusAttachedClient(sessionID: SessionID) async throws {
        focusedSessionIDs.append(sessionID)
        let call = focusedSessionIDs.count
        await sequence?.append("wezterm:\(sessionID.displayName)")
        await callSignal.record()
        if blockedCalls.contains(call) {
            let cancellationSignal = self.cancellationSignal
            await withTaskCancellationHandler {
                await gate.wait()
            } onCancel: {
                Task { await cancellationSignal.record() }
            }
            if Task.isCancelled {
                cancellationObservedSessionIDs.append(sessionID)
            }
            if checksCancellationAfterGate {
                try Task.checkCancellation()
            }
        }
        if !results.isEmpty {
            try results.removeFirst().get()
        }
    }

    func forget(sessionID: SessionID) {
        forgottenSessionIDs.append(sessionID)
    }

    func releaseBlockedCalls() async {
        await gate.release()
    }

    func waitForCalls(_ count: Int) async {
        await callSignal.wait(for: count)
    }

    func waitForCancellations(_ count: Int) async {
        await cancellationSignal.wait(for: count)
    }
}

private let defaultDescriptor = SessionDescriptor(
    id: .default, socketURL: URL(fileURLWithPath: "/tmp/default.sock")
)
private let workDescriptor = descriptor("work")

@MainActor
private func testPreferences(
    bundleIdentifier: String = WezTermCLIConstants.bundleIdentifier
) -> Preferences {
    let defaults = UserDefaults(suiteName: "dev.herdr.menubar.agent-store-tests.\(UUID().uuidString)")!
    let preferences = Preferences(defaults: defaults)
    preferences.selectedTerminalBundleIdentifier = bundleIdentifier
    return preferences
}

private func descriptor(_ name: String) -> SessionDescriptor {
    SessionDescriptor(id: .named(name), socketURL: URL(fileURLWithPath: "/tmp/\(name).sock"))
}

private func snapshot(_ panes: [PaneInfo]) -> PresentationSnapshot {
    PresentationSnapshot(panes: panes, workspaces: [], tabs: [])
}

private func pane(
    _ id: String,
    _ status: AgentStatus,
    title: String? = nil,
    label: String? = nil,
    workspaceID: String = "workspace",
    tabID: String = "tab"
) -> PaneInfo {
    PaneInfo(
        paneID: id, terminalID: "terminal-\(id)", workspaceID: workspaceID, tabID: tabID,
        focused: false, label: label, agent: "claude", title: title, displayAgent: "Claude",
        agentStatus: status, revision: 1
    )
}

private func workspace(_ id: String, label: String, tabCount: Int) -> WorkspaceInfo {
    WorkspaceInfo(
        workspaceID: id, number: 1, label: label, focused: false, paneCount: 1,
        tabCount: tabCount, activeTabID: "\(id):tab", agentStatus: .working
    )
}

private func tab(_ id: String, workspaceID: String, label: String) -> TabInfo {
    TabInfo(
        tabID: id, workspaceID: workspaceID, number: 1, label: label, focused: false,
        paneCount: 1, agentStatus: .working
    )
}
