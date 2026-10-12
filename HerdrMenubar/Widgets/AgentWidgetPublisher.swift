import Foundation
import CryptoKit
import WidgetKit
import OSLog

actor AgentWidgetPublisher {
    struct Dependencies: Sendable {
        var now: @Sendable () -> Date
        var activity: @Sendable (AgentSessionReference?) -> Date?
        var write: @Sendable (AgentWidgetSnapshot) throws -> Void
        var reload: @Sendable () -> Void
        var interval: Duration = .seconds(2)
        var configuredWidgetKinds: @Sendable () async throws -> [String] = {
            try await WidgetCenter.shared.currentConfigurations().map(\.kind)
        }
        var configurationInterval: Duration = .seconds(60)

        static let live = Dependencies(now: { .now }, activity: { reference in
            guard let reference, reference.agent == "pi", reference.kind == "path" else { return nil }
            let key = SHA256.hash(data: Data(reference.value.utf8)).map { String(format: "%02x", $0) }.joined()
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/herdr-widgets/activity/\(key).json")
            struct Activity: Decodable { let version: Int; let source: String; let sentAtMilliseconds: Double }
            guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? file.close() }
            guard let data = try? file.read(upToCount: 4097), data.count <= 4096,
                  let activity = try? JSONDecoder().decode(Activity.self, from: data),
                  activity.version == 1, activity.source == "interactive-confirmed", activity.sentAtMilliseconds.isFinite else { return nil }
            let date = Date(timeIntervalSince1970: activity.sentAtMilliseconds / 1000)
            return date <= .now ? date : nil
        }, write: { snapshot in
            try JSONEncoder().encode(snapshot).write(to: AgentWidgetSnapshot.fileURL(), options: .atomic)
        }, reload: { WidgetCenter.shared.reloadTimelines(ofKind: "HerdrAgents") })
    }

    private let supervisor: any SessionSupervising
    private let dependencies: Dependencies
    private var sessions: [SessionID: (SessionDescriptor, PresentationSnapshot)] = [:]
    private var verified: [SessionID: Date] = [:]
    private var refreshRequested: [SessionID: Date] = [:]
    private var unavailable: Set<SessionID> = []
    private var eventsTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var configurationTask: Task<Void, Never>?
    private var generation: UUID?
    private var updatesEnabled = true
    private var publicationGeneration: UUID?
    private var tickGeneration: UUID?
    private var lastAgents: [WidgetAgent] = []
    private var lastUnavailable = -1
    private var lastWrite = Date.distantPast
    private var lastSourceVerification: Date?
    private let logger = Logger(subsystem: "dev.herdr.menubar", category: "agent-widgets")

    init(supervisor: any SessionSupervising, dependencies: Dependencies = .live) {
        self.supervisor = supervisor
        self.dependencies = dependencies
    }

    func setUpdatesEnabled(_ enabled: Bool) {
        guard !Task.isCancelled, updatesEnabled != enabled else { return }
        updatesEnabled = enabled
        configurationTask?.cancel(); configurationTask = nil
        stopPublishing()
        if enabled, let generation { startConfigurationMonitoring(generation: generation) }
    }

    func start(updatesEnabled: Bool = true) async {
        guard generation == nil else { return }
        self.updatesEnabled = updatesEnabled
        let token = UUID()
        generation = token
        lastWrite = .distantPast
        lastUnavailable = -1
        lastSourceVerification = nil
        let events = await supervisor.events()
        guard generation == token else { return }
        eventsTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.consume(event, generation: token)
            }
        }
        startConfigurationMonitoring(generation: token)
    }

    private func startConfigurationMonitoring(generation token: UUID) {
        guard updatesEnabled, generation == token, !Task.isCancelled else { return }
        // WidgetKit discovery must not hold up the menu's own synchronization startup.
        configurationTask = Task { [weak self, interval = dependencies.configurationInterval] in
            await self?.checkWidgetConfiguration(generation: token)
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                await self?.checkWidgetConfiguration(generation: token)
            }
        }
    }

    func stop() {
        guard generation != nil else { return }
        let wasPublishing = publicationGeneration != nil
        generation = nil
        configurationTask?.cancel(); configurationTask = nil
        eventsTask?.cancel(); eventsTask = nil
        stopPublishing()
        sessions.removeAll(); verified.removeAll(); refreshRequested.removeAll(); unavailable.removeAll()
        guard wasPublishing else { return }
        do {
            var snapshot = AgentWidgetSnapshot(version: 1, writtenAt: dependencies.now(), agents: [], unavailableSessions: 0)
            snapshot.isRunning = false
            try dependencies.write(snapshot)
            dependencies.reload()
        } catch { logger.error("Widget shutdown snapshot failed") }
    }

    private func checkWidgetConfiguration(generation token: UUID) async {
        guard updatesEnabled, generation == token, !Task.isCancelled else { return }
        let hasAgentWidget: Bool
        do {
            hasAgentWidget = try await dependencies.configuredWidgetKinds().contains("HerdrAgents")
        } catch {
            hasAgentWidget = false
            logger.debug("Widget configuration unavailable; pausing publication")
        }
        guard updatesEnabled, generation == token, !Task.isCancelled else { return }
        guard hasAgentWidget else { stopPublishing(); return }
        guard publicationGeneration == nil else { return }
        let publication = UUID()
        publicationGeneration = publication
        lastWrite = .distantPast
        lastUnavailable = -1
        lastSourceVerification = nil
        timerTask = Task { [weak self, interval = dependencies.interval] in
            // Publish cached menubar events immediately, including when a widget is added later.
            await self?.tick(generation: token, publication: publication)
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                await self?.tick(generation: token, publication: publication)
            }
        }
    }

    private func stopPublishing() {
        publicationGeneration = nil
        tickGeneration = nil
        timerTask?.cancel(); timerTask = nil
    }

    /// One coalescing/publication cycle, only while an agent widget is configured.
    func tick() async {
        guard let generation, let publicationGeneration else { return }
        await tick(generation: generation, publication: publicationGeneration)
    }

    private func ownsPublication(generation token: UUID, publication: UUID) -> Bool {
        updatesEnabled && generation == token && publicationGeneration == publication && !Task.isCancelled
    }

    private func tick(generation token: UUID, publication: UUID) async {
        guard ownsPublication(generation: token, publication: publication), tickGeneration == nil else { return }
        tickGeneration = publication
        defer {
            if tickGeneration == publication { tickGeneration = nil }
        }
        let now = dependencies.now()
        let due = sessions.keys.filter {
            now.timeIntervalSince(refreshRequested[$0] ?? .distantPast) >= 60
        }.sorted {
            let left = refreshRequested[$0] ?? .distantPast, right = refreshRequested[$1] ?? .distantPast
            return left == right ? $0.displayName < $1.displayName : left < right
        }.prefix(4)
        for id in due {
            guard ownsPublication(generation: token, publication: publication) else { return }
            refreshRequested[id] = now
            // Existing client coalesces refreshes and bounds each source request with its timeout.
            // Only a resulting snapshot event advances verification, never the request itself.
            await supervisor.refresh(sessionID: id)
        }
        guard ownsPublication(generation: token, publication: publication) else { return }
        publishIfNeeded()
    }

    private func consume(_ event: SessionSupervisorEvent, generation token: UUID) {
        guard generation == token else { return }
        switch event {
        case .connected(let descriptor, let snapshot):
            sessions[descriptor.id] = (descriptor, snapshot); unavailable.remove(descriptor.id)
            verified[descriptor.id] = dependencies.now()
            refreshRequested[descriptor.id] = dependencies.now()
        case .snapshot(let id, let snapshot):
            if let (descriptor, _) = sessions[id] {
                sessions[id] = (descriptor, snapshot)
                verified[id] = dependencies.now()
            }
        case .unavailable(let id, _):
            sessions.removeValue(forKey: id); verified.removeValue(forKey: id)
            refreshRequested.removeValue(forKey: id); unavailable.insert(id)
        case .removed(let id):
            sessions.removeValue(forKey: id); verified.removeValue(forKey: id)
            refreshRequested.removeValue(forKey: id); unavailable.remove(id)
        case .discoverySnapshot: break
        }
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
                    status: pane.agentStatus.rawValue, lastMessageAt: dependencies.activity(pane.agentSession)))
            }
        }
        rows.sort { $0.id < $1.id }
        rows = Array(rows.prefix(500))
        let now = dependencies.now()
        let sourceVerifiedAt = verified.values.min()
        guard rows != lastAgents || unavailable.count != lastUnavailable || sourceVerifiedAt != lastSourceVerification || now.timeIntervalSince(lastWrite) >= 60 else { return }
        do {
            var snapshot = AgentWidgetSnapshot(version: 1, writtenAt: now, agents: rows, unavailableSessions: unavailable.count)
            snapshot.sourceVerifiedAt = sourceVerifiedAt
            try dependencies.write(snapshot)
            lastAgents = rows; lastUnavailable = unavailable.count; lastWrite = now; lastSourceVerification = sourceVerifiedAt
            dependencies.reload()
            logger.notice("Published \(rows.count) agent rows")
        } catch { logger.error("Agent widget snapshot unavailable: \(error.localizedDescription, privacy: .public)") }
    }
}
