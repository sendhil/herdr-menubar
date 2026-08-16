import Foundation
import Observation
import OSLog

enum ConnectionState: Equatable, Sendable {
    case searching
    case noSessions
    case connecting
    case connected
}

struct AgentMenuItemID: Hashable, Sendable {
    let sessionID: SessionID
    let paneID: String
}

struct AgentMenuItem: Identifiable, Equatable, Sendable {
    let sessionID: SessionID
    let sessionName: String
    let paneID: String
    let displayLabel: String
    let agentLabel: String
    let status: AgentStatus

    var id: AgentMenuItemID { AgentMenuItemID(sessionID: sessionID, paneID: paneID) }

    init(
        session: SessionDescriptor,
        pane: PaneInfo,
        workspace: WorkspaceInfo? = nil,
        tab: TabInfo? = nil,
        workspaceIsMultiTab: Bool = false
    ) {
        sessionID = session.id
        sessionName = session.displayName
        paneID = pane.paneID
        if let workspace, !workspace.label.isEmpty {
            if workspaceIsMultiTab, let tab, !tab.label.isEmpty {
                displayLabel = "\(workspace.label) · \(tab.label)"
            } else {
                displayLabel = workspace.label
            }
        } else {
            displayLabel = pane.displayLabel
        }
        agentLabel = pane.agentLabel
        status = pane.agentStatus
    }

    var visibleLabel: String {
        displayLabel == agentLabel ? displayLabel : "\(displayLabel) · \(agentLabel)"
    }

    var secondaryLabel: String { "\(status.rawValue) · \(agentLabel)" }

    static func attentionOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        let lhsRank = lhs.status == .blocked ? 0 : 1
        let rhsRank = rhs.status == .blocked ? 0 : 1
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return labelOrder(lhs, rhs)
    }

    static func labelOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        let locale = Locale(identifier: "en_US_POSIX")
        let lhsLabel = lhs.displayLabel.folding(options: [.caseInsensitive], locale: locale)
        let rhsLabel = rhs.displayLabel.folding(options: [.caseInsensitive], locale: locale)
        if lhsLabel != rhsLabel { return lhsLabel < rhsLabel }
        return lhs.paneID < rhs.paneID
    }
}

struct SessionMenuSection: Identifiable, Equatable, Sendable {
    let session: SessionDescriptor
    let items: [AgentMenuItem]
    var id: SessionID { session.id }
}

struct UnavailableSession: Identifiable, Equatable, Sendable {
    let session: SessionDescriptor
    let message: String
    var id: SessionID { session.id }
}

private struct SessionPresentationState {
    var descriptor: SessionDescriptor
    var isConnected = false
    var unavailableMessage: String?
    var attentionItems: [AgentMenuItem] = []
    var workingItems: [AgentMenuItem] = []
}

@Observable @MainActor
final class AgentStore {
    private let supervisor: any SessionSupervising
    private let terminalActivator: any TerminalActivating
    private let preferences: Preferences
    private var eventTask: Task<Void, Never>?
    private var eventGeneration = UUID()
    private var isRunning = false
    private var hasCompletedDiscovery = false
    private var sessions: [SessionID: SessionPresentationState] = [:]

    private(set) var connectionState: ConnectionState = .searching
    private(set) var transientError: String?

    var attentionSections: [SessionMenuSection] {
        sections(keyPath: \.attentionItems)
    }

    var workingSections: [SessionMenuSection] {
        sections(keyPath: \.workingItems)
    }

    var unavailableSessions: [UnavailableSession] {
        sessions.values.compactMap { state in
            state.unavailableMessage.map { UnavailableSession(session: state.descriptor, message: $0) }
        }
        .sorted { Self.sessionOrder($0.session, $1.session) }
    }

    var attentionCount: Int {
        sessions.values.reduce(into: 0) { $0 += $1.attentionItems.count }
    }

    init(
        supervisor: any SessionSupervising,
        terminalActivator: any TerminalActivating,
        preferences: Preferences = Preferences()
    ) {
        self.supervisor = supervisor
        self.terminalActivator = terminalActivator
        self.preferences = preferences
    }

    func start() async {
        guard !isRunning else { return }
        isRunning = true
        let generation = UUID()
        eventGeneration = generation
        let events = await supervisor.events()
        eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.consume(event, generation: generation)
            }
        }
        await supervisor.start()
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        eventGeneration = UUID()
        let task = eventTask
        eventTask = nil
        task?.cancel()
        await task?.value
        await supervisor.stop()
        hasCompletedDiscovery = false
        sessions.removeAll()
        connectionState = .searching
    }

    func retry() async {
        transientError = nil
        await supervisor.retryUnavailable()
    }

    func select(_ item: AgentMenuItem) async {
        transientError = nil
        do {
            _ = try await supervisor.focus(sessionID: item.sessionID, paneID: item.paneID)
        } catch {
            AppLog.systemActions.error("Pane focus failed in \(item.sessionName, privacy: .public): \(error.localizedDescription, privacy: .private)")
            transientError = "Could not focus pane in \(item.sessionName): \(error.localizedDescription)"
            return
        }

        do {
            try await terminalActivator.activate(
                bundleIdentifier: preferences.selectedTerminalBundleIdentifier
            )
        } catch {
            AppLog.systemActions.error("Terminal activation failed: \(error.localizedDescription, privacy: .private)")
            transientError = error.localizedDescription
        }
        await supervisor.refresh(sessionID: item.sessionID)
    }
}

private extension AgentStore {
    func consume(_ event: SessionSupervisorEvent, generation: UUID) {
        guard isRunning, eventGeneration == generation else { return }
        switch event {
        case .discoverySnapshot(let descriptors):
            hasCompletedDiscovery = true
            for descriptor in descriptors where sessions[descriptor.id] == nil {
                sessions[descriptor.id] = SessionPresentationState(descriptor: descriptor)
            }
        case .connected(let descriptor, let snapshot):
            var state = sessions[descriptor.id] ?? SessionPresentationState(descriptor: descriptor)
            state.descriptor = descriptor
            state.isConnected = true
            state.unavailableMessage = nil
            (state.attentionItems, state.workingItems) = makeItems(snapshot: snapshot, session: descriptor)
            sessions[descriptor.id] = state
            transientError = nil
        case .snapshot(let id, let snapshot):
            guard var state = sessions[id], state.isConnected else { return }
            (state.attentionItems, state.workingItems) = makeItems(snapshot: snapshot, session: state.descriptor)
            sessions[id] = state
        case .unavailable(let id, let message):
            guard var state = sessions[id] else { return }
            state.isConnected = false
            state.unavailableMessage = message
            state.attentionItems = []
            state.workingItems = []
            sessions[id] = state
        case .removed(let id):
            sessions.removeValue(forKey: id)
        }
        deriveConnectionState()
    }

    func deriveConnectionState() {
        if sessions.values.contains(where: \.isConnected) {
            connectionState = .connected
        } else if !hasCompletedDiscovery {
            connectionState = .searching
        } else if sessions.isEmpty {
            connectionState = .noSessions
        } else {
            connectionState = .connecting
        }
    }

    func makeItems(
        snapshot: PresentationSnapshot,
        session: SessionDescriptor
    ) -> (attention: [AgentMenuItem], working: [AgentMenuItem]) {
        let workspacesByID = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.workspaceID, $0) })
        let tabsByID = Dictionary(uniqueKeysWithValues: snapshot.tabs.map { ($0.tabID, $0) })
        var tabIDsByWorkspace: [String: Set<String>] = [:]
        for tab in snapshot.tabs {
            tabIDsByWorkspace[tab.workspaceID, default: []].insert(tab.tabID)
        }
        for pane in snapshot.panes {
            tabIDsByWorkspace[pane.workspaceID, default: []].insert(pane.tabID)
        }

        let items = snapshot.panes.map { pane in
            let workspace = workspacesByID[pane.workspaceID]
            let isMultiTab = (workspace?.tabCount ?? 0) > 1
                || (tabIDsByWorkspace[pane.workspaceID]?.count ?? 0) > 1
            return AgentMenuItem(
                session: session,
                pane: pane,
                workspace: workspace,
                tab: tabsByID[pane.tabID],
                workspaceIsMultiTab: isMultiTab
            )
        }
        return (
            items.filter { $0.status == .blocked || $0.status == .done }
                .sorted(by: AgentMenuItem.attentionOrder),
            items.filter { $0.status == .working }
                .sorted(by: AgentMenuItem.labelOrder)
        )
    }

    func sections(
        keyPath: KeyPath<SessionPresentationState, [AgentMenuItem]>
    ) -> [SessionMenuSection] {
        sessions.values.compactMap { state in
            let items = state[keyPath: keyPath]
            return items.isEmpty ? nil : SessionMenuSection(session: state.descriptor, items: items)
        }
        .sorted { Self.sessionOrder($0.session, $1.session) }
    }

    static func sessionOrder(_ lhs: SessionDescriptor, _ rhs: SessionDescriptor) -> Bool {
        switch (lhs.id, rhs.id) {
        case (.default, .default): return false
        case (.default, _): return true
        case (_, .default): return false
        case (.named(let lhsName), .named(let rhsName)):
            let locale = Locale(identifier: "en_US_POSIX")
            let lhsFolded = lhsName.folding(options: [.caseInsensitive], locale: locale)
            let rhsFolded = rhsName.folding(options: [.caseInsensitive], locale: locale)
            return lhsFolded == rhsFolded ? lhsName < rhsName : lhsFolded < rhsFolded
        }
    }
}
