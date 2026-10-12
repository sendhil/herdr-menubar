import Foundation
import XCTest
@testable import HerdrMenubar

final class Protocol16HerdrClientTests: XCTestCase {
    private func client(_ server: Protocol16HerdrServer) -> HerdrClient {
        HerdrClient(
            socketURL: URL(fileURLWithPath: "/tmp/protocol16-herdr.sock"),
            connectionFactory: server,
            backoff: BackoffPolicy(delays: [.seconds(15)], jitter: { 0 })
        )
    }

    private func record(_ stream: AsyncStream<HerdrClientEvent>, in recorder: ClientEventRecorder) -> Task<Void, Never> {
        Task {
            for await event in stream {
                guard !Task.isCancelled else { return }
                await recorder.append(event)
            }
        }
    }

    private func assertEventually(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () async -> Bool
    ) async {
        let matched = await eventuallyForProtocol16(condition)
        XCTAssertTrue(matched, "Condition did not become true", file: file, line: line)
    }

    func testProtocol16ServerClosesOnSecondSubscribe() async throws {
        let server = Protocol16HerdrServer(panes: [:])
        let socket = try await server.connect(to: URL(fileURLWithPath: "/tmp/protocol16-herdr.sock"))
        let first = HerdrRequest(id: "one", method: "events.subscribe", params: EmptyParams())
        try await socket.sendLine(JSONEncoder().encode(first))
        let acknowledged = try await socket.nextLine()
        XCTAssertNotNil(acknowledged)
        let second = HerdrRequest(id: "two", method: "events.subscribe", params: EmptyParams())
        try await socket.sendLine(JSONEncoder().encode(second))
        let closed = try await socket.nextLine()
        XCTAssertNil(closed)
        let count = await server.subscribeAttempts
        XCTAssertEqual(count, 2)
    }

    func testProtocol16ServerClosesOrdinarySocketAfterResponse() async throws {
        let server = Protocol16HerdrServer(panes: ["A": .working])
        let socket = try await server.connect(to: URL(fileURLWithPath: "/tmp/protocol16-herdr.sock"))
        let first = HerdrRequest(id: "one", method: "pane.list", params: EmptyParams())
        try await socket.sendLine(JSONEncoder().encode(first))
        let response = try await socket.nextLine()
        XCTAssertNotNil(response)
        let closed = try await socket.nextLine()
        XCTAssertNil(closed)
        let second = HerdrRequest(id: "two", method: "pane.list", params: EmptyParams())
        do {
            try await socket.sendLine(JSONEncoder().encode(second))
            XCTFail("A second request on a closed protocol-16 socket must fail")
        } catch let error as TransportError {
            XCTAssertEqual(error, .sendFailed("closed"))
        }
    }

    func testDetectionFlapsDoNotRebuildAndDoneThenIdleAreDelivered() async throws {
        let server = Protocol16HerdrServer(panes: ["A": .working])
        let herdr = client(server)
        let recorder = ClientEventRecorder()
        let observer = await record(herdr.events(), in: recorder)
        defer { observer.cancel() }
        await herdr.start()
        await assertEventually { await recorder.statuses(for: "A").contains(.working) }

        for agent: String? in ["pi", nil, "pi", nil] {
            await server.detect("A", agent: agent)
            await server.status(.unknown, for: "A")
            try await Task.sleep(for: .milliseconds(135))
        }
        await server.status(.working, for: "A")
        await server.status(.done, for: "A")
        await server.status(.idle, for: "A")
        await assertEventually {
            let statuses = await recorder.statuses(for: "A")
            return statuses.suffix(3) == [.working, .done, .idle]
        }
        let attempts = await server.subscribeAttempts
        let open = await server.openEventsConnections()
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(open, 1)
        let methods = await server.requestMethods
        XCTAssertEqual(methods.filter { $0 == "pane.list" }.count, 2, "detection must not re-list every pane")
        XCTAssertEqual(methods.filter { $0 == "pane.get" }.count, 4, "refresh only the detected pane")
        await herdr.stop()
    }

    func testStatusBurstUsesPayloadAndOneDebouncedMetadataPair() async throws {
        let server = Protocol16HerdrServer(panes: ["A": .working])
        let herdr = client(server)
        let recorder = ClientEventRecorder()
        let observer = await record(herdr.events(), in: recorder)
        defer { observer.cancel() }
        await herdr.start()
        await assertEventually { await recorder.statuses(for: "A").last == .working }

        await server.status(.blocked, for: "A")
        await server.status(.done, for: "A")
        await server.status(.idle, for: "A")
        await assertEventually { await recorder.statuses(for: "A").suffix(3) == [.blocked, .done, .idle] }
        await assertEventually {
            let methods = await server.requestMethods
            return methods.filter { $0 == "workspace.list" }.count == 2
                && methods.filter { $0 == "tab.list" }.count == 2
        }
        try await Task.sleep(for: .milliseconds(300))
        let methods = await server.requestMethods
        XCTAssertEqual(methods.filter { $0 == "pane.list" }.count, 2)
        XCTAssertEqual(methods.filter { $0 == "workspace.list" }.count, 2)
        XCTAssertEqual(methods.filter { $0 == "tab.list" }.count, 2)
        await herdr.stop()
    }

    func testLifecycleWithUnchangedPaneSetSkipsSubscribe() async throws {
        let server = Protocol16HerdrServer(panes: ["A": .working])
        let herdr = client(server)
        let recorder = ClientEventRecorder()
        let observer = await record(herdr.events(), in: recorder)
        defer { observer.cancel() }
        await herdr.start()
        await assertEventually { await recorder.latestPaneIDs() == ["A"] }
        await server.setPanes(["A": .working], event: "pane_moved")
        await assertEventually {
            let methods = await server.requestMethods
            return methods.filter { $0 == "pane.list" }.count >= 3
        }
        try await Task.sleep(for: .milliseconds(150))
        let attempts = await server.subscribeAttempts
        let open = await server.openEventsConnections()
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(open, 1)
        await herdr.stop()
    }

    func testChurnEvery150MillisecondsStillInstallsNewMembership() async throws {
        let server = Protocol16HerdrServer(
            panes: ["A": .working], replacementAcknowledgementDelay: .milliseconds(225)
        )
        let herdr = client(server)
        let recorder = ClientEventRecorder()
        let observer = await record(herdr.events(), in: recorder)
        defer { observer.cancel() }
        await herdr.start()
        await assertEventually { await recorder.latestPaneIDs() == ["A"] }
        for index in 0 ..< 8 {
            await server.setPanes(["A": .working, "B": .working], event: index == 0 ? "pane_created" : "pane_moved")
            try await Task.sleep(for: .milliseconds(150))
            if index == 5 {
                let ids = await server.subscribedPaneIDs
                XCTAssertEqual(ids, ["A", "B"], "the in-flight rebuild must finish despite churn")
            }
        }
        await assertEventually { await recorder.latestPaneIDs() == ["A", "B"] }
        await assertEventually { await server.openEventsConnections() == 1 }
        await herdr.stop()
    }

    func testMismatchStopsAfterThreeSwapsAndKeepsCurrentEventsSocket() async throws {
        let server = Protocol16HerdrServer(panes: ["A": .working])
        let herdr = HerdrClient(
            socketURL: URL(fileURLWithPath: "/tmp/protocol16-herdr.sock"),
            connectionFactory: server,
            backoff: .immediate,
            sleeper: ImmediateSleeper(),
            subscriptionRebuildDebounce: .zero
        )
        let recorder = ClientEventRecorder()
        let observer = await record(herdr.events(), in: recorder)
        defer { observer.cancel() }
        await herdr.start()
        await assertEventually { await recorder.latestPaneIDs() == ["A"] }
        await server.driftMembershipOnReplacementSubscribe()
        await server.setPanes(["A": .working, "B": .working])
        await assertEventually { await server.subscribeAttempts >= 4 }
        try await Task.sleep(for: .milliseconds(120))
        let attempts = await server.subscribeAttempts
        let open = await server.openEventsConnections()
        XCTAssertEqual(attempts, 4, "initial connection plus three bounded mismatch attempts")
        XCTAssertEqual(open, 1)
        await herdr.stop()
    }

    func testStatusMetadataDroppedDuringSwapIsRetriedAfterStaleRebuildMetadata() async throws {
        let server = Protocol16HerdrServer(panes: ["A": .working])
        let herdr = client(server)
        let recorder = ClientEventRecorder()
        let observer = await record(herdr.events(), in: recorder)
        defer { observer.cancel() }
        await herdr.start()
        await assertEventually { await recorder.latestWorkspaceLabel() == "base" }

        await server.holdNextWorkspaceList()
        await server.setPanes(["A": .working, "B": .working])
        await assertEventually { await server.heldWorkspaceListCount == 1 }
        await server.setWorkspaceLabel("new")
        await server.status(.blocked, for: "A")
        await assertEventually {
            let methods = await server.requestMethods
            return methods.filter { $0 == "workspace.list" }.count >= 3
        }
        await server.releaseWorkspaceLists()
        await assertEventually { await recorder.latestPaneIDs() == ["A", "B"] }
        await assertEventually { await recorder.latestWorkspaceLabel() == "new" }
        await herdr.stop()
    }

    func testOldMetadataReplyCannotReplaceNewSubscriptionMetadata() async throws {
        let server = Protocol16HerdrServer(panes: ["A": .working])
        let herdr = client(server)
        let recorder = ClientEventRecorder()
        let observer = await record(herdr.events(), in: recorder)
        defer { observer.cancel() }
        await herdr.start()
        await assertEventually { await recorder.latestWorkspaceLabel() == "base" }

        await server.holdNextWorkspaceList()
        await server.status(.blocked, for: "A")
        await assertEventually { await server.heldWorkspaceListCount == 1 }
        await server.setWorkspaceLabel("new")
        await server.setPanes(["A": .blocked, "B": .working])
        await assertEventually { await recorder.latestPaneIDs() == ["A", "B"] }
        await assertEventually { await recorder.latestWorkspaceLabel() == "new" }
        await server.releaseWorkspaceLists()
        try await Task.sleep(for: .milliseconds(50))
        let label = await recorder.latestWorkspaceLabel()
        XCTAssertEqual(label, "new")
        await herdr.stop()
    }

    func testOldDetectionGetCannotOverwriteAgentAfterSubscriptionSwap() async throws {
        let server = Protocol16HerdrServer(panes: ["A": .working])
        let herdr = client(server)
        let recorder = ClientEventRecorder()
        let observer = await record(herdr.events(), in: recorder)
        defer { observer.cancel() }
        await herdr.start()
        await assertEventually { await recorder.latestPaneIDs() == ["A"] }

        await server.holdNextGet()
        await server.detect("A", agent: "old")
        await assertEventually { await server.heldGetCount == 1 }
        await server.setAgent("A", to: "new")
        await server.setPanes(["A": .working, "B": .working])
        await assertEventually { await recorder.latestPaneIDs() == ["A", "B"] }
        await server.releaseGets()
        try await Task.sleep(for: .milliseconds(50))
        let agents = await recorder.agents(for: "A")
        XCTAssertEqual(agents.last ?? nil, "new")
        await herdr.stop()
    }

    func testMissingDetectionPaneDoesNotDiscardPendingRefresh() async throws {
        let server = Protocol16HerdrServer(panes: ["A": .working, "B": .working])
        let herdr = client(server)
        let recorder = ClientEventRecorder()
        let observer = await record(herdr.events(), in: recorder)
        defer { observer.cancel() }
        await herdr.start()
        await assertEventually { await recorder.latestPaneIDs() == ["A", "B"] }

        await server.holdNextGet()
        await server.detect("A", agent: "old")
        await assertEventually { await server.heldGetCount == 1 }
        await server.detect("B", agent: "pi")
        await server.failHeldGetsAsMissing()
        await assertEventually { await recorder.agents(for: "B").contains("pi") }
        let disconnected = await recorder.disconnectionCount
        XCTAssertEqual(disconnected, 0)
        await herdr.stop()
    }

    func testBlockedPaneIsNotLostWhenPostSwapListWasCapturedBeforeLiveEvent() async throws {
        let server = Protocol16HerdrServer(panes: ["A": .working])
        let herdr = client(server)
        let recorder = ClientEventRecorder()
        let observer = await record(herdr.events(), in: recorder)
        defer { observer.cancel() }
        await herdr.start()
        await assertEventually { await recorder.latestPaneIDs() == ["A"] }
        await server.holdListAfterNextSubscribe()
        await server.setPanes(["A": .working, "B": .working])
        await assertEventually { await server.heldListCount == 1 }
        let openDuringList = await server.openEventsConnections()
        XCTAssertEqual(openDuringList, 1, "old socket closes as soon as the new one acknowledges")
        await server.status(.blocked, for: "A")
        await assertEventually { await recorder.statuses(for: "A").last == .blocked }
        await server.releaseLists()
        await assertEventually { await recorder.latestPaneIDs() == ["A", "B"] }
        let statuses = await recorder.statuses(for: "A")
        let openAfterSwap = await server.openEventsConnections()
        XCTAssertEqual(statuses.last, .blocked)
        XCTAssertEqual(openAfterSwap, 1)
        await herdr.stop()
    }

    func testIdleAfterDoneCannotBeReplayedByStalePostSwapList() async throws {
        let server = Protocol16HerdrServer(panes: ["A": .working])
        let herdr = client(server)
        let recorder = ClientEventRecorder()
        let observer = await record(herdr.events(), in: recorder)
        defer { observer.cancel() }
        await herdr.start()
        await assertEventually { await recorder.latestPaneIDs() == ["A"] }
        await server.holdListAfterNextSubscribe()
        await server.setPanes(["A": .done, "B": .working])
        await assertEventually { await server.heldListCount == 1 }
        await server.status(.done, for: "A")
        await server.status(.idle, for: "A")
        await assertEventually { await recorder.statuses(for: "A").last == .idle }
        await server.releaseLists()
        await assertEventually { await recorder.latestPaneIDs() == ["A", "B"] }
        let statuses = await recorder.statuses(for: "A")
        XCTAssertEqual(statuses.filter { $0 == .done }.count, 1)
        XCTAssertEqual(statuses.last, .idle)
        await herdr.stop()
    }

    func testOnlyOneEventsConnectionOutsideSwaps() async throws {
        let server = Protocol16HerdrServer(panes: ["A": .working])
        let herdr = client(server)
        let recorder = ClientEventRecorder()
        let observer = await record(herdr.events(), in: recorder)
        defer { observer.cancel() }
        await herdr.start()
        await assertEventually { await recorder.latestPaneIDs() == ["A"] }
        let initialOpen = await server.openEventsConnections()
        XCTAssertEqual(initialOpen, 1)
        await server.setPanes(["A": .working, "B": .working])
        await assertEventually { await server.subscribedPaneIDs == ["A", "B"] }
        await assertEventually { await server.openEventsConnections() == 1 }
        await server.detect("B", agent: "pi")
        await server.status(.blocked, for: "B")
        await assertEventually { await recorder.statuses(for: "B").last == .blocked }
        let open = await server.openEventsConnections()
        XCTAssertEqual(open, 1)
        await herdr.stop()
        let closed = await server.openEventsConnections()
        XCTAssertEqual(closed, 0)
    }

    func testQueuedRequestKeepsOriginalTimeoutDeadline() async throws {
        let server = Protocol16HerdrServer(panes: [:])
        await server.holdFocusRequests()
        let timeoutSleeper = PerRequestTimeoutSleeper()
        let herdr = HerdrClient(
            socketURL: URL(fileURLWithPath: "/tmp/protocol16-herdr.sock"),
            connectionFactory: server,
            requestSleeper: timeoutSleeper
        )
        let firstFour = (0 ..< 4).map { _ in Task { try await herdr.focus(paneID: "A") } }
        await assertEventually { await server.heldFocusCount == 4 }
        let queued = Task { try await herdr.focus(paneID: "B") }
        let hasFiveDeadlines = await eventuallyForProtocol16 { await timeoutSleeper.waiterCount == 5 }
        XCTAssertTrue(hasFiveDeadlines, "the queued request's deadline starts before a socket is available")
        if hasFiveDeadlines {
            await timeoutSleeper.fireLast()
            do {
                _ = try await queued.value
                XCTFail("Queued request should time out without opening a fifth socket")
            } catch let error as HerdrClientError {
                XCTAssertEqual(error, .timeout)
            }
        } else {
            queued.cancel()
        }
        let held = await server.heldFocusCount
        XCTAssertEqual(held, 4)
        await server.releaseFocusRequests()
        for request in firstFour { _ = try await request.value }
        if !hasFiveDeadlines { _ = try? await queued.value }
    }

    func testOrdinaryRequestsNeverOpenMoreThanFourConnections() async throws {
        let server = Protocol16HerdrServer(panes: [:])
        await server.holdFocusRequests()
        let herdr = client(server)
        let requests = (0 ..< 9).map { _ in Task { try await herdr.focus(paneID: "A") } }
        await assertEventually { await server.heldFocusCount >= 4 }
        try await Task.sleep(for: .milliseconds(80))
        let held = await server.heldFocusCount
        XCTAssertEqual(held, 4)
        await server.releaseFocusRequests()
        for request in requests {
            let paneID = try await request.value.paneID
            XCTAssertEqual(paneID, "A")
        }
        let methods = await server.requestMethods
        XCTAssertEqual(methods.filter { $0 == "pane.focus" }.count, 9)
    }
}

private actor PerRequestTimeoutSleeper: Sleeper {
    private var waiters: [(UUID, CheckedContinuation<Void, any Error>)] = []

    var waiterCount: Int { waiters.count }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func fireLast() {
        waiters.removeLast().1.resume()
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
}
