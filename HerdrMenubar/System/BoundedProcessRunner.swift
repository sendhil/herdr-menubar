import Darwin
import Foundation

struct ProcessInvocation: Sendable {
    let executableURL: URL
    let arguments: [String]
    let deadline: Duration
    let stdoutLimit: Int
    let stderrLimit: Int
}

struct ProcessResult: Equatable, Sendable {
    let stdout: Data
    let stderr: Data
    let exitStatus: Int32
}

enum BoundedProcessError: Error, Equatable, Sendable {
    case launchFailed
    case timedOut
    case stdoutLimitExceeded
    case stderrLimitExceeded
    case cancelled
}

protocol BoundedProcessRunning: Sendable {
    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult
}

struct BoundedProcessRunner: BoundedProcessRunning {
    private let launchObserver: @Sendable (Int32) -> Void

    init(launchObserver: @escaping @Sendable (Int32) -> Void = { _ in }) {
        self.launchObserver = launchObserver
    }

    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        guard !Task.isCancelled else {
            throw BoundedProcessError.cancelled
        }
        let (events, eventContinuation) = AsyncStream<ProcessEvent>.makeStream()
        let execution = ProcessExecutionRecord(eventContinuation: eventContinuation)
        let token = execution.token

        do {
            try await execution.launch(invocation, observer: launchObserver)
        } catch {
            await execution.closeHandles(token: token)
            eventContinuation.finish()
            throw BoundedProcessError.launchFailed
        }

        let exitMonitor = await execution.startExitMonitor(token: token)
        let readers = await execution.startReaders(
            stdoutLimit: invocation.stdoutLimit,
            stderrLimit: invocation.stderrLimit,
            token: token
        )
        let deadlineTask = Task {
            do {
                try await Task.sleep(for: invocation.deadline)
                if !Task.isCancelled {
                    eventContinuation.yield(.failure(.timedOut, token))
                }
            } catch {
                // Cancellation is expected during normal finalization.
            }
        }

        var stdout: Data?
        var stderr: Data?
        var exitStatus: Int32?
        var terminalError: BoundedProcessError?

        var iterator = events.makeAsyncIterator()
        while stdout == nil || stderr == nil || exitStatus == nil {
            if Task.isCancelled {
                terminalError = await execution.claimTerminalError(.cancelled, token: token)
                break
            }

            guard let event = await iterator.next() else {
                terminalError = await execution.claimTerminalError(.cancelled, token: token)
                break
            }

            guard event.token == token else { continue }
            switch event {
            case let .stdout(data, _):
                stdout = data
            case let .stderr(data, _):
                stderr = data
            case let .exited(status, _):
                exitStatus = status
            case let .failure(error, _):
                terminalError = await execution.claimTerminalError(error, token: token)
            }

            if terminalError != nil { break }
        }

        deadlineTask.cancel()
        _ = await deadlineTask.result

        if let terminalError {
            if await execution.claimCleanup(token: token) {
                await execution.terminate(token: token)
                let graceTask = Task {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                await graceTask.value
                await execution.forceKillIfRunning(token: token)
                _ = await execution.waitForTermination(token: token)
            }
            await execution.closeHandles(token: token)
            _ = await readers.stdout.result
            _ = await readers.stderr.result
            _ = await exitMonitor.result
            eventContinuation.finish()
            throw terminalError
        }

        _ = await readers.stdout.result
        _ = await readers.stderr.result
        _ = await exitMonitor.result
        await execution.closeHandles(token: token)
        eventContinuation.finish()

        guard let stdout, let stderr, let exitStatus else {
            throw BoundedProcessError.cancelled
        }
        return ProcessResult(stdout: stdout, stderr: stderr, exitStatus: exitStatus)
    }
}

private enum ProcessEvent: Sendable {
    case stdout(Data, UUID)
    case stderr(Data, UUID)
    case exited(Int32, UUID)
    case failure(BoundedProcessError, UUID)

    var token: UUID {
        switch self {
        case let .stdout(_, token), let .stderr(_, token), let .exited(_, token), let .failure(_, token):
            token
        }
    }
}

private actor ProcessExecutionRecord {
    let token = UUID()

    private var pid: pid_t?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private let termination = ProcessTerminationLatch()
    private let eventContinuation: AsyncStream<ProcessEvent>.Continuation
    private var terminalError: BoundedProcessError?
    private var cleanupClaimed = false

    init(eventContinuation: AsyncStream<ProcessEvent>.Continuation) {
        self.eventContinuation = eventContinuation
    }

    func launch(
        _ invocation: ProcessInvocation,
        observer: @Sendable (Int32) -> Void
    ) throws {
        var stdoutDescriptors: [Int32] = [-1, -1]
        var stderrDescriptors: [Int32] = [-1, -1]
        guard Darwin.pipe(&stdoutDescriptors) == 0 else {
            throw BoundedProcessError.launchFailed
        }
        guard Darwin.pipe(&stderrDescriptors) == 0 else {
            closeDescriptor(&stdoutDescriptors[0])
            closeDescriptor(&stdoutDescriptors[1])
            throw BoundedProcessError.launchFailed
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var signalMask = sigset_t()
        sigemptyset(&signalMask)
        var launched = false
        defer {
            if actions != nil { posix_spawn_file_actions_destroy(&actions) }
            if attributes != nil { posix_spawnattr_destroy(&attributes) }
            if !launched {
                closeDescriptor(&stdoutDescriptors[0])
                closeDescriptor(&stdoutDescriptors[1])
                closeDescriptor(&stderrDescriptors[0])
                closeDescriptor(&stderrDescriptors[1])
            }
        }

        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0,
              posix_spawnattr_setsigmask(&attributes, &signalMask) == 0,
              posix_spawnattr_setflags(
                  &attributes,
                  Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK)
              ) == 0,
              posix_spawn_file_actions_adddup2(&actions, stdoutDescriptors[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, stderrDescriptors[1], STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, stdoutDescriptors[0]) == 0,
              posix_spawn_file_actions_addclose(&actions, stdoutDescriptors[1]) == 0,
              posix_spawn_file_actions_addclose(&actions, stderrDescriptors[0]) == 0,
              posix_spawn_file_actions_addclose(&actions, stderrDescriptors[1]) == 0
        else {
            throw BoundedProcessError.launchFailed
        }

        var childPID: pid_t = 0
        let executablePath = invocation.executableURL.path
        let spawnResult = spawn(
            executablePath: executablePath,
            arguments: invocation.arguments,
            actions: &actions,
            attributes: &attributes,
            childPID: &childPID
        )
        guard spawnResult == 0 else {
            throw BoundedProcessError.launchFailed
        }

        launched = true
        closeDescriptor(&stdoutDescriptors[1])
        closeDescriptor(&stderrDescriptors[1])
        stdoutHandle = FileHandle(fileDescriptor: stdoutDescriptors[0], closeOnDealloc: true)
        stderrHandle = FileHandle(fileDescriptor: stderrDescriptors[0], closeOnDealloc: true)
        stdoutDescriptors[0] = -1
        stderrDescriptors[0] = -1
        pid = childPID
        observer(childPID)
    }

    func startExitMonitor(token: UUID) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                if reapIfExited(token: token) { return }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
    }

    func startReaders(
        stdoutLimit: Int,
        stderrLimit: Int,
        token: UUID
    ) -> (stdout: Task<Void, Never>, stderr: Task<Void, Never>) {
        guard let stdoutHandle, let stderrHandle else {
            let stdoutFailure = Task { _ = eventContinuation.yield(.failure(.launchFailed, token)) }
            let stderrFailure = Task { _ = eventContinuation.yield(.failure(.launchFailed, token)) }
            return (stdoutFailure, stderrFailure)
        }
        let events = eventContinuation
        let stdoutTask = Task.detached {
            do {
                let data = try Self.read(stdoutHandle, limit: stdoutLimit, overflow: .stdoutLimitExceeded)
                events.yield(.stdout(data, token))
            } catch let error as BoundedProcessError {
                events.yield(.failure(error, token))
            } catch {
                events.yield(.failure(.launchFailed, token))
            }
        }
        let stderrTask = Task.detached {
            do {
                let data = try Self.read(stderrHandle, limit: stderrLimit, overflow: .stderrLimitExceeded)
                events.yield(.stderr(data, token))
            } catch let error as BoundedProcessError {
                events.yield(.failure(error, token))
            } catch {
                events.yield(.failure(.launchFailed, token))
            }
        }
        return (stdoutTask, stderrTask)
    }

    func claimTerminalError(_ error: BoundedProcessError, token: UUID) -> BoundedProcessError {
        guard token == self.token else { return error }
        if terminalError == nil {
            terminalError = error
        }
        return terminalError ?? error
    }

    func claimCleanup(token: UUID) -> Bool {
        guard token == self.token, !cleanupClaimed else { return false }
        cleanupClaimed = true
        return true
    }

    func terminate(token: UUID) {
        signalIfUnreaped(SIGTERM, token: token)
    }

    func forceKillIfRunning(token: UUID) {
        signalIfUnreaped(SIGKILL, token: token)
    }

    func waitForTermination(token: UUID) async -> Int32? {
        guard token == self.token else { return nil }
        return await termination.wait()
    }

    func closeHandles(token: UUID) {
        guard token == self.token else { return }
        try? stdoutHandle?.close()
        try? stderrHandle?.close()
        stdoutHandle = nil
        stderrHandle = nil
    }

    private func signalIfUnreaped(_ signal: Int32, token: UUID) {
        guard token == self.token, !reapIfExited(token: token), let pid else { return }
        Darwin.kill(pid, signal)
    }

    private func reapIfExited(token: UUID) -> Bool {
        guard token == self.token else { return true }
        guard let pid else { return true }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid {
            recordReaped(status: status, token: token)
            return true
        }
        if result == -1, errno == EINTR {
            return false
        }
        if result == -1 {
            recordReaped(status: 1 << 8, token: token)
            return true
        }
        return false
    }

    private func recordReaped(status: Int32, token: UUID) {
        guard token == self.token, pid != nil else { return }
        pid = nil
        let exitStatus = decodedExitStatus(status)
        termination.resume(exitStatus)
        eventContinuation.yield(.exited(exitStatus, token))
    }

    private func decodedExitStatus(_ status: Int32) -> Int32 {
        let terminatingSignal = status & 0x7f
        if terminatingSignal == 0 {
            return (status >> 8) & 0xff
        }
        return 128 + terminatingSignal
    }

    private func spawn(
        executablePath: String,
        arguments: [String],
        actions: inout posix_spawn_file_actions_t?,
        attributes: inout posix_spawnattr_t?,
        childPID: inout pid_t
    ) -> Int32 {
        var argumentPointers = ([executablePath] + arguments).map { strdup($0) }
        guard !argumentPointers.contains(where: { $0 == nil }) else {
            argumentPointers.forEach { free($0) }
            return ENOMEM
        }
        argumentPointers.append(nil)
        defer { argumentPointers.forEach { free($0) } }

        return executablePath.withCString { path in
            argumentPointers.withUnsafeBufferPointer { argv in
                posix_spawn(
                    &childPID,
                    path,
                    &actions,
                    &attributes,
                    argv.baseAddress,
                    environ
                )
            }
        }
    }

    private func closeDescriptor(_ descriptor: inout Int32) {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    nonisolated private static func read(
        _ handle: FileHandle,
        limit: Int,
        overflow: BoundedProcessError
    ) throws -> Data {
        var result = Data()
        while true {
            let remaining = max(0, limit - result.count)
            let chunk = try handle.read(upToCount: min(16_384, remaining + 1)) ?? Data()
            if chunk.isEmpty { return result }
            guard chunk.count <= remaining else { throw overflow }
            result.append(chunk)
        }
    }
}

private final class ProcessTerminationLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if let status {
                    continuation.resume(returning: status)
                } else {
                    precondition(self.continuation == nil)
                    self.continuation = continuation
                }
            }
        }
    }

    func resume(_ status: Int32) {
        let continuation = lock.withLock { () -> CheckedContinuation<Int32, Never>? in
            guard self.status == nil else { return nil }
            self.status = status
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: status)
    }
}
