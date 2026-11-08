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
        XCTAssertNil(store.transientError)
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
}

// MARK: - Fixtures

private let rexKey = AgentSessionKey(backend: .rex, rawID: "s1")
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
private func makeBackendStore(
    _ backends: [any AgentBackend],
    coordinator: BackendStoreCoordinator = BackendStoreCoordinator(),
    enabledBackends: [String] = ["herdr", "rex"]
) -> AgentStore {
    let defaults = UserDefaults(suiteName: "dev.herdr.menubar.backend-store-tests.\(UUID().uuidString)")!
    defaults.set(enabledBackends, forKey: Preferences.enabledBackendsKey)
    return AgentStore(
        backends: backends,
        attentionCoordinator: coordinator,
        notificationService: BackendStoreNotifications(),
        preferences: Preferences(defaults: defaults)
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
private final class FakeAgentBackend: AgentBackend {
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

private actor BackendStoreCoordinator: AttentionNotificationCoordinating {
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

private actor BackendStoreNotifications: NativeNotificationServing {
    func responses() async -> NotificationResponseSubscription { .finished() }
    func requestAuthorization() async throws -> Bool { true }
    func settings() async -> NotificationSystemSettings { .authorized }
    func deliver(_ event: AttentionNotificationEvent, sound: Bool) async throws -> NotificationDeliveryResult {
        .accepted
    }
}
