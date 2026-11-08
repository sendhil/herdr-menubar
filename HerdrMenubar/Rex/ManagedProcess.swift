import Darwin
import Foundation
import Synchronization

/// One-shot timeouts from the spec ("ManagedProcess", "CLI resolution").
enum RexTimeouts {
    static let version: Duration = .seconds(2)
    static let serverStatus: Duration = .seconds(3)
    static let focus: Duration = .seconds(5)
    static let shellProbe: Duration = .seconds(3)
    /// `client ls` has no spec'd value; it shares the focus budget.
    static let clientList: Duration = .seconds(5)
}

struct ProcessTermination: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case exited
        case signaled
    }

    let reason: Reason
    /// Exit code for `.exited`, signal number for `.signaled`.
    let status: Int32
    /// `terminate()` was called before the process was reaped. Such exits are never the
    /// child's own failure (spec: "our own termination doesn't count").
    let terminatedByUs: Bool

    var exitCode: Int32? { reason == .exited ? status : nil }
}

enum ManagedProcessEvent: Equatable, Sendable {
    /// One stdout line without its terminator (`.lines` mode only).
    case line(generation: Int, Data)
    /// Delivered at most once; no `.line` follows it. The caller decides whether to terminate.
    case framingError(generation: Int, FramingError)
    /// Always the last event. Delivered after all stdout has been processed.
    case exited(generation: Int, ProcessTermination)

    var generation: Int {
        switch self {
        case .line(let generation, _), .framingError(let generation, _), .exited(let generation, _): generation
        }
    }
}

enum ManagedProcessError: Error, Equatable, Sendable {
    case alreadyStarted
    case launchFailed(String)
}

/// A child process run with an argv (never a shell command line), the app's environment minus
/// every `REX_*` variable, stdin from `/dev/null`, stdout framed into lines (or collected), and
/// stderr drained continuously into a bounded ring.
///
/// Spawned with `posix_spawn` rather than Foundation `Process` so the shell probe can be put in
/// its own process group (`POSIX_SPAWN_SETPGROUP`) and killed as a group.
final class ManagedProcess: Sendable {
    static let watcherMaxLineLength = 4 * 1024 * 1024
    static let stderrCapacity = 16 * 1024
    /// Cap for `.collect` mode (one-shot runs).
    static let collectLimit = 1024 * 1024
    static let terminateGrace: Duration = .seconds(1)
    /// After the child is reaped, how long to wait for stdout/stderr EOF (a descendant may keep
    /// the pipes open) before delivering `.exited` anyway.
    static let drainAfterExit: Duration = .seconds(1)

    enum StdoutMode: Equatable, Sendable {
        case lines(maxLineLength: Int?)
        case collect(limit: Int)
    }

    static func scrubbedEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        environment.filter { !$0.key.hasPrefix("REX_") }
    }

    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let generation: Int
    let stdoutMode: StdoutMode
    let newProcessGroup: Bool

    private struct State {
        var started = false
        var pid: pid_t?
        var reaped = false
        var terminationRequested = false
        var termination: ProcessTermination?
        var framer = JSONLineFramer()
        var framingFailed = false
        var collected = Data()
        var stderrRing = Data()
        var stdoutEOF = false
        var stderrEOF = false
        var finished = false
        var exitWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
        var continuation: AsyncStream<ManagedProcessEvent>.Continuation?
        var sources: [DispatchSourceRead] = []
    }

    private let state: Mutex<State>
    private let queue = DispatchQueue(label: "ManagedProcess.io")

    init(
        executable: String,
        arguments: [String],
        environment: [String: String] = ManagedProcess.scrubbedEnvironment(),
        generation: Int = 0,
        stdout: StdoutMode = .lines(maxLineLength: nil),
        newProcessGroup: Bool = false
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = Self.scrubbedEnvironment(environment)
        self.generation = generation
        self.stdoutMode = stdout
        self.newProcessGroup = newProcessGroup
        var initial = State()
        if case .lines(let max) = stdout { initial.framer = JSONLineFramer(maxLineLength: max) }
        state = Mutex(initial)
    }

    var pid: pid_t? { state.withLock { $0.pid } }
    var termination: ProcessTermination? { state.withLock { $0.termination } }
    /// Stdout collected in `.collect` mode (complete once `.exited` has been delivered).
    var collectedStdout: Data { state.withLock { $0.collected } }
    /// The last `stderrCapacity` bytes of stderr, decoded leniently as UTF-8.
    var stderrTail: String { String(decoding: state.withLock { $0.stderrRing }, as: UTF8.self) }
    /// The last non-blank stderr line, trimmed.
    var lastStderrLine: String? {
        stderrTail.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }

    /// Spawns the child. The stream ends after `.exited`. Ending iteration early (consumer
    /// cancelled) terminates the child.
    func start() throws(ManagedProcessError) -> AsyncStream<ManagedProcessEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: ManagedProcessEvent.self)
        let alreadyStarted = state.withLock { state -> Bool in
            if state.started { return true }
            state.started = true
            state.continuation = continuation
            return false
        }
        if alreadyStarted { throw .alreadyStarted }

        let pipes: (out: [Int32], err: [Int32])
        do {
            pipes = (try Self.makePipe(), try Self.makePipe())
        } catch {
            continuation.finish()
            throw error
        }

        let pid: pid_t
        do {
            pid = try spawn(stdoutWrite: pipes.out[1], stderrWrite: pipes.err[1])
        } catch {
            for fd in pipes.out + pipes.err { close(fd) }
            continuation.finish()
            throw error
        }
        close(pipes.out[1])
        close(pipes.err[1])
        state.withLock { $0.pid = pid }

        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination, let self else { return }
            Task { await self.terminate() }
        }

        startReading(fd: pipes.out[0], isStdout: true)
        startReading(fd: pipes.err[0], isStdout: false)
        startReaper(pid: pid)
        return stream
    }

    /// SIGTERM, wait up to one second for the child to be reaped, then SIGKILL. Idempotent.
    /// With `newProcessGroup`, signals go to the whole group, even after the leader has exited.
    func terminate() async {
        guard sendSignal(SIGTERM, markRequested: true) else { return }
        if await waitForExit(timeout: Self.terminateGrace) {
            if newProcessGroup { _ = sendSignal(SIGKILL, markRequested: false) }   // stragglers
            return
        }
        _ = sendSignal(SIGKILL, markRequested: false)
        _ = await waitForExit(timeout: .seconds(5))
    }

    /// True once the child has been reaped; false on timeout or if it was never started.
    func waitForExit(timeout: Duration) async -> Bool {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let resumeNow: Bool? = state.withLock { state in
                if state.reaped { return true }
                if state.pid == nil { return false }
                state.exitWaiters[id] = continuation
                return nil
            }
            if let resumeNow {
                continuation.resume(returning: resumeNow)
                return
            }
            queue.asyncAfter(deadline: .now() + timeout.timeInterval) { [self] in
                let waiter = state.withLock { $0.exitWaiters.removeValue(forKey: id) }
                waiter?.resume(returning: false)
            }
        }
    }

    // MARK: Spawning

    private static func makePipe() throws(ManagedProcessError) -> [Int32] {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw .launchFailed("pipe: \(String(cString: strerror(errno)))") }
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        return fds
    }

    private func spawn(stdoutWrite: Int32, stderrWrite: Int32) throws(ManagedProcessError) -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, stdoutWrite, 1)
        posix_spawn_file_actions_adddup2(&fileActions, stderrWrite, 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        if newProcessGroup {
            flags |= POSIX_SPAWN_SETPGROUP
            posix_spawnattr_setpgroup(&attributes, 0)
        }
        posix_spawnattr_setflags(&attributes, Int16(flags))
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &fileActions, &attributes, argv, envp)
        guard result == 0 else {
            throw .launchFailed("\(executable): \(String(cString: strerror(result)))")
        }
        return pid
    }

    // MARK: I/O

    private func startReading(fd: Int32, isStdout: Bool) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count > 0 {
                    let data = Data(buffer[0..<count])
                    isStdout ? self.handleStdout(data) : self.handleStderr(data)
                    continue
                }
                if count < 0, errno == EINTR { continue }
                if count < 0, errno == EAGAIN { return }
                source.cancel()   // EOF or error
                return
            }
        }
        source.setCancelHandler { [weak self] in
            close(fd)
            self?.handleEOF(isStdout: isStdout)
        }
        state.withLock { $0.sources.append(source) }
        source.resume()
    }

    /// Runs on `queue`.
    private func handleStdout(_ data: Data) {
        var events: [ManagedProcessEvent] = []
        let continuation = state.withLock { state -> AsyncStream<ManagedProcessEvent>.Continuation? in
            guard !state.framingFailed else { return nil }
            switch stdoutMode {
            case .collect(let limit):
                let room = max(0, limit - state.collected.count)
                state.collected.append(data.prefix(room))
            case .lines:
                do throws(FramingError) {
                    events = try state.framer.appendLines(data).map { .line(generation: generation, $0) }
                } catch {
                    state.framingFailed = true
                    events = [.framingError(generation: generation, error)]
                }
            }
            return state.continuation
        }
        for event in events { continuation?.yield(event) }
    }

    /// Runs on `queue`.
    private func handleStderr(_ data: Data) {
        state.withLock { state in
            state.stderrRing.append(data)
            if state.stderrRing.count > Self.stderrCapacity {
                state.stderrRing = Data(state.stderrRing.suffix(Self.stderrCapacity))
            }
        }
    }

    /// Runs on `queue`.
    private func handleEOF(isStdout: Bool) {
        var framingEvent: ManagedProcessEvent?
        let continuation = state.withLock { state -> AsyncStream<ManagedProcessEvent>.Continuation? in
            if isStdout {
                state.stdoutEOF = true
                if case .lines = stdoutMode, !state.framingFailed {
                    do throws(FramingError) {
                        try state.framer.finish()
                    } catch {
                        state.framingFailed = true
                        framingEvent = .framingError(generation: generation, error)
                    }
                }
            } else {
                state.stderrEOF = true
            }
            return state.continuation
        }
        if let framingEvent { continuation?.yield(framingEvent) }
        finishIfComplete()
    }

    private func startReaper(pid: pid_t) {
        let thread = Thread { [weak self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
            self?.reaped(status: status)
        }
        thread.name = "ManagedProcess.reaper"
        thread.start()
    }

    private func reaped(status: Int32) {
        let waiters = state.withLock { state -> [CheckedContinuation<Bool, Never>] in
            let signaled = (status & 0x7F) != 0
            state.termination = ProcessTermination(
                reason: signaled ? .signaled : .exited,
                status: signaled ? status & 0x7F : (status >> 8) & 0xFF,
                terminatedByUs: state.terminationRequested
            )
            state.reaped = true
            let waiters = Array(state.exitWaiters.values)
            state.exitWaiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume(returning: true) }
        queue.async { [self] in finishIfComplete() }
        queue.asyncAfter(deadline: .now() + Self.drainAfterExit.timeInterval) { [self] in
            let sources = state.withLock { $0.sources }
            for source in sources where !source.isCancelled { source.cancel() }
        }
    }

    /// Runs on `queue`. Delivers `.exited` once the child is reaped and both pipes hit EOF.
    private func finishIfComplete() {
        let delivery = state.withLock { state -> (AsyncStream<ManagedProcessEvent>.Continuation, ProcessTermination)? in
            guard !state.finished, state.stdoutEOF, state.stderrEOF,
                  let termination = state.termination, let continuation = state.continuation else { return nil }
            state.finished = true
            state.sources.removeAll()
            return (continuation, termination)
        }
        guard let (continuation, termination) = delivery else { return }
        continuation.yield(.exited(generation: generation, termination))
        continuation.finish()
    }

    /// Returns false if there is nothing left to signal.
    private func sendSignal(_ signal: Int32, markRequested: Bool) -> Bool {
        let target = state.withLock { state -> pid_t? in
            guard let pid = state.pid else { return nil }
            if markRequested, !state.reaped { state.terminationRequested = true }
            if state.reaped { return newProcessGroup ? -pid : nil }
            return newProcessGroup ? -pid : pid
        }
        guard let target else { return false }
        kill(target, signal)
        return true
    }
}

// MARK: One-shot runs

struct ProcessRequest: Equatable, Sendable {
    let executable: String
    let arguments: [String]
    let timeout: Duration
    /// Run in its own process group and kill the group (the login-shell probe).
    var newProcessGroup = false
}

struct ProcessResult: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case exited(Int32)
        case signaled(Int32)
        case timedOut
        case cancelled
        case launchFailed(String)
    }

    let outcome: Outcome
    let stdout: Data
    let stderrTail: String

    init(outcome: Outcome, stdout: Data = Data(), stderrTail: String = "") {
        self.outcome = outcome
        self.stdout = stdout
        self.stderrTail = stderrTail
    }

    var exitCode: Int32? {
        if case .exited(let code) = outcome { code } else { nil }
    }

    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }

    var lastStderrLine: String? {
        stderrTail.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }
}

/// Injectable one-shot runner (CLI resolution, focus, client list).
protocol ProcessRunning: Sendable {
    func run(_ request: ProcessRequest) async -> ProcessResult
}

struct LiveProcessRunner: ProcessRunning {
    /// Runs to completion, or until the timeout or task cancellation, either of which terminates
    /// the child (SIGTERM, 1 s, SIGKILL; the whole group for `newProcessGroup`).
    func run(_ request: ProcessRequest) async -> ProcessResult {
        if Task.isCancelled { return ProcessResult(outcome: .cancelled) }
        let process = ManagedProcess(
            executable: request.executable,
            arguments: request.arguments,
            stdout: .collect(limit: ManagedProcess.collectLimit),
            newProcessGroup: request.newProcessGroup
        )
        let stream: AsyncStream<ManagedProcessEvent>
        do {
            stream = try process.start()
        } catch {
            if case .launchFailed(let message) = error { return ProcessResult(outcome: .launchFailed(message)) }
            return ProcessResult(outcome: .launchFailed(String(describing: error)))
        }

        let timedOut = Mutex(false)
        let timer = Task {
            try await Task.sleep(for: request.timeout)
            timedOut.withLock { $0 = true }
            await process.terminate()
        }
        defer { timer.cancel() }

        var termination: ProcessTermination?
        await withTaskCancellationHandler {
            for await event in stream {
                if case .exited(_, let value) = event { termination = value }
            }
        } onCancel: {
            Task { await process.terminate() }
        }

        let outcome: ProcessResult.Outcome
        if Task.isCancelled {
            // Iteration ends as soon as the task is cancelled; make sure the child is gone.
            await process.terminate()
            outcome = .cancelled
        } else if timedOut.withLock({ $0 }) {
            outcome = .timedOut
        } else if let termination {
            outcome = termination.reason == .exited ? .exited(termination.status) : .signaled(termination.status)
        } else {
            outcome = .cancelled
        }
        return ProcessResult(outcome: outcome, stdout: process.collectedStdout, stderrTail: process.stderrTail)
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
