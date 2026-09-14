import SwiftUI
import WidgetKit

/// The layouts share the same ordering and eligibility as the timeline entry.
/// Only the visible prefix changes with the space available to each family.
struct AgentWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AgentEntry

    var body: some View {
        AgentWidgetContent(entry: entry, large: family == .systemLarge)
            .containerBackground(.background, for: .widget)
    }
}

/// Family-specific content is independent of the WidgetKit environment so the
/// same layout can be rendered by the gallery, widget host, and visual checks.
struct AgentWidgetContent: View {
    let entry: AgentEntry
    let large: Bool

    var body: some View {
        GeometryReader { geometry in
            let presentation = AgentWidgetPresentation(agents: entry.agents, large: large, availableHeight: Double(geometry.size.height))
            VStack(alignment: .leading, spacing: 0) {
                header
                if let snapshot = entry.snapshot, snapshot.isRunning {
                    if entry.needsRefresh {
                        emptyState("Refresh needed", detail: "Open Herdr Menubar to update this window.", symbol: "arrow.clockwise")
                    } else {
                        summary(presentation)
                        if entry.agents.isEmpty {
                            if snapshot.unavailableSessions > 0 {
                                emptyState("Sessions unavailable", detail: "Herdr is reconnecting to your sessions.", symbol: "network.slash")
                            } else {
                                emptyState(entry.window == .all ? "No agents connected" : "No messages in this window", detail: entry.window == .all ? "Open an agent in Herdr." : "Message a tracked Pi agent to include it.", symbol: "text.bubble")
                            }
                        } else {
                            rows(presentation.shown)
                            Spacer(minLength: 0)
                        }
                    }
                    footer(snapshot, overflow: entry.needsRefresh ? 0 : presentation.overflow)
                } else {
                    emptyState("Open Herdr Menubar", detail: "Your agents will appear here.", symbol: "terminal")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "terminal.fill")
                .foregroundStyle(.tint)
                .widgetAccentable()
                .accessibilityHidden(true)
            Text("Herdr").font(.system(size: large ? 15 : 14, weight: .semibold))
            Spacer(minLength: 8)
            Text(entry.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(height: large ? 20 : 18)
    }

    private func summary(_ presentation: AgentWidgetPresentation) -> some View {
        HStack(spacing: 5) {
            if presentation.blockedCount > 0 {
                Text("\(presentation.blockedCount) blocked").foregroundStyle(.primary).fontWeight(.semibold)
            }
            if presentation.workingCount > 0 {
                if presentation.blockedCount > 0 { Text("·") }
                Text("\(presentation.workingCount) working")
            }
            if presentation.otherCount > 0 {
                if presentation.blockedCount + presentation.workingCount > 0 {
                    Text("·")
                    Text("\(presentation.otherCount) other")
                } else {
                    Text("\(presentation.otherCount) \(presentation.otherCount == 1 ? "agent" : "agents")")
                }
            }
            if presentation.blockedCount + presentation.workingCount + presentation.otherCount == 0 {
                Text("No matching agents")
            }
        }
        .font(.system(size: large ? 11 : 10))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(height: large ? 14 : 12, alignment: .leading)
        .padding(.top, large ? 6 : 4)
        .padding(.bottom, large ? 12 : 4)
        .accessibilityElement(children: .combine)
    }

    private func rows(_ agents: [WidgetAgent]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                if large && (index == 0 || agents[index - 1].groupID != agent.groupID) {
                    Text(agent.workspace)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(height: 18, alignment: .bottomLeading)
                        .accessibilityAddTraits(.isHeader)
                }
                Link(destination: agent.url) {
                    HStack(spacing: 7) {
                        Image(systemName: symbol(agent.status))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(color(agent.status))
                            .frame(width: 14)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(agent.title)
                                .font(.system(size: large ? 14 : 12, weight: agent.status == "blocked" ? .semibold : .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if !large {
                                Text(agent.workspace)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Spacer(minLength: 5)
                        Text(agent.status.capitalized)
                            .font(.system(size: 10, weight: agent.status == "blocked" ? .semibold : .regular))
                            .foregroundStyle(agent.status == "blocked" ? .primary : .secondary)
                            .fixedSize()
                    }
                    .frame(height: large ? 26 : 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(agent.workspace), \(agent.title), \(agent.status)")
                .accessibilityValue(agent.lastMessageAt.map { "Last message " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                .accessibilityHint("Opens this agent in Herdr")
            }
        }
    }

    private func emptyState(_ title: String, detail: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Spacer(minLength: 4)
            Label(title, systemImage: symbol)
                .font(.system(size: large ? 14 : 12, weight: .medium))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func footer(_ snapshot: AgentWidgetSnapshot, overflow: Int) -> some View {
        HStack(spacing: 4) {
            if snapshot.writtenAt > entry.date {
                Image(systemName: "clock.badge.exclamationmark").accessibilityHidden(true)
                Text("Update time unverified")
            } else if snapshot.isPublicationStale(at: entry.date) {
                Image(systemName: "clock.badge.exclamationmark").accessibilityHidden(true)
                Text("Last update")
                Text(snapshot.writtenAt, style: .relative)
                Text("ago")
            } else if snapshot.unavailableSessions > 0 {
                Image(systemName: "network.slash").accessibilityHidden(true)
                Text("\(snapshot.unavailableSessions) \(snapshot.unavailableSessions == 1 ? "session unavailable" : "sessions unavailable")")
            } else if snapshot.isSourceUnverified(at: entry.date) {
                Image(systemName: "network.slash").accessibilityHidden(true)
                Text("Connection unverified")
            } else {
                Text("Updated")
                Text(snapshot.writtenAt, style: .relative)
                Text("ago")
            }
            Spacer(minLength: 3)
            if overflow > 0 {
                Text("+\(overflow) more").fontWeight(.medium).fixedSize()
            }
        }
        .font(.system(size: large ? 10 : 9))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(height: large ? 20 : 16, alignment: .bottom)
        .accessibilityElement(children: .combine)
    }

    private func symbol(_ status: String) -> String {
        switch status {
        case "blocked": "exclamationmark.triangle.fill"
        case "working": "ellipsis.circle"
        case "done": "checkmark.circle"
        case "idle": "circle"
        default: "questionmark.circle"
        }
    }

    private func color(_ status: String) -> Color {
        switch status {
        case "blocked": .orange
        case "working": .accentColor
        case "done": .green
        default: .secondary
        }
    }
}
