import XCTest
@testable import HerdrMenubar

@MainActor
final class AgentStoreTests: XCTestCase {
    func testGroupsAndDeterministicallySortsAgentRows() {
        let store = AgentStore(client: FakeAgentClient(), terminalActivator: RecordingActivator())

        store.apply(snapshot: snapshot([
            pane("done-z", .done, title: "Zulu"),
            pane("blocked-z", .blocked, title: "zulu"),
            pane("blocked-a2", .blocked, title: "Alpha"),
            pane("blocked-a1", .blocked, title: "alpha"),
            pane("working-z", .working, title: "Zulu"),
            pane("working-a", .working, title: "alpha"),
            pane("idle", .idle),
            pane("unknown", .unknown)
        ]))

        XCTAssertEqual(store.attentionItems.map(\.paneID), ["blocked-a1", "blocked-a2", "blocked-z", "done-z"])
        XCTAssertEqual(store.attentionItems.map(\.status), [.blocked, .blocked, .blocked, .done])
        XCTAssertEqual(store.workingItems.map(\.paneID), ["working-a", "working-z"])
        XCTAssertEqual(store.attentionCount, 4)
    }

    func testJoinedLabelsMatchHerdrForSingleAndMultiTabWorkspaces() {
        let store = AgentStore(client: FakeAgentClient(), terminalActivator: RecordingActivator())
        let panes = [
            pane("single", .done, workspaceID: "dotfiles", tabID: "dotfiles:tab"),
            pane("multi", .done, workspaceID: "menubar", tabID: "menubar:server")
        ]
        let workspaces = [
            workspace("dotfiles", label: "dotfiles-mac", tabCount: 1),
            workspace("menubar", label: "Herdr Menubar", tabCount: 2)
        ]
        let tabs = [
            tab("dotfiles:tab", workspaceID: "dotfiles", label: "shell"),
            tab("menubar:server", workspaceID: "menubar", label: "server")
        ]

        store.apply(snapshot: PresentationSnapshot(panes: panes, workspaces: workspaces, tabs: tabs))

        XCTAssertEqual(store.attentionItems.map(\.displayLabel), ["dotfiles-mac", "Herdr Menubar · server"])
        XCTAssertEqual(store.attentionItems.map(\.secondaryLabel), ["done · Claude", "done · Claude"])
    }

    func testVisibleLabelsIncludeAgentContextWithoutDuplicateSuffixes() {
        let labeledAgentPane = PaneInfo(
            paneID: "bin:pane", terminalID: "terminal", workspaceID: "bin", tabID: "bin:tab",
            focused: false, label: "test-agent", agent: "pi", title: nil, displayAgent: nil,
            agentStatus: .idle, revision: 1
        )
        let singleTabItem = AgentMenuItem(
            pane: labeledAgentPane,
            workspace: workspace("bin", label: "bin", tabCount: 1),
            tab: tab("bin:tab", workspaceID: "bin", label: "shell")
        )
        let multiTabItem = AgentMenuItem(
            pane: labeledAgentPane,
            workspace: workspace("workspace", label: "workspace", tabCount: 2),
            tab: tab("workspace:test", workspaceID: "workspace", label: "tab"),
            workspaceIsMultiTab: true
        )
        let duplicateItem = AgentMenuItem(
            pane: labeledAgentPane,
            workspace: workspace("bin", label: "test-agent", tabCount: 1)
        )
        let fallbackPane = PaneInfo(
            paneID: "pane-42", terminalID: "terminal", workspaceID: "missing", tabID: "missing:tab",
            focused: false, label: nil, agent: "pi", title: nil, displayAgent: "test-agent",
            agentStatus: .idle, revision: 1
        )

        XCTAssertEqual(singleTabItem.visibleLabel, "bin · test-agent")
        XCTAssertEqual(multiTabItem.visibleLabel, "workspace · tab · test-agent")
        XCTAssertEqual(duplicateItem.visibleLabel, "test-agent")
        XCTAssertEqual(AgentMenuItem(pane: fallbackPane).visibleLabel, "pane-42 · test-agent")
    }

    func testSecondaryLabelPrefersHerdrPaneLabelOverDetectedAgent() {
        let pane = PaneInfo(
            paneID: "bin:pane", terminalID: "terminal", workspaceID: "bin", tabID: "bin:tab",
            focused: false, label: "test-agent", agent: "pi", title: nil, displayAgent: nil,
            agentStatus: .idle, revision: 1
        )

        let item = AgentMenuItem(pane: pane)

        XCTAssertEqual(item.secondaryLabel, "idle · test-agent")
    }

    func testSecondaryLabelStillPrefersDisplayAgentOverPaneLabel() {
        let pane = PaneInfo(
            paneID: "bin:pane", terminalID: "terminal", workspaceID: "bin", tabID: "bin:tab",
            focused: false, label: "test-agent", agent: "pi", title: nil, displayAgent: "Pi Display",
            agentStatus: .idle, revision: 1
        )

        let item = AgentMenuItem(pane: pane)

        XCTAssertEqual(item.secondaryLabel, "idle · Pi Display")
    }

    func testJoinedLabelFallsBackThroughPaneTitleLabelAndID() {
        let store = AgentStore(client: FakeAgentClient(), terminalActivator: RecordingActivator())
        let panes = [
            pane("title", .done, title: "Pane title", workspaceID: "missing", tabID: "missing:tab"),
            pane("label", .done, label: "Pane label", workspaceID: "missing", tabID: "missing:tab"),
            pane("final-id", .done, workspaceID: "missing", tabID: "missing:tab")
        ]

        store.apply(snapshot: PresentationSnapshot(panes: panes, workspaces: [], tabs: []))

        XCTAssertEqual(store.attentionItems.map(\.displayLabel), ["final-id", "Pane label", "Pane title"])
    }

    func testDistinctSnapshotTabsMakeWorkspaceMultiTabWhenCountIsStale() {
        let store = AgentStore(client: FakeAgentClient(), terminalActivator: RecordingActivator())
        let panes = [pane("server", .working, workspaceID: "w", tabID: "t2")]
        let snapshot = PresentationSnapshot(
            panes: panes,
            workspaces: [workspace("w", label: "Herdr Menubar", tabCount: 1)],
            tabs: [tab("t1", workspaceID: "w", label: "shell"), tab("t2", workspaceID: "w", label: "server")]
        )

        store.apply(snapshot: snapshot)

        XCTAssertEqual(store.workingItems.first?.displayLabel, "Herdr Menubar · server")
    }

    func testDisconnectedEventClearsVisibleRowsAndRetryDelegatesToClient() async {
        let client = FakeAgentClient()
        let store = AgentStore(client: client, terminalActivator: RecordingActivator())
        await store.start()
        await client.send(.connected(snapshot([pane("blocked", .blocked)])))
        await eventually { store.attentionCount == 1 }

        await client.send(.disconnected("socket unavailable"))
        await eventually { store.connectionState == .disconnected("socket unavailable") }
        XCTAssertTrue(store.attentionItems.isEmpty)
        XCTAssertTrue(store.workingItems.isEmpty)

        await store.retry()
        let retryCount = await client.retryCount
        XCTAssertEqual(retryCount, 1)
        XCTAssertNil(store.transientError)
        await store.stop()
    }

    func testStopClearsRowsSetsDisconnectedAndStopsClientOnce() async {
        let client = FakeAgentClient()
        let store = AgentStore(client: client, terminalActivator: RecordingActivator())
        await store.start()
        await client.send(.connected(snapshot([
            pane("blocked", .blocked),
            pane("working", .working)
        ])))
        await eventually { store.attentionCount == 1 && store.workingItems.count == 1 }

        await store.stop()
        await store.stop()

        XCTAssertEqual(store.connectionState, .disconnected("Disconnected from Herdr"))
        XCTAssertTrue(store.attentionItems.isEmpty)
        XCTAssertTrue(store.workingItems.isEmpty)
        let stopCount = await client.stopCount
        XCTAssertEqual(stopCount, 1)
    }

    func testEventsAfterStopDoNotRepopulateRows() async {
        let client = FakeAgentClient()
        let store = AgentStore(client: client, terminalActivator: RecordingActivator())
        await store.start()
        await store.stop()

        await client.send(.connected(snapshot([pane("stale", .blocked)])))
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(store.connectionState, .disconnected("Disconnected from Herdr"))
        XCTAssertTrue(store.attentionItems.isEmpty)
        XCTAssertTrue(store.workingItems.isEmpty)
    }

    func testMenuBarAccessibilityValuesDescribeState() {
        XCTAssertEqual(
            MenuBarIcon.accessibilityValue(
                connectionState: .disconnected("socket unavailable"),
                attentionCount: 3
            ),
            "Disconnected"
        )
        XCTAssertEqual(
            MenuBarIcon.accessibilityValue(connectionState: .connected, attentionCount: 0),
            "Connected, no agents need attention"
        )
        XCTAssertEqual(
            MenuBarIcon.accessibilityValue(connectionState: .connected, attentionCount: 1),
            "Connected, 1 agent needs attention"
        )
        XCTAssertEqual(
            MenuBarIcon.accessibilityValue(connectionState: .connected, attentionCount: 3),
            "Connected, 3 agents need attention"
        )
    }

    func testSelectionFocusesBeforeActivationThenRefreshes() async {
        let sequence = ActionSequence()
        let client = FakeAgentClient(sequence: sequence)
        let activator = RecordingActivator(sequence: sequence)
        let store = AgentStore(client: client, terminalActivator: activator)

        await store.select(AgentMenuItem(pane: pane("p", .blocked)))

        let values = await sequence.values
        XCTAssertEqual(values, ["focus:p", "activate:com.github.wez.wezterm", "refresh"])
        XCTAssertNil(store.transientError)
    }

    func testSelectionReadsCurrentTerminalPreferenceAfterFocusSucceeds() async {
        let suiteName = "dev.herdr.menubar.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(
            preferences.selectedTerminalBundleIdentifier,
            "com.github.wez.wezterm"
        )
        let client = FakeAgentClient(focusAction: {
            await MainActor.run {
                preferences.selectedTerminalBundleIdentifier = "com.mitchellh.ghostty"
            }
        })
        let activator = RecordingActivator()
        let store = AgentStore(
            client: client,
            terminalActivator: activator,
            preferences: preferences
        )

        await store.select(AgentMenuItem(pane: pane("p", .blocked)))

        XCTAssertEqual(activator.activatedBundleIdentifiers, ["com.mitchellh.ghostty"])
    }

    func testFailedFocusDoesNotActivateOrRefreshAndShowsTransientError() async {
        let client = FakeAgentClient(focusError: TestFailure.focus)
        let activator = RecordingActivator()
        let store = AgentStore(client: client, terminalActivator: activator)

        await store.select(AgentMenuItem(pane: pane("p", .blocked)))

        let activationCount = activator.activationCount
        let refreshCount = await client.refreshCount
        XCTAssertEqual(activationCount, 0)
        XCTAssertEqual(refreshCount, 0)
        XCTAssertNotNil(store.transientError)
    }

    func testActivationFailureAfterFocusStillRefreshesAndShowsTransientError() async {
        let sequence = ActionSequence()
        let client = FakeAgentClient(sequence: sequence)
        let activator = RecordingActivator(error: TestFailure.activation, sequence: sequence)
        let store = AgentStore(client: client, terminalActivator: activator)

        await store.select(AgentMenuItem(pane: pane("p", .done)))

        let values = await sequence.values
        XCTAssertEqual(values, ["focus:p", "activate:com.github.wez.wezterm", "refresh"])
        XCTAssertNotNil(store.transientError)
    }

    private func eventually(
        timeout: Duration = .seconds(1),
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition())
    }
}

private enum TestFailure: Error {
    case focus
    case activation
}

private actor ActionSequence {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private actor FakeAgentClient: AgentClientServing {
    private var continuation: AsyncStream<HerdrClientEvent>.Continuation?
    private(set) var retryCount = 0
    private(set) var refreshCount = 0
    private(set) var stopCount = 0
    private let focusError: (any Error)?
    private let sequence: ActionSequence?
    private let focusAction: (@Sendable () async -> Void)?

    init(
        focusError: (any Error)? = nil,
        sequence: ActionSequence? = nil,
        focusAction: (@Sendable () async -> Void)? = nil
    ) {
        self.focusError = focusError
        self.sequence = sequence
        self.focusAction = focusAction
    }

    func events() -> AsyncStream<HerdrClientEvent> {
        let (stream, continuation) = AsyncStream<HerdrClientEvent>.makeStream()
        self.continuation = continuation
        return stream
    }

    func start() {}
    func stop() { stopCount += 1 }

    func retryNow() {
        retryCount += 1
    }

    func refresh() async {
        refreshCount += 1
        await sequence?.append("refresh")
    }

    func focus(paneID: String) async throws -> PaneInfo {
        await sequence?.append("focus:\(paneID)")
        if let focusError { throw focusError }
        await focusAction?()
        return pane(paneID, .idle)
    }

    func send(_ event: HerdrClientEvent) {
        continuation?.yield(event)
    }
}

@MainActor
private final class RecordingActivator: TerminalActivating {
    private(set) var activationCount = 0
    private(set) var activatedBundleIdentifiers: [String] = []
    private let error: (any Error)?
    private let sequence: ActionSequence?

    init(error: (any Error)? = nil, sequence: ActionSequence? = nil) {
        self.error = error
        self.sequence = sequence
    }

    func activate(bundleIdentifier: String) async throws {
        activationCount += 1
        activatedBundleIdentifiers.append(bundleIdentifier)
        await sequence?.append("activate:\(bundleIdentifier)")
        if let error { throw error }
    }
}

private func snapshot(_ panes: [PaneInfo]) -> PresentationSnapshot {
    PresentationSnapshot(panes: panes, workspaces: [], tabs: [])
}

private func pane(
    _ id: String,
    _ status: AgentStatus,
    title: String? = nil,
    label: String? = nil,
    workspaceID: String = "workspace",
    tabID: String = "tab"
) -> PaneInfo {
    PaneInfo(
        paneID: id,
        terminalID: "terminal-\(id)",
        workspaceID: workspaceID,
        tabID: tabID,
        focused: false,
        label: label,
        agent: "claude",
        title: title,
        displayAgent: "Claude",
        agentStatus: status,
        revision: 1
    )
}

private func workspace(_ id: String, label: String, tabCount: Int) -> WorkspaceInfo {
    WorkspaceInfo(
        workspaceID: id,
        number: 1,
        label: label,
        focused: false,
        paneCount: 1,
        tabCount: tabCount,
        activeTabID: "\(id):tab",
        agentStatus: .working
    )
}

private func tab(_ id: String, workspaceID: String, label: String) -> TabInfo {
    TabInfo(
        tabID: id,
        workspaceID: workspaceID,
        number: 1,
        label: label,
        focused: false,
        paneCount: 1,
        agentStatus: .working
    )
}
