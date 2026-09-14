import AppIntents
import SwiftUI
import WidgetKit

struct AgentEntry: TimelineEntry {
    let date: Date
    let snapshot: AgentWidgetSnapshot?
    let window: AgentWindow
    let amount: Int
    var needsRefresh = false
    // Freeze which timestamps were valid when this timeline was read.
    var eligibilityReferenceDate: Date? = nil
    var label: String {
        switch window {
        case .all: "All agents"
        case .today: "Messaged today"
        case .hours: "Messaged · last \(amount)h"
        case .days: "Messaged · last \(amount)d"
        }
    }
    var agents: [WidgetAgent] {
        guard !needsRefresh else { return [] }
        let rows = (snapshot?.agents ?? []).filter { $0.matches(window, amount: amount, now: date, recordedBy: eligibilityReferenceDate ?? date) }
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
        let plan = WidgetTimelinePlan(now: current.date, writtenAt: current.snapshot?.writtenAt,
            sourceVerifiedAt: current.snapshot?.sourceVerifiedAt,
            messageDates: current.snapshot?.agents.compactMap(\.lastMessageAt) ?? [], window: current.window, amount: current.amount)
        let entries = plan.steps.map { step in
            AgentEntry(date: step.date, snapshot: current.snapshot, window: current.window, amount: current.amount, needsRefresh: step.needsRefresh, eligibilityReferenceDate: current.date)
        }
        return Timeline(entries: entries, policy: .after(plan.reloadAt))
    }

    private func read(_ configuration: AgentWidgetConfiguration) -> AgentEntry {
        AgentEntry(date: .now, snapshot: try? AgentWidgetSnapshot.read(), window: configuration.window, amount: max(1, min(configuration.amount, 8760)))
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
