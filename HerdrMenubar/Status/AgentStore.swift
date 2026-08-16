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

private struct AgentSelectionTarget: Sendable {
    let sessionID: SessionID
    let paneID: String
    let sessionName: String
}

@Observable @MainActor
final class AgentStore {
    private let supervisor: any SessionSupervising
    private let terminalActivator: any TerminalActivating
    private let wezTermFocuser: any WezTermSessionFocusing
    private let attentionCoordinator: any AttentionNotificationCoordinating
    private let notificationService: any NativeNotificationServing
    private let preferences: Preferences
    private var eventTask: Task<Void, Never>?
    private var notificationResponseTask: Task<Void, Never>?
    private var notificationResponseSubscription: NotificationResponseSubscription?
    private var pendingNotificationTarget: NotificationSelectionTarget?
    private var eventGeneration = UUID()
    private var startTask: Task<Void, Never>?
    private var startToken: UUID?
    private var startCallingSupervisorToken: UUID?
    private var stopTask: Task<Void, Never>?
    private var stopToken: UUID?
    private var selectionTask: Task<Void, Never>?
    private var selectionGeneration = UUID()
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
        wezTermFocuser: any WezTermSessionFocusing,
        attentionCoordinator: any AttentionNotificationCoordinating,
        notificationService: any NativeNotificationServing,
        preferences: Preferences = Preferences()
    ) {
        self.supervisor = supervisor
        self.terminalActivator = terminalActivator
        self.wezTermFocuser = wezTermFocuser
        self.attentionCoordinator = attentionCoordinator
        self.notificationService = notificationService
        self.preferences = preferences
    }

    func start() async {
        guard !isRunning else { return }
        isRunning = true
        let generation = UUID()
        eventGeneration = generation
        let token = UUID()
        let precedingStop = stopTask
        startToken = token
        let task = Task { [weak self] in
            await precedingStop?.value
            guard let self, self.ownsStart(generation: generation, token: token) else { return }

            let events = await self.supervisor.events()
            guard self.ownsStart(generation: generation, token: token) else { return }

            let notificationResponses = await self.notificationService.responses()
            guard self.ownsStart(generation: generation, token: token) else {
                notificationResponses.cancel()
                return
            }

            self.eventTask = Task { [weak self] in
                for await event in events {
                    guard !Task.isCancelled else { return }
                    await self?.consume(event, generation: generation)
                }
            }
            self.notificationResponseSubscription = notificationResponses
            self.notificationResponseTask = Task { [weak self] in
                defer { notificationResponses.cancel() }
                for await target in notificationResponses {
                    guard !Task.isCancelled else { return }
                    await self?.receiveNotificationTarget(target, generation: generation)
                }
            }
            self.startCallingSupervisorToken = token
            await self.supervisor.start()
            guard self.ownsStart(generation: generation, token: token) else { return }
            self.startCallingSupervisorToken = nil
        }
        startTask = task
        await task.value
        if startToken == token {
            startTask = nil
            startToken = nil
            if startCallingSupervisorToken == token {
                startCallingSupervisorToken = nil
            }
        }
    }

    func stop() async {
        if !isRunning, let stopTask {
            await stopTask.value
            return
        }
        guard isRunning || startTask != nil || eventTask != nil
            || notificationResponseTask != nil || selectionTask != nil else { return }

        isRunning = false
        eventGeneration = UUID()
        selectionGeneration = UUID()
        let selection = selectionTask
        selectionTask = nil
        selection?.cancel()
        let startingSupervisor = startCallingSupervisorToken == startToken ? startTask : nil
        startTask?.cancel()
        startTask = nil
        startToken = nil
        startCallingSupervisorToken = nil

        let consumer = eventTask
        eventTask = nil
        consumer?.cancel()
        let responseConsumer = notificationResponseTask
        notificationResponseTask = nil
        let responseSubscription = notificationResponseSubscription
        notificationResponseSubscription = nil
        pendingNotificationTarget = nil
        responseSubscription?.cancel()
        responseConsumer?.cancel()
        hasCompletedDiscovery = false
        sessions.removeAll()
        connectionState = .searching

        let precedingStop = stopTask
        let token = UUID()
        let supervisor = self.supervisor
        let task = Task {
            await precedingStop?.value
            await selection?.value
            await consumer?.value
            await responseConsumer?.value
            await startingSupervisor?.value
            await attentionCoordinator.reset()
            await supervisor.stop()
        }
        stopToken = token
        stopTask = task
        await task.value
        if stopToken == token {
            stopTask = nil
            stopToken = nil
        }
    }

    func retry() async {
        transientError = nil
        await supervisor.retryUnavailable()
    }

    func select(_ item: AgentMenuItem) async {
        pendingNotificationTarget = nil
        await startSelection(AgentSelectionTarget(
            sessionID: item.sessionID,
            paneID: item.paneID,
            sessionName: item.sessionName
        ))?.value
    }
}

private extension AgentStore {
    @discardableResult
    func startSelection(_ target: AgentSelectionTarget) -> Task<Void, Never>? {
        guard stopTask == nil else { return nil }
        let generation = UUID()
        selectionGeneration = generation
        transientError = nil
        let predecessor = selectionTask
        predecessor?.cancel()
        let task = Task { [weak self] in
            await predecessor?.value
            guard let self, self.ownsSelection(generation) else { return }
            await self.performSelection(target, generation: generation)
            if self.selectionGeneration == generation {
                self.selectionTask = nil
            }
        }
        selectionTask = task
        return task
    }

    func performSelection(_ target: AgentSelectionTarget, generation: UUID) async {
        do {
            _ = try await supervisor.focus(sessionID: target.sessionID, paneID: target.paneID)
        } catch {
            AppLog.systemActions.error("Pane focus failed: \(error.localizedDescription, privacy: .private)")
            if ownsSelection(generation) {
                transientError = "Could not focus pane in \(target.sessionName): \(error.localizedDescription)"
            }
            return
        }

        guard ownsSelection(generation) else {
            await supervisor.refresh(sessionID: target.sessionID)
            return
        }

        let bundleIdentifier = preferences.selectedTerminalBundleIdentifier
        if bundleIdentifier == WezTermCLIConstants.bundleIdentifier {
            do {
                try await wezTermFocuser.focusAttachedClient(sessionID: target.sessionID)
            } catch {
                AppLog.systemActions.error("WezTerm session focus failed: \(error.localizedDescription, privacy: .private)")
                if ownsSelection(generation) {
                    transientError = wezTermFocusMessage(error, sessionName: target.sessionName)
                }
                await supervisor.refresh(sessionID: target.sessionID)
                return
            }
        }

        if ownsSelection(generation) {
            do {
                try await terminalActivator.activate(bundleIdentifier: bundleIdentifier)
            } catch {
                AppLog.systemActions.error("Terminal activation failed: \(error.localizedDescription, privacy: .private)")
                if ownsSelection(generation) {
                    transientError = error.localizedDescription
                }
            }
        }
        await supervisor.refresh(sessionID: target.sessionID)
    }

    func ownsSelection(_ generation: UUID) -> Bool {
        selectionGeneration == generation && !Task.isCancelled
    }

    func wezTermFocusMessage(_ error: any Error, sessionName: String) -> String {
        let prefix = "Focused the pane in \(sessionName), but "
        switch error as? WezTermFocusError {
        case .noAttachedClient, .lookupTimedOut:
            return prefix + "no attached WezTerm tab was found."
        case .unsupportedHerdr:
            return prefix + "this Herdr session must be updated for WezTerm tab focus."
        case .markerCleanupFailed:
            return prefix + "the temporary WezTerm focus marker could not be cleared."
        case .wezTermUnavailable, .wezTermControlFailed, .ambiguousMarker, .none:
            return prefix + "WezTerm could not be controlled."
        }
    }

    func ownsStart(generation: UUID, token: UUID) -> Bool {
        isRunning && eventGeneration == generation && startToken == token && !Task.isCancelled
    }

    func consume(_ event: SessionSupervisorEvent, generation: UUID) async {
        guard isRunning, eventGeneration == generation else { return }
        switch event {
        case .discoverySnapshot(let descriptors):
            hasCompletedDiscovery = true
            for descriptor in descriptors where sessions[descriptor.id] == nil {
                sessions[descriptor.id] = SessionPresentationState(descriptor: descriptor)
            }
            discardAbsentPendingTarget(discovered: descriptors)
        case .connected(let descriptor, let snapshot):
            var state = sessions[descriptor.id] ?? SessionPresentationState(descriptor: descriptor)
            state.descriptor = descriptor
            state.isConnected = true
            state.unavailableMessage = nil
            let allItems = makeAllItems(snapshot: snapshot, session: descriptor)
            (state.attentionItems, state.workingItems) = makePresentationItems(allItems)
            sessions[descriptor.id] = state
            transientError = nil
            await attentionCoordinator.reconcile(
                session: descriptor,
                items: allItems,
                policy: notificationPolicy
            )
            if let pendingNotificationTarget,
               pendingNotificationTarget.sessionID == descriptor.id {
                receiveNotificationTarget(pendingNotificationTarget, generation: generation)
            }
        case .snapshot(let id, let snapshot):
            guard var state = sessions[id], state.isConnected else { return }
            let allItems = makeAllItems(snapshot: snapshot, session: state.descriptor)
            (state.attentionItems, state.workingItems) = makePresentationItems(allItems)
            sessions[id] = state
            await attentionCoordinator.reconcile(
                session: state.descriptor,
                items: allItems,
                policy: notificationPolicy
            )
        case .unavailable(let id, let message):
            guard var state = sessions[id] else { return }
            state.isConnected = false
            state.unavailableMessage = message
            state.attentionItems = []
            state.workingItems = []
            sessions[id] = state
            await attentionCoordinator.unavailable(sessionID: id)
        case .removed(let id):
            let removedState = sessions.removeValue(forKey: id)
            if pendingNotificationTarget?.sessionID == id {
                pendingNotificationTarget = nil
                transientError = "\(id.displayName) is unavailable"
            }
            guard removedState != nil else { return }
            wezTermFocuser.forget(sessionID: id)
            await attentionCoordinator.remove(sessionID: id)
        }
        deriveConnectionState()
    }

    var notificationPolicy: NotificationDeliveryPolicy {
        NotificationDeliveryPolicy(
            notificationsEnabled: preferences.notificationsEnabled,
            soundEnabled: preferences.notificationSoundEnabled
        )
    }

    func receiveNotificationTarget(
        _ target: NotificationSelectionTarget,
        generation: UUID
    ) {
        guard isRunning, eventGeneration == generation else { return }
        supersedeSelection()
        guard let state = sessions[target.sessionID] else {
            if hasCompletedDiscovery {
                pendingNotificationTarget = nil
                transientError = "\(target.sessionID.displayName) is unavailable"
            } else {
                pendingNotificationTarget = target
            }
            return
        }
        guard state.isConnected else {
            pendingNotificationTarget = target
            return
        }
        pendingNotificationTarget = nil
        startSelection(AgentSelectionTarget(
            sessionID: target.sessionID,
            paneID: target.paneID,
            sessionName: state.descriptor.displayName
        ))
    }

    func supersedeSelection() {
        selectionGeneration = UUID()
        transientError = nil
        selectionTask?.cancel()
    }

    func discardAbsentPendingTarget(discovered: [SessionDescriptor]) {
        guard let pendingNotificationTarget,
              !discovered.contains(where: { $0.id == pendingNotificationTarget.sessionID }) else {
            return
        }
        self.pendingNotificationTarget = nil
        transientError = "\(pendingNotificationTarget.sessionID.displayName) is unavailable"
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

    func makeAllItems(
        snapshot: PresentationSnapshot,
        session: SessionDescriptor
    ) -> [AgentMenuItem] {
        let workspacesByID = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.workspaceID, $0) })
        let tabsByID = Dictionary(uniqueKeysWithValues: snapshot.tabs.map { ($0.tabID, $0) })
        var tabIDsByWorkspace: [String: Set<String>] = [:]
        for tab in snapshot.tabs {
            tabIDsByWorkspace[tab.workspaceID, default: []].insert(tab.tabID)
        }
        for pane in snapshot.panes {
            tabIDsByWorkspace[pane.workspaceID, default: []].insert(pane.tabID)
        }

        return snapshot.panes.map { pane in
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
    }

    func makePresentationItems(
        _ items: [AgentMenuItem]
    ) -> (attention: [AgentMenuItem], working: [AgentMenuItem]) {
        (
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
