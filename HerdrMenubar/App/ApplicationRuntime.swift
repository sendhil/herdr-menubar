import AppKit
import Observation

@MainActor
protocol ApplicationRuntimeServing: AnyObject {
    func start() async
    func applicationDidBecomeActive() async
    func stop() async
    func openWidgetURL(_ url: URL) async
}

extension ApplicationRuntimeServing {
    func openWidgetURL(_ url: URL) async {}
}

@MainActor
struct ApplicationRuntimeDependencies {
    let startStatusItem: () -> Void
    let applyStatusItem: (StatusItemPresentation) -> Void
    let toggleStatusItem: () -> Void
    let stopStatusItem: () -> Void
    let startShortcuts: () -> Void
    let stopShortcuts: () async -> Void
    let showShortcutSettings: () -> Void
    let stopShortcutSettings: () -> Void
    let refreshLoginItem: () -> Void
    let setLoginItem: (Bool) async throws -> Void
    let refreshNotifications: () async -> Void
    let setNotifications: (Bool) async throws -> Void
    let setSound: (Bool) -> Void
    let refreshShortcutRegistration: () -> Void
    let startStore: () async -> Void
    let stopStore: () async -> Void
    let retryStore: () async -> Void
    let selectTarget: (NotificationSelectionTarget) -> Void
    let selectTerminal: (String) -> Void
    let sealAndResetLatestTarget: () async -> Void
    let makePresentation: () -> StatusItemPresentation
    let quit: () -> Void
    let lifecycleInvalidated: () -> Void
    let observationCancelled: () -> Void
    let menuActionsCancelled: () -> Void
    let menuActionsDrained: () -> Void
    let shouldStartSynchronization: Bool
}

@MainActor
final class ApplicationRuntime: ApplicationRuntimeServing {
    private let dependencies: ApplicationRuntimeDependencies
    private var generation: UUID?
    private var readyGeneration: UUID?
    private var startTask: Task<Void, Never>?
    private var startToken: UUID?
    private var stopTask: Task<Void, Never>?
    private var stopToken: UUID?
    private var isStopped = false
    private var observationArm: PresentationObservationArm?
    private var menuActions: [UUID: OwnedMenuAction] = [:]

    init(dependencies: ApplicationRuntimeDependencies) {
        self.dependencies = dependencies
    }

    static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ApplicationRuntime {
        let supervisor = SessionSupervisor(
            discovery: SessionDiscovery(),
            clientFactory: LiveSessionClientFactory()
        )
        let widgetPublisher = AgentWidgetPublisher(supervisor: supervisor)
        let processRunner = BoundedProcessRunner()
        let wezTermCLI = LiveWezTermCLI(runner: processRunner)
        let wezTermFocuser = LiveWezTermFocusAdapter(
            supervisor: supervisor,
            cli: wezTermCLI
        )
        let preferences = Preferences()
        let notificationService = NativeNotificationService()
        let latestTargetStore = LatestNotificationTargetStore()
        let attentionCoordinator = AttentionNotificationCoordinator(
            service: notificationService,
            latestTargetRecorder: latestTargetStore
        )
        let notificationSettings = NotificationSettingsController(
            service: notificationService,
            preferences: preferences
        )
        let loginItemService = LoginItemService()
        let store = AgentStore(
            supervisor: supervisor,
            terminalActivator: TerminalActivationService(),
            wezTermFocuser: wezTermFocuser,
            attentionCoordinator: attentionCoordinator,
            notificationService: notificationService,
            preferences: preferences
        )
        let registrar = LiveShortcutRegistrar()
        let assignmentController = ShortcutAssignmentController(registrar: registrar)
        let shortcutWindow = KeyboardShortcutSettingsWindowController(
            assignmentController: assignmentController
        )
        let callbackRelay = ApplicationRuntimeCallbackRelay()
        let statusItem = StatusItemController(
            driver: LiveStatusItemDriver(),
            action: { callbackRelay.perform($0) }
        )
        let shortcuts = GlobalShortcutController(
            registrar: registrar,
            latestTarget: latestTargetStore,
            toggleMenu: { callbackRelay.toggleMenu() },
            selectTarget: { callbackRelay.select($0) }
        )
        let terminals = TerminalCatalog().installedTerminals()
        let presentationBuilder = StatusMenuPresentationBuilder()

        let runtime = ApplicationRuntime(dependencies: ApplicationRuntimeDependencies(
            startStatusItem: { statusItem.start() },
            applyStatusItem: { statusItem.apply($0) },
            toggleStatusItem: { statusItem.toggle() },
            stopStatusItem: { statusItem.stop() },
            startShortcuts: { shortcuts.start() },
            stopShortcuts: { await shortcuts.stop() },
            showShortcutSettings: { shortcutWindow.show() },
            stopShortcutSettings: { shortcutWindow.stop() },
            refreshLoginItem: { loginItemService.refreshStatus() },
            setLoginItem: { enabled in
                try await updateLoginIntent(
                    enabled: enabled,
                    service: loginItemService,
                    preferences: preferences
                )
            },
            refreshNotifications: { await notificationSettings.refreshStatus() },
            setNotifications: { enabled in
                try await notificationSettings.setNotificationsEnabled(enabled)
            },
            setSound: { notificationSettings.setSoundEnabled($0) },
            refreshShortcutRegistration: {
                assignmentController.refreshRegistrationStatus()
            },
            startStore: { await widgetPublisher.start(); await store.start() },
            stopStore: { await widgetPublisher.stop(); await store.stop() },
            retryStore: { await store.retry() },
            selectTarget: { store.select($0) },
            selectTerminal: {
                preferences.selectedTerminalBundleIdentifier = $0
            },
            sealAndResetLatestTarget: { await latestTargetStore.sealAndReset() },
            makePresentation: {
                presentationBuilder.make(
                    store: store,
                    preferences: preferences,
                    terminals: terminals,
                    loginItem: loginItemService,
                    notifications: notificationSettings
                )
            },
            quit: { NSApplication.shared.terminate(nil) },
            lifecycleInvalidated: {},
            observationCancelled: {},
            menuActionsCancelled: {},
            menuActionsDrained: {},
            shouldStartSynchronization: shouldStartSynchronization(environment: environment)
        ))
        callbackRelay.runtime = runtime
        return runtime
    }

    static func shouldStartSynchronization(environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] == nil
    }

    static func updateLoginIntent(
        enabled: Bool,
        service: any LoginItemManaging,
        preferences: Preferences
    ) async throws {
        try await service.setEnabled(enabled)
        if enabled && (service.status == .enabled || service.status == .requiresApproval) {
            preferences.launchAtLoginIntent = true
        } else if !enabled, service.status == .disabled {
            preferences.launchAtLoginIntent = false
        }
    }

    func start() async {
        if let stopTask {
            await stopTask.value
            return
        }
        guard !isStopped else { return }
        if let startTask {
            await startTask.value
            return
        }
        guard generation == nil else { return }

        let token = UUID()
        generation = token
        startToken = token
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await runStart(generation: token)
        }
        startTask = task
        await task.value
        if startToken == token {
            startTask = nil
            startToken = nil
        }
    }

    func openWidgetURL(_ url: URL) async {
        guard let target = WidgetAgentTarget(url: url) else { return }
        await start()
        guard let token = readyGeneration, isReady(token) else { return }
        let session: SessionID = target.session == "default" ? .default : .named(String(target.session.dropFirst(6)))
        dependencies.selectTarget(NotificationSelectionTarget(sessionID: session, paneID: target.paneID))
    }

    func applicationDidBecomeActive() async {
        guard let token = readyGeneration, isReady(token) else { return }
        dependencies.refreshLoginItem()
        await dependencies.refreshNotifications()
        guard isReady(token) else { return }
        dependencies.refreshShortcutRegistration()
    }

    func stop() async {
        if let stopTask {
            await stopTask.value
            return
        }
        guard !isStopped else { return }

        isStopped = true
        generation = nil
        readyGeneration = nil
        dependencies.lifecycleInvalidated()
        startTask?.cancel()
        startTask = nil
        startToken = nil

        let token = UUID()
        stopToken = token
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await dependencies.stopShortcuts()
            dependencies.stopStatusItem()
            dependencies.stopShortcutSettings()
            cancelObservation()
            await dependencies.sealAndResetLatestTarget()
            await cancelAndDrainMenuActions()
            await dependencies.stopStore()
        }
        stopTask = task
        await task.value
        if stopToken == token {
            stopTask = nil
            stopToken = nil
        }
    }

    func perform(_ action: StatusMenuAction) {
        guard let token = readyGeneration, isReady(token) else { return }
        switch action {
        case .select(let target):
            dependencies.selectTarget(target)
        case .selectTerminal(let id):
            dependencies.selectTerminal(id)
        case .setLaunchAtLogin(let enabled):
            let dependencies = dependencies
            launchMenuAction(generation: token) {
                try? await dependencies.setLoginItem(enabled)
            }
        case .setNotifications(let enabled):
            let dependencies = dependencies
            launchMenuAction(generation: token) {
                try? await dependencies.setNotifications(enabled)
            }
        case .setSound(let enabled):
            dependencies.setSound(enabled)
        case .retryUnavailable:
            let dependencies = dependencies
            launchMenuAction(generation: token) {
                await dependencies.retryStore()
            }
        case .openKeyboardShortcuts:
            dependencies.showShortcutSettings()
        case .quit:
            dependencies.quit()
        }
    }

    func receiveToggleMenuShortcut() {
        guard let token = readyGeneration, isReady(token) else { return }
        dependencies.toggleStatusItem()
    }

    func receiveFocusLatestShortcut(_ target: NotificationSelectionTarget) {
        guard let token = readyGeneration, isReady(token) else { return }
        dependencies.selectTarget(target)
    }
}

@MainActor
private extension ApplicationRuntime {
    func runStart(generation token: UUID) async {
        guard owns(token) else { return }
        dependencies.startStatusItem()
        guard owns(token) else { return }
        dependencies.startShortcuts()
        guard owns(token) else { return }
        dependencies.refreshLoginItem()
        await dependencies.refreshNotifications()
        guard owns(token) else { return }
        dependencies.refreshShortcutRegistration()
        observePresentation(generation: token)
        guard owns(token) else { return }
        if dependencies.shouldStartSynchronization {
            await dependencies.startStore()
            guard owns(token) else { return }
        }
        readyGeneration = token
    }

    func observePresentation(generation token: UUID) {
        guard owns(token) else { return }
        let arm = PresentationObservationArm()
        let snapshot = withObservationTracking {
            dependencies.makePresentation()
        } onChange: { [weak self, weak arm] in
            Task { @MainActor in
                guard let self, let arm, arm.consume(), self.observationArm === arm else {
                    return
                }
                self.observePresentation(generation: token)
            }
        }
        guard owns(token) else {
            arm.cancel()
            return
        }
        observationArm = arm
        dependencies.applyStatusItem(snapshot)
    }

    func cancelObservation() {
        observationArm?.cancel()
        observationArm = nil
        dependencies.observationCancelled()
    }

    func launchMenuAction(
        generation token: UUID,
        operation: @escaping @MainActor () async -> Void
    ) {
        guard isReady(token) else { return }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.completeMenuAction(id: id, generation: token) }
            guard self.isReady(token) else { return }
            await operation()
        }
        menuActions[id] = OwnedMenuAction(generation: token, task: task)
    }

    func completeMenuAction(id: UUID, generation token: UUID) {
        guard menuActions[id]?.generation == token else { return }
        menuActions[id] = nil
    }

    func cancelAndDrainMenuActions() async {
        let actions = Array(menuActions.values)
        actions.forEach { $0.task.cancel() }
        dependencies.menuActionsCancelled()
        for action in actions {
            await action.task.value
        }
        dependencies.menuActionsDrained()
    }

    func owns(_ token: UUID) -> Bool {
        !isStopped && generation == token && !Task.isCancelled
    }

    func isReady(_ token: UUID) -> Bool {
        owns(token) && readyGeneration == token
    }
}

private struct OwnedMenuAction {
    let generation: UUID
    let task: Task<Void, Never>
}

@MainActor
private final class PresentationObservationArm {
    private var isActive = true

    func consume() -> Bool {
        guard isActive else { return false }
        isActive = false
        return true
    }

    func cancel() {
        isActive = false
    }
}

@MainActor
private final class ApplicationRuntimeCallbackRelay {
    weak var runtime: ApplicationRuntime?

    func perform(_ action: StatusMenuAction) {
        runtime?.perform(action)
    }

    func toggleMenu() {
        runtime?.receiveToggleMenuShortcut()
    }

    func select(_ target: NotificationSelectionTarget) {
        runtime?.receiveFocusLatestShortcut(target)
    }
}
