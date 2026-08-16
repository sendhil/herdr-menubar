import AppKit
import SwiftUI

@MainActor
final class HerdrAppDelegate: NSObject, NSApplicationDelegate {
    var store: AgentStore?
    var loginItemService: LoginItemService?
    var notificationSettings: NotificationSettingsController?

    func applicationDidBecomeActive(_ notification: Notification) {
        loginItemService?.refreshStatus()
        Task { await notificationSettings?.refreshStatus() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        Task {
            await store.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct HerdrMenubarApp: App {
    @NSApplicationDelegateAdaptor(HerdrAppDelegate.self) private var appDelegate
    @State private var store: AgentStore
    @State private var preferences: Preferences
    @State private var loginItemService: LoginItemService
    @State private var notificationSettings: NotificationSettingsController
    private let installedTerminals: [TerminalApp]

    init() {
        let supervisor = SessionSupervisor(
            discovery: SessionDiscovery(),
            clientFactory: LiveSessionClientFactory()
        )
        let processRunner = BoundedProcessRunner()
        let wezTermCLI = LiveWezTermCLI(runner: processRunner)
        let wezTermFocuser = LiveWezTermFocusAdapter(
            supervisor: supervisor,
            cli: wezTermCLI
        )
        let preferences = Preferences()
        let notificationService = NativeNotificationService()
        let attentionCoordinator = AttentionNotificationCoordinator(service: notificationService)
        let notificationSettings = NotificationSettingsController(
            service: notificationService,
            preferences: preferences
        )
        _preferences = State(initialValue: preferences)
        _loginItemService = State(initialValue: LoginItemService())
        _notificationSettings = State(initialValue: notificationSettings)
        _store = State(initialValue: AgentStore(
            supervisor: supervisor,
            terminalActivator: TerminalActivationService(),
            wezTermFocuser: wezTermFocuser,
            attentionCoordinator: attentionCoordinator,
            notificationService: notificationService,
            preferences: preferences
        ))
        installedTerminals = TerminalCatalog().installedTerminals()
    }

    static func shouldStartSynchronization(environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] == nil
    }

    var body: some Scene {
        MenuBarExtra {
            StatusMenu(
                store: store,
                preferences: preferences,
                installedTerminals: installedTerminals,
                loginItemService: loginItemService,
                notificationSettings: notificationSettings
            )
        } label: {
            MenuBarIcon(
                connectionState: store.connectionState,
                attentionCount: store.attentionCount
            )
            .task {
                appDelegate.store = store
                appDelegate.loginItemService = loginItemService
                appDelegate.notificationSettings = notificationSettings
                loginItemService.refreshStatus()
                await notificationSettings.refreshStatus()
                if Self.shouldStartSynchronization(environment: ProcessInfo.processInfo.environment) {
                    await store.start()
                }
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
