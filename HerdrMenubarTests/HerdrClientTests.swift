import Foundation
import XCTest
@testable import HerdrMenubar

final class HerdrClientTests: XCTestCase {
    func testBootstrapReconcilesPaneAddedBetweenInitialAndPostSubscriptionLists() async throws {
        let factory = FakeHerdrConnectionFactory()
        let client = makeClient(factory: factory)
        let events = await client.events()
        await client.start()

        let initial = await factory.connection(at: 0)
        let initialList = await initial.nextSent()
        XCTAssertEqual(initialList.method, "pane.list")
        await initial.reply(to: initialList, result: paneListResult(ids: ["p2", "p1", "p1"]))

        let staleSubscription = await factory.connection(at: 1)
        let staleSubscribe = await staleSubscription.nextSent()
        XCTAssertEqual(staleSubscribe.method, "events.subscribe")
        XCTAssertEqual(try staleSubscribe.paramsObject(), [
            "subscriptions": [
                ["type": "pane.created"],
                ["type": "pane.closed"],
                ["type": "pane.focused"],
                ["type": "pane.moved"],
                ["type": "pane.exited"],
                ["type": "pane.agent_detected"],
                ["type": "pane.agent_status_changed", "pane_id": "p1"],
                ["type": "pane.agent_status_changed", "pane_id": "p2"]
            ]
        ] as NSDictionary)
        await staleSubscription.reply(to: staleSubscribe, result: #"{"type":"subscription_started"}"#)

        let stalePost = await factory.connection(at: 2)
        let stalePostList = await stalePost.nextSent()
        await stalePost.reply(to: stalePostList, result: paneListResult(ids: ["p1", "p2", "p3"]))

        let replacement = await factory.connection(at: 3)
        let replacementSubscribe = await replacement.nextSent()
        XCTAssertEqual(replacementSubscribe.subscriptionPaneIDs, ["p1", "p2", "p3"])
        let staleBootstrapClosed = await staleSubscription.isClosed
        XCTAssertTrue(staleBootstrapClosed)
        await replacement.reply(to: replacementSubscribe, result: #"{"type":"subscription_started"}"#)

        let settledPost = await factory.connection(at: 4)
        let settledPostList = await settledPost.nextSent()
        await settledPost.reply(to: settledPostList, result: paneListResult(ids: ["p1", "p2", "p3"]))
        await completeMetadata(factory: factory, startIndex: 5)
        let connected = await events.next()
        XCTAssertEqual(connected, .connected(clientSnapshot([pane("p1"), pane("p2"), pane("p3")])))
        await client.stop()
    }

    func testConnectedSnapshotCarriesMetadataWithExactWireRequests() async throws {
        let factory = FakeHerdrConnectionFactory()
        let client = makeClient(factory: factory)
        let events = await client.events()
        await client.start()

        let initial = await factory.connection(at: 0)
        let initialRequest = await initial.nextSent()
        await initial.reply(to: initialRequest, result: paneListResult(ids: ["pane"]))
        let subscription = await factory.connection(at: 1)
        let subscribe = await subscription.nextSent()
        await subscription.reply(to: subscribe, result: #"{"type":"subscription_started"}"#)
        let authoritative = await factory.connection(at: 2)
        let paneRequest = await authoritative.nextSent()
        await authoritative.reply(to: paneRequest, result: paneListResult(ids: ["pane"]))

        let firstMetadataConnection = await factory.connection(at: 3)
        let firstMetadataRequest = await firstMetadataConnection.nextSent()
        let secondMetadataConnection = await factory.connection(at: 4)
        let secondMetadataRequest = await secondMetadataConnection.nextSent()
        XCTAssertEqual(Set([firstMetadataRequest.method, secondMetadataRequest.method]), ["workspace.list", "tab.list"])
        XCTAssertEqual(try firstMetadataRequest.paramsObject(), [:] as NSDictionary)
        XCTAssertEqual(try secondMetadataRequest.paramsObject(), [:] as NSDictionary)
        let workspaceResult = #"""
        {"type":"workspace_list","workspaces":[{
          "workspace_id":"workspace","number":1,"label":"Herdr Menubar","focused":true,
          "pane_count":1,"tab_count":1,"active_tab_id":"tab","agent_status":"working"
        }]}
        """#
        let tabResult = #"{"type":"tab_list","tabs":[{"tab_id":"tab","workspace_id":"workspace","number":1,"label":"server","focused":true,"pane_count":1,"agent_status":"working"}]}"#
        await replyToMetadata(
            connection: firstMetadataConnection,
            request: firstMetadataRequest,
            workspaces: workspaceResult,
            tabs: tabResult
        )
        await replyToMetadata(
            connection: secondMetadataConnection,
            request: secondMetadataRequest,
            workspaces: workspaceResult,
            tabs: tabResult
        )

        guard case .connected(let snapshot) = await events.next() else {
            return XCTFail("Expected connected presentation snapshot")
        }
        XCTAssertEqual(snapshot.panes, [pane("pane")])
        XCTAssertEqual(snapshot.workspaces.map(\.label), ["Herdr Menubar"])
        XCTAssertEqual(snapshot.tabs.map(\.label), ["server"])
        await client.stop()
    }

    func testMetadataAPIErrorsPublishPaneSnapshotUsingDesignedFallback() async throws {
        let factory = FakeHerdrConnectionFactory()
        let client = makeClient(factory: factory)
        let events = await client.events()
        await client.start()

        let initial = await factory.connection(at: 0)
        let initialRequest = await initial.nextSent()
        await initial.reply(to: initialRequest, result: paneListResult(ids: ["pane"]))
        let subscription = await factory.connection(at: 1)
        let subscribe = await subscription.nextSent()
        await subscription.reply(to: subscribe, result: #"{"type":"subscription_started"}"#)
        let authoritative = await factory.connection(at: 2)
        let paneRequest = await authoritative.nextSent()
        await authoritative.reply(to: paneRequest, result: paneListResult(ids: ["pane"]))
        for index in 3 ... 4 {
            let connection = await factory.connection(at: index)
            let request = await connection.nextSent()
            await connection.push(
                #"{"id":"\#(request.id)","error":{"code":"unavailable","message":"metadata unavailable"}}"#
            )
        }

        let connected = await events.next()
        XCTAssertEqual(connected, .connected(clientSnapshot([pane("pane")])))
        await client.stop()
    }

    func testMetadataProtocolFailureDisconnectsInsteadOfPublishingFallback() async throws {
        let factory = FakeHerdrConnectionFactory()
        let client = makeClient(factory: factory)
        let events = await client.events()
        await client.start()

        let initial = await factory.connection(at: 0)
        let initialRequest = await initial.nextSent()
        await initial.reply(to: initialRequest, result: paneListResult(ids: ["pane"]))
        let subscription = await factory.connection(at: 1)
        let subscribe = await subscription.nextSent()
        await subscription.reply(to: subscribe, result: #"{"type":"subscription_started"}"#)
        let authoritative = await factory.connection(at: 2)
        let paneRequest = await authoritative.nextSent()
        await authoritative.reply(to: paneRequest, result: paneListResult(ids: ["pane"]))
        let firstMetadataConnection = await factory.connection(at: 3)
        let firstMetadataRequest = await firstMetadataConnection.nextSent()
        let secondMetadataConnection = await factory.connection(at: 4)
        let secondMetadataRequest = await secondMetadataConnection.nextSent()
        await firstMetadataConnection.reply(
            to: firstMetadataRequest,
            result: firstMetadataRequest.method == "workspace.list"
                ? #"{"type":"wrong_type","workspaces":[]}"#
                : #"{"type":"wrong_type","tabs":[]}"#
        )
        await replyToMetadata(connection: secondMetadataConnection, request: secondMetadataRequest)

        guard case .disconnected = await events.next() else {
            return XCTFail("Expected metadata protocol failure to disconnect")
        }
        await client.stop()
    }

    func testOneSidedMetadataFallbackRetainsSuccessfulMetadata() async throws {
        let factory = FakeHerdrConnectionFactory()
        let client = makeClient(factory: factory)
        let events = await client.events()
        await client.start()

        let initial = await factory.connection(at: 0)
        let initialRequest = await initial.nextSent()
        await initial.reply(to: initialRequest, result: paneListResult(ids: ["pane"]))
        let subscription = await factory.connection(at: 1)
        let subscribe = await subscription.nextSent()
        await subscription.reply(to: subscribe, result: #"{"type":"subscription_started"}"#)
        let authoritative = await factory.connection(at: 2)
        let paneRequest = await authoritative.nextSent()
        await authoritative.reply(to: paneRequest, result: paneListResult(ids: ["pane"]))

        let firstMetadataConnection = await factory.connection(at: 3)
        let firstMetadataRequest = await firstMetadataConnection.nextSent()
        let secondMetadataConnection = await factory.connection(at: 4)
        let secondMetadataRequest = await secondMetadataConnection.nextSent()
        let tabResult = #"{"type":"tab_list","tabs":[{"tab_id":"tab","workspace_id":"workspace","number":1,"label":"retained","focused":true,"pane_count":1,"agent_status":"working"}]}"#
        for (connection, request) in [
            (firstMetadataConnection, firstMetadataRequest),
            (secondMetadataConnection, secondMetadataRequest)
        ] {
            if request.method == "workspace.list" {
                await connection.push(
                    #"{"id":"\#(request.id)","error":{"code":"unavailable","message":"metadata unavailable"}}"#
                )
            } else {
                await connection.reply(to: request, result: tabResult)
            }
        }

        guard case .connected(let snapshot) = await events.next() else {
            return XCTFail("Expected connected presentation snapshot")
        }
        XCTAssertEqual(snapshot.workspaces, [])
        XCTAssertEqual(snapshot.tabs.map(\.label), ["retained"])
        await client.stop()
    }

    func testMembershipBurstDebouncesAndKeepsOldSubscriptionUntilReplacementIsAuthoritative() async throws {
        let factory = FakeHerdrConnectionFactory()
        let client = makeClient(factory: factory, debounce: .milliseconds(20))
        let events = await client.events()
        await client.start()
        let oldSubscription = await completeBootstrap(factory: factory, discovered: ["old"], authoritative: ["old"])
        _ = await events.next()

        await oldSubscription.push(#"{"event":"pane.created","data":{}}"#)
        await oldSubscription.push(#"{"event":"pane.moved","data":{}}"#)
        await oldSubscription.push(#"{"event":"pane.closed","data":{}}"#)

        let discovery = await factory.connection(at: 5)
        let discoveryRequest = await discovery.nextSent()
        await discovery.reply(to: discoveryRequest, result: paneListResult(ids: ["new", "old"]))
        let replacement = await factory.connection(at: 6)
        let replacementSubscribe = await replacement.nextSent()
        XCTAssertEqual(replacementSubscribe.subscriptionPaneIDs, ["new", "old"])
        await replacement.reply(to: replacementSubscribe, result: #"{"type":"subscription_started"}"#)

        let postSubscription = await factory.connection(at: 7)
        let postRequest = await postSubscription.nextSent()
        let oldClosedBeforeAuthoritativeSnapshot = await oldSubscription.isClosed
        XCTAssertFalse(oldClosedBeforeAuthoritativeSnapshot)
        await postSubscription.reply(to: postRequest, result: paneListResult(ids: ["new", "old"]))
        await completeMetadata(factory: factory, startIndex: 8)
        let replacementSnapshot = await events.next()
        XCTAssertEqual(replacementSnapshot, .snapshot(clientSnapshot([pane("new"), pane("old")])))
        await waitUntil { await oldSubscription.isClosed }
        try await Task.sleep(for: .milliseconds(30))
        let rebuildConnectionCount = await factory.connectionCount
        XCTAssertEqual(rebuildConnectionCount, 10, "membership burst must produce one rebuild")
        await client.stop()
    }

    func testRebuildSupersedesRefreshThatCapturedOldMembership() async throws {
        let factory = FakeHerdrConnectionFactory()
        let client = makeClient(factory: factory)
        let events = await client.events()
        await client.start()
        let oldSubscription = await completeBootstrap(
            factory: factory,
            discovered: ["old"],
            authoritative: ["old"]
        )
        _ = await events.next()

        await oldSubscription.push(#"{"event":"pane.agent_status_changed","data":{"pane_id":"old"}}"#)
        let oldRefresh = await factory.connection(at: 5)
        let oldRefreshRequest = await oldRefresh.nextSent()
        await oldRefresh.reply(to: oldRefreshRequest, result: paneListResult(ids: ["old"]))
        let oldMetadataOne = await factory.connection(at: 6)
        let oldMetadataRequestOne = await oldMetadataOne.nextSent()
        let oldMetadataTwo = await factory.connection(at: 7)
        let oldMetadataRequestTwo = await oldMetadataTwo.nextSent()

        await oldSubscription.push(#"{"event":"pane.created","data":{}}"#)
        let discovery = await factory.connection(at: 8)
        let discoveryRequest = await discovery.nextSent()
        await discovery.reply(to: discoveryRequest, result: paneListResult(ids: ["new"]))
        let replacement = await factory.connection(at: 9)
        let replacementSubscribe = await replacement.nextSent()
        await replacement.reply(to: replacementSubscribe, result: #"{"type":"subscription_started"}"#)
        let authoritative = await factory.connection(at: 10)
        let authoritativeRequest = await authoritative.nextSent()
        await authoritative.reply(to: authoritativeRequest, result: paneListResult(ids: ["new"]))
        await completeMetadata(factory: factory, startIndex: 11)
        let rebuiltEvent = await events.next()
        XCTAssertEqual(rebuiltEvent, .snapshot(clientSnapshot([pane("new")])))

        await replyToMetadata(connection: oldMetadataOne, request: oldMetadataRequestOne)
        await replyToMetadata(connection: oldMetadataTwo, request: oldMetadataRequestTwo)
        await replacement.push(#"{"event":"pane.agent_status_changed","data":{"pane_id":"new"}}"#)
        let newRefresh = await factory.connection(at: 13)
        let newRefreshRequest = await newRefresh.nextSent()
        await newRefresh.reply(to: newRefreshRequest, result: paneListResult(ids: ["fresh"]))
        await completeMetadata(factory: factory, startIndex: 14)
        let postRebuildEvent = await events.next()
        XCTAssertEqual(
            postRebuildEvent,
            .snapshot(clientSnapshot([pane("fresh")])),
            "the held old-membership refresh must never publish after the rebuild"
        )
        await client.stop()
    }

    func testStatusEventDuringRebuildQueuesPostRebuildRefresh() async throws {
        let factory = FakeHerdrConnectionFactory()
        let client = makeClient(factory: factory)
        let events = await client.events()
        await client.start()
        let oldSubscription = await completeBootstrap(factory: factory, discovered: ["old"], authoritative: ["old"])
        _ = await events.next()

        await oldSubscription.push(#"{"event":"pane.created","data":{}}"#)
        let discovery = await factory.connection(at: 5)
        let discoveryRequest = await discovery.nextSent()
        await discovery.reply(to: discoveryRequest, result: paneListResult(ids: ["stale"]))
        let replacement = await factory.connection(at: 6)
        let replacementSubscribe = await replacement.nextSent()
        await replacement.reply(to: replacementSubscribe, result: #"{"type":"subscription_started"}"#)
        let authoritative = await factory.connection(at: 7)
        let authoritativeRequest = await authoritative.nextSent()

        await oldSubscription.push(#"{"event":"pane.agent_status_changed","data":{"pane_id":"old"}}"#)
        await authoritative.reply(to: authoritativeRequest, result: paneListResult(ids: ["stale"]))
        await completeMetadata(factory: factory, startIndex: 8)
        let rebuiltEvent = await events.next()
        XCTAssertEqual(rebuiltEvent, .snapshot(clientSnapshot([pane("stale")])))

        let refresh = await factory.connection(at: 10)
        let refreshRequest = await refresh.nextSent()
        await refresh.reply(to: refreshRequest, result: paneListResult(ids: ["latest"]))
        await completeMetadata(factory: factory, startIndex: 11)
        let refreshedEvent = await events.next()
        XCTAssertEqual(
            refreshedEvent,
            .snapshot(clientSnapshot([pane("latest")])),
            "the status event received during rebuild must refresh the rebuilt presentation"
        )
        try await Task.sleep(for: .milliseconds(20))
        let connectionCount = await factory.connectionCount
        XCTAssertEqual(connectionCount, 13, "the queued status event must start exactly one refresh")
        await client.stop()
    }

    func testRebuildReconcilesPaneRemovedBetweenInitialAndPostSubscriptionLists() async throws {
        let factory = FakeHerdrConnectionFactory()
        let client = makeClient(factory: factory)
        let events = await client.events()
        await client.start()
        let oldSubscription = await completeBootstrap(factory: factory, discovered: ["old"], authoritative: ["old"])
        _ = await events.next()

        await oldSubscription.push(#"{"event":"pane.closed","data":{}}"#)
        let discovery = await factory.connection(at: 5)
        let discoveryRequest = await discovery.nextSent()
        await discovery.reply(to: discoveryRequest, result: paneListResult(ids: ["old", "removed"]))

        let staleReplacement = await factory.connection(at: 6)
        let staleSubscribe = await staleReplacement.nextSent()
        XCTAssertEqual(staleSubscribe.subscriptionPaneIDs, ["old", "removed"])
        await staleReplacement.reply(to: staleSubscribe, result: #"{"type":"subscription_started"}"#)
        let stalePost = await factory.connection(at: 7)
        let stalePostRequest = await stalePost.nextSent()
        await stalePost.reply(to: stalePostRequest, result: paneListResult(ids: ["old"]))

        let replacement = await factory.connection(at: 8)
        let replacementSubscribe = await replacement.nextSent()
        XCTAssertEqual(replacementSubscribe.subscriptionPaneIDs, ["old"])
        let staleReplacementClosed = await staleReplacement.isClosed
        let oldSubscriptionClosed = await oldSubscription.isClosed
        XCTAssertTrue(staleReplacementClosed)
        XCTAssertFalse(oldSubscriptionClosed)
        await replacement.reply(to: replacementSubscribe, result: #"{"type":"subscription_started"}"#)
        let settledPost = await factory.connection(at: 9)
        let settledPostRequest = await settledPost.nextSent()
        await settledPost.reply(to: settledPostRequest, result: paneListResult(ids: ["old"]))
        await completeMetadata(factory: factory, startIndex: 10)

        let replacementSnapshot = await events.next()
        XCTAssertEqual(replacementSnapshot, .snapshot(clientSnapshot([pane("old")])))
        await waitUntil { await oldSubscription.isClosed }
        await client.stop()
    }

}

extension HerdrClientTests {
    func testServerWireStatusEventTriggersSnapshotRefresh() async throws {
        let factory = FakeHerdrConnectionFactory()
        let client = makeClient(factory: factory)
        let events = await client.events()
        await client.start()
        let subscription = await completeBootstrap(factory: factory, discovered: ["old"], authoritative: ["old"])
        _ = await events.next()

        await subscription.push(#"{"event":"pane_agent_status_changed","data":{"pane_id":"old"}}"#)
        try await Task.sleep(for: .milliseconds(50))
        guard await factory.connectionCount == 6 else {
            await client.stop()
            return XCTFail("server-compatible status event must start a pane snapshot refresh")
        }
        let refresh = await factory.connection(at: 5)
        let request = await refresh.nextSent()
        await refresh.reply(to: request, result: paneListResult(ids: ["updated"]))
        await completeMetadata(factory: factory, startIndex: 6)
        let refreshedEvent = await events.next()
        XCTAssertEqual(refreshedEvent, .snapshot(clientSnapshot([pane("updated")])))
        await client.stop()
    }

    func testServerWireLifecycleEventTriggersSubscriptionRebuild() async throws {
        let factory = FakeHerdrConnectionFactory()
        let client = makeClient(factory: factory)
        let events = await client.events()
        await client.start()
        let subscription = await completeBootstrap(factory: factory, discovered: ["old"], authoritative: ["old"])
        _ = await events.next()

        await subscription.push(#"{"event":"pane_created","data":{}}"#)
        try await Task.sleep(for: .milliseconds(50))
        guard await factory.connectionCount == 6 else {
            await client.stop()
            return XCTFail("server-compatible lifecycle event must start a subscription rebuild")
        }
        let discovery = await factory.connection(at: 5)
        let discoveryRequest = await discovery.nextSent()
        await discovery.reply(to: discoveryRequest, result: paneListResult(ids: ["new", "old"]))
        let replacement = await factory.connection(at: 6)
        let subscribe = await replacement.nextSent()
        XCTAssertEqual(subscribe.subscriptionPaneIDs, ["new", "old"])
        await replacement.reply(to: subscribe, result: #"{"type":"subscription_started"}"#)
        let authoritative = await factory.connection(at: 7)
        let authoritativeRequest = await authoritative.nextSent()
        await authoritative.reply(to: authoritativeRequest, result: paneListResult(ids: ["new", "old"]))
        await completeMetadata(factory: factory, startIndex: 8)
        let rebuiltEvent = await events.next()
        XCTAssertEqual(rebuiltEvent, .snapshot(clientSnapshot([pane("new"), pane("old")])))
        await waitUntil { await subscription.isClosed }
        await client.stop()
    }

    func testStatusEventRefreshesAndBurstCoalesces() async throws {
        let factory = FakeHerdrConnectionFactory()
        let client = makeClient(factory: factory)
        let events = await client.events()
        await client.start()
        let subscription = await completeBootstrap(factory: factory, discovered: ["old"], authoritative: ["old"])
        _ = await events.next()

        await subscription.push(#"{"event":"pane.agent_status_changed","data":{"pane_id":"old"}}"#)
        let firstConnection = await factory.connection(at: 5)
        let first = await firstConnection.nextSent()
        await subscription.push(#"{"event":"pane.focused","data":{}}"#)
        await subscription.push(#"{"event":"pane.agent_status_changed","data":{"pane_id":"old"}}"#)
        await firstConnection.reply(to: first, result: paneListResult(ids: ["one"]))
        await completeMetadata(factory: factory, startIndex: 6)
        let firstEvent = await events.next()
        XCTAssertEqual(firstEvent, .snapshot(clientSnapshot([pane("one")])))
        let secondConnection = await factory.connection(at: 8)
        let second = await secondConnection.nextSent()
        await secondConnection.reply(to: second, result: paneListResult(ids: ["two"]))
        await completeMetadata(factory: factory, startIndex: 9)
        let secondEvent = await events.next()
        XCTAssertEqual(secondEvent, .snapshot(clientSnapshot([pane("two")])))
        try await Task.sleep(for: .milliseconds(20))
        let coalescedConnectionCount = await factory.connectionCount
        XCTAssertEqual(coalescedConnectionCount, 11)
        await client.stop()
    }

    func testStopMakesCancelledStaleBootstrapUnableToInstallOrClearState() async throws {
        let factory = FakeHerdrConnectionFactory()
        let client = makeClient(factory: factory)
        await client.start()
        let stale = await factory.connection(at: 0)
        let staleRequest = await stale.nextSent()
        await client.stop()
        await stale.reply(to: staleRequest, result: paneListResult(ids: ["stale"]))
        try await Task.sleep(for: .milliseconds(20))
        let stoppedConnectionCount = await factory.connectionCount
        XCTAssertEqual(stoppedConnectionCount, 1)

        await client.start()
        let events = await client.events()
        _ = await completeBootstrap(factory: factory, startIndex: 1, discovered: ["new"], authoritative: ["new"])
        let newConnected = await events.next()
        XCTAssertEqual(newConnected, .connected(clientSnapshot([pane("new")])))
        await client.stop()
    }

    func testRetryGenerationRejectsLateCancelledBootstrapCompletion() async throws {
        let factory = FakeHerdrConnectionFactory()
        let client = makeClient(factory: factory)
        let events = await client.events()
        await client.start()
        let stale = await factory.connection(at: 0)
        let staleRequest = await stale.nextSent()

        await client.retryNow()
        let replacementInitial = await factory.connection(at: 1)
        let replacementRequest = await replacementInitial.nextSent()
        await stale.reply(to: staleRequest, result: paneListResult(ids: ["stale"]))
        await replacementInitial.reply(to: replacementRequest, result: paneListResult(ids: ["new"]))
        let replacementSubscription = await factory.connection(at: 2)
        let subscribe = await replacementSubscription.nextSent()
        await replacementSubscription.reply(to: subscribe, result: #"{"type":"subscription_started"}"#)
        let authoritative = await factory.connection(at: 3)
        let list = await authoritative.nextSent()
        await authoritative.reply(to: list, result: paneListResult(ids: ["new"]))
        await completeMetadata(factory: factory, startIndex: 4)
        let newConnected = await events.next()
        XCTAssertEqual(newConnected, .connected(clientSnapshot([pane("new")])))
        let retryConnectionCount = await factory.connectionCount
        XCTAssertEqual(retryConnectionCount, 6)
        await client.stop()
    }

    func testCancelledStaleRefreshCannotClearNewRefreshOwnership() async throws {
        let sleeper = ControlledSleeper()
        let factory = FakeHerdrConnectionFactory()
        let client = HerdrClient(
            connectionFactory: factory,
            pathResolver: FakePathResolver(),
            backoff: BackoffPolicy(delays: [.milliseconds(1)], jitter: { 0 }),
            sleeper: sleeper
        )
        let events = await client.events()
        await client.start()
        let oldSubscription = await completeBootstrap(factory: factory, discovered: ["old"], authoritative: ["old"])
        _ = await events.next()
        await oldSubscription.push(#"{"event":"pane.agent_status_changed","data":{"pane_id":"old"}}"#)
        let staleRefresh = await factory.connection(at: 5)
        let staleRequest = await staleRefresh.nextSent()

        await oldSubscription.finish()
        guard case .disconnected = await events.next() else { return XCTFail("Expected disconnect") }
        await sleeper.releaseFirst()
        let newSubscription = await completeBootstrap(factory: factory, startIndex: 6, discovered: ["new"], authoritative: ["new"])
        let newConnected = await events.next()
        XCTAssertEqual(newConnected, .connected(clientSnapshot([pane("new")])))
        await staleRefresh.reply(to: staleRequest, result: paneListResult(ids: ["stale"]))

        await newSubscription.push(#"{"event":"pane.agent_status_changed","data":{"pane_id":"new"}}"#)
        let newRefresh = await factory.connection(at: 11)
        let newRequest = await newRefresh.nextSent()
        await newRefresh.reply(to: newRequest, result: paneListResult(ids: ["fresh"]))
        await completeMetadata(factory: factory, startIndex: 12)
        let freshEvent = await events.next()
        XCTAssertEqual(freshEvent, .snapshot(clientSnapshot([pane("fresh")])))
        await client.stop()
    }

    func testTimeoutCoversConnectSendAndReceiveAsOneOrdinaryRequestDeadline() async throws {
        let factory = FakeHerdrConnectionFactory(sendDelays: [.milliseconds(35)])
        let client = HerdrClient(
            connectionFactory: factory,
            pathResolver: FakePathResolver(),
            backoff: BackoffPolicy(delays: [.seconds(15)], jitter: { 0 }),
            sleeper: ControlledSleeper(),
            requestTimeout: .milliseconds(60)
        )
        let events = await client.events()
        await client.start()
        let connection = await factory.connection(at: 0)
        let request = await connection.nextSent()
        try await Task.sleep(for: .milliseconds(35))
        await connection.reply(to: request, result: paneListResult(ids: []))
        guard case .disconnected(let reason) = await events.next() else { return XCTFail("Expected timeout") }
        XCTAssertEqual(reason, "Herdr request timed out")
        let timedOutConnectionClosed = await connection.isClosed
        XCTAssertTrue(timedOutConnectionClosed)
        await client.stop()
    }

    func testFocusCorrelatesResponseAndAPIErrorDoesNotDisconnect() async throws {
        let factory = FakeHerdrConnectionFactory()
        let client = makeClient(factory: factory)
        await client.start()
        _ = await completeBootstrap(factory: factory, discovered: [], authoritative: [])

        let focusTask = Task { try await client.focus(paneID: "focused") }
        let focusConnection = await factory.connection(at: 5)
        let focus = await focusConnection.nextSent()
        XCTAssertEqual(focus.paneID, "focused")
        await focusConnection.reply(to: focus, result: paneFocusResult(id: "focused"))
        let focusedPane = try await focusTask.value
        XCTAssertEqual(focusedPane, pane("focused"))

        let errorTask = Task { try await client.focus(paneID: "missing") }
        let errorConnection = await factory.connection(at: 6)
        let request = await errorConnection.nextSent()
        await errorConnection.push(#"{"id":"\#(request.id)","error":{"code":"not_found","message":"Missing pane"}}"#)
        do {
            _ = try await errorTask.value
            XCTFail("Expected API error")
        } catch let error as HerdrAPIError {
            XCTAssertEqual(error, HerdrAPIError(code: "not_found", message: "Missing pane"))
        }
        await client.stop()
    }

    func testMalformedAndUnknownEventsDoNotTerminateSubscription() async throws {
        let factory = FakeHerdrConnectionFactory()
        let client = makeClient(factory: factory)
        let events = await client.events()
        await client.start()
        let subscription = await completeBootstrap(factory: factory, discovered: [], authoritative: [])
        _ = await events.next()
        await subscription.push("not json")
        await subscription.push(#"{"event":"future.event","data":{}}"#)
        await subscription.push(#"{"event":"pane.focused","data":{}}"#)
        let refresh = await factory.connection(at: 5)
        let request = await refresh.nextSent()
        await refresh.reply(to: request, result: paneListResult(ids: ["live"]))
        await completeMetadata(factory: factory, startIndex: 6)
        let liveEvent = await events.next()
        XCTAssertEqual(liveEvent, .snapshot(clientSnapshot([pane("live")])))
        await client.stop()
    }

    func testBackoffIsBoundedAndClampsInjectedJitter() {
        XCTAssertEqual(BackoffPolicy(delays: [.seconds(15)], jitter: { 1 }).delay(attempt: 100), .seconds(18))
        XCTAssertEqual(BackoffPolicy(delays: [.seconds(15)], jitter: { -1 }).delay(attempt: 100), .seconds(12))
    }

    private func makeClient(factory: FakeHerdrConnectionFactory, debounce: Duration = .zero) -> HerdrClient {
        HerdrClient(
            connectionFactory: factory,
            pathResolver: FakePathResolver(),
            backoff: .immediate,
            sleeper: ImmediateSleeper(),
            subscriptionRebuildDebounce: debounce
        )
    }

    private func completeBootstrap(
        factory: FakeHerdrConnectionFactory,
        startIndex: Int = 0,
        discovered: [String],
        authoritative: [String]
    ) async -> FakeHerdrConnection {
        let initial = await factory.connection(at: startIndex)
        let initialRequest = await initial.nextSent()
        await initial.reply(to: initialRequest, result: paneListResult(ids: discovered))
        let subscription = await factory.connection(at: startIndex + 1)
        let subscribe = await subscription.nextSent()
        await subscription.reply(to: subscribe, result: #"{"type":"subscription_started"}"#)
        let post = await factory.connection(at: startIndex + 2)
        let postRequest = await post.nextSent()
        await post.reply(to: postRequest, result: paneListResult(ids: authoritative))
        await completeMetadata(factory: factory, startIndex: startIndex + 3)
        return subscription
    }
}

private struct FakePathResolver: SocketPathResolving {
    func resolve(environment: [String: String], homeDirectory: URL) -> URL {
        URL(fileURLWithPath: "/tmp/fake-herdr.sock")
    }
}

private actor FakeHerdrConnectionFactory: HerdrConnectionFactory {
    private var connections: [FakeHerdrConnection] = []
    private var waiters: [Int: [CheckedContinuation<FakeHerdrConnection, Never>]] = [:]
    private let sendDelays: [Duration]

    init(sendDelays: [Duration] = []) { self.sendDelays = sendDelays }
    var connectionCount: Int { connections.count }

    func connect(to socketURL: URL) async throws -> any HerdrConnection {
        let index = connections.count
        let connection = FakeHerdrConnection(sendDelay: sendDelays.indices.contains(index) ? sendDelays[index] : .zero)
        connections.append(connection)
        for waiter in waiters.removeValue(forKey: index) ?? [] { waiter.resume(returning: connection) }
        return connection
    }

    func connection(at index: Int) async -> FakeHerdrConnection {
        if connections.indices.contains(index) { return connections[index] }
        return await withCheckedContinuation { waiters[index, default: []].append($0) }
    }
}

private struct RecordedRequest: Sendable {
    let id: String
    let method: String
    let data: Data

    var paneID: String? {
        (try? paramsObject()["pane_id"] as? String) ?? nil
    }

    var subscriptionPaneIDs: [String] {
        guard let subscriptions = try? paramsObject()["subscriptions"] as? [[String: String]] else { return [] }
        return subscriptions.compactMap { $0["pane_id"] }.sorted()
    }

    func paramsObject() throws -> NSDictionary {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let params = object["params"] as? NSDictionary else {
            throw FakeConnectionError.malformedRequest
        }
        return params
    }
}

private enum FakeConnectionError: Error {
    case malformedRequest
}

private actor FakeHerdrConnection: HerdrConnection {
    private var sent: [RecordedRequest] = []
    private var sentWaiters: [CheckedContinuation<RecordedRequest, Never>] = []
    private var inbound: [Data?] = []
    private var readWaiters: [UUID: CheckedContinuation<Data?, any Error>] = [:]
    private(set) var isClosed = false
    private let sendDelay: Duration

    init(sendDelay: Duration) { self.sendDelay = sendDelay }

    func sendLine(_ data: Data) async throws {
        if sendDelay > .zero { try await Task.sleep(for: sendDelay) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String,
              let method = object["method"] as? String else {
            throw FakeConnectionError.malformedRequest
        }
        let request = RecordedRequest(id: id, method: method, data: data)
        if sentWaiters.isEmpty { sent.append(request) } else { sentWaiters.removeFirst().resume(returning: request) }
    }

    func nextLine() async throws -> Data? {
        if !inbound.isEmpty { return inbound.removeFirst() }
        if isClosed { return nil }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { readWaiters[id] = $0 }
        } onCancel: {
            Task { await self.cancelRead(id) }
        }
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        for waiter in readWaiters.values { waiter.resume(returning: nil) }
        readWaiters.removeAll()
    }

    func nextSent() async -> RecordedRequest {
        if !sent.isEmpty { return sent.removeFirst() }
        return await withCheckedContinuation { sentWaiters.append($0) }
    }

    func push(_ line: String) { enqueue(Data(line.utf8)) }
    func reply(to request: RecordedRequest, result: String) { push(#"{"id":"\#(request.id)","result":\#(result)}"#) }
    func finish() { isClosed = true; enqueue(nil) }

    private func enqueue(_ line: Data?) {
        guard let entry = readWaiters.first else { inbound.append(line); return }
        readWaiters.removeValue(forKey: entry.key)
        entry.value.resume(returning: line)
    }

    private func cancelRead(_ id: UUID) {
        guard let waiter = readWaiters.removeValue(forKey: id) else { return }
        waiter.resume(throwing: CancellationError())
    }
}

private struct ImmediateSleeper: Sleeper {
    func sleep(for duration: Duration) async throws { try Task.checkCancellation() }
}

private actor ControlledSleeper: Sleeper {
    private var waits: [(UUID, CheckedContinuation<Void, any Error>)] = []

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { waits.append((id, $0)) }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func releaseFirst() async {
        while waits.isEmpty { await Task.yield() }
        waits.removeFirst().1.resume()
    }

    private func cancel(_ id: UUID) {
        guard let index = waits.firstIndex(where: { $0.0 == id }) else { return }
        waits.remove(at: index).1.resume(throwing: CancellationError())
    }
}

private func completeMetadata(
    factory: FakeHerdrConnectionFactory,
    startIndex: Int,
    workspaces: String = #"{"type":"workspace_list","workspaces":[]}"#,
    tabs: String = #"{"type":"tab_list","tabs":[]}"#
) async {
    let firstConnection = await factory.connection(at: startIndex)
    let firstRequest = await firstConnection.nextSent()
    let secondConnection = await factory.connection(at: startIndex + 1)
    let secondRequest = await secondConnection.nextSent()
    assert(Set([firstRequest.method, secondRequest.method]) == ["workspace.list", "tab.list"])
    await replyToMetadata(
        connection: firstConnection,
        request: firstRequest,
        workspaces: workspaces,
        tabs: tabs
    )
    await replyToMetadata(
        connection: secondConnection,
        request: secondRequest,
        workspaces: workspaces,
        tabs: tabs
    )
}

private func replyToMetadata(
    connection: FakeHerdrConnection,
    request: RecordedRequest,
    workspaces: String = #"{"type":"workspace_list","workspaces":[]}"#,
    tabs: String = #"{"type":"tab_list","tabs":[]}"#
) async {
    switch request.method {
    case "workspace.list": await connection.reply(to: request, result: workspaces)
    case "tab.list": await connection.reply(to: request, result: tabs)
    default: assertionFailure("Unexpected metadata request: \(request.method)")
    }
}

private func clientSnapshot(_ panes: [PaneInfo]) -> PresentationSnapshot {
    PresentationSnapshot(panes: panes, workspaces: [], tabs: [])
}

private func pane(_ id: String) -> PaneInfo {
    PaneInfo(paneID: id, terminalID: "terminal", workspaceID: "workspace", tabID: "tab", focused: false, label: nil, agent: nil, title: nil, displayAgent: nil, agentStatus: .working, revision: 1)
}

private func paneJSON(_ id: String) -> String {
    #"{"pane_id":"\#(id)","terminal_id":"terminal","workspace_id":"workspace","tab_id":"tab","focused":false,"agent_status":"working","revision":1}"#
}

private func paneListResult(ids: [String]) -> String {
    #"{"type":"pane_list","panes":[\#(ids.map(paneJSON).joined(separator: ","))]}"#
}

private func paneFocusResult(id: String) -> String {
    #"{"type":"pane_info","pane":\#(paneJSON(id))}"#
}

private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async {
    while !(await condition()) { await Task.yield() }
}

private extension AsyncStream<HerdrClientEvent> {
    func next() async -> HerdrClientEvent? {
        var iterator = makeAsyncIterator()
        return await iterator.next()
    }
}
