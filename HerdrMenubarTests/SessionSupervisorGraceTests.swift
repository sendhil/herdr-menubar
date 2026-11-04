import Foundation
import XCTest
@testable import HerdrMenubar

@MainActor
final class SessionSupervisorGraceTests: XCTestCase {
    func testConnectionBeforeRediscoveryReplaysAndEnablesExactOwningClient() async {
        let harness = await makeMissingSession()
        await harness.client.send(.connected(emptySnapshot))
        await eventually { await harness.client.nextRequests >= 3 }
        await assertConnectedCount(harness.recorder, equals: 1)
        _ = try? await harness.supervisor.focus(sessionID: .named("work"), paneID: "exact")
        let absentFocus = await harness.client.focusedPaneIDs
        XCTAssertTrue(absentFocus.isEmpty)

        await harness.discovery.set([descriptor])
        await harness.supervisor.retryUnavailable()
        await eventually { await harness.recorder.connectedCount == 2 }
        _ = try? await harness.supervisor.focus(sessionID: .named("work"), paneID: "exact")
        let focused = await harness.client.focusedPaneIDs
        XCTAssertEqual(focused, ["exact"])
        let connected = await harness.recorder.connectedDescriptors
        XCTAssertEqual(connected, [descriptor, descriptor])
    }

    func testDisconnectWhileMissingDoesNotReplayAnObsoleteConnection() async {
        let harness = await makeMissingSession()
        await harness.client.send(.connected(emptySnapshot))
        await eventually { await harness.client.nextRequests >= 3 }
        await harness.client.send(.disconnected("fixture disconnected again"))
        await eventually { await harness.client.nextRequests >= 4 }

        await harness.discovery.set([descriptor])
        await harness.supervisor.retryUnavailable()
        await assertConnectedCount(harness.recorder, equals: 1)
        _ = try? await harness.supervisor.focus(sessionID: .named("work"), paneID: "exact")
        let disconnectedFocus = await harness.client.focusedPaneIDs
        XCTAssertTrue(disconnectedFocus.isEmpty)

        await harness.client.send(.connected(emptySnapshot))
        await eventually { await harness.client.nextRequests >= 5 }
        await eventually { await harness.recorder.connectedCount == 2 }
        _ = try? await harness.supervisor.focus(sessionID: .named("work"), paneID: "exact")
        let recoveredFocus = await harness.client.focusedPaneIDs
        XCTAssertEqual(recoveredFocus, ["exact"])
    }

    private func makeMissingSession() async -> SupervisorGraceHarness {
        let client = SupervisorGraceClient(initialSnapshot: emptySnapshot)
        let discovery = SupervisorGraceDiscovery(descriptors: [descriptor])
        let supervisor = SessionSupervisor(
            discovery: discovery,
            clientFactory: SupervisorGraceFactory(client: client),
            sleeper: SupervisorGraceSleeper(),
            discoveryInterval: .seconds(30),
            removalGracePeriod: .seconds(10)
        )
        let recorder = SupervisorGraceRecorder()
        let stream = await supervisor.events()
        let consumer = Task {
            for await event in stream { await recorder.append(event) }
        }
        addTeardownBlock {
            await supervisor.stop()
            await consumer.value
        }
        await supervisor.start()
        await eventually { await recorder.connectedCount == 1 }
        await discovery.set([])
        await supervisor.retryUnavailable()
        await eventually { await recorder.unavailableCount == 1 }
        await eventually { await client.nextRequests >= 2 }
        return SupervisorGraceHarness(
            client: client, discovery: discovery, supervisor: supervisor, recorder: recorder
        )
    }

    private func assertConnectedCount(_ recorder: SupervisorGraceRecorder, equals count: Int) async {
        let actual = await recorder.connectedCount
        XCTAssertEqual(actual, count)
    }

    private func eventually(_ condition: @escaping @Sendable () async -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Expected fixture condition within one second")
    }

    private var descriptor: SessionDescriptor {
        SessionDescriptor(id: .named("work"), socketURL: URL(fileURLWithPath: "/tmp/grace-fixture.sock"))
    }

    private var emptySnapshot: PresentationSnapshot {
        PresentationSnapshot(panes: [], workspaces: [], tabs: [])
    }
}

private struct SupervisorGraceHarness {
    let client: SupervisorGraceClient
    let discovery: SupervisorGraceDiscovery
    let supervisor: SessionSupervisor
    let recorder: SupervisorGraceRecorder
}

private actor SupervisorGraceDiscovery: SessionDiscovering {
    private var descriptors: [SessionDescriptor]
    init(descriptors: [SessionDescriptor]) { self.descriptors = descriptors }
    func discover() -> [SessionDescriptor] { descriptors }
    func set(_ descriptors: [SessionDescriptor]) { self.descriptors = descriptors }
}

private struct SupervisorGraceFactory: SessionClientCreating {
    let client: SupervisorGraceClient
    func makeClient(for descriptor: SessionDescriptor) -> any SessionClientServing { client }
}

private struct SupervisorGraceSleeper: Sleeper {
    func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}

private actor SupervisorGraceRecorder {
    private var events: [SessionSupervisorEvent] = []
    func append(_ event: SessionSupervisorEvent) { events.append(event) }
    var connectedDescriptors: [SessionDescriptor] {
        events.compactMap { event in
            guard case .connected(let descriptor, _) = event else { return nil }
            return descriptor
        }
    }
    var connectedCount: Int { connectedDescriptors.count }
    var unavailableCount: Int {
        events.filter { if case .unavailable = $0 { return true }; return false }.count
    }
}

private enum SupervisorGraceCommand: Error { case reachedClient }

private actor SupervisorGraceClient: SessionClientServing {
    private let initialSnapshot: PresentationSnapshot
    private var pending: [HerdrClientEvent] = []
    private var waiter: CheckedContinuation<HerdrClientEvent?, Never>?
    private var stopped = false
    private(set) var nextRequests = 0
    private(set) var focusedPaneIDs: [String] = []

    init(initialSnapshot: PresentationSnapshot) { self.initialSnapshot = initialSnapshot }

    func events() -> AsyncStream<HerdrClientEvent> {
        AsyncStream(unfolding: { await self.next() })
    }

    func start() { send(.connected(initialSnapshot)) }
    func stop() {
        stopped = true
        pending.removeAll()
        waiter?.resume(returning: nil)
        waiter = nil
    }
    func retryNow() {}
    func refresh() {}

    func focus(paneID: String) throws -> PaneInfo {
        focusedPaneIDs.append(paneID)
        throw SupervisorGraceCommand.reachedClient
    }

    func setClientWindowTitle(_ title: String) throws -> ClientWindowTitleResult {
        throw SupervisorGraceCommand.reachedClient
    }
    func clearClientWindowTitle(timeout: Duration) throws -> ClientWindowTitleResult {
        throw SupervisorGraceCommand.reachedClient
    }

    func send(_ event: HerdrClientEvent) {
        guard !stopped else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: event)
        } else {
            pending.append(event)
        }
    }

    private func next() async -> HerdrClientEvent? {
        nextRequests += 1
        guard !stopped else { return nil }
        if !pending.isEmpty { return pending.removeFirst() }
        return await withCheckedContinuation { waiter = $0 }
    }
}
