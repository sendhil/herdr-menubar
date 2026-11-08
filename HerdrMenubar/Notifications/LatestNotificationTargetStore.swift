actor LatestNotificationTargetStore: LatestNotificationTargetRecording {
    private var entry: (ordinal: UInt64, target: SelectionTarget)?
    private var isSealed = false

    func record(_ target: SelectionTarget, ordinal: UInt64) {
        guard !isSealed else { return }
        guard entry == nil || ordinal > entry!.ordinal else { return }
        entry = (ordinal, target)
    }

    func latest() -> SelectionTarget? {
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
