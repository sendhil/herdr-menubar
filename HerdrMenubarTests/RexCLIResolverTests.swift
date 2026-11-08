import Synchronization
import XCTest
@testable import HerdrMenubar

final class RexCLIResolverTests: XCTestCase {
    private let home = "/Users/u"
    private var versions: String { "\(home)/Library/Application Support/com.superlogical.rex/RexServer/Versions" }
    private func versioned(_ dir: String) -> String { "\(versions)/\(dir)/Rex Server.app/Contents/MacOS/rex" }

    private static func versionOutput(_ version: String, api: Int) -> String {
        "rex \(version)\ncommit: 01d6c4fe68668db3521570d7fbc9b6b112b1e572\nbuilt: 2026-11-06T16:04:08Z\napi: revision \(api) (supports 0 to \(api))\n"
    }

    private static func statusOutput(_ version: String) -> String {
        #"{"endpoint":"unix:///x","rex_version":"\#(version)","api_revision":10,"session_count":3}"#
    }

    private func makeResolver(
        configuredPath: String? = nil,
        fileSystem: FakeRexFileSystem,
        runner: FakeProcessRunner,
        rexAppInstalled: Bool = true,
        shell: String? = "/bin/zsh"
    ) -> RexCLIResolver {
        RexCLIResolver(
            configuredPath: configuredPath,
            homeDirectory: home,
            loginShell: shell,
            isRexAppInstalled: { rexAppInstalled },
            fileSystem: fileSystem,
            runner: runner
        )
    }

    // MARK: Parsing

    func testParsesRexVersionOutput() {
        XCTAssertEqual(RexCLIVersionInfo.parse(Self.versionOutput("0.0.1793645657-gd018d2", api: 10)),
                       RexCLIVersionInfo(version: "0.0.1793645657-gd018d2", apiRevision: 10))
        XCTAssertEqual(RexCLIVersionInfo.parse("rex 1.2 extra\napi: revision 11 (supports 0 to 11)"),
                       RexCLIVersionInfo(version: "1.2", apiRevision: 11))
        XCTAssertNil(RexCLIVersionInfo.parse("rex 1.2\n"))
        XCTAssertNil(RexCLIVersionInfo.parse("api: revision 11\n"))
        XCTAssertNil(RexCLIVersionInfo.parse("something 1.2\napi: revision 11"))
        XCTAssertNil(RexCLIVersionInfo.parse("rex 1.2\napi: revision x"))
    }

    func testParsesServerStatus() {
        XCTAssertEqual(RexServerStatus.parse(Data(Self.statusOutput("0.0.1").utf8)), RexServerStatus(rexVersion: "0.0.1", apiRevision: 10))
        XCTAssertNil(RexServerStatus.parse(Data("".utf8)))
        XCTAssertNil(RexServerStatus.parse(Data(#"{"api_revision":10}"#.utf8)))
        XCTAssertNil(RexServerStatus.parse(Data(#"["rex_version"]"#.utf8)))
        XCTAssertNil(RexServerStatus.parse(Data(#"{"rex_version":3}"#.utf8)))
    }

    // MARK: Candidate selection

    func testPicksTheBinaryWhoseVersionMatchesTheServer() async throws {
        let fs = FakeRexFileSystem(directories: [versions: ["Current", "1853", ".DS_Store"]],
                                   executables: [versioned("Current"), versioned("1853")])
        let runner = FakeProcessRunner()
        runner.respond(versioned("Current"), ["version"], .exited(0), Self.versionOutput("0.0.2-gnew", api: 11))
        runner.respond(versioned("1853"), ["version"], .exited(0), Self.versionOutput("0.0.1-gold", api: 10))
        runner.respond(versioned("Current"), RexCLIResolver.serverStatusArguments, .exited(0), Self.statusOutput("0.0.1-gold"))

        let resolution = try await makeResolver(fileSystem: fs, runner: runner).resolve()

        XCTAssertEqual(resolution, .ready(RexCLI(path: versioned("1853"), version: "0.0.1-gold", apiRevision: 10)))
        XCTAssertEqual(runner.requests.map(\.timeout), [RexTimeouts.version, RexTimeouts.version, RexTimeouts.serverStatus])
        XCTAssertEqual(RexCLIResolver.serverStatusArguments, ["--autostart=false", "server", "status", "--json"])
        XCTAssertFalse(runner.requests.contains { $0.executable.hasSuffix("zsh") })
    }

    func testCandidateOrderIsCurrentThenNumberedDescendingThenFixedPaths() async throws {
        let fs = FakeRexFileSystem(
            directories: [versions: ["1853", "Current", "990", "beta"]],
            executables: [versioned("1853"), versioned("Current"), versioned("990"), versioned("beta"),
                          "/opt/homebrew/bin/rex", "/usr/local/bin/rex", "\(home)/.local/bin/rex"]
        )
        let candidates = makeResolver(fileSystem: fs, runner: FakeProcessRunner()).automaticCandidates()
        XCTAssertEqual(candidates, [versioned("Current"), versioned("1853"), versioned("990"), versioned("beta"),
                                    "/opt/homebrew/bin/rex", "/usr/local/bin/rex", "\(home)/.local/bin/rex"])
    }

    func testNoVersionMatchPrefersCurrentThenHighestAPI() async throws {
        let fs = FakeRexFileSystem(directories: [versions: ["1853", "1700"]],
                                   executables: [versioned("1853"), versioned("1700"), "/opt/homebrew/bin/rex"])
        let runner = FakeProcessRunner()
        runner.respond(versioned("1853"), ["version"], .exited(0), Self.versionOutput("a", api: 10))
        runner.respond(versioned("1700"), ["version"], .exited(0), Self.versionOutput("b", api: 12))
        runner.respond("/opt/homebrew/bin/rex", ["version"], .exited(0), Self.versionOutput("c", api: 11))
        runner.respond(versioned("1853"), RexCLIResolver.serverStatusArguments, .exited(0), Self.statusOutput("zzz"))

        let resolution = try await makeResolver(fileSystem: fs, runner: runner).resolve()
        XCTAssertEqual(resolution, .ready(RexCLI(path: versioned("1700"), version: "b", apiRevision: 12)))

        let withCurrent = FakeRexFileSystem(directories: [versions: ["Current", "1700"]],
                                            executables: [versioned("Current"), versioned("1700")])
        let runner2 = FakeProcessRunner()
        runner2.respond(versioned("Current"), ["version"], .exited(0), Self.versionOutput("a", api: 10))
        runner2.respond(versioned("1700"), ["version"], .exited(0), Self.versionOutput("b", api: 12))
        runner2.respond(versioned("Current"), RexCLIResolver.serverStatusArguments, .exited(0), Self.statusOutput("zzz"))
        let resolution2 = try await makeResolver(fileSystem: withCurrent, runner: runner2).resolve()
        XCTAssertEqual(resolution2, .ready(RexCLI(path: versioned("Current"), version: "a", apiRevision: 10)))
    }

    func testInvalidCandidatesAreSkipped() async throws {
        let fs = FakeRexFileSystem(directories: [versions: ["Current", "1853", "1700"]],
                                   executables: [versioned("Current"), versioned("1853"), versioned("1700")])
        let runner = FakeProcessRunner()
        runner.respond(versioned("Current"), ["version"], .timedOut, "")
        runner.respond(versioned("1853"), ["version"], .exited(0), Self.versionOutput("old", api: 9))
        runner.respond(versioned("1700"), ["version"], .exited(0), Self.versionOutput("ok", api: 10))
        runner.respond(versioned("1700"), RexCLIResolver.serverStatusArguments, .exited(0), Self.statusOutput("ok"))

        let resolution = try await makeResolver(fileSystem: fs, runner: runner).resolve()
        XCTAssertEqual(resolution, .ready(RexCLI(path: versioned("1700"), version: "ok", apiRevision: 10)))
        // A non-zero `rex version` exit is invalid even with parseable output.
        let runner2 = FakeProcessRunner()
        runner2.respond(versioned("Current"), ["version"], .exited(1), Self.versionOutput("x", api: 11))
        runner2.respond(versioned("1853"), ["version"], .exited(0), Self.versionOutput("old", api: 9))
        runner2.respond(versioned("1700"), ["version"], .exited(0), Self.versionOutput("ok", api: 10))
        runner2.respond(versioned("1700"), RexCLIResolver.serverStatusArguments, .exited(0), Self.statusOutput("ok"))
        let resolution2 = try await makeResolver(fileSystem: fs, runner: runner2).resolve()
        XCTAssertEqual(resolution2.cli?.path, versioned("1700"))
    }

    func testServerStatusExitOneIsUnreachableAndPrefersCurrent() async throws {
        let fs = FakeRexFileSystem(directories: [versions: ["1853", "Current"]],
                                   executables: [versioned("1853"), versioned("Current")])
        let runner = FakeProcessRunner()
        runner.respond(versioned("Current"), ["version"], .exited(0), Self.versionOutput("new", api: 11))
        runner.respond(versioned("1853"), ["version"], .exited(0), Self.versionOutput("old", api: 10))
        runner.respond(versioned("Current"), RexCLIResolver.serverStatusArguments, .exited(1), "",
                       stderr: "Error: rex server is not running\n")

        let resolution = try await makeResolver(fileSystem: fs, runner: runner).resolve()
        XCTAssertEqual(resolution, .serverUnreachable(RexCLI(path: versioned("Current"), version: "new", apiRevision: 11)))
        XCTAssertEqual(resolution.retryInterval, .seconds(60))
    }

    func testServerStatusWithoutRexVersionIsUnreachableAndUsesFirstValidWithoutCurrent() async throws {
        let fs = FakeRexFileSystem(directories: [versions: ["1853"]], executables: [versioned("1853"), "/usr/local/bin/rex"])
        let runner = FakeProcessRunner()
        runner.respond(versioned("1853"), ["version"], .exited(0), Self.versionOutput("old", api: 10))
        runner.respond("/usr/local/bin/rex", ["version"], .exited(0), Self.versionOutput("new", api: 11))
        runner.respond(versioned("1853"), RexCLIResolver.serverStatusArguments, .exited(0), "not json")

        let resolution = try await makeResolver(fileSystem: fs, runner: runner).resolve()
        XCTAssertEqual(resolution, .serverUnreachable(RexCLI(path: versioned("1853"), version: "old", apiRevision: 10)))
    }

    func testConfiguredPathWinsWhenValidAndFallsBackWhenNot() async throws {
        let fs = FakeRexFileSystem(directories: [versions: ["Current"]], executables: [versioned("Current"), "/custom/rex"])
        let runner = FakeProcessRunner()
        runner.respond("/custom/rex", ["version"], .exited(0), Self.versionOutput("custom", api: 10))
        runner.respond("/custom/rex", RexCLIResolver.serverStatusArguments, .exited(0), Self.statusOutput("other"))
        let resolution = try await makeResolver(configuredPath: "/custom/rex", fileSystem: fs, runner: runner).resolve()
        XCTAssertEqual(resolution, .ready(RexCLI(path: "/custom/rex", version: "custom", apiRevision: 10)))
        XCTAssertEqual(runner.requests.map(\.executable), ["/custom/rex", "/custom/rex"])

        let runner2 = FakeProcessRunner()
        runner2.respond("/custom/rex", ["version"], .exited(0), Self.versionOutput("custom", api: 9))
        runner2.respond(versioned("Current"), ["version"], .exited(0), Self.versionOutput("cur", api: 10))
        runner2.respond(versioned("Current"), RexCLIResolver.serverStatusArguments, .exited(0), Self.statusOutput("cur"))
        let resolution2 = try await makeResolver(configuredPath: "/custom/rex", fileSystem: fs, runner: runner2).resolve()
        XCTAssertEqual(resolution2.cli?.path, versioned("Current"))
    }

    // MARK: Shell probe

    func testShellProbeRunsOnlyWhenNothingExistsAndRexAppIsInstalledOncePerLaunch() async throws {
        let fs = FakeRexFileSystem(directories: [:], executables: ["/Users/u/bin/rex"])
        let runner = FakeProcessRunner()
        runner.respond("/bin/zsh", ["-lc", "command -v rex"], .exited(0), "Welcome!\n/Users/u/bin/rex\n")
        runner.respond("/Users/u/bin/rex", ["version"], .exited(0), Self.versionOutput("v", api: 10))
        runner.respond("/Users/u/bin/rex", RexCLIResolver.serverStatusArguments, .exited(0), Self.statusOutput("v"))
        let resolver = makeResolver(fileSystem: fs, runner: runner)

        let first = try await resolver.resolve()
        XCTAssertEqual(first.cli?.path, "/Users/u/bin/rex")
        let probe = try XCTUnwrap(runner.requests.first)
        XCTAssertEqual(probe.timeout, RexTimeouts.shellProbe)
        XCTAssertTrue(probe.newProcessGroup)

        _ = try await resolver.resolve()
        XCTAssertEqual(runner.requests.filter { $0.executable == "/bin/zsh" }.count, 1)
    }

    func testShellProbeNeverRunsWithoutRexApp() async throws {
        let runner = FakeProcessRunner()
        let resolver = makeResolver(fileSystem: FakeRexFileSystem(directories: [:], executables: []),
                                    runner: runner, rexAppInstalled: false)
        let resolution = try await resolver.resolve()
        XCTAssertEqual(resolution, .hidden)
        XCTAssertEqual(runner.requests, [])
    }

    func testFailedShellProbeStillCountsAsRun() async throws {
        let runner = FakeProcessRunner()
        runner.respond("/bin/zsh", ["-lc", "command -v rex"], .timedOut, "")
        let resolver = makeResolver(fileSystem: FakeRexFileSystem(directories: [:], executables: []), runner: runner)
        let first = try await resolver.resolve()
        let second = try await resolver.resolve()
        XCTAssertEqual(first, .hidden)
        XCTAssertEqual(second, .hidden)
        XCTAssertEqual(runner.requests.count, 1)
    }

    func testShellProbeUsesZshWhenShellIsUnset() async throws {
        let runner = FakeProcessRunner()
        let resolver = makeResolver(fileSystem: FakeRexFileSystem(directories: [:], executables: []), runner: runner, shell: nil)
        _ = try await resolver.resolve()
        XCTAssertEqual(runner.requests.map(\.executable), ["/bin/zsh"])
    }

    // MARK: Hidden vs unavailable

    func testNeverFoundIsHiddenWithFiveMinuteRecheckAndPreviouslyFoundIsUnavailable() async throws {
        let fs = FakeRexFileSystem(directories: [versions: ["Current"]], executables: [versioned("Current")])
        let runner = FakeProcessRunner()
        runner.respond(versioned("Current"), ["version"], .exited(0), Self.versionOutput("v", api: 10))
        runner.respond(versioned("Current"), RexCLIResolver.serverStatusArguments, .exited(0), Self.statusOutput("v"))
        let resolver = makeResolver(fileSystem: fs, runner: runner, rexAppInstalled: false)

        let emptyFS = FakeRexFileSystem(directories: [:], executables: [])
        let neverFound = makeResolver(fileSystem: emptyFS, runner: FakeProcessRunner(), rexAppInstalled: false)
        let hidden = try await neverFound.resolve()
        XCTAssertEqual(hidden, .hidden)
        XCTAssertEqual(hidden.retryInterval, .seconds(300))
        let neverFoundEver = await neverFound.hasEverResolved
        XCTAssertFalse(neverFoundEver)

        let found = try await resolver.resolve()
        XCTAssertNotNil(found.cli)
        let everResolved = await resolver.hasEverResolved
        XCTAssertTrue(everResolved)

        fs.executables = []
        let missing = try await resolver.resolve()
        guard case .unavailable = missing else { return XCTFail("\(missing)") }
        XCTAssertNil(missing.retryInterval)
    }

    func testAllCandidatesInvalidCountsAsNotFound() async throws {
        let fs = FakeRexFileSystem(directories: [versions: ["Current"]], executables: [versioned("Current")])
        let runner = FakeProcessRunner()
        runner.respond(versioned("Current"), ["version"], .exited(0), Self.versionOutput("v", api: 9))
        let resolution = try await makeResolver(fileSystem: fs, runner: runner, rexAppInstalled: false).resolve()
        XCTAssertEqual(resolution, .hidden)
    }

    // MARK: Failed candidates

    func testFailedCandidatesAreSkippedUntilNoneAreLeftThenCleared() async throws {
        let fs = FakeRexFileSystem(directories: [versions: ["Current", "1853"]],
                                   executables: [versioned("Current"), versioned("1853")])
        let runner = FakeProcessRunner()
        runner.respond(versioned("Current"), ["version"], .exited(0), Self.versionOutput("new", api: 11))
        runner.respond(versioned("1853"), ["version"], .exited(0), Self.versionOutput("old", api: 10))
        runner.respond(versioned("Current"), RexCLIResolver.serverStatusArguments, .exited(0), Self.statusOutput("old"))
        runner.respond(versioned("1853"), RexCLIResolver.serverStatusArguments, .exited(0), Self.statusOutput("old"))
        let resolver = makeResolver(fileSystem: fs, runner: runner)

        let first = try await resolver.resolve()
        XCTAssertEqual(first.cli?.path, versioned("1853"))
        await resolver.markFailed(path: versioned("1853"))

        let second = try await resolver.resolve()
        XCTAssertEqual(second.cli?.path, versioned("Current"))
        await resolver.markFailed(path: versioned("Current"))

        // Both failed: the list is cleared and normal selection resumes.
        let third = try await resolver.resolve()
        XCTAssertEqual(third.cli?.path, versioned("1853"))
        let failed = await resolver.failedPaths
        XCTAssertEqual(failed, [])
    }

    func testCancellationThrowsWithoutChangingState() async throws {
        let fs = FakeRexFileSystem(directories: [versions: ["Current"]], executables: [versioned("Current")])
        let runner = FakeProcessRunner()
        runner.respond(versioned("Current"), ["version"], .cancelled, "")
        let resolver = makeResolver(fileSystem: fs, runner: runner, rexAppInstalled: false)
        do {
            _ = try await resolver.resolve()
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let everResolved = await resolver.hasEverResolved
        XCTAssertFalse(everResolved)
    }
}

// MARK: Fakes

final class FakeRexFileSystem: RexFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var _directories: [String: [String]]
    private var _executables: Set<String>

    init(directories: [String: [String]], executables: Set<String>) {
        _directories = directories
        _executables = executables
    }

    var executables: Set<String> {
        get { lock.withLock { _executables } }
        set { lock.withLock { _executables = newValue } }
    }

    func isExecutableFile(atPath path: String) -> Bool { lock.withLock { _executables.contains(path) } }
    func contentsOfDirectory(atPath path: String) -> [String] { lock.withLock { _directories[path] ?? [] } }
}

final class FakeProcessRunner: ProcessRunning, @unchecked Sendable {
    private struct Key: Hashable { let executable: String; let arguments: [String] }
    private let lock = NSLock()
    private var responses: [Key: ProcessResult] = [:]
    private var _requests: [ProcessRequest] = []

    var requests: [ProcessRequest] { lock.withLock { _requests } }

    func respond(_ executable: String, _ arguments: [String], _ outcome: ProcessResult.Outcome, _ stdout: String, stderr: String = "") {
        lock.withLock {
            responses[Key(executable: executable, arguments: arguments)] =
                ProcessResult(outcome: outcome, stdout: Data(stdout.utf8), stderrTail: stderr)
        }
    }

    func run(_ request: ProcessRequest) async -> ProcessResult {
        lock.withLock {
            _requests.append(request)
            return responses[Key(executable: request.executable, arguments: request.arguments)]
                ?? ProcessResult(outcome: .launchFailed("no fake response for \(request.executable) \(request.arguments)"))
        }
    }
}
