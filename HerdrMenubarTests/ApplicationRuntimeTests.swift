import AppKit
import Observation
import XCTest
@testable import HerdrMenubar

@MainActor
final class ApplicationRuntimeTests: XCTestCase {
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
            "target.reset",
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
    var onApply: ((StatusItemPresentation) -> Void)?
    var statusStart: (() -> Void)?
    var statusApply: ((StatusItemPresentation) -> Void)?
    var statusStop: (() -> Void)?

    private var notificationContinuation: CheckedContinuation<Void, Never>?
    private var notificationEnteredContinuation: CheckedContinuation<Void, Never>?
    private var notificationDidEnter = false
    private var shortcutContinuation: CheckedContinuation<Void, Never>?
    private var shortcutEnteredContinuation: CheckedContinuation<Void, Never>?
    private var shortcutDidEnter = false
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
                self?.events.append("login.set.\(enabled)")
                self?.markAsyncAction()
            },
            refreshNotifications: { [weak self] in
                guard let self else { return }
                events.append("notification.refresh.begin")
                notificationDidEnter = true
                notificationEnteredContinuation?.resume()
                notificationEnteredContinuation = nil
                if blockNotificationRefresh {
                    await withCheckedContinuation { notificationContinuation = $0 }
                }
                events.append("notification.refresh.end")
            },
            setNotifications: { [weak self] enabled in
                self?.events.append("notification.set.\(enabled)")
                self?.markAsyncAction()
            },
            setSound: { [weak self] enabled in self?.events.append("sound.set.\(enabled)") },
            refreshShortcutRegistration: { [weak self] in self?.events.append("shortcut.refresh") },
            startStore: { [weak self] in
                self?.storeStartCount += 1
                self?.events.append("store.start")
            },
            stopStore: { [weak self] in
                self?.storeStopCount += 1
                self?.events.append("store.stop")
            },
            retryStore: { [weak self] in
                self?.retryCount += 1
                self?.events.append("store.retry")
                self?.markAsyncAction()
            },
            selectTarget: { [weak self] target in
                self?.selectedTargets.append(target)
                self?.events.append("store.select.\(target.sessionID.displayName).\(target.paneID)")
            },
            selectTerminal: { [weak self] id in self?.events.append("terminal.select.\(id)") },
            resetLatestTarget: { [weak self] in self?.events.append("target.reset") },
            makePresentation: { [weak self] in self?.presentation.snapshot ?? RuntimePresentationState().snapshot },
            quit: { [weak self] in self?.events.append("quit") },
            lifecycleInvalidated: { [weak self] in self?.events.append("lifecycle.invalidate") },
            observationCancelled: { [weak self] in self?.events.append("observation.cancel") },
            shouldStartSynchronization: true
        )
    }

    func notificationRefreshEntered() async {
        if notificationDidEnter { return }
        await withCheckedContinuation { notificationEnteredContinuation = $0 }
    }

    func releaseNotificationRefresh() {
        blockNotificationRefresh = false
        notificationContinuation?.resume()
        notificationContinuation = nil
    }

    func shortcutStopEntered() async {
        if shortcutDidEnter { return }
        await withCheckedContinuation { shortcutEnteredContinuation = $0 }
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
