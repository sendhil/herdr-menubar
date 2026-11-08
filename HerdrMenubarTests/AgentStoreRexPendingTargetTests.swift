import Foundation
import XCTest
@testable import HerdrMenubar

/// Spec "AgentStore changes → Pending notification target → Rex targets": a store-owned 30 s
/// deadline on an injected clock, conditions (a)–(d), and cancellation on supersede, resolve,
/// discard, and stop. Herdr targets keep today's rules with no deadline.
@MainActor
final class AgentStoreRexPendingTargetTests: XCTestCase {
    func testTargetForConnectedRexSessionResolvesImmediatelyWithoutDeadline() async {
        let clock = ManualRexClock()
        let rex = FakeAgentBackend(kind: .rex)
        let store = makeBackendStore([rex], clock: clock)
        await store.start()
        rex.send(.discovery([pendingRexSession]))
        rex.send(.connected(pendingRexSession, BackendSnapshot(rows: [pendingRexRow], attention: [])))
        await settle { store.attentionCount == 1 }

        store.select(pendingRexTarget)
        await settle { rex.calls.contains("refresh:b1") }

        XCTAssertEqual(rex.calls, ["start", "focus:b1", "activate:b1", "refresh:b1"])
        XCTAssertEqual(clock.sleeperCount, 0)
        await store.stop()
    }

    func testPendingRexTargetResolvesOnConnectedAndCancelsDeadline() async {
        let clock = ManualRexClock()
        let rex = FakeAgentBackend(kind: .rex)
        let store = makeBackendStore([rex], clock: clock)
        await store.start()

        store.select(pendingRexTarget)
        await settle { clock.sleeperCount == 1 }
        XCTAssertNil(store.transientError)
        XCTAssertEqual(clock.pendingOffsets, [.seconds(30)])

        rex.send(.discovery([pendingRexSession]))
        rex.send(.connected(pendingRexSession, BackendSnapshot(rows: [pendingRexRow], attention: [])))
        await settle { rex.calls.contains("refresh:b1") }
        await settle { clock.sleeperCount == 0 }

        clock.advance(.seconds(31))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(store.transientError)
        XCTAssertEqual(rex.calls, ["start", "focus:b1", "activate:b1", "refresh:b1"])
        await store.stop()
    }

    func testPendingRexTargetExpiresAfterThirtySeconds() async {
        let clock = ManualRexClock()
        let rex = FakeAgentBackend(kind: .rex)
        let store = makeBackendStore([rex], clock: clock)
        await store.start()

        store.select(pendingRexTarget)
        await settle { clock.sleeperCount == 1 }
        clock.advance(.seconds(29))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(store.transientError)

        clock.advance(.seconds(1))
        await settle { store.transientError == "Rex did not respond in time" }

        // An expired target is gone: a later connection does not focus it.
        rex.send(.discovery([pendingRexSession]))
        rex.send(.connected(pendingRexSession, BackendSnapshot(rows: [pendingRexRow], attention: [])))
        await settle { store.attentionCount == 1 }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(rex.calls.contains("focus:b1"))
        await store.stop()
    }

    func testRexTargetHeldThroughBackendOutageThenResolvedOnReconnect() async {
        let clock = ManualRexClock()
        let rex = FakeAgentBackend(kind: .rex)
        let store = makeBackendStore([rex], clock: clock)
        await store.start()
        rex.send(.discovery([pendingRexSession]))
        rex.send(.connected(pendingRexSession, BackendSnapshot(rows: [pendingRexRow], attention: [])))
        await settle { store.attentionCount == 1 }
        rex.send(.backendUnavailable("watcher exited"))
        await settle { store.attentionCount == 0 }

        store.select(pendingRexTarget)
        await settle { clock.sleeperCount == 1 }
        XCTAssertNil(store.transientError)
        XCTAssertFalse(rex.calls.contains("focus:b1"))

        rex.send(.discovery([pendingRexSession]))
        rex.send(.connected(pendingRexSession, BackendSnapshot(rows: [pendingRexRow], attention: [])))
        await settle { rex.calls.contains("refresh:b1") }
        await settle { clock.sleeperCount == 0 }
        XCTAssertNil(store.transientError)
        await store.stop()
    }

    func testConditionAAtArrivalDiscardsAsNoLongerRunning() async {
        let clock = ManualRexClock()
        let rex = FakeAgentBackend(kind: .rex)
        let store = makeBackendStore([rex], clock: clock)
        await store.start()
        rex.send(.discovery([]))
        await settle { store.activeBackends.contains(.rex) }

        store.select(pendingRexTarget)

        XCTAssertEqual(store.transientError, "fix-playback is no longer running in Rex")
        XCTAssertEqual(clock.sleeperCount, 0)
        await store.stop()
    }

    func testConditionAOnDiscoveryDiscardsPendingAndCancelsDeadline() async {
        let clock = ManualRexClock()
        let rex = FakeAgentBackend(kind: .rex)
        let store = makeBackendStore([rex], clock: clock)
        await store.start()

        store.select(pendingRexTarget)
        await settle { clock.sleeperCount == 1 }
        rex.send(.discovery([otherRexSession]))
        await settle { store.transientError == "fix-playback is no longer running in Rex" }
        await settle { clock.sleeperCount == 0 }

        rex.send(.connected(pendingRexSession, BackendSnapshot(rows: [pendingRexRow], attention: [])))
        await settle { store.attentionCount == 1 }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(rex.calls.contains("focus:b1"))
        await store.stop()
    }

    func testConditionBRemovedDiscardsPendingWithStoreDescriptorName() async {
        let clock = ManualRexClock()
        let rex = FakeAgentBackend(kind: .rex)
        let store = makeBackendStore([rex], clock: clock)
        await store.start()
        rex.send(.discovery([pendingRexSession]))
        rex.send(.connected(pendingRexSession, .empty))
        rex.send(.descriptorChanged(AgentSessionDescriptor(key: pendingRexKey, displayName: "renamed")))
        rex.send(.backendUnavailable("heartbeat timeout"))
        await settle { store.unavailableBackends[.rex] != nil }

        store.select(pendingRexTarget)
        await settle { clock.sleeperCount == 1 }
        rex.send(.removed(pendingRexKey))

        await settle { store.transientError == "renamed is no longer running in Rex" }
        await settle { clock.sleeperCount == 0 }
        await store.stop()
    }

    func testConditionCHiddenAtArrivalIsNotAvailable() async {
        let clock = ManualRexClock()
        let rex = FakeAgentBackend(kind: .rex)
        let store = makeBackendStore([rex], clock: clock)
        await store.start()
        rex.send(.backendHidden)
        await settle { store.connectionState == .searching && rex.calls == ["start"] }
        for _ in 0..<20 { await Task.yield() }

        store.select(pendingRexTarget)

        XCTAssertEqual(store.transientError, "Rex is not available")
        XCTAssertEqual(clock.sleeperCount, 0)
        await store.stop()
    }

    func testConditionCHiddenWhilePendingDiscardsAndCancelsDeadline() async {
        let clock = ManualRexClock()
        let rex = FakeAgentBackend(kind: .rex)
        let store = makeBackendStore([rex], clock: clock)
        await store.start()

        store.select(pendingRexTarget)
        await settle { clock.sleeperCount == 1 }
        rex.send(.backendHidden)

        await settle { store.transientError == "Rex is not available" }
        await settle { clock.sleeperCount == 0 }
        await store.stop()
    }

    func testHiddenRexThatRecoversAcceptsTargetsAgain() async {
        let clock = ManualRexClock()
        let rex = FakeAgentBackend(kind: .rex)
        let store = makeBackendStore([rex], clock: clock)
        await store.start()
        rex.send(.backendHidden)
        rex.send(.discovery([pendingRexSession]))
        await settle { store.activeBackends.contains(.rex) }

        store.select(pendingRexTarget)

        XCTAssertNil(store.transientError)
        await settle { clock.sleeperCount == 1 }
        await store.stop()
    }

    func testMenuSelectionSupersedesPendingRexTargetAndCancelsDeadline() async {
        let clock = ManualRexClock()
        let herdr = FakeAgentBackend(kind: .herdr)
        let rex = FakeAgentBackend(kind: .rex)
        let store = makeBackendStore([herdr, rex], clock: clock)
        await store.start()
        let work = AgentSessionDescriptor(key: .named("work"), displayName: "work")
        herdr.send(.discovery([work]))
        herdr.send(.connected(work, .empty))
        await settle { store.connectionState == .connected }

        store.select(pendingRexTarget)
        await settle { clock.sleeperCount == 1 }
        await store.selectRow(.herdr(.named("work"), paneID: "p"))
        await settle { clock.sleeperCount == 0 }

        clock.advance(.seconds(31))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(store.transientError)
        XCTAssertEqual(herdr.calls, ["start", "focus:p", "activate:p", "refresh:p"])
        await store.stop()
    }

    func testNewerTargetSupersedesPendingRexTargetAndRestartsDeadline() async {
        let clock = ManualRexClock()
        let rex = FakeAgentBackend(kind: .rex)
        let store = makeBackendStore([rex], clock: clock)
        await store.start()

        store.select(pendingRexTarget)
        await settle { clock.sleeperCount == 1 }
        clock.advance(.seconds(20))
        let newer = SelectionTarget(target: AgentTarget(session: otherRexSession.key, paneID: "b9"), sessionDisplayName: "other")
        store.select(newer)
        await settle { clock.sleeperCount == 1 && clock.pendingOffsets == [.seconds(50)] }

        clock.advance(.seconds(15))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(store.transientError)

        // Only the newer target is pending; the superseded one never focuses.
        rex.send(.discovery([pendingRexSession, otherRexSession]))
        rex.send(.connected(pendingRexSession, BackendSnapshot(rows: [pendingRexRow], attention: [])))
        rex.send(.connected(otherRexSession, .empty))
        await settle { rex.calls.contains("refresh:b9") }
        XCTAssertFalse(rex.calls.contains("focus:b1"))
        await store.stop()
    }

    func testStopCancelsPendingDeadline() async {
        let clock = ManualRexClock()
        let rex = FakeAgentBackend(kind: .rex)
        let store = makeBackendStore([rex], clock: clock)
        await store.start()

        store.select(pendingRexTarget)
        await settle { clock.sleeperCount == 1 }
        await store.stop()

        await settle { clock.sleeperCount == 0 }
        XCTAssertNil(store.transientError)
    }

    func testExpiryFromAPreviousRunNeverReachesARestartedStore() async {
        let clock = ManualRexClock()
        let rex = FakeAgentBackend(kind: .rex)
        let store = makeBackendStore([rex], clock: clock)
        await store.start()
        store.select(pendingRexTarget)
        await settle { clock.sleeperCount == 1 }
        await store.stop()
        await store.start()

        clock.advance(.seconds(31))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(store.transientError)
        await store.stop()
    }

    func testHerdrPendingTargetHasNoDeadline() async {
        let clock = ManualRexClock()
        let herdr = FakeAgentBackend(kind: .herdr)
        let store = makeBackendStore([herdr], enabledBackends: ["herdr"], clock: clock)
        await store.start()

        store.select(.herdr(.named("work"), paneID: "p"))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(clock.sleeperCount, 0)
        clock.advance(.seconds(120))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(store.transientError)

        let work = AgentSessionDescriptor(key: .named("work"), displayName: "work")
        herdr.send(.discovery([work]))
        herdr.send(.connected(work, .empty))
        await settle { herdr.calls.contains("refresh:p") }
        XCTAssertNil(store.transientError)
        await store.stop()
    }

    func testHerdrRemovedAndAbsentMessagesAreUnchanged() async {
        let herdr = FakeAgentBackend(kind: .herdr)
        let store = makeBackendStore([herdr], enabledBackends: ["herdr"])
        await store.start()
        herdr.send(.discovery([]))
        await settle { store.connectionState == .noSessions }

        store.select(.herdr(.named("work"), paneID: "p"))
        XCTAssertEqual(store.transientError, "work is unavailable")

        let work = AgentSessionDescriptor(key: .named("work"), displayName: "work")
        herdr.send(.discovery([work]))
        await settle { store.connectionState == .connecting }
        store.select(.herdr(.named("work"), paneID: "p"))
        XCTAssertNil(store.transientError)
        herdr.send(.removed(work.key))
        await settle { store.transientError == "work is unavailable" }
        await store.stop()
    }
}

// MARK: - Fixtures

private let pendingRexKey = AgentSessionKey(backend: .rex, rawID: "s1")
private let pendingRexSession = AgentSessionDescriptor(key: pendingRexKey, displayName: "fix-playback")
private let otherRexSession = AgentSessionDescriptor(key: AgentSessionKey(backend: .rex, rawID: "s2"), displayName: "other")
private let pendingRexTarget = SelectionTarget(
    target: AgentTarget(session: pendingRexKey, paneID: "b1"),
    sessionDisplayName: "fix-playback"
)
private let pendingRexRow = AgentRow(
    target: AgentTarget(session: pendingRexKey, paneID: "b1"), displayLabel: "Playback", agentLabel: "pi",
    state: .attention(.blocked), subtitle: "blocked · pi", seenToken: nil
)

@MainActor
private func settle(
    timeout: Duration = .seconds(2),
    _ condition: @escaping @MainActor () -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition(), clock.now < deadline { await Task.yield() }
    XCTAssertTrue(condition())
}
