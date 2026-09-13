import AppIntents
import SwiftUI
import WidgetKit

extension AgentWindow: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Message window"
    static let caseDisplayRepresentations: [AgentWindow: DisplayRepresentation] = [
        .all: "All agents", .today: "Today", .hours: "Last hours", .days: "Last days"
    ]
}

struct AgentWidgetConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Herdr agents"
    static let description = IntentDescription("Show agents you messaged within a chosen window.")
    @Parameter(title: "Message window", default: .all) var window: AgentWindow
    @Parameter(title: "Number of hours or days", default: 24, inclusiveRange: (1, 8760)) var amount: Int
}

struct AgentEntry: TimelineEntry {
    let date: Date
    let snapshot: AgentWidgetSnapshot?
    let window: AgentWindow
    let amount: Int
    var label: String {
        switch window {
        case .all: "All agents"
        case .today: "Messaged today"
        case .hours: "Messaged · last \(amount)h"
        case .days: "Messaged · last \(amount)d"
        }
    }
    var agents: [WidgetAgent] {
        let rows = (snapshot?.agents ?? []).filter { $0.matches(window, amount: amount, now: date) }
        let groups = Dictionary(grouping: rows, by: \.groupID)
        func priority(_ agent: WidgetAgent) -> Int {
            switch agent.status { case "blocked": 0; case "working": 1; case "done": 2; default: 3 }
        }
        let orderedGroups = groups.values.sorted { left, right in
            let leftDate = left.compactMap(\.lastMessageAt).max() ?? .distantPast
            let rightDate = right.compactMap(\.lastMessageAt).max() ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            let lp = left.map(priority).min() ?? 3, rp = right.map(priority).min() ?? 3
            if lp != rp { return lp < rp }
            return left[0].workspace.localizedStandardCompare(right[0].workspace) == .orderedAscending
        }
        return orderedGroups.flatMap { group in
            group.sorted {
                if $0.lastMessageAt != $1.lastMessageAt { return ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast) }
                if priority($0) != priority($1) { return priority($0) < priority($1) }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
    }
}

struct AgentProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> AgentEntry {
        AgentEntry(date: .now, snapshot: AgentWidgetSnapshot(version: 1, writtenAt: .now, agents: [
            WidgetAgent(session: "default", workspaceID: "sample", workspace: "Luna Escalation", tabID: "1", tab: "New Session", paneID: "1", agentName: "", agentType: "pi", status: "working", lastMessageAt: .now),
            WidgetAgent(session: "default", workspaceID: "sample", workspace: "Luna Escalation", tabID: "2", tab: "Monitor", paneID: "2", agentName: "", agentType: "pi", status: "done", lastMessageAt: .now)
        ], unavailableSessions: 0), window: .all, amount: 24)
    }
    func snapshot(for configuration: AgentWidgetConfiguration, in context: Context) async -> AgentEntry {
        context.isPreview ? placeholder(in: context) : read(configuration)
    }
    func timeline(for configuration: AgentWidgetConfiguration, in context: Context) async -> Timeline<AgentEntry> {
        let current = read(configuration)
        var dates = [current.date.addingTimeInterval(180)]
        if let snapshot = current.snapshot {
            dates.append(snapshot.writtenAt.addingTimeInterval(180))
            if current.window == .hours || current.window == .days {
                let interval = Double(current.amount) * (current.window == .days ? 86400 : 3600)
                dates += snapshot.agents.compactMap { $0.lastMessageAt?.addingTimeInterval(interval) }
            } else if current.window == .today, let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: current.date)) { dates.append(midnight) }
        }
        let future = Array(Set(dates.filter { $0 > current.date })).sorted().prefix(32)
        let entries = [current] + future.map { AgentEntry(date: $0, snapshot: current.snapshot, window: current.window, amount: current.amount) }
        return Timeline(entries: entries, policy: .after(current.date.addingTimeInterval(300)))
    }
    private func read(_ configuration: AgentWidgetConfiguration) -> AgentEntry {
        AgentEntry(date: .now, snapshot: try? AgentWidgetSnapshot.read(), window: configuration.window, amount: max(1, min(configuration.amount, 8760)))
    }
}

struct AgentWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AgentEntry
    private var limit: Int { family == .systemLarge ? 7 : 3 }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Herdr", systemImage: "terminal.fill").font(.headline)
                Spacer()
                Text(entry.label).font(.caption2).foregroundStyle(.secondary)
            }
            if let snapshot = entry.snapshot, snapshot.isRunning {
                let agents = entry.agents
                let shown = Array(agents.prefix(limit))
                if agents.isEmpty {
                    Spacer(minLength: 0)
                    Text(entry.window == .all ? "No agents connected" : "No recorded messages in this window").font(.subheadline)
                    Text(entry.window == .all ? "Open an agent in Herdr." : "Pi tracking begins after loading the activity extension.").font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, agent in
                            if index == 0 || shown[index - 1].groupID != agent.groupID {
                                Text(agent.workspace).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Link(destination: agent.url) {
                                HStack(spacing: 6) {
                                    Circle().fill(color(agent.status)).frame(width: 5, height: 5)
                                    Text(agent.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Spacer(minLength: 3)
                                    Text(agent.status.capitalized).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                    Spacer(minLength: 0)
                }
                HStack {
                    if entry.date.timeIntervalSince(snapshot.writtenAt) >= 180 { Text("Updates delayed") }
                    else if snapshot.unavailableSessions > 0 { Text("Some sessions unavailable") }
                    else { Text("Updated"); Text(snapshot.writtenAt, style: .relative) }
                    Spacer(minLength: 0)
                    if agents.count > limit { Text("+\(agents.count - limit) more") }
                }.font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Spacer()
                Text("Open Herdr Menubar").font(.subheadline)
                Text("Your agents will appear here.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .containerBackground(.background, for: .widget)
    }
    private func color(_ status: String) -> Color {
        switch status { case "working": .blue; case "blocked": .orange; case "done": .green; default: .secondary }
    }
}

struct HerdrAgentWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "HerdrAgents", intent: AgentWidgetConfiguration.self, provider: AgentProvider()) { AgentWidgetView(entry: $0) }
            .configurationDisplayName("Herdr agents")
            .description("Your agents, grouped by workspace. Filter by when you last sent a message.")
            .supportedFamilies([.systemMedium, .systemLarge])
    }
}
