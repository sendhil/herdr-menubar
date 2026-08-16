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
        var canonicalByPaneID: [String: AgentMenuItem] = [:]
        // The last occurrence in an authoritative snapshot wins for a duplicate pane ID.
        for item in items {
            canonicalByPaneID[item.paneID] = item
        }
        let canonicalItems = canonicalByPaneID.values.sorted(by: AgentMenuItem.labelOrder)
        var current: [String: AgentStatus] = [:]
        for item in canonicalItems {
            current[item.paneID] = item.status
        }
        guard baselinedSessions.contains(session.id) else {
            baselinedSessions.insert(session.id)
            statuses[session.id] = current
            return
        }

        let previous = statuses[session.id] ?? [:]
        statuses[session.id] = current
        guard policy.notificationsEnabled else { return }

        for item in canonicalItems {
            guard item.status == .blocked || item.status == .done else { continue }
            guard previous[item.paneID] != item.status else { continue }
            guard !Task.isCancelled else { return }
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
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
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
