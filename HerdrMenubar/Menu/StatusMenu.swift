import AppKit
import SwiftUI

struct StatusMenu: View {
    let store: AgentStore
    let preferences: Preferences
    let installedTerminals: [TerminalApp]
    let loginItemService: LoginItemService

    var body: some View {
        if !store.attentionSections.isEmpty {
            sectionLabel("Needs Attention")
            ForEach(store.attentionSections) { section in
                sessionLabel(section.session.displayName)
                ForEach(section.items) { item in
                    AgentRow(item: item) {
                        Task { await store.select(item) }
                    }
                }
            }
            Divider()
        }

        if !store.workingSections.isEmpty {
            sectionLabel("Working")
            ForEach(store.workingSections) { section in
                sessionLabel(section.session.displayName)
                ForEach(section.items) { item in
                    AgentRow(item: item, quieter: true) {
                        Task { await store.select(item) }
                    }
                }
            }
            Divider()
        }

        connectionStatus

        if !store.unavailableSessions.isEmpty {
            sectionLabel("Reconnecting")
            ForEach(store.unavailableSessions) { unavailable in
                Text(unavailable.session.displayName)
                    .foregroundStyle(.secondary)
            }
        }

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

        if !store.unavailableSessions.isEmpty {
            Button("Retry Unavailable Sessions") {
                Task { await store.retry() }
            }
        }

        Divider()
        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .onAppear {
            loginItemService.refreshStatus()
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
            try await Self.updateLoginIntent(
                enabled: enabled,
                service: loginItemService,
                preferences: preferences
            )
        } catch {
            // LoginItemService presents failures; busy means no operation occurred.
        }
    }

    @MainActor
    static func updateLoginIntent(
        enabled: Bool,
        service: LoginItemService,
        preferences: Preferences
    ) async throws {
        try await service.setEnabled(enabled)
        if enabled && (service.status == .enabled || service.status == .requiresApproval) {
            preferences.launchAtLoginIntent = true
        } else if !enabled, service.status == .disabled {
            preferences.launchAtLoginIntent = false
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
        case .searching:
            Text("Searching for Herdr sessions…")
                .foregroundStyle(.secondary)
        case .noSessions:
            Text("No Herdr sessions running")
                .foregroundStyle(.secondary)
        case .connecting:
            Text("Connecting to Herdr sessions…")
                .foregroundStyle(.secondary)
        case .connected:
            if store.attentionSections.isEmpty, store.workingSections.isEmpty {
                Text("No active agents")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func sessionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption)
            .foregroundStyle(.secondary)
            .opacity(0.8)
    }
}
