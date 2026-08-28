actor LatestNotificationTargetStore: LatestNotificationTargetRecording {
    private var entry: (ordinal: UInt64, target: NotificationSelectionTarget)?
    private var isSealed = false

    func record(_ target: NotificationSelectionTarget, ordinal: UInt64) {
        guard !isSealed else { return }
        guard entry == nil || ordinal > entry!.ordinal else { return }
        entry = (ordinal, target)
    }

    func latest() -> NotificationSelectionTarget? {
        entry?.target
    }

    func reset() {
        entry = nil
    }

    func sealAndReset() {
        isSealed = true
        entry = nil
    }
}
