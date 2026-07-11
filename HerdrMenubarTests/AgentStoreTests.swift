import XCTest
@testable import HerdrMenubar

@MainActor
final class AgentStoreTests: XCTestCase {
    func testGroupsAndDeterministicallySortsAgentRows() {
        let store = AgentStore(client: FakeAgentClient(), terminalActivator: RecordingActivator())

        store.apply(snapshot: [
            pane("done-z", .done, title: "Zulu"),
            pane("blocked-z", .blocked, title: "zulu"),
            pane("blocked-a2", .blocked, title: "Alpha"),
            pane("blocked-a1", .blocked, title: "alpha"),
            pane("working-z", .working, title: "Zulu"),
            pane("working-a", .working, title: "alpha"),
            pane("idle", .idle),
            pane("unknown", .unknown)
        ])

        XCTAssertEqual(store.attentionItems.map(\.paneID), ["blocked-a1", "blocked-a2", "blocked-z", "done-z"])
        XCTAssertEqual(store.attentionItems.map(\.status), [.blocked, .blocked, .blocked, .done])
        XCTAssertEqual(store.workingItems.map(\.paneID), ["working-a", "working-z"])
        XCTAssertEqual(store.attentionCount, 4)
    }

    func testDisconnectedEventClearsVisibleRowsAndRetryDelegatesToClient() async {
        let client = FakeAgentClient()
        let store = AgentStore(client: client, terminalActivator: RecordingActivator())
        await store.start()
        await client.send(.connected([pane("blocked", .blocked)]))
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
        await client.send(.connected([
            pane("blocked", .blocked),
            pane("working", .working)
        ]))
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

        await client.send(.connected([pane("stale", .blocked)]))
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
        XCTAssertEqual(values, ["focus:p", "activate", "refresh"])
        XCTAssertNil(store.transientError)
    }

    func testFailedFocusDoesNotActivateOrRefreshAndShowsTransientError() async {
        let client = FakeAgentClient(focusError: TestFailure.focus)
        let activator = RecordingActivator()
        let store = AgentStore(client: client, terminalActivator: activator)

        await store.select(AgentMenuItem(pane: pane("p", .blocked)))

        let activationCount = await activator.activationCount
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
        XCTAssertEqual(values, ["focus:p", "activate", "refresh"])
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

    init(focusError: (any Error)? = nil, sequence: ActionSequence? = nil) {
        self.focusError = focusError
        self.sequence = sequence
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
        return pane(paneID, .idle)
    }

    func send(_ event: HerdrClientEvent) {
        continuation?.yield(event)
    }
}

private actor RecordingActivator: TerminalActivating {
    private(set) var activationCount = 0
    private let error: (any Error)?
    private let sequence: ActionSequence?

    init(error: (any Error)? = nil, sequence: ActionSequence? = nil) {
        self.error = error
        self.sequence = sequence
    }

    func activate() async throws {
        activationCount += 1
        await sequence?.append("activate")
        if let error { throw error }
    }
}

private func pane(_ id: String, _ status: AgentStatus, title: String? = nil) -> PaneInfo {
    PaneInfo(
        paneID: id,
        terminalID: "terminal-\(id)",
        workspaceID: "workspace",
        tabID: "tab",
        focused: false,
        label: nil,
        agent: "claude",
        title: title,
        displayAgent: "Claude",
        agentStatus: status,
        revision: 1
    )
}
