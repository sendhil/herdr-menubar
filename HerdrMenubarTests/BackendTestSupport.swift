import Foundation
@testable import HerdrMenubar

// Test-only shims that keep Herdr-shaped tests readable after the backend migration.

extension AgentSessionKey {
    static var `default`: AgentSessionKey { AgentSessionKey(herdr: .default) }
    static func named(_ name: String) -> AgentSessionKey { AgentSessionKey(herdr: .named(name)) }
}

extension SelectionTarget {
    /// Herdr targets only.
    var sessionID: SessionID { target.session.herdrSessionID! }
    var paneID: String { target.paneID }
}

/// Herdr attention records for a pane list, exactly as `HerdrBackend` builds them.
func herdrRecords(_ session: SessionDescriptor, _ panes: [PaneInfo]) -> [AttentionRecord] {
    HerdrBackend.makeSnapshot(
        PresentationSnapshot(panes: panes, workspaces: [], tabs: []),
        sessionID: session.id
    ).attention
}

extension AttentionNotificationCoordinating {
    /// Herdr-shaped reconcile so pane-list tests express "Herdr exactly as today".
    func reconcile(
        session: SessionDescriptor,
        items: [PaneInfo],
        policy: NotificationDeliveryPolicy
    ) async {
        await reconcile(
            session: AgentSessionDescriptor(herdr: session),
            records: herdrRecords(session, items),
            policy: policy
        )
    }
}
