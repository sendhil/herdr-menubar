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

extension AgentRow {
    var paneID: String { target.paneID }
}

extension AgentStore {
    /// Herdr-only store with the pre-backend initializer shape, so existing store and
    /// integration tests exercise AgentStore + HerdrBackend unchanged.
    convenience init(
        supervisor: any SessionSupervising,
        terminalActivator: any TerminalActivating,
        ghosttyFocuser: any GhosttySessionFocusing,
        attentionCoordinator: any AttentionNotificationCoordinating,
        notificationService: any NativeNotificationServing,
        preferences: Preferences = Preferences()
    ) {
        self.init(
            backends: [HerdrBackend(
                supervisor: supervisor,
                terminalActivator: terminalActivator,
                ghosttyFocuser: ghosttyFocuser,
                preferences: preferences
            )],
            attentionCoordinator: attentionCoordinator,
            notificationService: notificationService,
            preferences: preferences
        )
    }

    /// Menu-row selection of a Herdr row read from the store's sections.
    func select(_ row: AgentRow) async {
        await selectRow(SelectionTarget(
            target: row.target,
            sessionDisplayName: row.target.session.herdrSessionID?.displayName ?? row.target.session.rawID
        ))
    }
}
