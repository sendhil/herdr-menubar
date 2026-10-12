import Foundation
import OSLog

enum HerdrClientEvent: Equatable, Sendable {
    case connected(PresentationSnapshot)
    case snapshot(PresentationSnapshot)
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
        "pane_created", "pane_closed", "pane_moved", "pane_exited"
    ]
    private static let refreshEvents: Set<String> = [
        "pane_focused", "workspace_renamed", "tab_renamed"
    ]
    private static let globalSubscriptionEvents = [
        "pane.created", "pane.closed", "pane.focused", "pane.moved", "pane.exited",
        "pane.agent_detected", "workspace.renamed", "tab.renamed"
    ]

    private let socketURL: URL
    private let connectionFactory: any HerdrConnectionFactory
    private let backoff: BackoffPolicy
    private let sleeper: any Sleeper
    private let requestSleeper: any Sleeper
    private let requestTimeout: Duration
    private let subscriptionRebuildDebounce: Duration
    private let requestLimiter = RequestConnectionLimiter(limit: 4)

    private var presentation: PresentationSnapshot?
    private var subscriptionPaneIDs: Set<String> = []
    private var liveStatuses: [String: AgentStatus] = [:]
    private var subscriptionConnection: (any HerdrConnection)?
    private var subscriptionToken: UUID?
    private var reconnectTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshToken: UUID?
    private var refreshRequested = false
    private var rebuildTask: Task<Void, Never>?
    private var rebuildToken: UUID?
    private var rebuildInFlight = false
    private var rebuildDirty = false
    private var metadataTask: Task<Void, Never>?
    private var metadataToken: UUID?
    private var metadataInFlight = false
    private var metadataDirty = false
    private var detectionTask: Task<Void, Never>?
    private var detectionToken: UUID?
    private var detectionPaneIDs: Set<String> = []
    private var presentationGeneration: UInt64 = 0
    private var eventContinuations: [UUID: AsyncStream<HerdrClientEvent>.Continuation] = [:]
    private var running = false
    private var connected = false
    private var disconnectedPublished = false
    private var lifecycleGeneration = UUID()

    init(
        socketURL: URL,
        connectionFactory: any HerdrConnectionFactory = NWHerdrConnectionFactory(),
        backoff: BackoffPolicy = BackoffPolicy(),
        sleeper: any Sleeper = TaskSleeper(),
        requestSleeper: any Sleeper = TaskSleeper(),
        requestTimeout: Duration = .seconds(5),
        subscriptionRebuildDebounce: Duration = .milliseconds(100)
    ) {
        self.socketURL = socketURL
        self.connectionFactory = connectionFactory
        self.backoff = backoff
        self.sleeper = sleeper
        self.requestSleeper = requestSleeper
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
        rebuildInFlight = false
        rebuildDirty = false
        metadataTask?.cancel()
        metadataTask = nil
        metadataToken = nil
        metadataInFlight = false
        metadataDirty = false
        detectionTask?.cancel()
        detectionTask = nil
        detectionToken = nil
        detectionPaneIDs.removeAll()
        presentation = nil
        subscriptionPaneIDs.removeAll()
        liveStatuses.removeAll()
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
        rebuildInFlight = false
        rebuildDirty = false
        metadataTask?.cancel()
        metadataTask = nil
        metadataToken = nil
        metadataInFlight = false
        metadataDirty = false
        detectionTask?.cancel()
        detectionTask = nil
        detectionToken = nil
        detectionPaneIDs.removeAll()
        presentation = nil
        subscriptionPaneIDs.removeAll()
        liveStatuses.removeAll()
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

    func setClientWindowTitle(_ title: String) async throws -> ClientWindowTitleResult {
        try await clientWindowTitleRequest(
            method: "client.window_title.set",
            params: ClientWindowTitleSetParams(title: title)
        )
    }

    func clearClientWindowTitle() async throws -> ClientWindowTitleResult {
        try await clearClientWindowTitle(timeout: requestTimeout)
    }

    func clearClientWindowTitle(timeout: Duration) async throws -> ClientWindowTitleResult {
        try await clientWindowTitleRequest(
            method: "client.window_title.clear",
            params: EmptyParams(),
            timeout: timeout
        )
    }

    private func clientWindowTitleRequest<Params: Encodable & Sendable>(
        method: String,
        params: Params,
        timeout: Duration? = nil
    ) async throws -> ClientWindowTitleResult {
        let generation = lifecycleGeneration
        do {
            let result: ClientWindowTitleResult = try await request(
                method: method,
                params: params,
                as: ClientWindowTitleResult.self,
                timeout: timeout
            )
            guard result.type == "client_window_title" else {
                throw HerdrClientError.unexpectedResponseType(
                    expected: "client_window_title",
                    actual: result.type
                )
            }
            return result
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
                guard owns(generation), !Task.isCancelled else { break }
                await invalidate(reason: "Herdr request was cancelled", generation: generation)
                attempt += 1
            } catch {
                if owns(generation), !Task.isCancelled {
                    await invalidate(reason: description(for: error), generation: generation)
                    attempt += 1
                }
            }
        }
    }

    private func bootstrap(generation: UUID) async throws {
        var panes = try await paneList()
        var needsAnotherPass = false

        for attempt in 0 ..< 3 {
            try ensureOwnership(generation)
            let ids = Set(panes.map(\.paneID))
            let candidate = try await makeSubscription(paneIDs: Array(ids))
            guard owns(generation), !Task.isCancelled else {
                await candidate.connection.close()
                throw CancellationError()
            }
            await installSubscription(candidate, paneIDs: ids)
            try ensureOwnership(generation)
            panes = try await paneList()
            try ensureOwnership(generation)
            needsAnotherPass = Set(panes.map(\.paneID)) != ids
            if !needsAnotherPass { break }
            if attempt < 2 { try await sleeper.sleep(for: backoff.delay(attempt: attempt)) }
        }

        let snapshot = try await presentationSnapshot(panes: panes)
        try ensureOwnership(generation)
        presentation = snapshot
        connected = true
        disconnectedPublished = false
        AppLog.synchronization.info("Connected to Herdr")
        publish(.connected(snapshot))
        if needsAnotherPass { scheduleSubscriptionRebuild(generation: generation) }
    }

}

private extension HerdrClient {
    func makeSubscription(paneIDs: [String]) async throws -> (connection: any HerdrConnection, token: UUID) {
        return try await withTimeout { [connectionFactory, socketURL] in
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

    private func installSubscription(
        _ candidate: (connection: any HerdrConnection, token: UUID), paneIDs: Set<String>
    ) async {
        let oldConnection = subscriptionConnection
        subscriptionConnection = candidate.connection
        subscriptionToken = candidate.token
        subscriptionPaneIDs = paneIDs
        liveStatuses.removeAll()
        await oldConnection?.close()
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
                    guard subscriptionToken == token else { break } // never process an old socket after a swap
                    do {
                        let event = try JSONDecoder().decode(EventEnvelope.self, from: line)
                        let eventName = event.event.replacingOccurrences(of: ".", with: "_")
                        if Self.lifecycleEvents.contains(eventName) {
                            scheduleSubscriptionRebuild(generation: generation)
                        } else if eventName == "pane_agent_detected" {
                            if let paneID = event.data.paneID { scheduleDetectionRefresh(paneID: paneID) }
                        } else if eventName == "pane_agent_status_changed" {
                            applyStatusEvent(event.data)
                        } else if Self.refreshEvents.contains(eventName) {
                            scheduleRefresh()
                        } else {
                            AppLog.synchronization.debug("Ignoring unknown Herdr event: \(event.event, privacy: .private)")
                        }
                    } catch {
                        AppLog.synchronization.error("Ignoring malformed Herdr event message: \(String(describing: type(of: error)), privacy: .public)")
                    }
                }
            } catch {
                if subscriptionToken == token { throw error }
            }
        }
        throw CancellationError()
    }

    private func publishSnapshot(_ snapshot: PresentationSnapshot) {
        guard snapshot != presentation else { return }
        presentation = snapshot
        publish(.snapshot(snapshot))
    }

    private func mergingLiveStatuses(into snapshot: PresentationSnapshot) -> PresentationSnapshot {
        var panes = snapshot.panes
        for index in panes.indices {
            if let status = liveStatuses[panes[index].paneID] {
                panes[index].agentStatus = status
            }
        }
        return PresentationSnapshot(panes: panes, workspaces: snapshot.workspaces, tabs: snapshot.tabs)
    }

    private func applyStatusEvent(_ data: EventData) {
        guard let paneID = data.paneID, let status = data.agentStatus else {
            scheduleRefresh() // tolerate incomplete/older events without losing the subscription
            return
        }
        guard subscriptionPaneIDs.contains(paneID) else { return }
        liveStatuses[paneID] = status
        guard var snapshot = presentation,
              let index = snapshot.panes.firstIndex(where: { $0.paneID == paneID }) else { return }
        guard snapshot.panes[index].agentStatus != status else { return }
        var panes = snapshot.panes
        panes[index].agentStatus = status
        snapshot = PresentationSnapshot(panes: panes, workspaces: snapshot.workspaces, tabs: snapshot.tabs)
        publishSnapshot(snapshot)
        scheduleMetadataRefresh()
    }

    private func scheduleDetectionRefresh(paneID: String) {
        guard running, connected else { return }
        detectionPaneIDs.insert(paneID)
        guard detectionTask == nil else { return }
        let token = UUID()
        let generation = lifecycleGeneration
        detectionToken = token
        detectionTask = Task { [weak self] in
            await self?.runDetectionRefreshes(generation: generation, token: token)
        }
    }

    private func runDetectionRefreshes(generation: UUID, token: UUID) async {
        defer {
            if detectionToken == token {
                detectionTask = nil
                detectionToken = nil
            }
        }
        while owns(generation), connected, detectionToken == token, !detectionPaneIDs.isEmpty {
            let ids = detectionPaneIDs
            detectionPaneIDs.removeAll()
            let subscribedToken = subscriptionToken
            for paneID in ids {
                do {
                    let result: PaneFocusResult = try await request(
                        method: "pane.get", params: PaneTargetParams(paneID: paneID), as: PaneFocusResult.self
                    )
                    guard result.type == "pane_info" else {
                        throw HerdrClientError.unexpectedResponseType(expected: "pane_info", actual: result.type)
                    }
                    guard owns(generation), connected, detectionToken == token, !Task.isCancelled else { return }
                    guard subscriptionToken == subscribedToken,
                          let current = presentation,
                          let index = current.panes.firstIndex(where: { $0.paneID == paneID }) else { continue }
                    var panes = current.panes
                    panes[index].agent = result.pane.agent
                    panes[index].displayAgent = result.pane.displayAgent
                    publishSnapshot(PresentationSnapshot(
                        panes: panes, workspaces: current.workspaces, tabs: current.tabs
                    ))
                } catch let error as HerdrAPIError
                    where error.code == "pane_not_found" || error.code == "not_found" {
                    continue // the pane closed while its detection refresh was in flight
                } catch {
                    if owns(generation), detectionToken == token, shouldInvalidate(for: error) {
                        await invalidate(reason: description(for: error), generation: generation)
                    }
                    return
                }
            }
        }
    }

    private func scheduleMetadataRefresh() {
        guard running, connected else { return }
        if metadataTask != nil {
            if metadataInFlight { metadataDirty = true }
            return
        }
        let token = UUID()
        let generation = lifecycleGeneration
        metadataToken = token
        metadataTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                await self?.runMetadataRefresh(generation: generation, token: token)
            } catch {}
        }
    }

    private func runMetadataRefresh(generation: UUID, token: UUID) async {
        metadataInFlight = true
        defer {
            if metadataToken == token {
                let dirty = metadataDirty
                metadataTask = nil
                metadataToken = nil
                metadataInFlight = false
                metadataDirty = false
                if dirty, owns(generation), connected {
                    if rebuildToken == nil { scheduleMetadataRefresh() }
                    else { metadataDirty = true }
                }
            }
        }
        do {
            let subscribedToken = subscriptionToken
            let snapshotGeneration = presentationGeneration
            async let workspaces = workspaceListWithFallback()
            async let tabs = tabListWithFallback()
            let updatedWorkspaces = try await workspaces
            let updatedTabs = try await tabs
            guard owns(generation), connected, metadataToken == token,
                  subscriptionToken == subscribedToken,
                  presentationGeneration == snapshotGeneration,
                  !Task.isCancelled, let current = presentation else { return }
            guard rebuildToken == nil else {
                metadataDirty = true
                return
            }
            publishSnapshot(PresentationSnapshot(
                panes: current.panes, workspaces: updatedWorkspaces, tabs: updatedTabs
            ))
        } catch {
            if owns(generation), metadataToken == token, shouldInvalidate(for: error) {
                await invalidate(reason: description(for: error), generation: generation)
            }
        }
    }

    private func scheduleSubscriptionRebuild(generation: UUID, delay: Duration? = nil) {
        guard owns(generation), connected else { return }
        if rebuildTask != nil {
            if rebuildInFlight { rebuildDirty = true }
            return
        }
        let token = UUID()
        rebuildToken = token
        presentationGeneration &+= 1 // a full refresh started before this rebuild is stale
        let expected = presentationGeneration
        rebuildTask = Task { [weak self, subscriptionRebuildDebounce] in
            do {
                try await Task.sleep(for: delay ?? subscriptionRebuildDebounce)
                await self?.runSubscriptionRebuild(
                    generation: generation, token: token, presentationGeneration: expected
                )
            } catch {}
        }
    }

    private func runSubscriptionRebuild(
        generation: UUID,
        token: UUID,
        presentationGeneration expectedPresentationGeneration: UInt64
    ) async {
        rebuildInFlight = true
        var retryDelay: Duration?
        defer {
            if rebuildToken == token {
                let dirty = rebuildDirty
                rebuildTask = nil
                rebuildToken = nil
                rebuildInFlight = false
                rebuildDirty = false
                if owns(generation), connected {
                    if dirty { scheduleSubscriptionRebuild(generation: generation, delay: retryDelay ?? .zero) }
                    else if refreshRequested { scheduleRefresh() }
                    if metadataDirty, metadataTask == nil {
                        metadataDirty = false
                        scheduleMetadataRefresh()
                    }
                }
            }
        }
        do {
            var panes = try await paneList()
            for attempt in 0 ..< 3 {
                try ensureOwnership(
                    generation, rebuildToken: token,
                    presentationGeneration: expectedPresentationGeneration
                )
                let ids = Set(panes.map(\.paneID))
                if ids == subscriptionPaneIDs {
                    let snapshot = try await presentationSnapshot(panes: panes)
                    try ensureOwnership(generation, rebuildToken: token)
                    publishSnapshot(mergingLiveStatuses(into: snapshot))
                    presentationGeneration &+= 1
                    return
                }
                let candidate = try await makeSubscription(paneIDs: Array(ids))
                guard owns(generation), rebuildToken == token, !Task.isCancelled else {
                    await candidate.connection.close()
                    throw CancellationError()
                }
                await installSubscription(candidate, paneIDs: ids)
                try ensureOwnership(generation, rebuildToken: token)
                panes = try await paneList() // events on the new socket can be read while this is in flight
                let snapshot = try await presentationSnapshot(panes: panes)
                try ensureOwnership(generation, rebuildToken: token)
                publishSnapshot(mergingLiveStatuses(into: snapshot))
                if Set(panes.map(\.paneID)) == ids {
                    presentationGeneration &+= 1
                    return
                }
                if attempt == 2 {
                    presentationGeneration &+= 1
                    rebuildDirty = true
                    retryDelay = max(.milliseconds(500), backoff.delay(attempt: attempt))
                    return // keep the current events connection; try again later
                }
                try await sleeper.sleep(for: backoff.delay(attempt: attempt))
            }
        } catch is CancellationError {
            if owns(generation), rebuildToken == token, !Task.isCancelled {
                await invalidate(reason: "Herdr request was cancelled", generation: generation)
            }
        } catch {
            if owns(generation), rebuildToken == token {
                await invalidate(reason: description(for: error), generation: generation)
            }
        }
    }

    private func scheduleRefresh() {
        guard running, connected else { return }
        if rebuildToken != nil || refreshTask != nil {
            refreshRequested = true
            return
        }
        let token = UUID()
        let generation = lifecycleGeneration
        let refreshPresentationGeneration = presentationGeneration
        refreshToken = token
        refreshTask = Task { [weak self] in
            await self?.runRefreshes(
                generation: generation,
                token: token,
                presentationGeneration: refreshPresentationGeneration
            )
        }
    }

    private func runRefreshes(
        generation: UUID,
        token: UUID,
        presentationGeneration expectedPresentationGeneration: UInt64
    ) async {
        defer {
            if refreshToken == token {
                let shouldRefresh = refreshRequested && owns(generation) && connected
                refreshTask = nil
                refreshToken = nil
                refreshRequested = false
                if shouldRefresh { scheduleRefresh() }
            }
        }

        repeat {
            guard owns(generation),
                  refreshToken == token,
                  presentationGeneration == expectedPresentationGeneration,
                  !Task.isCancelled else { return }
            refreshRequested = false
            do {
                let panes = try await paneList()
                let snapshot = try await presentationSnapshot(panes: panes)
                guard owns(generation),
                      connected,
                      refreshToken == token,
                      rebuildToken == nil,
                      presentationGeneration == expectedPresentationGeneration,
                      !Task.isCancelled else { return }
                publishSnapshot(mergingLiveStatuses(into: snapshot))
            } catch is CancellationError {
                let isAuthoritativeRefresh = owns(generation)
                    && refreshToken == token
                    && rebuildToken == nil
                    && presentationGeneration == expectedPresentationGeneration
                    && !Task.isCancelled
                if isAuthoritativeRefresh {
                    await invalidate(reason: "Herdr request was cancelled", generation: generation)
                }
                return
            } catch {
                let isAuthoritativeRefresh = owns(generation)
                    && refreshToken == token
                    && rebuildToken == nil
                    && presentationGeneration == expectedPresentationGeneration
                if isAuthoritativeRefresh, shouldInvalidate(for: error) {
                    await invalidate(reason: description(for: error), generation: generation)
                } else if isAuthoritativeRefresh {
                    AppLog.synchronization.error("Herdr snapshot refresh failed: \(error.localizedDescription, privacy: .private)")
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

    private func presentationSnapshot(panes: [PaneInfo]) async throws -> PresentationSnapshot {
        async let workspaces = workspaceListWithFallback()
        async let tabs = tabListWithFallback()
        return try await PresentationSnapshot(panes: panes, workspaces: workspaces, tabs: tabs)
    }

    private func workspaceListWithFallback() async throws -> [WorkspaceInfo] {
        do {
            let result: WorkspaceListResult = try await request(
                method: "workspace.list", params: EmptyParams(), as: WorkspaceListResult.self
            )
            guard result.type == "workspace_list" else {
                throw HerdrClientError.unexpectedResponseType(expected: "workspace_list", actual: result.type)
            }
            return result.workspaces
        } catch {
            guard metadataFailureAllowsFallback(error) else { throw error }
            AppLog.synchronization.error("Herdr workspace metadata unavailable; using pane fallbacks")
            return []
        }
    }

    private func tabListWithFallback() async throws -> [TabInfo] {
        do {
            let result: TabListResult = try await request(
                method: "tab.list", params: TabListParams(), as: TabListResult.self
            )
            guard result.type == "tab_list" else {
                throw HerdrClientError.unexpectedResponseType(expected: "tab_list", actual: result.type)
            }
            return result.tabs
        } catch {
            guard metadataFailureAllowsFallback(error) else { throw error }
            AppLog.synchronization.error("Herdr tab metadata unavailable; using pane fallbacks")
            return []
        }
    }

    private func metadataFailureAllowsFallback(_ error: any Error) -> Bool {
        guard let apiError = error as? HerdrAPIError else { return false }
        return apiError.code == "unavailable" || apiError.code == "metadata_unavailable"
    }

    private func request<Params, Result>(
        method: String,
        params: Params,
        as type: Result.Type,
        timeout: Duration? = nil
    ) async throws -> Result
    where Params: Encodable & Sendable, Result: Decodable & Sendable {
        return try await withTimeout(timeout: timeout) { [connectionFactory, socketURL, requestLimiter] in
            try await requestLimiter.acquire()
            do {
                let connection = try await connectionFactory.connect(to: socketURL)
                do {
                    let requestID = UUID().uuidString
                    let request = HerdrRequest(id: requestID, method: method, params: params)
                    try await connection.sendLine(JSONEncoder().encode(request))
                    let result = try await Self.readResponse(from: connection, expectedID: requestID, as: type)
                    await connection.close()
                    await requestLimiter.release()
                    return result
                } catch {
                    await connection.close()
                    throw error
                }
            } catch {
                await requestLimiter.release()
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
        timeout requestedTimeout: Duration? = nil,
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let timeout = min(requestTimeout, max(.zero, requestedTimeout ?? requestTimeout))
        let requestSleeper = requestSleeper
        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await requestSleeper.sleep(for: timeout)
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
        rebuildInFlight = false
        rebuildDirty = false
        metadataTask?.cancel()
        metadataTask = nil
        metadataToken = nil
        metadataInFlight = false
        metadataDirty = false
        detectionTask?.cancel()
        detectionTask = nil
        detectionToken = nil
        detectionPaneIDs.removeAll()
        presentation = nil
        subscriptionPaneIDs.removeAll()
        liveStatuses.removeAll()
        let connection = subscriptionConnection
        subscriptionConnection = nil
        subscriptionToken = nil
        await connection?.close()
        guard owns(generation) else { return }
        if wasConnected || !disconnectedPublished {
            disconnectedPublished = true
            AppLog.synchronization.info("Disconnected from Herdr: \(reason, privacy: .private)")
            publish(.disconnected(reason))
        }
    }

    private func owns(_ generation: UUID) -> Bool {
        running && lifecycleGeneration == generation
    }

    private func ensureOwnership(
        _ generation: UUID,
        rebuildToken expectedToken: UUID? = nil,
        presentationGeneration expectedPresentationGeneration: UInt64? = nil
    ) throws {
        guard owns(generation), !Task.isCancelled else { throw CancellationError() }
        if let expectedToken, rebuildToken != expectedToken { throw CancellationError() }
        if let expectedPresentationGeneration,
           presentationGeneration != expectedPresentationGeneration { throw CancellationError() }
    }

    private func shouldInvalidate(for error: any Error) -> Bool {
        if error is CancellationError { return !Task.isCancelled }
        return !(error is HerdrAPIError)
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

private actor RequestConnectionLimiter {
    private var available: Int
    private var waiters: [(UUID, CheckedContinuation<Void, any Error>)] = []

    init(limit: Int) { available = limit }

    func acquire() async throws {
        try Task.checkCancellation()
        if available > 0 {
            available -= 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await enqueue(id)
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func enqueue(_ id: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            if Task.isCancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                waiters.append((id, continuation))
            }
        }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().1.resume()
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
}
