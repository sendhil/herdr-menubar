import Foundation
import OSLog

/// The Herdr session supervisor presented as one agent backend.
@MainActor
final class HerdrBackend: AgentBackend {
    nonisolated var kind: BackendKind { .herdr }

    private let supervisor: any SessionSupervising
    private let terminalActivator: any TerminalActivating
    private let ghosttyFocuser: any GhosttySessionFocusing
    private let preferences: Preferences
    private var continuation: AsyncStream<BackendEvent>.Continuation?
    private var forwardTask: Task<Void, Never>?
    private var lifecycle: UInt64 = 0
    /// Sessions forwarded as known; Ghostty state is forgotten only for these.
    private var knownSessions: Set<SessionID> = []

    init(
        supervisor: any SessionSupervising,
        terminalActivator: any TerminalActivating,
        ghosttyFocuser: any GhosttySessionFocusing,
        preferences: Preferences
    ) {
        self.supervisor = supervisor
        self.terminalActivator = terminalActivator
        self.ghosttyFocuser = ghosttyFocuser
        self.preferences = preferences
    }

    func events() async -> AsyncStream<BackendEvent> {
        let (stream, continuation) = AsyncStream<BackendEvent>.makeStream()
        let owningLifecycle = lifecycle
        let source = await supervisor.events()
        guard owningLifecycle == lifecycle else {
            continuation.finish()
            return stream
        }
        forwardTask?.cancel()
        self.continuation?.finish()
        self.continuation = continuation
        forwardTask = Task { [weak self] in
            for await event in source {
                guard !Task.isCancelled else { return }
                self?.forward(event)
            }
        }
        return stream
    }

    func start() async {
        guard preferences.enabledBackends.contains(.herdr) else {
            continuation?.yield(.backendHidden)
            return
        }
        await supervisor.start()
    }

    func stop() async {
        lifecycle &+= 1
        let task = forwardTask
        forwardTask = nil
        continuation?.finish()
        continuation = nil
        knownSessions.removeAll()
        task?.cancel()
        await task?.value
        await supervisor.stop()
    }

    func retryUnavailable() async {
        await supervisor.retryUnavailable()
    }

    func focusServer(_ target: AgentTarget) async throws {
        guard let sessionID = target.session.herdrSessionID else {
            throw FocusError.failed("Could not focus pane: \(target.session.rawID) is not a Herdr session")
        }
        do {
            _ = try await supervisor.focus(sessionID: sessionID, paneID: target.paneID)
        } catch {
            throw FocusError.failed(
                "Could not focus pane in \(sessionID.displayName): \(error.localizedDescription)"
            )
        }
    }

    func activate(_ target: AgentTarget) async -> String? {
        guard let sessionID = target.session.herdrSessionID else { return nil }
        let bundleIdentifier = preferences.selectedTerminalBundleIdentifier
        if bundleIdentifier == GhosttyControlConstants.bundleIdentifier {
            do {
                try await ghosttyFocuser.focusAttachedClient(sessionID: sessionID)
                return nil
            } catch {
                AppLog.systemActions.error(
                    "Ghostty session focus failed: \(error.localizedDescription, privacy: .private)"
                )
                return Self.ghosttyFocusMessage(error, sessionName: sessionID.displayName)
            }
        }
        // A superseded selection must not bring the terminal forward.
        if Task.isCancelled { return nil }
        do {
            try await terminalActivator.activate(bundleIdentifier: bundleIdentifier)
            return nil
        } catch {
            AppLog.systemActions.error(
                "Terminal activation failed: \(error.localizedDescription, privacy: .private)"
            )
            return error.localizedDescription
        }
    }

    func refreshAfterSelection(_ target: AgentTarget) async {
        guard let sessionID = target.session.herdrSessionID else { return }
        await supervisor.refresh(sessionID: sessionID)
    }

    func markSeen(_ token: SeenToken) async {}

    func clearFinished() async {}

    nonisolated func compareSessions(_ lhs: AgentSessionDescriptor, _ rhs: AgentSessionDescriptor) -> Bool {
        guard let lhsID = lhs.key.herdrSessionID, let rhsID = rhs.key.herdrSessionID else {
            return lhs.key.rawID < rhs.key.rawID
        }
        return Self.sessionOrder(lhsID, rhsID)
    }
}

extension HerdrBackend {
    nonisolated static func makeSnapshot(_ snapshot: PresentationSnapshot, sessionID: SessionID) -> BackendSnapshot {
        let workspacesByID = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.workspaceID, $0) })
        let tabsByID = Dictionary(uniqueKeysWithValues: snapshot.tabs.map { ($0.tabID, $0) })
        var tabIDsByWorkspace: [String: Set<String>] = [:]
        for tab in snapshot.tabs {
            tabIDsByWorkspace[tab.workspaceID, default: []].insert(tab.tabID)
        }
        for pane in snapshot.panes {
            tabIDsByWorkspace[pane.workspaceID, default: []].insert(pane.tabID)
        }

        var rows: [AgentRow] = []
        // The last occurrence in an authoritative snapshot wins for a duplicate pane ID,
        // including occurrences that produce no row.
        var latestByPaneID: [String: AgentRow?] = [:]
        for pane in snapshot.panes {
            let workspace = workspacesByID[pane.workspaceID]
            let isMultiTab = (workspace?.tabCount ?? 0) > 1
                || (tabIDsByWorkspace[pane.workspaceID]?.count ?? 0) > 1
            let row = row(
                for: pane,
                sessionID: sessionID,
                workspace: workspace,
                tab: tabsByID[pane.tabID],
                workspaceIsMultiTab: isMultiTab
            )
            if let row { rows.append(row) }
            latestByPaneID[pane.paneID] = .some(row)
        }

        let attention = latestByPaneID.values
            .compactMap { $0 }
            .sorted(by: AgentRow.labelOrder)
            .compactMap { row -> AttentionRecord? in
                guard case .attention(let state) = row.state else { return nil }
                return AttentionRecord(
                    target: row.target,
                    recordID: "",
                    epoch: 0,
                    state: state,
                    visibleLabel: row.visibleLabel,
                    message: nil
                )
            }
        return BackendSnapshot(rows: rows, attention: attention)
    }

    nonisolated static func row(
        for pane: PaneInfo,
        sessionID: SessionID,
        workspace: WorkspaceInfo? = nil,
        tab: TabInfo? = nil,
        workspaceIsMultiTab: Bool = false
    ) -> AgentRow? {
        let state: RowState
        switch pane.agentStatus {
        case .blocked: state = .attention(.blocked)
        case .done: state = .attention(.done)
        case .working: state = .working
        case .idle, .unknown: return nil
        }
        let agentLabel = pane.agentLabel
        return AgentRow(
            target: AgentTarget(session: AgentSessionKey(herdr: sessionID), paneID: pane.paneID),
            displayLabel: displayLabel(
                pane: pane,
                workspace: workspace,
                tab: tab,
                workspaceIsMultiTab: workspaceIsMultiTab
            ),
            agentLabel: agentLabel,
            state: state,
            subtitle: "\(pane.agentStatus.rawValue) · \(agentLabel)",
            seenToken: nil
        )
    }

    nonisolated static func sessionOrder(_ lhs: SessionID, _ rhs: SessionID) -> Bool {
        switch (lhs, rhs) {
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

    nonisolated static func ghosttyFocusMessage(_ error: any Error, sessionName: String) -> String {
        let prefix = "Focused the pane in \(sessionName), but "
        switch error as? GhosttyFocusError {
        case .noAttachedClient, .lookupTimedOut:
            return prefix + "no attached Ghostty surface was found."
        case .unsupportedHerdr:
            return prefix + "this Herdr session must be updated for Ghostty surface focus."
        case .markerCleanupFailed:
            return prefix + "the temporary Ghostty focus marker could not be cleared."
        case .ghosttyUnavailable:
            return prefix + "Ghostty is not running."
        case .unsupportedGhostty:
            return prefix + "Ghostty 1.4.0 or later with Apple Event support is required."
        case .automationDenied:
            return prefix + "Automation permission to control Ghostty was denied. "
                + "Allow Herdr Menubar in System Settings > Privacy & Security > Automation."
        case .targetGone:
            return prefix + "the attached Ghostty surface or process disappeared."
        case .ambiguousMarker:
            return prefix + "more than one Ghostty surface matched the focus marker."
        case .ghosttyControlFailed, .none:
            return prefix + "Ghostty could not be controlled."
        }
    }

    private nonisolated static func displayLabel(
        pane: PaneInfo,
        workspace: WorkspaceInfo?,
        tab: TabInfo?,
        workspaceIsMultiTab: Bool
    ) -> String {
        if let workspace, !workspace.label.isEmpty {
            if workspaceIsMultiTab, let tab, !tab.label.isEmpty {
                return "\(workspace.label) · \(tab.label)"
            }
            return workspace.label
        }
        return pane.displayLabel
    }
}

private extension HerdrBackend {
    func forward(_ event: SessionSupervisorEvent) {
        guard let continuation else { return }
        switch event {
        case .discoverySnapshot(let descriptors):
            knownSessions.formUnion(descriptors.map(\.id))
            continuation.yield(.discovery(descriptors.map(AgentSessionDescriptor.init(herdr:))))
        case .connected(let descriptor, let snapshot):
            knownSessions.insert(descriptor.id)
            continuation.yield(.connected(
                AgentSessionDescriptor(herdr: descriptor),
                Self.makeSnapshot(snapshot, sessionID: descriptor.id)
            ))
        case .snapshot(let sessionID, let snapshot):
            continuation.yield(.snapshot(
                AgentSessionKey(herdr: sessionID),
                Self.makeSnapshot(snapshot, sessionID: sessionID)
            ))
        case .unavailable(let sessionID, let message):
            continuation.yield(.sessionUnavailable(AgentSessionKey(herdr: sessionID), message))
        case .removed(let sessionID):
            if knownSessions.remove(sessionID) != nil {
                ghosttyFocuser.forget(sessionID: sessionID)
            }
            continuation.yield(.removed(AgentSessionKey(herdr: sessionID)))
        }
    }
}
