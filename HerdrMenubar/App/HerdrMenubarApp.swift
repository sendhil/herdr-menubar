import AppKit
import SwiftUI

@MainActor
final class HerdrAppDelegate: NSObject, NSApplicationDelegate {
    var store: AgentStore?

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

    init() {
        let client = HerdrClient()
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
                appDelegate.store = store
                await store.start()
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
