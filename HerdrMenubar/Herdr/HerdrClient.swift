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
    private static let relevantEvents: Set<String> = [
        "pane.created",
        "pane.closed",
        "pane.focused",
        "pane.moved",
        "pane.exited",
        "pane.agent_detected",
        "pane.agent_status_changed"
    ]

    private let connectionFactory: any HerdrConnectionFactory
    private let pathResolver: any SocketPathResolving
    private let backoff: BackoffPolicy
    private let sleeper: any Sleeper
    private let requestTimeout: Duration
    private let logger = Logger(subsystem: "dev.herdr.menubar", category: "synchronization")

    private var subscriptionConnection: (any HerdrConnection)?
    private var reconnectTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshRequested = false
    private var eventContinuations: [UUID: AsyncStream<HerdrClientEvent>.Continuation] = [:]
    private var running = false
    private var connected = false
    private var disconnectedPublished = false
    private var reconnectGeneration = UUID()

    init(
        connectionFactory: any HerdrConnectionFactory = NWHerdrConnectionFactory(),
        pathResolver: any SocketPathResolving = SocketPathResolver(),
        backoff: BackoffPolicy = BackoffPolicy(),
        sleeper: any Sleeper = TaskSleeper(),
        requestTimeout: Duration = .seconds(5)
    ) {
        self.connectionFactory = connectionFactory
        self.pathResolver = pathResolver
        self.backoff = backoff
        self.sleeper = sleeper
        self.requestTimeout = requestTimeout
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
        startReconnectLoop()
    }

    func stop() async {
        guard running || reconnectTask != nil || subscriptionConnection != nil else { return }
        running = false
        connected = false
        refreshRequested = false
        reconnectGeneration = UUID()
        reconnectTask?.cancel()
        reconnectTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        let connection = subscriptionConnection
        subscriptionConnection = nil
        await connection?.close()
    }

    func retryNow() async {
        guard running, !connected else { return }
        reconnectGeneration = UUID()
        reconnectTask?.cancel()
        reconnectTask = nil
        let connection = subscriptionConnection
        subscriptionConnection = nil
        await connection?.close()
        startReconnectLoop()
    }

    func refresh() {
        scheduleRefresh()
    }

    func focus(paneID: String) async throws -> PaneInfo {
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
            if shouldInvalidate(for: error) {
                await invalidate(reason: description(for: error))
            }
            throw error
        }
    }

    private func startReconnectLoop() {
        guard running, reconnectTask == nil else { return }
        let generation = UUID()
        reconnectGeneration = generation
        reconnectTask = Task { [weak self] in
            await self?.runReconnectLoop(generation: generation)
        }
    }

    private func runReconnectLoop(generation: UUID) async {
        var attempt = 0
        defer {
            if reconnectGeneration == generation {
                reconnectTask = nil
            }
        }

        while running, !Task.isCancelled {
            if attempt > 0 {
                do {
                    try await sleeper.sleep(for: backoff.delay(attempt: attempt - 1))
                } catch {
                    break
                }
            }

            do {
                try await bootstrap()
                attempt = 0
                try await readSubscriptionEvents()
                if running, !Task.isCancelled {
                    throw HerdrClientError.connectionClosed
                }
            } catch is CancellationError {
                break
            } catch {
                if running, !Task.isCancelled {
                    await invalidate(reason: description(for: error))
                    attempt += 1
                }
            }
        }
    }

    private func bootstrap() async throws {
        let socketURL = pathResolver.resolve()
        let connection = try await withTimeout { [connectionFactory] in
            try await connectionFactory.connect(to: socketURL)
        }
        subscriptionConnection = connection

        do {
            let requestID = UUID().uuidString
            let params = SubscriptionParams(events: Array(Self.relevantEvents).sorted())
            let request = HerdrRequest(id: requestID, method: "events.subscribe", params: params)
            try await withTimeout {
                try await connection.sendLine(JSONEncoder().encode(request))
                return ()
            }
            let acknowledgement: SubscriptionResult = try await readResponse(
                from: connection,
                expectedID: requestID,
                as: SubscriptionResult.self
            )
            guard acknowledgement.type == "subscription_started" else {
                throw HerdrClientError.unexpectedResponseType(
                    expected: "subscription_started",
                    actual: acknowledgement.type
                )
            }

            let snapshot = try await paneList()
            guard running, !Task.isCancelled else { throw CancellationError() }
            connected = true
            disconnectedPublished = false
            publish(.connected(snapshot))
        } catch {
            if subscriptionConnection != nil {
                subscriptionConnection = nil
            }
            await connection.close()
            throw error
        }
    }

    private func readSubscriptionEvents() async throws {
        guard let connection = subscriptionConnection else {
            throw HerdrClientError.connectionClosed
        }

        while running, !Task.isCancelled {
            guard let line = try await connection.nextLine() else {
                throw HerdrClientError.connectionClosed
            }
            do {
                let event = try JSONDecoder().decode(EventEnvelope.self, from: line)
                if Self.relevantEvents.contains(event.event) {
                    scheduleRefresh()
                } else {
                    logger.debug("Ignoring unknown Herdr event: \(event.event, privacy: .public)")
                }
            } catch {
                logger.error("Ignoring malformed Herdr event message: \(error.localizedDescription, privacy: .public)")
            }
        }
        throw CancellationError()
    }

    private func scheduleRefresh() {
        guard running, connected else { return }
        if refreshTask != nil {
            refreshRequested = true
            return
        }
        refreshTask = Task { [weak self] in
            await self?.runRefreshes()
        }
    }

    private func runRefreshes() async {
        defer {
            refreshTask = nil
            refreshRequested = false
        }

        repeat {
            refreshRequested = false
            do {
                let snapshot = try await paneList()
                guard running, connected, !Task.isCancelled else { return }
                publish(.snapshot(snapshot))
            } catch is CancellationError {
                return
            } catch {
                if shouldInvalidate(for: error) {
                    await invalidate(reason: description(for: error))
                } else {
                    logger.error("Herdr snapshot refresh failed: \(error.localizedDescription, privacy: .public)")
                }
                return
            }
        } while refreshRequested
    }

    private func paneList() async throws -> [PaneInfo] {
        let result: PaneListResult = try await request(
            method: "pane.list",
            params: EmptyParams(),
            as: PaneListResult.self
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
        let connection = try await withTimeout { [connectionFactory] in
            try await connectionFactory.connect(to: socketURL)
        }
        do {
            let requestID = UUID().uuidString
            let request = HerdrRequest(id: requestID, method: method, params: params)
            let encoded = try JSONEncoder().encode(request)
            try await withTimeout {
                try await connection.sendLine(encoded)
                return ()
            }
            let result = try await readResponse(from: connection, expectedID: requestID, as: type)
            await connection.close()
            return result
        } catch {
            await connection.close()
            throw error
        }
    }

    private func readResponse<Result: Decodable & Sendable>(
        from connection: any HerdrConnection,
        expectedID: String,
        as type: Result.Type
    ) async throws -> Result {
        let line = try await withTimeout {
            guard let line = try await connection.nextLine() else {
                throw HerdrClientError.connectionClosed
            }
            return line
        }
        let response = try JSONDecoder().decode(HerdrResponse<Result>.self, from: line)
        guard response.id == expectedID else {
            throw HerdrClientError.responseIDMismatch(expected: expectedID, actual: response.id)
        }
        switch (response.result, response.error) {
        case (.some(let result), .none):
            return result
        case (.none, .some(let error)):
            throw error
        default:
            throw HerdrClientError.malformedResponse
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
            guard let result = try await group.next() else {
                throw HerdrClientError.timeout
            }
            group.cancelAll()
            return result
        }
    }

    private func invalidate(reason: String) async {
        let wasConnected = connected
        connected = false
        refreshTask?.cancel()
        refreshTask = nil
        refreshRequested = false
        let connection = subscriptionConnection
        subscriptionConnection = nil
        await connection?.close()
        if wasConnected || (running && !disconnectedPublished) {
            disconnectedPublished = true
            publish(.disconnected(reason))
        }
    }

    private func shouldInvalidate(for error: any Error) -> Bool {
        !(error is HerdrAPIError) && !(error is CancellationError)
    }

    private func description(for error: any Error) -> String {
        switch error {
        case HerdrClientError.timeout:
            return "Herdr request timed out"
        case HerdrClientError.connectionClosed:
            return "Herdr disconnected"
        default:
            return error.localizedDescription
        }
    }

    private func publish(_ event: HerdrClientEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }
}

private struct SubscriptionParams: Encodable, Sendable {
    let events: [String]
}

private struct SubscriptionResult: Decodable, Sendable {
    let type: String
}
