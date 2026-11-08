import Foundation
import XCTest
@testable import HerdrMenubar

// Deterministic fakes for RexBackend: a manual clock, scripted watcher processes, a scripted
// resolver, a scripted one-shot runner, and a Rex.app stand-in.

/// A clock that only moves when the test calls `advance`. Sleepers whose deadline has passed
/// resume at once, so a timer armed after an `advance` still fires correctly.
final class ManualRexClock: RexBackendClock, @unchecked Sendable {
    private struct Sleeper {
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    let start = ContinuousClock.now
    private var offset: Duration = .zero
    private var sleepers: [UUID: Sleeper] = [:]
    private var cancelled: Set<UUID> = []

    var now: ContinuousClock.Instant { lock.withLock { start + offset } }
    var elapsed: Duration { lock.withLock { offset } }
    var sleeperCount: Int { lock.withLock { sleepers.count } }
    /// Pending sleep deadlines as offsets from `start`.
    var pendingOffsets: [Duration] { lock.withLock { sleepers.values.map { $0.deadline - start } } }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                enum Action { case resume, cancel, wait }
                let action: Action = lock.withLock {
                    if cancelled.remove(id) != nil { return .cancel }
                    if deadline <= start + offset { return .resume }
                    sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return .wait
                }
                switch action {
                case .resume: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                case .wait: break
                }
            }
        } onCancel: {
            let sleeper: Sleeper? = lock.withLock {
                if let sleeper = sleepers.removeValue(forKey: id) { return sleeper }
                cancelled.insert(id)
                return nil
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(_ duration: Duration) {
        let due: [Sleeper] = lock.withLock {
            offset += duration
            let now = start + offset
            let due = sleepers.filter { $0.value.deadline <= now }
            for id in due.keys { sleepers[id] = nil }
            return Array(due.values)
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}

/// A watcher child the test drives by hand.
final class FakeWatcherProcess: RexWatcherProcess, @unchecked Sendable {
    let cli: RexCLI
    let generation: Int
    private let lock = NSLock()
    private var continuation: AsyncStream<ManagedProcessEvent>.Continuation?
    private var _terminateCount = 0
    private var exited = false
    private let failStart: Bool
    var stderrLine: String?

    init(cli: RexCLI, generation: Int, failStart: Bool = false) {
        self.cli = cli
        self.generation = generation
        self.failStart = failStart
    }

    var terminateCount: Int { lock.withLock { _terminateCount } }
    var lastStderrLine: String? { lock.withLock { stderrLine } }

    func start() throws(ManagedProcessError) -> AsyncStream<ManagedProcessEvent> {
        if failStart { throw .launchFailed("boom") }
        let (stream, continuation) = AsyncStream<ManagedProcessEvent>.makeStream()
        lock.withLock { self.continuation = continuation }
        return stream
    }

    func terminate() async {
        let continuation: AsyncStream<ManagedProcessEvent>.Continuation? = lock.withLock {
            _terminateCount += 1
            guard !exited else { return nil }
            exited = true
            return self.continuation
        }
        continuation?.yield(.exited(generation: generation,
                                    ProcessTermination(reason: .exited, status: 130, terminatedByUs: true)))
        continuation?.finish()
    }

    func send(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        sendRaw(data)
    }

    func sendRaw(_ data: Data) {
        let continuation = lock.withLock { self.continuation }
        continuation?.yield(.line(generation: generation, data))
    }

    func sendFramingError() {
        let continuation = lock.withLock { self.continuation }
        continuation?.yield(.framingError(generation: generation, .lineTooLong(limit: 4_194_304)))
    }

    func exit(_ code: Int32) {
        let continuation: AsyncStream<ManagedProcessEvent>.Continuation? = lock.withLock {
            guard !exited else { return nil }
            exited = true
            return self.continuation
        }
        continuation?.yield(.exited(generation: generation,
                                    ProcessTermination(reason: .exited, status: code, terminatedByUs: false)))
        continuation?.finish()
    }
}

final class FakeWatcherFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var _processes: [FakeWatcherProcess] = []
    var failStarts = false

    var processes: [FakeWatcherProcess] { lock.withLock { _processes } }
    var last: FakeWatcherProcess? { processes.last }

    var factory: RexWatcherFactory {
        { [self] cli, _, generation in
            lock.withLock {
                let process = FakeWatcherProcess(cli: cli, generation: generation, failStart: failStarts)
                _processes.append(process)
                return process
            }
        }
    }
}

/// Returns scripted resolutions in order; the last one repeats.
final class FakeRexResolver: RexCLIResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [RexCLIResolution]
    private var _resolveCount = 0
    private var _failed: [String] = []

    init(_ results: [RexCLIResolution]) { self.results = results }

    var resolveCount: Int { lock.withLock { _resolveCount } }
    var failedPaths: [String] { lock.withLock { _failed } }

    func set(_ results: [RexCLIResolution]) { lock.withLock { self.results = results } }

    func resolve() async throws -> RexCLIResolution {
        try Task.checkCancellation()
        return lock.withLock {
            _resolveCount += 1
            return results.count > 1 ? results.removeFirst() : results[0]
        }
    }

    func markFailed(path: String) async {
        lock.withLock { _failed.append(path) }
    }
}

/// A one-shot runner answering through a closure; records every request.
final class ScriptedProcessRunner: ProcessRunning, @unchecked Sendable {
    typealias Handler = @Sendable (ProcessRequest) async -> ProcessResult
    private let lock = NSLock()
    private var _requests: [ProcessRequest] = []
    private var handler: Handler

    init(_ handler: @escaping Handler = { _ in ProcessResult(outcome: .launchFailed("unscripted")) }) {
        self.handler = handler
    }

    var requests: [ProcessRequest] { lock.withLock { _requests } }

    func setHandler(_ handler: @escaping Handler) { lock.withLock { self.handler = handler } }

    func run(_ request: ProcessRequest) async -> ProcessResult {
        let handler = lock.withLock {
            _requests.append(request)
            return self.handler
        }
        return await handler(request)
    }
}

final class FakeRexApp: RexAppControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var _running: Bool
    private var _activations = 0

    init(running: Bool = true) { _running = running }

    var activations: Int { lock.withLock { _activations } }
    var running: Bool {
        get { lock.withLock { _running } }
        set { lock.withLock { _running = newValue } }
    }

    func isRunning() async -> Bool { running }
    func activate() async { lock.withLock { _activations += 1 } }
}

/// Collects a backend's events.
final class BackendEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [BackendEvent] = []
    private var _finished = false
    private var task: Task<Void, Never>?

    var events: [BackendEvent] { lock.withLock { _events } }
    var finished: Bool { lock.withLock { _finished } }

    init(_ stream: AsyncStream<BackendEvent>) {
        task = Task { [weak self] in
            for await event in stream { self?.append(event) }
            self?.lock.withLock { self?._finished = true }
        }
    }

    private func append(_ event: BackendEvent) { lock.withLock { _events.append(event) } }

    func clear() { lock.withLock { _events.removeAll() } }
}

/// Polls `condition` until it holds (real time, up to `timeout`).
@MainActor
func rexWaitUntil(
    _ message: String = "condition",
    timeout: Duration = .seconds(3),
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () async -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
    if await condition() { return }
    XCTFail("Timed out waiting for \(message)", file: file, line: line)
}

/// Lets queued actor work run without moving the manual clock.
@MainActor
func settleTasks(_ rounds: Int = 20) async {
    for _ in 0..<rounds {
        try? await Task.sleep(for: .milliseconds(1))
    }
}

/// Watcher JSON lines in the exact shape `RexWatcher.lua` prints.
enum RexJSON {
    static func session(_ s: String, label: String) -> [String: Any] { ["t": "session", "s": s, "label": label] }

    static func view(_ s: String, label: String, blocks: [(b: String, window: String)]) -> [String: Any] {
        ["t": "view", "s": s, "session_label": label,
         "blocks": blocks.map { ["b": $0.b, "creator": RexLines.terminal, "window_id": "window:x",
                                 "window_label": $0.window, "block_label": "shell"] }]
    }

    static func block(_ s: String, _ b: String, state: String?, at: Int, via: String? = nil, msg: String? = nil) -> [String: Any] {
        var o: [String: Any] = ["t": "block", "s": s, "b": b]
        if let state {
            var record: [String: Any] = ["id": "", "state": state, "at": RexLines.ts(at)]
            record["msg"] = msg
            o["records"] = [record]
        } else {
            o["records"] = [String: Any]()
        }
        if let via { o["via"] = ["id": "", "state": via, "at": RexLines.ts(at)] }
        return o
    }

    static var snapshotDone: [String: Any] { ["t": "snapshot_done"] }
    static var heartbeat: [String: Any] { ["t": "heartbeat"] }

    /// One session `s1` labeled `work` with block `b1` in window `One`.
    static func snapshot(state: String? = "working", at: Int = 1, session: String = "s1", label: String = "work") -> [[String: Any]] {
        [
            Self.session(session, label: label),
            view(session, label: label, blocks: [("b1", "One")]),
            block(session, "b1", state: state, at: at),
            snapshotDone,
        ]
    }
}

extension FakeWatcherProcess {
    func send(_ objects: [[String: Any]]) {
        for object in objects { send(object) }
    }
}
