import Foundation

@MainActor
final class GlobalShortcutController {
    private let registrar: any ShortcutRegistering
    private let latestTarget: any LatestNotificationTargetRecording
    private let toggleMenu: @MainActor () -> Void
    private let selectTarget: @MainActor (NotificationSelectionTarget) -> Void
    private var generation: UUID?
    private var tasks: [Task<Void, Never>] = []
    private var stopTask: Task<Void, Never>?

    init(
        registrar: any ShortcutRegistering,
        latestTarget: any LatestNotificationTargetRecording,
        toggleMenu: @escaping @MainActor () -> Void,
        selectTarget: @escaping @MainActor (NotificationSelectionTarget) -> Void
    ) {
        self.registrar = registrar
        self.latestTarget = latestTarget
        self.toggleMenu = toggleMenu
        self.selectTarget = selectTarget
    }

    func start() {
        guard generation == nil, stopTask == nil else { return }
        let token = UUID()
        generation = token
        tasks = ShortcutAction.allCases.map { action in
            let events = registrar.events(for: action)
            return Task { [weak self] in
                for await event in events where event == .keyUp {
                    guard
                        let self,
                        self.generation == token,
                        !Task.isCancelled
                    else {
                        return
                    }
                    await self.handle(action, token: token)
                }
            }
        }
    }

    func stop() async {
        if let stopTask {
            await stopTask.value
            return
        }
        guard generation != nil || !tasks.isEmpty else { return }
        generation = nil
        let stoppingTasks = tasks
        stoppingTasks.forEach { $0.cancel() }
        let drainTask = Task {
            for task in stoppingTasks {
                await task.value
            }
        }
        stopTask = drainTask
        await drainTask.value
        tasks.removeAll()
        stopTask = nil
    }

    private func handle(_ action: ShortcutAction, token: UUID) async {
        guard generation == token, !Task.isCancelled else { return }
        switch action {
        case .toggleMenu:
            toggleMenu()
        case .focusLatestNotification:
            guard let target = await latestTarget.latest() else { return }
            guard generation == token, !Task.isCancelled else { return }
            selectTarget(target)
        }
    }
}
