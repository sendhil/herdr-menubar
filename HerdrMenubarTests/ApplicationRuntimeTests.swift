import AppKit
import Observation
import XCTest
@testable import HerdrMenubar

@MainActor
final class ApplicationRuntimeTests: XCTestCase {
    func testWidgetURLStartsRuntimeAndSelectsExactNamedSession() async {
        let harness = RuntimeHarness()
        let runtime = ApplicationRuntime(dependencies: harness.dependencies())
        await runtime.openWidgetURL(URL(string: "herdr-menubar://agent?session=named%3Awork&pane=wT%3Ap7")!)
        XCTAssertEqual(harness.storeStartCount, 1)
        XCTAssertEqual(harness.selectedTargets, [NotificationSelectionTarget(sessionID: .named("work"), paneID: "wT:p7")])
        await runtime.openWidgetURL(URL(string: "https://agent?session=default&pane=unwanted")!)
        XCTAssertEqual(harness.selectedTargets.count, 1)
        await runtime.stop()
    }

    func testStartInstallsHandlersRefreshesSettingsObservesThenStartsStoreExactlyOnce() async {
        let harness = RuntimeHarness()
        harness.blockNotificationRefresh = true
        let runtime = ApplicationRuntime(dependencies: harness.dependencies())

        let firstStart = Task { await runtime.start() }
        await harness.notificationRefreshEntered()

        XCTAssertEqual(harness.events, [
            "status.start",
            "shortcut.start",
            "login.refresh",
            "notification.refresh.begin"
        ])
        XCTAssertEqual(harness.storeStartCount, 0)

        harness.releaseNotificationRefresh()
        await firstStart.value
        await runtime.start()
        await runtime.start()

        XCTAssertEqual(harness.events, [
            "status.start",
            "shortcut.start",
            "login.refresh",
            "notification.refresh.begin",
            "notification.refresh.end",
            "shortcut.refresh",
            "status.apply.0",
            "store.start"
        ])
        XCTAssertEqual(harness.shortcutStartCount, 1)
        XCTAssertEqual(harness.storeStartCount, 1)
        await runtime.stop()
    }

    func testObservationImmediatelyAppliesAndRearmsAfterEveryChange() async {
        let harness = RuntimeHarness()
        let appliedThree = expectation(description: "three snapshots applied")
        appliedThree.expectedFulfillmentCount = 3
        harness.onApply = { _ in appliedThree.fulfill() }
        let runtime = ApplicationRuntime(dependencies: harness.dependencies())

        await runtime.start()
        harness.presentation.count = 1
        await harness.waitForAppliedCount(2)
        harness.presentation.count = 2
        await fulfillment(of: [appliedThree], timeout: 1)

        XCTAssertEqual(harness.appliedCounts, [0, 1, 2])
        await runtime.stop()
    }

    func testRuntimeAppliesIconWhileTrackingAndDefersStructuralReplacement() async {
        let harness = RuntimeHarness()
        let driver = RuntimeStatusItemDriver()
        let statusItem = StatusItemController(driver: driver) { _ in }
        harness.statusStart = { statusItem.start() }
        harness.statusApply = { statusItem.apply($0) }
        harness.statusStop = { statusItem.stop() }
        let runtime = ApplicationRuntime(dependencies: harness.dependencies())

        await runtime.start()
        driver.simulateMenuWillOpen()
        harness.presentation.count = 7
        await harness.waitForAppliedCount(2)

        XCTAssertEqual(driver.iconCounts, [0, 7])
        XCTAssertEqual(driver.menuCounts, [0, 0])

        driver.simulateMenuDidClose()
        XCTAssertEqual(driver.menuCounts, [0, 0, 7])
        await runtime.stop()
    }

    func testActivationRefreshesLoginNotificationAndShortcutRegistration() async {
        let harness = RuntimeHarness()
        let runtime = ApplicationRuntime(dependencies: harness.dependencies())
        await runtime.start()
        harness.events.removeAll()

        await runtime.applicationDidBecomeActive()

        XCTAssertEqual(harness.events, [
            "login.refresh",
            "notification.refresh.begin",
            "notification.refresh.end",
            "shortcut.refresh"
        ])
        await runtime.stop()
    }

    func testCallbacksRemainInertUntilStartupIsReadyThenBecomeActive() async {
        let harness = RuntimeHarness()
        harness.blockNotificationRefresh = true
        let runtime = ApplicationRuntime(dependencies: harness.dependencies())
        let target = NotificationSelectionTarget(sessionID: .named("work"), paneID: "pane-2")
        let activationFinished = RuntimeCancellableSignal()
        let prematureRefresh = RuntimeCancellableSignal()
        harness.onNotificationRefresh = { count in
            guard count == 2 else { return }
            Task { await prematureRefresh.signal() }
        }

        let starting = Task { await runtime.start() }
        await harness.notificationRefreshEntered()

        runtime.receiveToggleMenuShortcut()
        runtime.receiveFocusLatestShortcut(target)
        runtime.perform(.retryUnavailable)
        let activatingBeforeReady = Task {
            await runtime.applicationDidBecomeActive()
            await activationFinished.signal()
        }
        let firstActivationOutcome = await firstRuntimeSignal(
            completed: activationFinished,
            escapedRefresh: prematureRefresh
        )

        XCTAssertEqual(firstActivationOutcome, .completed)
        XCTAssertEqual(harness.statusToggleCount, 0)
        XCTAssertEqual(harness.selectedTargets, [])
        XCTAssertEqual(harness.retryCount, 0)
        XCTAssertEqual(harness.events.filter { $0 == "login.refresh" }.count, 1)
        XCTAssertEqual(harness.events.filter { $0 == "notification.refresh.begin" }.count, 1)

        harness.releaseNotificationRefresh()
        await starting.value
        await activatingBeforeReady.value

        runtime.receiveToggleMenuShortcut()
        runtime.receiveFocusLatestShortcut(target)
        runtime.perform(.retryUnavailable)
        await harness.waitForAsyncActions(1)
        await runtime.applicationDidBecomeActive()

        XCTAssertEqual(harness.statusToggleCount, 1)
        XCTAssertEqual(harness.selectedTargets, [target])
        XCTAssertEqual(harness.retryCount, 1)
        XCTAssertEqual(harness.events.filter { $0 == "login.refresh" }.count, 2)
        XCTAssertEqual(harness.events.filter { $0 == "notification.refresh.begin" }.count, 2)
        XCTAssertEqual(harness.events.filter { $0 == "shortcut.refresh" }.count, 2)
        await runtime.stop()
    }

    func testEveryStatusMenuActionMapsWithoutChangingItsPayload() async {
        let harness = RuntimeHarness()
        let runtime = ApplicationRuntime(dependencies: harness.dependencies())
        await runtime.start()
        harness.events.removeAll()
        let target = NotificationSelectionTarget(sessionID: .named("work"), paneID: "pane-2")

        runtime.perform(.select(target))
        runtime.perform(.selectTerminal("com.github.wez.wezterm"))
        runtime.perform(.setLaunchAtLogin(true))
        runtime.perform(.setNotifications(false))
        runtime.perform(.setSound(true))
        runtime.perform(.retryUnavailable)
        runtime.perform(.openKeyboardShortcuts)
        runtime.perform(.quit)
        await harness.waitForAsyncActions(3)

        XCTAssertTrue(harness.events.contains("store.select.work.pane-2"))
        XCTAssertTrue(harness.events.contains("terminal.select.com.github.wez.wezterm"))
        XCTAssertTrue(harness.events.contains("login.set.true"))
        XCTAssertTrue(harness.events.contains("notification.set.false"))
        XCTAssertTrue(harness.events.contains("sound.set.true"))
        XCTAssertTrue(harness.events.contains("store.retry"))
        XCTAssertTrue(harness.events.contains("settings.show"))
        XCTAssertTrue(harness.events.contains("quit"))
        await runtime.stop()
    }

    func testStopOwnsCancelsAndDrainsLoginMenuAction() async {
        await assertStopOwnsCancelsAndDrains(.login)
    }

    func testStopOwnsCancelsAndDrainsNotificationMenuAction() async {
        await assertStopOwnsCancelsAndDrains(.notifications)
    }

    func testStopOwnsCancelsAndDrainsRetryMenuAction() async {
        await assertStopOwnsCancelsAndDrains(.retry)
    }

    func testShutdownHasExactOrderAndRepeatedStopSharesOneBarrier() async {
        let harness = RuntimeHarness()
        harness.blockShortcutStop = true
        let runtime = ApplicationRuntime(dependencies: harness.dependencies())
        await runtime.start()
        harness.events.removeAll()

        let first = Task { await runtime.stop() }
        await harness.shortcutStopEntered()
        let second = Task { await runtime.stop() }
        let third = Task { await runtime.stop() }

        XCTAssertEqual(harness.events, ["lifecycle.invalidate", "shortcut.stop.begin"])

        harness.releaseShortcutStop()
        await first.value
        await second.value
        await third.value

        XCTAssertEqual(harness.events, [
            "lifecycle.invalidate",
            "shortcut.stop.begin",
            "shortcut.stop.end",
            "status.stop",
            "settings.stop",
            "observation.cancel",
            "target.sealAndReset",
            "actions.cancel",
            "actions.drain",
            "store.stop"
        ])
        XCTAssertEqual(harness.shortcutStopCount, 1)
        XCTAssertEqual(harness.storeStopCount, 1)
    }

    func testBlockedStartCannotResurrectAfterStop() async {
        let harness = RuntimeHarness()
        harness.blockNotificationRefresh = true
        let runtime = ApplicationRuntime(dependencies: harness.dependencies())

        let starting = Task { await runtime.start() }
        await harness.notificationRefreshEntered()
        await runtime.stop()

        XCTAssertEqual(harness.storeStartCount, 0)
        XCTAssertTrue(harness.appliedCounts.isEmpty)

        harness.releaseNotificationRefresh()
        await starting.value
        await runtime.start()

        XCTAssertEqual(harness.storeStartCount, 0)
        XCTAssertTrue(harness.appliedCounts.isEmpty)
        XCTAssertEqual(harness.statusStartCount, 1)
        XCTAssertEqual(harness.shortcutStartCount, 1)
    }

    func testShutdownCannotResurrectTargetFromAcceptedNoncooperativeDelivery() async {
        let supervisor = RuntimeNotificationSupervisor()
        let service = RuntimeNoncooperativeNotificationService()
        let latestTarget = LatestNotificationTargetStore()
        let coordinator = AttentionNotificationCoordinator(
            service: service,
            latestTargetRecorder: latestTarget
        )
        let suiteName = "dev.herdr.menubar.runtime-resurrection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = Preferences(defaults: defaults)
        preferences.notificationsEnabled = true
        let store = AgentStore(
            supervisor: supervisor,
            terminalActivator: RuntimeNoopTerminalActivator(),
            wezTermFocuser: RuntimeNoopWezTermFocuser(),
            attentionCoordinator: coordinator,
            notificationService: service,
            preferences: preferences
        )
        let resetFinished = RuntimeSignal()
        let harness = RuntimeHarness()
        harness.customStartStore = { await store.start() }
        harness.customStopStore = { await store.stop() }
        harness.customSealAndResetLatestTarget = {
            await latestTarget.sealAndReset()
            await resetFinished.signal()
        }
        let runtime = ApplicationRuntime(dependencies: harness.dependencies())
        let descriptor = SessionDescriptor(
            id: .default,
            socketURL: URL(fileURLWithPath: "/tmp/runtime-resurrection.sock")
        )

        await runtime.start()
        await supervisor.send(.connected(
            descriptor,
            runtimeSnapshot(status: .working)
        ))
        await supervisor.send(.snapshot(
            descriptor.id,
            runtimeSnapshot(status: .blocked)
        ))
        await service.waitForAttempt()

        let stopping = Task { await runtime.stop() }
        await resetFinished.wait()
        await service.release()
        await stopping.value

        let targetAfterStop = await latestTarget.latest()
        XCTAssertNil(targetAfterStop)
    }

    func testLateObservationAndShortcutCallbacksAreRejectedAfterStop() async {
        let harness = RuntimeHarness()
        let runtime = ApplicationRuntime(dependencies: harness.dependencies())
        await runtime.start()
        let applyCount = harness.appliedCounts.count

        await runtime.stop()
        harness.presentation.count = 9
        runtime.receiveToggleMenuShortcut()
        runtime.receiveFocusLatestShortcut(
            NotificationSelectionTarget(sessionID: .default, paneID: "late")
        )
        runtime.perform(.retryUnavailable)

        XCTAssertEqual(harness.appliedCounts.count, applyCount)
        XCTAssertEqual(harness.statusToggleCount, 0)
        XCTAssertEqual(harness.selectedTargets, [])
        XCTAssertEqual(harness.retryCount, 0)
    }

    func testDelegateStartsOnceRefreshesOnActivationAndRepliesAfterSharedStop() async {
        let runtime = DelegateRuntimeFake()
        let replies = expectation(description: "each pending termination receives one reply")
        replies.expectedFulfillmentCount = 2
        var replyValues: [Bool] = []
        let delegate = HerdrAppDelegate(runtime: runtime) { _, value in
            replyValues.append(value)
            replies.fulfill()
        }

        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )
        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )
        await runtime.waitForStarts(1)
        delegate.applicationDidBecomeActive(
            Notification(name: NSApplication.didBecomeActiveNotification)
        )
        await runtime.waitForActivations(1)

        XCTAssertEqual(
            delegate.applicationShouldTerminate(NSApplication.shared),
            .terminateLater
        )
        XCTAssertEqual(
            delegate.applicationShouldTerminate(NSApplication.shared),
            .terminateLater
        )
        await runtime.waitForStops(1)
        XCTAssertTrue(replyValues.isEmpty)

        runtime.releaseStop()
        await fulfillment(of: [replies], timeout: 1)

        XCTAssertEqual(runtime.startCount, 1)
        XCTAssertEqual(runtime.activationCount, 1)
        XCTAssertEqual(runtime.stopCount, 1)
        XCTAssertEqual(replyValues, [true, true])
    }

    private func assertStopOwnsCancelsAndDrains(
        _ kind: RuntimeGatedMenuActionKind,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let harness = RuntimeHarness()
        let entered = RuntimeSignal()
        let release = RuntimeSignal()
        var completedActions = 0
        var observedCancellation = false
        switch kind {
        case .login:
            harness.customSetLoginItem = { _ in
                await entered.signal()
                await release.wait()
                observedCancellation = Task.isCancelled
                completedActions += 1
                harness.events.append("login.action.finished")
            }
        case .notifications:
            harness.customSetNotifications = { _ in
                await entered.signal()
                await release.wait()
                observedCancellation = Task.isCancelled
                completedActions += 1
                harness.events.append("notification.action.finished")
            }
        case .retry:
            harness.customRetryStore = {
                await entered.signal()
                await release.wait()
                observedCancellation = Task.isCancelled
                completedActions += 1
                harness.events.append("retry.action.finished")
            }
        }
        let runtime = ApplicationRuntime(dependencies: harness.dependencies())
        await runtime.start()
        harness.events.removeAll()

        runtime.perform(kind.action)
        await entered.wait()

        var completedStops = 0
        let firstStop = Task {
            await runtime.stop()
            completedStops += 1
        }
        let secondStop = Task {
            await runtime.stop()
            completedStops += 1
        }
        firstStop.cancel()
        await harness.menuActionCancellationEntered()

        XCTAssertEqual(completedStops, 0, file: file, line: line)
        XCTAssertEqual(harness.storeStopCount, 0, file: file, line: line)

        await release.signal()
        await firstStop.value
        await secondStop.value

        XCTAssertEqual(completedActions, 1, file: file, line: line)
        XCTAssertTrue(observedCancellation, file: file, line: line)
        XCTAssertEqual(completedStops, 2, file: file, line: line)
        XCTAssertEqual(harness.storeStopCount, 1, file: file, line: line)
        XCTAssertLessThan(
            harness.events.firstIndex(of: kind.finishedEvent)!,
            harness.events.firstIndex(of: "store.stop")!,
            file: file,
            line: line
        )

        runtime.perform(kind.action)
        XCTAssertEqual(completedActions, 1, file: file, line: line)
    }
}

private enum RuntimeGatedMenuActionKind {
    case login
    case notifications
    case retry

    var action: StatusMenuAction {
        switch self {
        case .login: .setLaunchAtLogin(true)
        case .notifications: .setNotifications(true)
        case .retry: .retryUnavailable
        }
    }

    var finishedEvent: String {
        switch self {
        case .login: "login.action.finished"
        case .notifications: "notification.action.finished"
        case .retry: "retry.action.finished"
        }
    }
}

@Observable @MainActor
private final class RuntimePresentationState {
    var count = 0

    var snapshot: StatusItemPresentation {
        StatusItemPresentation(
            icon: MenuBarIconPresentation(connectionState: .connected, attentionCount: count),
            accessibilityValue: "snapshot \(count)",
            menu: [.heading("SNAPSHOT \(count)")]
        )
    }
}

@MainActor
private final class RuntimeHarness {
    let presentation = RuntimePresentationState()
    var events: [String] = []
    var appliedCounts: [Int] = []
    var selectedTargets: [NotificationSelectionTarget] = []
    var statusStartCount = 0
    var shortcutStartCount = 0
    var shortcutStopCount = 0
    var storeStartCount = 0
    var storeStopCount = 0
    var statusToggleCount = 0
    var retryCount = 0
    var blockNotificationRefresh = false
    var blockShortcutStop = false
    var onNotificationRefresh: ((Int) -> Void)?
    var onApply: ((StatusItemPresentation) -> Void)?
    var statusStart: (() -> Void)?
    var statusApply: ((StatusItemPresentation) -> Void)?
    var statusStop: (() -> Void)?
    var customStartStore: (() async -> Void)?
    var customStopStore: (() async -> Void)?
    var customSetLoginItem: ((Bool) async throws -> Void)?
    var customSetNotifications: ((Bool) async throws -> Void)?
    var customRetryStore: (() async -> Void)?
    var customSealAndResetLatestTarget: (() async -> Void)?

    private var notificationContinuations: [CheckedContinuation<Void, Never>] = []
    private var notificationEnteredWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var notificationEnterCount = 0
    private var shortcutContinuation: CheckedContinuation<Void, Never>?
    private var shortcutEnteredContinuation: CheckedContinuation<Void, Never>?
    private var shortcutDidEnter = false
    private var menuActionCancellationContinuation: CheckedContinuation<Void, Never>?
    private var menuActionCancellationDidEnter = false
    private var appliedWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var asyncActions = 0
    private var asyncActionWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func dependencies() -> ApplicationRuntimeDependencies {
        ApplicationRuntimeDependencies(
            startStatusItem: { [weak self] in
                guard let self else { return }
                statusStartCount += 1
                events.append("status.start")
                statusStart?()
            },
            applyStatusItem: { [weak self] snapshot in
                guard let self else { return }
                appliedCounts.append(snapshot.icon.attentionCount)
                events.append("status.apply.\(snapshot.icon.attentionCount)")
                statusApply?(snapshot)
                onApply?(snapshot)
                resumeAppliedWaiters()
            },
            toggleStatusItem: { [weak self] in
                self?.statusToggleCount += 1
                self?.events.append("status.toggle")
            },
            stopStatusItem: { [weak self] in
                self?.events.append("status.stop")
                self?.statusStop?()
            },
            startShortcuts: { [weak self] in
                self?.shortcutStartCount += 1
                self?.events.append("shortcut.start")
            },
            stopShortcuts: { [weak self] in
                guard let self else { return }
                shortcutStopCount += 1
                events.append("shortcut.stop.begin")
                shortcutDidEnter = true
                shortcutEnteredContinuation?.resume()
                shortcutEnteredContinuation = nil
                if blockShortcutStop {
                    await withCheckedContinuation { shortcutContinuation = $0 }
                }
                events.append("shortcut.stop.end")
            },
            showShortcutSettings: { [weak self] in self?.events.append("settings.show") },
            stopShortcutSettings: { [weak self] in self?.events.append("settings.stop") },
            refreshLoginItem: { [weak self] in self?.events.append("login.refresh") },
            setLoginItem: { [weak self] enabled in
                if let custom = self?.customSetLoginItem {
                    try await custom(enabled)
                    return
                }
                self?.events.append("login.set.\(enabled)")
                self?.markAsyncAction()
            },
            refreshNotifications: { [weak self] in
                guard let self else { return }
                events.append("notification.refresh.begin")
                notificationEnterCount += 1
                onNotificationRefresh?(notificationEnterCount)
                let ready = notificationEnteredWaiters.filter { notificationEnterCount >= $0.0 }
                notificationEnteredWaiters.removeAll { notificationEnterCount >= $0.0 }
                ready.forEach { $0.1.resume() }
                if blockNotificationRefresh {
                    await withCheckedContinuation { notificationContinuations.append($0) }
                }
                events.append("notification.refresh.end")
            },
            setNotifications: { [weak self] enabled in
                if let custom = self?.customSetNotifications {
                    try await custom(enabled)
                    return
                }
                self?.events.append("notification.set.\(enabled)")
                self?.markAsyncAction()
            },
            setSound: { [weak self] enabled in self?.events.append("sound.set.\(enabled)") },
            refreshShortcutRegistration: { [weak self] in self?.events.append("shortcut.refresh") },
            startStore: { [weak self] in
                self?.storeStartCount += 1
                self?.events.append("store.start")
                await self?.customStartStore?()
            },
            stopStore: { [weak self] in
                self?.storeStopCount += 1
                self?.events.append("store.stop")
                await self?.customStopStore?()
            },
            retryStore: { [weak self] in
                if let custom = self?.customRetryStore {
                    await custom()
                    return
                }
                self?.retryCount += 1
                self?.events.append("store.retry")
                self?.markAsyncAction()
            },
            selectTarget: { [weak self] target in
                self?.selectedTargets.append(target)
                self?.events.append("store.select.\(target.sessionID.displayName).\(target.paneID)")
            },
            selectTerminal: { [weak self] id in self?.events.append("terminal.select.\(id)") },
            sealAndResetLatestTarget: { [weak self] in
                self?.events.append("target.sealAndReset")
                await self?.customSealAndResetLatestTarget?()
            },
            makePresentation: { [weak self] in self?.presentation.snapshot ?? RuntimePresentationState().snapshot },
            quit: { [weak self] in self?.events.append("quit") },
            lifecycleInvalidated: { [weak self] in self?.events.append("lifecycle.invalidate") },
            observationCancelled: { [weak self] in self?.events.append("observation.cancel") },
            menuActionsCancelled: { [weak self] in
                guard let self else { return }
                events.append("actions.cancel")
                menuActionCancellationDidEnter = true
                menuActionCancellationContinuation?.resume()
                menuActionCancellationContinuation = nil
            },
            menuActionsDrained: { [weak self] in self?.events.append("actions.drain") },
            shouldStartSynchronization: true
        )
    }

    func notificationRefreshEntered(count: Int = 1) async {
        if notificationEnterCount >= count { return }
        await withCheckedContinuation { notificationEnteredWaiters.append((count, $0)) }
    }

    func releaseNotificationRefresh() {
        blockNotificationRefresh = false
        let continuations = notificationContinuations
        notificationContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func shortcutStopEntered() async {
        if shortcutDidEnter { return }
        await withCheckedContinuation { shortcutEnteredContinuation = $0 }
    }

    func menuActionCancellationEntered() async {
        if menuActionCancellationDidEnter { return }
        await withCheckedContinuation { menuActionCancellationContinuation = $0 }
    }

    func releaseShortcutStop() {
        blockShortcutStop = false
        shortcutContinuation?.resume()
        shortcutContinuation = nil
    }

    func waitForAppliedCount(_ count: Int) async {
        if appliedCounts.count >= count { return }
        await withCheckedContinuation { appliedWaiters.append((count, $0)) }
    }

    func waitForAsyncActions(_ count: Int) async {
        if asyncActions >= count { return }
        await withCheckedContinuation { asyncActionWaiters.append((count, $0)) }
    }

    private func resumeAppliedWaiters() {
        let ready = appliedWaiters.filter { appliedCounts.count >= $0.0 }
        appliedWaiters.removeAll { appliedCounts.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }

    private func markAsyncAction() {
        asyncActions += 1
        let ready = asyncActionWaiters.filter { asyncActions >= $0.0 }
        asyncActionWaiters.removeAll { asyncActions >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
}

private func runtimeSnapshot(status: AgentStatus) -> PresentationSnapshot {
    PresentationSnapshot(
        panes: [PaneInfo(
            paneID: "accepted-late",
            terminalID: "terminal",
            workspaceID: "workspace",
            tabID: "tab",
            focused: false,
            label: "Late",
            agent: "claude",
            title: "Late",
            displayAgent: "Claude",
            agentStatus: status,
            revision: 1
        )],
        workspaces: [],
        tabs: []
    )
}

private actor RuntimeSignal {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        isSignaled = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }

    func wait() async {
        guard !isSignaled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private enum RuntimeActivationOutcome: Sendable {
    case completed
    case escapedRefresh
}

private actor RuntimeCancellableSignal {
    private var isSignaled = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func signal() {
        isSignaled = true
        let current = waiters.values
        waiters.removeAll()
        current.forEach { $0.resume() }
    }

    func wait() async {
        guard !isSignaled else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if isSignaled || Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }
}

private func firstRuntimeSignal(
    completed: RuntimeCancellableSignal,
    escapedRefresh: RuntimeCancellableSignal
) async -> RuntimeActivationOutcome {
    await withTaskGroup(of: RuntimeActivationOutcome.self) { group in
        group.addTask {
            await completed.wait()
            return .completed
        }
        group.addTask {
            await escapedRefresh.wait()
            return .escapedRefresh
        }
        let first = await group.next()!
        group.cancelAll()
        return first
    }
}

private actor RuntimeNotificationSupervisor: SessionSupervising {
    private var continuation: AsyncStream<SessionSupervisorEvent>.Continuation?

    func events() -> AsyncStream<SessionSupervisorEvent> {
        let (stream, continuation) = AsyncStream<SessionSupervisorEvent>.makeStream()
        self.continuation = continuation
        return stream
    }

    func start() {}
    func stop() { continuation?.finish() }
    func retryUnavailable() {}
    func focus(sessionID: SessionID, paneID: String) throws -> PaneInfo {
        runtimeSnapshot(status: .working).panes[0]
    }
    func setClientWindowTitle(
        sessionID: SessionID,
        title: String
    ) throws -> ClientWindowTitleResult {
        ClientWindowTitleResult(type: "client_window_title", changed: false, reason: "test")
    }
    func clearClientWindowTitle(
        sessionID: SessionID,
        timeout: Duration
    ) throws -> ClientWindowTitleResult {
        ClientWindowTitleResult(type: "client_window_title", changed: false, reason: "test")
    }
    func refresh(sessionID: SessionID) {}
    func send(_ event: SessionSupervisorEvent) { continuation?.yield(event) }
}

private actor RuntimeNoncooperativeNotificationService: NativeNotificationServing {
    private let attempted = RuntimeSignal()
    private let releaseGate = RuntimeSignal()

    func responses() -> NotificationResponseSubscription { .finished() }
    func requestAuthorization() throws -> Bool { true }
    func settings() -> NotificationSystemSettings { .authorized }
    func deliver(
        _ event: AttentionNotificationEvent,
        sound: Bool
    ) async throws -> NotificationDeliveryResult {
        await attempted.signal()
        await releaseGate.wait()
        return .accepted
    }
    func waitForAttempt() async { await attempted.wait() }
    func release() async { await releaseGate.signal() }
}

@MainActor
private struct RuntimeNoopTerminalActivator: TerminalActivating {
    func activate(bundleIdentifier: String) async throws {}
}

@MainActor
private final class RuntimeNoopWezTermFocuser: WezTermSessionFocusing {
    func focusAttachedClient(sessionID: SessionID) async throws {}
    func forget(sessionID: SessionID) {}
}

@MainActor
private final class RuntimeStatusItemDriver: StatusItemDriving {
    private weak var delegate: (any StatusItemDriverDelegate)?
    private(set) var iconCounts: [Int] = []
    private(set) var menuCounts: [Int] = []

    func install(delegate: any StatusItemDriverDelegate) { self.delegate = delegate }
    func applyIcon(_ presentation: MenuBarIconPresentation, accessibilityValue: String) {
        iconCounts.append(presentation.attentionCount)
    }
    func replaceMenu(
        with nodes: [StatusMenuNode],
        action: @escaping (StatusMenuAction) -> Void
    ) {
        guard case let .heading(title)? = nodes.first,
              let count = Int(title.replacingOccurrences(of: "SNAPSHOT ", with: "")) else {
            return
        }
        menuCounts.append(count)
    }
    func performClick() {}
    func cancelTracking() {}
    func remove() {}
    func simulateMenuWillOpen() { delegate?.statusItemMenuWillOpen() }
    func simulateMenuDidClose() { delegate?.statusItemMenuDidClose() }
}

@MainActor
private final class DelegateRuntimeFake: ApplicationRuntimeServing {
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var activationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var stopWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var startCount = 0
    private(set) var activationCount = 0
    private(set) var stopCount = 0

    func start() async {
        startCount += 1
        resume(&startWaiters, current: startCount)
    }

    func applicationDidBecomeActive() async {
        activationCount += 1
        resume(&activationWaiters, current: activationCount)
    }

    func stop() async {
        stopCount += 1
        resume(&stopWaiters, current: stopCount)
        await withCheckedContinuation { stopContinuation = $0 }
    }

    func waitForStarts(_ count: Int) async {
        if startCount >= count { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }
    func waitForActivations(_ count: Int) async {
        if activationCount >= count { return }
        await withCheckedContinuation { activationWaiters.append((count, $0)) }
    }
    func waitForStops(_ count: Int) async {
        if stopCount >= count { return }
        await withCheckedContinuation { stopWaiters.append((count, $0)) }
    }
    func releaseStop() {
        stopContinuation?.resume()
        stopContinuation = nil
    }

    private func resume(
        _ waiters: inout [(Int, CheckedContinuation<Void, Never>)],
        current: Int
    ) {
        let ready = waiters.filter { current >= $0.0 }
        waiters.removeAll { current >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
}
