import Foundation
import XCTest
@testable import HerdrMenubar

actor FakeHerdrConnectionFactory: HerdrConnectionFactory {
    private var connections: [FakeHerdrConnection] = []
    private var socketURLs: [URL] = []
    private var waiters: [Int: [CheckedContinuation<FakeHerdrConnection, Never>]] = [:]
    private let sendDelays: [Duration]

    init(sendDelays: [Duration] = []) { self.sendDelays = sendDelays }
    var connectionCount: Int { connections.count }
    var connectedSocketURLs: [URL] { socketURLs }

    func connect(to socketURL: URL) async throws -> any HerdrConnection {
        let index = connections.count
        let connection = FakeHerdrConnection(sendDelay: sendDelays.indices.contains(index) ? sendDelays[index] : .zero)
        socketURLs.append(socketURL)
        connections.append(connection)
        for waiter in waiters.removeValue(forKey: index) ?? [] { waiter.resume(returning: connection) }
        return connection
    }

    func connection(at index: Int) async -> FakeHerdrConnection {
        if connections.indices.contains(index) { return connections[index] }
        return await withCheckedContinuation { waiters[index, default: []].append($0) }
    }
}

struct RecordedRequest: Sendable {
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

enum FakeConnectionError: Error {
    case malformedRequest
}

actor FakeHerdrConnection: HerdrConnection {
    private var sent: [RecordedRequest] = []
    private var sentHistory: [RecordedRequest] = []
    private var sentWaiters: [CheckedContinuation<RecordedRequest, Never>] = []
    private var inbound: [Data?] = []
    private var readWaiters: [UUID: CheckedContinuation<Data?, any Error>] = [:]
    private(set) var isClosed = false
    private let sendDelay: Duration
    private let onSend: (@Sendable (RecordedRequest) async -> Void)?

    init(sendDelay: Duration, onSend: (@Sendable (RecordedRequest) async -> Void)? = nil) {
        self.sendDelay = sendDelay
        self.onSend = onSend
    }

    func sendLine(_ data: Data) async throws {
        if sendDelay > .zero { try await Task.sleep(for: sendDelay) }
        guard !isClosed else { throw TransportError.sendFailed("closed") }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String,
              let method = object["method"] as? String else {
            throw FakeConnectionError.malformedRequest
        }
        let request = RecordedRequest(id: id, method: method, data: data)
        sentHistory.append(request)
        if sentWaiters.isEmpty { sent.append(request) } else { sentWaiters.removeFirst().resume(returning: request) }
        await onSend?(request)
    }

    private var pendingReadError: (any Error)?

    func nextLine() async throws -> Data? {
        if let error = pendingReadError {
            pendingReadError = nil
            throw error
        }
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

    var firstRecordedRequest: RecordedRequest? { sentHistory.first }

    func nextSent() async -> RecordedRequest {
        if !sent.isEmpty { return sent.removeFirst() }
        return await withCheckedContinuation { sentWaiters.append($0) }
    }

    func push(_ line: String) { enqueue(Data(line.utf8)) }
    func reply(to request: RecordedRequest, result: String) { push(#"{"id":"\#(request.id)","result":\#(result)}"#) }
    func finish() { isClosed = true; enqueue(nil) }

    func fail(_ error: any Error) {
        guard let entry = readWaiters.first else {
            pendingReadError = error
            return
        }
        readWaiters.removeValue(forKey: entry.key)
        entry.value.resume(throwing: error)
    }

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

struct ImmediateSleeper: Sleeper {
    func sleep(for duration: Duration) async throws { try Task.checkCancellation() }
}

actor ControlledSleeper: Sleeper {
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

func completeMetadata(
    factory: FakeHerdrConnectionFactory,
    startIndex: Int,
    workspaces: String = #"{"type":"workspace_list","workspaces":[]}"#,
    tabs: String = #"{"type":"tab_list","tabs":[]}"#
) async {
    let firstConnection = await factory.connection(at: startIndex)
    let firstRequest = await firstConnection.nextSent()
    let secondConnection = await factory.connection(at: startIndex + 1)
    let secondRequest = await secondConnection.nextSent()
    assert(Set([firstRequest.method, secondRequest.method]) == ["workspace.list", "tab.list"])
    await replyToMetadata(
        connection: firstConnection,
        request: firstRequest,
        workspaces: workspaces,
        tabs: tabs
    )
    await replyToMetadata(
        connection: secondConnection,
        request: secondRequest,
        workspaces: workspaces,
        tabs: tabs
    )
}

func replyToMetadata(
    connection: FakeHerdrConnection,
    request: RecordedRequest,
    workspaces: String = #"{"type":"workspace_list","workspaces":[]}"#,
    tabs: String = #"{"type":"tab_list","tabs":[]}"#
) async {
    switch request.method {
    case "workspace.list": await connection.reply(to: request, result: workspaces)
    case "tab.list": await connection.reply(to: request, result: tabs)
    default: assertionFailure("Unexpected metadata request: \(request.method)")
    }
}

func clientSnapshot(_ panes: [PaneInfo]) -> PresentationSnapshot {
    PresentationSnapshot(panes: panes, workspaces: [], tabs: [])
}

func pane(_ id: String, status: AgentStatus = .working) -> PaneInfo {
    PaneInfo(paneID: id, terminalID: "terminal", workspaceID: "workspace", tabID: "tab", focused: false, label: nil, agent: nil, title: nil, displayAgent: nil, agentStatus: status, revision: 1)
}

func paneJSON(_ id: String, status: String = "working") -> String {
    #"{"pane_id":"\#(id)","terminal_id":"terminal","workspace_id":"workspace","tab_id":"tab","focused":false,"agent_status":"\#(status)","revision":1}"#
}

func paneListResult(ids: [String]) -> String {
    paneListResult(panes: ids.map { paneJSON($0) })
}

func paneListResult(panes: [String]) -> String {
    #"{"type":"pane_list","panes":[\#(panes.joined(separator: ","))]}"#
}

func paneFocusResult(id: String) -> String {
    #"{"type":"pane_info","pane":\#(paneJSON(id))}"#
}

func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async {
    while !(await condition()) { await Task.yield() }
}

extension AsyncStream<HerdrClientEvent> {
    func next() async -> HerdrClientEvent? {
        var iterator = makeAsyncIterator()
        return await iterator.next()
    }
}

// Protocol 16: each request has its own socket and only the first subscribe on
// an events socket succeeds. Responses close ordinary request sockets.
actor Protocol16HerdrServer: HerdrConnectionFactory {
    private var sockets: [FakeHerdrConnection] = []
    private var requestedSockets: Set<Int> = []
    private let replacementAcknowledgementDelay: Duration
    private var subscriptions: [Int: Set<String>] = [:]
    private var panes: [String: AgentStatus]
    private var agents: [String: String] = [:]
    private var pauseNextList = false
    private var pauseNextGet = false
    private var pauseAfterNextSubscribe = false
    private var heldLists: [(Int, RecordedRequest, String)] = []
    private var heldGets: [(Int, RecordedRequest, String)] = []
    private var holdWorkspaceList = false
    private var heldWorkspaceLists: [(Int, RecordedRequest, String)] = []
    private var workspaceLabel = "base"
    private var holdingFocus = false
    private var heldFocuses: [(Int, RecordedRequest)] = []
    private var driftOnReplacementSubscribe = false
    private(set) var subscribeAttempts = 0
    private(set) var requestMethods: [String] = []

    init(panes: [String: AgentStatus], replacementAcknowledgementDelay: Duration = .zero) {
        self.panes = panes
        self.replacementAcknowledgementDelay = replacementAcknowledgementDelay
    }

    func connect(to socketURL: URL) async throws -> any HerdrConnection {
        let index = sockets.count
        let socket = FakeHerdrConnection(sendDelay: .zero) { [weak self] request in
            await self?.respond(to: request, at: index)
        }
        sockets.append(socket)
        return socket
    }

    var heldListCount: Int { heldLists.count }
    var heldGetCount: Int { heldGets.count }
    var heldWorkspaceListCount: Int { heldWorkspaceLists.count }
    var heldFocusCount: Int { heldFocuses.count }
    var subscribedPaneIDs: Set<String> {
        guard let index = subscriptions.keys.max() else { return [] }
        return subscriptions[index] ?? []
    }

    func openEventsConnections() async -> Int {
        var count = 0
        for (index, _) in subscriptions where !(await sockets[index].isClosed) { count += 1 }
        return count
    }

    func driftMembershipOnReplacementSubscribe() { driftOnReplacementSubscribe = true }
    func holdNextList() { pauseNextList = true }
    func holdNextGet() { pauseNextGet = true }

    func releaseGets() async {
        let requests = heldGets
        heldGets.removeAll()
        for (index, request, result) in requests {
            await respondAndClose(to: request, on: sockets[index], result: result)
        }
    }

    func failHeldGetsAsMissing() async {
        let requests = heldGets
        heldGets.removeAll()
        for (index, request, _) in requests {
            await sockets[index].push(
                #"{"id":"\#(request.id)","error":{"code":"pane_not_found","message":"Missing pane"}}"#
            )
            await sockets[index].finish()
        }
    }

    func holdNextWorkspaceList() { holdWorkspaceList = true }
    func setWorkspaceLabel(_ label: String) { workspaceLabel = label }

    func releaseWorkspaceLists() async {
        let lists = heldWorkspaceLists
        heldWorkspaceLists.removeAll()
        for (index, request, result) in lists {
            await respondAndClose(to: request, on: sockets[index], result: result)
        }
    }

    func holdFocusRequests() { holdingFocus = true }

    func releaseFocusRequests() async {
        holdingFocus = false
        let requests = heldFocuses
        heldFocuses.removeAll()
        for (index, request) in requests {
            await respondAndClose(
                to: request, on: sockets[index], result: paneFocusResult(id: request.paneID ?? "A")
            )
        }
    }
    func holdListAfterNextSubscribe() { pauseAfterNextSubscribe = true }

    func releaseLists() async {
        let lists = heldLists
        heldLists.removeAll()
        for (index, request, result) in lists {
            await respondAndClose(to: request, on: sockets[index], result: result)
        }
    }

    func setPanes(_ updated: [String: AgentStatus], event: String = "pane_created") async {
        panes = updated
        await emit(event: event, data: #"{"type":"\#(event)"}"#)
    }

    func setAgent(_ id: String, to agent: String?) { agents[id] = agent }

    func detect(_ id: String, agent: String?) async {
        agents[id] = agent
        let value = agent.map { "\"\($0)\"" } ?? "null"
        await emit(event: "pane_agent_detected", data: #"{"pane_id":"\#(id)","agent":\#(value)}"#)
    }

    func status(_ status: AgentStatus, for id: String) async {
        panes[id] = status
        await emit(
            event: "pane.agent_status_changed",
            data: #"{"pane_id":"\#(id)","agent_status":"\#(status.rawValue)"}"#,
            paneID: id
        )
    }

    private func emit(event: String, data: String, paneID: String? = nil) async {
        for (index, ids) in subscriptions {
            guard paneID == nil || ids.contains(paneID!) else { continue }
            guard !(await sockets[index].isClosed) else { continue }
            await sockets[index].push(#"{"event":"\#(event)","data":\#(data)}"#)
        }
    }

    private func respond(to request: RecordedRequest, at index: Int) async {
        requestMethods.append(request.method)
        let socket = sockets[index]
        guard requestedSockets.insert(index).inserted else {
            if request.method == "events.subscribe" { subscribeAttempts += 1 }
            await socket.finish()
            return
        }
        switch request.method {
        case "events.subscribe":
            subscribeAttempts += 1
            guard subscriptions[index] == nil else {
                await socket.finish() // Herdr closes a connection on a second subscribe.
                return
            }
            let ids = Set(request.subscriptionPaneIDs)
            if subscribeAttempts > 1, replacementAcknowledgementDelay > .zero {
                try? await Task.sleep(for: replacementAcknowledgementDelay)
            }
            guard !(await socket.isClosed) else { return }
            subscriptions[index] = ids
            if driftOnReplacementSubscribe, subscribeAttempts > 1 {
                panes["drift\(subscribeAttempts)"] = .working
            }
            if pauseAfterNextSubscribe {
                pauseAfterNextSubscribe = false
                pauseNextList = true
            }
            await socket.reply(to: request, result: #"{"type":"subscription_started"}"#)
        case "pane.list":
            let result = paneListResult(panes: panes.keys.sorted().map(paneData))
            if pauseNextList {
                pauseNextList = false
                heldLists.append((index, request, result))
            } else {
                await respondAndClose(to: request, on: socket, result: result)
            }
        case "pane.get":
            guard let id = request.paneID, panes[id] != nil else {
                await socket.push(#"{"id":"\#(request.id)","error":{"code":"pane_not_found","message":"Missing pane"}}"#)
                await socket.finish()
                return
            }
            let result = #"{"type":"pane_info","pane":\#(paneData(id))}"#
            if pauseNextGet {
                pauseNextGet = false
                heldGets.append((index, request, result))
            } else {
                await respondAndClose(to: request, on: socket, result: result)
            }
        case "pane.focus":
            if holdingFocus {
                heldFocuses.append((index, request))
            } else {
                await respondAndClose(to: request, on: socket, result: paneFocusResult(id: request.paneID ?? "A"))
            }
        case "workspace.list":
            let result = #"""
            {"type":"workspace_list","workspaces":[{
              "workspace_id":"workspace","number":1,"label":"\#(workspaceLabel)",
              "focused":true,"pane_count":1,"tab_count":1,
              "active_tab_id":"tab","agent_status":"working"
            }]}
            """#
            if holdWorkspaceList {
                holdWorkspaceList = false
                heldWorkspaceLists.append((index, request, result))
            } else {
                await respondAndClose(to: request, on: socket, result: result)
            }
        case "tab.list":
            await respondAndClose(to: request, on: socket, result: #"{"type":"tab_list","tabs":[]}"#)
        default:
            await socket.finish()
        }
    }

    private func paneData(_ id: String) -> String {
        let pane = paneJSON(id, status: panes[id, default: .unknown].rawValue)
        guard let agent = agents[id] else { return pane }
        return pane.replacingOccurrences(of: #""revision":1"#, with: #""agent":"\#(agent)","revision":1"#)
    }

    private func respondAndClose(to request: RecordedRequest, on socket: FakeHerdrConnection, result: String) async {
        await socket.reply(to: request, result: result)
        await socket.finish()
    }
}

func eventuallyForProtocol16(
    within timeout: Duration = .seconds(3),
    _ condition: @escaping () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

actor ClientEventRecorder {
    private var events: [HerdrClientEvent] = []

    func append(_ event: HerdrClientEvent) { events.append(event) }

    var disconnectionCount: Int {
        events.filter { if case .disconnected = $0 { return true }; return false }.count
    }

    func latestPaneIDs() -> Set<String> {
        for event in events.reversed() {
            switch event {
            case .connected(let snapshot), .snapshot(let snapshot):
                return Set(snapshot.panes.map(\.paneID))
            case .disconnected: continue
            }
        }
        return []
    }

    func latestWorkspaceLabel() -> String? {
        for event in events.reversed() {
            switch event {
            case .connected(let snapshot), .snapshot(let snapshot):
                return snapshot.workspaces.first?.label
            case .disconnected: continue
            }
        }
        return nil
    }

    func agents(for paneID: String) -> [String?] {
        events.compactMap { event in
            let snapshot: PresentationSnapshot
            switch event {
            case .connected(let value), .snapshot(let value): snapshot = value
            case .disconnected: return nil
            }
            return snapshot.panes.first(where: { $0.paneID == paneID }).map { $0.agent }
        }
    }

    func statuses(for paneID: String) -> [AgentStatus] {
        events.compactMap { event in
            let snapshot: PresentationSnapshot
            switch event {
            case .connected(let value), .snapshot(let value): snapshot = value
            case .disconnected: return nil
            }
            return snapshot.panes.first(where: { $0.paneID == paneID })?.agentStatus
        }
    }
}

enum MetadataFailure: Equatable {
    case transport
    case timeout
    case connectionClosed
    case cancellation
    case decoding
    case idMismatch
    case malformed
}

func assertMetadataFailureRestartsBootstrap(
    method failedMethod: String,
    failure: MetadataFailure
) async throws {
    let factory = FakeHerdrConnectionFactory()
    let client = HerdrClient(
        socketURL: URL(fileURLWithPath: "/tmp/fake-herdr.sock"),
        connectionFactory: factory,
        backoff: .immediate,
        sleeper: ImmediateSleeper(),
        requestTimeout: .milliseconds(25)
    )
    let events = await client.events()
    await client.start()

    let initial = await factory.connection(at: 0)
    let initialRequest = await initial.nextSent()
    await initial.reply(to: initialRequest, result: paneListResult(ids: ["pane"]))
    let subscription = await factory.connection(at: 1)
    let subscribe = await subscription.nextSent()
    await subscription.reply(to: subscribe, result: #"{"type":"subscription_started"}"#)
    let authoritative = await factory.connection(at: 2)
    let paneRequest = await authoritative.nextSent()
    await authoritative.reply(to: paneRequest, result: paneListResult(ids: ["pane"]))

    let first = await factory.connection(at: 3)
    let firstRequest = await first.nextSent()
    let second = await factory.connection(at: 4)
    let secondRequest = await second.nextSent()
    for (connection, request) in [(first, firstRequest), (second, secondRequest)] {
        if request.method == failedMethod {
            switch failure {
            case .transport:
                await connection.fail(TransportError.receiveFailed("metadata socket failed"))
            case .timeout:
                break
            case .connectionClosed:
                await connection.finish()
            case .cancellation:
                await connection.fail(CancellationError())
            case .decoding:
                await connection.push("not json")
            case .idMismatch:
                await connection.push(#"{"id":"wrong-id","result":{"type":"workspace_list","workspaces":[]}}"#)
            case .malformed:
                await connection.push(#"{"id":"\#(request.id)"}"#)
            }
        } else {
            await replyToMetadata(connection: connection, request: request)
        }
    }

    guard case .disconnected = await events.next() else {
        await client.stop()
        return XCTFail("Expected \(failedMethod) \(failure) to invalidate live state")
    }
    let replacement = await completeBootstrap(
        factory: factory,
        startIndex: 5,
        discovered: ["fresh"],
        authoritative: ["fresh"]
    )
    let replacementSubscribe = await replacement.firstRecordedRequest
    XCTAssertEqual(
        replacementSubscribe?.subscriptionPaneIDs,
        ["fresh"],
        "metadata failure must install a usable replacement subscription"
    )
    let reconnected = await events.next()
    XCTAssertEqual(
        reconnected,
        .connected(clientSnapshot([pane("fresh")])),
        "metadata failure recovery must publish a fresh authoritative connected snapshot"
    )
    await client.stop()
}

func assertRawMetadataRenameTriggersRefresh(event: String) async throws {
    let factory = FakeHerdrConnectionFactory()
    let client = makeClient(factory: factory)
    let events = await client.events()
    await client.start()
    let subscription = await completeBootstrap(factory: factory, discovered: ["old"], authoritative: ["old"])
    _ = await events.next()

    await subscription.push(#"{"event":"\#(event)","data":{}}"#)
    let refresh = await factory.connection(at: 5)
    let request = await refresh.nextSent()
    XCTAssertEqual(request.method, "pane.list")
    await refresh.reply(to: request, result: paneListResult(ids: ["updated"]))
    await completeMetadata(factory: factory, startIndex: 6)
    let refreshedEvent = await events.next()
    XCTAssertEqual(refreshedEvent, .snapshot(clientSnapshot([pane("updated")])))
    await client.stop()
}

func makeClient(
    factory: FakeHerdrConnectionFactory,
    socketURL: URL = URL(fileURLWithPath: "/tmp/fake-herdr.sock"),
    debounce: Duration = .zero
) -> HerdrClient {
    HerdrClient(
        socketURL: socketURL,
        connectionFactory: factory,
        backoff: .immediate,
        sleeper: ImmediateSleeper(),
        subscriptionRebuildDebounce: debounce
    )
}

func completeBootstrap(
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
    await completeMetadata(factory: factory, startIndex: startIndex + 3)
    return subscription
}
