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

    func testMissingSocketPublishesUnavailableAndClearsConnectionImmediately() async {
        let client = FakeSessionClient(eventsOnStart: [.connected(clientSnapshot([pane("one")]))])
        let factory = FakeSessionClientFactory(clients: [.default: client])
        let discovery = FakeSessionDiscovery(results: [
            .success([defaultDescriptor]),
            .success([]),
            .success([])
        ])
        let sleeper = SupervisorTestSleeper()
        let supervisor = makeSupervisor(discovery: discovery, factory: factory, sleeper: sleeper)
        let recorder = await recordEvents(from: supervisor)

        await supervisor.start()
        await XCTAssertTrueAsync(await spinUntil { await client.startCount == 1 })
        await XCTAssertTrueAsync(await sleeper.releaseFirst(for: .seconds(2)))
        await XCTAssertTrueAsync(await spinUntil {
            await recorder.recorded.contains(.unavailable(.default, "Session socket unavailable"))
        })
        await XCTAssertTrueAsync(await sleeper.releaseFirst(for: .seconds(2)))
        await XCTAssertTrueAsync(await spinUntil { await discovery.callCount == 3 })

        do {
            _ = try await supervisor.focus(sessionID: .default, paneID: "one")
            XCTFail("Expected missing session to become unavailable immediately")
        } catch {
            XCTAssertEqual(error as? SessionSupervisorError, .sessionUnavailable("Default"))
        }
        let graceWaitCount = await sleeper.requestedDurations.filter { $0 == .seconds(10) }.count
        let unavailableCount = await recorder.recorded.filter {
            $0 == .unavailable(.default, "Session socket unavailable")
        }.count
        XCTAssertEqual(graceWaitCount, 1)
        XCTAssertEqual(unavailableCount, 1)
        await supervisor.stop()
        await recorder.task.value
    }

    func testReappearanceWithinGraceKeepsClientAndRetriesIt() async {
        let client = FakeSessionClient(eventsOnStart: [.connected(clientSnapshot([]))])
        let factory = FakeSessionClientFactory(clients: [.default: client])
        let discovery = FakeSessionDiscovery(results: [
            .success([defaultDescriptor]),
            .success([]),
            .success([defaultDescriptor])
        ])
        let sleeper = SupervisorTestSleeper()
        let supervisor = makeSupervisor(discovery: discovery, factory: factory, sleeper: sleeper)

        await supervisor.start()
        await XCTAssertTrueAsync(await spinUntil { await client.startCount == 1 })
        await XCTAssertTrueAsync(await sleeper.releaseFirst(for: .seconds(2)))
        await XCTAssertTrueAsync(await spinUntil { await sleeper.hasWait(for: .seconds(10)) })
        await XCTAssertTrueAsync(await sleeper.releaseFirst(for: .seconds(2)))
        await XCTAssertTrueAsync(await spinUntil { await client.retryCount == 1 })

        await XCTAssertEqualAsync(await factory.makeCount, 1)
        await XCTAssertEqualAsync(await client.retryCount, 1)
        await XCTAssertTrueAsync(await spinUntil {
            !(await sleeper.hasWait(for: .seconds(10)))
        })
        await supervisor.stop()
    }

    func testGraceExpiryStopsClientAwaitsEventConsumerThenPublishesRemoved() async {
        let client = FakeSessionClient(eventsOnStart: [.connected(clientSnapshot([]))])
        let factory = FakeSessionClientFactory(clients: [.default: client])
        let discovery = FakeSessionDiscovery(results: [.success([defaultDescriptor]), .success([])])
        let sleeper = SupervisorTestSleeper()
        let supervisor = makeSupervisor(discovery: discovery, factory: factory, sleeper: sleeper)
        let recorder = await recordEvents(from: supervisor)

        await supervisor.start()
        await XCTAssertTrueAsync(await spinUntil { await client.startCount == 1 })
        await XCTAssertTrueAsync(await sleeper.releaseFirst(for: .seconds(2)))
        await XCTAssertTrueAsync(await spinUntil { await sleeper.hasWait(for: .seconds(10)) })
        await XCTAssertTrueAsync(await sleeper.releaseFirst(for: .seconds(10)))
        await XCTAssertTrueAsync(await spinUntil { await recorder.recorded.contains(.removed(.default)) })

        await XCTAssertEqualAsync(await client.stopCount, 1)
        await XCTAssertTrueAsync(await client.streamTerminated)
        let events = await recorder.recorded
        let unavailableIndex = events.firstIndex(of: .unavailable(.default, "Session socket unavailable"))
        let removedIndex = events.firstIndex(of: .removed(.default))
        XCTAssertNotNil(unavailableIndex)
        XCTAssertNotNil(removedIndex)
        if let unavailableIndex, let removedIndex { XCTAssertLessThan(unavailableIndex, removedIndex) }
        await supervisor.stop()
        await recorder.task.value
    }

    func testStopDuringGraceCleanupAwaitsInFlightRemoval() async {
        let client = FakeSessionClient(eventsOnStart: [.connected(clientSnapshot([]))])
        await client.setStopBlocked(true)
        let factory = FakeSessionClientFactory(clients: [.default: client])
        let discovery = FakeSessionDiscovery(results: [.success([defaultDescriptor]), .success([])])
        let sleeper = SupervisorTestSleeper()
        let supervisor = makeSupervisor(discovery: discovery, factory: factory, sleeper: sleeper)
        let recorder = await recordEvents(from: supervisor)

        await supervisor.start()
        await XCTAssertTrueAsync(await spinUntil { await client.startCount == 1 })
        await XCTAssertTrueAsync(await sleeper.releaseFirst(for: .seconds(2)))
        await XCTAssertTrueAsync(await spinUntil { await sleeper.hasWait(for: .seconds(10)) })
        await XCTAssertTrueAsync(await sleeper.releaseFirst(for: .seconds(10)))
        await XCTAssertTrueAsync(await spinUntil { await client.stopStarted })

        let stopped = AsyncFlag()
        let stopTask = Task {
            await supervisor.stop()
            await stopped.set()
        }
        await Task.yield()
        await XCTAssertFalseAsync(await stopped.value)
        await XCTAssertFalseAsync(await recorder.finished.value)
        await client.releaseStop()
        await stopTask.value

        await XCTAssertTrueAsync(await stopped.value)
        await XCTAssertTrueAsync(await client.streamTerminated)
        await XCTAssertTrueAsync(await recorder.finished.value)
    }

    func testReappearanceDuringBlockedRemovalKeepsNewRuntimeAndSuppressesOldRemovedEvent() async {
        let oldClient = FakeSessionClient(eventsOnStart: [.connected(clientSnapshot([pane("old")]))])
        await oldClient.setStopBlocked(true)
        let replacement = FakeSessionClient(eventsOnStart: [.connected(clientSnapshot([pane("new")]))])
        let factory = FakeSessionClientFactory(clients: [.default: oldClient])
        await factory.enqueue(replacement, for: .default)
        let discovery = FakeSessionDiscovery(results: [
            .success([defaultDescriptor]),
            .success([]),
            .success([defaultDescriptor])
        ])
        let sleeper = SupervisorTestSleeper()
        let supervisor = makeSupervisor(discovery: discovery, factory: factory, sleeper: sleeper)
        let recorder = await recordEvents(from: supervisor)

        await supervisor.start()
        await XCTAssertTrueAsync(await spinUntil { await oldClient.startCount == 1 })
        await XCTAssertTrueAsync(await sleeper.releaseFirst(for: .seconds(2)))
        await XCTAssertTrueAsync(await spinUntil { await sleeper.hasWait(for: .seconds(10)) })
        await XCTAssertTrueAsync(await sleeper.releaseFirst(for: .seconds(10)))
        await XCTAssertTrueAsync(await spinUntil { await oldClient.stopStarted })
        await XCTAssertTrueAsync(await sleeper.releaseFirst(for: .seconds(2)))
        await XCTAssertTrueAsync(await spinUntil { await replacement.startCount == 1 })
        let replacementConnected = SessionSupervisorEvent.connected(
            defaultDescriptor,
            clientSnapshot([pane("new")])
        )
        await XCTAssertTrueAsync(await spinUntil {
            await recorder.recorded.contains(replacementConnected)
        })

        await oldClient.releaseStop()
        await XCTAssertTrueAsync(await spinUntil { await oldClient.streamTerminated })
        await Task.yield()
        await XCTAssertFalseAsync(await recorder.recorded.contains(.removed(.default)))
        await XCTAssertEqualAsync(await factory.makeCount, 2)
        await supervisor.stop()
        await recorder.task.value
    }

    func testLateEventFromRemovedGenerationIsIgnored() async {
        let oldClient = FakeSessionClient(eventsOnStart: [.connected(clientSnapshot([]))])
        await oldClient.setStopBlocked(true)
        let factory = FakeSessionClientFactory(clients: [.default: oldClient])
        let discovery = FakeSessionDiscovery(results: [.success([defaultDescriptor]), .success([])])
        let sleeper = SupervisorTestSleeper()
        let supervisor = makeSupervisor(discovery: discovery, factory: factory, sleeper: sleeper)
        let recorder = await recordEvents(from: supervisor)

        await supervisor.start()
        await XCTAssertTrueAsync(await spinUntil { await oldClient.startCount == 1 })
        await XCTAssertTrueAsync(await sleeper.releaseFirst(for: .seconds(2)))
        await XCTAssertTrueAsync(await spinUntil { await sleeper.hasWait(for: .seconds(10)) })
        await XCTAssertTrueAsync(await sleeper.releaseFirst(for: .seconds(10)))
        await XCTAssertTrueAsync(await spinUntil { await oldClient.stopStarted })
        await oldClient.send(.snapshot(clientSnapshot([pane("late")])))
        await Task.yield()

        await XCTAssertFalseAsync(await recorder.recorded.contains(.snapshot(.default, clientSnapshot([pane("late")]))))
        await oldClient.releaseStop()
        await XCTAssertTrueAsync(await spinUntil { await recorder.recorded.contains(.removed(.default)) })
        await supervisor.stop()
        await recorder.task.value
    }

    func testPresentButDisconnectedSocketIsNotRemoved() async {
        let client = FakeSessionClient(eventsOnStart: [.connected(clientSnapshot([]))])
        let factory = FakeSessionClientFactory(clients: [.default: client])
        let discovery = FakeSessionDiscovery(results: [
            .success([defaultDescriptor]),
            .success([defaultDescriptor]),
            .success([defaultDescriptor])
        ])
        let sleeper = SupervisorTestSleeper()
        let supervisor = makeSupervisor(discovery: discovery, factory: factory, sleeper: sleeper)
        let recorder = await recordEvents(from: supervisor)

        await supervisor.start()
        await XCTAssertTrueAsync(await spinUntil { await client.startCount == 1 })
        await client.send(.disconnected("connection lost"))
        await XCTAssertTrueAsync(await spinUntil {
            await recorder.recorded.contains(.unavailable(.default, "connection lost"))
        })
        await XCTAssertTrueAsync(await sleeper.releaseFirst(for: .seconds(2)))
        await XCTAssertTrueAsync(await spinUntil { await discovery.callCount == 2 })
        await XCTAssertTrueAsync(await sleeper.releaseFirst(for: .seconds(2)))
        await XCTAssertTrueAsync(await spinUntil { await discovery.callCount == 3 })

        await XCTAssertFalseAsync(await sleeper.requestedDurations.contains(.seconds(10)))
        await XCTAssertFalseAsync(await recorder.recorded.contains(.removed(.default)))
        await XCTAssertEqualAsync(await client.stopCount, 0)
        await supervisor.stop()
        await recorder.task.value
    }

    func testRetryRunsDiscoveryImmediatelyAndRetriesOnlyDisconnectedClients() async {
        let connected = FakeSessionClient(eventsOnStart: [.connected(clientSnapshot([]))])
        let disconnected = FakeSessionClient(eventsOnStart: [.connected(clientSnapshot([]))])
        let disconnectedID = namedDescriptor.id
        let factory = FakeSessionClientFactory(clients: [
            .default: connected,
            disconnectedID: disconnected
        ])
        let descriptors = [defaultDescriptor, namedDescriptor]
        let discovery = FakeSessionDiscovery(results: [.success(descriptors), .success(descriptors)])
        let supervisor = makeSupervisor(discovery: discovery, factory: factory)
        let recorder = await recordEvents(from: supervisor)

        await supervisor.start()
        await XCTAssertTrueAsync(await spinUntil { await disconnected.startCount == 1 })
        await disconnected.send(.disconnected("lost"))
        await XCTAssertTrueAsync(await spinUntil {
            await recorder.recorded.contains(.unavailable(disconnectedID, "lost"))
        })
        let retry = Task { await supervisor.retryUnavailable() }
        await retry.value

        await XCTAssertEqualAsync(await discovery.callCount, 2)
        await XCTAssertEqualAsync(await connected.retryCount, 0)
        await XCTAssertEqualAsync(await disconnected.retryCount, 1)
        await supervisor.stop()
        await recorder.task.value
    }

    func testCoalescedRetryCallersShareOutcomeAndRetryReappearedClientOnce() async {
        let client = FakeSessionClient(eventsOnStart: [.connected(clientSnapshot([]))])
        let factory = FakeSessionClientFactory(clients: [.default: client])
        let discovery = FakeSessionDiscovery(results: [
            .success([defaultDescriptor]),
            .success([]),
            .success([defaultDescriptor])
        ])
        await discovery.blockCall(2)
        let sleeper = SupervisorTestSleeper()
        let supervisor = makeSupervisor(discovery: discovery, factory: factory, sleeper: sleeper)

        await supervisor.start()
        await XCTAssertTrueAsync(await spinUntil { await client.startCount == 1 })
        await XCTAssertTrueAsync(await sleeper.releaseFirst(for: .seconds(2)))
        await XCTAssertTrueAsync(await spinUntil { await discovery.callCount == 2 })
        let firstRetry = Task { await supervisor.retryUnavailable() }
        let secondRetry = Task { await supervisor.retryUnavailable() }
        for _ in 0..<100 { await Task.yield() }
        await XCTAssertEqualAsync(await discovery.maximumConcurrentCalls, 1)
        await discovery.releaseCall(2)
        await firstRetry.value
        await secondRetry.value

        await XCTAssertEqualAsync(await client.retryCount, 1)
        await XCTAssertEqualAsync(await discovery.maximumConcurrentCalls, 1)
        await XCTAssertEqualAsync(await discovery.callCount, 3)
        await supervisor.stop()
    }

    func testCoalescedRetryCallersRetryStableDisconnectedClientOncePerSharedOutcome() async {
        let client = FakeSessionClient(eventsOnStart: [.connected(clientSnapshot([]))])
        let factory = FakeSessionClientFactory(clients: [.default: client])
        let discovery = FakeSessionDiscovery(results: [
            .success([defaultDescriptor]),
            .success([defaultDescriptor]),
            .success([defaultDescriptor])
        ])
        await discovery.blockCall(2)
        let sleeper = SupervisorTestSleeper()
        let supervisor = makeSupervisor(discovery: discovery, factory: factory, sleeper: sleeper)
        let recorder = await recordEvents(from: supervisor)

        await supervisor.start()
        await XCTAssertTrueAsync(await spinUntil { await client.startCount == 1 })
        await client.send(.disconnected("lost"))
        await XCTAssertTrueAsync(await spinUntil {
            await recorder.recorded.contains(.unavailable(.default, "lost"))
        })
        await XCTAssertTrueAsync(await sleeper.releaseFirst(for: .seconds(2)))
        await XCTAssertTrueAsync(await spinUntil { await discovery.callCount == 2 })

        let firstRetry = Task { await supervisor.retryUnavailable() }
        let secondRetry = Task { await supervisor.retryUnavailable() }
        for _ in 0..<100 { await Task.yield() }
        await discovery.releaseCall(2)
        await firstRetry.value
        await secondRetry.value

        await XCTAssertEqualAsync(await discovery.callCount, 3)
        await XCTAssertEqualAsync(await client.retryCount, 1)

        await supervisor.retryUnavailable()
        await XCTAssertEqualAsync(await discovery.callCount, 4)
        await XCTAssertEqualAsync(await client.retryCount, 2)
        await supervisor.stop()
        await recorder.task.value
    }

    func testCancelledRetryWaiterReturnsBeforeScanAndNeverRetriesClient() async {
        let client = FakeSessionClient(eventsOnStart: [.connected(clientSnapshot([]))])
        let factory = FakeSessionClientFactory(clients: [.default: client])
        let discovery = FakeSessionDiscovery(results: [
            .success([defaultDescriptor]),
            .success([defaultDescriptor]),
            .success([defaultDescriptor])
        ])
        await discovery.blockCall(2)
        let sleeper = SupervisorTestSleeper()
        let supervisor = makeSupervisor(discovery: discovery, factory: factory, sleeper: sleeper)
        let recorder = await recordEvents(from: supervisor)
        let retryReturned = AsyncFlag()

        await supervisor.start()
        await XCTAssertTrueAsync(await spinUntil { await client.startCount == 1 })
        await client.send(.disconnected("lost"))
        await XCTAssertTrueAsync(await spinUntil {
            await recorder.recorded.contains(.unavailable(.default, "lost"))
        })
        await XCTAssertTrueAsync(await sleeper.releaseFirst(for: .seconds(2)))
        await XCTAssertTrueAsync(await spinUntil { await discovery.callCount == 2 })

        let retry = Task {
            await supervisor.retryUnavailable()
            await retryReturned.set()
        }
        for _ in 0..<100 { await Task.yield() }
        retry.cancel()
        let returnedBeforeScan = await spinUntil { await retryReturned.value }

        XCTAssertTrue(returnedBeforeScan)
        await XCTAssertEqualAsync(await client.retryCount, 0)
        await discovery.releaseCall(2)
        await retry.value
        await XCTAssertTrueAsync(await spinUntil { await discovery.callCount == 3 })
        await XCTAssertEqualAsync(await client.retryCount, 0)
        await supervisor.stop()
        await recorder.task.value
    }

    func testDisconnectedEventWhileMissingDoesNotPublishSecondUnavailableReason() async {
        let client = FakeSessionClient(eventsOnStart: [.connected(clientSnapshot([]))])
        let factory = FakeSessionClientFactory(clients: [.default: client])
        let discovery = FakeSessionDiscovery(results: [.success([defaultDescriptor]), .success([])])
        let sleeper = SupervisorTestSleeper()
        let supervisor = makeSupervisor(discovery: discovery, factory: factory, sleeper: sleeper)
        let recorder = await recordEvents(from: supervisor)

        await supervisor.start()
        await XCTAssertTrueAsync(await spinUntil { await client.startCount == 1 })
        await XCTAssertTrueAsync(await sleeper.releaseFirst(for: .seconds(2)))
        await XCTAssertTrueAsync(await spinUntil {
            await recorder.recorded.contains(
                .unavailable(.default, "Session socket unavailable")
            )
        })
        await client.send(.disconnected("late transport close"))
        for _ in 0..<20_000 { await Task.yield() }

        let unavailableEvents = await recorder.recorded.filter {
            if case .unavailable(.default, _) = $0 { return true }
            return false
        }
        XCTAssertEqual(
            unavailableEvents,
            [.unavailable(.default, "Session socket unavailable")]
        )
        await supervisor.stop()
        await recorder.task.value
    }

    func testDiscoveryFailureDoesNotPublishEmptySnapshotOrRemoveHealthyRuntime() async throws {
        let client = FakeSessionClient(eventsOnStart: [.connected(clientSnapshot([]))])
        let factory = FakeSessionClientFactory(clients: [.default: client])
        let discovery = FakeSessionDiscovery(results: [
            .success([defaultDescriptor]),
            .failure(SupervisorTestError.expectedFailure)
        ])
        let supervisor = makeSupervisor(discovery: discovery, factory: factory)
        let recorder = await recordEvents(from: supervisor)

        await supervisor.start()
        await XCTAssertTrueAsync(await spinUntil { await client.startCount == 1 })
        await supervisor.retryUnavailable()
        let focused = try await supervisor.focus(sessionID: .default, paneID: "healthy")

        XCTAssertEqual(focused.paneID, "healthy")
        await XCTAssertEqualAsync(await recorder.recorded.filter {
            if case .discoverySnapshot = $0 { return true }
            return false
        }.count, 1)
        await XCTAssertFalseAsync(await recorder.recorded.contains(.discoverySnapshot([])))
        await XCTAssertEqualAsync(await client.stopCount, 0)
        await supervisor.stop()
        await recorder.task.value
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

    private func recordEvents(from supervisor: SessionSupervisor) async -> EventRecording {
        let recorder = SessionEventRecorder()
        let finished = AsyncFlag()
        let stream = await supervisor.events()
        let task = Task {
            for await event in stream { await recorder.append(event) }
            await finished.set()
        }
        return EventRecording(recorder: recorder, task: task, finished: finished)
    }
}

private enum SupervisorTestError: Error {
    case exhausted
    case expectedFailure
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
    private(set) var stopStarted = false
    private var stopIsBlocked = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

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

    func stop() async {
        stopCount += 1
        stopStarted = true
        if stopIsBlocked {
            await withCheckedContinuation { stopWaiters.append($0) }
        }
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

    func setStopBlocked(_ blocked: Bool) { stopIsBlocked = blocked }

    func releaseStop() {
        stopIsBlocked = false
        let waiters = stopWaiters
        stopWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func markStreamTerminated() { streamTerminated = true }
}

private actor FakeSessionClientFactory: SessionClientCreating {
    private var availableClients: [SessionID: [FakeSessionClient]]
    private var mostRecentClients: [SessionID: FakeSessionClient] = [:]
    private(set) var requestedDescriptors: [SessionDescriptor] = []
    private(set) var makeCount = 0
    private var blockedCalls: Set<Int> = []
    private var releases: [Int: CheckedContinuation<Void, Never>] = [:]

    init(clients: [SessionID: FakeSessionClient] = [:]) {
        availableClients = clients.mapValues { [$0] }
    }

    func makeClient(for descriptor: SessionDescriptor) async -> any SessionClientServing {
        makeCount += 1
        let call = makeCount
        requestedDescriptors.append(descriptor)
        if blockedCalls.contains(call) {
            await withCheckedContinuation { releases[call] = $0 }
        }
        let client: FakeSessionClient
        if var available = availableClients[descriptor.id], !available.isEmpty {
            client = available.removeFirst()
            availableClients[descriptor.id] = available
        } else {
            client = FakeSessionClient()
        }
        mostRecentClients[descriptor.id] = client
        return client
    }

    func client(for id: SessionID) -> FakeSessionClient? {
        mostRecentClients[id] ?? availableClients[id]?.first
    }

    func enqueue(_ client: FakeSessionClient, for id: SessionID) {
        availableClients[id, default: []].append(client)
    }
    func blockCall(_ call: Int) { blockedCalls.insert(call) }

    func releaseCall(_ call: Int) {
        blockedCalls.remove(call)
        releases.removeValue(forKey: call)?.resume()
    }
}

private actor SupervisorTestSleeper: Sleeper {
    private struct Wait {
        let id: UUID
        let duration: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var waits: [Wait] = []
    private(set) var waitCount = 0
    private(set) var cancellationCount = 0
    private(set) var requestedDurations: [Duration] = []
    var activeWaitCount: Int { waits.count }

    func sleep(for duration: Duration) async throws {
        waitCount += 1
        requestedDurations.append(duration)
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation {
                waits.append(Wait(id: id, duration: duration, continuation: $0))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func releaseFirst() async {
        while waits.isEmpty { await Task.yield() }
        waits.removeFirst().continuation.resume()
    }

    func hasWait(for duration: Duration) -> Bool {
        waits.contains { $0.duration == duration }
    }

    func releaseFirst(for duration: Duration) async -> Bool {
        for _ in 0..<20_000 {
            if let index = waits.firstIndex(where: { $0.duration == duration }) {
                waits.remove(at: index).continuation.resume()
                return true
            }
            await Task.yield()
        }
        return false
    }

    private func cancel(_ id: UUID) {
        guard let index = waits.firstIndex(where: { $0.id == id }) else { return }
        cancellationCount += 1
        waits.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

private actor AsyncFlag {
    private(set) var value = false
    func set() { value = true }
}

private actor SessionEventRecorder {
    private(set) var recorded: [SessionSupervisorEvent] = []
    func append(_ event: SessionSupervisorEvent) { recorded.append(event) }
}

private struct EventRecording: Sendable {
    let recorder: SessionEventRecorder
    let task: Task<Void, Never>
    let finished: AsyncFlag
    var recorded: [SessionSupervisorEvent] { get async { await recorder.recorded } }
}

private func spinUntil(
    attempts: Int = 20_000,
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}

private func XCTAssertTrueAsync(
    _ expression: @autoclosure () async -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let value = await expression()
    XCTAssertTrue(value, file: file, line: line)
}

private func XCTAssertFalseAsync(
    _ expression: @autoclosure () async -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let value = await expression()
    XCTAssertFalse(value, file: file, line: line)
}

private func XCTAssertEqualAsync<T: Equatable>(
    _ first: @autoclosure () async -> T,
    _ second: @autoclosure () async -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let firstValue = await first()
    let secondValue = await second()
    XCTAssertEqual(firstValue, secondValue, file: file, line: line)
}
