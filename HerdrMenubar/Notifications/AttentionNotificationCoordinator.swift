import OSLog

actor AttentionNotificationCoordinator: AttentionNotificationCoordinating {
    private let service: any NativeNotificationServing
    private let latestTargetRecorder: any LatestNotificationTargetRecording
    private var baselinedSessions: Set<SessionID> = []
    private var statuses: [SessionID: [String: AgentStatus]] = [:]
    private var nextDeliveryOrdinal: UInt64 = 0

    init(
        service: any NativeNotificationServing,
        latestTargetRecorder: any LatestNotificationTargetRecording
    ) {
        self.service = service
        self.latestTargetRecorder = latestTargetRecorder
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

        let candidates = canonicalItems.compactMap { item -> AttentionNotificationEvent? in
            guard item.status == .blocked || item.status == .done else { return nil }
            guard previous[item.paneID] != item.status else { return nil }
            return AttentionNotificationEvent(
                target: NotificationSelectionTarget(
                    sessionID: session.id,
                    paneID: item.paneID
                ),
                sessionName: session.displayName,
                visibleLabel: item.visibleLabel,
                status: item.status
            )
        }

        for event in candidates {
            guard !Task.isCancelled else { return }
            precondition(nextDeliveryOrdinal < .max, "notification delivery ordinal exhausted")
            nextDeliveryOrdinal += 1
            let ordinal = nextDeliveryOrdinal
            do {
                let result = try await service.deliver(event, sound: policy.soundEnabled)
                if result == .accepted {
                    await latestTargetRecorder.record(event.target, ordinal: ordinal)
                }
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
