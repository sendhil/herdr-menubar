import Foundation
import OSLog

protocol SessionClientServing: Sendable {
    func events() async -> AsyncStream<HerdrClientEvent>
    func start() async
    func stop() async
    func retryNow() async
    func refresh() async
    func focus(paneID: String) async throws -> PaneInfo
}

extension HerdrClient: SessionClientServing {}

protocol SessionClientCreating: Sendable {
    func makeClient(for descriptor: SessionDescriptor) async -> any SessionClientServing
}

struct LiveSessionClientFactory: SessionClientCreating {
    func makeClient(for descriptor: SessionDescriptor) async -> any SessionClientServing {
        HerdrClient(socketURL: descriptor.socketURL)
    }
}

enum SessionSupervisorEvent: Equatable, Sendable {
    case discoverySnapshot([SessionDescriptor])
    case connected(SessionDescriptor, PresentationSnapshot)
    case snapshot(SessionID, PresentationSnapshot)
    case unavailable(SessionID, String)
    case removed(SessionID)
}

enum SessionSupervisorError: LocalizedError, Equatable, Sendable {
    case sessionUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .sessionUnavailable(let name): "\(name) is unavailable"
        }
    }
}

enum ReconciliationStatus: Sendable {
    case applied
    case cancelled
    case failed
    case stopped
}

struct ReconciliationOutcome: Sendable {
    let generation: UInt64
    let status: ReconciliationStatus
    let retriedSessionIDs: Set<SessionID>
}

actor SessionSupervisor {
    struct Runtime {
        var descriptor: SessionDescriptor
        let client: any SessionClientServing
        let generation: UInt64
        var isPresent: Bool
        var isConnected: Bool
        var eventTask: Task<Void, Never>?
        var graceTask: Task<Void, Never>?
    }

    struct Removal {
        let sessionID: SessionID
        let runtimeGeneration: UInt64
        let task: Task<Void, Never>
    }

    struct ReconciliationWaiter {
        let id: UUID
        let continuation: CheckedContinuation<ReconciliationOutcome, Never>
    }

    private let discovery: any SessionDiscovering
    private let clientFactory: any SessionClientCreating
    private let sleeper: any Sleeper
    private let discoveryInterval: Duration
    private let removalGracePeriod: Duration

    private var runtimes: [SessionID: Runtime] = [:]
    private var eventContinuations: [UUID: AsyncStream<SessionSupervisorEvent>.Continuation] = [:]
    private var running = false
    private var lifecycleGeneration: UInt64 = 0
    private var nextRuntimeGeneration: UInt64 = 0
    private var discoveryLoopTask: Task<Void, Never>?

    private var requestedReconciliationGeneration: UInt64 = 0
    private var completedReconciliationGeneration: UInt64 = 0
    private var reconciliationWaiters: [
        UInt64: [ReconciliationWaiter]
    ] = [:]
    private var reconciliationTask: Task<Void, Never>?
    private var reconciliationTaskToken: UUID?
    private var targetedRetryGenerations: Set<UInt64> = []
    private var removalTasks: [UUID: Removal] = [:]

    init(
        discovery: any SessionDiscovering,
        clientFactory: any SessionClientCreating,
        sleeper: any Sleeper = TaskSleeper(),
        discoveryInterval: Duration = .seconds(2),
        removalGracePeriod: Duration = .seconds(10)
    ) {
        self.discovery = discovery
        self.clientFactory = clientFactory
        self.sleeper = sleeper
        self.discoveryInterval = discoveryInterval
        self.removalGracePeriod = removalGracePeriod
    }

    func events() -> AsyncStream<SessionSupervisorEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SessionSupervisorEvent>.makeStream()
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeEventContinuation(id) }
        }
        eventContinuations[id] = continuation
        return stream
    }

    func start() {
        guard !running else { return }
        running = true
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        discoveryLoopTask = Task { [weak self] in
            await self?.runDiscoveryLoop(lifecycleGeneration: generation)
        }
    }

    func stop() async {
        guard running
                || discoveryLoopTask != nil
                || reconciliationTask != nil
                || !runtimes.isEmpty
                || !removalTasks.isEmpty else {
            return
        }

        running = false
        lifecycleGeneration &+= 1

        let loopTask = discoveryLoopTask
        discoveryLoopTask = nil
        let workerTask = reconciliationTask
        reconciliationTask = nil
        reconciliationTaskToken = nil

        let ownedRuntimes = Array(runtimes.values)
        runtimes.removeAll()
        let ownedRemovals = Array(removalTasks.values)
        removalTasks.removeAll()

        let stopped = ReconciliationOutcome(
            generation: requestedReconciliationGeneration,
            status: .stopped,
            retriedSessionIDs: []
        )
        let waiters = reconciliationWaiters.values.flatMap { $0 }
        reconciliationWaiters.removeAll()
        for waiter in waiters { waiter.continuation.resume(returning: stopped) }

        loopTask?.cancel()
        workerTask?.cancel()
        for runtime in ownedRuntimes {
            runtime.graceTask?.cancel()
            runtime.eventTask?.cancel()
        }

        for runtime in ownedRuntimes {
            await runtime.client.stop()
        }

        await loopTask?.value
        await workerTask?.value
        for runtime in ownedRuntimes {
            await runtime.graceTask?.value
            await runtime.eventTask?.value
        }
        for removal in ownedRemovals {
            await removal.task.value
        }

        let continuations = eventContinuations.values
        eventContinuations.removeAll()
        for continuation in continuations { continuation.finish() }
    }

    func retryUnavailable() async {
        let outcome = await requestReconciliation()
        guard outcome.status == .applied, !Task.isCancelled else { return }
        guard targetedRetryGenerations.insert(outcome.generation).inserted else { return }
        let lifecycle = lifecycleGeneration

        let clients = runtimes.values.compactMap { runtime -> (any SessionClientServing)? in
            guard runtime.isPresent,
                  !runtime.isConnected,
                  !outcome.retriedSessionIDs.contains(runtime.descriptor.id) else { return nil }
            return runtime.client
        }
        for client in clients {
            guard ownsLifecycle(lifecycle), !Task.isCancelled else { return }
            await client.retryNow()
        }
    }

    func focus(sessionID: SessionID, paneID: String) async throws -> PaneInfo {
        guard let runtime = runtimes[sessionID], runtime.isPresent, runtime.isConnected else {
            throw SessionSupervisorError.sessionUnavailable(sessionID.displayName)
        }
        return try await runtime.client.focus(paneID: paneID)
    }

    func refresh(sessionID: SessionID) async {
        guard let runtime = runtimes[sessionID], runtime.isPresent else { return }
        await runtime.client.refresh()
    }
}

private extension SessionSupervisor {
    func runDiscoveryLoop(lifecycleGeneration generation: UInt64) async {
        defer {
            if lifecycleGeneration == generation {
                discoveryLoopTask = nil
            }
        }

        while ownsLifecycle(generation), !Task.isCancelled {
            let outcome = await requestReconciliation()
            guard outcome.status != .stopped, ownsLifecycle(generation), !Task.isCancelled else { return }
            do {
                try await sleeper.sleep(for: discoveryInterval)
            } catch {
                return
            }
        }
    }

    func requestReconciliation() async -> ReconciliationOutcome {
        guard running else {
            return ReconciliationOutcome(
                generation: requestedReconciliationGeneration,
                status: .stopped,
                retriedSessionIDs: []
            )
        }
        guard !Task.isCancelled else {
            return ReconciliationOutcome(
                generation: requestedReconciliationGeneration,
                status: .cancelled,
                retriedSessionIDs: []
            )
        }

        requestedReconciliationGeneration &+= 1
        let requestedGeneration = requestedReconciliationGeneration
        let lifecycle = lifecycleGeneration
        let waiterID = UUID()
        let supervisor = self
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: ReconciliationOutcome(
                        generation: requestedGeneration,
                        status: .cancelled,
                        retriedSessionIDs: []
                    ))
                    return
                }
                reconciliationWaiters[requestedGeneration, default: []].append(
                    ReconciliationWaiter(id: waiterID, continuation: continuation)
                )
                startReconciliationWorkerIfNeeded(lifecycleGeneration: lifecycle)
            }
        } onCancel: {
            Task {
                await supervisor.cancelReconciliationWaiter(
                    generation: requestedGeneration,
                    waiterID: waiterID
                )
            }
        }
    }

    func cancelReconciliationWaiter(generation: UInt64, waiterID: UUID) {
        guard var waiters = reconciliationWaiters[generation],
              let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return }
        let waiter = waiters.remove(at: index)
        if waiters.isEmpty {
            reconciliationWaiters.removeValue(forKey: generation)
        } else {
            reconciliationWaiters[generation] = waiters
        }
        waiter.continuation.resume(returning: ReconciliationOutcome(
            generation: generation,
            status: .cancelled,
            retriedSessionIDs: []
        ))
    }

    func startReconciliationWorkerIfNeeded(lifecycleGeneration generation: UInt64) {
        guard reconciliationTask == nil else { return }
        let token = UUID()
        reconciliationTaskToken = token
        reconciliationTask = Task { [weak self] in
            await self?.runReconciliationWorker(lifecycleGeneration: generation, token: token)
        }
    }

    func runReconciliationWorker(lifecycleGeneration generation: UInt64, token: UUID) async {
        defer { reconciliationWorkerFinished(token: token) }

        while ownsLifecycle(generation), !Task.isCancelled {
            let capturedGeneration = requestedReconciliationGeneration
            let outcome: ReconciliationOutcome
            do {
                let descriptors = try await discovery.discover()
                guard ownsLifecycle(generation), !Task.isCancelled else { return }
                let retriedSessionIDs = await apply(
                    descriptors: descriptors,
                    lifecycleGeneration: generation
                )
                guard ownsLifecycle(generation), !Task.isCancelled else { return }
                outcome = ReconciliationOutcome(
                    generation: capturedGeneration,
                    status: .applied,
                    retriedSessionIDs: retriedSessionIDs
                )
            } catch {
                guard ownsLifecycle(generation), !Task.isCancelled else { return }
                AppLog.synchronization.error("Session discovery failed: \(error.localizedDescription)")
                outcome = ReconciliationOutcome(
                    generation: capturedGeneration,
                    status: .failed,
                    retriedSessionIDs: []
                )
            }

            completeReconciliations(through: capturedGeneration, with: outcome)
            guard requestedReconciliationGeneration > capturedGeneration else { return }
        }
    }

    func reconciliationWorkerFinished(token: UUID) {
        guard reconciliationTaskToken == token else { return }
        reconciliationTask = nil
        reconciliationTaskToken = nil
    }

    func completeReconciliations(
        through generation: UInt64,
        with outcome: ReconciliationOutcome
    ) {
        let satisfied = reconciliationWaiters.keys
            .filter { $0 > completedReconciliationGeneration && $0 <= generation }
            .sorted()
        for key in satisfied {
            for waiter in reconciliationWaiters.removeValue(forKey: key) ?? [] {
                waiter.continuation.resume(returning: outcome)
            }
        }
        completedReconciliationGeneration = max(completedReconciliationGeneration, generation)
    }

    func apply(
        descriptors: [SessionDescriptor],
        lifecycleGeneration generation: UInt64
    ) async -> Set<SessionID> {
        publish(.discoverySnapshot(descriptors))

        var retriedSessionIDs: Set<SessionID> = []
        for descriptor in descriptors {
            if var runtime = runtimes[descriptor.id] {
                let returnedDuringGrace = !runtime.isPresent
                runtime.descriptor = descriptor
                runtime.isPresent = true
                runtime.graceTask?.cancel()
                runtime.graceTask = nil
                runtimes[descriptor.id] = runtime
                if returnedDuringGrace {
                    retriedSessionIDs.insert(descriptor.id)
                    await runtime.client.retryNow()
                    guard ownsLifecycle(generation), !Task.isCancelled else { break }
                }
                continue
            }
            await createRuntime(for: descriptor, lifecycleGeneration: generation)
            guard ownsLifecycle(generation), !Task.isCancelled else { break }
        }

        let discoveredIDs = Set(descriptors.map(\.id))
        for id in Array(runtimes.keys) where !discoveredIDs.contains(id) {
            markMissing(id, lifecycleGeneration: generation)
        }

        return retriedSessionIDs
    }

    func markMissing(_ sessionID: SessionID, lifecycleGeneration lifecycle: UInt64) {
        guard ownsLifecycle(lifecycle),
              var runtime = runtimes[sessionID],
              runtime.isPresent else { return }

        runtime.isPresent = false
        runtime.isConnected = false
        let runtimeGeneration = runtime.generation
        let graceTask = Task { [weak self, sleeper, removalGracePeriod] in
            do {
                try await sleeper.sleep(for: removalGracePeriod)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.graceExpired(
                sessionID: sessionID,
                runtimeGeneration: runtimeGeneration,
                lifecycleGeneration: lifecycle
            )
        }
        runtime.graceTask = graceTask
        runtimes[sessionID] = runtime
        publish(.unavailable(sessionID, "Session socket unavailable"))
    }

    func graceExpired(
        sessionID: SessionID,
        runtimeGeneration: UInt64,
        lifecycleGeneration lifecycle: UInt64
    ) {
        guard ownsLifecycle(lifecycle),
              let runtime = runtimes[sessionID],
              runtime.generation == runtimeGeneration,
              !runtime.isPresent else { return }

        runtimes.removeValue(forKey: sessionID)
        runtime.eventTask?.cancel()

        let token = UUID()
        let removalTask = Task { [weak self] in
            await runtime.client.stop()
            await runtime.eventTask?.value
            await runtime.graceTask?.value
            await self?.removalFinished(
                sessionID: sessionID,
                runtimeGeneration: runtimeGeneration,
                lifecycleGeneration: lifecycle,
                token: token
            )
        }
        removalTasks[token] = Removal(
            sessionID: sessionID,
            runtimeGeneration: runtimeGeneration,
            task: removalTask
        )
    }

    func removalFinished(
        sessionID: SessionID,
        runtimeGeneration: UInt64,
        lifecycleGeneration lifecycle: UInt64,
        token: UUID
    ) {
        guard let removal = removalTasks[token],
              removal.sessionID == sessionID,
              removal.runtimeGeneration == runtimeGeneration else { return }
        removalTasks.removeValue(forKey: token)

        guard ownsLifecycle(lifecycle),
              runtimes[sessionID]?.generation != runtimeGeneration else { return }
        guard runtimes[sessionID] == nil else { return }
        publish(.removed(sessionID))
    }

    func createRuntime(
        for descriptor: SessionDescriptor,
        lifecycleGeneration lifecycle: UInt64
    ) async {
        let client = await clientFactory.makeClient(for: descriptor)
        guard ownsLifecycle(lifecycle), !Task.isCancelled, runtimes[descriptor.id] == nil else {
            await client.stop()
            return
        }

        let stream = await client.events()
        guard ownsLifecycle(lifecycle), !Task.isCancelled, runtimes[descriptor.id] == nil else {
            await client.stop()
            return
        }

        nextRuntimeGeneration &+= 1
        let runtimeGeneration = nextRuntimeGeneration
        var runtime = Runtime(
            descriptor: descriptor,
            client: client,
            generation: runtimeGeneration,
            isPresent: true,
            isConnected: false,
            eventTask: nil,
            graceTask: nil
        )
        runtimes[descriptor.id] = runtime

        let eventTask = Task { [weak self] in
            guard let self else { return }
            await self.consume(
                stream: stream,
                sessionID: descriptor.id,
                runtimeGeneration: runtimeGeneration,
                lifecycleGeneration: lifecycle
            )
        }
        runtime.eventTask = eventTask
        runtimes[descriptor.id] = runtime

        guard ownsRuntime(
            sessionID: descriptor.id,
            runtimeGeneration: runtimeGeneration,
            lifecycleGeneration: lifecycle
        ), !Task.isCancelled else {
            await cleanUpRuntimeIfOwned(sessionID: descriptor.id, runtimeGeneration: runtimeGeneration)
            return
        }

        await client.start()
        guard ownsRuntime(
            sessionID: descriptor.id,
            runtimeGeneration: runtimeGeneration,
            lifecycleGeneration: lifecycle
        ), !Task.isCancelled else {
            await cleanUpRuntimeIfOwned(sessionID: descriptor.id, runtimeGeneration: runtimeGeneration)
            return
        }
    }

    func consume(
        stream: AsyncStream<HerdrClientEvent>,
        sessionID: SessionID,
        runtimeGeneration: UInt64,
        lifecycleGeneration lifecycle: UInt64
    ) async {
        for await event in stream {
            guard !Task.isCancelled else { return }
            forward(
                event,
                sessionID: sessionID,
                runtimeGeneration: runtimeGeneration,
                lifecycleGeneration: lifecycle
            )
        }
    }

    func forward(
        _ event: HerdrClientEvent,
        sessionID: SessionID,
        runtimeGeneration: UInt64,
        lifecycleGeneration lifecycle: UInt64
    ) {
        guard ownsRuntime(
            sessionID: sessionID,
            runtimeGeneration: runtimeGeneration,
            lifecycleGeneration: lifecycle
        ), var runtime = runtimes[sessionID] else { return }

        switch event {
        case .connected(let snapshot):
            guard runtime.isPresent else { return }
            runtime.isConnected = true
            runtimes[sessionID] = runtime
            publish(.connected(runtime.descriptor, snapshot))
        case .snapshot(let snapshot):
            guard runtime.isPresent else { return }
            publish(.snapshot(sessionID, snapshot))
        case .disconnected(let reason):
            guard runtime.isPresent else { return }
            runtime.isConnected = false
            runtimes[sessionID] = runtime
            publish(.unavailable(sessionID, reason))
        }
    }

    func cleanUpRuntimeIfOwned(sessionID: SessionID, runtimeGeneration: UInt64) async {
        guard let runtime = runtimes[sessionID], runtime.generation == runtimeGeneration else { return }
        runtimes.removeValue(forKey: sessionID)
        runtime.graceTask?.cancel()
        runtime.eventTask?.cancel()
        await runtime.client.stop()
        await runtime.graceTask?.value
        await runtime.eventTask?.value
    }

    func ownsLifecycle(_ generation: UInt64) -> Bool {
        running && lifecycleGeneration == generation
    }

    func ownsRuntime(
        sessionID: SessionID,
        runtimeGeneration: UInt64,
        lifecycleGeneration lifecycle: UInt64
    ) -> Bool {
        ownsLifecycle(lifecycle) && runtimes[sessionID]?.generation == runtimeGeneration
    }

    func publish(_ event: SessionSupervisorEvent) {
        for continuation in eventContinuations.values { continuation.yield(event) }
    }

    func removeEventContinuation(_ id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }
}
