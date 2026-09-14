import Foundation
import XCTest
@testable import HerdrMenubar

final class AgentWidgetPublisherTests: XCTestCase {
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
        for _ in 0..<100 {
            await publisher.tick()
            if harness.latest?.agents.count == 5 { break }
            await Task.yield()
        }
        XCTAssertEqual(harness.latest?.agents.count, 5)
        let sourceDate = harness.latest?.sourceVerifiedAt
        harness.advance(61)
        await publisher.tick()
        let firstBatch = await supervisor.refreshes
        XCTAssertEqual(firstBatch.count, 4)
        await publisher.tick()
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
        await publisher.tick()
        XCTAssertNil(harness.latest)
        XCTAssertEqual(harness.reloads, 0)
        harness.failWrites = false
        await publisher.tick()
        XCTAssertNotNil(harness.latest)
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

    private func settle(_ publisher: AgentWidgetPublisher, harness: PublisherHarness) async {
        for _ in 0..<100 {
            await publisher.tick()
            if harness.latest?.agents.count == 1 { return }
            await Task.yield()
        }
        XCTFail("Source event was not published")
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
    private var reloadCount = 0
    private var shouldFail = false
    var now: Date { lock.withLock { date } }
    var latest: AgentWidgetSnapshot? { lock.withLock { snapshots.last } }
    var reloads: Int { lock.withLock { reloadCount } }
    var failWrites: Bool {
        get { lock.withLock { shouldFail } }
        set { lock.withLock { shouldFail = newValue } }
    }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
    var dependencies: AgentWidgetPublisher.Dependencies {
        .init(now: { self.now }, activity: { _ in nil }, write: { snapshot in
            try self.lock.withLock {
                if self.shouldFail { throw CocoaError(.fileWriteUnknown) }
                self.snapshots.append(snapshot)
            }
        }, reload: { self.lock.withLock { self.reloadCount += 1 } }, interval: .seconds(3600))
    }
}

private actor WidgetPublisherSupervisor: SessionSupervising {
    private var streams: [AsyncStream<SessionSupervisorEvent>.Continuation] = []
    private(set) var refreshes: [SessionID] = []
    func events() -> AsyncStream<SessionSupervisorEvent> {
        let (stream, continuation) = AsyncStream<SessionSupervisorEvent>.makeStream()
        streams.append(continuation)
        return stream
    }
    func send(_ event: SessionSupervisorEvent, stream: Int = 0) { streams[stream].yield(event) }
    func start() {}
    func stop() {}
    func retryUnavailable() {}
    func refresh(sessionID: SessionID) { refreshes.append(sessionID) }
    func focus(sessionID: SessionID, paneID: String) throws -> PaneInfo { throw CocoaError(.featureUnsupported) }
    func setClientWindowTitle(sessionID: SessionID, title: String) throws -> ClientWindowTitleResult { throw CocoaError(.featureUnsupported) }
    func clearClientWindowTitle(sessionID: SessionID, timeout: Duration) throws -> ClientWindowTitleResult { throw CocoaError(.featureUnsupported) }
}
