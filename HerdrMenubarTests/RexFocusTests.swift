import XCTest
@testable import HerdrMenubar

/// Focus never touches a live server: every process goes through `ScriptedProcessRunner`.
@MainActor
final class RexFocusTests: XCTestCase {
    private let cli = RexCLI(path: "/rex/Current/rex", version: "0.0.1", apiRevision: 10)
    private let target = AgentTarget(session: rexKey("s1"), paneID: "b1")
    private var runner: ScriptedProcessRunner!
    private var app: FakeRexApp!
    private var watchers: FakeWatcherFactory!
    private var backend: RexBackend!
    private var recorder: BackendEventRecorder!

    override func setUp() {
        super.setUp()
        runner = ScriptedProcessRunner()
        app = FakeRexApp()
        watchers = FakeWatcherFactory()
    }

    override func tearDown() async throws {
        await backend?.stop()
        backend = nil
        try await super.tearDown()
    }

    /// A backend that resolved `cli` and knows session `s1` as "work".
    private func startBackend(host: String? = "Studio") async {
        let clock = ManualRexClock()
        backend = RexBackend(resolver: FakeRexResolver([.ready(cli)]), scriptURL: URL(fileURLWithPath: "/x.lua"),
                             makeWatcher: watchers.factory, runner: runner, app: app, clock: clock,
                             hostName: { host }, isEnabled: { true })
        recorder = BackendEventRecorder(await backend.events())
        await backend.start()
        await rexWaitUntil { watchers.processes.count == 1 && watchers.processes[0].started }
        watchers.last!.send(RexJSON.snapshot(state: "blocked"))
        await rexWaitUntil { recorder.events.contains { if case .connected = $0 { true } else { false } } }
    }

    nonisolated private static func result(_ outcome: ProcessResult.Outcome, _ stdout: String = "", stderr: String = "") -> ProcessResult {
        ProcessResult(outcome: outcome, stdout: Data(stdout.utf8), stderrTail: stderr)
    }

    nonisolated private static func clients(_ entries: [String]) -> String { #"{"clients":["# + entries.joined(separator: ",") + "]}" }

    nonisolated private static func client(_ id: String, label: String = "Studio", kind: String = "app", platform: String = "macos",
                               state: String = "connected") -> String {
        #"{"client_id":"\#(id)","connection_state":"\#(state)","info":{"kind":"\#(kind)","platform":"\#(platform)","label":"\#(label)"}}"#
    }

    /// Answers `client ls` with `clientList` and `session.select` with `select`.
    private func script(clientList: ProcessResult, select: ProcessResult = result(.exited(0))) {
        runner.setHandler { request in
            if request.arguments == RexFocus.clientListArguments { return clientList }
            if request.arguments.contains("session.select") { return select }
            return ProcessResult(outcome: .launchFailed("unexpected \(request.arguments)"))
        }
    }

    private func focusError(_ outcome: ProcessResult.Outcome, _ stdout: String = "", stderr: String = "") async -> Error? {
        runner.setHandler { _ in Self.result(outcome, stdout, stderr: stderr) }
        do {
            try await backend.focusServer(target)
            return nil
        } catch {
            return error
        }
    }

    // MARK: focusServer

    func testFocusServerRunsTheSessionScopedScriptWithIdsInArgs() async throws {
        await startBackend()
        let error = await focusError(.exited(0), #"{"focus":"ok"}"# + "\n")
        XCTAssertNil(error)
        let request = try XCTUnwrap(runner.requests.last)
        XCTAssertEqual(request.executable, cli.path)
        XCTAssertEqual(request.timeout, .seconds(5))
        XCTAssertEqual(request.arguments, ["--autostart=false", "do", "-s", "s1", "--args", #"{"block":"b1"}"#, "-e", RexFocus.script])
        XCTAssertTrue(RexFocus.script.contains("rex.session.focus_block{ block_id = rex.args.block }"))
    }

    func testFocusServerExitCodeTable() async {
        await startBackend()
        let notFound = await focusError(.exited(0), #"{"focus":"error","err":"rex: code=not_found message=block not found"}"#)
        XCTAssertEqual(notFound as? FocusError, .failed("That pane no longer exists in work"))

        let other = await focusError(.exited(0), #"{"focus":"error","err":"code=conflict nope"}"#)
        XCTAssertEqual(other as? FocusError, .failed("work: code=conflict nope"))

        let gone = await focusError(.exited(3), stderr: "Error: session target s1 not found\n")
        XCTAssertEqual(gone as? FocusError, .failed("work is no longer running in Rex"))

        let down = await focusError(.exited(4), stderr: "Error: no Rex server is running at /x, and autostart is disabled\n")
        XCTAssertEqual(down as? FocusError, .unavailable("Rex is not running"))

        let schema = await focusError(.exited(2), stderr: "listening:\nError: invalid args\n\n")
        XCTAssertEqual(schema as? FocusError, .failed("Error: invalid args"))

        let noJSON = await focusError(.exited(0), "hello\n", stderr: "warning: odd\n")
        XCTAssertEqual(noJSON as? FocusError, .failed("warning: odd"))

        let timeout = await focusError(.timedOut)
        XCTAssertEqual(timeout as? FocusError, .failed("Rex did not respond in time"))
    }

    func testFocusServerUsesTheFallbackSessionNameForUnknownSessions() async {
        await startBackend()
        runner.setHandler { _ in Self.result(.exited(3)) }
        do {
            try await backend.focusServer(AgentTarget(session: rexKey("zz"), paneID: "b"))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? FocusError, .failed("Rex session is no longer running in Rex"))
        }
    }

    func testFocusServerWithoutAResolvedCLIIsUnavailable() async {
        backend = RexBackend(resolver: FakeRexResolver([.hidden]), scriptURL: nil, makeWatcher: watchers.factory,
                             runner: runner, app: app, clock: ManualRexClock(), hostName: { nil }, isEnabled: { true })
        do {
            try await backend.focusServer(target)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? FocusError, .unavailable("Rex is not running"))
        }
        XCTAssertTrue(runner.requests.isEmpty)
    }

    func testCancelledFocusServerThrowsCancellation() async {
        await startBackend()
        runner.setHandler { _ in Self.result(.cancelled) }
        do {
            try await backend.focusServer(target)
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    // MARK: Client selection

    func testClientSelectionPrefersThisMacThenTheOnlyClient() {
        func pick(_ entries: [String], host: String? = "Studio") -> String? {
            RexFocus.selectClient(RexFocus.parseClients(Data(Self.clients(entries).utf8)), hostName: host)?.id
        }
        XCTAssertEqual(pick([Self.client("a", label: "Laptop"), Self.client("b", label: "Studio")]), "b")
        XCTAssertEqual(pick([Self.client("a", label: "Laptop")]), "a", "the only remaining client")
        XCTAssertNil(pick([Self.client("a", label: "Laptop"), Self.client("b", label: "Other")]))
        XCTAssertEqual(pick([Self.client("cli", kind: "cli"), Self.client("ios", platform: "ios"),
                             Self.client("lost", state: "lost"), Self.client("a", label: "Laptop")]), "a")
        XCTAssertNil(pick([Self.client("lost", state: "lost")]))
        XCTAssertEqual(pick([#"{"client_id":"n","info":null}"#, Self.client("a", label: "Laptop")]), "a")
        XCTAssertEqual(RexFocus.parseClients(Data(#"{"clients":null}"#.utf8)), [])
    }

    // MARK: activate

    func testActivateSwitchesTheClientAndActivatesRex() async throws {
        await startBackend()
        script(clientList: Self.result(.exited(0), Self.clients([Self.client("c1")])))
        let partial = await backend.activate(target)
        XCTAssertNil(partial)
        XCTAssertEqual(app.activations, 1)
        let list = runner.requests[0]
        XCTAssertEqual(list.arguments, ["--autostart=false", "client", "ls", "--json"])
        let select = runner.requests[1]
        XCTAssertEqual(select.arguments, ["--autostart=false", "-C", "c1", "do", "session.select", "--args", #"{"session_id":"s1"}"#])
        XCTAssertEqual(select.timeout, .seconds(5))
    }

    func testActivateWithoutAClient() async {
        await startBackend()
        script(clientList: Self.result(.exited(0), Self.clients([])))
        app.running = true
        let connected = await backend.activate(target)
        XCTAssertEqual(connected, "Rex app is not connected to the server.")
        XCTAssertEqual(app.activations, 1)

        app.running = false
        let notRunning = await backend.activate(target)
        XCTAssertEqual(notRunning, "Rex is not running.")
        XCTAssertEqual(app.activations, 1)

        script(clientList: Self.result(.exited(4)))
        app.running = true
        let listFailed = await backend.activate(target)
        XCTAssertEqual(listFailed, "Rex app is not connected to the server.")
        XCTAssertFalse(runner.requests.contains { $0.arguments.contains("session.select") })
    }

    func testActivateSelectOutcomes() async {
        await startBackend()
        let list = Self.result(.exited(0), Self.clients([Self.client("c1")]))

        script(clientList: list, select: Self.result(.exited(1), stderr:
            "Error: Rex.app is not accepting actions. Turn on Remote Control in its Settings under Rex Server.\n"))
        let off = await backend.activate(target)
        XCTAssertEqual(off, "Turn on Remote Control in Rex Settings → Rex Server to switch sessions.")

        script(clientList: list, select: Self.result(.exited(3), stderr: "Error: client target c1 not found\n"))
        let disconnected = await backend.activate(target)
        XCTAssertEqual(disconnected, "Rex app disconnected.")

        script(clientList: list, select: Self.result(.exited(1), stderr: "Error: something else\n"))
        let other = await backend.activate(target)
        XCTAssertEqual(other, "Error: something else")

        XCTAssertEqual(app.activations, 3, "Rex.app is still brought forward after a partial switch")
    }

    func testSupersededActivationDoesNotActivateRex() async {
        await startBackend()
        let gate = RexTestGate()
        let list = Self.result(.exited(0), Self.clients([Self.client("c1")]))
        runner.setHandler { request in
            if request.arguments == RexFocus.clientListArguments { return list }
            await gate.wait()
            return Self.result(.exited(0))   // the switch finished, but the selection was superseded
        }
        let backend = self.backend!
        let task = Task { await backend.activate(self.target) }
        await rexWaitUntil { self.runner.requests.count == 2 }
        task.cancel()
        gate.open()
        let partial = await task.value
        XCTAssertNil(partial)
        XCTAssertEqual(app.activations, 0)
    }

    func testCancelledBeforeTheClientSwitchRunsNothingFurther() async {
        await startBackend()
        let gate = RexTestGate()
        runner.setHandler { request in
            await gate.wait()
            return Self.result(.exited(0), Self.clients([Self.client("c1")]))
        }
        let backend = self.backend!
        let task = Task { await backend.activate(self.target) }
        await rexWaitUntil { self.runner.requests.count == 1 }
        task.cancel()
        gate.open()
        _ = await task.value
        XCTAssertEqual(runner.requests.count, 1, "no session.select after cancellation")
        XCTAssertEqual(app.activations, 0)
    }

    func testRefreshAfterSelectionIsANoOp() async {
        await startBackend()
        let before = recorder.events.count
        await backend.refreshAfterSelection(target)
        await settleTasks()
        XCTAssertEqual(recorder.events.count, before)
        XCTAssertTrue(runner.requests.isEmpty)
    }
}
