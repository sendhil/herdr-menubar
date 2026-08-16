import Darwin
import Foundation
import XCTest
@testable import HerdrMenubar

@MainActor
final class WezTermCLITests: XCTestCase {
    func testListResolvesSiblingCLIAndDecodesPaneIdentity() async throws {
        let application = try TemporaryWezTermApplication()
        defer { application.remove() }
        let runner = FakeBoundedProcessRunner(results: [
            .success(ProcessResult(
                stdout: Data("""
                [
                  {"window_id": 11, "tab_id": 22, "pane_id": 33, "title": "first"},
                  {"window_id": 44, "tab_id": 55, "pane_id": 66, "title": "second"}
                ]
                """.utf8),
                stderr: Data(),
                exitStatus: 0
            ))
        ])
        let cli = LiveWezTermCLI(
            runner: runner,
            bundleURL: { application.appURL }
        )

        let panes = try await cli.listPanes()

        XCTAssertEqual(panes, [
            WezTermPane(windowID: 11, tabID: 22, paneID: 33, title: "first"),
            WezTermPane(windowID: 44, tabID: 55, paneID: 66, title: "second")
        ])
        let invocations = await runner.invocations()
        let invocation = try XCTUnwrap(invocations.only)
        XCTAssertEqual(invocation.executableURL, application.cliURL)
        XCTAssertEqual(invocation.arguments, ["cli", "list", "--format", "json"])
    }

    func testActivatePaneUsesExactIntegerPaneIDAndOneSecondDeadline() async throws {
        let application = try TemporaryWezTermApplication()
        defer { application.remove() }
        let runner = FakeBoundedProcessRunner(results: [
            .success(ProcessResult(stdout: Data("ignored".utf8), stderr: Data(), exitStatus: 0))
        ])
        let cli = LiveWezTermCLI(runner: runner, bundleURL: { application.appURL })

        try await cli.activatePane(id: 9_007_199_254_740_991)

        let invocations = await runner.invocations()
        let invocation = try XCTUnwrap(invocations.only)
        XCTAssertEqual(
            invocation.arguments,
            ["cli", "activate-pane", "--pane-id", "9007199254740991"]
        )
        XCTAssertEqual(invocation.deadline, .seconds(1))
        XCTAssertEqual(invocation.stdoutLimit, 256 * 1024)
        XCTAssertEqual(invocation.stderrLimit, 256 * 1024)
    }

    func testMissingApplicationThrowsUnavailableWithoutRunningProcess() async {
        let runner = FakeBoundedProcessRunner(results: [])
        let cli = LiveWezTermCLI(runner: runner, bundleURL: { nil })

        await assertError(.unavailable) {
            _ = try await cli.listPanes()
        }
        let invocations = await runner.invocations()
        XCTAssertTrue(invocations.isEmpty)
    }

    func testMissingSiblingCLIThrowsUnavailableWithoutPATHFallback() async {
        let application: TemporaryWezTermApplication
        do {
            application = try TemporaryWezTermApplication(createCLI: false)
        } catch {
            return XCTFail("Could not create temporary app: \(error)")
        }
        defer { application.remove() }
        let runner = FakeBoundedProcessRunner(results: [])
        let cli = LiveWezTermCLI(runner: runner, bundleURL: { application.appURL })

        await assertError(.unavailable) {
            _ = try await cli.listPanes()
        }
        let invocations = await runner.invocations()
        XCTAssertTrue(invocations.isEmpty)
    }

    func testBundleEntryPointWeztermGUIIsNeverExecuted() async {
        let application: TemporaryWezTermApplication
        do {
            application = try TemporaryWezTermApplication()
        } catch {
            return XCTFail("Could not create temporary app: \(error)")
        }
        defer { application.remove() }
        let runner = FakeBoundedProcessRunner(results: [
            .success(ProcessResult(stdout: Data("[]".utf8), stderr: Data(), exitStatus: 0))
        ])
        let cli = LiveWezTermCLI(runner: runner, bundleURL: { application.appURL })

        do {
            _ = try await cli.listPanes()
        } catch {
            return XCTFail("Unexpected error: \(error)")
        }

        let invocations = await runner.invocations()
        let executable = invocations.only?.executableURL
        XCTAssertEqual(executable, application.cliURL)
        XCTAssertNotEqual(executable, application.guiURL)
    }

    func testNonExecutableSiblingCLIThrowsUnavailable() async {
        let application: TemporaryWezTermApplication
        do {
            application = try TemporaryWezTermApplication(cliIsExecutable: false)
        } catch {
            return XCTFail("Could not create temporary app: \(error)")
        }
        defer { application.remove() }
        let runner = FakeBoundedProcessRunner(results: [])
        let cli = LiveWezTermCLI(runner: runner, bundleURL: { application.appURL })

        await assertError(.unavailable) {
            try await cli.activatePane(id: 7)
        }
        let invocations = await runner.invocations()
        XCTAssertTrue(invocations.isEmpty)
    }

    func testListNonzeroExitThrowsControlFailureWithoutExposingStderr() async {
        let application: TemporaryWezTermApplication
        do {
            application = try TemporaryWezTermApplication()
        } catch {
            return XCTFail("Could not create temporary app: \(error)")
        }
        defer { application.remove() }
        let secret = "private wezterm stderr"
        let runner = FakeBoundedProcessRunner(results: [
            .success(ProcessResult(
                stdout: Data(),
                stderr: Data(secret.utf8),
                exitStatus: 17
            )),
            .failure(BoundedProcessError.launchFailed)
        ])
        let cli = LiveWezTermCLI(runner: runner, bundleURL: { application.appURL })

        let nonzeroError = await capturedError {
            _ = try await cli.listPanes()
        }
        XCTAssertEqual(nonzeroError as? WezTermCLIError, .controlFailed)
        XCTAssertFalse(String(describing: nonzeroError).contains(secret))

        await assertError(.unavailable) {
            _ = try await cli.listPanes()
        }
    }

    func testMalformedUTF8AndJSONThrowMalformedOutput() async {
        let application: TemporaryWezTermApplication
        do {
            application = try TemporaryWezTermApplication()
        } catch {
            return XCTFail("Could not create temporary app: \(error)")
        }
        defer { application.remove() }
        let runner = FakeBoundedProcessRunner(results: [
            .success(ProcessResult(stdout: Data([0xFF]), stderr: Data(), exitStatus: 0)),
            .success(ProcessResult(stdout: Data("{}".utf8), stderr: Data(), exitStatus: 0))
        ])
        let cli = LiveWezTermCLI(runner: runner, bundleURL: { application.appURL })

        await assertError(.malformedOutput) {
            _ = try await cli.listPanes()
        }
        await assertError(.malformedOutput) {
            _ = try await cli.listPanes()
        }
    }

    func testListUsesFiveHundredMillisecondDeadlineAndIndependent256KiBLimits() async throws {
        let application = try TemporaryWezTermApplication()
        defer { application.remove() }
        let runner = FakeBoundedProcessRunner(results: [
            .success(ProcessResult(stdout: Data("[]".utf8), stderr: Data(), exitStatus: 0))
        ])
        let cli = LiveWezTermCLI(runner: runner, bundleURL: { application.appURL })

        _ = try await cli.listPanes()

        let invocations = await runner.invocations()
        let invocation = try XCTUnwrap(invocations.only)
        XCTAssertEqual(invocation.deadline, .milliseconds(500))
        XCTAssertEqual(invocation.stdoutLimit, 256 * 1024)
        XCTAssertEqual(invocation.stderrLimit, 256 * 1024)
    }

    func testListCapsProcessInvocationToCallerRemainingLookupBudget() async throws {
        let application = try TemporaryWezTermApplication()
        defer { application.remove() }
        let runner = FakeBoundedProcessRunner(results: [
            .success(ProcessResult(stdout: Data("[]".utf8), stderr: Data(), exitStatus: 0)),
            .success(ProcessResult(stdout: Data("[]".utf8), stderr: Data(), exitStatus: 0))
        ])
        let cli = LiveWezTermCLI(runner: runner, bundleURL: { application.appURL })

        _ = try await cli.listPanes(timeout: .milliseconds(125))
        _ = try await cli.listPanes(timeout: .seconds(2))

        let invocations = await runner.invocations()
        XCTAssertEqual(invocations.map(\.deadline), [.milliseconds(125), .milliseconds(500)])
    }

    private func assertError(
        _ expected: WezTermCLIError,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let error = await capturedError(operation: operation)
        XCTAssertEqual(error as? WezTermCLIError, expected, file: file, line: line)
    }

    private func capturedError(
        operation: () async throws -> Void
    ) async -> Error? {
        do {
            try await operation()
            return nil
        } catch {
            return error
        }
    }
}

private actor FakeBoundedProcessRunner: BoundedProcessRunning {
    private var queuedResults: [Result<ProcessResult, Error>]
    private var recordedInvocations: [ProcessInvocation] = []

    init(results: [Result<ProcessResult, Error>]) {
        queuedResults = results
    }

    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        recordedInvocations.append(invocation)
        guard !queuedResults.isEmpty else {
            throw BoundedProcessError.launchFailed
        }
        return try queuedResults.removeFirst().get()
    }

    func invocations() -> [ProcessInvocation] {
        recordedInvocations
    }
}

private struct TemporaryWezTermApplication {
    let rootURL: URL
    let appURL: URL
    let cliURL: URL
    let guiURL: URL

    init(
        createCLI: Bool = true,
        cliIsExecutable: Bool = true
    ) throws {
        let fileManager = FileManager.default
        rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("HerdrMenubar-WezTermCLI-\(UUID().uuidString)")
        appURL = rootURL.appendingPathComponent("WezTerm.app")
        let executableDirectory = appURL.appendingPathComponent("Contents/MacOS")
        cliURL = executableDirectory.appendingPathComponent("wezterm")
        guiURL = executableDirectory.appendingPathComponent("wezterm-gui")

        try fileManager.createDirectory(
            at: executableDirectory,
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: guiURL)
        guard chmod(guiURL.path, 0o700) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard createCLI else { return }
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: cliURL)
        if cliIsExecutable {
            guard chmod(cliURL.path, 0o700) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? self[0] : nil
    }
}
