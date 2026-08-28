import XCTest
@testable import HerdrMenubar

@MainActor
final class GlobalShortcutControllerTests: XCTestCase {
    func testKeyDownIsIgnoredAndEachKeyUpRoutesItsActionExactlyOnce() async {
        let registrar = GlobalShortcutRegistrarFake()
        let latestTarget = GlobalShortcutTargetFake(
            target: NotificationSelectionTarget(sessionID: .named("work"), paneID: "p1")
        )
        var toggleCount = 0
        var selectedTargets: [NotificationSelectionTarget] = []
        let toggled = expectation(description: "menu toggled")
        let selected = expectation(description: "target selected")
        let controller = GlobalShortcutController(
            registrar: registrar,
            latestTarget: latestTarget,
            toggleMenu: {
                toggleCount += 1
                toggled.fulfill()
            },
            selectTarget: {
                selectedTargets.append($0)
                selected.fulfill()
            }
        )
        controller.start()

        registrar.send(.keyDown, for: .toggleMenu)
        registrar.send(.keyDown, for: .focusLatestNotification)
        registrar.send(.keyUp, for: .toggleMenu)
        registrar.send(.keyUp, for: .focusLatestNotification)
        await fulfillment(of: [toggled, selected], timeout: 1)

        XCTAssertEqual(toggleCount, 1)
        XCTAssertEqual(
            selectedTargets,
            [NotificationSelectionTarget(sessionID: .named("work"), paneID: "p1")]
        )
        let lookupCount = await latestTarget.lookupCount
        XCTAssertEqual(lookupCount, 1)
        await controller.stop()
    }

    func testLatestKeyUpWithNoCurrentRunTargetIsInert() async {
        let registrar = GlobalShortcutRegistrarFake()
        let latestTarget = GlobalShortcutTargetFake(target: nil)
        var toggleCount = 0
        var selectedTargets: [NotificationSelectionTarget] = []
        let barrier = expectation(description: "later toggle event consumed")
        let controller = GlobalShortcutController(
            registrar: registrar,
            latestTarget: latestTarget,
            toggleMenu: {
                toggleCount += 1
                barrier.fulfill()
            },
            selectTarget: { selectedTargets.append($0) }
        )
        controller.start()

        registrar.send(.keyUp, for: .focusLatestNotification)
        await latestTarget.waitForLookups(1)
        registrar.send(.keyUp, for: .toggleMenu)
        await fulfillment(of: [barrier], timeout: 1)

        XCTAssertEqual(toggleCount, 1)
        XCTAssertTrue(selectedTargets.isEmpty)
        await controller.stop()
    }

    func testRepeatedPressesReuseTargetAndNewerTargetWins() async {
        let old = NotificationSelectionTarget(sessionID: .default, paneID: "old")
        let newest = NotificationSelectionTarget(sessionID: .named("work"), paneID: "new")
        let registrar = GlobalShortcutRegistrarFake()
        let latestTarget = GlobalShortcutTargetFake(target: old)
        var selectedTargets: [NotificationSelectionTarget] = []
        let firstTwo = expectation(description: "same target selected twice")
        firstTwo.expectedFulfillmentCount = 2
        let third = expectation(description: "new target selected")
        let controller = GlobalShortcutController(
            registrar: registrar,
            latestTarget: latestTarget,
            toggleMenu: {},
            selectTarget: { target in
                selectedTargets.append(target)
                if selectedTargets.count <= 2 {
                    firstTwo.fulfill()
                } else {
                    third.fulfill()
                }
            }
        )
        controller.start()

        registrar.send(.keyUp, for: .focusLatestNotification)
        registrar.send(.keyUp, for: .focusLatestNotification)
        await fulfillment(of: [firstTwo], timeout: 1)
        await latestTarget.setTarget(newest)
        registrar.send(.keyUp, for: .focusLatestNotification)
        await fulfillment(of: [third], timeout: 1)

        XCTAssertEqual(selectedTargets, [old, old, newest])
        let lookupCount = await latestTarget.lookupCount
        XCTAssertEqual(lookupCount, 3)
        await controller.stop()
    }

    func testStartInstallsExactlyTwoConsumersAndRepeatedStartIsIdempotent() async {
        let registrar = GlobalShortcutRegistrarFake()
        let controller = GlobalShortcutController(
            registrar: registrar,
            latestTarget: GlobalShortcutTargetFake(target: nil),
            toggleMenu: {},
            selectTarget: { _ in }
        )

        controller.start()
        controller.start()
        controller.start()

        XCTAssertEqual(registrar.eventRequests, ShortcutAction.allCases)
        XCTAssertEqual(registrar.eventRequests.count, 2)
        await controller.stop()
    }

    func testStopCancelsAndAwaitsBothConsumers() async {
        let registrar = GlobalShortcutRegistrarFake()
        let latestTarget = GlobalShortcutTargetFake(target: nil)
        let toggleConsumed = expectation(description: "toggle consumer entered stream")
        let controller = GlobalShortcutController(
            registrar: registrar,
            latestTarget: latestTarget,
            toggleMenu: { toggleConsumed.fulfill() },
            selectTarget: { _ in }
        )
        controller.start()
        registrar.send(.keyUp, for: .toggleMenu)
        registrar.send(.keyUp, for: .focusLatestNotification)
        await fulfillment(of: [toggleConsumed], timeout: 1)
        await latestTarget.waitForLookups(1)

        await controller.stop()
        await registrar.waitForTerminations(2)

        let terminatedActions = await registrar.terminatedActions()
        let terminationCount = await registrar.terminationCount()
        XCTAssertEqual(terminatedActions, Set(ShortcutAction.allCases))
        XCTAssertEqual(terminationCount, 2)
    }

    func testEventFromStoppedGenerationIsIgnored() async {
        let registrar = GlobalShortcutRegistrarFake()
        var toggleCount = 0
        let controller = GlobalShortcutController(
            registrar: registrar,
            latestTarget: GlobalShortcutTargetFake(target: nil),
            toggleMenu: { toggleCount += 1 },
            selectTarget: { _ in }
        )
        controller.start()
        await controller.stop()

        registrar.send(.keyUp, for: .toggleMenu, streamIndex: 0)

        XCTAssertEqual(toggleCount, 0)
    }

    func testBlockedLatestLookupCompletingAfterStopCannotSelect() async {
        let target = NotificationSelectionTarget(sessionID: .named("work"), paneID: "blocked")
        let registrar = GlobalShortcutRegistrarFake()
        let latestTarget = GlobalShortcutTargetFake(target: target, blocksNextLookup: true)
        var selectedTargets: [NotificationSelectionTarget] = []
        let toggleConsumed = expectation(description: "toggle consumer entered stream")
        let controller = GlobalShortcutController(
            registrar: registrar,
            latestTarget: latestTarget,
            toggleMenu: { toggleConsumed.fulfill() },
            selectTarget: { selectedTargets.append($0) }
        )
        controller.start()
        registrar.send(.keyUp, for: .toggleMenu)
        await fulfillment(of: [toggleConsumed], timeout: 1)
        registrar.send(.keyUp, for: .focusLatestNotification)
        await latestTarget.waitForLookups(1)

        var stopCompleted = false
        let stopping = Task {
            await controller.stop()
            stopCompleted = true
        }
        await registrar.waitForTerminations(1)
        XCTAssertFalse(stopCompleted)
        await latestTarget.releaseLookup()
        await stopping.value
        await registrar.waitForTerminations(2)

        XCTAssertTrue(stopCompleted)
        XCTAssertTrue(selectedTargets.isEmpty)
        let terminationCount = await registrar.terminationCount()
        XCTAssertEqual(terminationCount, 2)
    }

    func testJoiningStopIsCompleteBarrierBeforeRestartWithTripleCallers() async {
        let target = NotificationSelectionTarget(sessionID: .named("work"), paneID: "gated")
        let registrar = GlobalShortcutRegistrarFake()
        let latestTarget = GlobalShortcutTargetFake(target: target, blocksNextLookup: true)
        var toggleCount = 0
        var selectedTargets: [NotificationSelectionTarget] = []
        let initialToggle = expectation(description: "initial toggle consumer entered stream")
        let restartedToggle = expectation(description: "restarted toggle consumer handled event")
        let restartedSelection = expectation(description: "restarted focus consumer handled event")
        let controller = GlobalShortcutController(
            registrar: registrar,
            latestTarget: latestTarget,
            toggleMenu: {
                toggleCount += 1
                if toggleCount == 1 {
                    initialToggle.fulfill()
                } else if toggleCount == 2 {
                    restartedToggle.fulfill()
                }
            },
            selectTarget: {
                selectedTargets.append($0)
                restartedSelection.fulfill()
            }
        )
        controller.start()
        registrar.send(.keyUp, for: .toggleMenu)
        await fulfillment(of: [initialToggle], timeout: 1)
        registrar.send(.keyUp, for: .focusLatestNotification)
        await latestTarget.waitForLookups(1)

        var firstStopCompleted = false
        let firstStopping = Task(priority: .background) {
            await controller.stop()
            firstStopCompleted = true
        }
        await registrar.waitForTerminations(1)

        controller.start()

        XCTAssertEqual(registrar.eventRequests, ShortcutAction.allCases)
        XCTAssertFalse(firstStopCompleted)
        let concurrentStopEntered = expectation(description: "concurrent stop joined shutdown")
        var concurrentStopCompleted = false
        let concurrentStopping = Task(priority: .background) {
            concurrentStopEntered.fulfill()
            await controller.stop()
            concurrentStopCompleted = true
        }
        await fulfillment(of: [concurrentStopEntered], timeout: 1)
        XCTAssertFalse(concurrentStopCompleted)

        await latestTarget.releaseLookup()
        await registrar.waitForTerminations(2)
        await controller.stop()
        controller.start()
        XCTAssertEqual(
            registrar.eventRequests,
            ShortcutAction.allCases + ShortcutAction.allCases
        )
        guard registrar.eventRequests.count == 4 else {
            await firstStopping.value
            await concurrentStopping.value
            return
        }

        controller.start()
        XCTAssertEqual(registrar.eventRequests.count, 4)
        registrar.send(.keyUp, for: .toggleMenu, streamIndex: 1)
        registrar.send(.keyUp, for: .focusLatestNotification, streamIndex: 1)
        await fulfillment(of: [restartedToggle, restartedSelection], timeout: 1)

        XCTAssertEqual(toggleCount, 2)
        XCTAssertEqual(selectedTargets, [target])

        await controller.stop()
        await controller.stop()
        await registrar.waitForTerminations(4)
        await firstStopping.value
        await concurrentStopping.value
        XCTAssertTrue(firstStopCompleted)
        XCTAssertTrue(concurrentStopCompleted)
        let terminationCount = await registrar.terminationCount()
        XCTAssertEqual(terminationCount, 4)
    }

    func testRestartAcceptsOnlyEventsFromNewGeneration() async {
        let target = NotificationSelectionTarget(sessionID: .default, paneID: "new-generation")
        let registrar = GlobalShortcutRegistrarFake()
        let latestTarget = GlobalShortcutTargetFake(target: target)
        var toggleCount = 0
        var selectedTargets: [NotificationSelectionTarget] = []
        let toggled = expectation(description: "new toggle event")
        let selected = expectation(description: "new focus event")
        let controller = GlobalShortcutController(
            registrar: registrar,
            latestTarget: latestTarget,
            toggleMenu: {
                toggleCount += 1
                toggled.fulfill()
            },
            selectTarget: {
                selectedTargets.append($0)
                selected.fulfill()
            }
        )
        controller.start()
        await controller.stop()
        controller.start()

        registrar.send(.keyUp, for: .toggleMenu, streamIndex: 0)
        registrar.send(.keyUp, for: .focusLatestNotification, streamIndex: 0)
        registrar.send(.keyUp, for: .toggleMenu, streamIndex: 1)
        registrar.send(.keyUp, for: .focusLatestNotification, streamIndex: 1)
        await fulfillment(of: [toggled, selected], timeout: 1)

        XCTAssertEqual(toggleCount, 1)
        XCTAssertEqual(selectedTargets, [target])
        let lookupCount = await latestTarget.lookupCount
        XCTAssertEqual(lookupCount, 1)
        XCTAssertEqual(registrar.eventRequests, ShortcutAction.allCases + ShortcutAction.allCases)
        await controller.stop()
    }
}

@MainActor
private final class GlobalShortcutRegistrarFake: ShortcutRegistering {
    private var continuations: [ShortcutAction: [AsyncStream<GlobalShortcutEvent>.Continuation]] = [:]
    private let terminationSignal = GlobalShortcutCountSignal()
    private let terminationRecorder = GlobalShortcutActionRecorder()
    private(set) var eventRequests: [ShortcutAction] = []

    func shortcut(for action: ShortcutAction) -> ShortcutBinding? { nil }
    func setShortcut(_ shortcut: ShortcutBinding?, for action: ShortcutAction) {}
    func isEnabled(for action: ShortcutAction) -> Bool { false }
    func retryRegistration(for action: ShortcutAction) {}
    func isTakenBySystem(_ shortcut: ShortcutBinding) -> Bool { false }
    func conflictsWithMainMenu(_ shortcut: ShortcutBinding) -> Bool { false }
    func displayString(for shortcut: ShortcutBinding) -> String { "" }
    func setGlobalShortcutDeliveryEnabled(_ isEnabled: Bool) {}

    func events(for action: ShortcutAction) -> AsyncStream<GlobalShortcutEvent> {
        eventRequests.append(action)
        let (stream, continuation) = AsyncStream<GlobalShortcutEvent>.makeStream()
        continuation.onTermination = { [terminationSignal, terminationRecorder] _ in
            Task {
                await terminationRecorder.record(action)
                await terminationSignal.signal()
            }
        }
        continuations[action, default: []].append(continuation)
        return stream
    }

    func send(
        _ event: GlobalShortcutEvent,
        for action: ShortcutAction,
        streamIndex: Int? = nil
    ) {
        let streams = continuations[action] ?? []
        if let streamIndex {
            guard streams.indices.contains(streamIndex) else { return }
            streams[streamIndex].yield(event)
        } else {
            streams.last?.yield(event)
        }
    }

    func waitForTerminations(_ count: Int) async {
        await terminationSignal.wait(for: count)
    }

    func terminationCount() async -> Int {
        await terminationSignal.currentCount
    }

    func terminatedActions() async -> Set<ShortcutAction> {
        await terminationRecorder.actions
    }
}

private actor GlobalShortcutTargetFake: LatestNotificationTargetRecording {
    private var target: NotificationSelectionTarget?
    private var shouldBlockNextLookup: Bool
    private let lookupSignal = GlobalShortcutCountSignal()
    private var lookupGate: CheckedContinuation<Void, Never>?
    private(set) var lookupCount = 0

    init(target: NotificationSelectionTarget?, blocksNextLookup: Bool = false) {
        self.target = target
        shouldBlockNextLookup = blocksNextLookup
    }

    func record(_ target: NotificationSelectionTarget, ordinal: UInt64) {
        self.target = target
    }

    func latest() async -> NotificationSelectionTarget? {
        lookupCount += 1
        await lookupSignal.signal()
        if shouldBlockNextLookup {
            shouldBlockNextLookup = false
            await withCheckedContinuation { lookupGate = $0 }
        }
        return target
    }

    func reset() {
        target = nil
    }

    func sealAndReset() {
        target = nil
    }

    func setTarget(_ target: NotificationSelectionTarget?) {
        self.target = target
    }

    func waitForLookups(_ count: Int) async {
        await lookupSignal.wait(for: count)
    }

    func releaseLookup() {
        lookupGate?.resume()
        lookupGate = nil
    }
}

private actor GlobalShortcutCountSignal {
    private(set) var currentCount = 0
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func signal() {
        currentCount += 1
        let ready = waiters.filter { $0.count <= currentCount }
        waiters.removeAll { $0.count <= currentCount }
        ready.forEach { $0.continuation.resume() }
    }

    func wait(for count: Int) async {
        guard currentCount < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }
}

private actor GlobalShortcutActionRecorder {
    private(set) var actions: Set<ShortcutAction> = []

    func record(_ action: ShortcutAction) {
        actions.insert(action)
    }
}
