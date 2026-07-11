import Foundation
import OSLog

enum HerdrClientEvent: Equatable, Sendable {
    case connected([PaneInfo])
    case snapshot([PaneInfo])
    case disconnected(String)
}

enum HerdrClientError: Error, Equatable, Sendable {
    case timeout
    case connectionClosed
    case responseIDMismatch(expected: String, actual: String)
    case malformedResponse
    case unexpectedResponseType(expected: String, actual: String)
}

protocol Sleeper: Sendable {
    func sleep(for duration: Duration) async throws
}

struct TaskSleeper: Sleeper {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

struct BackoffPolicy: Sendable {
    let delays: [Duration]
    private let jitter: @Sendable () -> Double

    init(
        delays: [Duration] = [
            .milliseconds(500), .seconds(1), .seconds(2),
            .seconds(4), .seconds(8), .seconds(15)
        ],
        jitter: @escaping @Sendable () -> Double = { Double.random(in: -0.2 ... 0.2) }
    ) {
        precondition(!delays.isEmpty)
        self.delays = delays
        self.jitter = jitter
    }

    func delay(attempt: Int) -> Duration {
        let base = delays[min(max(0, attempt), delays.count - 1)]
        let adjustment = min(0.2, max(-0.2, jitter()))
        return base * (1 + adjustment)
    }

    static let immediate = BackoffPolicy(delays: [.zero], jitter: { 0 })
}

actor HerdrClient {
    private static let lifecycleEvents: Set<String> = [
        "pane.created", "pane.closed", "pane.moved", "pane.exited", "pane.agent_detected"
    ]
    private static let refreshEvents: Set<String> = [
        "pane.focused", "pane.agent_status_changed"
    ]
    private static let globalSubscriptionEvents = [
        "pane.created", "pane.closed", "pane.focused", "pane.moved", "pane.exited",
        "pane.agent_detected"
    ]

    private let connectionFactory: any HerdrConnectionFactory
    private let pathResolver: any SocketPathResolving
    private let backoff: BackoffPolicy
    private let sleeper: any Sleeper
    private let requestTimeout: Duration
    private let subscriptionRebuildDebounce: Duration
    private let logger = Logger(subsystem: "dev.herdr.menubar", category: "synchronization")

    private var subscriptionConnection: (any HerdrConnection)?
    private var subscriptionToken: UUID?
    private var reconnectTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshToken: UUID?
    private var refreshRequested = false
    private var rebuildTask: Task<Void, Never>?
    private var rebuildToken: UUID?
    private var eventContinuations: [UUID: AsyncStream<HerdrClientEvent>.Continuation] = [:]
    private var running = false
    private var connected = false
    private var disconnectedPublished = false
    private var lifecycleGeneration = UUID()

    init(
        connectionFactory: any HerdrConnectionFactory = NWHerdrConnectionFactory(),
        pathResolver: any SocketPathResolving = SocketPathResolver(),
        backoff: BackoffPolicy = BackoffPolicy(),
        sleeper: any Sleeper = TaskSleeper(),
        requestTimeout: Duration = .seconds(5),
        subscriptionRebuildDebounce: Duration = .milliseconds(100)
    ) {
        self.connectionFactory = connectionFactory
        self.pathResolver = pathResolver
        self.backoff = backoff
        self.sleeper = sleeper
        self.requestTimeout = requestTimeout
        self.subscriptionRebuildDebounce = subscriptionRebuildDebounce
    }

    func events() -> AsyncStream<HerdrClientEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<HerdrClientEvent>.makeStream()
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeEventContinuation(id) }
        }
        eventContinuations[id] = continuation
        return stream
    }

    func start() {
        guard !running else { return }
        running = true
        lifecycleGeneration = UUID()
        startReconnectLoop()
    }

    func stop() async {
        guard running || reconnectTask != nil || subscriptionConnection != nil else { return }
        running = false
        connected = false
        disconnectedPublished = false
        refreshRequested = false
        lifecycleGeneration = UUID()
        reconnectTask?.cancel()
        reconnectTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshToken = nil
        rebuildTask?.cancel()
        rebuildTask = nil
        rebuildToken = nil
        let connection = subscriptionConnection
        subscriptionConnection = nil
        subscriptionToken = nil
        await connection?.close()
    }

    func retryNow() async {
        guard running, !connected else { return }
        lifecycleGeneration = UUID()
        reconnectTask?.cancel()
        reconnectTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshToken = nil
        rebuildTask?.cancel()
        rebuildTask = nil
        rebuildToken = nil
        let connection = subscriptionConnection
        subscriptionConnection = nil
        subscriptionToken = nil
        await connection?.close()
        startReconnectLoop()
    }

    func refresh() {
        scheduleRefresh()
    }

    func focus(paneID: String) async throws -> PaneInfo {
        let generation = lifecycleGeneration
        do {
            let result: PaneFocusResult = try await request(
                method: "pane.focus",
                params: PaneTargetParams(paneID: paneID),
                as: PaneFocusResult.self
            )
            guard result.type == "pane_info" else {
                throw HerdrClientError.unexpectedResponseType(expected: "pane_info", actual: result.type)
            }
            return result.pane
        } catch {
            if generation == lifecycleGeneration, shouldInvalidate(for: error) {
                await invalidate(reason: description(for: error), generation: generation)
            }
            throw error
        }
    }

    private func startReconnectLoop() {
        guard running, reconnectTask == nil else { return }
        let generation = lifecycleGeneration
        reconnectTask = Task { [weak self] in
            await self?.runReconnectLoop(generation: generation)
        }
    }

    private func runReconnectLoop(generation: UUID) async {
        var attempt = 0
        defer {
            if lifecycleGeneration == generation {
                reconnectTask = nil
            }
        }

        while owns(generation), !Task.isCancelled {
            if attempt > 0 {
                do {
                    try await sleeper.sleep(for: backoff.delay(attempt: attempt - 1))
                } catch {
                    break
                }
            }

            do {
                try await bootstrap(generation: generation)
                attempt = 0
                try await readSubscriptionEvents(generation: generation)
                if owns(generation), !Task.isCancelled {
                    throw HerdrClientError.connectionClosed
                }
            } catch is CancellationError {
                break
            } catch {
                if owns(generation), !Task.isCancelled {
                    await invalidate(reason: description(for: error), generation: generation)
                    attempt += 1
                }
            }
        }
    }

    private func bootstrap(generation: UUID) async throws {
        var snapshot = try await paneList()
        var reconciliationAttempt = 0

        while true {
            try ensureOwnership(generation)
            let subscribedPaneIDs = Set(snapshot.map(\.paneID))
            let candidate = try await makeSubscription(paneIDs: Array(subscribedPaneIDs))
            do {
                try ensureOwnership(generation)
                snapshot = try await paneList()
                try ensureOwnership(generation)
                guard Set(snapshot.map(\.paneID)) == subscribedPaneIDs else {
                    await candidate.connection.close()
                    try await sleeper.sleep(for: backoff.delay(attempt: reconciliationAttempt))
                    reconciliationAttempt += 1
                    continue
                }
                let oldConnection = subscriptionConnection
                subscriptionConnection = candidate.connection
                subscriptionToken = candidate.token
                connected = true
                disconnectedPublished = false
                publish(.connected(snapshot))
                await oldConnection?.close()
                return
            } catch {
                await candidate.connection.close()
                throw error
            }
        }
    }

}

private extension HerdrClient {
    func makeSubscription(paneIDs: [String]) async throws -> (connection: any HerdrConnection, token: UUID) {
        let socketURL = pathResolver.resolve()
        return try await withTimeout { [connectionFactory] in
            let connection = try await connectionFactory.connect(to: socketURL)
            do {
                let requestID = UUID().uuidString
                let subscriptions = Self.globalSubscriptionEvents.map { Subscription(type: $0, paneID: nil) }
                    + Array(Set(paneIDs)).sorted().map { Subscription(type: "pane.agent_status_changed", paneID: $0) }
                let request = HerdrRequest(
                    id: requestID,
                    method: "events.subscribe",
                    params: SubscriptionParams(subscriptions: subscriptions)
                )
                try await connection.sendLine(JSONEncoder().encode(request))
                let acknowledgement: SubscriptionResult = try await Self.readResponse(
                    from: connection,
                    expectedID: requestID,
                    as: SubscriptionResult.self
                )
                guard acknowledgement.type == "subscription_started" else {
                    throw HerdrClientError.unexpectedResponseType(
                        expected: "subscription_started", actual: acknowledgement.type
                    )
                }
                return (connection, UUID())
            } catch {
                await connection.close()
                throw error
            }
        }
    }

    private func readSubscriptionEvents(generation: UUID) async throws {
        while owns(generation), !Task.isCancelled {
            guard let connection = subscriptionConnection, let token = subscriptionToken else {
                throw HerdrClientError.connectionClosed
            }
            do {
                while owns(generation), subscriptionToken == token, !Task.isCancelled {
                    guard let line = try await connection.nextLine() else {
                        throw HerdrClientError.connectionClosed
                    }
                    do {
                        let event = try JSONDecoder().decode(EventEnvelope.self, from: line)
                        if Self.lifecycleEvents.contains(event.event) {
                            scheduleSubscriptionRebuild(generation: generation)
                        } else if Self.refreshEvents.contains(event.event) {
                            scheduleRefresh()
                        } else {
                            logger.debug("Ignoring unknown Herdr event: \(event.event, privacy: .public)")
                        }
                    } catch {
                        logger.error("Ignoring malformed Herdr event message: \(error.localizedDescription, privacy: .public)")
                    }
                }
            } catch {
                if subscriptionToken == token { throw error }
            }
        }
        throw CancellationError()
    }

    private func scheduleSubscriptionRebuild(generation: UUID) {
        guard owns(generation), connected else { return }
        rebuildTask?.cancel()
        let token = UUID()
        rebuildToken = token
        rebuildTask = Task { [weak self, subscriptionRebuildDebounce] in
            do {
                try await Task.sleep(for: subscriptionRebuildDebounce)
                await self?.runSubscriptionRebuild(generation: generation, token: token)
            } catch {}
        }
    }

    private func runSubscriptionRebuild(generation: UUID, token: UUID) async {
        defer {
            if rebuildToken == token {
                rebuildTask = nil
                rebuildToken = nil
            }
        }
        do {
            var snapshot = try await paneList()
            var reconciliationAttempt = 0

            while true {
                try ensureOwnership(generation, rebuildToken: token)
                let subscribedPaneIDs = Set(snapshot.map(\.paneID))
                let candidate = try await makeSubscription(paneIDs: Array(subscribedPaneIDs))
                do {
                    try ensureOwnership(generation, rebuildToken: token)
                    snapshot = try await paneList()
                    try ensureOwnership(generation, rebuildToken: token)
                    guard Set(snapshot.map(\.paneID)) == subscribedPaneIDs else {
                        await candidate.connection.close()
                        try await sleeper.sleep(for: backoff.delay(attempt: reconciliationAttempt))
                        reconciliationAttempt += 1
                        continue
                    }
                    let oldConnection = subscriptionConnection
                    subscriptionConnection = candidate.connection
                    subscriptionToken = candidate.token
                    publish(.snapshot(snapshot))
                    await oldConnection?.close()
                    return
                } catch {
                    await candidate.connection.close()
                    throw error
                }
            }
        } catch is CancellationError {
            return
        } catch {
            if owns(generation), rebuildToken == token, shouldInvalidate(for: error) {
                await invalidate(reason: description(for: error), generation: generation)
            } else if owns(generation), rebuildToken == token {
                logger.error("Herdr subscription rebuild failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func scheduleRefresh() {
        guard running, connected else { return }
        if refreshTask != nil {
            refreshRequested = true
            return
        }
        let token = UUID()
        let generation = lifecycleGeneration
        refreshToken = token
        refreshTask = Task { [weak self] in
            await self?.runRefreshes(generation: generation, token: token)
        }
    }

    private func runRefreshes(generation: UUID, token: UUID) async {
        defer {
            if refreshToken == token {
                refreshTask = nil
                refreshToken = nil
                refreshRequested = false
            }
        }

        repeat {
            guard owns(generation), refreshToken == token, !Task.isCancelled else { return }
            refreshRequested = false
            do {
                let snapshot = try await paneList()
                guard owns(generation), connected, refreshToken == token, !Task.isCancelled else { return }
                publish(.snapshot(snapshot))
            } catch is CancellationError {
                return
            } catch {
                if owns(generation), refreshToken == token, shouldInvalidate(for: error) {
                    await invalidate(reason: description(for: error), generation: generation)
                } else if owns(generation), refreshToken == token {
                    logger.error("Herdr snapshot refresh failed: \(error.localizedDescription, privacy: .public)")
                }
                return
            }
        } while refreshRequested
    }

    private func paneList() async throws -> [PaneInfo] {
        let result: PaneListResult = try await request(
            method: "pane.list", params: EmptyParams(), as: PaneListResult.self
        )
        guard result.type == "pane_list" else {
            throw HerdrClientError.unexpectedResponseType(expected: "pane_list", actual: result.type)
        }
        return result.panes
    }

    private func request<Params, Result>(
        method: String,
        params: Params,
        as type: Result.Type
    ) async throws -> Result
    where Params: Encodable & Sendable, Result: Decodable & Sendable {
        let socketURL = pathResolver.resolve()
        return try await withTimeout { [connectionFactory] in
            let connection = try await connectionFactory.connect(to: socketURL)
            do {
                let requestID = UUID().uuidString
                let request = HerdrRequest(id: requestID, method: method, params: params)
                try await connection.sendLine(JSONEncoder().encode(request))
                let result = try await Self.readResponse(from: connection, expectedID: requestID, as: type)
                await connection.close()
                return result
            } catch {
                await connection.close()
                throw error
            }
        }
    }

    private static func readResponse<Result: Decodable & Sendable>(
        from connection: any HerdrConnection,
        expectedID: String,
        as type: Result.Type
    ) async throws -> Result {
        guard let line = try await connection.nextLine() else {
            throw HerdrClientError.connectionClosed
        }
        let response = try JSONDecoder().decode(HerdrResponse<Result>.self, from: line)
        guard response.id == expectedID else {
            throw HerdrClientError.responseIDMismatch(expected: expectedID, actual: response.id)
        }
        switch (response.result, response.error) {
        case (.some(let result), .none): return result
        case (.none, .some(let error)): throw error
        default: throw HerdrClientError.malformedResponse
        }
    }

    private func withTimeout<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let timeout = requestTimeout
        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw HerdrClientError.timeout
            }
            guard let result = try await group.next() else { throw HerdrClientError.timeout }
            group.cancelAll()
            return result
        }
    }

    private func invalidate(reason: String, generation: UUID) async {
        guard owns(generation) else { return }
        let wasConnected = connected
        connected = false
        refreshTask?.cancel()
        refreshTask = nil
        refreshToken = nil
        refreshRequested = false
        rebuildTask?.cancel()
        rebuildTask = nil
        rebuildToken = nil
        let connection = subscriptionConnection
        subscriptionConnection = nil
        subscriptionToken = nil
        await connection?.close()
        guard owns(generation) else { return }
        if wasConnected || !disconnectedPublished {
            disconnectedPublished = true
            publish(.disconnected(reason))
        }
    }

    private func owns(_ generation: UUID) -> Bool {
        running && lifecycleGeneration == generation
    }

    private func ensureOwnership(_ generation: UUID, rebuildToken expectedToken: UUID? = nil) throws {
        guard owns(generation), !Task.isCancelled else { throw CancellationError() }
        if let expectedToken, rebuildToken != expectedToken { throw CancellationError() }
    }

    private func shouldInvalidate(for error: any Error) -> Bool {
        !(error is HerdrAPIError) && !(error is CancellationError)
    }

    private func description(for error: any Error) -> String {
        switch error {
        case HerdrClientError.timeout: return "Herdr request timed out"
        case HerdrClientError.connectionClosed: return "Herdr disconnected"
        default: return error.localizedDescription
        }
    }

    private func publish(_ event: HerdrClientEvent) {
        for continuation in eventContinuations.values { continuation.yield(event) }
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }
}

private struct SubscriptionParams: Encodable, Sendable {
    let subscriptions: [Subscription]
}

private struct Subscription: Encodable, Sendable {
    let type: String
    let paneID: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case paneID = "pane_id"
    }
}

private struct SubscriptionResult: Decodable, Sendable {
    let type: String
}
