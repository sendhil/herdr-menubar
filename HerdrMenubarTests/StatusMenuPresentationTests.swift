import Foundation
import XCTest
@testable import HerdrMenubar

@MainActor
final class StatusMenuPresentationTests: XCTestCase {
    func testSearchingSnapshotReproducesCompleteBaseMenu() {
        let fixture = PresentationFixture()

        XCTAssertEqual(fixture.presentation(), StatusItemPresentation(
            icon: MenuBarIconPresentation(connectionState: .searching, attentionCount: 0),
            accessibilityValue: "Searching for Herdr sessions",
            menu: [
                .info("Searching for Herdr sessions…", tone: .secondary),
                .submenu(title: "Terminal", children: [
                    .action(
                        title: "WezTerm (Unavailable)", state: .on, isEnabled: false,
                        action: .selectTerminal("com.github.wez.wezterm")
                    )
                ]),
                .toggle(
                    title: "Launch at Login", isOn: false, isEnabled: true,
                    action: .setLaunchAtLogin(true)
                ),
                .heading("NOTIFICATIONS"),
                .toggle(
                    title: "Notifications", isOn: false, isEnabled: true,
                    action: .setNotifications(true)
                ),
                .toggle(
                    title: "Sound", isOn: false, isEnabled: false,
                    action: .setSound(true)
                ),
                .action(
                    title: "Keyboard Shortcuts…", state: .off, isEnabled: true,
                    action: .openKeyboardShortcuts
                ),
                .separator,
                .action(title: "Quit", state: .off, isEnabled: true, action: .quit)
            ]
        ))
    }

    func testNoSessionsConnectingAndConnectedIdleUseExactConnectionCopy() async {
        let fixture = PresentationFixture()
        await fixture.start()

        await fixture.send(.discoverySnapshot([]))
        await fixture.waitUntil { fixture.store.connectionState == .noSessions }
        XCTAssertEqual(fixture.presentation().menu.first,
                       .info("No Herdr sessions running", tone: .secondary))

        await fixture.send(.discoverySnapshot([fixture.workDescriptor]))
        await fixture.waitUntil { fixture.store.connectionState == .connecting }
        XCTAssertEqual(fixture.presentation().menu.first,
                       .info("Connecting to Herdr sessions…", tone: .secondary))

        await fixture.send(.connected(fixture.workDescriptor, fixture.snapshot([])))
        await fixture.waitUntil { fixture.store.connectionState == .connected }
        XCTAssertEqual(fixture.presentation().menu.first,
                       .info("No active agents", tone: .secondary))
        XCTAssertEqual(
            fixture.presentation().accessibilityValue,
            "Connected, no agents need attention"
        )
        await fixture.stop()
    }

    func testAttentionPrecedesWorkingAndActionsDisambiguateDuplicatePaneIDs() async {
        let fixture = PresentationFixture()
        await fixture.start()
        let defaultDescriptor = fixture.defaultDescriptor
        let workDescriptor = fixture.workDescriptor

        await fixture.send(.connected(workDescriptor, fixture.snapshot([
            fixture.pane("same", .done, title: "Work Done"),
            fixture.pane("work-active", .working, title: "Work Active")
        ])))
        await fixture.send(.connected(defaultDescriptor, fixture.snapshot([
            fixture.pane("default-done", .done, title: "Zulu Done"),
            fixture.pane("same", .blocked, title: "Alpha Blocked"),
            fixture.pane("default-active", .working, title: "Default Active")
        ])))
        await fixture.waitUntil {
            fixture.store.attentionCount == 3 && fixture.store.workingSections.count == 2
        }

        let prefix = Array(fixture.presentation().menu.prefix(13))
        XCTAssertEqual(prefix, [
            .heading("NEEDS ATTENTION"),
            .heading("DEFAULT"),
            .agent(
                title: "Alpha Blocked · Claude", subtitle: "blocked · Claude",
                symbol: "exclamationmark.triangle.fill", quieter: false,
                target: NotificationSelectionTarget(sessionID: .default, paneID: "same")
            ),
            .agent(
                title: "Zulu Done · Claude", subtitle: "done · Claude",
                symbol: "checkmark.circle.fill", quieter: false,
                target: NotificationSelectionTarget(sessionID: .default, paneID: "default-done")
            ),
            .heading("WORK"),
            .agent(
                title: "Work Done · Claude", subtitle: "done · Claude",
                symbol: "checkmark.circle.fill", quieter: false,
                target: NotificationSelectionTarget(sessionID: .named("work"), paneID: "same")
            ),
            .separator,
            .heading("WORKING"),
            .heading("DEFAULT"),
            .agent(
                title: "Default Active · Claude", subtitle: "working · Claude",
                symbol: "ellipsis.circle", quieter: true,
                target: NotificationSelectionTarget(
                    sessionID: .default, paneID: "default-active"
                )
            ),
            .heading("WORK"),
            .agent(
                title: "Work Active · Claude", subtitle: "working · Claude",
                symbol: "ellipsis.circle", quieter: true,
                target: NotificationSelectionTarget(
                    sessionID: .named("work"), paneID: "work-active"
                )
            ),
            .separator
        ])
        XCTAssertEqual(
            fixture.presentation().icon,
            MenuBarIconPresentation(connectionState: .connected, attentionCount: 3)
        )
        XCTAssertEqual(
            fixture.presentation().accessibilityValue,
            "Connected, 3 agents need attention"
        )
        await fixture.stop()
    }

    func testAgentVisibleLabelChangesNeverChangeActionIdentityAndAllSymbolsMatchAgentRow() async {
        let fixture = PresentationFixture()
        await fixture.start()
        await fixture.send(.connected(fixture.defaultDescriptor, fixture.snapshot([
            fixture.pane("blocked", .blocked, title: "First"),
            fixture.pane("done", .done),
            fixture.pane("working", .working)
        ])))
        await fixture.waitUntil { fixture.store.attentionCount == 2 }

        XCTAssertEqual(fixture.agentNodes().map(\.symbol), [
            "exclamationmark.triangle.fill", "checkmark.circle.fill", "ellipsis.circle"
        ])
        let oldTarget = fixture.agentNodes().first?.target

        await fixture.send(.snapshot(.default, fixture.snapshot([
            fixture.pane("blocked", .blocked, title: "Renamed"),
            fixture.pane("done", .done),
            fixture.pane("working", .working)
        ])))
        await fixture.waitUntil { fixture.agentNodes().first?.title == "Renamed · Claude" }
        XCTAssertEqual(fixture.agentNodes().first?.target, oldTarget)
        await fixture.stop()
    }

    func testUnavailableSessionShowsReconnectingAndRetryInExactPosition() async throws {
        let fixture = PresentationFixture()
        await fixture.start()
        await fixture.send(.connected(fixture.defaultDescriptor, fixture.snapshot([])))
        await fixture.send(.connected(fixture.workDescriptor, fixture.snapshot([])))
        await fixture.send(.unavailable(.named("work"), "socket unavailable"))
        await fixture.waitUntil { fixture.store.unavailableSessions.count == 1 }

        let menu = fixture.presentation().menu
        XCTAssertEqual(Array(menu.prefix(3)), [
            .info("No active agents", tone: .secondary),
            .heading("RECONNECTING"),
            .info("work", tone: .secondary)
        ])
        let retryIndex = try XCTUnwrap(menu.firstIndex(of: .action(
            title: "Retry Unavailable Sessions", state: .off, isEnabled: true,
            action: .retryUnavailable
        )))
        let shortcutsIndex = try XCTUnwrap(menu.firstIndex(of: .action(
            title: "Keyboard Shortcuts…", state: .off, isEnabled: true,
            action: .openKeyboardShortcuts
        )))
        XCTAssertEqual(retryIndex + 1, shortcutsIndex)
        await fixture.stop()
    }

    func testTransientErrorUsesErrorTone() async {
        let fixture = PresentationFixture(focusError: PresentationTestError.focusFailed)
        await fixture.store.select(AgentMenuItem(
            session: fixture.workDescriptor,
            pane: fixture.pane("p", .blocked)
        ))

        XCTAssertTrue(fixture.presentation().menu.contains(.info(
            "Could not focus pane in work: focusFailed", tone: .error
        )))
    }

    func testTerminalSubmenuPreservesOrderSelectionAndUnavailableSavedChoice() {
        let fixture = PresentationFixture(
            selectedTerminal: "com.googlecode.iterm2",
            terminals: [
                TerminalApp(name: "Ghostty", bundleIdentifier: "com.mitchellh.ghostty"),
                TerminalApp(name: "Terminal", bundleIdentifier: "com.apple.Terminal")
            ]
        )

        XCTAssertEqual(fixture.terminalNode(), .submenu(title: "Terminal", children: [
            .action(
                title: "iTerm2 (Unavailable)", state: .on, isEnabled: false,
                action: .selectTerminal("com.googlecode.iterm2")
            ),
            .action(
                title: "Ghostty", state: .off, isEnabled: true,
                action: .selectTerminal("com.mitchellh.ghostty")
            ),
            .action(
                title: "Terminal", state: .off, isEnabled: true,
                action: .selectTerminal("com.apple.Terminal")
            )
        ]))

        fixture.preferences.selectedTerminalBundleIdentifier = "com.apple.Terminal"
        XCTAssertEqual(fixture.terminalNode(), .submenu(title: "Terminal", children: [
            .action(
                title: "Ghostty", state: .off, isEnabled: true,
                action: .selectTerminal("com.mitchellh.ghostty")
            ),
            .action(
                title: "Terminal", state: .on, isEnabled: true,
                action: .selectTerminal("com.apple.Terminal")
            )
        ]))
    }

    func testLoginToggleEnablementHelpAndErrorReproduceServiceState() {
        let fixture = PresentationFixture()
        fixture.login.status = .enabled
        fixture.login.isChanging = true

        var menu = fixture.presentation().menu
        XCTAssertTrue(menu.contains(.toggle(
            title: "Launch at Login", isOn: true, isEnabled: false,
            action: .setLaunchAtLogin(false)
        )))

        fixture.login.status = .requiresApproval
        fixture.login.isChanging = false
        menu = fixture.presentation().menu
        XCTAssertTrue(menu.contains(.toggle(
            title: "Launch at Login", isOn: false, isEnabled: true,
            action: .setLaunchAtLogin(true)
        )))
        XCTAssertTrue(menu.contains(.info("Allow in System Settings", tone: .secondary)))

        fixture.login.status = .disabled
        fixture.login.errorMessage = "Could not update Launch at Login."
        menu = fixture.presentation().menu
        XCTAssertTrue(menu.contains(.info("Could not update Launch at Login.", tone: .error)))

        fixture.login.status = .unavailable
        fixture.login.errorMessage = nil
        XCTAssertTrue(fixture.presentation().menu.contains(.toggle(
            title: "Launch at Login", isOn: false, isEnabled: false,
            action: .setLaunchAtLogin(true)
        )))
    }

    func testNotificationAndSoundTogglesExposeIndependentIntentHelpAndError() async {
        let denied = NotificationSystemSettings.denied
        let fixture = PresentationFixture(notificationSettings: denied)
        fixture.preferences.notificationsEnabled = true
        fixture.preferences.notificationSoundEnabled = true
        await fixture.notifications.refreshStatus()

        var menu = fixture.presentation().menu
        XCTAssertTrue(menu.contains(.toggle(
            title: "Notifications", isOn: true, isEnabled: true,
            action: .setNotifications(false)
        )))
        XCTAssertTrue(menu.contains(.toggle(
            title: "Sound", isOn: true, isEnabled: true,
            action: .setSound(false)
        )))
        XCTAssertTrue(menu.contains(.info(
            "Notifications are disabled in System Settings", tone: .secondary
        )))

        await fixture.notificationService.setAuthorizationError(PresentationTestError.authorization)
        fixture.preferences.notificationsEnabled = false
        do {
            try await fixture.notifications.setNotificationsEnabled(true)
            XCTFail("Expected authorization failure")
        } catch {}
        menu = fixture.presentation().menu
        XCTAssertTrue(menu.contains(.info("Could not enable notifications.", tone: .error)))
    }

    func testDeniedNotificationHelpReflectsDisabledUserIntent() async {
        let fixture = PresentationFixture(notificationSettings: .denied)
        await fixture.notifications.refreshStatus()

        XCTAssertTrue(fixture.presentation().menu.contains(.info(
            "Allow notifications in System Settings", tone: .secondary
        )))
    }

    func testNotificationAndSoundDisableWhilePermissionChangeIsActive() async {
        let fixture = PresentationFixture(gateAuthorization: true)
        fixture.preferences.notificationsEnabled = true
        fixture.preferences.notificationSoundEnabled = true
        let operation = Task { try await fixture.notifications.setNotificationsEnabled(true) }
        await fixture.notificationService.waitForAuthorizationRequest()

        let menu = fixture.presentation().menu
        XCTAssertTrue(menu.contains(.toggle(
            title: "Notifications", isOn: true, isEnabled: false,
            action: .setNotifications(false)
        )))
        XCTAssertTrue(menu.contains(.toggle(
            title: "Sound", isOn: true, isEnabled: false,
            action: .setSound(false)
        )))

        await fixture.notificationService.releaseAuthorization()
        _ = try? await operation.value
    }

    func testSystemSoundHelpIsPresentedWithoutDisablingEnabledSoundIntent() async {
        let fixture = PresentationFixture(notificationSettings: NotificationSystemSettings(
            authorization: .authorized,
            alertsEnabled: true,
            soundsEnabled: false
        ))
        fixture.preferences.notificationsEnabled = true
        fixture.preferences.notificationSoundEnabled = true
        await fixture.notifications.refreshStatus()

        let menu = fixture.presentation().menu
        XCTAssertTrue(menu.contains(.toggle(
            title: "Sound", isOn: true, isEnabled: true,
            action: .setSound(false)
        )))
        XCTAssertTrue(menu.contains(.info(
            "Notification sounds are disabled in System Settings", tone: .secondary
        )))
    }

    func testKeyboardShortcutsImmediatelyPrecedesFinalSeparatorAndQuit() {
        let suffix = Array(PresentationFixture().presentation().menu.suffix(3))
        XCTAssertEqual(suffix, [
            .action(
                title: "Keyboard Shortcuts…", state: .off, isEnabled: true,
                action: .openKeyboardShortcuts
            ),
            .separator,
            .action(title: "Quit", state: .off, isEnabled: true, action: .quit)
        ])
    }
}

private extension StatusMenuNode {
    var agentValue: (title: String, symbol: String, target: NotificationSelectionTarget)? {
        guard case .agent(let title, _, let symbol, _, let target) = self else { return nil }
        return (title, symbol, target)
    }
}

@MainActor
private final class PresentationFixture {
    let supervisor: PresentationSupervisor
    let preferences: Preferences
    let notificationService: PresentationNotificationService
    let notifications: NotificationSettingsController
    let login = PresentationLoginItem()
    let store: AgentStore
    let terminals: [TerminalApp]

    let defaultDescriptor = SessionDescriptor(
        id: .default, socketURL: URL(fileURLWithPath: "/tmp/presentation-default.sock")
    )
    let workDescriptor = SessionDescriptor(
        id: .named("work"), socketURL: URL(fileURLWithPath: "/tmp/presentation-work.sock")
    )

    init(
        focusError: (any Error)? = nil,
        selectedTerminal: String = Preferences.defaultTerminalBundleIdentifier,
        terminals: [TerminalApp] = [],
        notificationSettings: NotificationSystemSettings = .notDetermined,
        gateAuthorization: Bool = false
    ) {
        supervisor = PresentationSupervisor(focusError: focusError)
        let suite = "dev.herdr.menubar.status-presentation-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        preferences = Preferences(defaults: defaults)
        preferences.selectedTerminalBundleIdentifier = selectedTerminal
        notificationService = PresentationNotificationService(
            settings: notificationSettings,
            gateAuthorization: gateAuthorization
        )
        notifications = NotificationSettingsController(
            service: notificationService, preferences: preferences
        )
        store = AgentStore(
            supervisor: supervisor,
            terminalActivator: PresentationTerminalActivator(),
            wezTermFocuser: PresentationWezTermFocuser(),
            attentionCoordinator: PresentationAttentionCoordinator(),
            notificationService: notificationService,
            preferences: preferences
        )
        self.terminals = terminals
    }

    func presentation() -> StatusItemPresentation {
        StatusMenuPresentationBuilder().make(
            store: store,
            preferences: preferences,
            terminals: terminals,
            loginItem: login,
            notifications: notifications
        )
    }

    func terminalNode() -> StatusMenuNode? {
        presentation().menu.first {
            if case .submenu(title: "Terminal", children: _) = $0 { return true }
            return false
        }
    }

    func agentNodes() -> [(title: String, symbol: String, target: NotificationSelectionTarget)] {
        presentation().menu.compactMap(\.agentValue)
    }

    func snapshot(_ panes: [PaneInfo]) -> PresentationSnapshot {
        PresentationSnapshot(panes: panes, workspaces: [], tabs: [])
    }

    func pane(_ id: String, _ status: AgentStatus, title: String? = nil) -> PaneInfo {
        PaneInfo(
            paneID: id,
            terminalID: "terminal-\(id)",
            workspaceID: "workspace",
            tabID: "tab",
            focused: false,
            label: nil,
            agent: "claude",
            title: title,
            displayAgent: "Claude",
            agentStatus: status,
            revision: 1
        )
    }

    func start() async { await store.start() }
    func stop() async { await store.stop() }
    func send(_ event: SessionSupervisorEvent) async { await supervisor.send(event) }

    func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !condition(), clock.now < deadline { await Task.yield() }
        XCTAssertTrue(condition())
    }
}

private enum PresentationTestError: LocalizedError {
    case focusFailed
    case authorization

    var errorDescription: String? {
        switch self {
        case .focusFailed: "focusFailed"
        case .authorization: "authorization"
        }
    }
}

private actor PresentationSupervisor: SessionSupervising {
    private var continuation: AsyncStream<SessionSupervisorEvent>.Continuation?
    private let focusError: (any Error)?

    init(focusError: (any Error)?) { self.focusError = focusError }

    func events() -> AsyncStream<SessionSupervisorEvent> {
        let (stream, continuation) = AsyncStream<SessionSupervisorEvent>.makeStream()
        self.continuation = continuation
        return stream
    }
    func start() {}
    func stop() { continuation?.finish() }
    func retryUnavailable() {}
    func focus(sessionID: SessionID, paneID: String) throws -> PaneInfo {
        if let focusError { throw focusError }
        return PaneInfo(
            paneID: paneID, terminalID: "terminal", workspaceID: "workspace", tabID: "tab",
            focused: true, label: nil, agent: nil, title: nil, displayAgent: nil,
            agentStatus: .idle, revision: 1
        )
    }
    func setClientWindowTitle(
        sessionID: SessionID, title: String
    ) -> ClientWindowTitleResult {
        ClientWindowTitleResult(type: "client_window_title", changed: true, reason: "changed")
    }
    func clearClientWindowTitle(
        sessionID: SessionID, timeout: Duration
    ) -> ClientWindowTitleResult {
        ClientWindowTitleResult(type: "client_window_title", changed: true, reason: "changed")
    }
    func refresh(sessionID: SessionID) {}
    func send(_ event: SessionSupervisorEvent) { continuation?.yield(event) }
}

private actor PresentationNotificationService: NativeNotificationServing {
    private var settingsValue: NotificationSystemSettings
    private var authorizationError: (any Error)?
    private let gateAuthorization: Bool
    private var authorizationContinuation: CheckedContinuation<Void, Never>?
    private var authorizationWaiter: CheckedContinuation<Void, Never>?
    private var authorizationRequested = false

    init(settings: NotificationSystemSettings, gateAuthorization: Bool) {
        settingsValue = settings
        self.gateAuthorization = gateAuthorization
    }

    func responses() -> NotificationResponseSubscription { .finished() }
    func requestAuthorization() async throws -> Bool {
        authorizationRequested = true
        authorizationWaiter?.resume()
        authorizationWaiter = nil
        if gateAuthorization {
            await withCheckedContinuation { authorizationContinuation = $0 }
        }
        if let authorizationError { throw authorizationError }
        return settingsValue.authorization == .authorized
    }
    func settings() -> NotificationSystemSettings { settingsValue }
    func deliver(
        _ event: AttentionNotificationEvent, sound: Bool
    ) -> NotificationDeliveryResult { .accepted }

    func setAuthorizationError(_ error: any Error) { authorizationError = error }
    func waitForAuthorizationRequest() async {
        guard !authorizationRequested else { return }
        await withCheckedContinuation { authorizationWaiter = $0 }
    }
    func releaseAuthorization() {
        authorizationContinuation?.resume()
        authorizationContinuation = nil
    }
}

@MainActor
private final class PresentationLoginItem: LoginItemManaging {
    var status: LoginItemStatus = .disabled
    var isChanging = false
    var errorMessage: String?
    var isEnabled: Bool { status == .enabled }
    var helpText: String? {
        status == .requiresApproval ? "Allow in System Settings" : nil
    }
    func refreshStatus() {}
    func setEnabled(_ enabled: Bool) async throws {}
}

private actor PresentationAttentionCoordinator: AttentionNotificationCoordinating {
    func reconcile(
        session: SessionDescriptor,
        items: [AgentMenuItem],
        policy: NotificationDeliveryPolicy
    ) {}
    func unavailable(sessionID: SessionID) {}
    func remove(sessionID: SessionID) {}
    func reset() {}
}

@MainActor
private final class PresentationTerminalActivator: TerminalActivating {
    func activate(bundleIdentifier: String) async throws {}
}

@MainActor
private final class PresentationWezTermFocuser: WezTermSessionFocusing {
    func focusAttachedClient(sessionID: SessionID) async throws {}
    func forget(sessionID: SessionID) {}
}
