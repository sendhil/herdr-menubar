import AppKit
import SwiftUI

@MainActor
final class HerdrAppDelegate: NSObject, NSApplicationDelegate {
    var client: HerdrClient?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let client else { return .terminateNow }
        Task {
            await client.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct HerdrMenubarApp: App {
    @NSApplicationDelegateAdaptor(HerdrAppDelegate.self) private var appDelegate
    @State private var store: AgentStore
    private let client: HerdrClient

    init() {
        let client = HerdrClient()
        self.client = client
        _store = State(initialValue: AgentStore(
            client: client,
            terminalActivator: DeferredTerminalActivator()
        ))
    }

    var body: some Scene {
        MenuBarExtra {
            StatusMenu(store: store)
        } label: {
            MenuBarIcon(
                connectionState: store.connectionState,
                attentionCount: store.attentionCount
            )
            .task {
                appDelegate.client = client
                await store.start()
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
