import Foundation
import XCTest
@testable import HerdrMenubar

final class SessionSupervisorTests: XCTestCase {
    func testSuccessfulEmptyReconciliationPublishesEmptyDiscoverySnapshot() async {
        let discovery = FakeSessionDiscovery(results: [.success([])])
        let supervisor = makeSupervisor(discovery: discovery)
        let stream = await supervisor.events()
        var iterator = stream.makeAsyncIterator()

        await supervisor.start()

        let event = await iterator.next()
        XCTAssertEqual(event, .discoverySnapshot([]))
        await supervisor.stop()
    }

    func testCreatesOneClientPerDescriptorAndDoesNotDuplicateOnRepeatedScan() async {
        let descriptors = [defaultDescriptor, namedDescriptor]
        let discovery = FakeSessionDiscovery(results: [.success(descriptors), .success(descriptors)])
        let factory = FakeSessionClientFactory()
        let sleeper = SupervisorTestSleeper()
        let supervisor = makeSupervisor(discovery: discovery, factory: factory, sleeper: sleeper)

        await supervisor.start()
        await waitUntil { await factory.makeCount == 2 }
        await sleeper.releaseFirst()
        await waitUntil { await discovery.callCount == 2 }

        let makeCount = await factory.makeCount
        let requestedDescriptors = await factory.requestedDescriptors
        XCTAssertEqual(makeCount, 2)
        XCTAssertEqual(requestedDescriptors, descriptors)
        await supervisor.stop()
    }

    func testNewNamedSessionAppearingWhileRunningCreatesAndStartsClient() async {
        let discovery = FakeSessionDiscovery(results: [
            .success([defaultDescriptor]),
            .success([defaultDescriptor, namedDescriptor])
        ])
        let factory = FakeSessionClientFactory()
        let sleeper = SupervisorTestSleeper()
        let supervisor = makeSupervisor(discovery: discovery, factory: factory, sleeper: sleeper)

        await supervisor.start()
        await waitUntil { await factory.makeCount == 1 }
        await sleeper.releaseFirst()
        await waitUntil { await factory.makeCount == 2 }

        let named = await factory.client(for: namedDescriptor.id)
        let namedStartCount = await named?.startCount
        XCTAssertEqual(namedStartCount, 1)
        await supervisor.stop()
    }

    func testForwardsConnectedSnapshotWithOwningDescriptor() async {
        let snapshot = clientSnapshot([pane("alpha")])
        let client = FakeSessionClient(eventsOnStart: [.connected(snapshot)])
        let factory = FakeSessionClientFactory(clients: [namedDescriptor.id: client])
        let discovery = FakeSessionDiscovery(results: [.success([namedDescriptor])])
        let supervisor = makeSupervisor(discovery: discovery, factory: factory)
        let stream = await supervisor.events()
        var iterator = stream.makeAsyncIterator()

        await supervisor.start()

        let discoveryEvent = await iterator.next()
        let connectedEvent = await iterator.next()
        XCTAssertEqual(discoveryEvent, .discoverySnapshot([namedDescriptor]))
        XCTAssertEqual(connectedEvent, .connected(namedDescriptor, snapshot))
        await supervisor.stop()
    }

    func testOneClientDisconnectDoesNotChangeTheOtherClient() async throws {
        let first = FakeSessionClient(eventsOnStart: [.connected(clientSnapshot([pane("one")]))])
        let second = FakeSessionClient(eventsOnStart: [.connected(clientSnapshot([pane("two")]))])
        let factory = FakeSessionClientFactory(clients: [
            defaultDescriptor.id: first,
            namedDescriptor.id: second
        ])
        let discovery = FakeSessionDiscovery(results: [.success([defaultDescriptor, namedDescriptor])])
        let supervisor = makeSupervisor(discovery: discovery, factory: factory)
        let stream = await supervisor.events()
        var iterator = stream.makeAsyncIterator()

        await supervisor.start()
        _ = await iterator.next()
        _ = await iterator.next()
        _ = await iterator.next()
        await first.send(.disconnected("lost default"))

        let unavailableEvent = await iterator.next()
        XCTAssertEqual(unavailableEvent, .unavailable(.default, "lost default"))
        do {
            _ = try await supervisor.focus(sessionID: .default, paneID: "one")
            XCTFail("Expected disconnected session to be unavailable")
        } catch {
            XCTAssertEqual(error as? SessionSupervisorError, .sessionUnavailable("Default"))
        }
        let focused = try await supervisor.focus(sessionID: namedDescriptor.id, paneID: "two")
        XCTAssertEqual(focused.paneID, "two")
        await supervisor.stop()
    }

    func testFocusAndRefreshRouteOnlyToRequestedSession() async throws {
        let first = FakeSessionClient(eventsOnStart: [.connected(clientSnapshot([]))])
        let second = FakeSessionClient(eventsOnStart: [.connected(clientSnapshot([]))])
        let factory = FakeSessionClientFactory(clients: [
            defaultDescriptor.id: first,
            namedDescriptor.id: second
        ])
        let discovery = FakeSessionDiscovery(results: [.success([defaultDescriptor, namedDescriptor])])
        let supervisor = makeSupervisor(discovery: discovery, factory: factory)
        let stream = await supervisor.events()
        var iterator = stream.makeAsyncIterator()

        await supervisor.start()
        _ = await iterator.next()
        _ = await iterator.next()
        _ = await iterator.next()
        _ = try await supervisor.focus(sessionID: namedDescriptor.id, paneID: "target")
        await supervisor.refresh(sessionID: .default)

        let firstRefreshCount = await first.refreshCount
        let firstFocusedPaneIDs = await first.focusedPaneIDs
        let secondRefreshCount = await second.refreshCount
        let secondFocusedPaneIDs = await second.focusedPaneIDs
        XCTAssertEqual(firstRefreshCount, 1)
        XCTAssertEqual(firstFocusedPaneIDs, [])
        XCTAssertEqual(secondRefreshCount, 0)
        XCTAssertEqual(secondFocusedPaneIDs, ["target"])
        await supervisor.stop()
    }

    func testUnknownSessionFocusThrowsNamedUnavailableError() async {
        let discovery = FakeSessionDiscovery(results: [.success([])])
        let supervisor = makeSupervisor(discovery: discovery)
        await supervisor.start()

        do {
            _ = try await supervisor.focus(sessionID: .named("client"), paneID: "pane")
            XCTFail("Expected unavailable error")
        } catch {
            XCTAssertEqual(error as? SessionSupervisorError, .sessionUnavailable("client"))
        }
        await supervisor.stop()
    }

    func testStopCancelsConsumersAndStopsEveryClientOnce() async {
        let first = FakeSessionClient()
        let second = FakeSessionClient()
        let factory = FakeSessionClientFactory(clients: [
            defaultDescriptor.id: first,
            namedDescriptor.id: second
        ])
        let discovery = FakeSessionDiscovery(results: [.success([defaultDescriptor, namedDescriptor])])
        let supervisor = makeSupervisor(discovery: discovery, factory: factory)
        await supervisor.start()
        await waitUntil { await factory.makeCount == 2 }

        await supervisor.stop()
        await supervisor.stop()

        let firstStopCount = await first.stopCount
        let secondStopCount = await second.stopCount
        let firstTerminated = await first.streamTerminated
        let secondTerminated = await second.streamTerminated
        XCTAssertEqual(firstStopCount, 1)
        XCTAssertEqual(secondStopCount, 1)
        XCTAssertTrue(firstTerminated)
        XCTAssertTrue(secondTerminated)
    }

    func testOverlappingPeriodicScanAndRetryAreSingleFlightAndApplyNewestResult() async {
        let discovery = FakeSessionDiscovery(results: [
            .success([defaultDescriptor]),
            .success([namedDescriptor])
        ])
        await discovery.blockCall(1)
        let supervisor = makeSupervisor(discovery: discovery)
        let stream = await supervisor.events()
        var iterator = stream.makeAsyncIterator()
        await supervisor.start()
        await waitUntil { await discovery.callCount == 1 }

        let retry = Task { await supervisor.retryUnavailable() }
        await Task.yield()
        let maximumBeforeRelease = await discovery.maximumConcurrentCalls
        XCTAssertEqual(maximumBeforeRelease, 1)
        await discovery.releaseCall(1)
        await retry.value

        let firstEvent = await iterator.next()
        let secondEvent = await iterator.next()
        let maximumConcurrentCalls = await discovery.maximumConcurrentCalls
        let callCount = await discovery.callCount
        XCTAssertEqual(firstEvent, .discoverySnapshot([defaultDescriptor]))
        XCTAssertEqual(secondEvent, .discoverySnapshot([namedDescriptor]))
        XCTAssertEqual(maximumConcurrentCalls, 1)
        XCTAssertEqual(callCount, 2)
        await supervisor.stop()
    }

    func testStopAwaitsDiscoveryReconciliationConsumersAndSleepers() async {
        let client = FakeSessionClient()
        let factory = FakeSessionClientFactory(clients: [defaultDescriptor.id: client])
        let discovery = FakeSessionDiscovery(results: [.success([defaultDescriptor])])
        let sleeper = SupervisorTestSleeper()
        let supervisor = makeSupervisor(discovery: discovery, factory: factory, sleeper: sleeper)
        await supervisor.start()
        await waitUntil { await client.startCount == 1 }
        await waitUntil { await sleeper.waitCount == 1 }

        await supervisor.stop()

        let stopCount = await client.stopCount
        let streamTerminated = await client.streamTerminated
        let cancellationCount = await sleeper.cancellationCount
        let activeWaitCount = await sleeper.activeWaitCount
        XCTAssertEqual(stopCount, 1)
        XCTAssertTrue(streamTerminated)
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertEqual(activeWaitCount, 0)
    }

    func testStopDuringBlockedClientCreationCleansCreatedClientWithoutStartingIt() async {
        let client = FakeSessionClient()
        let factory = FakeSessionClientFactory(clients: [defaultDescriptor.id: client])
        await factory.blockCall(1)
        let discovery = FakeSessionDiscovery(results: [.success([defaultDescriptor])])
        let supervisor = makeSupervisor(discovery: discovery, factory: factory)
        await supervisor.start()
        await waitUntil { await factory.makeCount == 1 }

        let stop = Task { await supervisor.stop() }
        await Task.yield()
        await factory.releaseCall(1)
        await stop.value

        let startCount = await client.startCount
        let stopCount = await client.stopCount
        XCTAssertEqual(startCount, 0)
        XCTAssertEqual(stopCount, 1)
        do {
            _ = try await supervisor.focus(sessionID: .default, paneID: "pane")
            XCTFail("Expected runtime not to be inserted")
        } catch {
            XCTAssertEqual(error as? SessionSupervisorError, .sessionUnavailable("Default"))
        }
    }

    func testStopResumesRetryWaitingOnBlockedReconciliation() async {
        let discovery = FakeSessionDiscovery(results: [.success([])])
        await discovery.blockCall(1)
        let supervisor = makeSupervisor(discovery: discovery)
        let retryFinished = AsyncFlag()
        let stopFinished = AsyncFlag()
        await supervisor.start()
        await waitUntil { await discovery.callCount == 1 }
        let retry = Task {
            await supervisor.retryUnavailable()
            await retryFinished.set()
        }
        await Task.yield()

        let stop = Task {
            await supervisor.stop()
            await stopFinished.set()
        }
        await waitUntil { await retryFinished.value }
        let stopDidFinishEarly = await stopFinished.value
        XCTAssertFalse(stopDidFinishEarly)
        await discovery.releaseCall(1)
        await stop.value
        await retry.value

        let retryDidFinish = await retryFinished.value
        let stopDidFinish = await stopFinished.value
        let maximumConcurrentCalls = await discovery.maximumConcurrentCalls
        XCTAssertTrue(retryDidFinish)
        XCTAssertTrue(stopDidFinish)
        XCTAssertEqual(maximumConcurrentCalls, 1)
    }

    private var defaultDescriptor: SessionDescriptor {
        SessionDescriptor(id: .default, socketURL: URL(fileURLWithPath: "/tmp/default.sock"))
    }

    private var namedDescriptor: SessionDescriptor {
        SessionDescriptor(id: .named("work"), socketURL: URL(fileURLWithPath: "/tmp/work.sock"))
    }

    private func makeSupervisor(
        discovery: FakeSessionDiscovery,
        factory: FakeSessionClientFactory = FakeSessionClientFactory(),
        sleeper: SupervisorTestSleeper = SupervisorTestSleeper()
    ) -> SessionSupervisor {
        SessionSupervisor(
            discovery: discovery,
            clientFactory: factory,
            sleeper: sleeper,
            discoveryInterval: .seconds(2),
            removalGracePeriod: .seconds(10)
        )
    }
}

private enum SupervisorTestError: Error {
    case exhausted
}

private actor FakeSessionDiscovery: SessionDiscovering {
    var results: [Result<[SessionDescriptor], Error>]
    private(set) var callCount = 0
    private(set) var maximumConcurrentCalls = 0
    private var activeCalls = 0
    private var blockedCalls: Set<Int> = []
    private var releases: [Int: CheckedContinuation<Void, Never>] = [:]

    init(results: [Result<[SessionDescriptor], Error>]) {
        self.results = results
    }

    func discover() async throws -> [SessionDescriptor] {
        callCount += 1
        let call = callCount
        activeCalls += 1
        maximumConcurrentCalls = max(maximumConcurrentCalls, activeCalls)
        if blockedCalls.contains(call) {
            await withCheckedContinuation { releases[call] = $0 }
        }
        defer { activeCalls -= 1 }
        guard !results.isEmpty else { throw SupervisorTestError.exhausted }
        let result = results.count == 1 ? results[0] : results.removeFirst()
        return try result.get()
    }

    func blockCall(_ call: Int) { blockedCalls.insert(call) }

    func releaseCall(_ call: Int) {
        blockedCalls.remove(call)
        releases.removeValue(forKey: call)?.resume()
    }
}

private actor FakeSessionClient: SessionClientServing {
    nonisolated let stream: AsyncStream<HerdrClientEvent>
    private let continuation: AsyncStream<HerdrClientEvent>.Continuation
    private let eventsOnStart: [HerdrClientEvent]
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var retryCount = 0
    private(set) var refreshCount = 0
    private(set) var focusedPaneIDs: [String] = []
    private(set) var streamTerminated = false
    private(set) var focusIsAvailable = false

    init(eventsOnStart: [HerdrClientEvent] = []) {
        let pair = AsyncStream<HerdrClientEvent>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
        self.eventsOnStart = eventsOnStart
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.markStreamTerminated() }
        }
    }

    func events() -> AsyncStream<HerdrClientEvent> { stream }

    func start() {
        startCount += 1
        for event in eventsOnStart {
            if case .connected = event { focusIsAvailable = true }
            continuation.yield(event)
        }
    }

    func stop() {
        stopCount += 1
        focusIsAvailable = false
        continuation.finish()
    }

    func retryNow() { retryCount += 1 }
    func refresh() { refreshCount += 1 }

    func focus(paneID: String) throws -> PaneInfo {
        focusedPaneIDs.append(paneID)
        return pane(paneID)
    }

    func send(_ event: HerdrClientEvent) {
        switch event {
        case .connected: focusIsAvailable = true
        case .disconnected: focusIsAvailable = false
        case .snapshot: break
        }
        continuation.yield(event)
    }

    private func markStreamTerminated() { streamTerminated = true }
}

private actor FakeSessionClientFactory: SessionClientCreating {
    private var clients: [SessionID: FakeSessionClient]
    private(set) var requestedDescriptors: [SessionDescriptor] = []
    private(set) var makeCount = 0
    private var blockedCalls: Set<Int> = []
    private var releases: [Int: CheckedContinuation<Void, Never>] = [:]

    init(clients: [SessionID: FakeSessionClient] = [:]) {
        self.clients = clients
    }

    func makeClient(for descriptor: SessionDescriptor) async -> any SessionClientServing {
        makeCount += 1
        let call = makeCount
        requestedDescriptors.append(descriptor)
        if blockedCalls.contains(call) {
            await withCheckedContinuation { releases[call] = $0 }
        }
        if let client = clients[descriptor.id] { return client }
        let client = FakeSessionClient()
        clients[descriptor.id] = client
        return client
    }

    func client(for id: SessionID) -> FakeSessionClient? { clients[id] }
    func blockCall(_ call: Int) { blockedCalls.insert(call) }

    func releaseCall(_ call: Int) {
        blockedCalls.remove(call)
        releases.removeValue(forKey: call)?.resume()
    }
}

private actor SupervisorTestSleeper: Sleeper {
    private var waits: [(UUID, CheckedContinuation<Void, any Error>)] = []
    private(set) var waitCount = 0
    private(set) var cancellationCount = 0
    var activeWaitCount: Int { waits.count }

    func sleep(for duration: Duration) async throws {
        waitCount += 1
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { waits.append((id, $0)) }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func releaseFirst() async {
        while waits.isEmpty { await Task.yield() }
        waits.removeFirst().1.resume()
    }

    private func cancel(_ id: UUID) {
        guard let index = waits.firstIndex(where: { $0.0 == id }) else { return }
        cancellationCount += 1
        waits.remove(at: index).1.resume(throwing: CancellationError())
    }
}

private actor AsyncFlag {
    private(set) var value = false
    func set() { value = true }
}
