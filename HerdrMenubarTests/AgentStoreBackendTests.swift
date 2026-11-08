import Foundation
import XCTest
@testable import HerdrMenubar

@MainActor
final class AgentStoreBackendTests: XCTestCase {
    func testCompletedSelectionMarksCapturedSeenTokenBeforeRefresh() async {
        let backend = FakeAgentBackend(kind: .rex)
        let store = makeBackendStore([backend])
        await store.start()
        backend.send(.discovery([rexSession]))
        backend.send(.connected(rexSession, BackendSnapshot(rows: [finishedRow], attention: [])))
        await eventually { store.finishedSections.count == 1 }

        await store.selectRow(SelectionTarget(target: finishedRow.target, sessionDisplayName: "fix-playback"))

        XCTAssertEqual(backend.calls, ["start", "focus:b1", "activate:b1", "markSeen", "refresh:b1"])
        XCTAssertEqual(backend.markedTokens, [finishedToken])
        XCTAssertNil(store.transientError)
        await store.stop()
    }

    func testPartialActivationShowsMessageAndMarksNothing() async {
        let backend = FakeAgentBackend(kind: .rex)
        backend.activationResult = "Turn on Remote Control in Rex Settings → Rex Server to switch sessions."
        let store = makeBackendStore([backend])
        await store.start()
        backend.send(.connected(rexSession, BackendSnapshot(rows: [finishedRow], attention: [])))
        await eventually { store.finishedSections.count == 1 }

        await store.selectRow(SelectionTarget(target: finishedRow.target, sessionDisplayName: "fix-playback"))

        XCTAssertEqual(backend.calls, ["start", "focus:b1", "activate:b1", "refresh:b1"])
        XCTAssertTrue(backend.markedTokens.isEmpty)
        XCTAssertEqual(store.transientError, "Turn on Remote Control in Rex Settings → Rex Server to switch sessions.")
        await store.stop()
    }

    func testFocusFailureShowsBackendWordingWithoutActivationOrRefresh() async {
        let backend = FakeAgentBackend(kind: .rex)
        backend.focusError = .failed("That pane no longer exists in fix-playback")
        let store = makeBackendStore([backend])

        await store.selectRow(SelectionTarget(target: finishedRow.target, sessionDisplayName: "fix-playback"))

        XCTAssertEqual(backend.calls, ["focus:b1"])
        XCTAssertFalse(backend.calls.contains("retry"))
        XCTAssertEqual(store.transientError, "That pane no longer exists in fix-playback")
    }

    func testFocusUnavailableShowsWordingAndRetriesThatBackendOnly() async {
        let herdr = FakeAgentBackend(kind: .herdr)
        let backend = FakeAgentBackend(kind: .rex)
        backend.focusError = .unavailable("fix-playback is not reachable")
        let store = makeBackendStore([herdr, backend])

        await store.selectRow(SelectionTarget(target: finishedRow.target, sessionDisplayName: "fix-playback"))

        XCTAssertEqual(backend.calls, ["focus:b1", "retry"])
        XCTAssertTrue(herdr.calls.isEmpty)
        XCTAssertEqual(store.transientError, "fix-playback is not reachable")
    }

    func testSupersededSelectionRefreshesWithoutActivatingOrMarkingSeen() async {
        let backend = FakeAgentBackend(kind: .rex)
        backend.heldFocusPaneIDs = ["b1"]
        let store = makeBackendStore([backend])
        await store.start()
        backend.send(.connected(rexSession, BackendSnapshot(rows: [finishedRow, attentionRow], attention: [])))
        await eventually { store.finishedSections.count == 1 && store.attentionCount == 1 }

        let first = Task {
            await store.selectRow(SelectionTarget(target: finishedRow.target, sessionDisplayName: "fix-playback"))
        }
        await eventually { backend.calls.contains("focus:b1") }
        let second = Task {
            await store.selectRow(SelectionTarget(target: attentionRow.target, sessionDisplayName: "fix-playback"))
        }
        for _ in 0..<20 { await Task.yield() }
        backend.releaseHeldFocus()
        await first.value
        await second.value

        XCTAssertEqual(backend.calls, [
            "start", "focus:b1", "refresh:b1", "focus:b2", "activate:b2", "refresh:b2"
        ])
        XCTAssertTrue(backend.markedTokens.isEmpty)
        XCTAssertNil(store.transientError)
        await store.stop()
    }

    func testUnroutableTargetDoesNotSupersedeInFlightHerdrSelection() async {
        let herdr = FakeAgentBackend(kind: .herdr)
        herdr.heldFocusPaneIDs = ["p"]
        let store = makeBackendStore([herdr], enabledBackends: ["herdr"])
        await store.start()
        let herdrSession = AgentSessionDescriptor(key: .named("work"), displayName: "work")
        herdr.send(.connected(herdrSession, BackendSnapshot(rows: [row(herdrSession.key, "p", .working)], attention: [])))
        await eventually { store.workingSections.count == 1 }

        let selection = Task { await store.selectRow(.herdr(.named("work"), paneID: "p")) }
        await eventually { herdr.calls.contains("focus:p") }
        store.select(SelectionTarget(target: finishedRow.target, sessionDisplayName: "fix-playback"))
        herdr.releaseHeldFocus()
        await selection.value

        XCTAssertEqual(herdr.calls, ["start", "focus:p", "activate:p", "refresh:p"])
        XCTAssertEqual(store.transientError, "Rex is turned off")
        await store.stop()
    }

    func testTargetForHiddenBackendDoesNotSupersedeInFlightHerdrSelection() async {
        let herdr = FakeAgentBackend(kind: .herdr)
        let rex = FakeAgentBackend(kind: .rex)
        herdr.heldFocusPaneIDs = ["p"]
        let store = makeBackendStore([herdr, rex])
        await store.start()
        rex.send(.backendHidden)
        let herdrSession = AgentSessionDescriptor(key: .named("work"), displayName: "work")
        herdr.send(.connected(herdrSession, BackendSnapshot(rows: [row(herdrSession.key, "p", .working)], attention: [])))
        await eventually { store.workingSections.count == 1 }
        for _ in 0..<20 { await Task.yield() }

        let selection = Task { await store.selectRow(.herdr(.named("work"), paneID: "p")) }
        await eventually { herdr.calls.contains("focus:p") }
        store.select(SelectionTarget(target: finishedRow.target, sessionDisplayName: "fix-playback"))
        XCTAssertEqual(store.transientError, "Rex is not available")
        herdr.releaseHeldFocus()
        await selection.value

        XCTAssertEqual(herdr.calls, ["start", "focus:p", "activate:p", "refresh:p"])
        XCTAssertEqual(store.transientError, "Rex is not available")
        await store.stop()
    }

    func testFinishedRowsFormTheirOwnSectionAndAreNotCounted() async {
        let backend = FakeAgentBackend(kind: .rex)
        let store = makeBackendStore([backend])
        await store.start()
        backend.send(.connected(rexSession, BackendSnapshot(rows: [finishedRow, attentionRow, workingRow], attention: [])))
        await eventually { store.workingSections.count == 1 }

        XCTAssertEqual(store.attentionCount, 1)
        XCTAssertEqual(store.attentionSections.flatMap(\.items), [attentionRow])
        XCTAssertEqual(store.finishedSections.flatMap(\.items), [finishedRow])
        XCTAssertEqual(store.workingSections.flatMap(\.items), [workingRow])
        await store.stop()
    }

    func testSessionsSortByBackendKindThenBackendComparator() async {
        let herdr = FakeAgentBackend(kind: .herdr)
        let rex = FakeAgentBackend(kind: .rex)
        let store = makeBackendStore([rex, herdr])
        await store.start()
        let herdrZulu = AgentSessionDescriptor(key: AgentSessionKey(backend: .herdr, rawID: "named:zulu"), displayName: "zulu")
        let rexBeta = AgentSessionDescriptor(key: AgentSessionKey(backend: .rex, rawID: "s2"), displayName: "beta")
        rex.send(.connected(rexBeta, BackendSnapshot(rows: [row(rexBeta.key, "x", .working)], attention: [])))
        rex.send(.connected(rexSession, BackendSnapshot(rows: [row(rexKey, "y", .working)], attention: [])))
        herdr.send(.connected(herdrZulu, BackendSnapshot(rows: [row(herdrZulu.key, "z", .working)], attention: [])))
        await eventually { store.workingSections.count == 3 }

        XCTAssertEqual(store.workingSections.map(\.session.displayName), ["zulu", "beta", "fix-playback"])
        await store.stop()
    }

    func testBackendUnavailableClearsRowsKeepsHistoryAndHidesSessionsFromReconnecting() async {
        let backend = FakeAgentBackend(kind: .rex)
        let coordinator = BackendStoreCoordinator()
        let store = makeBackendStore([backend], coordinator: coordinator)
        await store.start()
        backend.send(.discovery([rexSession]))
        backend.send(.connected(rexSession, BackendSnapshot(rows: [attentionRow], attention: [])))
        await eventually { store.attentionCount == 1 }

        backend.send(.backendUnavailable("watcher exited"))
        await eventually { store.attentionCount == 0 }

        XCTAssertEqual(store.unavailableBackends, [.rex: "watcher exited"])
        XCTAssertTrue(store.unavailableSessions.isEmpty)
        // `waitUntil` is the shared helper in HerdrClientTestSupport.swift.
        await waitUntil { await coordinator.unavailableSessions == [rexKey] }
        let unavailable = await coordinator.unavailableSessions
        let removed = await coordinator.removedSessions
        XCTAssertEqual(unavailable, [rexKey])
        XCTAssertTrue(removed.isEmpty)

        backend.send(.discovery([rexSession]))
        await eventually { store.unavailableBackends.isEmpty }
        await store.stop()
    }

    func testBackendHiddenRemovesSessionsAndHistory() async {
        let backend = FakeAgentBackend(kind: .rex)
        let coordinator = BackendStoreCoordinator()
        let store = makeBackendStore([backend], coordinator: coordinator)
        await store.start()
        backend.send(.discovery([rexSession]))
        backend.send(.connected(rexSession, BackendSnapshot(rows: [attentionRow], attention: [])))
        await eventually { store.attentionCount == 1 }

        backend.send(.backendHidden)
        await eventually { store.attentionSections.isEmpty }
        await waitUntil { await coordinator.removedSessions == [rexKey] }

        let removed = await coordinator.removedSessions
        XCTAssertEqual(removed, [rexKey])
        XCTAssertFalse(store.activeBackends.contains(.rex))
        // "Has been active in this run" is sticky across `.backendHidden`.
        XCTAssertEqual(store.everActiveBackends, [.rex])
        XCTAssertEqual(store.wording, .herdr)
        XCTAssertEqual(store.connectionState, .searching)
        await store.stop()
        XCTAssertTrue(store.everActiveBackends.isEmpty)
    }

    func testBackendHiddenDiscardsItsPendingTargetAsNotAvailable() async {
        let backend = FakeAgentBackend(kind: .rex)
        let store = makeBackendStore([backend])
        await store.start()

        store.select(SelectionTarget(target: finishedRow.target, sessionDisplayName: "fix-playback"))
        XCTAssertNil(store.transientError)
        backend.send(.backendHidden)
        await eventually { store.transientError == "Rex is not available" }

        backend.send(.discovery([rexSession]))
        backend.send(.connected(rexSession, BackendSnapshot(rows: [finishedRow], attention: [])))
        await eventually { store.finishedSections.count == 1 }
        XCTAssertFalse(backend.calls.contains("focus:b1"))
        await store.stop()
    }

    func testDescriptorChangedRenamesHeadingWithoutTouchingCoordinator() async {
        let backend = FakeAgentBackend(kind: .rex)
        let coordinator = BackendStoreCoordinator()
        let store = makeBackendStore([backend], coordinator: coordinator)
        await store.start()
        backend.send(.connected(rexSession, BackendSnapshot(rows: [attentionRow], attention: [])))
        await eventually { store.attentionCount == 1 }

        backend.send(.descriptorChanged(AgentSessionDescriptor(key: rexKey, displayName: "renamed")))
        await eventually { store.attentionSections.first?.session.displayName == "renamed" }

        let reconciled = await coordinator.reconciledSessions
        XCTAssertEqual(reconciled, [rexKey])
        await store.stop()
    }

    func testTargetForDisabledBackendIsDiscardedAsTurnedOff() async {
        let herdr = FakeAgentBackend(kind: .herdr)
        let store = makeBackendStore([herdr], enabledBackends: ["herdr"])
        await store.start()

        store.select(SelectionTarget(target: finishedRow.target, sessionDisplayName: "fix-playback"))

        XCTAssertEqual(store.transientError, "Rex is turned off")
        XCTAssertEqual(herdr.calls, ["start"])
        await store.stop()
    }

    func testTargetForEnabledBackendWithoutInstanceIsNotAvailable() async {
        let herdr = FakeAgentBackend(kind: .herdr)
        let store = makeBackendStore([herdr], enabledBackends: ["herdr", "rex"])
        await store.start()

        store.select(SelectionTarget(target: finishedRow.target, sessionDisplayName: "fix-playback"))

        XCTAssertEqual(store.transientError, "Rex is not available")
        await store.stop()
    }

    func testWordingSwitchesToAgentsOnlyOnceRexIsActive() async {
        let herdr = FakeAgentBackend(kind: .herdr)
        let rex = FakeAgentBackend(kind: .rex)
        let store = makeBackendStore([herdr, rex])
        await store.start()
        herdr.send(.discovery([]))
        await eventually { store.connectionState == .noSessions }
        XCTAssertEqual(store.wording, .herdr)

        rex.send(.discovery([]))
        await eventually { store.wording == .agents }
        XCTAssertEqual(store.activeBackends, [.herdr, .rex])
        await store.stop()
    }

    func testHerdrOnlyConnectionStatesAreTodaysWhenRexNeverBecomesActive() async {
        let herdr = FakeAgentBackend(kind: .herdr)
        let rex = FakeAgentBackend(kind: .rex)
        let store = makeBackendStore([herdr, rex])
        await store.start()
        XCTAssertEqual(store.connectionState, .searching)

        herdr.send(.discovery([]))
        await eventually { store.connectionState == .noSessions }
        herdr.send(.discovery([herdrWork]))
        await eventually { store.connectionState == .connecting }
        herdr.send(.connected(herdrWork, .empty))
        await eventually { store.connectionState == .connected }
        herdr.send(.sessionUnavailable(herdrWork.key, "socket unavailable"))
        await eventually { store.connectionState == .connecting }
        XCTAssertEqual(store.wording, .herdr)
        await store.stop()
    }

    func testConnectionStateAggregatesActiveBackendsInSpecTableOrder() async {
        let herdr = FakeAgentBackend(kind: .herdr)
        let rex = FakeAgentBackend(kind: .rex)
        let store = makeBackendStore([herdr, rex])
        await store.start()

        // Rex active with zero sessions precedes Herdr's own (searching) state.
        rex.send(.discovery([]))
        await eventually { store.activeBackends.contains(.rex) }
        XCTAssertEqual(store.connectionState, .noSessions)

        herdr.send(.discovery([]))
        await eventually { store.activeBackends.contains(.herdr) }
        XCTAssertEqual(store.connectionState, .noSessions)

        rex.send(.discovery([rexSession]))
        await eventually { store.connectionState == .connecting }

        rex.send(.connected(rexSession, .empty))
        await eventually { store.connectionState == .connected }

        // Rex active and currently unavailable is connecting; its sessions are excluded.
        rex.send(.backendUnavailable("heartbeat timeout"))
        await eventually { store.connectionState == .connecting }
        XCTAssertEqual(store.unavailableBackends, [.rex: "heartbeat timeout"])

        herdr.send(.connected(herdrWork, .empty))
        await eventually { store.connectionState == .connected }

        // A Herdr connecting (unavailable) session while Rex is unavailable is connecting,
        // and only the Rex sessions are hidden from RECONNECTING.
        herdr.send(.sessionUnavailable(herdrWork.key, "socket unavailable"))
        await eventually { store.connectionState == .connecting }
        XCTAssertEqual(store.unavailableSessions.map(\.id), [herdrWork.key])
        await store.stop()
    }

    func testRexOnlyActiveWithZeroSessionsIsNoSessions() async {
        let rex = FakeAgentBackend(kind: .rex)
        let store = makeBackendStore([rex], enabledBackends: ["rex"])
        await store.start()
        XCTAssertEqual(store.connectionState, .searching)

        rex.send(.discovery([]))
        await eventually { store.connectionState == .noSessions }
        await store.stop()
    }
}

// MARK: - Fixtures

private let rexKey = AgentSessionKey(backend: .rex, rawID: "s1")
private let herdrWork = AgentSessionDescriptor(key: .named("work"), displayName: "work")
private let rexSession = AgentSessionDescriptor(key: rexKey, displayName: "fix-playback")
private let finishedToken = SeenToken(marks: ["s1/b1/:3"])
private let finishedRow = AgentRow(
    target: AgentTarget(session: rexKey, paneID: "b1"), displayLabel: "Review", agentLabel: "claude-code",
    state: .finished, subtitle: "done · claude-code", seenToken: finishedToken
)
private let attentionRow = AgentRow(
    target: AgentTarget(session: rexKey, paneID: "b2"), displayLabel: "Playback", agentLabel: "pi",
    state: .attention(.blocked), subtitle: "blocked · Allow rm -rf build?", seenToken: nil
)
private let workingRow = AgentRow(
    target: AgentTarget(session: rexKey, paneID: "b3"), displayLabel: "Design", agentLabel: "claude-code",
    state: .working, subtitle: "working · claude-code", seenToken: nil
)

private func row(_ key: AgentSessionKey, _ paneID: String, _ state: RowState) -> AgentRow {
    AgentRow(
        target: AgentTarget(session: key, paneID: paneID), displayLabel: paneID, agentLabel: nil,
        state: state, subtitle: "", seenToken: nil
    )
}

@MainActor
func makeBackendStore(
    _ backends: [any AgentBackend],
    coordinator: BackendStoreCoordinator = BackendStoreCoordinator(),
    enabledBackends: [String] = ["herdr", "rex"],
    clock: any AgentStoreClock = LiveRexBackendClock()
) -> AgentStore {
    let defaults = UserDefaults(suiteName: "dev.herdr.menubar.backend-store-tests.\(UUID().uuidString)")!
    defaults.set(enabledBackends, forKey: Preferences.enabledBackendsKey)
    return AgentStore(
        backends: backends,
        attentionCoordinator: coordinator,
        notificationService: BackendStoreNotifications(),
        preferences: Preferences(defaults: defaults),
        clock: clock
    )
}

@MainActor
private func eventually(
    timeout: Duration = .seconds(1),
    _ condition: @escaping @MainActor () -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition(), clock.now < deadline { await Task.yield() }
    XCTAssertTrue(condition())
}

@MainActor
final class FakeAgentBackend: AgentBackend {
    nonisolated let kind: BackendKind
    private(set) var calls: [String] = []
    private(set) var markedTokens: [SeenToken] = []
    var focusError: FocusError?
    var activationResult: String?
    var heldFocusPaneIDs: Set<String> = []
    private var continuation: AsyncStream<BackendEvent>.Continuation?
    private var focusWaiters: [CheckedContinuation<Void, Never>] = []

    init(kind: BackendKind) { self.kind = kind }

    func events() async -> AsyncStream<BackendEvent> {
        let (stream, continuation) = AsyncStream<BackendEvent>.makeStream()
        self.continuation = continuation
        return stream
    }

    func start() async { calls.append("start") }

    func stop() async {
        calls.append("stop")
        continuation?.finish()
        continuation = nil
    }

    func retryUnavailable() async { calls.append("retry") }

    func focusServer(_ target: AgentTarget) async throws {
        calls.append("focus:\(target.paneID)")
        if heldFocusPaneIDs.contains(target.paneID) {
            await withCheckedContinuation { focusWaiters.append($0) }
        }
        if let focusError { throw focusError }
    }

    func activate(_ target: AgentTarget) async -> String? {
        calls.append("activate:\(target.paneID)")
        return activationResult
    }

    func refreshAfterSelection(_ target: AgentTarget) async { calls.append("refresh:\(target.paneID)") }

    func markSeen(_ token: SeenToken) async {
        calls.append("markSeen")
        markedTokens.append(token)
    }

    func clearFinished() async { calls.append("clearFinished") }

    nonisolated func compareSessions(_ lhs: AgentSessionDescriptor, _ rhs: AgentSessionDescriptor) -> Bool {
        lhs.displayName < rhs.displayName
    }

    func send(_ event: BackendEvent) { continuation?.yield(event) }

    func releaseHeldFocus() {
        heldFocusPaneIDs.removeAll()
        let waiters = focusWaiters
        focusWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

actor BackendStoreCoordinator: AttentionNotificationCoordinating {
    private(set) var reconciledSessions: [AgentSessionKey] = []
    private(set) var unavailableSessions: [AgentSessionKey] = []
    private(set) var removedSessions: [AgentSessionKey] = []

    func reconcile(session: AgentSessionDescriptor, records: [AttentionRecord], policy: NotificationDeliveryPolicy) {
        reconciledSessions.append(session.key)
    }
    func unavailable(session: AgentSessionKey) { unavailableSessions.append(session) }
    func remove(session: AgentSessionKey) { removedSessions.append(session) }
    func reset() {}
}

actor BackendStoreNotifications: NativeNotificationServing {
    func responses() async -> NotificationResponseSubscription { .finished() }
    func requestAuthorization() async throws -> Bool { true }
    func settings() async -> NotificationSystemSettings { .authorized }
    func deliver(_ event: AttentionNotificationEvent, sound: Bool) async throws -> NotificationDeliveryResult {
        .accepted
    }
}
