import OSLog

actor AttentionNotificationCoordinator: AttentionNotificationCoordinating {
    private let service: any NativeNotificationServing
    private var baselinedSessions: Set<SessionID> = []
    private var statuses: [SessionID: [String: AgentStatus]] = [:]

    init(service: any NativeNotificationServing) {
        self.service = service
    }

    func reconcile(
        session: SessionDescriptor,
        items: [AgentMenuItem],
        policy: NotificationDeliveryPolicy
    ) async {
        let current = Dictionary(uniqueKeysWithValues: items.map { ($0.paneID, $0.status) })
        guard baselinedSessions.contains(session.id) else {
            baselinedSessions.insert(session.id)
            statuses[session.id] = current
            return
        }

        let previous = statuses[session.id] ?? [:]
        statuses[session.id] = current
        guard policy.notificationsEnabled else { return }

        for item in items.sorted(by: AgentMenuItem.labelOrder) {
            guard item.status == .blocked || item.status == .done else { continue }
            guard previous[item.paneID] != item.status else { continue }
            do {
                try await service.deliver(
                    AttentionNotificationEvent(
                        target: NotificationSelectionTarget(
                            sessionID: session.id,
                            paneID: item.paneID
                        ),
                        sessionName: session.displayName,
                        visibleLabel: item.visibleLabel,
                        status: item.status
                    ),
                    sound: policy.soundEnabled
                )
            } catch {
                AppLog.systemActions.error(
                    "Notification delivery failed: \(error.localizedDescription, privacy: .private)"
                )
            }
        }
    }

    func unavailable(sessionID: SessionID) {
        // Preserve the last authoritative status through the supervisor's grace period.
    }

    func remove(sessionID: SessionID) {
        baselinedSessions.remove(sessionID)
        statuses.removeValue(forKey: sessionID)
    }

    func reset() {
        baselinedSessions.removeAll()
        statuses.removeAll()
    }
}
