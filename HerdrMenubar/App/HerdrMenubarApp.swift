import AppKit
import SwiftUI

@MainActor
final class HerdrAppDelegate: NSObject, NSApplicationDelegate {
    var store: AgentStore?
    var loginItemService: LoginItemService?

    func applicationDidBecomeActive(_ notification: Notification) {
        loginItemService?.refreshStatus()
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
    private let installedTerminals: [TerminalApp]

    init() {
        let discovery = SessionDiscovery()
        let supervisor = SessionSupervisor(
            discovery: discovery,
            clientFactory: LiveSessionClientFactory()
        )
        let preferences = Preferences()
        _preferences = State(initialValue: preferences)
        _loginItemService = State(initialValue: LoginItemService())
        _store = State(initialValue: AgentStore(
            supervisor: supervisor,
            terminalActivator: TerminalActivationService(),
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
                loginItemService: loginItemService
            )
        } label: {
            MenuBarIcon(
                connectionState: store.connectionState,
                attentionCount: store.attentionCount
            )
            .task {
                appDelegate.store = store
                appDelegate.loginItemService = loginItemService
                loginItemService.refreshStatus()
                if Self.shouldStartSynchronization(environment: ProcessInfo.processInfo.environment) {
                    await store.start()
                }
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
