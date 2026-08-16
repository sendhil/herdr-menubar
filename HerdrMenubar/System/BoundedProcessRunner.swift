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
        let (events, eventContinuation) = AsyncStream<ProcessEvent>.makeStream()
        let execution = ProcessExecutionRecord(eventContinuation: eventContinuation)
        let token = execution.token

        do {
            try await execution.launch(invocation, observer: launchObserver)
        } catch {
            await execution.closeHandlesAndClearHandler(token: token)
            eventContinuation.finish()
            throw BoundedProcessError.launchFailed
        }

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
            await execution.clearTerminationHandler(token: token)
            eventContinuation.finish()
            throw terminalError
        }

        _ = await readers.stdout.result
        _ = await readers.stderr.result
        await execution.closeHandlesAndClearHandler(token: token)
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

    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private let termination = ProcessTerminationLatch()
    private let eventContinuation: AsyncStream<ProcessEvent>.Continuation
    private var terminalError: BoundedProcessError?
    private var cleanupClaimed = false

    init(eventContinuation: AsyncStream<ProcessEvent>.Continuation) {
        self.eventContinuation = eventContinuation
        stdoutHandle = stdoutPipe.fileHandleForReading
        stderrHandle = stderrPipe.fileHandleForReading
        let termination = self.termination
        let token = self.token
        process.terminationHandler = { process in
            let status = process.terminationStatus
            termination.resume(status)
            eventContinuation.yield(.exited(status, token))
        }
    }

    func launch(
        _ invocation: ProcessInvocation,
        observer: @Sendable (Int32) -> Void
    ) throws {
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            throw BoundedProcessError.launchFailed
        }
        observer(process.processIdentifier)
    }

    func startReaders(
        stdoutLimit: Int,
        stderrLimit: Int,
        token: UUID
    ) -> (stdout: Task<Void, Never>, stderr: Task<Void, Never>) {
        let stdoutHandle = self.stdoutHandle
        let stderrHandle = self.stderrHandle
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
        guard token == self.token, process.isRunning else { return }
        process.terminate()
    }

    func forceKillIfRunning(token: UUID) {
        guard token == self.token, process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
    }

    func waitForTermination(token: UUID) async -> Int32? {
        guard token == self.token else { return nil }
        return await termination.wait()
    }

    func closeHandles(token: UUID) {
        guard token == self.token else { return }
        try? stdoutHandle.close()
        try? stderrHandle.close()
    }

    func clearTerminationHandler(token: UUID) {
        guard token == self.token else { return }
        process.terminationHandler = nil
    }

    func closeHandlesAndClearHandler(token: UUID) {
        closeHandles(token: token)
        clearTerminationHandler(token: token)
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
