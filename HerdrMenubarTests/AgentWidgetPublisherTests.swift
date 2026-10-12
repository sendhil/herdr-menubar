import Foundation
import XCTest
@testable import HerdrMenubar

final class AgentWidgetPublisherTests: XCTestCase {
    func testNoConfiguredWidgetPerformsNoPublicationWork() async {
        let harness = PublisherHarness()
        harness.configuredKinds = []
        let supervisor = WidgetPublisherSupervisor()
        let publisher = AgentWidgetPublisher(supervisor: supervisor, dependencies: harness.dependencies)
        await publisher.start()
        await waitUntil { harness.configurationQueries == 1 }
        await supervisor.send(.connected(Self.descriptor, Self.presentation))
        for _ in 0..<100 { await publisher.tick(); await Task.yield() }
        harness.advance(61)
        await publisher.tick()
        await publisher.stop()
        XCTAssertEqual(harness.activityReads, 0)
        XCTAssertEqual(harness.writes, 0)
        XCTAssertEqual(harness.reloads, 0)
        let refreshes = await supervisor.refreshes
        XCTAssertTrue(refreshes.isEmpty)
    }

    func testProbeWidgetAloneDoesNotStartPublicationTimer() async throws {
        let harness = PublisherHarness()
        harness.configuredKinds = ["HerdrRefreshProbe"]
        var dependencies = harness.dependencies
        dependencies.interval = .milliseconds(5)
        let supervisor = WidgetPublisherSupervisor()
        let publisher = AgentWidgetPublisher(supervisor: supervisor, dependencies: dependencies)
        await publisher.start()
        await waitUntil { harness.configurationQueries == 1 }
        await supervisor.send(.connected(Self.descriptor, Self.presentation))
        try await Task.sleep(for: .milliseconds(50))
        await publisher.stop()
        XCTAssertEqual(harness.publicationCounts, [0, 0, 0])
        let refreshes = await supervisor.refreshes
        XCTAssertTrue(refreshes.isEmpty)
    }

    func testAddingRemovingAndReaddingWidgetUsesCachedSessionState() async throws {
        let harness = PublisherHarness()
        harness.configuredKinds = []
        var dependencies = harness.dependencies
        dependencies.configurationInterval = .milliseconds(10)
        let supervisor = WidgetPublisherSupervisor()
        let publisher = AgentWidgetPublisher(supervisor: supervisor, dependencies: dependencies)
        await publisher.start()
        await supervisor.send(.connected(Self.descriptor, Self.presentation))
        await waitUntil { harness.configurationQueries >= 2 }
        XCTAssertEqual(harness.publicationCounts, [0, 0, 0])

        harness.configuredKinds = ["HerdrAgents", "HerdrAgents"]
        await waitUntil { harness.latest?.agents.count == 1 }
        XCTAssertEqual(harness.reloads, 1)
        let removalQuery = harness.configurationQueries
        harness.configuredKinds = []
        await waitUntil { harness.configurationQueries >= removalQuery + 2 }
        let pausedCounts = harness.publicationCounts
        harness.advance(61)
        var pane = Self.presentation.panes[0]
        pane.agentStatus = .blocked
        let changed = PresentationSnapshot(panes: [pane], workspaces: [], tabs: [])
        await supervisor.send(.snapshot(.default, changed))
        for _ in 0..<100 { await publisher.tick(); await Task.yield() }
        XCTAssertEqual(harness.publicationCounts, pausedCounts)
        let inactiveRefreshes = await supervisor.refreshes
        XCTAssertTrue(inactiveRefreshes.isEmpty)

        harness.configuredKinds = ["HerdrAgents"]
        await waitUntil { harness.latest?.agents.first?.status == "blocked" }
        XCTAssertGreaterThan(harness.writes, pausedCounts[0])
        await publisher.stop()
        let checksAfterStop = harness.configurationQueries
        XCTAssertEqual(harness.latest?.isRunning, false)
        let stoppedCounts = harness.publicationCounts
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(harness.configurationQueries, checksAfterStop)
        XCTAssertEqual(harness.publicationCounts, stoppedCounts)
    }

    func testRemovingLastWidgetCancelsPublicationTimer() async throws {
        let harness = PublisherHarness()
        var dependencies = harness.dependencies
        dependencies.interval = .milliseconds(5)
        dependencies.configurationInterval = .milliseconds(10)
        let supervisor = WidgetPublisherSupervisor()
        let publisher = AgentWidgetPublisher(supervisor: supervisor, dependencies: dependencies)
        await publisher.start()
        await supervisor.send(.connected(Self.descriptor, Self.presentation))
        await waitUntil { harness.activityReads >= 2 }
        let removalQuery = harness.configurationQueries
        harness.configuredKinds = []
        await waitUntil { harness.configurationQueries >= removalQuery + 2 }
        let pausedCounts = harness.publicationCounts
        harness.advance(61)
        try await Task.sleep(for: .milliseconds(40))
        await publisher.stop()
        XCTAssertEqual(harness.publicationCounts, pausedCounts)
        let refreshes = await supervisor.refreshes
        XCTAssertTrue(refreshes.isEmpty)
    }

    func testConfigurationFailurePausesPublicationUntilSuccessfulCheck() async {
        let harness = PublisherHarness()
        var dependencies = harness.dependencies
        dependencies.configurationInterval = .milliseconds(10)
        let supervisor = WidgetPublisherSupervisor()
        let publisher = AgentWidgetPublisher(supervisor: supervisor, dependencies: dependencies)
        await publisher.start()
        await supervisor.send(.connected(Self.descriptor, Self.presentation))
        await settle(publisher, harness: harness)
        let failedQuery = harness.configurationQueries
        harness.failConfigurationQueries = true
        await waitUntil { harness.configurationQueries >= failedQuery + 2 }
        let pausedCounts = harness.publicationCounts
        harness.advance(61)
        await publisher.tick()
        XCTAssertEqual(harness.publicationCounts, pausedCounts)
        let refreshes = await supervisor.refreshes
        XCTAssertTrue(refreshes.isEmpty)

        harness.failConfigurationQueries = false
        await waitUntil { harness.writes > pausedCounts[0] }
        XCTAssertEqual(harness.latest?.agents.count, 1)
        await publisher.stop()
    }

    func testPendingConfigurationDoesNotBlockStartOrReactivateAfterRestart() async {
        let harness = PublisherHarness()
        let query = PendingWidgetConfigurations()
        var dependencies = harness.dependencies
        dependencies.configuredWidgetKinds = { await query.read() }
        let supervisor = WidgetPublisherSupervisor()
        let publisher = AgentWidgetPublisher(supervisor: supervisor, dependencies: dependencies)
        let startup = Task { await publisher.start(); harness.markStartReturned() }
        await waitUntil { await query.count == 1 }
        await waitUntil { harness.startReturned }
        if !harness.startReturned { await query.resolve(0, kinds: []) }
        await publisher.stop()
        await startup.value
        await publisher.start()
        await waitUntil { await query.count == 2 }
        await query.resolve(1, kinds: [])
        await query.resolve(0, kinds: ["HerdrAgents"])
        for _ in 0..<100 { await publisher.tick(); await Task.yield() }
        await publisher.stop()
        XCTAssertEqual(harness.publicationCounts, [0, 0, 0])
    }

    func testReenabledPublisherRejectsPreviousInFlightTick() async {
        let harness = PublisherHarness()
        var dependencies = harness.dependencies
        dependencies.configurationInterval = .milliseconds(10)
        let supervisor = WidgetPublisherSupervisor()
        let publisher = AgentWidgetPublisher(supervisor: supervisor, dependencies: dependencies)
        await publisher.start()
        await supervisor.send(.connected(Self.descriptor, Self.presentation))
        await settle(publisher, harness: harness)
        await supervisor.holdRefreshes()
        harness.advance(61)
        let oldTick = Task { await publisher.tick() }
        await waitUntil { await supervisor.heldRefreshCount == 1 }
        let removalQuery = harness.configurationQueries
        harness.configuredKinds = []
        await waitUntil { harness.configurationQueries >= removalQuery + 2 }
        harness.advance(1)
        harness.configuredKinds = ["HerdrAgents"]
        await waitUntil { harness.latest?.writtenAt == harness.now }
        let newCounts = harness.publicationCounts
        harness.advance(61)
        await supervisor.releaseRefreshes()
        await oldTick.value
        XCTAssertEqual(harness.publicationCounts, newCounts)
        await publisher.stop()
    }

    func testOverlappingTicksCoalesceSessionReconciliation() async {
        let harness = PublisherHarness()
        let supervisor = WidgetPublisherSupervisor()
        let publisher = AgentWidgetPublisher(supervisor: supervisor, dependencies: harness.dependencies)
        await publisher.start()
        await supervisor.send(.connected(Self.descriptor, Self.presentation))
        let other = SessionDescriptor(id: .named("second"), socketURL: Self.descriptor.socketURL)
        await supervisor.send(.connected(other, Self.presentation))
        await waitUntil {
            await publisher.tick()
            return harness.latest?.agents.count == 2
        }
        harness.advance(61)
        await supervisor.holdRefreshes()
        let first = Task { await publisher.tick() }
        await waitUntil { await supervisor.heldRefreshCount == 1 }
        let second = Task { await publisher.tick(); harness.markSecondTickReturned() }
        await waitUntil {
            if harness.secondTickReturned { return true }
            return await supervisor.heldRefreshCount >= 2
        }
        let pending = await supervisor.heldRefreshCount
        XCTAssertEqual(pending, 1, "Only one publication cycle may request refreshes")
        XCTAssertTrue(harness.secondTickReturned)
        await supervisor.releaseRefreshes()
        await first.value
        await second.value
        await waitUntil { await supervisor.refreshes.count >= 2 }
        let requests = await supervisor.refreshes
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(Set(requests), [.default, .named("second")])
        await publisher.stop()
    }

    func testHeartbeatDoesNotClaimSourceVerificationAndRequestsReconciliation() async throws {
        let harness = PublisherHarness()
        let supervisor = WidgetPublisherSupervisor()
        let publisher = AgentWidgetPublisher(supervisor: supervisor, dependencies: harness.dependencies)
        await publisher.start()
        await supervisor.send(.connected(Self.descriptor, Self.presentation))
        await settle(publisher, harness: harness)
        let verified = try XCTUnwrap(harness.latest?.sourceVerifiedAt)
        harness.advance(61)
        await publisher.tick()
        await waitUntil { harness.latest?.writtenAt == harness.now }
        XCTAssertEqual(harness.latest?.sourceVerifiedAt, verified)
        XCTAssertEqual(harness.latest?.writtenAt, harness.now)
        let requests = await supervisor.refreshes
        XCTAssertEqual(requests, [.default])
        await supervisor.send(.snapshot(.default, Self.presentation))
        for _ in 0..<100 {
            await publisher.tick()
            if harness.latest?.sourceVerifiedAt == harness.now { break }
            await Task.yield()
        }
        XCTAssertEqual(harness.latest?.sourceVerifiedAt, harness.now)
        await publisher.stop()
    }

    func testReconciliationBatchesSessionsAndDoesNotAdvanceVerification() async {
        let harness = PublisherHarness()
        let supervisor = WidgetPublisherSupervisor()
        let publisher = AgentWidgetPublisher(supervisor: supervisor, dependencies: harness.dependencies)
        await publisher.start()
        for index in 0..<5 {
            let descriptor = SessionDescriptor(id: .named("session-\(index)"), socketURL: Self.descriptor.socketURL)
            await supervisor.send(.connected(descriptor, Self.presentation))
        }
        await waitUntil {
            await publisher.tick()
            return harness.latest?.agents.count == 5
        }
        let sourceDate = harness.latest?.sourceVerifiedAt
        harness.advance(61)
        await publisher.tick()
        // A coalesced tick may return while the activation timer owns the first batch.
        await waitUntil { await supervisor.refreshes.count >= 4 }
        let firstBatch = await supervisor.refreshes
        XCTAssertEqual(firstBatch.count, 4)
        await waitUntil {
            await publisher.tick()
            return await supervisor.refreshes.count == 5
        }
        let secondBatch = await supervisor.refreshes
        XCTAssertEqual(Set(secondBatch).count, 5)
        XCTAssertEqual(secondBatch.count, 5)
        XCTAssertEqual(harness.latest?.sourceVerifiedAt, sourceDate)
        await publisher.stop()
    }

    func testFailedWriteRetriesWithoutReportingSuccessfulReload() async {
        let harness = PublisherHarness()
        harness.failWrites = true
        let publisher = AgentWidgetPublisher(supervisor: WidgetPublisherSupervisor(), dependencies: harness.dependencies)
        await publisher.start()
        await waitUntil {
            await publisher.tick()
            return harness.writeAttempts > 0
        }
        XCTAssertNil(harness.latest)
        XCTAssertEqual(harness.reloads, 0)
        harness.failWrites = false
        await waitUntil {
            await publisher.tick()
            return harness.latest != nil
        }
        XCTAssertEqual(harness.reloads, 1)
        await publisher.stop()
    }

    func testStopAndRestartRejectOldStreamEvents() async {
        let harness = PublisherHarness()
        let supervisor = WidgetPublisherSupervisor()
        let publisher = AgentWidgetPublisher(supervisor: supervisor, dependencies: harness.dependencies)
        await publisher.start()
        await supervisor.send(.connected(Self.descriptor, Self.presentation))
        await settle(publisher, harness: harness)
        await publisher.stop()
        XCTAssertEqual(harness.latest?.isRunning, false)
        await supervisor.send(.connected(Self.descriptor, Self.presentation), stream: 0)
        await publisher.tick()
        XCTAssertEqual(harness.latest?.isRunning, false)
        await publisher.start()
        await supervisor.send(.connected(Self.descriptor, Self.presentation), stream: 0)
        await publisher.tick()
        XCTAssertEqual(harness.latest?.agents.count, 0)
        await supervisor.send(.connected(Self.descriptor, Self.presentation), stream: 1)
        await settle(publisher, harness: harness)
        XCTAssertEqual(harness.latest?.agents.count, 1)
        await supervisor.send(.unavailable(.default, "disconnected"), stream: 1)
        for _ in 0..<100 {
            await publisher.tick()
            if harness.latest?.unavailableSessions == 1 { break }
            await Task.yield()
        }
        XCTAssertEqual(harness.latest?.agents.count, 0)
        XCTAssertNil(harness.latest?.sourceVerifiedAt)
        XCTAssertEqual(harness.latest?.unavailableSessions, 1)
        await publisher.stop()
    }

    func testExplicitOffSkipsGhostConfigurationsAndAllPublicationWork() async throws {
        let harness = PublisherHarness()
        harness.configuredKinds = ["HerdrAgents", "HerdrRefreshProbe"]
        var dependencies = harness.dependencies
        dependencies.interval = .milliseconds(5)
        dependencies.configurationInterval = .milliseconds(5)
        let supervisor = WidgetPublisherSupervisor()
        let publisher = AgentWidgetPublisher(supervisor: supervisor, dependencies: dependencies)
        await publisher.start(updatesEnabled: false)
        await supervisor.send(.connected(Self.descriptor, Self.presentation))
        harness.advance(61)
        for _ in 0..<100 { await publisher.tick(); await Task.yield() }
        try await Task.sleep(for: .milliseconds(40))
        await publisher.stop()
        XCTAssertEqual(harness.configurationQueries, 0)
        XCTAssertEqual(harness.publicationCounts, [0, 0, 0])
        let refreshes = await supervisor.refreshes
        XCTAssertTrue(refreshes.isEmpty)
    }

    func testExplicitOffCancelsConfigurationAndPublicationTimers() async throws {
        let harness = PublisherHarness()
        var dependencies = harness.dependencies
        dependencies.interval = .milliseconds(5)
        dependencies.configurationInterval = .milliseconds(5)
        let supervisor = WidgetPublisherSupervisor()
        let publisher = AgentWidgetPublisher(supervisor: supervisor, dependencies: dependencies)
        await publisher.start()
        await supervisor.send(.connected(Self.descriptor, Self.presentation))
        await waitUntil { harness.activityReads >= 2 && harness.configurationQueries >= 2 }
        await publisher.setUpdatesEnabled(false)
        let pausedCounts = harness.publicationCounts
        let pausedQueries = harness.configurationQueries
        harness.advance(61)
        try await Task.sleep(for: .milliseconds(40))
        await publisher.tick()
        await publisher.stop()
        XCTAssertEqual(harness.publicationCounts, pausedCounts)
        XCTAssertEqual(harness.configurationQueries, pausedQueries)
        let refreshes = await supervisor.refreshes
        XCTAssertTrue(refreshes.isEmpty)
    }

    func testAutomaticAfterExplicitOffPublishesLatestCachedSessionWithoutReconnect() async {
        let harness = PublisherHarness()
        let supervisor = WidgetPublisherSupervisor()
        let publisher = AgentWidgetPublisher(supervisor: supervisor, dependencies: harness.dependencies)
        await publisher.start(updatesEnabled: false)
        await supervisor.send(.connected(Self.descriptor, Self.presentation))
        var pane = Self.presentation.panes[0]
        pane.agentStatus = .blocked
        await supervisor.send(.snapshot(.default, PresentationSnapshot(panes: [pane], workspaces: [], tabs: [])))
        XCTAssertEqual(harness.configurationQueries, 0)
        await publisher.setUpdatesEnabled(true)
        // Stream delivery is asynchronous; the harness's automatic tick sleeps for an hour.
        await waitUntil {
            await publisher.tick()
            return harness.latest?.agents.first?.status == "blocked"
        }
        XCTAssertEqual(harness.latest?.agents.map(\.status), ["blocked"])
        XCTAssertEqual(harness.configurationQueries, 1)
        let refreshes = await supervisor.refreshes
        XCTAssertTrue(refreshes.isEmpty)
        await publisher.setUpdatesEnabled(false)
        let pausedCounts = harness.publicationCounts
        pane.agentStatus = .working
        await supervisor.send(.snapshot(.default, PresentationSnapshot(panes: [pane], workspaces: [], tabs: [])))
        for _ in 0..<100 { await publisher.tick(); await Task.yield() }
        XCTAssertEqual(harness.publicationCounts, pausedCounts)
        await publisher.setUpdatesEnabled(true)
        await waitUntil { harness.latest?.agents.first?.status == "working" }
        XCTAssertEqual(harness.configurationQueries, 2)
        await publisher.stop()
    }

    func testExplicitOffRejectsLatePositiveConfigurationAfterAutomaticRestart() async {
        let harness = PublisherHarness()
        let query = PendingWidgetConfigurations()
        var dependencies = harness.dependencies
        dependencies.configuredWidgetKinds = { await query.read() }
        let publisher = AgentWidgetPublisher(supervisor: WidgetPublisherSupervisor(), dependencies: dependencies)
        await publisher.start()
        await waitUntil { await query.count == 1 }
        await publisher.setUpdatesEnabled(false)
        await publisher.setUpdatesEnabled(true)
        await waitUntil { await query.count == 2 }
        await query.resolve(1, kinds: [])
        await query.resolve(0, kinds: ["HerdrAgents"])
        for _ in 0..<100 { await publisher.tick(); await Task.yield() }
        await publisher.setUpdatesEnabled(false)
        await publisher.stop()
        XCTAssertEqual(harness.publicationCounts, [0, 0, 0])
    }

    func testExplicitOffRejectsInFlightRefreshTick() async {
        let harness = PublisherHarness()
        let supervisor = WidgetPublisherSupervisor()
        let publisher = AgentWidgetPublisher(supervisor: supervisor, dependencies: harness.dependencies)
        await publisher.start()
        await supervisor.send(.connected(Self.descriptor, Self.presentation))
        await settle(publisher, harness: harness)
        await supervisor.holdRefreshes()
        harness.advance(61)
        let oldTick = Task { await publisher.tick() }
        await waitUntil { await supervisor.heldRefreshCount == 1 }
        await publisher.setUpdatesEnabled(false)
        let pausedCounts = harness.publicationCounts
        await supervisor.releaseRefreshes()
        await oldTick.value
        await publisher.tick()
        await publisher.stop()
        XCTAssertEqual(harness.publicationCounts, pausedCounts)
    }

    func testCancelledModeChangeCannotReenableExplicitOff() async {
        let harness = PublisherHarness()
        let publisher = AgentWidgetPublisher(supervisor: WidgetPublisherSupervisor(), dependencies: harness.dependencies)
        await publisher.start(updatesEnabled: false)
        let obsoleteChange = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await publisher.setUpdatesEnabled(true)
        }
        await obsoleteChange.value
        for _ in 0..<100 { await publisher.tick(); await Task.yield() }
        await publisher.stop()
        XCTAssertEqual(harness.configurationQueries, 0)
        XCTAssertEqual(harness.publicationCounts, [0, 0, 0])
    }

    private func settle(_ publisher: AgentWidgetPublisher, harness: PublisherHarness) async {
        await waitUntil {
            await publisher.tick()
            return harness.latest?.agents.count == 1
        }
    }

    private func waitUntil(
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: @escaping () async -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        let reached = await condition()
        XCTAssertTrue(reached, "Condition did not become true", file: file, line: line)
    }
    private static let descriptor = SessionDescriptor(id: .default, socketURL: URL(fileURLWithPath: "/tmp/widget-test.sock"))
    private static let presentation = PresentationSnapshot(panes: [PaneInfo(
        paneID: "p1", terminalID: "term", workspaceID: "w1", tabID: "t1", focused: false,
        label: nil, agent: "pi", title: nil, displayAgent: nil, agentStatus: .idle, revision: 1
    )], workspaces: [], tabs: [])
}

private final class PublisherHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 100_000)
    private var snapshots: [AgentWidgetSnapshot] = []
    private var writeAttemptCount = 0
    private var reloadCount = 0
    private var activityReadCount = 0
    private var kinds = ["HerdrAgents"]
    private var configurationQueryCount = 0
    private var shouldFailConfiguration = false
    private var didStartReturn = false
    private var didSecondTickReturn = false
    private var shouldFail = false
    var now: Date { lock.withLock { date } }
    var latest: AgentWidgetSnapshot? { lock.withLock { snapshots.last } }
    var writes: Int { lock.withLock { snapshots.count } }
    var writeAttempts: Int { lock.withLock { writeAttemptCount } }
    var reloads: Int { lock.withLock { reloadCount } }
    var activityReads: Int { lock.withLock { activityReadCount } }
    var publicationCounts: [Int] { lock.withLock { [snapshots.count, reloadCount, activityReadCount] } }
    var configurationQueries: Int { lock.withLock { configurationQueryCount } }
    var startReturned: Bool { lock.withLock { didStartReturn } }
    func markStartReturned() { lock.withLock { didStartReturn = true } }
    var secondTickReturned: Bool { lock.withLock { didSecondTickReturn } }
    func markSecondTickReturned() { lock.withLock { didSecondTickReturn = true } }
    var failConfigurationQueries: Bool {
        get { lock.withLock { shouldFailConfiguration } }
        set { lock.withLock { shouldFailConfiguration = newValue } }
    }
    var configuredKinds: [String] {
        get { lock.withLock { kinds } }
        set { lock.withLock { kinds = newValue } }
    }
    var failWrites: Bool {
        get { lock.withLock { shouldFail } }
        set { lock.withLock { shouldFail = newValue } }
    }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
    var dependencies: AgentWidgetPublisher.Dependencies {
        .init(now: { self.now }, activity: { _ in
            self.lock.withLock { self.activityReadCount += 1 }
            return nil
        }, write: { snapshot in
            try self.lock.withLock {
                self.writeAttemptCount += 1
                if self.shouldFail { throw CocoaError(.fileWriteUnknown) }
                self.snapshots.append(snapshot)
            }
        }, reload: { self.lock.withLock { self.reloadCount += 1 } }, interval: .seconds(3600),
        configuredWidgetKinds: {
            try self.lock.withLock {
                self.configurationQueryCount += 1
                if self.shouldFailConfiguration { throw CocoaError(.featureUnsupported) }
                return self.kinds
            }
        }, configurationInterval: .seconds(3600))
    }
}

private actor PendingWidgetConfigurations {
    private(set) var count = 0
    private var pending: [Int: CheckedContinuation<[String], Never>] = [:]
    func read() async -> [String] {
        let index = count
        count += 1
        return await withCheckedContinuation { pending[index] = $0 }
    }
    func resolve(_ index: Int, kinds: [String]) {
        pending.removeValue(forKey: index)?.resume(returning: kinds)
    }
}

private actor WidgetPublisherSupervisor: SessionSupervising {
    private var streams: [AsyncStream<SessionSupervisorEvent>.Continuation] = []
    private(set) var refreshes: [SessionID] = []
    private var holdingRefreshes = false
    private var heldRefreshes: [CheckedContinuation<Void, Never>] = []
    var heldRefreshCount: Int { heldRefreshes.count }
    func holdRefreshes() { holdingRefreshes = true }
    func releaseRefreshes() {
        holdingRefreshes = false
        let pending = heldRefreshes
        heldRefreshes.removeAll()
        for waiter in pending { waiter.resume() }
    }
    func events() -> AsyncStream<SessionSupervisorEvent> {
        let (stream, continuation) = AsyncStream<SessionSupervisorEvent>.makeStream()
        streams.append(continuation)
        return stream
    }
    func send(_ event: SessionSupervisorEvent, stream: Int = 0) { streams[stream].yield(event) }
    func start() {}
    func stop() {}
    func retryUnavailable() {}
    func refresh(sessionID: SessionID) async {
        refreshes.append(sessionID)
        if holdingRefreshes {
            await withCheckedContinuation { heldRefreshes.append($0) }
        }
    }
    func focus(sessionID: SessionID, paneID: String) throws -> PaneInfo { throw CocoaError(.featureUnsupported) }
    func setClientWindowTitle(sessionID: SessionID, title: String) throws -> ClientWindowTitleResult { throw CocoaError(.featureUnsupported) }
    func clearClientWindowTitle(sessionID: SessionID, timeout: Duration) throws -> ClientWindowTitleResult { throw CocoaError(.featureUnsupported) }
}
