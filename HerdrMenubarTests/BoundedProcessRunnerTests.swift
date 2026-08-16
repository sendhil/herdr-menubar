import Darwin
import Foundation
import XCTest
@testable import HerdrMenubar

final class BoundedProcessRunnerTests: XCTestCase {
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
        let pids = PIDRecorder()
        let runner = BoundedProcessRunner(launchObserver: { pids.record($0) })
        let request = invocation(
            command: "while :; do printf '0123456789abcdef'; printf 'fedcba9876543210' >&2; done",
            deadline: .seconds(1),
            stdoutLimit: 64,
            stderrLimit: 64
        )

        do {
            _ = try await runner.run(request)
            XCTFail("Expected one output limit to win the terminal-error race")
        } catch let error as BoundedProcessError {
            XCTAssertTrue(
                error == .stdoutLimitExceeded || error == .stderrLimitExceeded,
                "Unexpected error: \(error)"
            )
        } catch {
            XCTFail("Expected BoundedProcessError, got \(error)")
        }

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
        trap '' TERM
        while :; do :; done
        """)
        defer { fixture.remove() }
        let pids = PIDRecorder()
        let runner = BoundedProcessRunner(launchObserver: { pids.record($0) })
        let request = ProcessInvocation(
            executableURL: fixture.url,
            arguments: [],
            deadline: .milliseconds(40),
            stdoutLimit: 1_024,
            stderrLimit: 1_024
        )

        await assertRun(request, with: runner, throws: .timedOut)
        assertRecordedProcessWasReaped(pids)
    }

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
