import OSLog

actor AttentionNotificationCoordinator: AttentionNotificationCoordinating {
    private struct RecordKey: Hashable {
        let target: AgentTarget
        let recordID: String
    }

    private struct RecordStamp: Equatable {
        let state: AttentionState
        let epoch: Int
    }

    private let service: any NativeNotificationServing
    private let latestTargetRecorder: any LatestNotificationTargetRecording
    private var baselinedSessions: Set<AgentSessionKey> = []
    private var history: [AgentSessionKey: [RecordKey: RecordStamp]] = [:]
    private var nextDeliveryOrdinal: UInt64 = 0

    init(
        service: any NativeNotificationServing,
        latestTargetRecorder: any LatestNotificationTargetRecording
    ) {
        self.service = service
        self.latestTargetRecorder = latestTargetRecorder
    }

    func reconcile(
        session: AgentSessionDescriptor,
        records: [AttentionRecord],
        policy: NotificationDeliveryPolicy
    ) async {
        // The last occurrence of a record key wins; delivery keeps first-occurrence order.
        var canonical: [RecordKey: AttentionRecord] = [:]
        for record in records {
            canonical[Self.key(record)] = record
        }
        var ordered: [AttentionRecord] = []
        var emitted: Set<RecordKey> = []
        for record in records {
            let key = Self.key(record)
            guard emitted.insert(key).inserted, let winner = canonical[key] else { continue }
            ordered.append(winner)
        }
        let current = canonical.mapValues { RecordStamp(state: $0.state, epoch: $0.epoch) }

        guard baselinedSessions.contains(session.key) else {
            baselinedSessions.insert(session.key)
            history[session.key] = current
            return
        }

        // Each reconcile replaces the session's history with exactly the given records.
        let previous = history[session.key] ?? [:]
        history[session.key] = current
        guard policy.notificationsEnabled else { return }

        let deliverableStates = policy.notifyStates[session.key.backend] ?? session.key.backend.defaultNotifyStates
        let candidates = ordered.compactMap { record -> AttentionNotificationEvent? in
            guard deliverableStates.contains(record.state) else { return nil }
            let stamp = RecordStamp(state: record.state, epoch: record.epoch)
            guard previous[Self.key(record)] != stamp else { return nil }
            return AttentionNotificationEvent(
                target: SelectionTarget(target: record.target, sessionDisplayName: session.displayName),
                sessionName: session.displayName,
                visibleLabel: record.visibleLabel,
                status: record.state
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

    func unavailable(session: AgentSessionKey) {
        // Preserve the last authoritative history through the backend's grace period or outage.
    }

    func remove(session: AgentSessionKey) {
        baselinedSessions.remove(session)
        history.removeValue(forKey: session)
    }

    func reset() {
        baselinedSessions.removeAll()
        history.removeAll()
    }

    private static func key(_ record: AttentionRecord) -> RecordKey {
        RecordKey(target: record.target, recordID: record.recordID)
    }
}
