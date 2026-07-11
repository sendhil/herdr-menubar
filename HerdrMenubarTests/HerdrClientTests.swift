import Foundation
import XCTest
@testable import HerdrMenubar

final class HerdrClientTests: XCTestCase {
    func testBootstrapSubscribesBeforeTakingAuthoritativeSnapshot() async throws {
        let factory = FakeHerdrConnectionFactory()
        let client = HerdrClient(
            connectionFactory: factory,
            pathResolver: FakePathResolver(),
            backoff: .immediate,
            sleeper: ImmediateSleeper()
        )

        await client.start()
        let subscription = await factory.connection(at: 0)
        let subscribe = await subscription.nextSent()
        XCTAssertEqual(subscribe.method, "events.subscribe")
        XCTAssertEqual(Set(subscribe.events ?? []), [
            "pane.created", "pane.closed", "pane.focused", "pane.moved", "pane.exited",
            "pane.agent_detected", "pane.agent_status_changed"
        ])
        await subscription.reply(to: subscribe, result: #"{"type":"subscription_started"}"#)

        let listConnection = await factory.connection(at: 1)
        let list = await listConnection.nextSent()
        XCTAssertEqual(list.method, "pane.list")
        await listConnection.reply(to: list, result: paneListResult(ids: ["initial"]))

        let event = await nextEvent(from: client)
        XCTAssertEqual(event, .connected([pane("initial")]))
        await client.stop()
    }

    func testRelevantEventRefreshesFromAuthoritativeSnapshot() async throws {
        let (client, factory, subscription) = await bootstrappedClient(ids: ["old"])
        await subscription.push(#"{"event":"pane.agent_status_changed","data":{"pane_id":"old"}}"#)

        let refreshConnection = await factory.connection(at: 2)
        let request = await refreshConnection.nextSent()
        XCTAssertEqual(request.method, "pane.list")
        await refreshConnection.reply(to: request, result: paneListResult(ids: ["new"]))
        let event = await nextEvent(from: client)
        XCTAssertEqual(event, .snapshot([pane("new")]))
        await client.stop()
    }

    func testEventBurstCoalescesToOneFollowUpRefresh() async throws {
        let (client, factory, subscription) = await bootstrappedClient(ids: [])
        await subscription.push(#"{"event":"pane.created","data":{}}"#)
        let firstConnection = await factory.connection(at: 2)
        let first = await firstConnection.nextSent()

        await subscription.push(#"{"event":"pane.closed","data":{}}"#)
        await subscription.push(#"{"event":"pane.focused","data":{}}"#)
        await firstConnection.reply(to: first, result: paneListResult(ids: ["one"]))
        let firstEvent = await nextEvent(from: client)
        XCTAssertEqual(firstEvent, .snapshot([pane("one")]))

        let secondConnection = await factory.connection(at: 3)
        let second = await secondConnection.nextSent()
        await secondConnection.reply(to: second, result: paneListResult(ids: ["two"]))
        let secondEvent = await nextEvent(from: client)
        XCTAssertEqual(secondEvent, .snapshot([pane("two")]))
        try await Task.sleep(for: .milliseconds(20))
        let connectionCount = await factory.connectionCount
        XCTAssertEqual(connectionCount, 4)
        await client.stop()
    }

    func testFocusUsesOneRequestConnectionAndStrictlyCorrelatesResponse() async throws {
        let (client, factory, _) = await bootstrappedClient(ids: [])
        let focusTask = Task { try await client.focus(paneID: "focused") }
        let connection = await factory.connection(at: 2)
        let request = await connection.nextSent()
        XCTAssertEqual(request.method, "pane.focus")
        XCTAssertEqual(request.paneID, "focused")
        await connection.reply(to: request, result: paneFocusResult(id: "focused"))
        let focusedPane = try await focusTask.value
        XCTAssertEqual(focusedPane, pane("focused"))
        let focusConnectionClosed = await connection.isClosed
        XCTAssertTrue(focusConnectionClosed)

        let mismatchTask = Task { try await client.focus(paneID: "mismatch") }
        let mismatchConnection = await factory.connection(at: 3)
        let mismatch = await mismatchConnection.nextSent()
        await mismatchConnection.push(#"{"id":"wrong","result":{"type":"pane_info","pane":\#(paneJSON("mismatch"))}}"#)
        do {
            _ = try await mismatchTask.value
            XCTFail("Expected response ID mismatch")
        } catch let error as HerdrClientError {
            XCTAssertEqual(error, .responseIDMismatch(expected: mismatch.id, actual: "wrong"))
        }
        await client.stop()
    }

    func testRequestTimesOutAndClosesItsOneRequestConnection() async throws {
        let factory = FakeHerdrConnectionFactory()
        let client = HerdrClient(
            connectionFactory: factory,
            pathResolver: FakePathResolver(),
            backoff: .immediate,
            sleeper: ImmediateSleeper(),
            requestTimeout: .milliseconds(20)
        )
        await client.start()
        _ = await completeBootstrap(factory: factory, ids: [])

        let focusTask = Task { try await client.focus(paneID: "slow") }
        let connection = await factory.connection(at: 2)
        _ = await connection.nextSent()
        do {
            _ = try await focusTask.value
            XCTFail("Expected timeout")
        } catch let error as HerdrClientError {
            XCTAssertEqual(error, .timeout)
        }
        let connectionClosed = await connection.isClosed
        XCTAssertTrue(connectionClosed)
        await client.stop()
    }

    func testAPIErrorIsThrownWithoutInvalidatingConnection() async throws {
        let (client, factory, _) = await bootstrappedClient(ids: [])
        let focusTask = Task { try await client.focus(paneID: "missing") }
        let connection = await factory.connection(at: 2)
        let request = await connection.nextSent()
        await connection.push(#"{"id":"\#(request.id)","error":{"code":"not_found","message":"Missing pane"}}"#)
        do {
            _ = try await focusTask.value
            XCTFail("Expected API error")
        } catch let error as HerdrAPIError {
            XCTAssertEqual(error, HerdrAPIError(code: "not_found", message: "Missing pane"))
        }
        let connectionClosed = await connection.isClosed
        XCTAssertTrue(connectionClosed)
        await client.stop()
    }

    func testOrdinaryRequestSocketClosureInvalidatesAndRestartsBootstrap() async throws {
        let (client, factory, _) = await bootstrappedClient(ids: ["live"])
        let events = await client.events()
        let focusTask = Task { try await client.focus(paneID: "live") }
        let focusConnection = await factory.connection(at: 2)
        _ = await focusConnection.nextSent()
        await focusConnection.finish()

        do {
            _ = try await focusTask.value
            XCTFail("Expected socket closure")
        } catch let error as HerdrClientError {
            XCTAssertEqual(error, .connectionClosed)
        }
        guard case .disconnected = await events.next() else {
            return XCTFail("Expected disconnected event")
        }
        let replacement = await factory.connection(at: 3)
        let subscribe = await replacement.nextSent()
        XCTAssertEqual(subscribe.method, "events.subscribe")
        await client.stop()
    }

    func testDisconnectInvalidatesSnapshotAndReconnectsWithOneBackoffLoop() async throws {
        let sleeper = ControlledSleeper()
        let factory = FakeHerdrConnectionFactory()
        let client = HerdrClient(
            connectionFactory: factory,
            pathResolver: FakePathResolver(),
            backoff: BackoffPolicy(delays: [.milliseconds(500), .seconds(1)], jitter: { 0 }),
            sleeper: sleeper
        )
        let events = await client.events()
        await client.start()
        let subscription = await completeBootstrap(factory: factory, ids: ["live"])
        let connectedEvent = await events.next()
        XCTAssertEqual(connectedEvent, .connected([pane("live")]))

        await subscription.finish()
        guard case .disconnected = await events.next() else {
            return XCTFail("Expected disconnected event")
        }
        let sleepCount = await sleeper.sleepCount
        let connectionCount = await factory.connectionCount
        XCTAssertEqual(sleepCount, 1)
        XCTAssertEqual(connectionCount, 2)

        await sleeper.releaseFirst()
        let replacement = await factory.connection(at: 2)
        let replacementRequest = await replacement.nextSent()
        XCTAssertEqual(replacementRequest.method, "events.subscribe")
        let recordedDurations = await sleeper.recordedDurations
        XCTAssertEqual(recordedDurations, [.milliseconds(500)])
        await client.stop()
    }

    func testManualRetryCancelsBackoffAndReconnectsImmediately() async throws {
        let sleeper = ControlledSleeper()
        let factory = FakeHerdrConnectionFactory()
        let client = HerdrClient(
            connectionFactory: factory,
            pathResolver: FakePathResolver(),
            backoff: BackoffPolicy(delays: [.seconds(15)], jitter: { 0 }),
            sleeper: sleeper
        )
        await client.start()
        let subscription = await completeBootstrap(factory: factory, ids: [])
        await subscription.finish()
        await waitUntil { await sleeper.sleepCount == 1 }

        await client.retryNow()
        let replacement = await factory.connection(at: 2)
        let replacementRequest = await replacement.nextSent()
        XCTAssertEqual(replacementRequest.method, "events.subscribe")
        let cancelCount = await sleeper.cancelCount
        XCTAssertEqual(cancelCount, 1)
        await client.stop()
    }

    func testStopCancelsPendingReconnectAndPreventsFurtherConnections() async throws {
        let sleeper = ControlledSleeper()
        let factory = FakeHerdrConnectionFactory()
        let client = HerdrClient(
            connectionFactory: factory,
            pathResolver: FakePathResolver(),
            backoff: BackoffPolicy(delays: [.seconds(15)], jitter: { 0 }),
            sleeper: sleeper
        )
        await client.start()
        await client.start()
        let subscription = await completeBootstrap(factory: factory, ids: [])
        await subscription.finish()
        await waitUntil { await sleeper.sleepCount == 1 }

        await client.stop()
        try await Task.sleep(for: .milliseconds(20))
        let cancelCount = await sleeper.cancelCount
        let connectionCount = await factory.connectionCount
        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(connectionCount, 2)
    }

    func testBackoffIsBoundedAndClampsInjectedJitter() {
        let high = BackoffPolicy(delays: [.seconds(15)], jitter: { 1 })
        let low = BackoffPolicy(delays: [.seconds(15)], jitter: { -1 })
        XCTAssertEqual(high.delay(attempt: 100), .seconds(18))
        XCTAssertEqual(low.delay(attempt: 100), .seconds(12))
    }

    func testMalformedAndUnknownEventsDoNotTerminateSubscription() async throws {
        let (client, factory, subscription) = await bootstrappedClient(ids: [])
        await subscription.push("not json")
        await subscription.push(#"{"event":"future.event","data":{}}"#)
        await subscription.push(#"{"event":"pane.moved","data":{}}"#)

        let refreshConnection = await factory.connection(at: 2)
        let refresh = await refreshConnection.nextSent()
        await refreshConnection.reply(to: refresh, result: paneListResult(ids: ["still-live"]))
        let event = await nextEvent(from: client)
        XCTAssertEqual(event, .snapshot([pane("still-live")]))
        await client.stop()
    }

    private func bootstrappedClient(ids: [String]) async -> (HerdrClient, FakeHerdrConnectionFactory, FakeHerdrConnection) {
        let factory = FakeHerdrConnectionFactory()
        let client = HerdrClient(connectionFactory: factory, pathResolver: FakePathResolver(), backoff: .immediate, sleeper: ImmediateSleeper())
        let events = await client.events()
        await client.start()
        let subscription = await completeBootstrap(factory: factory, ids: ids)
        _ = await events.next()
        return (client, factory, subscription)
    }

    private func completeBootstrap(factory: FakeHerdrConnectionFactory, ids: [String]) async -> FakeHerdrConnection {
        let subscription = await factory.connection(at: 0)
        let subscribe = await subscription.nextSent()
        await subscription.reply(to: subscribe, result: #"{"type":"subscription_started"}"#)
        let listConnection = await factory.connection(at: 1)
        let list = await listConnection.nextSent()
        await listConnection.reply(to: list, result: paneListResult(ids: ids))
        return subscription
    }

    private func nextEvent(from client: HerdrClient) async -> HerdrClientEvent? {
        let stream = await client.events()
        return await stream.next()
    }
}

private struct FakePathResolver: SocketPathResolving {
    func resolve(environment: [String: String], homeDirectory: URL) -> URL {
        URL(fileURLWithPath: "/tmp/fake-herdr.sock")
    }
}

private actor FakeHerdrConnectionFactory: HerdrConnectionFactory {
    private var connections: [FakeHerdrConnection] = []
    private var waiters: [Int: [CheckedContinuation<FakeHerdrConnection, Never>]] = [:]

    var connectionCount: Int { connections.count }

    func connect(to socketURL: URL) async throws -> any HerdrConnection {
        let connection = FakeHerdrConnection()
        connections.append(connection)
        let index = connections.count - 1
        for waiter in waiters.removeValue(forKey: index) ?? [] {
            waiter.resume(returning: connection)
        }
        return connection
    }

    func connection(at index: Int) async -> FakeHerdrConnection {
        if connections.indices.contains(index) { return connections[index] }
        return await withCheckedContinuation { continuation in
            waiters[index, default: []].append(continuation)
        }
    }
}

private struct RecordedRequest: Sendable {
    let id: String
    let method: String
    let paneID: String?
    let events: [String]?
}

private actor FakeHerdrConnection: HerdrConnection {
    private var sent: [RecordedRequest] = []
    private var sentWaiters: [CheckedContinuation<RecordedRequest, Never>] = []
    private var inbound: [Data?] = []
    private var readWaiters: [UUID: CheckedContinuation<Data?, any Error>] = [:]
    private(set) var isClosed = false

    func sendLine(_ data: Data) async throws {
        struct Header: Decodable { let id: String; let method: String; let params: Params }
        struct Params: Decodable {
            let paneID: String?
            let events: [String]?
            enum CodingKeys: String, CodingKey { case paneID = "pane_id"; case events }
        }
        let request = try JSONDecoder().decode(Header.self, from: data)
        let recorded = RecordedRequest(
            id: request.id,
            method: request.method,
            paneID: request.params.paneID,
            events: request.params.events
        )
        if sentWaiters.isEmpty { sent.append(recorded) } else { sentWaiters.removeFirst().resume(returning: recorded) }
    }

    func nextLine() async throws -> Data? {
        if !inbound.isEmpty { return inbound.removeFirst() }
        if isClosed { return nil }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { readWaiters[id] = $0 }
        } onCancel: {
            Task { await self.cancelRead(id) }
        }
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        for waiter in readWaiters.values { waiter.resume(returning: nil) }
        readWaiters.removeAll()
    }

    func nextSent() async -> RecordedRequest {
        if !sent.isEmpty { return sent.removeFirst() }
        return await withCheckedContinuation { sentWaiters.append($0) }
    }

    func push(_ line: String) {
        enqueue(Data(line.utf8))
    }

    func reply(to request: RecordedRequest, result: String) {
        push(#"{"id":"\#(request.id)","result":\#(result)}"#)
    }

    func finish() {
        isClosed = true
        enqueue(nil)
    }

    private func enqueue(_ line: Data?) {
        guard let entry = readWaiters.first else {
            inbound.append(line)
            return
        }
        readWaiters.removeValue(forKey: entry.key)
        entry.value.resume(returning: line)
    }

    private func cancelRead(_ id: UUID) {
        guard let waiter = readWaiters.removeValue(forKey: id) else { return }
        waiter.resume(throwing: CancellationError())
    }
}

private struct ImmediateSleeper: Sleeper {
    func sleep(for duration: Duration) async throws { try Task.checkCancellation() }
}

private actor ControlledSleeper: Sleeper {
    private var waits: [(UUID, CheckedContinuation<Void, any Error>)] = []
    private(set) var recordedDurations: [Duration] = []
    private(set) var cancelCount = 0
    var sleepCount: Int { recordedDurations.count }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                recordedDurations.append(duration)
                waits.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func releaseFirst() {
        guard !waits.isEmpty else { return }
        waits.removeFirst().1.resume()
    }

    private func cancel(_ id: UUID) {
        guard let index = waits.firstIndex(where: { $0.0 == id }) else { return }
        cancelCount += 1
        waits.remove(at: index).1.resume(throwing: CancellationError())
    }
}

private func pane(_ id: String) -> PaneInfo {
    PaneInfo(paneID: id, terminalID: "terminal", workspaceID: "workspace", tabID: "tab", focused: false, label: nil, agent: nil, title: nil, displayAgent: nil, agentStatus: .working, revision: 1)
}

private func paneJSON(_ id: String) -> String {
    #"{"pane_id":"\#(id)","terminal_id":"terminal","workspace_id":"workspace","tab_id":"tab","focused":false,"agent_status":"working","revision":1}"#
}

private func paneListResult(ids: [String]) -> String {
    #"{"type":"pane_list","panes":[\#(ids.map(paneJSON).joined(separator: ","))]}"#
}

private func paneFocusResult(id: String) -> String {
    #"{"type":"pane_info","pane":\#(paneJSON(id))}"#
}

private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async {
    while !(await condition()) { await Task.yield() }
}

private extension AsyncStream<HerdrClientEvent> {
    func next() async -> HerdrClientEvent? {
        var iterator = makeAsyncIterator()
        return await iterator.next()
    }
}
