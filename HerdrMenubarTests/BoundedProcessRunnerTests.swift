import Darwin
import Foundation
import XCTest
@testable import HerdrMenubar

final class BoundedProcessRunnerTests: XCTestCase {
    func testCancellationBeforeRunDoesNotLaunchProcess() async {
        let gate = CancellationGate()
        let pids = PIDRecorder()
        let runner = BoundedProcessRunner(launchObserver: { pids.record($0) })
        let request = invocation(command: "exit 0")
        let task = Task {
            await gate.wait()
            return try await runner.run(request)
        }
        await gate.waitUntilBlocked()

        task.cancel()
        await gate.open()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation before launch")
        } catch let error as BoundedProcessError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Expected BoundedProcessError.cancelled, got \(error)")
        }
        XCTAssertTrue(pids.values.isEmpty)
    }

    func testCapturesStdoutStderrAndExitStatusConcurrently() async throws {
        let runner = BoundedProcessRunner()

        let result = try await runner.run(invocation(
            command: "printf 'known stdout'; printf 'known stderr' >&2"
        ))

        XCTAssertEqual(String(data: result.stdout, encoding: .utf8), "known stdout")
        XCTAssertEqual(String(data: result.stderr, encoding: .utf8), "known stderr")
        XCTAssertEqual(result.exitStatus, 0)
    }

    func testNonzeroExitReturnsCapturedResultForCallerClassification() async throws {
        let runner = BoundedProcessRunner()

        let result = try await runner.run(invocation(
            command: "printf 'out'; printf 'err' >&2; exit 23"
        ))

        XCTAssertEqual(result, ProcessResult(
            stdout: Data("out".utf8),
            stderr: Data("err".utf8),
            exitStatus: 23
        ))
    }

    func testStdoutLimitTerminatesAndReapsProcess() async {
        let pids = PIDRecorder()
        let runner = BoundedProcessRunner(launchObserver: { pids.record($0) })
        let request = invocation(
            command: "while :; do printf '0123456789abcdef'; printf 'e' >&2; done",
            deadline: .seconds(1),
            stdoutLimit: 64,
            stderrLimit: 100_000
        )

        await assertRun(request, with: runner, throws: .stdoutLimitExceeded)
        assertRecordedProcessWasReaped(pids)
    }

    func testStderrLimitTerminatesAndReapsProcess() async {
        let pids = PIDRecorder()
        let runner = BoundedProcessRunner(launchObserver: { pids.record($0) })
        let request = invocation(
            command: "while :; do printf 'o'; printf '0123456789abcdef' >&2; done",
            deadline: .seconds(1),
            stdoutLimit: 100_000,
            stderrLimit: 64
        )

        await assertRun(request, with: runner, throws: .stderrLimitExceeded)
        assertRecordedProcessWasReaped(pids)
    }

    func testSimultaneousStdoutAndStderrOverflowTerminatesExactlyOnce() async {
        let fixture: TemporaryExecutable
        do {
            fixture = try TemporaryExecutable(contents: Self.synchronizedOverflowFixture)
        } catch {
            return XCTFail("Could not create synchronized fixture: \(error)")
        }
        defer { fixture.remove() }
        let termMarker = fixture.directoryURL.appendingPathComponent("term-count")
        let readyMarker = fixture.directoryURL.appendingPathComponent("ready")
        let pids = PIDRecorder()
        let runner = BoundedProcessRunner(launchObserver: { pids.record($0) })
        let request = ProcessInvocation(
            executableURL: fixture.url,
            arguments: [termMarker.path, readyMarker.path],
            deadline: .seconds(1),
            stdoutLimit: 64,
            stderrLimit: 64
        )
        let task = Task { try await runner.run(request) }

        await assertFileAppears(readyMarker, within: .seconds(1))
        let clock = ContinuousClock()
        let started = clock.now

        do {
            _ = try await task.value
            XCTFail("Expected one output limit to win the terminal-error race")
        } catch let error as BoundedProcessError {
            XCTAssertTrue(
                error == .stdoutLimitExceeded || error == .stderrLimitExceeded,
                "Unexpected error: \(error)"
            )
        } catch {
            XCTFail("Expected BoundedProcessError, got \(error)")
        }

        let elapsed = started.duration(to: clock.now)
        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertEqual(try? String(contentsOf: termMarker, encoding: .utf8), "term\n")
        XCTAssertEqual(pids.values.count, 1)
        assertRecordedProcessWasReaped(pids)
    }

    func testDeadlineTerminatesAndReapsProcess() async {
        let pids = PIDRecorder()
        let runner = BoundedProcessRunner(launchObserver: { pids.record($0) })
        let request = invocation(
            command: "while :; do :; done",
            deadline: .milliseconds(40)
        )

        await assertRun(request, with: runner, throws: .timedOut)
        assertRecordedProcessWasReaped(pids)
    }

    func testCancellationTerminatesAndReapsProcess() async {
        let pids = PIDRecorder()
        let runner = BoundedProcessRunner(launchObserver: { pids.record($0) })
        let request = invocation(
            command: "while :; do :; done",
            deadline: .seconds(5)
        )
        let task = Task { try await runner.run(request) }
        await waitForLaunch(pids)

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch let error as BoundedProcessError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Expected BoundedProcessError.cancelled, got \(error)")
        }
        assertRecordedProcessWasReaped(pids)
    }

    func testChildIgnoringTerminateIsKilledAfterGraceAndReaped() async throws {
        let fixture = try TemporaryExecutable(contents: """
        #!/bin/sh
        term_marker="$1"
        ready_marker="$2"
        trap 'printf "term\\n" >> "$term_marker"' TERM
        printf ready > "$ready_marker"
        while :; do :; done
        """)
        defer { fixture.remove() }
        let termMarker = fixture.directoryURL.appendingPathComponent("term-count")
        let readyMarker = fixture.directoryURL.appendingPathComponent("ready")
        let pids = PIDRecorder()
        let runner = BoundedProcessRunner(launchObserver: { pids.record($0) })
        let request = ProcessInvocation(
            executableURL: fixture.url,
            arguments: [termMarker.path, readyMarker.path],
            deadline: .seconds(5),
            stdoutLimit: 1_024,
            stderrLimit: 1_024
        )
        let task = Task { try await runner.run(request) }
        await assertFileAppears(readyMarker, within: .seconds(1))
        let clock = ContinuousClock()
        let cancelledAt = clock.now

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch let error as BoundedProcessError {
            XCTAssertEqual(error, .cancelled)
        }
        let elapsed = cancelledAt.duration(to: clock.now)
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(90))
        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertEqual(try String(contentsOf: termMarker, encoding: .utf8), "term\n")
        assertRecordedProcessWasReaped(pids)
    }

    private func assertFileAppears(
        _ url: URL,
        within timeout: Duration,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !FileManager.default.fileExists(atPath: url.path), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), file: file, line: line)
    }

    private static let synchronizedOverflowFixture = """
    #!/usr/bin/python3
    import os
    import signal
    import sys
    import threading
    import time

    term_marker, ready_marker = sys.argv[1:3]

    def on_term(_signal, _frame):
        with open(term_marker, "ab", buffering=0) as marker:
            marker.write(b"term\\n")

    signal.signal(signal.SIGTERM, on_term)
    barrier = threading.Barrier(3)

    def write_stream(fd, byte):
        barrier.wait()
        os.write(fd, byte * 4096)

    stdout_writer = threading.Thread(target=write_stream, args=(1, b"o"))
    stderr_writer = threading.Thread(target=write_stream, args=(2, b"e"))
    stdout_writer.start()
    stderr_writer.start()
    with open(ready_marker, "wb", buffering=0) as marker:
        marker.write(b"ready")
    barrier.wait()
    stdout_writer.join()
    stderr_writer.join()
    while True:
        time.sleep(0.01)
    """

    private func invocation(
        command: String,
        deadline: Duration = .seconds(1),
        stdoutLimit: Int = 4_096,
        stderrLimit: Int = 4_096
    ) -> ProcessInvocation {
        ProcessInvocation(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", command],
            deadline: deadline,
            stdoutLimit: stdoutLimit,
            stderrLimit: stderrLimit
        )
    }

    private func assertRun(
        _ invocation: ProcessInvocation,
        with runner: BoundedProcessRunner,
        throws expected: BoundedProcessError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await runner.run(invocation)
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as BoundedProcessError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected BoundedProcessError, got \(error)", file: file, line: line)
        }
    }

    private func waitForLaunch(_ recorder: PIDRecorder) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while recorder.values.isEmpty, clock.now < deadline {
            await Task.yield()
        }
        XCTAssertEqual(recorder.values.count, 1)
    }

    private func assertRecordedProcessWasReaped(
        _ recorder: PIDRecorder,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let pid = recorder.values.only else {
            return XCTFail("Expected exactly one launched PID", file: file, line: line)
        }
        errno = 0
        XCTAssertEqual(kill(pid, 0), -1, file: file, line: line)
        XCTAssertEqual(errno, ESRCH, file: file, line: line)
    }
}

private final class PIDRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int32] = []

    var values: [Int32] {
        lock.withLock { storage }
    }

    func record(_ pid: Int32) {
        lock.withLock { storage.append(pid) }
    }
}

private actor CancellationGate {
    private var blocked = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var blockedContinuation: CheckedContinuation<Void, Never>?

    func wait() async {
        blocked = true
        blockedContinuation?.resume()
        blockedContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilBlocked() async {
        if blocked { return }
        await withCheckedContinuation { continuation in
            blockedContinuation = continuation
        }
    }

    func open() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private struct TemporaryExecutable {
    let directoryURL: URL
    let url: URL

    init(contents: String) throws {
        let manager = FileManager.default
        directoryURL = manager.temporaryDirectory
            .appendingPathComponent("herdr-process-tests-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directoryURL, withIntermediateDirectories: false)
        url = directoryURL.appendingPathComponent("fixture")
        try Data(contents.utf8).write(to: url)
        guard chmod(url.path, 0o700) == 0 else {
            throw POSIXError(.EACCES)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
