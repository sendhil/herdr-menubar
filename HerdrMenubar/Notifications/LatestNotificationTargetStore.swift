actor LatestNotificationTargetStore: LatestNotificationTargetRecording {
    private var entry: (ordinal: UInt64, target: NotificationSelectionTarget)?

    func record(_ target: NotificationSelectionTarget, ordinal: UInt64) {
        guard entry == nil || ordinal > entry!.ordinal else { return }
        entry = (ordinal, target)
    }

    func latest() -> NotificationSelectionTarget? {
        entry?.target
    }

    func reset() {
        entry = nil
    }
}
