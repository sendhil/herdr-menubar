import Foundation
import XCTest
@testable import HerdrMenubar

@MainActor
final class HerdrBackendTests: XCTestCase {
    // MARK: Rows and attention records

    func testSnapshotBuildsRowsOnlyForAttentionAndWorkingPanesInSnapshotOrder() {
        let snapshot = herdrSnapshot([
            herdrPane("idle", .idle), herdrPane("blocked", .blocked), herdrPane("unknown", .unknown),
            herdrPane("working", .working), herdrPane("done", .done)
        ])

        let rows = HerdrBackend.makeSnapshot(snapshot, sessionID: .named("work")).rows

        XCTAssertEqual(rows.map(\.target.paneID), ["blocked", "working", "done"])
        XCTAssertEqual(rows.map(\.state), [.attention(.blocked), .working, .attention(.done)])
        XCTAssertEqual(rows.map(\.subtitle), ["blocked · Claude", "working · Claude", "done · Claude"])
        XCTAssertEqual(rows.map(\.agentLabel), ["Claude", "Claude", "Claude"])
        XCTAssertTrue(rows.allSatisfy { $0.seenToken == nil })
        XCTAssertTrue(rows.allSatisfy { $0.target.session == AgentSessionKey(herdr: .named("work")) })
    }

    func testAttentionRecordsAreLabelOrderedDeduplicatedLastWinsAndHerdrShaped() {
        let snapshot = herdrSnapshot([
            herdrPane("z", .blocked, title: "Zulu"),
            herdrPane("b", .done, title: "Alpha"),
            herdrPane("a", .blocked, title: "alpha"),
            herdrPane("dup", .blocked, title: "Dup"),
            herdrPane("dup", .working, title: "Dup"),
            herdrPane("w", .working, title: "Working")
        ])

        let attention = HerdrBackend.makeSnapshot(snapshot, sessionID: .default).attention

        XCTAssertEqual(attention.map(\.target.paneID), ["a", "b", "z"])
        XCTAssertEqual(attention.map(\.state), [.blocked, .done, .blocked])
        XCTAssertEqual(attention.map(\.visibleLabel), ["alpha · Claude", "Alpha · Claude", "Zulu · Claude"])
        XCTAssertTrue(attention.allSatisfy { $0.recordID == "" && $0.epoch == 0 && $0.message == nil })
    }

    func testAttentionDedupeLastOccurrenceWinsWhenWorkingPrecedesBlocked() {
        let snapshot = herdrSnapshot([
            herdrPane("dup", .working, title: "Dup"),
            herdrPane("other", .done, title: "Other"),
            herdrPane("dup", .blocked, title: "Dup")
        ])

        let attention = HerdrBackend.makeSnapshot(snapshot, sessionID: .default).attention

        XCTAssertEqual(attention.map(\.target.paneID), ["dup", "other"])
        XCTAssertEqual(attention.map(\.state), [.blocked, .done])
    }

    func testAttentionOrderBreaksEqualLabelTiesByPaneID() {
        let snapshot = herdrSnapshot([
            herdrPane("p2", .blocked, title: "Same"),
            herdrPane("p1", .done, title: "Same"),
            herdrPane("b", .blocked, title: "Beta"),
            herdrPane("a", .blocked, title: "beta")
        ])

        let attention = HerdrBackend.makeSnapshot(snapshot, sessionID: .default).attention

        // Case-folded label equality falls through to the pane ID, not the raw label.
        XCTAssertEqual(attention.map(\.target.paneID), ["a", "b", "p1", "p2"])
    }

    func testNamedDefaultAndDefaultProduceDistinctTargets() {
        let snapshot = herdrSnapshot([herdrPane("same", .done)])
        let defaultRow = HerdrBackend.makeSnapshot(snapshot, sessionID: .default).rows[0]
        let namedRow = HerdrBackend.makeSnapshot(snapshot, sessionID: .named("default")).rows[0]
        XCTAssertNotEqual(defaultRow.target, namedRow.target)
    }

    func testJoinedLabelsMatchHerdrForSingleAndMultiTabWorkspaces() {
        let snapshot = PresentationSnapshot(
            panes: [
                herdrPane("single", .done, workspaceID: "dotfiles", tabID: "dotfiles:tab"),
                herdrPane("multi", .done, workspaceID: "menubar", tabID: "menubar:server")
            ],
            workspaces: [
                herdrWorkspace("dotfiles", label: "dotfiles-mac", tabCount: 1),
                herdrWorkspace("menubar", label: "Herdr Menubar", tabCount: 2)
            ],
            tabs: [
                herdrTab("dotfiles:tab", workspaceID: "dotfiles", label: "shell"),
                herdrTab("menubar:server", workspaceID: "menubar", label: "server")
            ]
        )

        let rows = HerdrBackend.makeSnapshot(snapshot, sessionID: .default).rows

        XCTAssertEqual(rows.map(\.displayLabel), ["dotfiles-mac", "Herdr Menubar · server"])
        XCTAssertEqual(rows.map(\.subtitle), ["done · Claude", "done · Claude"])
    }

    func testVisibleLabelsIncludeAgentContextWithoutDuplicateSuffixes() throws {
        let labeledAgentPane = PaneInfo(
            paneID: "bin:pane", terminalID: "terminal", workspaceID: "bin", tabID: "bin:tab",
            focused: false, label: "test-agent", agent: "pi", title: nil, displayAgent: nil,
            agentStatus: .blocked, revision: 1
        )
        let singleTab = try XCTUnwrap(HerdrBackend.row(
            for: labeledAgentPane, sessionID: .default,
            workspace: herdrWorkspace("bin", label: "bin", tabCount: 1),
            tab: herdrTab("bin:tab", workspaceID: "bin", label: "shell")
        ))
        let multiTab = try XCTUnwrap(HerdrBackend.row(
            for: labeledAgentPane, sessionID: .default,
            workspace: herdrWorkspace("workspace", label: "workspace", tabCount: 2),
            tab: herdrTab("workspace:test", workspaceID: "workspace", label: "tab"),
            workspaceIsMultiTab: true
        ))
        let duplicate = try XCTUnwrap(HerdrBackend.row(
            for: labeledAgentPane, sessionID: .default,
            workspace: herdrWorkspace("bin", label: "test-agent", tabCount: 1)
        ))
        let fallbackPane = PaneInfo(
            paneID: "pane-42", terminalID: "terminal", workspaceID: "missing", tabID: "missing:tab",
            focused: false, label: nil, agent: "pi", title: nil, displayAgent: "test-agent",
            agentStatus: .blocked, revision: 1
        )
        let fallback = try XCTUnwrap(HerdrBackend.row(for: fallbackPane, sessionID: .default))

        XCTAssertEqual(singleTab.visibleLabel, "bin · test-agent")
        XCTAssertEqual(multiTab.visibleLabel, "workspace · tab · test-agent")
        XCTAssertEqual(duplicate.visibleLabel, "test-agent")
        XCTAssertEqual(fallback.visibleLabel, "pane-42 · test-agent")
    }

    func testSubtitlesPreservePaneLabelAndDisplayAgentPreference() throws {
        let paneLabel = PaneInfo(
            paneID: "p1", terminalID: "t", workspaceID: "w", tabID: "tab", focused: false,
            label: "test-agent", agent: "pi", title: nil, displayAgent: nil, agentStatus: .blocked, revision: 1
        )
        let displayAgent = PaneInfo(
            paneID: "p2", terminalID: "t", workspaceID: "w", tabID: "tab", focused: false,
            label: "test-agent", agent: "pi", title: nil, displayAgent: "Pi Display", agentStatus: .working, revision: 1
        )
        XCTAssertEqual(try XCTUnwrap(HerdrBackend.row(for: paneLabel, sessionID: .default)).subtitle,
                       "blocked · test-agent")
        XCTAssertEqual(try XCTUnwrap(HerdrBackend.row(for: displayAgent, sessionID: .default)).subtitle,
                       "working · Pi Display")
    }

    func testJoinedLabelFallsBackThroughPaneTitleLabelAndID() {
        let rows = HerdrBackend.makeSnapshot(PresentationSnapshot(panes: [
            herdrPane("title", .done, title: "Pane title", workspaceID: "missing", tabID: "missing:tab"),
            herdrPane("label", .done, label: "Pane label", workspaceID: "missing", tabID: "missing:tab"),
            herdrPane("final-id", .done, workspaceID: "missing", tabID: "missing:tab")
        ], workspaces: [], tabs: []), sessionID: .default).rows

        XCTAssertEqual(rows.map(\.displayLabel), ["Pane title", "Pane label", "final-id"])
    }

    func testDistinctSnapshotTabsMakeWorkspaceMultiTabWhenCountIsStale() {
        let rows = HerdrBackend.makeSnapshot(PresentationSnapshot(
            panes: [herdrPane("server", .working, workspaceID: "w", tabID: "t2")],
            workspaces: [herdrWorkspace("w", label: "Herdr Menubar", tabCount: 1)],
            tabs: [herdrTab("t1", workspaceID: "w", label: "shell"), herdrTab("t2", workspaceID: "w", label: "server")]
        ), sessionID: .default).rows

        XCTAssertEqual(rows.first?.displayLabel, "Herdr Menubar · server")
    }

    // MARK: Events and lifecycle

    func testSupervisorEventsMapOneToOneOntoBackendEvents() async {
        let fixture = HerdrBackendFixture()
        var events = await fixture.backend.events().makeAsyncIterator()
        await fixture.backend.start()
        let work = herdrDescriptor("work")
        let snapshot = herdrSnapshot([herdrPane("p", .blocked)])

        await fixture.supervisor.send(.discoverySnapshot([work]))
        await fixture.supervisor.send(.connected(work, snapshot))
        await fixture.supervisor.send(.snapshot(.named("work"), snapshot))
        await fixture.supervisor.send(.unavailable(.named("work"), "socket unavailable"))
        await fixture.supervisor.send(.removed(.named("work")))

        var received: [BackendEvent] = []
        for _ in 0..<5 {
            if let event = await events.next() { received.append(event) }
        }
        let key = AgentSessionKey(herdr: .named("work"))
        let descriptor = AgentSessionDescriptor(key: key, displayName: "work")
        let expected = HerdrBackend.makeSnapshot(snapshot, sessionID: .named("work"))
        XCTAssertEqual(received, [
            .discovery([descriptor]),
            .connected(descriptor, expected),
            .snapshot(key, expected),
            .sessionUnavailable(key, "socket unavailable"),
            .removed(key)
        ])
        let actions = await fixture.supervisor.actions
        XCTAssertEqual(actions, ["events", "start"])
        await fixture.backend.stop()
    }

    func testRemovalForgetsGhosttyStateOnlyForForwardedSessionsAndOnlyOnce() async {
        let fixture = HerdrBackendFixture()
        var events = await fixture.backend.events().makeAsyncIterator()
        await fixture.backend.start()

        await fixture.supervisor.send(.discoverySnapshot([herdrDescriptor("work")]))
        await fixture.supervisor.send(.removed(.named("work")))
        await fixture.supervisor.send(.removed(.named("work")))
        await fixture.supervisor.send(.removed(.named("never-seen")))
        for _ in 0..<4 { _ = await events.next() }

        XCTAssertEqual(fixture.focuser.forgotten, [.named("work")])
        await fixture.backend.stop()
    }

    func testDisabledHerdrEmitsHiddenAndNeverStartsSupervisor() async {
        let fixture = HerdrBackendFixture(enabledBackends: ["rex"])
        var events = await fixture.backend.events().makeAsyncIterator()

        await fixture.backend.start()

        let first = await events.next()
        XCTAssertEqual(first, .backendHidden)
        let actions = await fixture.supervisor.actions
        XCTAssertEqual(actions, ["events"])
        await fixture.backend.stop()
    }

    func testStopTerminatesSupervisorStreamBeforeStoppingSupervisor() async {
        let fixture = HerdrBackendFixture()
        _ = await fixture.backend.events()
        await fixture.backend.start()

        await fixture.backend.stop()

        let sawTerminated = await fixture.supervisor.stopSawTerminatedStream
        let actions = await fixture.supervisor.actions
        XCTAssertTrue(sawTerminated)
        XCTAssertEqual(actions, ["events", "start", "stop"])
    }

    func testStopWhileEventsAwaitsSupervisorDeliversNothingAfterStop() async {
        let fixture = HerdrBackendFixture(gateEvents: true)
        let eventsTask = Task { await fixture.backend.events() }
        while await !fixture.supervisor.eventsEntered { await Task.yield() }

        await fixture.backend.stop()
        await fixture.supervisor.releaseEvents()
        let stream = await eventsTask.value
        await fixture.supervisor.send(.discoverySnapshot([herdrDescriptor("work")]))

        // The lifecycle guard finishes the stale stream instead of forwarding into it.
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertNil(first)
        let actions = await fixture.supervisor.actions
        XCTAssertEqual(actions, ["events", "stop"])
    }

    // MARK: Selection

    func testFocusServerWrapsFailureWithSessionNameWording() async {
        let fixture = HerdrBackendFixture(
            focusError: HerdrAPIError(code: "pane_not_found", message: "Pane no longer exists")
        )
        do {
            try await fixture.backend.focusServer(herdrTarget(.named("work"), "p"))
            XCTFail("Expected focus failure")
        } catch let error as FocusError {
            XCTAssertEqual(error, .failed("Could not focus pane in work: Pane no longer exists"))
            XCTAssertEqual(error.localizedDescription, "Could not focus pane in work: Pane no longer exists")
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        let actions = await fixture.supervisor.actions
        XCTAssertEqual(actions, ["focus:work:p"])
    }

    func testFocusServerCancelledMidFlightThrowsWrappedFailure() async {
        // The backend surfaces cancellation as an ordinary focus failure; AgentStore's
        // ownsSelection gate is what suppresses the message for a superseded selection.
        let fixture = HerdrBackendFixture(focusHangs: true)
        let focus = Task { try await fixture.backend.focusServer(herdrTarget(.named("work"), "p")) }
        while await !fixture.supervisor.actions.contains("focus:work:p") { await Task.yield() }

        focus.cancel()

        do {
            try await focus.value
            XCTFail("Expected cancelled focus to throw")
        } catch let error as FocusError {
            guard case .failed(let message) = error else { return XCTFail("Unexpected \(error)") }
            XCTAssertTrue(message.hasPrefix("Could not focus pane in work: "), message)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testFocusServerFocusesExactSessionAndPane() async throws {
        let fixture = HerdrBackendFixture()
        try await fixture.backend.focusServer(herdrTarget(.default, "pane-1"))
        let actions = await fixture.supervisor.actions
        XCTAssertEqual(actions, ["focus:Default:pane-1"])
    }

    func testGhosttyActivationFocusesExactSessionAndReportsPartialFocus() async {
        let fixture = HerdrBackendFixture(terminal: GhosttyControlConstants.bundleIdentifier)
        let success = await fixture.backend.activate(herdrTarget(.named("work"), "p"))
        XCTAssertNil(success)

        fixture.focuser.error = .noAttachedClient
        let partial = await fixture.backend.activate(herdrTarget(.named("work"), "p"))

        XCTAssertEqual(partial, "Focused the pane in work, but no attached Ghostty surface was found.")
        XCTAssertEqual(fixture.focuser.focused, [.named("work"), .named("work")])
        XCTAssertTrue(fixture.activator.activated.isEmpty)
    }

    func testOtherTerminalsUseGenericActivationAndReportItsError() async {
        let fixture = HerdrBackendFixture(terminal: "com.apple.Terminal")
        let success = await fixture.backend.activate(herdrTarget(.default, "p"))
        XCTAssertNil(success)

        fixture.activator.error = HerdrBackendTestError.activation
        let failure = await fixture.backend.activate(herdrTarget(.default, "p"))

        XCTAssertEqual(failure, "activation failed")
        XCTAssertEqual(fixture.activator.activated, ["com.apple.Terminal", "com.apple.Terminal"])
        XCTAssertTrue(fixture.focuser.focused.isEmpty)
    }

    func testRefreshAndRetryDelegateToSupervisor() async {
        let fixture = HerdrBackendFixture()
        await fixture.backend.refreshAfterSelection(herdrTarget(.named("work"), "p"))
        await fixture.backend.retryUnavailable()
        await fixture.backend.markSeen(SeenToken(marks: ["ignored"]))
        await fixture.backend.clearFinished()
        let actions = await fixture.supervisor.actions
        XCTAssertEqual(actions, ["refresh:work", "retry"])
    }

    func testCompareSessionsKeepsTodaysComparator() {
        let fixture = HerdrBackendFixture()
        let sessions = [
            AgentSessionDescriptor(herdr: herdrDescriptor("zulu")),
            AgentSessionDescriptor(herdr: herdrDescriptor("alpha")),
            AgentSessionDescriptor(herdr: SessionDescriptor(id: .default, socketURL: URL(fileURLWithPath: "/tmp/d.sock"))),
            AgentSessionDescriptor(herdr: herdrDescriptor("Alpha"))
        ]

        let sorted = sessions.sorted(by: fixture.backend.compareSessions)

        XCTAssertEqual(sorted.map(\.displayName), ["Default", "Alpha", "alpha", "zulu"])
        XCTAssertEqual(fixture.backend.kind, .herdr)
    }
}

@MainActor
private struct HerdrBackendFixture {
    let supervisor: HerdrBackendSupervisor
    let focuser: HerdrBackendGhosttyFocuser
    let activator: HerdrBackendActivator
    let backend: HerdrBackend

    init(
        focusError: (any Error)? = nil,
        terminal: String = GhosttyControlConstants.bundleIdentifier,
        enabledBackends: [String]? = nil,
        gateEvents: Bool = false,
        focusHangs: Bool = false
    ) {
        supervisor = HerdrBackendSupervisor(focusError: focusError, gateEvents: gateEvents, focusHangs: focusHangs)
        focuser = HerdrBackendGhosttyFocuser()
        activator = HerdrBackendActivator()
        let defaults = UserDefaults(suiteName: "dev.herdr.menubar.herdr-backend-tests.\(UUID().uuidString)")!
        if let enabledBackends {
            defaults.set(enabledBackends, forKey: Preferences.enabledBackendsKey)
        }
        let preferences = Preferences(defaults: defaults)
        preferences.selectedTerminalBundleIdentifier = terminal
        backend = HerdrBackend(
            supervisor: supervisor,
            terminalActivator: activator,
            ghosttyFocuser: focuser,
            preferences: preferences
        )
    }
}

private final class HerdrBackendTerminationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

private actor HerdrBackendSupervisor: SessionSupervising {
    private var continuation: AsyncStream<SessionSupervisorEvent>.Continuation?
    private let termination = HerdrBackendTerminationFlag()
    private let focusError: (any Error)?
    private let gateEvents: Bool
    private let focusHangs: Bool
    private var eventsWaiter: CheckedContinuation<Void, Never>?
    private(set) var actions: [String] = []
    private(set) var stopSawTerminatedStream = false
    private(set) var eventsEntered = false

    init(focusError: (any Error)?, gateEvents: Bool = false, focusHangs: Bool = false) {
        self.focusError = focusError
        self.gateEvents = gateEvents
        self.focusHangs = focusHangs
    }

    func events() async -> AsyncStream<SessionSupervisorEvent> {
        actions.append("events")
        if gateEvents {
            eventsEntered = true
            await withCheckedContinuation { eventsWaiter = $0 }
        }
        let (stream, continuation) = AsyncStream<SessionSupervisorEvent>.makeStream()
        let termination = self.termination
        continuation.onTermination = { _ in termination.set() }
        self.continuation = continuation
        return stream
    }

    func start() { actions.append("start") }

    func stop() {
        stopSawTerminatedStream = termination.isSet
        actions.append("stop")
        continuation?.finish()
    }

    func retryUnavailable() { actions.append("retry") }

    func releaseEvents() {
        eventsWaiter?.resume()
        eventsWaiter = nil
    }

    func focus(sessionID: SessionID, paneID: String) async throws -> PaneInfo {
        actions.append("focus:\(sessionID.displayName):\(paneID)")
        if focusHangs { try await Task.sleep(for: .seconds(60)) }
        if let focusError { throw focusError }
        return herdrPane(paneID, .idle)
    }

    func setClientWindowTitle(sessionID: SessionID, title: String) -> ClientWindowTitleResult {
        ClientWindowTitleResult(type: "client_window_title", changed: true, reason: "set")
    }

    func clearClientWindowTitle(sessionID: SessionID, timeout: Duration) -> ClientWindowTitleResult {
        ClientWindowTitleResult(type: "client_window_title", changed: true, reason: "cleared")
    }

    func refresh(sessionID: SessionID) { actions.append("refresh:\(sessionID.displayName)") }

    func send(_ event: SessionSupervisorEvent) { continuation?.yield(event) }
}

@MainActor
private final class HerdrBackendGhosttyFocuser: GhosttySessionFocusing {
    private(set) var focused: [SessionID] = []
    private(set) var forgotten: [SessionID] = []
    var error: GhosttyFocusError?

    func focusAttachedClient(sessionID: SessionID) async throws {
        focused.append(sessionID)
        if let error { throw error }
    }

    func forget(sessionID: SessionID) { forgotten.append(sessionID) }
}

@MainActor
private final class HerdrBackendActivator: TerminalActivating {
    private(set) var activated: [String] = []
    var error: (any Error)?

    func activate(bundleIdentifier: String) async throws {
        activated.append(bundleIdentifier)
        if let error { throw error }
    }
}

private enum HerdrBackendTestError: LocalizedError {
    case activation
    var errorDescription: String? { "activation failed" }
}

private func herdrTarget(_ sessionID: SessionID, _ paneID: String) -> AgentTarget {
    AgentTarget(session: AgentSessionKey(herdr: sessionID), paneID: paneID)
}

private func herdrDescriptor(_ name: String) -> SessionDescriptor {
    SessionDescriptor(id: .named(name), socketURL: URL(fileURLWithPath: "/tmp/\(name).sock"))
}

private func herdrSnapshot(_ panes: [PaneInfo]) -> PresentationSnapshot {
    PresentationSnapshot(panes: panes, workspaces: [], tabs: [])
}

private func herdrPane(
    _ id: String,
    _ status: AgentStatus,
    title: String? = nil,
    label: String? = nil,
    workspaceID: String = "workspace",
    tabID: String = "tab"
) -> PaneInfo {
    PaneInfo(
        paneID: id, terminalID: "terminal-\(id)", workspaceID: workspaceID, tabID: tabID,
        focused: false, label: label, agent: "claude", title: title, displayAgent: "Claude",
        agentStatus: status, revision: 1
    )
}

private func herdrWorkspace(_ id: String, label: String, tabCount: Int) -> WorkspaceInfo {
    WorkspaceInfo(
        workspaceID: id, number: 1, label: label, focused: false, paneCount: 1,
        tabCount: tabCount, activeTabID: "\(id):tab", agentStatus: .working
    )
}

private func herdrTab(_ id: String, workspaceID: String, label: String) -> TabInfo {
    TabInfo(
        tabID: id, workspaceID: workspaceID, number: 1, label: label, focused: false,
        paneCount: 1, agentStatus: .working
    )
}
