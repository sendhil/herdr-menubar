import Foundation
import Observation
import OSLog

protocol AgentClientServing: Sendable {
    func events() async -> AsyncStream<HerdrClientEvent>
    func start() async
    func stop() async
    func retryNow() async
    func refresh() async
    func focus(paneID: String) async throws -> PaneInfo
}

extension HerdrClient: AgentClientServing {}

enum ConnectionState: Equatable, Sendable {
    case connected
    case disconnected(String)
}

struct AgentMenuItem: Identifiable, Equatable, Sendable {
    let paneID: String
    let displayLabel: String
    let agentLabel: String
    let status: AgentStatus

    var id: String { paneID }

    init(pane: PaneInfo) {
        paneID = pane.paneID
        displayLabel = pane.displayLabel
        agentLabel = pane.agentLabel
        status = pane.agentStatus
    }

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

@Observable @MainActor
final class AgentStore {
    private let client: any AgentClientServing
    private let terminalActivator: any TerminalActivating
    private let preferences: Preferences
    private var eventTask: Task<Void, Never>?
    private var eventGeneration = UUID()
    private var isRunning = false

    private(set) var connectionState: ConnectionState = .disconnected("Connecting to Herdr…")
    private(set) var attentionItems: [AgentMenuItem] = []
    private(set) var workingItems: [AgentMenuItem] = []
    private(set) var transientError: String?

    var attentionCount: Int { attentionItems.count }

    init(
        client: any AgentClientServing,
        terminalActivator: any TerminalActivating,
        preferences: Preferences = Preferences()
    ) {
        self.client = client
        self.terminalActivator = terminalActivator
        self.preferences = preferences
    }

    func start() async {
        guard !isRunning else { return }
        isRunning = true
        let generation = UUID()
        eventGeneration = generation
        let events = await client.events()
        eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.consume(event, generation: generation)
            }
        }
        await client.start()
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        eventGeneration = UUID()
        eventTask?.cancel()
        eventTask = nil
        connectionState = .disconnected("Disconnected from Herdr")
        attentionItems = []
        workingItems = []
        await client.stop()
    }

    func retry() async {
        transientError = nil
        await client.retryNow()
    }

    func select(_ item: AgentMenuItem) async {
        transientError = nil
        do {
            _ = try await client.focus(paneID: item.paneID)
        } catch {
            AppLog.systemActions.error("Pane focus failed: \(error.localizedDescription, privacy: .private)")
            transientError = "Could not focus pane: \(error.localizedDescription)"
            return
        }

        let terminalBundleIdentifier = preferences.selectedTerminalBundleIdentifier
        do {
            try await terminalActivator.activate(bundleIdentifier: terminalBundleIdentifier)
        } catch {
            AppLog.systemActions.error("Terminal activation failed: \(error.localizedDescription, privacy: .private)")
            transientError = error.localizedDescription
        }
        await client.refresh()
    }

    func apply(snapshot panes: [PaneInfo]) {
        attentionItems = panes
            .filter { $0.agentStatus == .blocked || $0.agentStatus == .done }
            .map(AgentMenuItem.init)
            .sorted(by: AgentMenuItem.attentionOrder)
        workingItems = panes
            .filter { $0.agentStatus == .working }
            .map(AgentMenuItem.init)
            .sorted(by: AgentMenuItem.labelOrder)
    }

    private func consume(_ event: HerdrClientEvent, generation: UUID) {
        guard isRunning, eventGeneration == generation else { return }
        switch event {
        case .connected(let panes):
            connectionState = .connected
            transientError = nil
            apply(snapshot: panes)
        case .snapshot(let panes):
            guard connectionState == .connected else { return }
            apply(snapshot: panes)
        case .disconnected(let message):
            connectionState = .disconnected(message)
            attentionItems = []
            workingItems = []
        }
    }
}
