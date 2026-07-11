import AppKit
import SwiftUI

struct StatusMenu: View {
    let store: AgentStore

    var body: some View {
        if !store.attentionItems.isEmpty {
            sectionLabel("Needs Attention")
            ForEach(store.attentionItems) { item in
                AgentRow(item: item) {
                    Task { await store.select(item) }
                }
            }
            Divider()
        }

        if !store.workingItems.isEmpty {
            sectionLabel("Working")
            ForEach(store.workingItems) { item in
                AgentRow(item: item, quieter: true) {
                    Task { await store.select(item) }
                }
            }
            Divider()
        }

        connectionStatus

        if let error = store.transientError {
            Text(error)
                .foregroundStyle(.red)
        }

        if case .disconnected = store.connectionState {
            Button("Retry") {
                Task { await store.retry() }
            }
        }

        Divider()
        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        switch store.connectionState {
        case .connected:
            if store.attentionItems.isEmpty, store.workingItems.isEmpty {
                Text("No active agents")
                    .foregroundStyle(.secondary)
            }
        case .disconnected(let message):
            Text("Disconnected")
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
