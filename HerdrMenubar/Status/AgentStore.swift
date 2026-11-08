import Foundation
import Observation
import OSLog

enum ConnectionState: Equatable, Sendable {
    case searching
    case noSessions
    case connecting
    case connected
}

struct SessionMenuSection: Identifiable, Equatable, Sendable {
    let session: AgentSessionDescriptor
    let items: [AgentRow]
    var id: AgentSessionKey { session.key }
}

struct UnavailableSession: Identifiable, Equatable, Sendable {
    let session: AgentSessionDescriptor
    let message: String
    var id: AgentSessionKey { session.key }
}

private struct SessionPresentationState {
    var descriptor: AgentSessionDescriptor
    var isConnected = false
    var unavailableMessage: String?
    private(set) var rows: [AgentRow] = []
    private(set) var attentionRows: [AgentRow] = []
    private(set) var finishedRows: [AgentRow] = []
    private(set) var workingRows: [AgentRow] = []

    init(descriptor: AgentSessionDescriptor) {
        self.descriptor = descriptor
    }

    /// Sections and badge come from `RowState` only.
    mutating func setRows(_ newRows: [AgentRow]) {
        rows = newRows
        attentionRows = newRows.filter(\.isAttention).sorted(by: AgentRow.attentionOrder)
        finishedRows = newRows.filter { $0.state == .finished }.sorted(by: AgentRow.labelOrder)
        workingRows = newRows.filter { $0.state == .working }.sorted(by: AgentRow.labelOrder)
    }
}

private extension AgentRow {
    var isAttention: Bool {
        if case .attention = state { return true }
        return false
    }
}

@Observable @MainActor
final class AgentStore {
    private let backends: [any AgentBackend]
    private let attentionCoordinator: any AttentionNotificationCoordinating
    private let notificationService: any NativeNotificationServing
    private let preferences: Preferences
    private var eventTasks: [Task<Void, Never>] = []
    private var notificationResponseTask: Task<Void, Never>?
    private var notificationResponseSubscription: NotificationResponseSubscription?
    private var pendingNotificationTarget: SelectionTarget?
    private var eventGeneration = UUID()
    private var startTask: Task<Void, Never>?
    private var startToken: UUID?
    private var startCallingBackendsToken: UUID?
    private var stopTask: Task<Void, Never>?
    private var stopToken: UUID?
    private var selectionTask: Task<Void, Never>?
    private var selectionGeneration = UUID()
    private var isRunning = false
    private var discoveredBackends: Set<BackendKind> = []
    private var sessions: [AgentSessionKey: SessionPresentationState] = [:]

    private(set) var connectionState: ConnectionState = .searching
    private(set) var transientError: String?

    var attentionSections: [SessionMenuSection] { sections(\.attentionRows) }
    var finishedSections: [SessionMenuSection] { sections(\.finishedRows) }
    var workingSections: [SessionMenuSection] { sections(\.workingRows) }

    var unavailableSessions: [UnavailableSession] {
        sessions.values.compactMap { state in
            state.unavailableMessage.map { UnavailableSession(session: state.descriptor, message: $0) }
        }
        .sorted { sessionOrder($0.session, $1.session) }
    }

    var attentionCount: Int {
        sessions.values.reduce(into: 0) { $0 += $1.attentionRows.count }
    }

    init(
        backends: [any AgentBackend],
        attentionCoordinator: any AttentionNotificationCoordinating,
        notificationService: any NativeNotificationServing,
        preferences: Preferences = Preferences()
    ) {
        self.backends = backends
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

            var streams: [(BackendKind, AsyncStream<BackendEvent>)] = []
            for backend in self.backends {
                let events = await backend.events()
                guard self.ownsStart(generation: generation, token: token) else { return }
                streams.append((backend.kind, events))
            }

            let notificationResponses = await self.notificationService.responses()
            guard self.ownsStart(generation: generation, token: token) else {
                notificationResponses.cancel()
                return
            }

            for (kind, events) in streams {
                self.eventTasks.append(Task { [weak self] in
                    for await event in events {
                        guard !Task.isCancelled else { return }
                        await self?.consume(event, from: kind, generation: generation)
                    }
                })
            }
            self.notificationResponseSubscription = notificationResponses
            self.notificationResponseTask = Task { [weak self] in
                defer { notificationResponses.cancel() }
                for await target in notificationResponses {
                    guard !Task.isCancelled else { return }
                    self?.select(target)
                }
            }
            self.startCallingBackendsToken = token
            for backend in self.backends {
                await backend.start()
                guard self.ownsStart(generation: generation, token: token) else { return }
            }
            self.startCallingBackendsToken = nil
        }
        startTask = task
        await task.value
        if startToken == token {
            startTask = nil
            startToken = nil
            if startCallingBackendsToken == token {
                startCallingBackendsToken = nil
            }
        }
    }

    func stop() async {
        if !isRunning, let stopTask {
            await stopTask.value
            return
        }
        guard isRunning || startTask != nil || !eventTasks.isEmpty
            || notificationResponseTask != nil || selectionTask != nil else { return }

        isRunning = false
        eventGeneration = UUID()
        selectionGeneration = UUID()
        let selection = selectionTask
        selectionTask = nil
        selection?.cancel()
        let startingBackends = startCallingBackendsToken == startToken ? startTask : nil
        startTask?.cancel()
        startTask = nil
        startToken = nil
        startCallingBackendsToken = nil

        let consumers = eventTasks
        eventTasks = []
        consumers.forEach { $0.cancel() }
        let responseConsumer = notificationResponseTask
        notificationResponseTask = nil
        let responseSubscription = notificationResponseSubscription
        notificationResponseSubscription = nil
        pendingNotificationTarget = nil
        responseSubscription?.cancel()
        responseConsumer?.cancel()
        discoveredBackends.removeAll()
        sessions.removeAll()
        connectionState = .searching
        transientError = nil

        let precedingStop = stopTask
        let token = UUID()
        let backends = self.backends
        let coordinator = attentionCoordinator
        let task = Task {
            await precedingStop?.value
            await selection?.value
            for consumer in consumers { await consumer.value }
            await responseConsumer?.value
            await startingBackends?.value
            await coordinator.reset()
            for backend in backends { await backend.stop() }
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
        let enabled = preferences.enabledBackends
        let targets = backends.filter { enabled.contains($0.kind) }
        await withTaskGroup(of: Void.self) { group in
            for backend in targets {
                group.addTask { await backend.retryUnavailable() }
            }
        }
    }

    /// A menu row was chosen.
    func selectRow(_ target: SelectionTarget) async {
        pendingNotificationTarget = nil
        await startSelection(target)?.value
    }

    /// A notification click, the latest-notification shortcut, or a menu action.
    func select(_ target: SelectionTarget) {
        guard isRunning else { return }
        receiveNotificationTarget(target, generation: eventGeneration)
    }
}

private extension AgentStore {
    func backend(for kind: BackendKind) -> (any AgentBackend)? {
        backends.first { $0.kind == kind }
    }

    @discardableResult
    func startSelection(_ target: SelectionTarget) -> Task<Void, Never>? {
        guard stopTask == nil else { return nil }
        guard let backend = backend(for: target.target.session.backend) else { return nil }
        // Step 0: capture the token from the store's own row cache for every selection source.
        let seenToken = sessions[target.target.session]?.rows.first { $0.target == target.target }?.seenToken
        let generation = UUID()
        selectionGeneration = generation
        transientError = nil
        let predecessor = selectionTask
        predecessor?.cancel()
        let task = Task { [weak self] in
            await predecessor?.value
            guard let self, self.ownsSelection(generation) else { return }
            await self.performSelection(target, backend: backend, seenToken: seenToken, generation: generation)
            if self.selectionGeneration == generation {
                self.selectionTask = nil
            }
        }
        selectionTask = task
        return task
    }

    func performSelection(
        _ target: SelectionTarget,
        backend: any AgentBackend,
        seenToken: SeenToken?,
        generation: UUID
    ) async {
        // Step 1.
        do {
            try await backend.focusServer(target.target)
        } catch {
            AppLog.systemActions.error("Pane focus failed: \(error.localizedDescription, privacy: .private)")
            if ownsSelection(generation) {
                transientError = error.localizedDescription
            }
            if case .unavailable = error as? FocusError {
                await backend.retryUnavailable()
            }
            return
        }

        // Step 2.
        guard ownsSelection(generation) else {
            await backend.refreshAfterSelection(target.target)
            return
        }

        // Step 3.
        let partial = await backend.activate(target.target)
        if ownsSelection(generation), let partial {
            transientError = partial
        }

        // Step 4.
        if ownsSelection(generation), partial == nil, let seenToken {
            await backend.markSeen(seenToken)
        }

        // Step 5.
        await backend.refreshAfterSelection(target.target)
    }

    func ownsSelection(_ generation: UUID) -> Bool {
        selectionGeneration == generation && !Task.isCancelled
    }

    func ownsStart(generation: UUID, token: UUID) -> Bool {
        isRunning && eventGeneration == generation && startToken == token && !Task.isCancelled
    }

    func consume(_ event: BackendEvent, from kind: BackendKind, generation: UUID) async {
        guard isRunning, eventGeneration == generation else { return }
        switch event {
        case .discovery(let descriptors):
            discoveredBackends.insert(kind)
            for descriptor in descriptors where sessions[descriptor.key] == nil {
                sessions[descriptor.key] = SessionPresentationState(descriptor: descriptor)
            }
            discardAbsentPendingTarget(kind: kind, discovered: descriptors)
        case .connected(let descriptor, let snapshot):
            var state = sessions[descriptor.key] ?? SessionPresentationState(descriptor: descriptor)
            state.descriptor = descriptor
            state.isConnected = true
            state.unavailableMessage = nil
            state.setRows(snapshot.rows)
            sessions[descriptor.key] = state
            await attentionCoordinator.reconcile(
                session: descriptor,
                records: snapshot.attention,
                policy: notificationPolicy
            )
            if let pendingNotificationTarget,
               pendingNotificationTarget.target.session == descriptor.key {
                receiveNotificationTarget(pendingNotificationTarget, generation: generation)
            }
        case .snapshot(let key, let snapshot):
            guard var state = sessions[key], state.isConnected else { return }
            state.setRows(snapshot.rows)
            sessions[key] = state
            await attentionCoordinator.reconcile(
                session: state.descriptor,
                records: snapshot.attention,
                policy: notificationPolicy
            )
        case .sessionUnavailable(let key, let message):
            guard var state = sessions[key] else { return }
            state.isConnected = false
            state.unavailableMessage = message
            state.setRows([])
            sessions[key] = state
            await attentionCoordinator.unavailable(session: key)
        case .removed(let key):
            let removedState = sessions.removeValue(forKey: key)
            if let pendingNotificationTarget, pendingNotificationTarget.target.session == key {
                self.pendingNotificationTarget = nil
                let name = removedState?.descriptor.displayName ?? sessionName(for: key, hint: pendingNotificationTarget)
                transientError = "\(name) is unavailable"
            }
            guard removedState != nil else { return }
            await attentionCoordinator.remove(session: key)
        case .descriptorChanged, .backendUnavailable, .backendHidden:
            break
        }
        deriveConnectionState()
    }

    var notificationPolicy: NotificationDeliveryPolicy {
        NotificationDeliveryPolicy(
            notificationsEnabled: preferences.notificationsEnabled,
            soundEnabled: preferences.notificationSoundEnabled,
            notifyStates: preferences.notifyStates
        )
    }

    func receiveNotificationTarget(_ target: SelectionTarget, generation: UUID) {
        guard isRunning, eventGeneration == generation else { return }
        let kind = target.target.session.backend
        // An unroutable target never supersedes the current selection.
        guard backend(for: kind) != nil else { return }
        supersedeSelection()
        guard let state = sessions[target.target.session] else {
            if discoveredBackends.contains(kind) {
                pendingNotificationTarget = nil
                transientError = "\(sessionName(for: target.target.session, hint: target)) is unavailable"
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
        startSelection(SelectionTarget(target: target.target, sessionDisplayName: state.descriptor.displayName))
    }

    func supersedeSelection() {
        selectionGeneration = UUID()
        transientError = nil
        selectionTask?.cancel()
    }

    func discardAbsentPendingTarget(kind: BackendKind, discovered: [AgentSessionDescriptor]) {
        guard let pendingNotificationTarget,
              pendingNotificationTarget.target.session.backend == kind,
              sessions[pendingNotificationTarget.target.session] == nil,
              !discovered.contains(where: { $0.key == pendingNotificationTarget.target.session }) else {
            return
        }
        self.pendingNotificationTarget = nil
        transientError = "\(sessionName(for: pendingNotificationTarget.target.session, hint: pendingNotificationTarget)) is unavailable"
    }

    /// User-facing session name: the store's descriptor, else the raw Herdr session ID.
    /// The payload's display name is only a hint for backends without either.
    func sessionName(for key: AgentSessionKey, hint: SelectionTarget) -> String {
        sessions[key]?.descriptor.displayName ?? key.herdrSessionID?.displayName ?? hint.sessionDisplayName
    }

    func deriveConnectionState() {
        if sessions.values.contains(where: \.isConnected) {
            connectionState = .connected
        } else if discoveredBackends.isEmpty {
            connectionState = .searching
        } else if sessions.isEmpty {
            connectionState = .noSessions
        } else {
            connectionState = .connecting
        }
    }

    func sections(_ keyPath: KeyPath<SessionPresentationState, [AgentRow]>) -> [SessionMenuSection] {
        sessions.values.compactMap { state in
            let rows = state[keyPath: keyPath]
            return rows.isEmpty ? nil : SessionMenuSection(session: state.descriptor, items: rows)
        }
        .sorted { sessionOrder($0.session, $1.session) }
    }

    /// `BackendKind` order, then the owning backend's comparator.
    func sessionOrder(_ lhs: AgentSessionDescriptor, _ rhs: AgentSessionDescriptor) -> Bool {
        if lhs.key.backend != rhs.key.backend {
            return lhs.key.backend.sortIndex < rhs.key.backend.sortIndex
        }
        guard let backend = backend(for: lhs.key.backend) else {
            return lhs.key.rawID < rhs.key.rawID
        }
        return backend.compareSessions(lhs, rhs)
    }
}
