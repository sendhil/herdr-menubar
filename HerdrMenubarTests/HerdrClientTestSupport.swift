import Foundation
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

    init(sendDelay: Duration) { self.sendDelay = sendDelay }

    func sendLine(_ data: Data) async throws {
        if sendDelay > .zero { try await Task.sleep(for: sendDelay) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String,
              let method = object["method"] as? String else {
            throw FakeConnectionError.malformedRequest
        }
        let request = RecordedRequest(id: id, method: method, data: data)
        sentHistory.append(request)
        if sentWaiters.isEmpty { sent.append(request) } else { sentWaiters.removeFirst().resume(returning: request) }
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
