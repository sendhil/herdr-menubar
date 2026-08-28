import Darwin
import Foundation
import XCTest
@testable import HerdrMenubar

final class MultiSessionIntegrationTests: XCTestCase {
    func testShortcutSignalWaitsTimeOutWhenExpectedSignalsNeverArrive() async {
        let target = NotificationSelectionTarget(
            sessionID: .named("missing"),
            paneID: "missing"
        )
        let observedLatestTarget = IntegrationObservedLatestTargetStore(
            wrapping: LatestNotificationTargetStore()
        )
        let deliveryGate = IntegrationNotificationDeliveryGate()
        addTeardownBlock {
            await deliveryGate.finish()
            await observedLatestTarget.finish()
        }
        let start = ContinuousClock.now

        do {
            try await observedLatestTarget.waitForLatest(target, timeout: .milliseconds(20))
            XCTFail("Expected a bounded missing-latest-target error")
        } catch let error as IntegrationAttentionObserverError {
            XCTAssertEqual(error, .timedOut(.latestTarget))
        } catch {
            XCTFail("Unexpected missing-latest-target error: \(error)")
        }

        do {
            try await observedLatestTarget.waitForLookups(1, timeout: .milliseconds(20))
            XCTFail("Expected a bounded missing-lookup error")
        } catch let error as IntegrationAttentionObserverError {
            XCTAssertEqual(error, .timedOut(.latestTargetLookup))
        } catch {
            XCTFail("Unexpected missing-lookup error: \(error)")
        }

        do {
            try await deliveryGate.waitUntilDeliveryReturnIsPaused(timeout: .milliseconds(20))
            XCTFail("Expected a bounded missing-delivery-pause error")
        } catch let error as IntegrationAttentionObserverError {
            XCTAssertEqual(error, .timedOut(.deliveryPause))
        } catch {
            XCTFail("Unexpected missing-delivery-pause error: \(error)")
        }

        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        await observedLatestTarget.finish()
        await deliveryGate.finish()
    }

    func testShortcutFixtureFinishReleasesPausedDeliveryAndPendingSignalWaits() async throws {
        let target = NotificationSelectionTarget(
            sessionID: .named("never-recorded"),
            paneID: "never-recorded"
        )
        let observedLatestTarget = IntegrationObservedLatestTargetStore(
            wrapping: LatestNotificationTargetStore()
        )
        let deliveryGate = IntegrationNotificationDeliveryGate()
        addTeardownBlock {
            await deliveryGate.finish()
            await observedLatestTarget.finish()
        }
        let pausedDelivery = Task {
            try await deliveryGate.pauseDeliveryReturn(timeout: .seconds(1))
        }
        try await deliveryGate.waitUntilDeliveryReturnIsPaused(timeout: .seconds(1))
        let latestWait = Task {
            try await observedLatestTarget.waitForLatest(target, timeout: .seconds(1))
        }
        let lookupWait = Task {
            try await observedLatestTarget.waitForLookups(1, timeout: .seconds(1))
        }
        try await observedLatestTarget.waitUntilWaitersArePending(
            latest: 1,
            lookups: 1,
            timeout: .seconds(1)
        )

        await deliveryGate.finish()
        await deliveryGate.finish()
        await observedLatestTarget.finish()
        await observedLatestTarget.finish()

        for task in [pausedDelivery, latestWait, lookupWait] {
            do {
                try await task.value
                XCTFail("Expected finish to release the pending fixture wait")
            } catch let error as IntegrationAttentionObserverError {
                XCTAssertEqual(error, .finished)
            } catch {
                XCTFail("Unexpected fixture-finish error: \(error)")
            }
        }
        let deliveryWaiterCount = await deliveryGate.pendingWaiterCount
        let signalWaiterCount = await observedLatestTarget.pendingWaiterCount
        XCTAssertEqual(deliveryWaiterCount, 0)
        XCTAssertEqual(signalWaiterCount, 0)
    }

    @MainActor
    func testShortcutCannotObserveDeliveryBeforeAcceptedResultReturns() async throws {
        let deliveryGate = IntegrationNotificationDeliveryGate()
        let notifications = IntegrationNotificationService(deliveryReturnGate: deliveryGate)
        let latestTargetStore = LatestNotificationTargetStore()
        let observedLatestTarget = IntegrationObservedLatestTargetStore(
            wrapping: latestTargetStore
        )
        let coordinator = AttentionNotificationCoordinator(
            service: notifications,
            latestTargetRecorder: latestTargetStore
        )
        let registrar = IntegrationShortcutRegistrar()
        var routedTargets: [NotificationSelectionTarget] = []
        var routedExpectation: XCTestExpectation?
        let shortcutController = GlobalShortcutController(
            registrar: registrar,
            latestTarget: observedLatestTarget,
            toggleMenu: {},
            selectTarget: { target in
                routedTargets.append(target)
                routedExpectation?.fulfill()
            }
        )
        addTeardownBlock {
            await deliveryGate.finish()
            await observedLatestTarget.finish()
            await MainActor.run { registrar.finish() }
            await shortcutController.stop()
        }
        let session = SessionDescriptor(
            id: .named("work"),
            socketURL: URL(fileURLWithPath: "/tmp/integration-accepted-target.sock")
        )
        let expectedTarget = NotificationSelectionTarget(
            sessionID: session.id,
            paneID: "duplicate"
        )
        let policy = NotificationDeliveryPolicy(
            notificationsEnabled: true,
            soundEnabled: false
        )
        await coordinator.reconcile(
            session: session,
            items: [AgentMenuItem(
                session: session,
                pane: integrationPane("duplicate", .working)
            )],
            policy: policy
        )
        shortcutController.start()

        let acceptingDelivery = Task {
            await coordinator.reconcile(
                session: session,
                items: [AgentMenuItem(
                    session: session,
                    pane: integrationPane("duplicate", .blocked)
                )],
                policy: policy
            )
        }
        try await deliveryGate.waitUntilDeliveryReturnIsPaused(timeout: .seconds(1))
        let appendedDeliveries = await notifications.deliveries
        XCTAssertEqual(appendedDeliveries.map(\.event.target), [expectedTarget])
        let targetBeforeAcceptedReturn = await latestTargetStore.latest()
        XCTAssertNil(targetBeforeAcceptedReturn)

        registrar.send(.keyUp, for: .focusLatestNotification)
        try await observedLatestTarget.waitForLookups(1, timeout: .seconds(1))
        XCTAssertEqual(routedTargets, [])

        await deliveryGate.releaseDeliveryReturn()
        await acceptingDelivery.value
        let targetAfterAcceptedReturn = await latestTargetStore.latest()
        XCTAssertEqual(targetAfterAcceptedReturn, expectedTarget)

        routedExpectation = expectation(description: "accepted target routed")
        registrar.send(.keyUp, for: .focusLatestNotification)
        try await observedLatestTarget.waitForLookups(2, timeout: .seconds(1))
        if let routedExpectation {
            await fulfillment(of: [routedExpectation], timeout: 1)
        }
        XCTAssertEqual(routedTargets, [expectedTarget])
        await shortcutController.stop()
    }

    @MainActor
    func testAcceptedTargetsRouteRepeatedGlobalFocusAcrossTwoServersAndReconnectGrace() async throws {
        let root = try makeTemporaryHerdrRoot()
        let defaultURL = root.appending(path: "herdr.sock")
        let namedURL = root.appending(path: "sessions/work/herdr.sock")
        let defaultServer = try FakeHerdrServer(
            url: defaultURL,
            panes: [integrationPane("duplicate", .working)]
        )
        var namedServer: FakeHerdrServer? = try FakeHerdrServer(
            url: namedURL,
            panes: [integrationPane("duplicate", .working)]
        )
        defer {
            defaultServer.stop()
            namedServer?.stop()
            try? FileManager.default.removeItem(at: root)
        }

        let graceSleeper = IntegrationHoldingSleeper()
        let supervisor = SessionSupervisor(
            discovery: SessionDiscovery(configRoot: root),
            clientFactory: IntegrationClientFactory(),
            sleeper: graceSleeper,
            discoveryInterval: .seconds(30),
            removalGracePeriod: .seconds(10)
        )
        let notifications = IntegrationNotificationService()
        let latestTargetStore = LatestNotificationTargetStore()
        let observedLatestTarget = IntegrationObservedLatestTargetStore(
            wrapping: latestTargetStore
        )
        let coordinator = AttentionNotificationCoordinator(
            service: notifications,
            latestTargetRecorder: observedLatestTarget
        )
        let activator = IntegrationRecordingActivator()
        let focuser = IntegrationRecordingWezTermFocuser()
        let preferencesFixture = try IntegrationPreferencesFixture()
        preferencesFixture.preferences.notificationsEnabled = true
        let store = AgentStore(
            supervisor: supervisor,
            terminalActivator: activator,
            wezTermFocuser: focuser,
            attentionCoordinator: coordinator,
            notificationService: notifications,
            preferences: preferencesFixture.preferences
        )
        let registrar = IntegrationShortcutRegistrar()
        let statusDriver = IntegrationStatusItemDriver()
        let statusController = StatusItemController(driver: statusDriver) { _ in }
        var routedTargets: [NotificationSelectionTarget] = []
        var routeExpectations: [XCTestExpectation] = []
        let shortcutController = GlobalShortcutController(
            registrar: registrar,
            latestTarget: observedLatestTarget,
            toggleMenu: { statusController.toggle() },
            selectTarget: { target in
                routedTargets.append(target)
                store.select(target)
                if !routeExpectations.isEmpty {
                    routeExpectations.removeFirst().fulfill()
                }
            }
        )
        addTeardownBlock {
            await observedLatestTarget.finish()
            await MainActor.run { registrar.finish() }
            await shortcutController.stop()
            await store.stop()
            await MainActor.run {
                statusController.stop()
                preferencesFixture.remove()
            }
        }

        statusController.start()
        shortcutController.start()
        await store.start()
        await eventually {
            await MainActor.run { store.workingSections.count == 2 }
        }

        await defaultServer.setPanes([integrationPane("duplicate", .blocked)])
        await defaultServer.pushAgentStatusEvent(paneID: "duplicate", status: .blocked)
        await eventually { await notifications.deliveries.count == 1 }
        let defaultTarget = NotificationSelectionTarget(
            sessionID: .default,
            paneID: "duplicate"
        )
        try await observedLatestTarget.waitForLatest(defaultTarget, timeout: .seconds(1))
        let latestAfterDefaultDelivery = await latestTargetStore.latest()
        XCTAssertEqual(latestAfterDefaultDelivery, defaultTarget)
        await namedServer?.setPanes([integrationPane("duplicate", .blocked)])
        await namedServer?.pushAgentStatusEvent(paneID: "duplicate", status: .blocked)
        await eventually { await notifications.deliveries.count == 2 }
        let namedTarget = NotificationSelectionTarget(
            sessionID: .named("work"),
            paneID: "duplicate"
        )
        try await observedLatestTarget.waitForLatest(namedTarget, timeout: .seconds(1))
        let latestAfterNamedDelivery = await latestTargetStore.latest()
        XCTAssertEqual(latestAfterNamedDelivery, namedTarget)
        let initialDeliveries = await notifications.deliveries
        let initialDeliveryTargets = initialDeliveries.map(\.event.target)
        XCTAssertEqual(initialDeliveryTargets, [defaultTarget, namedTarget])

        guard let initialNamedServer = namedServer else {
            return XCTFail("Expected named server")
        }
        let namedRefreshBaseline = await initialNamedServer.paneListRequestCount
        let defaultRefreshBaseline = await defaultServer.paneListRequestCount
        for expectedFocusCount in 1...2 {
            let routed = expectation(description: "named shortcut route \(expectedFocusCount)")
            routeExpectations.append(routed)
            registrar.send(.keyUp, for: .focusLatestNotification)
            await fulfillment(of: [routed], timeout: 1)
            await eventually {
                let focusCount = await initialNamedServer.focusedPaneIDs.count
                let requestCount = await initialNamedServer.paneListRequestCount
                return focusCount == expectedFocusCount
                    && requestCount >= namedRefreshBaseline + expectedFocusCount
            }
        }
        let namedFocusedAfterRepeatedShortcut = await initialNamedServer.focusedPaneIDs
        let defaultFocusedAfterNamedShortcuts = await defaultServer.focusedPaneIDs
        let defaultRefreshAfterNamedShortcuts = await defaultServer.paneListRequestCount
        XCTAssertEqual(namedFocusedAfterRepeatedShortcut, ["duplicate", "duplicate"])
        XCTAssertEqual(defaultFocusedAfterNamedShortcuts, [])
        XCTAssertEqual(defaultRefreshAfterNamedShortcuts, defaultRefreshBaseline)

        await defaultServer.setPanes([integrationPane("duplicate", .done)])
        await defaultServer.pushAgentStatusEvent(paneID: "duplicate", status: .done)
        await eventually { await notifications.deliveries.count == 3 }
        try await observedLatestTarget.waitForLatest(defaultTarget, timeout: .seconds(1))
        let latestAfterNewerDefaultDelivery = await latestTargetStore.latest()
        XCTAssertEqual(latestAfterNewerDefaultDelivery, defaultTarget)
        let defaultSelectionRefreshBaseline = await defaultServer.paneListRequestCount
        let namedFocusBaseline = await initialNamedServer.focusedPaneIDs.count
        let routedDefault = expectation(description: "newer default shortcut route")
        routeExpectations.append(routedDefault)
        registrar.send(.keyUp, for: .focusLatestNotification)
        await fulfillment(of: [routedDefault], timeout: 1)
        await eventually {
            let focused = await defaultServer.focusedPaneIDs
            let requestCount = await defaultServer.paneListRequestCount
            return focused == ["duplicate"]
                && requestCount >= defaultSelectionRefreshBaseline + 1
        }
        let namedFocusAfterDefaultShortcut = await initialNamedServer.focusedPaneIDs.count
        XCTAssertEqual(namedFocusAfterDefaultShortcut, namedFocusBaseline)

        await namedServer?.setPanes([integrationPane("duplicate", .done)])
        await namedServer?.pushAgentStatusEvent(paneID: "duplicate", status: .done)
        await eventually { await notifications.deliveries.count == 4 }
        try await observedLatestTarget.waitForLatest(namedTarget, timeout: .seconds(1))
        let latestAfterNewerNamedDelivery = await latestTargetStore.latest()
        XCTAssertEqual(latestAfterNewerNamedDelivery, namedTarget)
        let latestDeliveredTarget = await notifications.deliveries.last?.event.target
        XCTAssertEqual(
            latestDeliveredTarget,
            namedTarget
        )

        namedServer?.stop()
        namedServer = nil
        await store.retry()
        await eventually {
            await MainActor.run {
                store.unavailableSessions.map(\.id) == [.named("work")]
            }
        }
        let hasPendingGrace = await graceSleeper.hasPendingWait(for: .seconds(10))
        XCTAssertTrue(hasPendingGrace)
        let defaultFocusBeforeGraceShortcut = await defaultServer.focusedPaneIDs
        let routedUnavailableNamed = expectation(description: "unavailable named shortcut route")
        routeExpectations.append(routedUnavailableNamed)
        registrar.send(.keyUp, for: .focusLatestNotification)
        await fulfillment(of: [routedUnavailableNamed], timeout: 1)
        let defaultFocusAfterGraceShortcut = await defaultServer.focusedPaneIDs
        XCTAssertEqual(defaultFocusAfterGraceShortcut, defaultFocusBeforeGraceShortcut)

        let reconnectedNamedServer = try FakeHerdrServer(
            url: namedURL,
            panes: [integrationPane("duplicate", .done)]
        )
        namedServer = reconnectedNamedServer
        await store.retry()
        await eventually {
            let focused = await reconnectedNamedServer.focusedPaneIDs
            let requestCount = await reconnectedNamedServer.paneListRequestCount
            return focused == ["duplicate"] && requestCount >= 2
        }
        let reconnectedNamedFocus = await reconnectedNamedServer.focusedPaneIDs
        let defaultFocusAfterReconnect = await defaultServer.focusedPaneIDs
        XCTAssertEqual(reconnectedNamedFocus, ["duplicate"])
        XCTAssertEqual(defaultFocusAfterReconnect, defaultFocusBeforeGraceShortcut)
        XCTAssertEqual(routedTargets, [
            NotificationSelectionTarget(sessionID: .named("work"), paneID: "duplicate"),
            NotificationSelectionTarget(sessionID: .named("work"), paneID: "duplicate"),
            NotificationSelectionTarget(sessionID: .default, paneID: "duplicate"),
            NotificationSelectionTarget(sessionID: .named("work"), paneID: "duplicate")
        ])
        registrar.send(.keyUp, for: .toggleMenu)
        await eventually { await MainActor.run { statusDriver.performClickCount == 1 } }
        registrar.send(.keyUp, for: .toggleMenu)
        await eventually { await MainActor.run { statusDriver.cancelTrackingCount == 1 } }
        XCTAssertEqual(statusDriver.performClickCount, 1)
        XCTAssertEqual(statusDriver.cancelTrackingCount, 1)

        await observedLatestTarget.finish()
        registrar.finish()
        await shortcutController.stop()
        await store.stop()
        statusController.stop()
        preferencesFixture.remove()
        defaultServer.stop()
        namedServer?.stop()
        namedServer = nil
        try FileManager.default.removeItem(at: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: namedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    @MainActor
    func testToggleGlobalShortcutOpensAndClosesRealStatusController() async {
        let registrar = IntegrationShortcutRegistrar()
        let statusDriver = IntegrationStatusItemDriver()
        let statusController = StatusItemController(driver: statusDriver) { _ in }
        let shortcutController = GlobalShortcutController(
            registrar: registrar,
            latestTarget: LatestNotificationTargetStore(),
            toggleMenu: { statusController.toggle() },
            selectTarget: { _ in }
        )
        addTeardownBlock {
            await MainActor.run { registrar.finish() }
            await shortcutController.stop()
        }
        statusController.start()
        shortcutController.start()

        registrar.send(.keyUp, for: .toggleMenu)
        await eventually { await MainActor.run { statusDriver.performClickCount == 1 } }
        registrar.send(.keyUp, for: .toggleMenu)
        await eventually { await MainActor.run { statusDriver.cancelTrackingCount == 1 } }

        XCTAssertEqual(statusDriver.performClickCount, 1)
        XCTAssertEqual(statusDriver.cancelTrackingCount, 1)
        registrar.finish()
        await shortcutController.stop()
        statusController.stop()
    }

    func testAttentionObserverBoundsMissingCompletionAndFinishReleasesPausedReconcile() async throws {
        let observer = IntegrationObservingAttentionCoordinator(
            wrapping: IntegrationAttentionCoordinator()
        )
        let start = ContinuousClock.now
        do {
            try await observer.waitForReconcileCompletion(
                for: .named("missing"),
                after: 0,
                timeout: .milliseconds(20)
            )
            XCTFail("Expected a bounded missing-completion error")
        } catch let error as IntegrationAttentionObserverError {
            XCTAssertEqual(error, .timedOut(.reconcile))
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))

        let session = SessionDescriptor(
            id: .named("paused"),
            socketURL: URL(fileURLWithPath: "/tmp/observer-paused.sock")
        )
        await observer.pauseNextReconcile(for: session.id)
        let reconcile = Task {
            await observer.reconcile(
                session: session,
                items: [],
                policy: NotificationDeliveryPolicy(
                    notificationsEnabled: true,
                    soundEnabled: false
                )
            )
        }
        try await observer.waitUntilReconcileIsPaused(
            for: session.id,
            timeout: .seconds(1)
        )

        await observer.finish()
        try await withIntegrationWatchdog(operation: .reconcile, timeout: .seconds(1)) {
            await reconcile.value
        }
    }

    func testTwoServersDeliverDistinctAttentionTransitionsAndRouteNotificationClickExactly() async throws {
        let root = try makeTemporaryHerdrRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let defaultURL = root.appending(path: "herdr.sock")
        let namedURL = root.appending(path: "sessions/work/herdr.sock")
        let defaultServer = try FakeHerdrServer(
            url: defaultURL,
            panes: [integrationPane("duplicate", .working)]
        )
        defer { defaultServer.stop() }
        var namedServer: FakeHerdrServer? = try FakeHerdrServer(
            url: namedURL,
            panes: [integrationPane("duplicate", .working)]
        )
        defer { namedServer?.stop() }

        let graceSleeper = IntegrationHoldingSleeper()
        let supervisor = SessionSupervisor(
            discovery: SessionDiscovery(configRoot: root),
            clientFactory: IntegrationClientFactory(),
            sleeper: graceSleeper,
            discoveryInterval: .seconds(30),
            removalGracePeriod: .seconds(10)
        )
        let notifications = IntegrationNotificationService()
        let latestTargetStore = LatestNotificationTargetStore()
        let liveCoordinator = AttentionNotificationCoordinator(
            service: notifications,
            latestTargetRecorder: latestTargetStore
        )
        let coordinator = IntegrationObservingAttentionCoordinator(wrapping: liveCoordinator)
        let activator = await MainActor.run { IntegrationRecordingActivator() }
        let focuser = await MainActor.run { IntegrationRecordingWezTermFocuser() }
        let preferencesFixture = try await MainActor.run { try IntegrationPreferencesFixture() }
        await MainActor.run {
            preferencesFixture.preferences.notificationsEnabled = true
        }
        let store = await MainActor.run {
            AgentStore(
                supervisor: supervisor,
                terminalActivator: activator,
                wezTermFocuser: focuser,
                attentionCoordinator: coordinator,
                notificationService: notifications,
                preferences: preferencesFixture.preferences
            )
        }
        addTeardownBlock {
            await coordinator.finish()
            await store.stop()
            await MainActor.run { preferencesFixture.remove() }
        }

        await store.start()
        await eventually {
            await MainActor.run { store.workingSections.count == 2 }
        }
        var deliveries = await notifications.deliveries
        XCTAssertEqual(deliveries, [])

        guard let initialNamedServer = namedServer else {
            await store.stop()
            return XCTFail("Expected named server")
        }
        await initialNamedServer.setPanes([integrationPane("duplicate", .blocked)])
        await initialNamedServer.pushAgentStatusEvent(paneID: "duplicate", status: .blocked)
        await eventually { await notifications.deliveries.count == 1 }
        deliveries = await notifications.deliveries
        XCTAssertEqual(deliveries[0].event, AttentionNotificationEvent(
            target: NotificationSelectionTarget(sessionID: .named("work"), paneID: "duplicate"),
            sessionName: "work",
            visibleLabel: "pane-duplicate · Claude",
            status: .blocked
        ))
        XCTAssertFalse(deliveries[0].sound)

        await defaultServer.setPanes([integrationPane("duplicate", .done)])
        await defaultServer.pushAgentStatusEvent(paneID: "duplicate", status: .done)
        await eventually { await notifications.deliveries.count == 2 }
        deliveries = await notifications.deliveries
        XCTAssertEqual(deliveries.map(\.event.target.sessionID), [.named("work"), .default])
        XCTAssertEqual(deliveries[1].event, AttentionNotificationEvent(
            target: NotificationSelectionTarget(sessionID: .default, paneID: "duplicate"),
            sessionName: "Default",
            visibleLabel: "pane-duplicate · Claude",
            status: .done
        ))
        XCTAssertFalse(deliveries[1].sound)

        await initialNamedServer.setPanes([integrationPane("duplicate", .done)])
        await initialNamedServer.pushAgentStatusEvent(paneID: "duplicate", status: .done)
        await eventually { await notifications.deliveries.count == 3 }
        deliveries = await notifications.deliveries
        XCTAssertEqual(deliveries[2].event, AttentionNotificationEvent(
            target: NotificationSelectionTarget(sessionID: .named("work"), paneID: "duplicate"),
            sessionName: "work",
            visibleLabel: "pane-duplicate · Claude",
            status: .done
        ))
        XCTAssertEqual(deliveries.map(\.sound), [false, false, false])

        await notifications.send(NotificationSelectionTarget(
            sessionID: .named("work"),
            paneID: "duplicate"
        ))
        await eventually { await initialNamedServer.focusedPaneIDs == ["duplicate"] }
        let defaultFocusedPaneIDs = await defaultServer.focusedPaneIDs
        let focusedSessionIDs = await MainActor.run { focuser.focusedSessionIDs }
        XCTAssertEqual(defaultFocusedPaneIDs, [])
        XCTAssertEqual(focusedSessionIDs, [.named("work")])

        namedServer?.stop()
        namedServer = nil
        await store.retry()
        await eventually {
            await MainActor.run { store.unavailableSessions.map(\.id) == [.named("work")] }
        }
        let reconnectBaseline = await coordinator.reconcileCompletionCount(for: .named("work"))
        await coordinator.pauseNextReconcile(for: .named("work"))
        let reconnectedNamedServer = try FakeHerdrServer(
            url: namedURL,
            panes: [integrationPane("duplicate", .done)]
        )
        namedServer = reconnectedNamedServer
        await store.retry()
        await eventually {
            await MainActor.run {
                store.attentionSections.contains { $0.id == .named("work") }
                    && store.unavailableSessions.isEmpty
            }
        }
        try await coordinator.waitUntilReconcileIsPaused(
            for: .named("work"),
            timeout: .seconds(1)
        )
        await coordinator.resumePausedReconcile(for: .named("work"))
        try await coordinator.waitForReconcileCompletion(
            for: .named("work"),
            after: reconnectBaseline,
            timeout: .seconds(1)
        )
        let reconnectDeliveryCount = await notifications.deliveries.count
        XCTAssertEqual(reconnectDeliveryCount, 3)

        let removalBaseline = await coordinator.removeCompletionCount(for: .named("work"))
        namedServer?.stop()
        namedServer = nil
        await store.retry()
        await eventually { await graceSleeper.hasPendingWait(for: .seconds(10)) }
        await graceSleeper.resumePendingWait(for: .seconds(10))
        await eventually {
            await MainActor.run {
                !store.unavailableSessions.contains { $0.id == .named("work") }
                    && !store.attentionSections.contains { $0.id == .named("work") }
            }
        }
        try await coordinator.waitForRemoveCompletion(
            for: .named("work"),
            after: removalBaseline,
            timeout: .seconds(1)
        )
        let recreationBaseline = await coordinator.reconcileCompletionCount(for: .named("work"))
        await coordinator.pauseNextReconcile(for: .named("work"))
        let recreatedNamedServer = try FakeHerdrServer(
            url: namedURL,
            panes: [integrationPane("duplicate", .blocked)]
        )
        namedServer = recreatedNamedServer
        await store.retry()
        await eventually {
            await MainActor.run { store.attentionSections.contains { $0.id == .named("work") } }
        }
        try await coordinator.waitUntilReconcileIsPaused(
            for: .named("work"),
            timeout: .seconds(1)
        )
        await coordinator.resumePausedReconcile(for: .named("work"))
        try await coordinator.waitForReconcileCompletion(
            for: .named("work"),
            after: recreationBaseline,
            timeout: .seconds(1)
        )
        let recreatedDeliveryCount = await notifications.deliveries.count
        XCTAssertEqual(recreatedDeliveryCount, 3)

        await coordinator.finish()
        await store.stop()
        await MainActor.run { preferencesFixture.remove() }
    }

    func testTwoServersBootstrapUpdateAndFocusIndependently() async throws {
        let root = try makeTemporaryHerdrRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let defaultServer = try FakeHerdrServer(
            url: root.appending(path: "herdr.sock"),
            panes: [integrationPane("duplicate", .done)]
        )
        defer { defaultServer.stop() }
        let namedServer = try FakeHerdrServer(
            url: root.appending(path: "sessions/work/herdr.sock"),
            panes: [integrationPane("duplicate", .working)]
        )
        defer { namedServer.stop() }

        let supervisor = SessionSupervisor(
            discovery: SessionDiscovery(configRoot: root),
            clientFactory: IntegrationClientFactory(),
            sleeper: IntegrationHoldingSleeper(),
            discoveryInterval: .seconds(30)
        )
        let activator = await MainActor.run { IntegrationRecordingActivator() }
        let focuser = await MainActor.run { IntegrationRecordingWezTermFocuser() }
        let notifications = IntegrationNotificationService()
        let coordinator = IntegrationAttentionCoordinator()
        let store = await MainActor.run {
            AgentStore(
                supervisor: supervisor,
                terminalActivator: activator,
                wezTermFocuser: focuser,
                attentionCoordinator: coordinator,
                notificationService: notifications
            )
        }
        await store.start()

        await eventually {
            await MainActor.run {
                store.attentionCount == 1 && store.workingSections.count == 1
            }
        }
        let initialIDs = await MainActor.run {
            (store.attentionSections.flatMap(\.items) + store.workingSections.flatMap(\.items))
                .map(\.id)
        }
        XCTAssertEqual(Set(initialIDs), [
            AgentMenuItemID(sessionID: .default, paneID: "duplicate"),
            AgentMenuItemID(sessionID: .named("work"), paneID: "duplicate")
        ])

        await namedServer.setPanes([integrationPane("duplicate", .blocked)])
        await namedServer.pushAgentStatusEvent(paneID: "duplicate", status: .blocked)
        await eventually {
            await MainActor.run { store.attentionCount == 2 }
        }

        let namedItem = await MainActor.run {
            store.attentionSections.first { $0.id == .named("work") }?.items.first
        }
        guard let namedItem else {
            XCTFail("Expected one named-session attention item")
            await store.stop()
            return
        }
        await store.select(namedItem)
        let namedFocused = await namedServer.focusedPaneIDs
        let defaultFocused = await defaultServer.focusedPaneIDs
        XCTAssertEqual(namedFocused, ["duplicate"])
        XCTAssertEqual(defaultFocused, [])
        await store.stop()
    }

    func testDuplicatePaneIDsFocusOwningHerdrServerAndOwningWezTermPane() async throws {
        let root = try makeTemporaryHerdrRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultServer = try FakeHerdrServer(
            url: root.appending(path: "herdr.sock"),
            panes: [integrationPane("duplicate", .done)]
        )
        defer { defaultServer.stop() }
        let namedServer = try FakeHerdrServer(
            url: root.appending(path: "sessions/work/herdr.sock"),
            panes: [integrationPane("duplicate", .done)]
        )
        defer { namedServer.stop() }

        let supervisor = SessionSupervisor(
            discovery: SessionDiscovery(configRoot: root),
            clientFactory: IntegrationClientFactory(),
            sleeper: IntegrationHoldingSleeper(),
            discoveryInterval: .seconds(30)
        )
        let activator = await MainActor.run { IntegrationRecordingActivator() }
        let wezTermCLI = await MainActor.run {
            IntegrationWezTermCLI(
                defaultServer: defaultServer,
                namedServer: namedServer,
                defaultPaneID: 41,
                namedPaneID: 82
            )
        }
        let wezTermFocuser = await MainActor.run {
            LiveWezTermFocusAdapter(
                supervisor: supervisor,
                cli: wezTermCLI,
                markerGenerator: { "herdr-menubar-focus:integration" }
            )
        }
        let preferencesFixture = try await MainActor.run { try IntegrationPreferencesFixture() }
        let notifications = IntegrationNotificationService()
        let coordinator = IntegrationAttentionCoordinator()
        let store = await MainActor.run {
            AgentStore(
                supervisor: supervisor,
                terminalActivator: activator,
                wezTermFocuser: wezTermFocuser,
                attentionCoordinator: coordinator,
                notificationService: notifications,
                preferences: preferencesFixture.preferences
            )
        }
        await store.start()
        await eventually {
            await MainActor.run { store.attentionCount == 2 }
        }

        guard let namedItem = await MainActor.run(body: {
            store.attentionSections.first { $0.id == .named("work") }?.items.first
        }) else {
            await store.stop()
            await MainActor.run { preferencesFixture.remove() }
            return XCTFail("Expected named-session attention item")
        }
        await store.select(namedItem)

        let namedFocused = await namedServer.focusedPaneIDs
        let defaultInitiallyFocused = await defaultServer.focusedPaneIDs
        XCTAssertEqual(namedFocused, ["duplicate"])
        XCTAssertEqual(defaultInitiallyFocused, [])
        let namedActivations = await MainActor.run { wezTermCLI.activatedPaneIDs }
        XCTAssertEqual(namedActivations, [82])
        let namedTitleActions = await namedServer.windowTitleActions
        let defaultInitialTitleActions = await defaultServer.windowTitleActions
        XCTAssertEqual(namedTitleActions, [
            .set("herdr-menubar-focus:integration"), .clear
        ])
        XCTAssertEqual(defaultInitialTitleActions, [])

        guard let defaultItem = await MainActor.run(body: {
            store.attentionSections.first { $0.id == .default }?.items.first
        }) else {
            await store.stop()
            await MainActor.run { preferencesFixture.remove() }
            return XCTFail("Expected default-session attention item")
        }
        await store.select(defaultItem)

        let allActivations = await MainActor.run { wezTermCLI.activatedPaneIDs }
        XCTAssertEqual(allActivations, [82, 41])
        let defaultFocused = await defaultServer.focusedPaneIDs
        let defaultTitleActions = await defaultServer.windowTitleActions
        XCTAssertEqual(defaultFocused, ["duplicate"])
        XCTAssertEqual(defaultTitleActions, [
            .set("herdr-menubar-focus:integration"), .clear
        ])
        await store.stop()
        await MainActor.run { preferencesFixture.remove() }
    }

    func testStoppingOneServerKeepsOtherConnectedAndRestartWithinGraceDoesNotDuplicate() async throws {
        let root = try makeTemporaryHerdrRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let defaultServer = try FakeHerdrServer(
            url: root.appending(path: "herdr.sock"),
            panes: [integrationPane("a", .done)]
        )
        defer { defaultServer.stop() }
        let namedURL = root.appending(path: "sessions/work/herdr.sock")
        var namedServer: FakeHerdrServer? = try FakeHerdrServer(
            url: namedURL,
            panes: [integrationPane("b", .done)]
        )
        defer { namedServer?.stop() }

        let graceSleeper = IntegrationHoldingSleeper()
        let supervisor = SessionSupervisor(
            discovery: SessionDiscovery(configRoot: root),
            clientFactory: IntegrationClientFactory(),
            sleeper: graceSleeper,
            discoveryInterval: .seconds(30),
            removalGracePeriod: .seconds(10)
        )
        let activator = await MainActor.run { IntegrationRecordingActivator() }
        let focuser = await MainActor.run { IntegrationRecordingWezTermFocuser() }
        let notifications = IntegrationNotificationService()
        let coordinator = IntegrationAttentionCoordinator()
        let store = await MainActor.run {
            AgentStore(
                supervisor: supervisor,
                terminalActivator: activator,
                wezTermFocuser: focuser,
                attentionCoordinator: coordinator,
                notificationService: notifications
            )
        }
        await store.start()
        await eventually {
            await MainActor.run { store.attentionCount == 2 }
        }

        namedServer?.stop()
        namedServer = nil
        await store.retry()
        await eventually {
            await MainActor.run {
                store.attentionCount == 1
                    && store.unavailableSessions.map(\.id) == [.named("work")]
            }
        }
        let stateWhileNamedUnavailable = await MainActor.run { store.connectionState }
        XCTAssertEqual(stateWhileNamedUnavailable, .connected)
        let defaultSectionIDs = await MainActor.run { store.attentionSections.map(\.id) }
        XCTAssertEqual(defaultSectionIDs, [.default])
        let hasPendingGrace = await graceSleeper.hasPendingWait(for: .seconds(10))
        XCTAssertTrue(hasPendingGrace)

        do {
            namedServer = try FakeHerdrServer(
                url: namedURL,
                panes: [integrationPane("b", .done)]
            )
        } catch {
            await store.stop()
            throw error
        }
        await store.retry()
        await eventually {
            await MainActor.run {
                store.attentionCount == 2
                    && store.attentionSections.filter { $0.id == .named("work") }.count == 1
            }
        }
        let namedSectionCount = await MainActor.run {
            store.attentionSections.filter { $0.id == .named("work") }.count
        }
        XCTAssertEqual(namedSectionCount, 1)
        await store.stop()
    }
}

private struct IntegrationClientFactory: SessionClientCreating {
    func makeClient(for descriptor: SessionDescriptor) async -> any SessionClientServing {
        HerdrClient(
            socketURL: descriptor.socketURL,
            backoff: BackoffPolicy(delays: [.milliseconds(10)], jitter: { 0 }),
            requestTimeout: .milliseconds(250),
            subscriptionRebuildDebounce: .milliseconds(10)
        )
    }
}

private struct IntegrationNotificationDelivery: Equatable, Sendable {
    let event: AttentionNotificationEvent
    let sound: Bool
}

private actor IntegrationNotificationDeliveryGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var isPaused = false
    private var arrivalWaiters: [Waiter] = []
    private var releaseWaiters: [Waiter] = []
    private var isFinished = false

    var pendingWaiterCount: Int {
        arrivalWaiters.count + releaseWaiters.count
    }

    func pauseDeliveryReturn(timeout: Duration) async throws {
        let gate = self
        try await withIntegrationWatchdog(operation: .deliveryRelease, timeout: timeout) {
            try await gate.awaitDeliveryReturnRelease()
        }
    }

    func waitUntilDeliveryReturnIsPaused(timeout: Duration) async throws {
        let gate = self
        try await withIntegrationWatchdog(operation: .deliveryPause, timeout: timeout) {
            try await gate.awaitDeliveryPause()
        }
    }

    func releaseDeliveryReturn() {
        guard !isFinished else { return }
        isPaused = false
        let ownedReleaseWaiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in ownedReleaseWaiters { waiter.continuation.resume() }
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        isPaused = false
        let waiters = arrivalWaiters + releaseWaiters
        arrivalWaiters.removeAll()
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(throwing: IntegrationAttentionObserverError.finished)
        }
    }

    private func awaitDeliveryReturnRelease() async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if isFinished {
                    continuation.resume(throwing: IntegrationAttentionObserverError.finished)
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    isPaused = true
                    let arrivals = arrivalWaiters
                    arrivalWaiters.removeAll()
                    for arrival in arrivals { arrival.continuation.resume() }
                    releaseWaiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelReleaseWaiter(id: waiterID) }
        }
    }

    private func awaitDeliveryPause() async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if isFinished {
                    continuation.resume(throwing: IntegrationAttentionObserverError.finished)
                } else if isPaused {
                    continuation.resume()
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    arrivalWaiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelArrivalWaiter(id: waiterID) }
        }
    }

    private func cancelArrivalWaiter(id: UUID) {
        cancelWaiter(id: id, in: &arrivalWaiters)
    }

    private func cancelReleaseWaiter(id: UUID) {
        cancelWaiter(id: id, in: &releaseWaiters)
        if releaseWaiters.isEmpty { isPaused = false }
    }

    private func cancelWaiter(id: UUID, in waiters: inout [Waiter]) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

private actor IntegrationObservedLatestTargetStore: LatestNotificationTargetRecording {
    private struct LookupWaiter {
        let id: UUID
        let count: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct TargetWaiter {
        let id: UUID
        let target: NotificationSelectionTarget
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct RegistrationWaiter {
        let id: UUID
        let latestCount: Int
        let lookupCount: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let wrapped: any LatestNotificationTargetRecording
    private var observedLatestTarget: NotificationSelectionTarget?
    private var lookupCount = 0
    private var lookupWaiters: [LookupWaiter] = []
    private var targetWaiters: [TargetWaiter] = []
    private var registrationWaiters: [RegistrationWaiter] = []
    private var isFinished = false

    init(wrapping wrapped: any LatestNotificationTargetRecording) {
        self.wrapped = wrapped
    }

    func record(_ target: NotificationSelectionTarget, ordinal: UInt64) async {
        await wrapped.record(target, ordinal: ordinal)
        observedLatestTarget = await wrapped.latest()
        let ready = targetWaiters.filter { $0.target == observedLatestTarget }
        targetWaiters.removeAll { $0.target == observedLatestTarget }
        for waiter in ready { waiter.continuation.resume() }
    }

    func latest() async -> NotificationSelectionTarget? {
        let target = await wrapped.latest()
        lookupCount += 1
        let ready = lookupWaiters.filter { $0.count <= lookupCount }
        lookupWaiters.removeAll { $0.count <= lookupCount }
        for waiter in ready { waiter.continuation.resume() }
        return target
    }

    func reset() async {
        await wrapped.reset()
        observedLatestTarget = nil
    }

    func sealAndReset() async {
        await wrapped.sealAndReset()
        observedLatestTarget = nil
    }

    var pendingWaiterCount: Int {
        lookupWaiters.count + targetWaiters.count + registrationWaiters.count
    }

    func waitForLookups(_ count: Int, timeout: Duration) async throws {
        let store = self
        try await withIntegrationWatchdog(operation: .latestTargetLookup, timeout: timeout) {
            try await store.awaitLookups(count)
        }
    }

    func waitForLatest(
        _ target: NotificationSelectionTarget,
        timeout: Duration
    ) async throws {
        let store = self
        try await withIntegrationWatchdog(operation: .latestTarget, timeout: timeout) {
            try await store.awaitLatest(target)
        }
    }

    func waitUntilWaitersArePending(
        latest: Int,
        lookups: Int,
        timeout: Duration
    ) async throws {
        let store = self
        try await withIntegrationWatchdog(operation: .signalWaiterRegistration, timeout: timeout) {
            try await store.awaitPendingWaiters(latest: latest, lookups: lookups)
        }
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        let waiters = lookupWaiters.map(\.continuation)
            + targetWaiters.map(\.continuation)
            + registrationWaiters.map(\.continuation)
        lookupWaiters.removeAll()
        targetWaiters.removeAll()
        registrationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(throwing: IntegrationAttentionObserverError.finished)
        }
    }

    private func awaitLookups(_ count: Int) async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if isFinished {
                    continuation.resume(throwing: IntegrationAttentionObserverError.finished)
                } else if lookupCount >= count {
                    continuation.resume()
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    lookupWaiters.append(LookupWaiter(
                        id: waiterID,
                        count: count,
                        continuation: continuation
                    ))
                    resumeReadyRegistrationWaiters()
                }
            }
        } onCancel: {
            Task { await self.cancelLookupWaiter(id: waiterID) }
        }
    }

    private func awaitLatest(_ target: NotificationSelectionTarget) async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if isFinished {
                    continuation.resume(throwing: IntegrationAttentionObserverError.finished)
                } else if observedLatestTarget == target {
                    continuation.resume()
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    targetWaiters.append(TargetWaiter(
                        id: waiterID,
                        target: target,
                        continuation: continuation
                    ))
                    resumeReadyRegistrationWaiters()
                }
            }
        } onCancel: {
            Task { await self.cancelTargetWaiter(id: waiterID) }
        }
    }

    private func awaitPendingWaiters(latest: Int, lookups: Int) async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if isFinished {
                    continuation.resume(throwing: IntegrationAttentionObserverError.finished)
                } else if targetWaiters.count >= latest && lookupWaiters.count >= lookups {
                    continuation.resume()
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    registrationWaiters.append(RegistrationWaiter(
                        id: waiterID,
                        latestCount: latest,
                        lookupCount: lookups,
                        continuation: continuation
                    ))
                }
            }
        } onCancel: {
            Task { await self.cancelRegistrationWaiter(id: waiterID) }
        }
    }

    private func cancelLookupWaiter(id: UUID) {
        guard let index = lookupWaiters.firstIndex(where: { $0.id == id }) else { return }
        lookupWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func cancelTargetWaiter(id: UUID) {
        guard let index = targetWaiters.firstIndex(where: { $0.id == id }) else { return }
        targetWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func cancelRegistrationWaiter(id: UUID) {
        guard let index = registrationWaiters.firstIndex(where: { $0.id == id }) else { return }
        registrationWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func resumeReadyRegistrationWaiters() {
        let ready = registrationWaiters.filter {
            targetWaiters.count >= $0.latestCount && lookupWaiters.count >= $0.lookupCount
        }
        let readyIDs = Set(ready.map(\.id))
        registrationWaiters.removeAll { readyIDs.contains($0.id) }
        for waiter in ready { waiter.continuation.resume() }
    }
}

@MainActor
private final class IntegrationShortcutRegistrar: ShortcutRegistering {
    private var continuations: [
        ShortcutAction: AsyncStream<GlobalShortcutEvent>.Continuation
    ] = [:]
    private var isFinished = false

    func shortcut(for action: ShortcutAction) -> ShortcutBinding? { nil }
    func setShortcut(_ shortcut: ShortcutBinding?, for action: ShortcutAction) {}
    func isEnabled(for action: ShortcutAction) -> Bool { false }
    func retryRegistration(for action: ShortcutAction) {}
    func isTakenBySystem(_ shortcut: ShortcutBinding) -> Bool { false }
    func conflictsWithMainMenu(_ shortcut: ShortcutBinding) -> Bool { false }
    func displayString(for shortcut: ShortcutBinding) -> String { "" }
    func setGlobalShortcutDeliveryEnabled(_ isEnabled: Bool) {}

    func events(for action: ShortcutAction) -> AsyncStream<GlobalShortcutEvent> {
        let (stream, continuation) = AsyncStream<GlobalShortcutEvent>.makeStream()
        continuations[action]?.finish()
        if isFinished {
            continuation.finish()
        } else {
            continuations[action] = continuation
        }
        return stream
    }

    func send(_ event: GlobalShortcutEvent, for action: ShortcutAction) {
        continuations[action]?.yield(event)
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        let ownedContinuations = Array(continuations.values)
        continuations.removeAll()
        for continuation in ownedContinuations { continuation.finish() }
    }
}

@MainActor
private final class IntegrationStatusItemDriver: StatusItemDriving {
    weak var delegate: (any StatusItemDriverDelegate)?
    private(set) var performClickCount = 0
    private(set) var cancelTrackingCount = 0

    func install(delegate: any StatusItemDriverDelegate) {
        self.delegate = delegate
    }

    func applyIcon(
        _ presentation: MenuBarIconPresentation,
        accessibilityValue: String
    ) {}

    func replaceMenu(
        with nodes: [StatusMenuNode],
        action: @escaping (StatusMenuAction) -> Void
    ) {}

    func performClick() {
        performClickCount += 1
        delegate?.statusItemMenuWillOpen()
    }

    func cancelTracking() {
        cancelTrackingCount += 1
        delegate?.statusItemMenuDidClose()
    }

    func remove() {}
}

private actor IntegrationNotificationService: NativeNotificationServing {
    private(set) var deliveries: [IntegrationNotificationDelivery] = []
    private var responseContinuation: AsyncStream<NotificationSelectionTarget>.Continuation?
    private let deliveryResult: NotificationDeliveryResult
    private let deliveryReturnGate: IntegrationNotificationDeliveryGate?

    init(
        deliveryResult: NotificationDeliveryResult = .accepted,
        deliveryReturnGate: IntegrationNotificationDeliveryGate? = nil
    ) {
        self.deliveryResult = deliveryResult
        self.deliveryReturnGate = deliveryReturnGate
    }

    func responses() async -> NotificationResponseSubscription {
        let (stream, continuation) = AsyncStream<NotificationSelectionTarget>.makeStream()
        responseContinuation?.finish()
        responseContinuation = continuation
        return NotificationResponseSubscription(
            stream: stream,
            cancellation: NotificationResponseCancellation {
                continuation.finish()
            }
        )
    }

    func send(_ target: NotificationSelectionTarget) {
        responseContinuation?.yield(target)
    }

    func requestAuthorization() async throws -> Bool { true }
    func settings() async -> NotificationSystemSettings { .authorized }
    func deliver(
        _ event: AttentionNotificationEvent,
        sound: Bool
    ) async throws -> NotificationDeliveryResult {
        deliveries.append(IntegrationNotificationDelivery(event: event, sound: sound))
        if let deliveryReturnGate {
            try await deliveryReturnGate.pauseDeliveryReturn(timeout: .seconds(1))
        }
        return deliveryResult
    }
}

private actor IntegrationAttentionCoordinator: AttentionNotificationCoordinating {
    func reconcile(
        session: SessionDescriptor,
        items: [AgentMenuItem],
        policy: NotificationDeliveryPolicy
    ) {}
    func unavailable(sessionID: SessionID) {}
    func remove(sessionID: SessionID) {}
    func reset() {}
}

private enum IntegrationAttentionObserverOperation: Equatable, Sendable {
    case reconcile
    case remove
    case pause
    case deliveryPause
    case deliveryRelease
    case latestTarget
    case latestTargetLookup
    case signalWaiterRegistration
}

private enum IntegrationAttentionObserverError: Error, Equatable, Sendable {
    case timedOut(IntegrationAttentionObserverOperation)
    case finished
}

private func withIntegrationWatchdog(
    operation: IntegrationAttentionObserverOperation,
    timeout: Duration,
    work: @escaping @Sendable () async throws -> Void
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw IntegrationAttentionObserverError.timedOut(operation)
        }
        defer { group.cancelAll() }
        _ = try await group.next()
    }
}

private actor IntegrationObservingAttentionCoordinator: AttentionNotificationCoordinating {
    private struct Waiter {
        let id: UUID
        let threshold: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct Pause {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct PauseArrivalWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let wrapped: any AttentionNotificationCoordinating
    private var reconcileCompletions: [SessionID: Int] = [:]
    private var removeCompletions: [SessionID: Int] = [:]
    private var reconcileWaiters: [SessionID: [Waiter]] = [:]
    private var removeWaiters: [SessionID: [Waiter]] = [:]
    private var reconcilePauses: Set<SessionID> = []
    private var pausedReconciles: [SessionID: Pause] = [:]
    private var pauseArrivalWaiters: [SessionID: [PauseArrivalWaiter]] = [:]
    private var isFinished = false

    init(wrapping wrapped: any AttentionNotificationCoordinating) {
        self.wrapped = wrapped
    }

    func reconcile(
        session: SessionDescriptor,
        items: [AgentMenuItem],
        policy: NotificationDeliveryPolicy
    ) async {
        if reconcilePauses.remove(session.id) != nil {
            do {
                try await waitForPauseRelease(for: session.id)
            } catch {
                return
            }
        }
        await wrapped.reconcile(session: session, items: items, policy: policy)
        recordCompletion(for: session.id, counts: &reconcileCompletions, waiters: &reconcileWaiters)
    }

    func unavailable(sessionID: SessionID) async {
        await wrapped.unavailable(sessionID: sessionID)
    }

    func remove(sessionID: SessionID) async {
        await wrapped.remove(sessionID: sessionID)
        recordCompletion(for: sessionID, counts: &removeCompletions, waiters: &removeWaiters)
    }

    func reset() async {
        await wrapped.reset()
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        reconcilePauses.removeAll()

        let pauses = pausedReconciles.values
        pausedReconciles.removeAll()
        for pause in pauses {
            pause.continuation.resume(throwing: IntegrationAttentionObserverError.finished)
        }

        let completionWaiters = reconcileWaiters.values.flatMap { $0 }
            + removeWaiters.values.flatMap { $0 }
        reconcileWaiters.removeAll()
        removeWaiters.removeAll()
        for waiter in completionWaiters {
            waiter.continuation.resume(throwing: IntegrationAttentionObserverError.finished)
        }

        let arrivalWaiters = pauseArrivalWaiters.values.flatMap { $0 }
        pauseArrivalWaiters.removeAll()
        for waiter in arrivalWaiters {
            waiter.continuation.resume(throwing: IntegrationAttentionObserverError.finished)
        }
    }

    func reconcileCompletionCount(for sessionID: SessionID) -> Int {
        reconcileCompletions[sessionID, default: 0]
    }

    func removeCompletionCount(for sessionID: SessionID) -> Int {
        removeCompletions[sessionID, default: 0]
    }

    func waitForReconcileCompletion(
        for sessionID: SessionID,
        after count: Int,
        timeout: Duration
    ) async throws {
        let observer = self
        try await withIntegrationWatchdog(operation: .reconcile, timeout: timeout) {
            try await observer.awaitReconcileCompletion(for: sessionID, after: count)
        }
    }

    func waitForRemoveCompletion(
        for sessionID: SessionID,
        after count: Int,
        timeout: Duration
    ) async throws {
        let observer = self
        try await withIntegrationWatchdog(operation: .remove, timeout: timeout) {
            try await observer.awaitRemoveCompletion(for: sessionID, after: count)
        }
    }

    func pauseNextReconcile(for sessionID: SessionID) {
        guard !isFinished else { return }
        reconcilePauses.insert(sessionID)
    }

    func waitUntilReconcileIsPaused(
        for sessionID: SessionID,
        timeout: Duration
    ) async throws {
        let observer = self
        try await withIntegrationWatchdog(operation: .pause, timeout: timeout) {
            try await observer.awaitReconcilePause(for: sessionID)
        }
    }

    func resumePausedReconcile(for sessionID: SessionID) {
        pausedReconciles.removeValue(forKey: sessionID)?.continuation.resume()
    }

    private func awaitReconcileCompletion(for sessionID: SessionID, after count: Int) async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if isFinished {
                    continuation.resume(throwing: IntegrationAttentionObserverError.finished)
                } else if reconcileCompletions[sessionID, default: 0] > count {
                    continuation.resume()
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    reconcileWaiters[sessionID, default: []].append(Waiter(
                        id: waiterID,
                        threshold: count,
                        continuation: continuation
                    ))
                }
            }
        } onCancel: {
            Task { await self.cancelReconcileWaiter(id: waiterID, sessionID: sessionID) }
        }
    }

    private func awaitRemoveCompletion(for sessionID: SessionID, after count: Int) async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if isFinished {
                    continuation.resume(throwing: IntegrationAttentionObserverError.finished)
                } else if removeCompletions[sessionID, default: 0] > count {
                    continuation.resume()
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    removeWaiters[sessionID, default: []].append(Waiter(
                        id: waiterID,
                        threshold: count,
                        continuation: continuation
                    ))
                }
            }
        } onCancel: {
            Task { await self.cancelRemoveWaiter(id: waiterID, sessionID: sessionID) }
        }
    }

    private func awaitReconcilePause(for sessionID: SessionID) async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if isFinished {
                    continuation.resume(throwing: IntegrationAttentionObserverError.finished)
                } else if pausedReconciles[sessionID] != nil {
                    continuation.resume()
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    pauseArrivalWaiters[sessionID, default: []].append(PauseArrivalWaiter(
                        id: waiterID,
                        continuation: continuation
                    ))
                }
            }
        } onCancel: {
            Task { await self.cancelPauseArrivalWaiter(id: waiterID, sessionID: sessionID) }
        }
    }

    private func waitForPauseRelease(for sessionID: SessionID) async throws {
        let pauseID = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if isFinished {
                    continuation.resume(throwing: IntegrationAttentionObserverError.finished)
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    pausedReconciles[sessionID] = Pause(id: pauseID, continuation: continuation)
                    let arrivals = pauseArrivalWaiters.removeValue(forKey: sessionID) ?? []
                    for arrival in arrivals {
                        arrival.continuation.resume()
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelPause(id: pauseID, sessionID: sessionID) }
        }
    }

    private func cancelReconcileWaiter(id: UUID, sessionID: SessionID) {
        cancelWaiter(id: id, sessionID: sessionID, waiters: &reconcileWaiters)
    }

    private func cancelRemoveWaiter(id: UUID, sessionID: SessionID) {
        cancelWaiter(id: id, sessionID: sessionID, waiters: &removeWaiters)
    }

    private func cancelWaiter(
        id: UUID,
        sessionID: SessionID,
        waiters: inout [SessionID: [Waiter]]
    ) {
        guard var sessionWaiters = waiters[sessionID],
              let index = sessionWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = sessionWaiters.remove(at: index)
        waiters[sessionID] = sessionWaiters.isEmpty ? nil : sessionWaiters
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func cancelPauseArrivalWaiter(id: UUID, sessionID: SessionID) {
        guard var waiters = pauseArrivalWaiters[sessionID],
              let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        pauseArrivalWaiters[sessionID] = waiters.isEmpty ? nil : waiters
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func cancelPause(id: UUID, sessionID: SessionID) {
        guard let pause = pausedReconciles[sessionID], pause.id == id else { return }
        pausedReconciles.removeValue(forKey: sessionID)
        pause.continuation.resume(throwing: CancellationError())
    }

    private func recordCompletion(
        for sessionID: SessionID,
        counts: inout [SessionID: Int],
        waiters: inout [SessionID: [Waiter]]
    ) {
        counts[sessionID, default: 0] += 1
        let count = counts[sessionID, default: 0]
        let waiting = waiters.removeValue(forKey: sessionID) ?? []
        for waiter in waiting where count > waiter.threshold {
            waiter.continuation.resume()
        }
        waiters[sessionID] = waiting.filter { count <= $0.threshold }
    }
}

@MainActor
private final class IntegrationRecordingActivator: TerminalActivating {
    private(set) var activationCount = 0

    func activate(bundleIdentifier: String) async throws {
        activationCount += 1
    }
}

@MainActor
private final class IntegrationPreferencesFixture {
    let preferences: Preferences

    private let defaults: UserDefaults
    private let suiteName: String

    init() throws {
        suiteName = "dev.herdr.menubar.integration.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw CocoaError(.fileWriteUnknown)
        }
        self.defaults = defaults
        defaults.removePersistentDomain(forName: suiteName)
        preferences = Preferences(defaults: defaults)
        preferences.selectedTerminalBundleIdentifier = WezTermCLIConstants.bundleIdentifier
    }

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
private final class IntegrationRecordingWezTermFocuser: WezTermSessionFocusing {
    private(set) var focusedSessionIDs: [SessionID] = []
    private(set) var forgottenSessionIDs: [SessionID] = []

    func focusAttachedClient(sessionID: SessionID) async throws {
        focusedSessionIDs.append(sessionID)
    }

    func forget(sessionID: SessionID) {
        forgottenSessionIDs.append(sessionID)
    }
}

@MainActor
private final class IntegrationWezTermCLI: WezTermCLIControlling {
    private let defaultServer: FakeHerdrServer
    private let namedServer: FakeHerdrServer
    private let defaultPaneID: Int
    private let namedPaneID: Int
    private(set) var activatedPaneIDs: [Int] = []

    init(
        defaultServer: FakeHerdrServer,
        namedServer: FakeHerdrServer,
        defaultPaneID: Int,
        namedPaneID: Int
    ) {
        self.defaultServer = defaultServer
        self.namedServer = namedServer
        self.defaultPaneID = defaultPaneID
        self.namedPaneID = namedPaneID
    }

    func listPanes(timeout: Duration) async -> [WezTermPane] {
        var panes: [WezTermPane] = []
        if let title = await defaultServer.currentWindowTitle {
            panes.append(WezTermPane(
                windowID: 1,
                tabID: 1,
                paneID: defaultPaneID,
                title: title
            ))
        }
        if let title = await namedServer.currentWindowTitle {
            panes.append(WezTermPane(
                windowID: 1,
                tabID: 2,
                paneID: namedPaneID,
                title: title
            ))
        }
        return panes
    }

    func activatePane(id: Int) {
        activatedPaneIDs.append(id)
    }
}

private actor IntegrationHoldingSleeper: Sleeper {
    private struct Wait {
        let id: UUID
        let duration: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var waits: [Wait] = []

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                waits.append(Wait(id: id, duration: duration, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waits.firstIndex(where: { $0.id == id }) else { return }
        waits.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    func hasPendingWait(for duration: Duration) -> Bool {
        waits.contains { $0.duration == duration }
    }

    @discardableResult
    func resumePendingWait(for duration: Duration) -> Bool {
        guard let index = waits.firstIndex(where: { $0.duration == duration }) else { return false }
        waits.remove(at: index).continuation.resume()
        return true
    }
}

private func eventually(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping @Sendable () async -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while clock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Condition was not met within one second", file: file, line: line)
}

private func makeTemporaryHerdrRoot() throws -> URL {
    let fileManager = FileManager.default
    for _ in 0..<20 {
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        let root = URL(fileURLWithPath: "/tmp/hm-\(suffix)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
            return root
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            continue
        }
    }
    throw FakeHerdrServerError.temporaryRootCollision
}

private func integrationPane(_ id: String, _ status: AgentStatus) -> PaneInfo {
    PaneInfo(
        paneID: id,
        terminalID: "terminal-\(id)",
        workspaceID: "workspace",
        tabID: "tab",
        focused: false,
        label: "pane-\(id)",
        agent: "claude",
        title: nil,
        displayAgent: "Claude",
        agentStatus: status,
        revision: 1
    )
}

private enum FakeHerdrServerError: Error {
    case temporaryRootCollision
    case socketPathTooLong
    case systemCall(String, Int32)
    case malformedRequest
    case unsupportedMethod(String)
    case missingPane(String)
}

private struct FakeServerRequest: Decodable, Sendable {
    let id: String
    let method: String
    let params: FakeServerRequestParams
}

private struct FakeServerRequestParams: Decodable, Sendable {
    let paneID: String?
    let title: String?

    private enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case title
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paneID = try container.decodeIfPresent(String.self, forKey: .paneID)
        title = try container.decodeIfPresent(String.self, forKey: .title)
    }
}

private struct FakeServerResponse<Result: Encodable>: Encodable {
    let id: String
    let result: Result
}

private struct FakeSubscriptionResult: Encodable {
    let type = "subscription_started"
}

private struct FakeServerAction: Sendable {
    let response: Data
    let isSubscription: Bool
}

private enum FakeWindowTitleAction: Equatable, Sendable {
    case set(String)
    case clear
}

private actor FakeHerdrServerState {
    private var panes: [PaneInfo]
    private var focused: [String] = []
    private var windowTitle: String?
    private var titleActions: [FakeWindowTitleAction] = []
    private var requestCounts: [String: Int] = [:]

    init(panes: [PaneInfo]) {
        self.panes = panes
    }

    func setPanes(_ panes: [PaneInfo]) {
        self.panes = panes
    }

    var focusedPaneIDs: [String] { focused }
    var currentWindowTitle: String? { windowTitle }
    var windowTitleActions: [FakeWindowTitleAction] { titleActions }
    var paneListRequestCount: Int { requestCounts["pane.list", default: 0] }

    func action(for request: FakeServerRequest) throws -> FakeServerAction {
        requestCounts[request.method, default: 0] += 1
        let encoder = JSONEncoder()
        let response: Data
        let isSubscription: Bool

        switch request.method {
        case "pane.list":
            response = try encoder.encode(FakeServerResponse(
                id: request.id,
                result: PaneListResult(type: "pane_list", panes: panes)
            ))
            isSubscription = false
        case "workspace.list":
            response = try encoder.encode(FakeServerResponse(
                id: request.id,
                result: WorkspaceListResult(type: "workspace_list", workspaces: [])
            ))
            isSubscription = false
        case "tab.list":
            response = try encoder.encode(FakeServerResponse(
                id: request.id,
                result: TabListResult(type: "tab_list", tabs: [])
            ))
            isSubscription = false
        case "events.subscribe":
            response = try encoder.encode(FakeServerResponse(
                id: request.id,
                result: FakeSubscriptionResult()
            ))
            isSubscription = true
        case "pane.focus":
            guard let paneID = request.params.paneID else {
                throw FakeHerdrServerError.malformedRequest
            }
            guard let pane = panes.first(where: { $0.paneID == paneID }) else {
                throw FakeHerdrServerError.missingPane(paneID)
            }
            focused.append(paneID)
            response = try encoder.encode(FakeServerResponse(
                id: request.id,
                result: PaneFocusResult(type: "pane_info", pane: pane)
            ))
            isSubscription = false
        case "client.window_title.set":
            guard let title = request.params.title else {
                throw FakeHerdrServerError.malformedRequest
            }
            windowTitle = title
            titleActions.append(.set(title))
            response = try encoder.encode(FakeServerResponse(
                id: request.id,
                result: ClientWindowTitleResult(
                    type: "client_window_title",
                    changed: true,
                    reason: "set"
                )
            ))
            isSubscription = false
        case "client.window_title.clear":
            windowTitle = nil
            titleActions.append(.clear)
            response = try encoder.encode(FakeServerResponse(
                id: request.id,
                result: ClientWindowTitleResult(
                    type: "client_window_title",
                    changed: true,
                    reason: "cleared"
                )
            ))
            isSubscription = false
        default:
            throw FakeHerdrServerError.unsupportedMethod(request.method)
        }
        return FakeServerAction(response: response, isSubscription: isSubscription)
    }
}

private final class FakeHerdrServer: @unchecked Sendable {
    let url: URL

    private let state: FakeHerdrServerState
    private let lock = NSLock()
    private let workers = DispatchGroup()
    private var listenerFD: Int32
    private var peerFDs: Set<Int32> = []
    private var subscriptionPeerFDs: Set<Int32> = []
    private var stopped = false

    init(url: URL, panes: [PaneInfo]) throws {
        self.url = url
        state = FakeHerdrServerState(panes: panes)

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = Darwin.unlink(url.path)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw FakeHerdrServerError.systemCall("socket", errno)
        }
        listenerFD = fd

        do {
            try Self.bindAndListen(fd: fd, path: url.path)
        } catch {
            Darwin.close(fd)
            _ = Darwin.unlink(url.path)
            throw error
        }

        workers.enter()
        let workers = workers
        Task.detached { [weak self, workers] in
            defer { workers.leave() }
            self?.acceptConnections(listenerFD: fd)
        }
    }

    deinit {
        stop()
    }

    func setPanes(_ panes: [PaneInfo]) async {
        await state.setPanes(panes)
    }

    func pushAgentStatusEvent(paneID: String, status: AgentStatus) async {
        let event = EventEnvelope(
            event: "pane.agent_status_changed",
            data: EventData(paneID: paneID, workspaceID: nil, agentStatus: status)
        )
        guard let data = try? JSONEncoder().encode(event) else { return }
        let peers = subscriptionPeers
        for peer in peers where !Self.sendLine(data, to: peer) {
            _ = Darwin.shutdown(peer, SHUT_RDWR)
        }
    }

    var focusedPaneIDs: [String] {
        get async { await state.focusedPaneIDs }
    }

    var currentWindowTitle: String? {
        get async { await state.currentWindowTitle }
    }

    var windowTitleActions: [FakeWindowTitleAction] {
        get async { await state.windowTitleActions }
    }

    var paneListRequestCount: Int {
        get async { await state.paneListRequestCount }
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let listener = listenerFD
        listenerFD = -1
        let peers = Array(peerFDs)
        lock.unlock()

        if listener >= 0 {
            _ = Darwin.shutdown(listener, SHUT_RDWR)
            Darwin.close(listener)
        }
        for peer in peers {
            _ = Darwin.shutdown(peer, SHUT_RDWR)
        }
        workers.wait()
        _ = Darwin.unlink(url.path)
    }

    private static func bindAndListen(fd: Int32, path: String) throws {
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw FakeHerdrServerError.socketPathTooLong
        }
        address.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
                _ = Darwin.strlcpy(destination, source, pathCapacity)
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                Darwin.bind(fd, addressPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            throw FakeHerdrServerError.systemCall("bind", errno)
        }
        guard Darwin.listen(fd, 32) == 0 else {
            throw FakeHerdrServerError.systemCall("listen", errno)
        }
    }

    private func acceptConnections(listenerFD: Int32) {
        while !isStopped {
            let peer = Darwin.accept(listenerFD, nil, nil)
            guard peer >= 0 else {
                if errno == EINTR { continue }
                return
            }
            configure(peer: peer)
            guard register(peer: peer) else {
                Darwin.close(peer)
                return
            }
            workers.enter()
            let workers = workers
            Task.detached { [weak self, workers] in
                defer { workers.leave() }
                guard let self else { return }
                defer {
                    self.close(peer: peer)
                }
                await self.serve(peer: peer)
            }
        }
    }

    private func serve(peer: Int32) async {
        var reader = SocketLineReader()
        while !isStopped {
            switch reader.nextLine(from: peer) {
            case .line(let data):
                do {
                    let request = try JSONDecoder().decode(FakeServerRequest.self, from: data)
                    let action = try await state.action(for: request)
                    guard Self.sendLine(action.response, to: peer) else { return }
                    if action.isSubscription {
                        markSubscription(peer: peer)
                    }
                } catch {
                    return
                }
            case .timedOut:
                continue
            case .closed:
                return
            }
        }
    }

    private func configure(peer: Int32) {
        var enabled: Int32 = 1
        let enabledSize = socklen_t(MemoryLayout.size(ofValue: enabled))
        _ = withUnsafePointer(to: &enabled) {
            Darwin.setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, $0, enabledSize)
        }
        var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
        let timeoutSize = socklen_t(MemoryLayout.size(ofValue: timeout))
        _ = withUnsafePointer(to: &timeout) {
            Darwin.setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, $0, timeoutSize)
        }
    }

    private static func sendLine(_ data: Data, to peer: Int32) -> Bool {
        var framed = data
        framed.append(0x0A)
        return framed.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return true }
            var sent = 0
            while sent < rawBuffer.count {
                let count = Darwin.send(peer, baseAddress.advanced(by: sent), rawBuffer.count - sent, 0)
                if count > 0 {
                    sent += count
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func register(peer: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return false }
        peerFDs.insert(peer)
        return true
    }

    private func markSubscription(peer: Int32) {
        lock.lock()
        subscriptionPeerFDs.insert(peer)
        lock.unlock()
    }

    private var subscriptionPeers: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return Array(subscriptionPeerFDs)
    }

    private func close(peer: Int32) {
        lock.lock()
        peerFDs.remove(peer)
        subscriptionPeerFDs.remove(peer)
        lock.unlock()
        Darwin.close(peer)
    }
}

private enum SocketReadResult {
    case line(Data)
    case timedOut
    case closed
}

private struct SocketLineReader {
    private var buffer = Data()

    mutating func nextLine(from fd: Int32) -> SocketReadResult {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                return .line(line)
            }

            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.recv(fd, &chunk, chunk.count, 0)
            if count > 0 {
                buffer.append(contentsOf: chunk.prefix(count))
            } else if count == 0 {
                return .closed
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return .timedOut
            } else {
                return .closed
            }
        }
    }
}
