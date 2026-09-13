import Foundation
import CryptoKit
import WidgetKit
import OSLog

actor AgentWidgetPublisher {
    private let supervisor: any SessionSupervising
    private var sessions: [SessionID: (SessionDescriptor, PresentationSnapshot)] = [:]
    private var unavailable: Set<SessionID> = []
    private var eventsTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var lastAgents: [WidgetAgent] = []
    private var lastUnavailable = -1
    private var lastWrite = Date.distantPast
    private let logger = Logger(subsystem: "dev.herdr.menubar", category: "agent-widgets")

    init(supervisor: any SessionSupervising) { self.supervisor = supervisor }

    func start() async {
        guard eventsTask == nil else { return }
        lastWrite = .distantPast
        lastUnavailable = -1
        unavailable.removeAll()
        let events = await supervisor.events()
        eventsTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.consume(event)
            }
        }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.publishIfNeeded()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    func stop() {
        eventsTask?.cancel(); eventsTask = nil
        timerTask?.cancel(); timerTask = nil
        sessions = [:]
        do {
            var snapshot = AgentWidgetSnapshot(version: 1, writtenAt: .now, agents: [], unavailableSessions: 0)
            snapshot.isRunning = false
            try JSONEncoder().encode(snapshot).write(to: AgentWidgetSnapshot.fileURL(), options: .atomic)
            WidgetCenter.shared.reloadTimelines(ofKind: "HerdrAgents")
        } catch { logger.error("Widget shutdown snapshot failed") }
    }

    private func consume(_ event: SessionSupervisorEvent) {
        switch event {
        case .connected(let descriptor, let snapshot):
            sessions[descriptor.id] = (descriptor, snapshot); unavailable.remove(descriptor.id)
        case .snapshot(let id, let snapshot):
            if let (descriptor, _) = sessions[id] { sessions[id] = (descriptor, snapshot) }
        case .unavailable(let id, _): sessions.removeValue(forKey: id); unavailable.insert(id)
        case .removed(let id): sessions.removeValue(forKey: id); unavailable.remove(id)
        case .discoverySnapshot: break
        }
        // The fixed two-second ticker coalesces bursts without indefinite debounce.
    }

    private func lastMessage(_ reference: AgentSessionReference?) -> Date? {
        guard let reference, reference.agent == "pi", reference.kind == "path" else { return nil }
        let key = SHA256.hash(data: Data(reference.value.utf8)).map { String(format: "%02x", $0) }.joined()
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/herdr-widgets/activity/\(key).json")
        struct Activity: Decodable { let version: Int; let source: String; let sentAtMilliseconds: Double }
        guard let data = try? Data(contentsOf: url), data.count <= 4096,
              let activity = try? JSONDecoder().decode(Activity.self, from: data),
              activity.version == 1, activity.source == "interactive-confirmed", activity.sentAtMilliseconds.isFinite else { return nil }
        let date = Date(timeIntervalSince1970: activity.sentAtMilliseconds / 1000)
        return date <= .now ? date : nil
    }

    private func publishIfNeeded() {
        var rows: [WidgetAgent] = []
        for (id, (descriptor, snapshot)) in sessions {
            let sessionKey: String
            switch id { case .default: sessionKey = "default"; case .named(let name): sessionKey = "named:" + name }
            let workspaces = Dictionary(snapshot.workspaces.map { ($0.workspaceID, $0.label) }, uniquingKeysWith: { first, _ in first })
            let tabs = Dictionary(snapshot.tabs.map { ($0.tabID, $0.label) }, uniquingKeysWith: { first, _ in first })
            let agents = snapshot.panes.filter { $0.agent != nil }
            let tabCounts = Dictionary(grouping: agents, by: \.tabID).mapValues(\.count)
            for pane in agents {
                let type = pane.agent ?? "Agent"
                let tab = tabs[pane.tabID] ?? ""
                var name = [pane.displayAgent, pane.label, pane.title].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty && $0 != type && $0 != tab } ?? ""
                if (tabCounts[pane.tabID] ?? 0) > 1 && name.isEmpty { name = pane.paneID }
                let workspace = workspaces[pane.workspaceID] ?? pane.workspaceID
                rows.append(WidgetAgent(session: sessionKey, workspaceID: pane.workspaceID,
                    workspace: id == .default ? workspace : "\(descriptor.displayName) / \(workspace)",
                    tabID: pane.tabID, tab: tab, paneID: pane.paneID, agentName: name, agentType: type,
                    status: pane.agentStatus.rawValue, lastMessageAt: lastMessage(pane.agentSession)))
            }
        }
        rows.sort { $0.id < $1.id }
        rows = Array(rows.prefix(500))
        let now = Date.now
        guard rows != lastAgents || unavailable.count != lastUnavailable || now.timeIntervalSince(lastWrite) >= 60 else { return }
        do {
            let snapshot = AgentWidgetSnapshot(version: 1, writtenAt: now, agents: rows, unavailableSessions: unavailable.count)
            try JSONEncoder().encode(snapshot).write(to: AgentWidgetSnapshot.fileURL(), options: .atomic)
            lastAgents = rows; lastUnavailable = unavailable.count; lastWrite = now
            WidgetCenter.shared.reloadTimelines(ofKind: "HerdrAgents")
            logger.notice("Published \(rows.count) agent rows")
        } catch { logger.error("Agent widget snapshot unavailable: \(error.localizedDescription, privacy: .public)") }
    }
}
