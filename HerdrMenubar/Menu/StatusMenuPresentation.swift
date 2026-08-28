import Foundation

struct StatusItemPresentation: Equatable, Sendable {
    let icon: MenuBarIconPresentation
    let accessibilityValue: String
    let menu: [StatusMenuNode]
}

enum MenuTextTone: Equatable, Sendable {
    case secondary
    case error
}

indirect enum StatusMenuNode: Equatable, Sendable {
    case heading(String)
    case agent(
        title: String,
        subtitle: String,
        symbol: String,
        quieter: Bool,
        target: NotificationSelectionTarget
    )
    case info(String, tone: MenuTextTone)
    case toggle(
        title: String,
        isOn: Bool,
        isEnabled: Bool,
        action: StatusMenuAction
    )
    case submenu(title: String, children: [StatusMenuNode])
    case action(
        title: String,
        state: MenuItemState,
        isEnabled: Bool,
        action: StatusMenuAction
    )
    case separator
}

enum MenuItemState: Equatable, Sendable {
    case off
    case on
    case mixed
}

enum StatusMenuAction: Equatable, Sendable {
    case select(NotificationSelectionTarget)
    case selectTerminal(String)
    case setLaunchAtLogin(Bool)
    case setNotifications(Bool)
    case setSound(Bool)
    case retryUnavailable
    case openKeyboardShortcuts
    case quit
}

@MainActor
struct StatusMenuPresentationBuilder {
    func make(
        store: AgentStore,
        preferences: Preferences,
        terminals: [TerminalApp],
        loginItem: any LoginItemManaging,
        notifications: NotificationSettingsController
    ) -> StatusItemPresentation {
        StatusItemPresentation(
            icon: MenuBarIconPresentation(
                connectionState: store.connectionState,
                attentionCount: store.attentionCount
            ),
            accessibilityValue: MenuBarIcon.accessibilityValue(
                connectionState: store.connectionState,
                attentionCount: store.attentionCount
            ),
            menu: makeMenu(
                store: store,
                preferences: preferences,
                terminals: terminals,
                loginItem: loginItem,
                notifications: notifications
            )
        )
    }
}

@MainActor
private extension StatusMenuPresentationBuilder {
    func makeMenu(
        store: AgentStore,
        preferences: Preferences,
        terminals: [TerminalApp],
        loginItem: any LoginItemManaging,
        notifications: NotificationSettingsController
    ) -> [StatusMenuNode] {
        var nodes: [StatusMenuNode] = []

        appendAgentSections(
            store.attentionSections,
            heading: "NEEDS ATTENTION",
            quieter: false,
            to: &nodes
        )
        appendAgentSections(
            store.workingSections,
            heading: "WORKING",
            quieter: true,
            to: &nodes
        )

        if let connectionNode = connectionNode(
            state: store.connectionState,
            hasPresentedAgents: !store.attentionSections.isEmpty || !store.workingSections.isEmpty
        ) {
            nodes.append(connectionNode)
        }

        if !store.unavailableSessions.isEmpty {
            nodes.append(.heading("RECONNECTING"))
            nodes.append(contentsOf: store.unavailableSessions.map {
                .info($0.session.displayName, tone: .secondary)
            })
        }

        if let error = store.transientError {
            nodes.append(.info(error, tone: .error))
        }

        nodes.append(terminalNode(preferences: preferences, terminals: terminals))
        nodes.append(.toggle(
            title: "Launch at Login",
            isOn: loginItem.isEnabled,
            isEnabled: !loginItem.isChanging && loginItem.status != .unavailable,
            action: .setLaunchAtLogin(!loginItem.isEnabled)
        ))
        appendMessages(
            help: loginItem.helpText,
            error: loginItem.errorMessage,
            to: &nodes
        )

        nodes.append(.heading("NOTIFICATIONS"))
        nodes.append(.toggle(
            title: "Notifications",
            isOn: notifications.isEnabled,
            isEnabled: !notifications.isChanging,
            action: .setNotifications(!notifications.isEnabled)
        ))
        nodes.append(.toggle(
            title: "Sound",
            isOn: notifications.isSoundEnabled,
            isEnabled: notifications.canEnableSound,
            action: .setSound(!notifications.isSoundEnabled)
        ))
        appendMessages(
            help: notifications.helpText,
            error: notifications.errorMessage,
            to: &nodes
        )

        if !store.unavailableSessions.isEmpty {
            nodes.append(.action(
                title: "Retry Unavailable Sessions",
                state: .off,
                isEnabled: true,
                action: .retryUnavailable
            ))
        }

        nodes.append(.action(
            title: "Keyboard Shortcuts…",
            state: .off,
            isEnabled: true,
            action: .openKeyboardShortcuts
        ))
        nodes.append(.separator)
        nodes.append(.action(title: "Quit", state: .off, isEnabled: true, action: .quit))
        return nodes
    }

    func appendAgentSections(
        _ sections: [SessionMenuSection],
        heading: String,
        quieter: Bool,
        to nodes: inout [StatusMenuNode]
    ) {
        guard !sections.isEmpty else { return }
        nodes.append(.heading(heading))
        for section in sections {
            nodes.append(.heading(section.session.displayName.uppercased()))
            nodes.append(contentsOf: section.items.map { item in
                .agent(
                    title: item.visibleLabel,
                    subtitle: item.secondaryLabel,
                    symbol: statusSymbol(item.status),
                    quieter: quieter,
                    target: NotificationSelectionTarget(
                        sessionID: item.sessionID,
                        paneID: item.paneID
                    )
                )
            })
        }
        nodes.append(.separator)
    }

    func connectionNode(
        state: ConnectionState,
        hasPresentedAgents: Bool
    ) -> StatusMenuNode? {
        switch state {
        case .searching:
            return .info("Searching for Herdr sessions…", tone: .secondary)
        case .noSessions:
            return .info("No Herdr sessions running", tone: .secondary)
        case .connecting:
            return .info("Connecting to Herdr sessions…", tone: .secondary)
        case .connected where !hasPresentedAgents:
            return .info("No active agents", tone: .secondary)
        case .connected:
            return nil
        }
    }

    func terminalNode(
        preferences: Preferences,
        terminals: [TerminalApp]
    ) -> StatusMenuNode {
        let selectedIdentifier = preferences.selectedTerminalBundleIdentifier
        var children: [StatusMenuNode] = []
        if !terminals.contains(where: { $0.bundleIdentifier == selectedIdentifier }) {
            let savedName = TerminalCatalog.knownTerminals.first {
                $0.bundleIdentifier == selectedIdentifier
            }?.name ?? selectedIdentifier
            children.append(.action(
                title: "\(savedName) (Unavailable)",
                state: .on,
                isEnabled: false,
                action: .selectTerminal(selectedIdentifier)
            ))
        }
        children.append(contentsOf: terminals.map { terminal in
            .action(
                title: terminal.name,
                state: terminal.bundleIdentifier == selectedIdentifier ? .on : .off,
                isEnabled: true,
                action: .selectTerminal(terminal.bundleIdentifier)
            )
        })
        return .submenu(title: "Terminal", children: children)
    }

    func appendMessages(
        help: String?,
        error: String?,
        to nodes: inout [StatusMenuNode]
    ) {
        if let help { nodes.append(.info(help, tone: .secondary)) }
        if let error { nodes.append(.info(error, tone: .error)) }
    }

    func statusSymbol(_ status: AgentStatus) -> String {
        switch status {
        case .blocked:
            "exclamationmark.triangle.fill"
        case .done:
            "checkmark.circle.fill"
        case .working:
            "ellipsis.circle"
        default:
            "circle"
        }
    }
}
