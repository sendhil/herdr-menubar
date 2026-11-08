import XCTest
@testable import HerdrMenubar

final class ManagedProcessTests: XCTestCase {
    private func collect(_ stream: AsyncStream<ManagedProcessEvent>) async -> [ManagedProcessEvent] {
        var events: [ManagedProcessEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    func testScrubbedEnvironmentRemovesEveryRexVariable() {
        let scrubbed = ManagedProcess.scrubbedEnvironment(["REX_SERVER": "a", "REX_SESSION": "b", "PATH": "/bin",
                                                          "HOME": "/h", "XREX_KEEP": "c", "rex_lower": "d"])
        XCTAssertEqual(scrubbed, ["PATH": "/bin", "HOME": "/h", "XREX_KEEP": "c", "rex_lower": "d"])
    }

    func testChildEnvironmentDoesNotContainRexVariablesByDefault() async {
        setenv("REX_MANAGED_PROCESS_TEST", "1", 1)
        setenv("MANAGED_PROCESS_TEST_KEEP", "1", 1)
        defer {
            unsetenv("REX_MANAGED_PROCESS_TEST")
            unsetenv("MANAGED_PROCESS_TEST_KEEP")
        }
        let result = await LiveProcessRunner().run(ProcessRequest(executable: "/usr/bin/env", arguments: [], timeout: .seconds(5)))
        XCTAssertEqual(result.outcome, .exited(0))
        XCTAssertFalse(result.stdoutText.contains("REX_"))
        XCTAssertTrue(result.stdoutText.contains("MANAGED_PROCESS_TEST_KEEP=1"))
    }

    func testArgumentsArePassedVerbatimWithoutAShell() async {
        let result = await LiveProcessRunner().run(ProcessRequest(
            executable: "/bin/echo", arguments: ["$HOME", "a b", "'q'", "; ls"], timeout: .seconds(5)))
        XCTAssertEqual(result.outcome, .exited(0))
        XCTAssertEqual(result.stdoutText, "$HOME a b 'q' ; ls\n")
    }

    func testOneShotReportsExitCodeStdoutAndLastStderrLine() async {
        let result = await LiveProcessRunner().run(ProcessRequest(
            executable: "/bin/sh", arguments: ["-c", "printf 'out\\n'; printf 'first\\nError: last one\\n\\n' >&2; exit 3"],
            timeout: .seconds(5)))
        XCTAssertEqual(result.outcome, .exited(3))
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.stdoutText, "out\n")
        XCTAssertEqual(result.lastStderrLine, "Error: last one")
    }

    func testLaunchFailureIsReported() async {
        let result = await LiveProcessRunner().run(ProcessRequest(
            executable: "/nonexistent/rex", arguments: ["version"], timeout: .seconds(5)))
        guard case .launchFailed = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertNil(result.exitCode)
    }

    func testOneShotTimeoutTerminatesTheChild() async {
        let started = ContinuousClock.now
        let result = await LiveProcessRunner().run(ProcessRequest(
            executable: "/bin/sleep", arguments: ["30"], timeout: .milliseconds(200)))
        XCTAssertEqual(result.outcome, .timedOut)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
    }

    func testTerminateEscalatesToSIGKILLAfterOneSecond() async throws {
        let process = ManagedProcess(executable: "/bin/sh", arguments: ["-c", "trap '' TERM; echo ready; while :; do sleep 0.05; done"])
        let stream = try process.start()
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, .line(generation: 0, Data("ready".utf8)))
        let started = ContinuousClock.now
        await process.terminate()
        let elapsed = ContinuousClock.now - started
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(900))
        XCTAssertLessThan(elapsed, .seconds(4))
        var last: ManagedProcessEvent?
        while let event = await iterator.next() { last = event }
        XCTAssertEqual(last, .exited(generation: 0, ProcessTermination(reason: .signaled, status: SIGKILL, terminatedByUs: true)))
    }

    func testTerminateSendsSIGTERMFirst() async throws {
        let process = ManagedProcess(executable: "/bin/sh", arguments: ["-c", "echo ready; exec sleep 30"])
        let stream = try process.start()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        let started = ContinuousClock.now
        await process.terminate()
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(900))
        var last: ManagedProcessEvent?
        while let event = await iterator.next() { last = event }
        XCTAssertEqual(last, .exited(generation: 0, ProcessTermination(reason: .signaled, status: SIGTERM, terminatedByUs: true)))
    }

    func testCancellingAOneShotTerminatesTheChild() async {
        let task = Task {
            await LiveProcessRunner().run(ProcessRequest(executable: "/bin/sleep", arguments: ["30"], timeout: .seconds(30)))
        }
        try? await Task.sleep(for: .milliseconds(200))
        let started = ContinuousClock.now
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(3))
    }

    func testCancelledBeforeStartDoesNotSpawn() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await LiveProcessRunner().run(ProcessRequest(executable: "/bin/sleep", arguments: ["30"], timeout: .seconds(30)))
        }
        let result = await task.value
        XCTAssertEqual(result.outcome, .cancelled)
    }

    func testCancellingTheStreamConsumerTerminatesTheChild() async throws {
        let process = ManagedProcess(executable: "/bin/sh", arguments: ["-c", "echo ready; exec sleep 30"])
        let stream = try process.start()
        let consumer = Task {
            for await event in stream { if case .exited = event { return } }
        }
        try await Task.sleep(for: .milliseconds(200))
        consumer.cancel()
        await consumer.value
        let exited = await process.waitForExit(timeout: .seconds(3))
        XCTAssertTrue(exited)
    }

    func testStreamTagsLinesWithGenerationAndExitsLast() async throws {
        let process = ManagedProcess(executable: "/bin/sh", arguments: ["-c", "printf '{\"a\":1}\\r\\n\\n{\"b\":2}\\n'; exit 4"],
                                     generation: 7, stdout: .lines(maxLineLength: 64))
        let events = await collect(try process.start())
        XCTAssertEqual(events, [
            .line(generation: 7, Data(#"{"a":1}"#.utf8)),
            .line(generation: 7, Data(#"{"b":2}"#.utf8)),
            .exited(generation: 7, ProcessTermination(reason: .exited, status: 4, terminatedByUs: false)),
        ])
    }

    func testOversizedLineIsAFramingErrorAndLaterLinesAreDropped() async throws {
        let process = ManagedProcess(executable: "/bin/sh", arguments: ["-c", "echo ok; sleep 0.1; echo 0123456789; echo after"],
                                     generation: 1, stdout: .lines(maxLineLength: 5))
        let events = await collect(try process.start())
        XCTAssertEqual(events.first, .line(generation: 1, Data("ok".utf8)))
        XCTAssertEqual(events.dropFirst().first, .framingError(generation: 1, .lineTooLong(limit: 5)))
        XCTAssertFalse(events.contains(.line(generation: 1, Data("after".utf8))))
        XCTAssertEqual(events.filter { if case .framingError = $0 { true } else { false } }.count, 1)
        guard case .exited = events.last else { return XCTFail("\(events)") }
    }

    func testIncompleteFinalLineIsAFramingError() async throws {
        let process = ManagedProcess(executable: "/bin/sh", arguments: ["-c", "printf '{\"a\"'"], stdout: .lines(maxLineLength: nil))
        let events = await collect(try process.start())
        XCTAssertEqual(events.first, .framingError(generation: 0, .incompleteLine))
    }

    func testStderrIsDrainedIntoABoundedRing() async throws {
        // 64 KiB of stderr must not block the child; only the last 16 KiB are kept.
        let process = ManagedProcess(executable: "/bin/sh", arguments: ["-c", "i=0; while [ $i -lt 1024 ]; do printf '%063d\\n' $i >&2; i=$((i+1)); done; echo tail >&2"])
        let events = await collect(try process.start())
        XCTAssertEqual(events.last, .exited(generation: 0, ProcessTermination(reason: .exited, status: 0, terminatedByUs: false)))
        let tail = process.stderrTail
        XCTAssertLessThanOrEqual(tail.utf8.count, ManagedProcess.stderrCapacity)
        XCTAssertGreaterThan(tail.utf8.count, ManagedProcess.stderrCapacity - 100)
        XCTAssertTrue(tail.hasSuffix("tail\n"))
        XCTAssertEqual(process.lastStderrLine, "tail")
    }

    func testProcessGroupTerminationKillsDescendants() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("mp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        // The background grandchild would outlive a kill of the shell alone.
        let process = ManagedProcess(executable: "/bin/sh",
                                     arguments: ["-c", "sleep 30 & echo $! > '\(pidFile.path)'; echo ready; wait"],
                                     newProcessGroup: true)
        let stream = try process.start()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        let text = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let grandchild = try XCTUnwrap(pid_t(text))
        XCTAssertEqual(kill(grandchild, 0), 0)
        await process.terminate()
        while await iterator.next() != nil {}
        var gone = false
        for _ in 0..<40 {
            if kill(grandchild, 0) != 0 { gone = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(gone, "grandchild \(grandchild) survived the group kill")
    }

    func testRexTimeoutsMatchTheSpec() {
        XCTAssertEqual(RexTimeouts.version, .seconds(2))
        XCTAssertEqual(RexTimeouts.serverStatus, .seconds(3))
        XCTAssertEqual(RexTimeouts.focus, .seconds(5))
        XCTAssertEqual(RexTimeouts.shellProbe, .seconds(3))
        XCTAssertEqual(ManagedProcess.watcherMaxLineLength, 4 * 1024 * 1024)
        XCTAssertEqual(ManagedProcess.stderrCapacity, 16 * 1024)
    }
}
