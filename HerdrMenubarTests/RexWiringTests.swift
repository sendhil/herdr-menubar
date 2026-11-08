import Darwin
import Foundation
import XCTest
@testable import HerdrMenubar

/// Step-2 item 15: runtime wiring, cross-backend supersession, and Herdr-only visibility.
@MainActor
final class RexWiringTests: XCTestCase {
    // MARK: Wiring

    func testDefaultPreferencesBuildHerdrOnlyAndNeverConstructRex() {
        let preferences = wiringPreferences(nil)
        var rexBuilds = 0

        let backends = ApplicationRuntime.makeBackends(
            preferences: preferences, herdr: FakeAgentBackend(kind: .herdr),
            makeRex: { _ in rexBuilds += 1; return FakeAgentBackend(kind: .rex) }
        )

        XCTAssertEqual(backends.map(\.kind), [.herdr])
        XCTAssertEqual(rexBuilds, 0)
    }

    func testEnabledRexIsBuiltOnceWithTheConfiguredCLIPath() {
        let preferences = wiringPreferences(["herdr", "rex"], rexCLIPath: "/opt/rex/bin/rex")
        var paths: [String?] = []

        let backends = ApplicationRuntime.makeBackends(
            preferences: preferences, herdr: FakeAgentBackend(kind: .herdr),
            makeRex: { paths.append($0); return FakeAgentBackend(kind: .rex) }
        )

        XCTAssertEqual(backends.map(\.kind), [.herdr, .rex])
        XCTAssertEqual(paths, ["/opt/rex/bin/rex"])
    }

    func testEnabledRexWithoutConfiguredPathResolvesAutomatically() {
        let preferences = wiringPreferences(["herdr", "rex"])
        var paths: [String?] = []

        _ = ApplicationRuntime.makeBackends(
            preferences: preferences, herdr: FakeAgentBackend(kind: .herdr),
            makeRex: { paths.append($0); return FakeAgentBackend(kind: .rex) }
        )

        XCTAssertEqual(paths, [nil])
    }

    func testLiveRexBackendIsARexBackend() {
        let backend = ApplicationRuntime.liveRexBackend(configuredCLIPath: nil)
        XCTAssertEqual(backend.kind, .rex)
        XCTAssertTrue(backend is RexBackend)
    }

    // MARK: Cross-backend supersession

    /// Selecting Herdr while a Rex server focus is in flight terminates the Rex child process and
    /// never activates Rex.app. Uses the real `LiveProcessRunner` with a stand-in CLI script.
    func testHerdrSelectionSupersedesInFlightRexFocusTerminatingTheChild() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rex-wiring-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let script = directory.appendingPathComponent("rex")
        try "#!/bin/sh\necho $$ > '\(pidFile.path)'\nexec /bin/sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let watchers = FakeWatcherFactory()
        let app = FakeRexApp()
        let rex = RexBackend(
            resolver: FakeRexResolver([.ready(RexCLI(path: script.path, version: "0.0.1", apiRevision: 10))]),
            scriptURL: URL(fileURLWithPath: "/x.lua"), makeWatcher: watchers.factory,
            runner: LiveProcessRunner(), app: app, clock: ManualRexClock(),
            hostName: { "Studio" }, isEnabled: { true }
        )
        let herdr = FakeAgentBackend(kind: .herdr)
        let store = makeBackendStore([herdr, rex])
        await store.start()
        let work = AgentSessionDescriptor(key: .named("work"), displayName: "work")
        herdr.send(.discovery([work]))
        herdr.send(.connected(work, .empty))
        await rexWaitUntil { watchers.processes.count == 1 && watchers.processes[0].started }
        watchers.last!.send(RexJSON.snapshot(state: "blocked"))
        await rexWaitUntil { store.attentionCount == 1 && store.connectionState == .connected }

        store.select(SelectionTarget(
            target: AgentTarget(session: AgentSessionKey(backend: .rex, rawID: "s1"), paneID: "b1"),
            sessionDisplayName: "work"
        ))
        await rexWaitUntil("Rex focus child running") {
            (try? String(contentsOf: pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(pid, SIGKILL) }
        XCTAssertEqual(kill(pid, 0), 0, "the focus child is alive before supersession")

        let started = ContinuousClock.now
        await store.selectRow(.herdr(.named("work"), paneID: "p"))

        XCTAssertEqual(herdr.calls, ["start", "focus:p", "activate:p", "refresh:p"])
        await rexWaitUntil("Rex focus child terminated") { kill(pid, 0) == -1 && errno == ESRCH }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
        XCTAssertEqual(app.activations, 0)
        XCTAssertNil(store.transientError)
        await store.stop()
    }

    // MARK: Herdr-only visibility

    func testHerdrOnlyOutputIsIdenticalWhenRexIsAbsentDisabledHiddenUnreachableOrStopped() async {
        let baseline = await herdrOnlyRun(.absent)

        // Today's exact Herdr wording, badge, and states.
        XCTAssertEqual(baseline.map(\.presentation.menu.first), [
            .info("Searching for Herdr sessions…", tone: .secondary),
            .info("No Herdr sessions running", tone: .secondary),
            .info("Connecting to Herdr sessions…", tone: .secondary),
            .heading("NEEDS ATTENTION"),
            .info("Connecting to Herdr sessions…", tone: .secondary),
        ])
        XCTAssertEqual(baseline.map(\.presentation.icon.wording), Array(repeating: .herdr, count: 5))
        XCTAssertEqual(baseline[3].presentation.icon.attentionCount, 2)
        XCTAssertEqual(baseline[3].presentation.accessibilityValue, "Connected, 2 agents need attention")
        XCTAssertTrue(baseline[3].presentation.menu.contains(.heading("WORK")))
        XCTAssertFalse(baseline.contains { $0.presentation.menu.contains(.heading("FINISHED")) })
        XCTAssertEqual(baseline[4].presentation.menu.prefix(3), [
            .info("Connecting to Herdr sessions…", tone: .secondary),
            .heading("RECONNECTING"),
            .info("work", tone: .secondary),
        ])
        XCTAssertEqual(baseline[3].sketchyBar, SketchyBarSnapshot(
            writtenAt: 1, isRunning: true, mode: "attention", attentionCount: 2,
            summary: "Connected, 2 agents need attention"
        ))

        for variant in [HerdrOnlyVariant.disabled, .hidden, .serverUnreachable, .stoppedAfterActiveRun] {
            let run = await herdrOnlyRun(variant)
            XCTAssertEqual(run.map(\.presentation), baseline.map(\.presentation), "\(variant)")
            XCTAssertEqual(run.map(\.sketchyBar), baseline.map(\.sketchyBar), "\(variant)")
            XCTAssertEqual(run.map(\.toolTip), baseline.map(\.toolTip), "\(variant)")
        }
    }

    private enum HerdrOnlyVariant: CustomStringConvertible {
        case absent, disabled, hidden, serverUnreachable, stoppedAfterActiveRun
        var description: String {
            switch self {
            case .absent: "absent"
            case .disabled: "disabled"
            case .hidden: "hidden (not installed)"
            case .serverUnreachable: "installed but not running"
            case .stoppedAfterActiveRun: "stopped after an active run"
            }
        }
    }

    private struct Observation {
        let presentation: StatusItemPresentation
        let sketchyBar: SketchyBarSnapshot?
        let toolTip: String
    }

    /// Drives the same Herdr events through a store whose Rex backend is in `variant`, recording
    /// the full presentation, SketchyBar record, and status-button tooltip after each step.
    private func herdrOnlyRun(_ variant: HerdrOnlyVariant) async -> [Observation] {
        let herdr = FakeAgentBackend(kind: .herdr)
        let cli = RexCLI(path: "/rex/Current/rex", version: "0.0.1", apiRevision: 10)
        let watchers = FakeWatcherFactory()
        let resolver: FakeRexResolver
        let enabled: [String]?
        var backends: [any AgentBackend] = [herdr]
        switch variant {
        case .absent:
            resolver = FakeRexResolver([.hidden])
            enabled = nil
        case .disabled:
            resolver = FakeRexResolver([.hidden])
            enabled = nil
        case .hidden:
            resolver = FakeRexResolver([.hidden])
            enabled = ["herdr", "rex"]
        case .serverUnreachable:
            resolver = FakeRexResolver([.serverUnreachable(cli)])
            enabled = ["herdr", "rex"]
        case .stoppedAfterActiveRun:
            resolver = FakeRexResolver([.ready(cli)])
            enabled = ["herdr", "rex"]
        }
        let rex = RexBackend(
            resolver: resolver, scriptURL: URL(fileURLWithPath: "/x.lua"), makeWatcher: watchers.factory,
            runner: ScriptedProcessRunner(), app: FakeRexApp(), clock: ManualRexClock(),
            hostName: { "Studio" }, isEnabled: { variant != .disabled }
        )
        if variant != .absent { backends.append(rex) }

        let preferences = wiringPreferences(enabled)
        let service = BackendStoreNotifications()
        let notifications = NotificationSettingsController(service: service, preferences: preferences)
        let store = AgentStore(
            backends: backends, attentionCoordinator: BackendStoreCoordinator(),
            notificationService: service, preferences: preferences, clock: ManualRexClock()
        )
        let login = RexPresentationLoginItem()
        var written: [SketchyBarSnapshot] = []
        let publisher = SketchyBarStatusPublisher(now: { 1 }, write: { written.append($0) }, notify: {}, automaticHeartbeat: false)
        publisher.start()
        var observations: [Observation] = []
        func observe() {
            let presentation = StatusMenuPresentationBuilder().make(
                store: store, preferences: preferences, terminals: [], loginItem: login, notifications: notifications
            )
            publisher.apply(presentation)
            observations.append(Observation(
                presentation: presentation, sketchyBar: written.last,
                toolTip: presentation.icon.wording.tooltipPrefix + presentation.accessibilityValue
            ))
        }

        await store.start()
        switch variant {
        case .absent, .disabled:
            await settleTasks()
        case .hidden:
            await rexWaitUntil { resolver.resolveCount >= 1 }
            await settleTasks()
        case .serverUnreachable:
            await rexWaitUntil { store.unavailableBackends[.rex] != nil }
        case .stoppedAfterActiveRun:
            // A previous run where Rex was active, then stop and restart with the server down.
            await rexWaitUntil { watchers.processes.count == 1 && watchers.processes[0].started }
            watchers.last!.send(RexJSON.snapshot(state: "blocked"))
            await rexWaitUntil { store.activeBackends.contains(.rex) && store.attentionCount == 1 }
            await store.stop()
            resolver.set([.serverUnreachable(cli)])
            await store.start()
            await rexWaitUntil { store.unavailableBackends[.rex] != nil }
        }

        let work = AgentSessionDescriptor(key: .named("work"), displayName: "work")
        func herdrRow(_ pane: String, _ state: RowState) -> AgentRow {
            AgentRow(target: AgentTarget(session: work.key, paneID: pane), displayLabel: pane, agentLabel: "claude",
                     state: state, subtitle: "status · claude", seenToken: nil)
        }

        observe()
        herdr.send(.discovery([]))
        await rexWaitUntil { store.connectionState == .noSessions }
        observe()
        herdr.send(.discovery([work]))
        await rexWaitUntil { store.connectionState == .connecting }
        observe()
        herdr.send(.connected(work, BackendSnapshot(
            rows: [herdrRow("a", .attention(.blocked)), herdrRow("b", .attention(.done)), herdrRow("c", .working)],
            attention: []
        )))
        await rexWaitUntil { store.connectionState == .connected }
        observe()
        herdr.send(.sessionUnavailable(work.key, "socket unavailable"))
        await rexWaitUntil { store.connectionState == .connecting }
        observe()

        publisher.stop()
        await store.stop()
        return observations
    }
}

@MainActor
private func wiringPreferences(_ enabledBackends: [String]?, rexCLIPath: String? = nil) -> Preferences {
    let defaults = UserDefaults(suiteName: "dev.herdr.menubar.rex-wiring-tests.\(UUID().uuidString)")!
    if let enabledBackends { defaults.set(enabledBackends, forKey: Preferences.enabledBackendsKey) }
    if let rexCLIPath { defaults.set(rexCLIPath, forKey: Preferences.rexCLIPathKey) }
    return Preferences(defaults: defaults)
}
