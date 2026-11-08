import UserNotifications
import XCTest
@testable import HerdrMenubar

/// Spec "Notifications": Rex bodies carry the sanitized `msg` on the first line and always end
/// with `<primary label> — Rex · <session label>`. Herdr content is unchanged.
final class RexNotificationContentTests: XCTestCase {
    func testRexBodyPutsMessageFirstThenPrimaryLabelAndSession() async throws {
        let backend = FakeNotificationCenterBackend(settings: .authorized)
        let service = NativeNotificationService(backend: backend)

        _ = try await service.deliver(rexEvent(.blocked, message: "Allow rm -rf build?"), sound: false)

        let request = try XCTUnwrap(backend.addedRequests.first)
        XCTAssertEqual(request.content.title, "Agent blocked")
        XCTAssertEqual(request.content.body, "Allow rm -rf build?\nPlayback — Rex · fix-playback")
        XCTAssertEqual(request.content.userInfo["backend"] as? String, "rex")
        XCTAssertEqual(request.content.userInfo["rex_session_id"] as? String, "s1")
    }

    func testRexBodyWithoutMessageIsOnlyTheSourceLine() async throws {
        let backend = FakeNotificationCenterBackend(settings: .authorized)
        let service = NativeNotificationService(backend: backend)

        _ = try await service.deliver(rexEvent(.error, message: nil), sound: false)

        let request = try XCTUnwrap(backend.addedRequests.first)
        XCTAssertEqual(request.content.title, "Agent failed")
        XCTAssertEqual(request.content.body, "Playback — Rex · fix-playback")
    }

    func testRexBodyUsesOnlyTheFirstNonEmptyMessageLine() async throws {
        let backend = FakeNotificationCenterBackend(settings: .authorized)
        let service = NativeNotificationService(backend: backend)

        _ = try await service.deliver(rexEvent(.done, message: "Tests passed\nsecond line"), sound: false)
        _ = try await service.deliver(rexEvent(.done, message: "   "), sound: false)

        let bodies = backend.addedRequests.map(\.content.body)
        XCTAssertEqual(bodies, [
            "Tests passed\nPlayback — Rex · fix-playback",
            "Playback — Rex · fix-playback"
        ])
        XCTAssertEqual(backend.addedRequests.first?.content.title, "Agent finished")
    }

    func testHerdrBodyIsUnchangedEvenIfAMessageWereSet() async throws {
        let backend = FakeNotificationCenterBackend(settings: .authorized)
        let service = NativeNotificationService(backend: backend)

        _ = try await service.deliver(AttentionNotificationEvent(
            target: .herdr(.named("work"), paneID: "p"),
            sessionName: "work",
            visibleLabel: "api · claude",
            status: .blocked,
            message: "ignored"
        ), sound: false)

        XCTAssertEqual(backend.addedRequests.first?.content.body, "api · claude — work")
    }

    func testCoordinatorForwardsRexMessageAndLeavesHerdrMessageNil() async {
        let service = MessageRecordingService()
        let coordinator = AttentionNotificationCoordinator(service: service, latestTargetRecorder: MessageRecordingRecorder())
        let rex = AgentSessionDescriptor(key: AgentSessionKey(backend: .rex, rawID: "s1"), displayName: "fix-playback")
        let herdr = AgentSessionDescriptor(key: .named("work"), displayName: "work")
        let policy = NotificationDeliveryPolicy(notificationsEnabled: true, soundEnabled: false)
        await coordinator.reconcile(session: rex, records: [], policy: policy)
        await coordinator.reconcile(session: herdr, records: [], policy: policy)

        await coordinator.reconcile(session: rex, records: [AttentionRecord(
            target: AgentTarget(session: rex.key, paneID: "b1"), recordID: "", epoch: 4, state: .blocked,
            visibleLabel: "Playback", message: "Allow rm -rf build?"
        )], policy: policy)
        await coordinator.reconcile(session: herdr, records: [AttentionRecord(
            target: AgentTarget(session: herdr.key, paneID: "p"), recordID: "", epoch: 0, state: .blocked,
            visibleLabel: "api · claude", message: nil
        )], policy: policy)

        let events = await service.events
        XCTAssertEqual(events, [
            AttentionNotificationEvent(
                target: SelectionTarget(target: AgentTarget(session: rex.key, paneID: "b1"), sessionDisplayName: "fix-playback"),
                sessionName: "fix-playback", visibleLabel: "Playback", status: .blocked, message: "Allow rm -rf build?"
            ),
            AttentionNotificationEvent(
                target: .herdr(.named("work"), paneID: "p"),
                sessionName: "work", visibleLabel: "api · claude", status: .blocked, message: nil
            )
        ])
    }
}

private func rexEvent(_ status: AttentionState, message: String?) -> AttentionNotificationEvent {
    AttentionNotificationEvent(
        target: SelectionTarget(
            target: AgentTarget(session: AgentSessionKey(backend: .rex, rawID: "s1"), paneID: "b1"),
            sessionDisplayName: "fix-playback"
        ),
        sessionName: "fix-playback",
        visibleLabel: "Playback",
        status: status,
        message: message
    )
}

private actor MessageRecordingService: NativeNotificationServing {
    private(set) var events: [AttentionNotificationEvent] = []
    func responses() async -> NotificationResponseSubscription { .finished() }
    func requestAuthorization() async throws -> Bool { true }
    func settings() async -> NotificationSystemSettings { .authorized }
    func deliver(_ event: AttentionNotificationEvent, sound: Bool) async throws -> NotificationDeliveryResult {
        events.append(event)
        return .accepted
    }
}

private actor MessageRecordingRecorder: LatestNotificationTargetRecording {
    func record(_ target: SelectionTarget, ordinal: UInt64) async {}
    func latest() async -> SelectionTarget? { nil }
    func reset() async {}
    func sealAndReset() async {}
}
