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
        target: SelectionTarget
    )
    case info(String, tone: MenuTextTone, toolTip: String? = nil)
    case toggle(
        title: String,
        isOn: Bool,
        isEnabled: Bool,
        action: StatusMenuAction
    )
    /// `state` marks the parent item: on (checkmark), mixed (dash), or off (nothing).
    case submenu(title: String, state: MenuItemState = .off, children: [StatusMenuNode])
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
    case select(SelectionTarget)
    case selectTerminal(String)
    case setLaunchAtLogin(Bool)
    case setNotifications(Bool)
    case setSound(Bool)
    /// Turns one notification state on or off for a backend.
    case setNotifyState(BackendKind, AttentionState, Bool)
    case retryUnavailable
    case clearFinished
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
        let wording = store.wording
        return StatusItemPresentation(
            icon: MenuBarIconPresentation(
                connectionState: store.connectionState,
                attentionCount: store.attentionCount,
                wording: wording
            ),
            accessibilityValue: MenuBarIcon.accessibilityValue(
                connectionState: store.connectionState,
                attentionCount: store.attentionCount,
                wording: wording
            ),
            menu: makeMenu(
                store: store,
                preferences: preferences,
                terminals: terminals,
                loginItem: loginItem,
                notifications: notifications,
                wording: wording
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
        notifications: NotificationSettingsController,
        wording: AgentWording
    ) -> [StatusMenuNode] {
        var nodes: [StatusMenuNode] = []

        let showsBackendPrefix = store.showsBackendPrefix
        let clearItem = clearFinishedNode(store.clearable)
        appendAgentSections(
            store.attentionSections,
            heading: "NEEDS ATTENTION",
            quieter: false,
            showsBackendPrefix: showsBackendPrefix,
            trailing: clearItem,
            to: &nodes
        )
        appendAgentSections(
            store.workingSections,
            heading: "WORKING",
            quieter: true,
            showsBackendPrefix: showsBackendPrefix,
            trailing: store.attentionSections.isEmpty ? clearItem : nil,
            to: &nodes
        )

        if let connectionNode = connectionNode(
            state: store.connectionState,
            hasPresentedAgents: !store.attentionSections.isEmpty || !store.workingSections.isEmpty,
            wording: wording
        ) {
            nodes.append(connectionNode)
        }

        let unavailableSessions = store.unavailableSessions
        let unavailableBackends = store.reconnectingBackends
        if !unavailableSessions.isEmpty || !unavailableBackends.isEmpty {
            nodes.append(.heading("RECONNECTING"))
            nodes.append(contentsOf: unavailableSessions.map {
                .info($0.session.displayName, tone: .secondary)
            })
            nodes.append(contentsOf: unavailableBackends.map {
                .info($0.kind.displayName, tone: .secondary, toolTip: $0.reason)
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
        nodes.append(contentsOf: notifyStateNodes(store: store, preferences: preferences, notifications: notifications))
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

        if !unavailableSessions.isEmpty || !unavailableBackends.isEmpty {
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

    /// Per-backend notification states, between Notifications and Sound. Herdr's submenu shows
    /// whenever Herdr is enabled; Rex's only when Rex is enabled and has been active in this run
    /// (emitted `.discovery`) or `notifyStates.rex` is stored, so a Rex that is absent, or
    /// installed but never running, adds nothing.
    func notifyStateNodes(
        store: AgentStore,
        preferences: Preferences,
        notifications: NotificationSettingsController
    ) -> [StatusMenuNode] {
        let enabled = preferences.enabledBackends
        var nodes: [StatusMenuNode] = []
        if enabled.contains(.herdr) {
            nodes.append(notifyStateSubmenu(.herdr, states: [("Blocked", .blocked), ("Finished", .done)],
                                            notifications: notifications))
        }
        if enabled.contains(.rex),
           store.everActiveBackends.contains(.rex) || preferences.hasStoredNotifyStates(for: .rex) {
            nodes.append(notifyStateSubmenu(.rex, states: [("Blocked", .blocked), ("Failed", .error), ("Finished", .done)],
                                            notifications: notifications))
        }
        return nodes
    }

    func notifyStateSubmenu(
        _ kind: BackendKind,
        states: [(title: String, state: AttentionState)],
        notifications: NotificationSettingsController
    ) -> StatusMenuNode {
        let selected = notifications.notifyStates(for: kind)
        let onCount = states.filter { selected.contains($0.state) }.count
        let parentState: MenuItemState = onCount == states.count ? .on : (onCount == 0 ? .off : .mixed)
        return .submenu(
            title: "\(kind.displayName) Agents",
            state: parentState,
            children: states.map { item in
                let isOn = selected.contains(item.state)
                return .toggle(title: item.title, isOn: isOn, isEnabled: true,
                               action: .setNotifyState(kind, item.state, !isOn))
            }
        )
    }

    /// Clear Finished is shown when it would dismiss something (the backends' `clearable`: an
    /// unseen done or settled error record), at the end of NEEDS ATTENTION, or of WORKING when
    /// there is no NEEDS ATTENTION. "and Failed" only when a settled error would be cleared.
    /// Herdr never reports anything clearable.
    func clearFinishedNode(_ clearable: ClearableRecords) -> StatusMenuNode? {
        guard !clearable.isEmpty else { return nil }
        return .action(
            title: clearable.error ? "Clear Finished and Failed" : "Clear Finished",
            state: .off,
            isEnabled: true,
            action: .clearFinished
        )
    }

    func appendAgentSections(
        _ sections: [SessionMenuSection],
        heading: String,
        quieter: Bool,
        showsBackendPrefix: Bool,
        trailing: StatusMenuNode? = nil,
        to nodes: inout [StatusMenuNode]
    ) {
        guard !sections.isEmpty else { return }
        nodes.append(.heading(heading))
        for section in sections {
            let name = showsBackendPrefix
                ? "\(section.session.key.backend.displayName) · \(section.session.displayName)"
                : section.session.displayName
            nodes.append(.heading(name.uppercased()))
            nodes.append(contentsOf: section.items.map { row in
                .agent(
                    title: row.visibleLabel,
                    subtitle: row.subtitle,
                    symbol: statusSymbol(row.state),
                    quieter: quieter,
                    target: SelectionTarget(target: row.target, sessionDisplayName: section.session.displayName)
                )
            })
        }
        if let trailing { nodes.append(trailing) }
        nodes.append(.separator)
    }

    func connectionNode(
        state: ConnectionState,
        hasPresentedAgents: Bool,
        wording: AgentWording
    ) -> StatusMenuNode? {
        switch state {
        case .searching:
            return .info("Searching for \(wording.sessionsNoun)…", tone: .secondary)
        case .noSessions:
            return .info("No \(wording.sessionsNoun) running", tone: .secondary)
        case .connecting:
            return .info("Connecting to \(wording.sessionsNoun)…", tone: .secondary)
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

    func statusSymbol(_ state: RowState) -> String {
        switch state {
        case .attention(.blocked):
            "exclamationmark.triangle.fill"
        case .attention(.error):
            "xmark.octagon"
        case .attention(.done):
            "checkmark.circle.fill"
        case .working:
            "ellipsis.circle"
        }
    }
}
