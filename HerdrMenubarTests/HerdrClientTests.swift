import Foundation
import XCTest
@testable import HerdrMenubar

final class HerdrClientTests: XCTestCase {
    func testBootstrapUsesExactPublicSubscriptionSchemaAndPostSubscriptionSnapshot() async throws {
        let factory = FakeHerdrConnectionFactory()
        let client = makeClient(factory: factory)
        let events = await client.events()
        await client.start()

        let initial = await factory.connection(at: 0)
        let initialList = await initial.nextSent()
        XCTAssertEqual(initialList.method, "pane.list")
        await initial.reply(to: initialList, result: paneListResult(ids: ["p2", "p1", "p1"]))

        let subscription = await factory.connection(at: 1)
        let subscribe = await subscription.nextSent()
        XCTAssertEqual(subscribe.method, "events.subscribe")
        XCTAssertEqual(try subscribe.paramsObject(), [
            "subscriptions": [
                ["type": "pane.created"],
                ["type": "pane.closed"],
                ["type": "pane.focused"],
                ["type": "pane.moved"],
                ["type": "pane.exited"],
                ["type": "pane.agent_detected"],
                ["type": "pane.agent_status_changed", "pane_id": "p1"],
                ["type": "pane.agent_status_changed", "pane_id": "p2"]
            ]
        ] as NSDictionary)
        await subscription.reply(to: subscribe, result: #"{"type":"subscription_started"}"#)

        let authoritative = await factory.connection(at: 2)
        let authoritativeList = await authoritative.nextSent()
        XCTAssertEqual(authoritativeList.method, "pane.list")
        await authoritative.reply(to: authoritativeList, result: paneListResult(ids: ["authoritative"]))
        let connected = await events.next()
        XCTAssertEqual(connected, .connected([pane("authoritative")]))
        await client.stop()
    }

    func testMembershipBurstDebouncesAndKeepsOldSubscriptionUntilReplacementIsAuthoritative() async throws {
        let factory = FakeHerdrConnectionFactory()
        let client = makeClient(factory: factory, debounce: .milliseconds(20))
        let events = await client.events()
        await client.start()
        let oldSubscription = await completeBootstrap(factory: factory, discovered: ["old"], authoritative: ["old"])
        _ = await events.next()

        await oldSubscription.push(#"{"event":"pane.created","data":{}}"#)
        await oldSubscription.push(#"{"event":"pane.moved","data":{}}"#)
        await oldSubscription.push(#"{"event":"pane.closed","data":{}}"#)

        let discovery = await factory.connection(at: 3)
        let discoveryRequest = await discovery.nextSent()
        await discovery.reply(to: discoveryRequest, result: paneListResult(ids: ["new", "old"]))
        let replacement = await factory.connection(at: 4)
        let replacementSubscribe = await replacement.nextSent()
        XCTAssertEqual(replacementSubscribe.subscriptionPaneIDs, ["new", "old"])
        await replacement.reply(to: replacementSubscribe, result: #"{"type":"subscription_started"}"#)

        let postSubscription = await factory.connection(at: 5)
        let postRequest = await postSubscription.nextSent()
        let oldClosedBeforeAuthoritativeSnapshot = await oldSubscription.isClosed
        XCTAssertFalse(oldClosedBeforeAuthoritativeSnapshot)
        await postSubscription.reply(to: postRequest, result: paneListResult(ids: ["new", "old"]))
        let replacementSnapshot = await events.next()
        XCTAssertEqual(replacementSnapshot, .snapshot([pane("new"), pane("old")]))
        await waitUntil { await oldSubscription.isClosed }
        try await Task.sleep(for: .milliseconds(30))
        let rebuildConnectionCount = await factory.connectionCount
        XCTAssertEqual(rebuildConnectionCount, 6, "membership burst must produce one rebuild")
        await client.stop()
    }

    func testStatusEventRefreshesAndBurstCoalesces() async throws {
        let factory = FakeHerdrConnectionFactory()
        let client = makeClient(factory: factory)
        let events = await client.events()
        await client.start()
        let subscription = await completeBootstrap(factory: factory, discovered: ["old"], authoritative: ["old"])
        _ = await events.next()

        await subscription.push(#"{"event":"pane.agent_status_changed","data":{"pane_id":"old"}}"#)
        let firstConnection = await factory.connection(at: 3)
        let first = await firstConnection.nextSent()
        await subscription.push(#"{"event":"pane.focused","data":{}}"#)
        await subscription.push(#"{"event":"pane.agent_status_changed","data":{"pane_id":"old"}}"#)
        await firstConnection.reply(to: first, result: paneListResult(ids: ["one"]))
        let firstEvent = await events.next()
        XCTAssertEqual(firstEvent, .snapshot([pane("one")]))
        let secondConnection = await factory.connection(at: 4)
        let second = await secondConnection.nextSent()
        await secondConnection.reply(to: second, result: paneListResult(ids: ["two"]))
        let secondEvent = await events.next()
        XCTAssertEqual(secondEvent, .snapshot([pane("two")]))
        try await Task.sleep(for: .milliseconds(20))
        let coalescedConnectionCount = await factory.connectionCount
        XCTAssertEqual(coalescedConnectionCount, 5)
        await client.stop()
    }

    func testStopMakesCancelledStaleBootstrapUnableToInstallOrClearState() async throws {
        let factory = FakeHerdrConnectionFactory()
        let client = makeClient(factory: factory)
        await client.start()
        let stale = await factory.connection(at: 0)
        let staleRequest = await stale.nextSent()
        await client.stop()
        await stale.reply(to: staleRequest, result: paneListResult(ids: ["stale"]))
        try await Task.sleep(for: .milliseconds(20))
        let stoppedConnectionCount = await factory.connectionCount
        XCTAssertEqual(stoppedConnectionCount, 1)

        await client.start()
        let events = await client.events()
        _ = await completeBootstrap(factory: factory, startIndex: 1, discovered: ["new"], authoritative: ["new"])
        let newConnected = await events.next()
        XCTAssertEqual(newConnected, .connected([pane("new")]))
        await client.stop()
    }

    func testRetryGenerationRejectsLateCancelledBootstrapCompletion() async throws {
        let factory = FakeHerdrConnectionFactory()
        let client = makeClient(factory: factory)
        let events = await client.events()
        await client.start()
        let stale = await factory.connection(at: 0)
        let staleRequest = await stale.nextSent()

        await client.retryNow()
        let replacementInitial = await factory.connection(at: 1)
        let replacementRequest = await replacementInitial.nextSent()
        await stale.reply(to: staleRequest, result: paneListResult(ids: ["stale"]))
        await replacementInitial.reply(to: replacementRequest, result: paneListResult(ids: ["new"]))
        let replacementSubscription = await factory.connection(at: 2)
        let subscribe = await replacementSubscription.nextSent()
        await replacementSubscription.reply(to: subscribe, result: #"{"type":"subscription_started"}"#)
        let authoritative = await factory.connection(at: 3)
        let list = await authoritative.nextSent()
        await authoritative.reply(to: list, result: paneListResult(ids: ["new"]))
        let newConnected = await events.next()
        XCTAssertEqual(newConnected, .connected([pane("new")]))
        let retryConnectionCount = await factory.connectionCount
        XCTAssertEqual(retryConnectionCount, 4)
        await client.stop()
    }

    func testCancelledStaleRefreshCannotClearNewRefreshOwnership() async throws {
        let sleeper = ControlledSleeper()
        let factory = FakeHerdrConnectionFactory()
        let client = HerdrClient(
            connectionFactory: factory,
            pathResolver: FakePathResolver(),
            backoff: BackoffPolicy(delays: [.milliseconds(1)], jitter: { 0 }),
            sleeper: sleeper
        )
        let events = await client.events()
        await client.start()
        let oldSubscription = await completeBootstrap(factory: factory, discovered: ["old"], authoritative: ["old"])
        _ = await events.next()
        await oldSubscription.push(#"{"event":"pane.agent_status_changed","data":{"pane_id":"old"}}"#)
        let staleRefresh = await factory.connection(at: 3)
        let staleRequest = await staleRefresh.nextSent()

        await oldSubscription.finish()
        guard case .disconnected = await events.next() else { return XCTFail("Expected disconnect") }
        await sleeper.releaseFirst()
        let newSubscription = await completeBootstrap(factory: factory, startIndex: 4, discovered: ["new"], authoritative: ["new"])
        let newConnected = await events.next()
        XCTAssertEqual(newConnected, .connected([pane("new")]))
        await staleRefresh.reply(to: staleRequest, result: paneListResult(ids: ["stale"]))

        await newSubscription.push(#"{"event":"pane.agent_status_changed","data":{"pane_id":"new"}}"#)
        let newRefresh = await factory.connection(at: 7)
        let newRequest = await newRefresh.nextSent()
        await newRefresh.reply(to: newRequest, result: paneListResult(ids: ["fresh"]))
        let freshEvent = await events.next()
        XCTAssertEqual(freshEvent, .snapshot([pane("fresh")]))
        await client.stop()
    }

    func testTimeoutCoversConnectSendAndReceiveAsOneOrdinaryRequestDeadline() async throws {
        let factory = FakeHerdrConnectionFactory(sendDelays: [.milliseconds(35)])
        let client = HerdrClient(
            connectionFactory: factory,
            pathResolver: FakePathResolver(),
            backoff: BackoffPolicy(delays: [.seconds(15)], jitter: { 0 }),
            sleeper: ControlledSleeper(),
            requestTimeout: .milliseconds(60)
        )
        let events = await client.events()
        await client.start()
        let connection = await factory.connection(at: 0)
        let request = await connection.nextSent()
        try await Task.sleep(for: .milliseconds(35))
        await connection.reply(to: request, result: paneListResult(ids: []))
        guard case .disconnected(let reason) = await events.next() else { return XCTFail("Expected timeout") }
        XCTAssertEqual(reason, "Herdr request timed out")
        let timedOutConnectionClosed = await connection.isClosed
        XCTAssertTrue(timedOutConnectionClosed)
        await client.stop()
    }

    func testFocusCorrelatesResponseAndAPIErrorDoesNotDisconnect() async throws {
        let factory = FakeHerdrConnectionFactory()
        let client = makeClient(factory: factory)
        await client.start()
        _ = await completeBootstrap(factory: factory, discovered: [], authoritative: [])

        let focusTask = Task { try await client.focus(paneID: "focused") }
        let focusConnection = await factory.connection(at: 3)
        let focus = await focusConnection.nextSent()
        XCTAssertEqual(focus.paneID, "focused")
        await focusConnection.reply(to: focus, result: paneFocusResult(id: "focused"))
        let focusedPane = try await focusTask.value
        XCTAssertEqual(focusedPane, pane("focused"))

        let errorTask = Task { try await client.focus(paneID: "missing") }
        let errorConnection = await factory.connection(at: 4)
        let request = await errorConnection.nextSent()
        await errorConnection.push(#"{"id":"\#(request.id)","error":{"code":"not_found","message":"Missing pane"}}"#)
        do {
            _ = try await errorTask.value
            XCTFail("Expected API error")
        } catch let error as HerdrAPIError {
            XCTAssertEqual(error, HerdrAPIError(code: "not_found", message: "Missing pane"))
        }
        await client.stop()
    }

    func testMalformedAndUnknownEventsDoNotTerminateSubscription() async throws {
        let factory = FakeHerdrConnectionFactory()
        let client = makeClient(factory: factory)
        let events = await client.events()
        await client.start()
        let subscription = await completeBootstrap(factory: factory, discovered: [], authoritative: [])
        _ = await events.next()
        await subscription.push("not json")
        await subscription.push(#"{"event":"future.event","data":{}}"#)
        await subscription.push(#"{"event":"pane.focused","data":{}}"#)
        let refresh = await factory.connection(at: 3)
        let request = await refresh.nextSent()
        await refresh.reply(to: request, result: paneListResult(ids: ["live"]))
        let liveEvent = await events.next()
        XCTAssertEqual(liveEvent, .snapshot([pane("live")]))
        await client.stop()
    }

    func testBackoffIsBoundedAndClampsInjectedJitter() {
        XCTAssertEqual(BackoffPolicy(delays: [.seconds(15)], jitter: { 1 }).delay(attempt: 100), .seconds(18))
        XCTAssertEqual(BackoffPolicy(delays: [.seconds(15)], jitter: { -1 }).delay(attempt: 100), .seconds(12))
    }

    private func makeClient(factory: FakeHerdrConnectionFactory, debounce: Duration = .zero) -> HerdrClient {
        HerdrClient(
            connectionFactory: factory,
            pathResolver: FakePathResolver(),
            backoff: .immediate,
            sleeper: ImmediateSleeper(),
            subscriptionRebuildDebounce: debounce
        )
    }

    private func completeBootstrap(
        factory: FakeHerdrConnectionFactory,
        startIndex: Int = 0,
        discovered: [String],
        authoritative: [String]
    ) async -> FakeHerdrConnection {
        let initial = await factory.connection(at: startIndex)
        let initialRequest = await initial.nextSent()
        await initial.reply(to: initialRequest, result: paneListResult(ids: discovered))
        let subscription = await factory.connection(at: startIndex + 1)
        let subscribe = await subscription.nextSent()
        await subscription.reply(to: subscribe, result: #"{"type":"subscription_started"}"#)
        let post = await factory.connection(at: startIndex + 2)
        let postRequest = await post.nextSent()
        await post.reply(to: postRequest, result: paneListResult(ids: authoritative))
        return subscription
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
    private let sendDelays: [Duration]

    init(sendDelays: [Duration] = []) { self.sendDelays = sendDelays }
    var connectionCount: Int { connections.count }

    func connect(to socketURL: URL) async throws -> any HerdrConnection {
        let index = connections.count
        let connection = FakeHerdrConnection(sendDelay: sendDelays.indices.contains(index) ? sendDelays[index] : .zero)
        connections.append(connection)
        for waiter in waiters.removeValue(forKey: index) ?? [] { waiter.resume(returning: connection) }
        return connection
    }

    func connection(at index: Int) async -> FakeHerdrConnection {
        if connections.indices.contains(index) { return connections[index] }
        return await withCheckedContinuation { waiters[index, default: []].append($0) }
    }
}

private struct RecordedRequest: Sendable {
    let id: String
    let method: String
    let data: Data

    var paneID: String? {
        (try? paramsObject()["pane_id"] as? String) ?? nil
    }

    var subscriptionPaneIDs: [String] {
        guard let subscriptions = try? paramsObject()["subscriptions"] as? [[String: String]] else { return [] }
        return subscriptions.compactMap { $0["pane_id"] }.sorted()
    }

    func paramsObject() throws -> NSDictionary {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let params = object["params"] as? NSDictionary else {
            throw FakeConnectionError.malformedRequest
        }
        return params
    }
}

private enum FakeConnectionError: Error {
    case malformedRequest
}

private actor FakeHerdrConnection: HerdrConnection {
    private var sent: [RecordedRequest] = []
    private var sentWaiters: [CheckedContinuation<RecordedRequest, Never>] = []
    private var inbound: [Data?] = []
    private var readWaiters: [UUID: CheckedContinuation<Data?, any Error>] = [:]
    private(set) var isClosed = false
    private let sendDelay: Duration

    init(sendDelay: Duration) { self.sendDelay = sendDelay }

    func sendLine(_ data: Data) async throws {
        if sendDelay > .zero { try await Task.sleep(for: sendDelay) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String,
              let method = object["method"] as? String else {
            throw FakeConnectionError.malformedRequest
        }
        let request = RecordedRequest(id: id, method: method, data: data)
        if sentWaiters.isEmpty { sent.append(request) } else { sentWaiters.removeFirst().resume(returning: request) }
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

    func push(_ line: String) { enqueue(Data(line.utf8)) }
    func reply(to request: RecordedRequest, result: String) { push(#"{"id":"\#(request.id)","result":\#(result)}"#) }
    func finish() { isClosed = true; enqueue(nil) }

    private func enqueue(_ line: Data?) {
        guard let entry = readWaiters.first else { inbound.append(line); return }
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

    func sleep(for duration: Duration) async throws {
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
