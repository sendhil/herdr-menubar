import AppKit
import SwiftUI

struct StatusMenu: View {
    let store: AgentStore
    let preferences: Preferences
    let installedTerminals: [TerminalApp]
    let loginItemService: LoginItemService

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

        terminalPicker

        Toggle("Launch at Login", isOn: Binding(
            get: { loginItemService.isEnabled },
            set: { enabled in
                Task { await updateLoginItem(enabled: enabled) }
            }
        ))
        .disabled(loginItemService.isChanging || loginItemService.status == .unavailable)

        if let helpText = loginItemService.helpText {
            Text(helpText)
                .foregroundStyle(.secondary)
        }
        if let error = loginItemService.errorMessage {
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

    private var terminalPicker: some View {
        Picker("Terminal", selection: Binding(
            get: { preferences.selectedTerminalBundleIdentifier },
            set: { preferences.selectedTerminalBundleIdentifier = $0 }
        )) {
            if !installedTerminals.contains(where: {
                $0.bundleIdentifier == preferences.selectedTerminalBundleIdentifier
            }) {
                Text("\(savedTerminalName) (Unavailable)")
                    .tag(preferences.selectedTerminalBundleIdentifier)
                    .disabled(true)
            }
            ForEach(installedTerminals) { terminal in
                Text(terminal.name)
                    .tag(terminal.bundleIdentifier)
            }
        }
    }

    @MainActor
    private func updateLoginItem(enabled: Bool) async {
        do {
            try await loginItemService.setEnabled(enabled)
            if enabled {
                if loginItemService.status == .enabled || loginItemService.status == .requiresApproval {
                    preferences.launchAtLoginIntent = true
                }
            } else if loginItemService.status == .disabled {
                preferences.launchAtLoginIntent = false
            }
        } catch {
            // LoginItemService retains and presents the concise operation error.
        }
    }

    private var savedTerminalName: String {
        TerminalCatalog.knownTerminals.first {
            $0.bundleIdentifier == preferences.selectedTerminalBundleIdentifier
        }?.name ?? preferences.selectedTerminalBundleIdentifier
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
