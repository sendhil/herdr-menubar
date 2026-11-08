import AppKit
import Foundation

// RexBackend: drives one long-running `rex do RexWatcher.lua --all` process per watcher
// generation, feeds its lines to the pure RexReducer, and supervises it (snapshot deadline,
// heartbeats, backoff). Focus runs one-shot CLI processes. Everything time-related goes through
// an injected clock so tests are deterministic.

// MARK: Injection points

/// Time source and sleeper for deadlines, heartbeats, backoff, and settle timers.
protocol RexBackendClock: Sendable {
    var now: ContinuousClock.Instant { get }
    /// Returns at or after `deadline`; throws `CancellationError` when the task is cancelled.
    func sleep(until deadline: ContinuousClock.Instant) async throws
}

struct LiveRexBackendClock: RexBackendClock {
    var now: ContinuousClock.Instant { ContinuousClock.now }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        try await ContinuousClock().sleep(until: deadline, tolerance: nil)
    }
}

/// CLI resolution as RexBackend uses it. `RexCLIResolver` is the live implementation.
protocol RexCLIResolving: Sendable {
    func resolve() async throws -> RexCLIResolution
    func markFailed(path: String) async
}

extension RexCLIResolver: RexCLIResolving {}

/// A started-on-demand watcher child. `ManagedProcess` is the live implementation.
protocol RexWatcherProcess: Sendable {
    func start() throws(ManagedProcessError) -> AsyncStream<ManagedProcessEvent>
    func terminate() async
    var lastStderrLine: String? { get }
}

extension ManagedProcess: RexWatcherProcess {}

/// Creates an unstarted watcher process for a CLI, script, and generation.
typealias RexWatcherFactory = @Sendable (RexCLI, URL, Int) -> any RexWatcherProcess

/// Rex.app as seen through NSWorkspace.
protocol RexAppControlling: Sendable {
    func isRunning() async -> Bool
    func activate() async
}

struct LiveRexAppControl: RexAppControlling {
    static let bundleIdentifier = RexCLIResolver.rexAppBundleIdentifier

    @MainActor
    private static func runningApp() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
    }

    func isRunning() async -> Bool {
        await MainActor.run { Self.runningApp() != nil }
    }

    /// Brings a running Rex.app forward. Never launches it (launching is a non-goal): when it is
    /// not running this does nothing.
    func activate() async {
        await MainActor.run {
            guard let running = Self.runningApp() else { return }
            guard let url = running.bundleURL
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) else {
                _ = running.activate()
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error {
                    AppLog.systemActions.error("Rex activation failed: \(error.localizedDescription, privacy: .private)")
                }
            }
        }
    }
}

// MARK: Backend

actor RexBackend: AgentBackend {
    /// Restart delays after a watcher failure; the last one repeats.
    static let backoffSchedule: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(15), .seconds(60)]
    static let snapshotTimeout: Duration = .seconds(20)
    static let heartbeatTimeout: Duration = .seconds(15)
    static let hiddenRecheckInterval: Duration = .seconds(300)
    static let serverUnreachableInterval: Duration = .seconds(60)
    /// Watcher exit status meaning "no Rex server is running" (F15).
    static let serverUnreachableExitCode: Int32 = 4

    nonisolated var kind: BackendKind { .rex }

    private let resolver: any RexCLIResolving
    private let makeWatcher: RexWatcherFactory
    private let scriptURL: URL?
    let runner: any ProcessRunning
    let app: any RexAppControlling
    let clock: any RexBackendClock
    let hostName: @Sendable () -> String?
    private let isEnabled: @Sendable () -> Bool

    private var continuation: AsyncStream<BackendEvent>.Continuation?
    private var reducer = RexReducer()

    /// Bumped by `start()` and `stop()`; work started under an older value is discarded.
    private var lifecycle = 0
    private var isRunning = false
    private var loopTask: Task<Void, Never>?

    // Watcher supervision
    private struct Generation {
        let id: Int
        let process: any RexWatcherProcess
        let cli: RexCLI
        var supervisionDeadline: ContinuousClock.Instant
        var snapshotDone = false
        var waiter: CheckedContinuation<GenerationOutcome, Never>?
    }

    private struct GenerationOutcome {
        let reason: String
        var marksCandidateFailed = false
        var serverUnreachable = false
        var stopped = false
    }

    private var generationCounter = 0
    private var current: Generation?
    private var pendingProcessEvents: [ManagedProcessEvent] = []
    private var drainScheduled = false

    // Backoff and visibility
    private var backoffIndex = 0
    private var backoffWait: Task<Void, Error>?
    private var isHidden = false
    private var unavailableReason: String?
    /// The CLI of the latest successful resolution (focus uses it).
    private(set) var resolvedCLI: RexCLI?
    /// A CLI resolved at least once since `start()` (step 3's "Rex resolved this run").
    private(set) var hasResolvedCLIThisRun = false

    // Timers
    private var timerTask: Task<Void, Never>?
    private var armedDeadline: ContinuousClock.Instant?

    /// Display names from the latest `.connected`/`.descriptorChanged`, for focus messages.
    private var sessionNames: [String: String] = [:]

    init(
        resolver: any RexCLIResolving,
        scriptURL: URL? = RexWatcherScript.bundledURL(),
        makeWatcher: @escaping RexWatcherFactory = RexBackend.liveWatcherFactory,
        runner: any ProcessRunning = LiveProcessRunner(),
        app: any RexAppControlling = LiveRexAppControl(),
        clock: any RexBackendClock = LiveRexBackendClock(),
        hostName: @escaping @Sendable () -> String? = { Host.current().localizedName },
        isEnabled: @escaping @Sendable () -> Bool
    ) {
        self.resolver = resolver
        self.scriptURL = scriptURL
        self.makeWatcher = makeWatcher
        self.runner = runner
        self.app = app
        self.clock = clock
        self.hostName = hostName
        self.isEnabled = isEnabled
    }

    static let liveWatcherFactory: RexWatcherFactory = { cli, scriptURL, generation in
        RexWatcherScript.makeProcess(cli: cli, scriptURL: scriptURL, generation: generation)
    }

    // MARK: AgentBackend

    func events() async -> AsyncStream<BackendEvent> {
        let (stream, continuation) = AsyncStream<BackendEvent>.makeStream()
        self.continuation?.finish()
        self.continuation = continuation
        return stream
    }

    func start() async {
        guard !isRunning else { return }
        isRunning = true
        lifecycle += 1
        guard isEnabled() else {
            isHidden = true
            yield(.backendHidden)
            return
        }
        let owner = lifecycle
        loopTask = Task { [weak self] in await self?.runLoop(lifecycle: owner) }
    }

    func stop() async {
        lifecycle += 1
        isRunning = false
        let loop = loopTask
        loopTask = nil
        loop?.cancel()
        backoffWait?.cancel()
        backoffWait = nil
        let process = current?.process
        finishGeneration(GenerationOutcome(reason: "stopped", stopped: true))
        cancelTimer()
        pendingProcessEvents = []
        continuation?.finish()
        continuation = nil
        await process?.terminate()
        await loop?.value
        reducer.reset()
        backoffIndex = 0
        isHidden = false
        unavailableReason = nil
        resolvedCLI = nil
        hasResolvedCLIThisRun = false
        sessionNames = [:]
    }

    func retryUnavailable() async {
        // Healthy or resolving: nothing to do. In backoff or hidden: wake the loop now.
        guard isRunning, let wait = backoffWait else { return }
        backoffIndex = 0
        wait.cancel()
    }

    func refreshAfterSelection(_ target: AgentTarget) async {}

    func markSeen(_ token: SeenToken) async {
        emit(reducer.markSeen(token))
    }

    func clearFinished() async {
        emit(reducer.clearFinished())
    }

    nonisolated func compareSessions(_ lhs: AgentSessionDescriptor, _ rhs: AgentSessionDescriptor) -> Bool {
        RexRows.compareSessions(lhs, rhs)
    }

    // MARK: Focus support

    /// The session's display name for messages, falling back to "Rex session".
    func sessionName(_ sessionID: String) -> String {
        sessionNames[sessionID] ?? RexRows.fallbackSessionName
    }

    // MARK: Supervision loop

    private func owns(_ owner: Int) -> Bool {
        owner == lifecycle && !Task.isCancelled
    }

    private func runLoop(lifecycle owner: Int) async {
        while owns(owner) {
            let resolution: RexCLIResolution
            do {
                resolution = try await resolver.resolve()
            } catch {
                return
            }
            guard owns(owner) else { return }

            let delay: Duration
            switch resolution {
            case .hidden:
                if !isHidden {
                    isHidden = true
                    yield(.backendHidden)
                }
                delay = resolution.retryInterval ?? Self.hiddenRecheckInterval
            case .unavailable(let reason):
                isHidden = false
                markUnavailable(reason)
                delay = resolution.retryInterval ?? nextBackoff()
            case .serverUnreachable(let cli):
                isHidden = false
                noteResolved(cli)
                markUnavailable("Rex is not running")
                backoffIndex = Self.backoffSchedule.count - 1
                delay = resolution.retryInterval ?? Self.serverUnreachableInterval
            case .ready(let cli):
                isHidden = false
                noteResolved(cli)
                let outcome = await runWatcher(cli)
                guard owns(owner), !outcome.stopped else { return }
                if outcome.marksCandidateFailed { await resolver.markFailed(path: cli.path) }
                guard owns(owner) else { return }
                markUnavailable(outcome.reason)
                if outcome.serverUnreachable {
                    backoffIndex = Self.backoffSchedule.count - 1
                    delay = Self.serverUnreachableInterval
                } else {
                    delay = nextBackoff()
                }
            }
            guard await waitForRetry(delay), owns(owner) else { return }
        }
    }

    private func noteResolved(_ cli: RexCLI) {
        resolvedCLI = cli
        hasResolvedCLIThisRun = true
    }

    private func nextBackoff() -> Duration {
        let delay = Self.backoffSchedule[min(backoffIndex, Self.backoffSchedule.count - 1)]
        backoffIndex = min(backoffIndex + 1, Self.backoffSchedule.count - 1)
        return delay
    }

    /// Sleeps for `delay` unless `retryUnavailable()` wakes it first. False when the loop itself
    /// was cancelled.
    private func waitForRetry(_ delay: Duration) async -> Bool {
        let deadline = clock.now + delay
        let clock = self.clock
        let wait = Task { try await clock.sleep(until: deadline) }
        backoffWait = wait
        await withTaskCancellationHandler {
            _ = await wait.result
        } onCancel: {
            wait.cancel()
        }
        if backoffWait == wait { backoffWait = nil }
        return !Task.isCancelled
    }

    private func markUnavailable(_ reason: String) {
        guard unavailableReason != reason else { return }
        unavailableReason = reason
        AppLog.synchronization.error("Rex backend unavailable: \(reason, privacy: .private)")
        yield(.backendUnavailable(reason))
    }

    // MARK: One watcher generation

    private func runWatcher(_ cli: RexCLI) async -> GenerationOutcome {
        guard let scriptURL else {
            return GenerationOutcome(reason: "The Rex watcher script is missing from the app bundle")
        }
        generationCounter += 1
        let id = generationCounter
        let process = makeWatcher(cli, scriptURL, id)
        let stream: AsyncStream<ManagedProcessEvent>
        do {
            stream = try process.start()
        } catch {
            return GenerationOutcome(reason: "Could not start the Rex watcher: \(error)")
        }

        reducer.beginGeneration(id)
        pendingProcessEvents = []
        current = Generation(id: id, process: process, cli: cli, supervisionDeadline: clock.now + Self.snapshotTimeout)
        rearmTimer()

        let consumer = Task { [weak self] in
            for await event in stream {
                await self?.enqueue(event)
            }
        }
        // No suspension point between storing `current` and installing the waiter, so nothing
        // can finish the generation before the waiter exists.
        let outcome = await withCheckedContinuation { continuation in
            current?.waiter = continuation
        }
        consumer.cancel()
        await process.terminate()
        return outcome
    }

    /// Ends the current generation (idempotent): later lines of it are ignored, the reducer stops
    /// emitting until the next `snapshot_done`, and the loop resumes with `outcome`.
    private func finishGeneration(_ outcome: GenerationOutcome) {
        guard let generation = current else { return }
        current = nil
        pendingProcessEvents = []
        reducer.endGeneration()
        rearmTimer()
        generation.waiter?.resume(returning: outcome)
    }

    private func enqueue(_ event: ManagedProcessEvent) {
        guard let current, event.generation == current.id else { return }
        pendingProcessEvents.append(event)
        guard !drainScheduled else { return }
        drainScheduled = true
        Task { [weak self] in await self?.drainProcessEvents() }
    }

    /// Applies every queued process event as one batch, coalescing the resulting snapshots.
    private func drainProcessEvents() {
        drainScheduled = false
        let batch = pendingProcessEvents
        pendingProcessEvents = []
        var events: [BackendEvent] = []
        var ended: GenerationOutcome?

        for event in batch {
            guard let generation = current, event.generation == generation.id else { break }
            switch event {
            case .line(_, let data):
                let line: RexWatcherLine
                do {
                    line = try RexWatcherLine.decode(data)
                } catch {
                    AppLog.synchronization.error("Ignoring undecodable Rex watcher line: \(String(describing: error), privacy: .private)")
                    continue
                }
                let now = clock.now
                let wasDone = reducer.isSnapshotDone
                let output = reducer.apply(line, generation: generation.id, now: now)
                events += output.events
                for message in output.logMessages {
                    AppLog.synchronization.info("\(message, privacy: .private)")
                }
                if let failure = output.failure {
                    ended = GenerationOutcome(reason: failure.reason, marksCandidateFailed: failure.marksCandidateFailed)
                } else if !wasDone, reducer.isSnapshotDone {
                    current?.snapshotDone = true
                    current?.supervisionDeadline = now + Self.heartbeatTimeout
                    backoffIndex = 0
                    unavailableReason = nil
                } else if line == .heartbeat, generation.snapshotDone {
                    current?.supervisionDeadline = now + Self.heartbeatTimeout
                }

            case .framingError(_, let error):
                ended = GenerationOutcome(reason: "The Rex watcher sent an unreadable line (\(error))")

            case .exited(_, let termination):
                guard !termination.terminatedByUs else { continue }
                ended = exitOutcome(termination, generation: generation)
            }
            if ended != nil { break }
        }

        emit(RexEventCoalescer.coalesce(events))
        if let ended { finishGeneration(ended) }
        rearmTimer()
    }

    private func exitOutcome(_ termination: ProcessTermination, generation: Generation) -> GenerationOutcome {
        if termination.exitCode == Self.serverUnreachableExitCode {
            return GenerationOutcome(reason: "Rex is not running", serverUnreachable: true)
        }
        let detail = generation.process.lastStderrLine
        let status: String = switch termination.reason {
        case .exited: "status \(termination.status)"
        case .signaled: "signal \(termination.status)"
        }
        let reason = detail.map { "The Rex watcher exited: \($0)" } ?? "The Rex watcher exited with \(status)"
        // Exiting on its own before `snapshot_done` (not exit 4, not our termination) marks
        // the binary failed for this run.
        return GenerationOutcome(reason: reason, marksCandidateFailed: !generation.snapshotDone)
    }

    // MARK: Timers (supervision deadline and settle deadlines share one timer)

    private func rearmTimer() {
        var deadline = current?.supervisionDeadline
        if reducer.isSnapshotDone, let settle = reducer.nextSettleDeadline {
            deadline = deadline.map { min($0, settle) } ?? settle
        }
        guard deadline != armedDeadline else { return }
        timerTask?.cancel()
        timerTask = nil
        armedDeadline = deadline
        guard let deadline else { return }
        let clock = self.clock
        timerTask = Task { [weak self] in
            do { try await clock.sleep(until: deadline) } catch { return }
            await self?.timerFired(deadline)
        }
    }

    private func cancelTimer() {
        timerTask?.cancel()
        timerTask = nil
        armedDeadline = nil
    }

    private func timerFired(_ deadline: ContinuousClock.Instant) {
        guard armedDeadline == deadline else { return }
        timerTask = nil
        armedDeadline = nil
        // Lines already received count (a queued heartbeat must not time out).
        if !pendingProcessEvents.isEmpty { drainProcessEvents() }
        let now = clock.now
        if let generation = current, now >= generation.supervisionDeadline {
            let reason = generation.snapshotDone
                ? "The Rex watcher stopped responding"
                : "Rex did not finish its snapshot in time"
            finishGeneration(GenerationOutcome(reason: reason))
        }
        emit(reducer.tick(now: now))
        rearmTimer()
    }

    // MARK: Emission

    private func emit(_ events: [BackendEvent]) {
        for event in events { yield(event) }
    }

    private func yield(_ event: BackendEvent) {
        switch event {
        case .connected(let descriptor, _), .descriptorChanged(let descriptor):
            sessionNames[descriptor.key.rawID] = descriptor.displayName
        case .removed(let key):
            sessionNames[key.rawID] = nil
        default:
            break
        }
        continuation?.yield(event)
    }
}

// MARK: Coalescing

enum RexEventCoalescer {
    /// Drops a `.snapshot` that a later `.snapshot` for the same session in the same batch
    /// supersedes, but only when nothing else for that session lies between them and both carry
    /// the same attention list, so the coordinator sees every attention change. Order is kept and
    /// a `.connected` is never merged with a following `.snapshot`.
    static func coalesce(_ events: [BackendEvent]) -> [BackendEvent] {
        guard events.count > 1 else { return events }
        var keep = [Bool](repeating: true, count: events.count)
        /// Index of the latest kept `.snapshot` per session that a later one may replace.
        var replaceable: [AgentSessionKey: Int] = [:]
        for (index, event) in events.enumerated() {
            switch event {
            case .snapshot(let key, let snapshot):
                if let previous = replaceable[key], case .snapshot(_, let earlier) = events[previous],
                   earlier.attention == snapshot.attention {
                    keep[previous] = false
                }
                replaceable[key] = index
            case .connected(let descriptor, _), .descriptorChanged(let descriptor):
                replaceable[descriptor.key] = nil
            case .removed(let key), .sessionUnavailable(let key, _):
                replaceable[key] = nil
            case .discovery, .backendUnavailable, .backendHidden:
                replaceable.removeAll()
            }
        }
        return zip(events, keep).compactMap { $1 ? $0 : nil }
    }
}
